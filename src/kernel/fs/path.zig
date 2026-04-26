// src/kernel/fs/path.zig — Phase 3.D path resolution.
//
// Iterative left-to-right walker. Absolute paths start at root inum 1;
// relative paths start at cur.cwd (or root if cur.cwd is 0 / lazy).
//
// API:
//   namei(path):                  return final inode, or null on missing.
//   nameiparent(path, name_out):  return parent inode + write leaf name
//                                 into name_out. Used by 3.E mkdirat /
//                                 unlinkat / openat-O_CREAT.
//
// Bounds: path ≤ MAX_PATH (256 bytes); component ≤ DIR_NAME_LEN-1 (13).
// Both bounds enforced with null returns.

const std = @import("std");
const layout = @import("layout.zig");
const inode = @import("inode.zig");
const dir = @import("dir.zig");

pub const MAX_PATH: u32 = 256;

const PathError = error{
    Empty,
    TooLong,
    BadComponent,
};

/// Skip slashes; return the start of the next component or null at end.
fn skipSlashes(p: []const u8, off: u32) ?u32 {
    var i = off;
    while (i < p.len and p[i] == '/') i += 1;
    if (i >= p.len) return null;
    return i;
}

/// Find the end of the component starting at off (up to next '/' or end).
/// Returns (start_of_next, component_slice).
fn nextComponent(p: []const u8, off: u32) ?struct { next: u32, comp: []const u8 } {
    const start = skipSlashes(p, off) orelse return null;
    var end = start;
    while (end < p.len and p[end] != '/') end += 1;
    if (end - start > layout.DIR_NAME_LEN - 1) return null;
    return .{ .next = end, .comp = p[start..end] };
}

/// Returns the starting inode for path resolution: root for absolute,
/// cwd for relative. Caller owns one ref on the returned inode.
fn startInode(path: []const u8) *inode.InMemInode {
    if (path.len > 0 and path[0] == '/') {
        return inode.iget(layout.ROOT_INUM);
    }
    // TODO(Task 12): use proc.cur().cwd once the field exists.
    return inode.iget(layout.ROOT_INUM);
}

/// Walk path. If name_parent_out is non-null, stop one component short
/// and write the leaf component into it (NUL-padded). Returns the final
/// inode (refs incremented) or null on failure.
fn nameix(path: []const u8, name_parent_out: ?*[layout.DIR_NAME_LEN]u8) ?*inode.InMemInode {
    if (path.len == 0 or path.len > MAX_PATH) return null;

    // Special case: absolute root "/" alone.
    if (name_parent_out == null and path.len == 1 and path[0] == '/') {
        return inode.iget(layout.ROOT_INUM);
    }

    var cur = startInode(path);
    var off: u32 = 0;

    while (true) {
        const step = nextComponent(path, off) orelse {
            // No more components — cur is the answer.
            return cur;
        };
        const comp = step.comp;
        const next = step.next;

        // Look ahead: is comp the LAST component?
        const is_last = (skipSlashes(path, next) == null);

        if (is_last and name_parent_out != null) {
            // Caller wants the parent. Copy the leaf name and return cur.
            var i: u32 = 0;
            while (i < layout.DIR_NAME_LEN) : (i += 1) {
                name_parent_out.?[i] = if (i < comp.len) comp[i] else 0;
            }
            return cur;
        }

        // Walk into comp.
        inode.ilock(cur);
        if (cur.dinode.type != .Dir) {
            inode.iunlock(cur);
            inode.iput(cur);
            return null;
        }
        const child_inum = dir.dirlookup(cur, comp) orelse {
            inode.iunlock(cur);
            inode.iput(cur);
            return null;
        };
        inode.iunlock(cur);
        const next_ip = inode.iget(child_inum);
        inode.iput(cur);
        cur = next_ip;
        off = next;
    }
}

pub fn namei(path: []const u8) ?*inode.InMemInode {
    return nameix(path, null);
}

pub fn nameiparent(path: []const u8, name_out: *[layout.DIR_NAME_LEN]u8) ?*inode.InMemInode {
    return nameix(path, name_out);
}
