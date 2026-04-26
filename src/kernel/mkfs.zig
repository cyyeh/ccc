// src/kernel/mkfs.zig — Phase 3.D host-side FS image builder.
//
// Walks --root + --bin into a 4 MB image written to --out:
//   block 0       boot sector (zeros, reserved)
//   block 1       superblock
//   block 2       block bitmap
//   blocks 3..6   inode table
//   blocks 7..1023  data blocks
//
// Inode 1 is hard-wired as root (/). Subdirectories `bin` and `etc` are
// created by walking --bin (each file → /bin/<name>) and --root (every
// non-/bin file → /<rel-path>) respectively.
//
// Bound: NINODES=64, NBLOCKS=1024 (data: 1017). Errors out cleanly if
// the staged tree exceeds either bound.
//
// Usage:
//   zig-out/bin/mkfs --root <dir> --bin <dir> --out <path>

const std = @import("std");
const layout = @import("fs/layout.zig");
const Io = std.Io;

const ImageBuilder = struct {
    image: [layout.NBLOCKS * layout.BLOCK_SIZE]u8,
    inodes: [layout.NINODES]layout.DiskInode,
    next_inum: u32, // next free inum (1-based)
    next_blk: u32, // next free data block (≥ DATA_START_BLK)
    bitmap: [layout.NBLOCKS / 8]u8,

    fn init(self: *ImageBuilder) void {
        self.image = std.mem.zeroes([layout.NBLOCKS * layout.BLOCK_SIZE]u8);
        self.inodes = std.mem.zeroes([layout.NINODES]layout.DiskInode);
        self.bitmap = std.mem.zeroes([layout.NBLOCKS / 8]u8);
        // Reserve blocks 0..6 (boot/super/bitmap/inode-table).
        var b: u32 = 0;
        while (b < layout.DATA_START_BLK) : (b += 1) self.setBitmap(b);
        self.next_inum = 1; // inum 0 == "free"
        self.next_blk = layout.DATA_START_BLK;
    }

    fn setBitmap(self: *ImageBuilder, blk: u32) void {
        self.bitmap[blk / 8] |= (@as(u8, 1) << @intCast(blk % 8));
    }

    fn allocInum(self: *ImageBuilder) ?u32 {
        if (self.next_inum >= layout.NINODES) return null;
        const i = self.next_inum;
        self.next_inum += 1;
        return i;
    }

    fn allocBlock(self: *ImageBuilder) ?u32 {
        if (self.next_blk >= layout.NBLOCKS) return null;
        const b = self.next_blk;
        self.next_blk += 1;
        self.setBitmap(b);
        return b;
    }

    /// Write `data` into the inode `inum`'s data blocks. Allocates direct
    /// blocks for the first NDIRECT logical blocks; allocates an indirect
    /// block + per-leaf data blocks for any blocks past NDIRECT. Updates
    /// inode size + addrs.
    fn writeFile(self: *ImageBuilder, inum: u32, data: []const u8) !void {
        const ip = &self.inodes[inum]; // index == inum (slot 0 reserved as Free)
        ip.size = @intCast(data.len);

        var off: u32 = 0;
        var bn: u32 = 0;
        while (off < data.len) : ({
            bn += 1;
            off += layout.BLOCK_SIZE;
        }) {
            const remain = data.len - off;
            const chunk = if (remain > layout.BLOCK_SIZE) layout.BLOCK_SIZE else remain;
            const blk = self.allocBlock() orelse return error.OutOfBlocks;

            const start = blk * layout.BLOCK_SIZE;
            @memcpy(self.image[start .. start + chunk], data[off .. off + chunk]);

            if (bn < layout.NDIRECT) {
                ip.addrs[bn] = blk;
            } else {
                // Need indirect block.
                if (ip.addrs[layout.NDIRECT] == 0) {
                    ip.addrs[layout.NDIRECT] = self.allocBlock() orelse return error.OutOfBlocks;
                }
                const ind_off = ip.addrs[layout.NDIRECT] * layout.BLOCK_SIZE;
                const ind_idx = bn - layout.NDIRECT;
                if (ind_idx >= layout.NINDIRECT) return error.FileTooBig;
                const ptrs: [*]u32 = @ptrCast(@alignCast(&self.image[ind_off]));
                ptrs[ind_idx] = blk;
            }
        }
    }

    /// Append a DirEntry to dir's data blocks (creating blocks as needed).
    fn appendDirEntry(self: *ImageBuilder, dir_inum: u32, name: []const u8, entry_inum: u32) !void {
        if (name.len > layout.DIR_NAME_LEN - 1) return error.NameTooLong;
        const dir = &self.inodes[dir_inum];
        const off = dir.size;
        const bn = off / layout.BLOCK_SIZE;
        const blk_off = off % layout.BLOCK_SIZE;

        // Allocate a new block if we'd straddle the boundary or this is
        // the first DirEntry in a fresh block.
        if (blk_off == 0) {
            if (bn >= layout.NDIRECT) return error.DirTooBig; // 3.D: dirs ≤ 12 blocks
            const blk = self.allocBlock() orelse return error.OutOfBlocks;
            dir.addrs[bn] = blk;
        }

        const dst_blk = dir.addrs[bn];
        const dst_off = dst_blk * layout.BLOCK_SIZE + blk_off;
        var de: layout.DirEntry = .{ .inum = @intCast(entry_inum), .name = std.mem.zeroes([layout.DIR_NAME_LEN]u8) };
        var i: u32 = 0;
        while (i < name.len) : (i += 1) de.name[i] = name[i];

        const de_bytes = std.mem.asBytes(&de);
        @memcpy(self.image[dst_off .. dst_off + 16], de_bytes);
        dir.size += 16;
    }

    fn createDir(self: *ImageBuilder, parent_inum: u32) !u32 {
        const inum = self.allocInum() orelse return error.OutOfInodes;
        const ip = &self.inodes[inum];
        ip.type = .Dir;
        ip.nlink = 1;
        ip.size = 0;
        try self.appendDirEntry(inum, ".", inum);
        try self.appendDirEntry(inum, "..", parent_inum);
        return inum;
    }

    fn createFile(self: *ImageBuilder, dir_inum: u32, name: []const u8, data: []const u8) !void {
        const inum = self.allocInum() orelse return error.OutOfInodes;
        self.inodes[inum].type = .File;
        self.inodes[inum].nlink = 1;
        try self.writeFile(inum, data);
        try self.appendDirEntry(dir_inum, name, inum);
    }

    fn finalize(self: *ImageBuilder) void {
        // Superblock at block 1.
        const sb: *layout.SuperBlock = @ptrCast(@alignCast(&self.image[layout.SUPERBLOCK_BLK * layout.BLOCK_SIZE]));
        sb.* = .{
            .magic = layout.SUPER_MAGIC,
            .nblocks = layout.NBLOCKS,
            .ninodes = layout.NINODES,
            .bitmap_blk = layout.BITMAP_BLK,
            .inode_start = layout.INODE_START_BLK,
            .data_start = layout.DATA_START_BLK,
            .dirty = 0,
        };

        // Bitmap at block 2.
        const bmp_off = layout.BITMAP_BLK * layout.BLOCK_SIZE;
        @memcpy(self.image[bmp_off .. bmp_off + self.bitmap.len], &self.bitmap);

        // Inode table at blocks 3..6 (we only fill block 3 — 64 inodes × 64 B = 4 KB).
        const inodes_off = layout.INODE_START_BLK * layout.BLOCK_SIZE;
        const inodes_bytes = std.mem.asBytes(&self.inodes);
        @memcpy(self.image[inodes_off .. inodes_off + inodes_bytes.len], inodes_bytes);
    }
};

