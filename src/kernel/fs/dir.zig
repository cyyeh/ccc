// src/kernel/fs/dir.zig — Phase 3.D directory operations.
//
// Directories store an array of 16-byte DirEntry records back-to-back
// inside their inode's data blocks. inum == 0 means a free slot.
//
// API:
//   dirlookup(dir, name): linear-scan dir's data via readi; return
//                         the matching entry's inum or null.
//   dirlink(dir, name, inum): NOT implemented in 3.D (write path is
//                             3.E). Returns false unconditionally so
//                             3.D's syscalls compile against a stable
//                             API surface.

const std = @import("std");
const layout = @import("layout.zig");
const inode = @import("inode.zig");

pub fn dirlookup(dir: *inode.InMemInode, name: []const u8) ?u32 {
    if (dir.dinode.type != .Dir) return null;
    if (name.len == 0 or name.len > layout.DIR_NAME_LEN - 1) return null;

    var off: u32 = 0;
    var de: layout.DirEntry = undefined;
    while (off < dir.dinode.size) : (off += @sizeOf(layout.DirEntry)) {
        const got = inode.readi(dir, @ptrCast(&de), off, @sizeOf(layout.DirEntry));
        if (got != @sizeOf(layout.DirEntry)) return null;
        if (de.inum == 0) continue;

        // Compare name (NUL-terminated within the 14-byte field).
        var i: u32 = 0;
        var match = true;
        while (i < name.len) : (i += 1) {
            if (de.name[i] != name[i]) {
                match = false;
                break;
            }
        }
        // The byte after the name (if any) must be NUL or the end.
        if (match and (name.len == layout.DIR_NAME_LEN or de.name[name.len] == 0)) {
            return de.inum;
        }
    }
    return null;
}

/// 3.D stub. 3.E implements the real write-path body that finds an
/// inum==0 slot (or appends), constructs a DirEntry, and writes it
/// via writei.
pub fn dirlink(dir: *inode.InMemInode, name: []const u8, inum: u16) bool {
    _ = dir;
    _ = name;
    _ = inum;
    return false;
}
