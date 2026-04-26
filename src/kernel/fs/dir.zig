// src/kernel/fs/dir.zig — Phase 3.E directory operations.
//
// Directories store an array of 16-byte DirEntry records back-to-back
// inside their inode's data blocks. inum == 0 means a free slot.
//
// API:
//   dirlookup(dir, name): linear-scan dir's data via readi; return
//                         the matching entry's inum or null.
//   dirlink(dir, name, inum): find free slot or append; write DirEntry.
//   dirunlink(dir, name): zero the matching slot.

const std = @import("std");
const layout = @import("layout.zig");
const inode = @import("inode.zig");

/// Compare a directory entry's NUL-padded name slot against an exact-length target.
fn nameEq(slot_name: []const u8, target: []const u8) bool {
    if (target.len >= slot_name.len) return false;
    var i: u32 = 0;
    while (i < target.len) : (i += 1) {
        if (slot_name[i] != target[i]) return false;
    }
    return slot_name[target.len] == 0;
}

pub fn dirlookup(dir: *inode.InMemInode, name: []const u8) ?u32 {
    if (dir.dinode.type != .Dir) return null;
    if (name.len == 0 or name.len > layout.DIR_NAME_LEN - 1) return null;

    var off: u32 = 0;
    var de: layout.DirEntry = undefined;
    while (off < dir.dinode.size) : (off += @sizeOf(layout.DirEntry)) {
        const got = inode.readi(dir, @ptrCast(&de), off, @sizeOf(layout.DirEntry));
        if (got != @sizeOf(layout.DirEntry)) return null;
        if (de.inum == 0) continue;

        if (nameEq(de.name[0..], name)) return de.inum;
    }
    return null;
}

pub fn dirlink(dir: *inode.InMemInode, name: []const u8, inum: u16) bool {
    if (name.len == 0 or name.len >= layout.DIR_NAME_LEN) return false;

    // Reject duplicates.
    var off: u32 = 0;
    var de: layout.DirEntry = undefined;
    while (off < dir.dinode.size) : (off += @sizeOf(layout.DirEntry)) {
        const got = inode.readi(dir, @ptrCast(&de), off, @sizeOf(layout.DirEntry));
        if (got != @sizeOf(layout.DirEntry)) return false;
        if (de.inum != 0 and nameEq(de.name[0..], name)) return false;
    }

    // Find first free slot OR fall through to append at end.
    off = 0;
    while (off < dir.dinode.size) : (off += @sizeOf(layout.DirEntry)) {
        const got = inode.readi(dir, @ptrCast(&de), off, @sizeOf(layout.DirEntry));
        if (got != @sizeOf(layout.DirEntry)) break;
        if (de.inum == 0) break;
    }
    // Note: if the loop ran to completion without finding a free slot,
    // `off == dir.dinode.size` — writei will extend the directory.

    var entry: layout.DirEntry = .{ .inum = inum, .name = std.mem.zeroes([layout.DIR_NAME_LEN]u8) };
    var i: u32 = 0;
    while (i < name.len) : (i += 1) entry.name[i] = name[i];
    // Remaining bytes already zero from std.mem.zeroes.

    const wrote = inode.writei(dir, @ptrCast(&entry), off, @sizeOf(layout.DirEntry));
    return wrote == @sizeOf(layout.DirEntry);
}

pub fn dirunlink(dir: *inode.InMemInode, name: []const u8) bool {
    var off: u32 = 0;
    var de: layout.DirEntry = undefined;
    while (off < dir.dinode.size) : (off += @sizeOf(layout.DirEntry)) {
        const got = inode.readi(dir, @ptrCast(&de), off, @sizeOf(layout.DirEntry));
        if (got != @sizeOf(layout.DirEntry)) return false;
        if (de.inum != 0 and nameEq(de.name[0..], name)) {
            de.inum = 0;
            de.name = std.mem.zeroes([layout.DIR_NAME_LEN]u8);
            const wrote = inode.writei(dir, @ptrCast(&de), off, @sizeOf(layout.DirEntry));
            return wrote == @sizeOf(layout.DirEntry);
        }
    }
    return false;
}