fn populateFromDir(io: Io, builder: *ImageBuilder, dir_inum: u32, dir: Io.Dir, gpa: std.mem.Allocator) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                var f = try dir.openFile(io, entry.name, .{});
                defer f.close(io);
                const sz = try f.length(io);
                const buf = try gpa.alloc(u8, sz);
                defer gpa.free(buf);
                _ = try f.readPositionalAll(io, buf, 0);
                try builder.createFile(dir_inum, entry.name, buf);
            },
            .directory => {
                const sub_inum = try builder.createDir(dir_inum);
                try builder.appendDirEntry(dir_inum, entry.name, sub_inum);
                var sub_dir = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer sub_dir.close(io);
                try populateFromDir(io, builder, sub_inum, sub_dir, gpa);
            },
            else => {},
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stderr_buf: [512]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_fw.interface;

    const argv = try init.minimal.args.toSlice(gpa);
    defer gpa.free(argv);

    var root_path: ?[]const u8 = null;
    var bin_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) {
        if (std.mem.eql(u8, argv[i], "--root") and i + 1 < argv.len) {
            root_path = argv[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, argv[i], "--bin") and i + 1 < argv.len) {
            bin_path = argv[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, argv[i], "--out") and i + 1 < argv.len) {
            out_path = argv[i + 1];
            i += 2;
        } else {
            stderr.print("mkfs: unexpected arg {s}\n", .{argv[i]}) catch {};
            stderr.flush() catch {};
            std.process.exit(2);
        }
    }
    if (root_path == null or bin_path == null or out_path == null) {
        stderr.print("usage: mkfs --root <dir> --bin <dir> --out <path>\n", .{}) catch {};
        stderr.flush() catch {};
        std.process.exit(2);
    }

    var builder = try gpa.create(ImageBuilder);
    defer gpa.destroy(builder);
    builder.init();

    // Create root inode (inum 1) with `.` and `..` (both → root). We
    // pre-fill the inode here rather than calling createDir(0) because
    // createDir would seed `..` with the bogus parent_inum=0 first; the
    // entries below are the canonical root listing.
    const root_inum = builder.allocInum() orelse return error.OutOfInodes;
    if (root_inum != layout.ROOT_INUM) return error.RootInumMismatch;
    const root_ip = &builder.inodes[root_inum];
    root_ip.type = .Dir;
    root_ip.nlink = 1;
    root_ip.size = 0;
    try builder.appendDirEntry(root_inum, ".", root_inum);
    try builder.appendDirEntry(root_inum, "..", root_inum);

    // /etc + /bin subdirectories.
    const etc_inum = try builder.createDir(root_inum);
    try builder.appendDirEntry(root_inum, "etc", etc_inum);
    const bin_inum = try builder.createDir(root_inum);
    try builder.appendDirEntry(root_inum, "bin", bin_inum);

    // Walk --root: every file goes into /etc (3.D simplification — only
    // /etc is supported; the spec eventually expands to /var, /tmp, etc.,
    // but 3.D's e2e only needs /etc/motd).
    var root_dir = Io.Dir.cwd().openDir(io, root_path.?, .{ .iterate = true }) catch |err| {
        stderr.print("mkfs: cannot open --root {s}: {s}\n", .{ root_path.?, @errorName(err) }) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };
    defer root_dir.close(io);
    var etc_dir_opt: ?Io.Dir = root_dir.openDir(io, "etc", .{ .iterate = true }) catch null;
    if (etc_dir_opt) |*d| {
        defer d.close(io);
        try populateFromDir(io, builder, etc_inum, d.*, gpa);
    }

    // Walk --bin: every file goes into /bin.
    var bin_dir = Io.Dir.cwd().openDir(io, bin_path.?, .{ .iterate = true }) catch |err| {
        stderr.print("mkfs: cannot open --bin {s}: {s}\n", .{ bin_path.?, @errorName(err) }) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };
    defer bin_dir.close(io);
    try populateFromDir(io, builder, bin_inum, bin_dir, gpa);

    builder.finalize();

    // Write the image.
    var f = try Io.Dir.cwd().createFile(io, out_path.?, .{ .truncate = true });
    defer f.close(io);
    try f.writePositionalAll(io, &builder.image, 0);
}
