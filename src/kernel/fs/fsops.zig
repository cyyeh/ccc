// src/kernel/fs/fsops.zig — Phase 3.E create + unlink glue.
//
// Bridges the syscall layer (sysOpenat O_CREAT, sysMkdirat, sysUnlinkat)
// with the FS primitives (path, dir, inode, balloc).
//
// API:
//   create(path, type) -> ?*InMemInode
//     - For .File: idempotent open-or-create (returns existing if a File
//       at `path` already exists; null if a non-File exists there).
//     - For .Dir: strictly create-new (null if anything at `path` exists).
//   unlink(path) -> i32
//     - Decrements nlink; on zero, frees blocks via inode.iput truncate.
//     - Refuses to unlink "." or ".." or non-empty directories.
//     - Returns 0 on success, -1 on any failure.

const std = @import("std");
const layout = @import("layout.zig");
const inode = @import("inode.zig");
const path_mod = @import("path.zig");
const dir = @import("dir.zig");

pub fn create(path: []const u8, itype: layout.FileType) ?*inode.InMemInode {
    var leaf: [layout.DIR_NAME_LEN]u8 = undefined;
    const parent = path_mod.nameiparent(path, &leaf) orelse return null;

    const leaf_slice = leafSlice(&leaf);
    if (leaf_slice.len == 0) {
        inode.iput(parent);
        return null;
    }

    inode.ilock(parent);

    // Existing entry?
    if (dir.dirlookup(parent, leaf_slice)) |existing_inum| {
        inode.iunlock(parent);
        inode.iput(parent);
        const existing_ip = inode.iget(existing_inum);
        inode.ilock(existing_ip);
        if (itype == .File and existing_ip.dinode.type == .File) {
            inode.iunlock(existing_ip);
            return existing_ip; // idempotent open-or-create for files
        }
        inode.iunlock(existing_ip);
        inode.iput(existing_ip);
        return null;
    }

    const new_ip = inode.ialloc(itype) orelse {
        inode.iunlock(parent);
        inode.iput(parent);
        return null;
    };

    // For dirs, install . and .. entries first.
    if (itype == .Dir) {
        inode.ilock(new_ip);
        const ok_dot = dir.dirlink(new_ip, ".", @intCast(new_ip.inum));
        const ok_dotdot = dir.dirlink(new_ip, "..", @intCast(parent.inum));
        if (!ok_dot or !ok_dotdot) {
            inode.iunlock(new_ip);
            inode.iput(new_ip);
            inode.iunlock(parent);
            inode.iput(parent);
            return null;
        }
        // Bump parent's nlink for the new "..".
        parent.dinode.nlink += 1;
        inode.iupdate(parent);
        inode.iunlock(new_ip);
    }

    if (!dir.dirlink(parent, leaf_slice, @intCast(new_ip.inum))) {
        inode.iunlock(parent);
        inode.iput(parent);
        inode.iput(new_ip);
        return null;
    }

    inode.iunlock(parent);
    inode.iput(parent);
    return new_ip;
}

pub fn unlink(path: []const u8) i32 {
    var leaf: [layout.DIR_NAME_LEN]u8 = undefined;
    const parent = path_mod.nameiparent(path, &leaf) orelse return -1;

    const leaf_slice = leafSlice(&leaf);
    if (leaf_slice.len == 0 or
        (leaf_slice.len == 1 and leaf_slice[0] == '.') or
        (leaf_slice.len == 2 and leaf_slice[0] == '.' and leaf_slice[1] == '.'))
    {
        inode.iput(parent);
        return -1;
    }

    inode.ilock(parent);
    const target_inum = dir.dirlookup(parent, leaf_slice) orelse {
        inode.iunlock(parent);
        inode.iput(parent);
        return -1;
    };

    const target_ip = inode.iget(target_inum);
    inode.ilock(target_ip);

    if (target_ip.dinode.type == .Dir and !isDirEmpty(target_ip)) {
        inode.iunlock(target_ip);
        inode.iput(target_ip);
        inode.iunlock(parent);
        inode.iput(parent);
        return -1;
    }

    _ = dir.dirunlink(parent, leaf_slice);

    if (target_ip.dinode.type == .Dir) {
        // Drop the parent's nlink that mkdir bumped.
        parent.dinode.nlink -= 1;
        inode.iupdate(parent);
    }

    target_ip.dinode.nlink -= 1;
    inode.iupdate(target_ip);
    inode.iunlock(target_ip);
    inode.iput(target_ip); // triggers truncate if nlink == 0 + last ref

    inode.iunlock(parent);
    inode.iput(parent);
    return 0;
}

fn leafSlice(leaf: *const [layout.DIR_NAME_LEN]u8) []const u8 {
    var n: u32 = 0;
    while (n < leaf.len and leaf[n] != 0) : (n += 1) {}
    return leaf[0..n];
}

fn isDirEmpty(d: *inode.InMemInode) bool {
    var off: u32 = 2 * @sizeOf(layout.DirEntry); // skip . and ..
    var de: layout.DirEntry = undefined;
    while (off < d.dinode.size) : (off += @sizeOf(layout.DirEntry)) {
        const got = inode.readi(d, @ptrCast(&de), off, @sizeOf(layout.DirEntry));
        if (got != @sizeOf(layout.DirEntry)) break;
        if (de.inum != 0) return false;
    }
    return true;
}

// Host tests for the leaf helpers (run via `zig build test`).
const testing = std.testing;

test "leafSlice trims at NUL" {
    var buf: [layout.DIR_NAME_LEN]u8 = std.mem.zeroes([layout.DIR_NAME_LEN]u8);
    @memcpy(buf[0..3], "abc");
    const slice = leafSlice(&buf);
    try testing.expectEqual(@as(usize, 3), slice.len);
    try testing.expectEqualStrings("abc", slice);
}

test "leafSlice empty when first byte is NUL" {
    const buf: [layout.DIR_NAME_LEN]u8 = std.mem.zeroes([layout.DIR_NAME_LEN]u8);
    const slice = leafSlice(&buf);
    try testing.expectEqual(@as(usize, 0), slice.len);
}
