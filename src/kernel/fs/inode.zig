// src/kernel/fs/inode.zig — Phase 3.D in-memory inode cache.
//
// NINODE=32 in-memory inode entries. Each entry caches a DiskInode plus
// metadata: refs (held by namei walkers + open files), valid (whether
// dinode has been read from disk), busy (sleep-locked).
//
// API:
//   init():                  zero the icache.
//   iget(inum):              return existing entry or claim a free slot;
//                            increments refs; valid=false until ilock'd.
//   idup(ip):                bump refs; return ip.
//   ilock(ip):               sleep until !busy, then busy=true; if !valid,
//                            bread the inode block, copy the slot into
//                            ip.dinode, brelse, valid=true.
//   iunlock(ip):             busy=false; wakeup waiters.
//   iput(ip):                refs -= 1. (3.E adds the on-zero on-disk
//                            truncate when nlink == 0.)
//   bmap(ip, bn):            translate logical block bn to disk block#.
//                            Returns 0 for unallocated entries (read-as-EOF).
//   readi(ip, dst, off, n):  copy n bytes into dst. Returns bytes copied
//                            (clamped to ip.dinode.size).

const std = @import("std");
const layout = @import("layout.zig");
const bufcache = @import("bufcache.zig");
const proc = @import("../proc.zig");
const kprintf = @import("../kprintf.zig");

pub const NINODE: u32 = 32;

pub const InMemInode = struct {
    inum: u32,
    refs: u32,
    valid: bool,
    busy: bool,
    dinode: layout.DiskInode,
};

pub var icache: [NINODE]InMemInode = undefined;

pub fn init() void {
    var i: u32 = 0;
    while (i < NINODE) : (i += 1) {
        icache[i].inum = 0;
        icache[i].refs = 0;
        icache[i].valid = false;
        icache[i].busy = false;
        icache[i].dinode = std.mem.zeroes(layout.DiskInode);
    }
}

pub fn iget(inum: u32) *InMemInode {
    var empty: ?*InMemInode = null;
    var i: u32 = 0;
    while (i < NINODE) : (i += 1) {
        const ip = &icache[i];
        if (ip.refs > 0 and ip.inum == inum) {
            ip.refs += 1;
            return ip;
        }
        if (empty == null and ip.refs == 0) empty = ip;
    }
    const slot = empty orelse kprintf.panic("iget: icache full", .{});
    slot.inum = inum;
    slot.refs = 1;
    slot.valid = false;
    return slot;
}

pub fn idup(ip: *InMemInode) *InMemInode {
    ip.refs += 1;
    return ip;
}

pub fn ilock(ip: *InMemInode) void {
    while (ip.busy) proc.sleep(@intFromPtr(ip));
    ip.busy = true;

    if (!ip.valid) {
        // Inode (inum) lives in inode block (inum / INODES_PER_BLOCK + INODE_START_BLK).
        const blk = layout.INODE_START_BLK + ip.inum / layout.INODES_PER_BLOCK;
        const slot = ip.inum % layout.INODES_PER_BLOCK;
        const b = bufcache.bread(blk);
        defer bufcache.brelse(b);

        const inodes_ptr: [*]const layout.DiskInode = @ptrCast(@alignCast(&b.data[0]));
        ip.dinode = inodes_ptr[slot];
        ip.valid = true;
    }
}

pub fn iunlock(ip: *InMemInode) void {
    proc.wakeup(@intFromPtr(ip));
    ip.busy = false;
}

pub fn iput(ip: *InMemInode) void {
    if (ip.refs == 0) kprintf.panic("iput: refs == 0 (inum {d})", .{ip.inum});
    ip.refs -= 1;
    // 3.E: if refs == 0 and dinode.nlink == 0, ilock + truncate + zero
    // the dinode + bwrite the inode block. 3.D never reaches this branch.
}

/// Map logical block index `bn` (0-based) within the file to its on-disk
/// block number. Returns 0 for blocks past the file's allocated extent
/// (caller's readi treats 0 as a hole / EOF).
///
/// Caller MUST hold ip locked (busy=true, valid=true).
pub fn bmap(ip: *InMemInode, bn: u32) u32 {
    if (bn < layout.NDIRECT) {
        return ip.dinode.addrs[bn];
    }
    if (bn < layout.NDIRECT + layout.NINDIRECT) {
        const ind_blk = ip.dinode.addrs[layout.NDIRECT];
        if (ind_blk == 0) return 0;
        const b = bufcache.bread(ind_blk);
        defer bufcache.brelse(b);
        const ptrs: [*]const u32 = @ptrCast(@alignCast(&b.data[0]));
        return ptrs[bn - layout.NDIRECT];
    }
    kprintf.panic("bmap: bn {d} > MAX_FILE_BLOCKS", .{bn});
}

/// Copy up to n bytes from inode at offset off into dst. Reads past
/// ip.dinode.size return 0. Reads of unallocated blocks return zeros.
///
/// Caller MUST hold ip locked.
pub fn readi(ip: *InMemInode, dst: [*]u8, off: u32, n: u32) u32 {
    if (off >= ip.dinode.size) return 0;
    const real_n = if (off + n > ip.dinode.size) ip.dinode.size - off else n;

    var copied: u32 = 0;
    while (copied < real_n) {
        const cur_off = off + copied;
        const bn = cur_off / layout.BLOCK_SIZE;
        const blk_off = cur_off % layout.BLOCK_SIZE;
        const remain = real_n - copied;
        const chunk = if (blk_off + remain > layout.BLOCK_SIZE)
            layout.BLOCK_SIZE - blk_off
        else
            remain;

        const dblk = bmap(ip, bn);
        if (dblk == 0) {
            // Hole — readi returns zeros without touching disk.
            var i: u32 = 0;
            while (i < chunk) : (i += 1) dst[copied + i] = 0;
        } else {
            const b = bufcache.bread(dblk);
            defer bufcache.brelse(b);
            var i: u32 = 0;
            while (i < chunk) : (i += 1) dst[copied + i] = b.data[blk_off + i];
        }
        copied += chunk;
    }
    return copied;
}
