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
//   bmap(ip, bn, for_write): translate logical block bn to disk block#.
//                            When for_write=true, lazily allocates missing
//                            blocks. Returns 0 for holes (for_write=false)
//                            or on out-of-disk (for_write=true).
//   readi(ip, dst, off, n):  copy n bytes into dst. Returns bytes copied
//                            (clamped to ip.dinode.size).
//   writei(ip, src, off, n): write n bytes from src at offset off, growing
//                            the file as needed. Returns bytes written.

const std = @import("std");
const layout = @import("layout.zig");
const bufcache = @import("bufcache.zig");
const balloc = @import("balloc.zig");
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

/// Flush this inode's in-memory dinode back to its slot in the inode table.
pub fn iupdate(ip: *InMemInode) void {
    const blk = layout.INODE_START_BLK + ip.inum / layout.INODES_PER_BLOCK;
    const slot = ip.inum % layout.INODES_PER_BLOCK;
    const buf = bufcache.bread(blk);
    const inodes: [*]layout.DiskInode = @ptrCast(@alignCast(&buf.data[0]));
    inodes[slot] = ip.dinode;
    bufcache.bwrite(buf);
    bufcache.brelse(buf);
}

/// Find the first free disk inode (type == .Free), claim it with the
/// given type (writes back via bwrite), and return the in-memory cache
/// entry holding it. Returns null on full inode table.
pub fn ialloc(itype: layout.FileType) ?*InMemInode {
    var inum: u32 = 1; // inum 0 is the "no inode" sentinel; root is inum 1
    while (inum < layout.NINODES) : (inum += 1) {
        const blk = layout.INODE_START_BLK + inum / layout.INODES_PER_BLOCK;
        const slot = inum % layout.INODES_PER_BLOCK;
        const buf = bufcache.bread(blk);
        const inodes: [*]layout.DiskInode = @ptrCast(@alignCast(&buf.data[0]));
        if (inodes[slot].type == .Free) {
            inodes[slot] = .{
                .type = itype,
                .nlink = 1,
                .size = 0,
                .addrs = std.mem.zeroes([layout.NDIRECT + 1]u32),
                ._reserved = std.mem.zeroes([4]u8),
            };
            bufcache.bwrite(buf);
            bufcache.brelse(buf);

            // Bring it into the in-memory cache.
            const ip = iget(inum);
            ilock(ip);
            // ip.dinode now reflects what we just wrote.
            iunlock(ip);
            return ip;
        }
        bufcache.brelse(buf);
    }
    return null;
}

/// Map logical block index `bn` (0-based) within the file to its on-disk
/// block number. When `for_write` is true and the entry is unallocated (== 0),
/// allocates a fresh block via balloc.alloc (zero-filling the indirect block
/// on first allocation). Returns 0 for holes when for_write=false, or on
/// out-of-disk when for_write=true.
///
/// Caller MUST hold ip locked (busy=true, valid=true).
pub fn bmap(ip: *InMemInode, bn: u32, for_write: bool) u32 {
    if (bn < layout.NDIRECT) {
        var addr = ip.dinode.addrs[bn];
        if (addr == 0 and for_write) {
            addr = balloc.alloc();
            if (addr == 0) return 0;
            ip.dinode.addrs[bn] = addr;
            // Caller is responsible for iupdate after the write.
        }
        return addr;
    }

    const ix = bn - layout.NDIRECT;
    if (ix >= layout.NINDIRECT) {
        kprintf.panic("bmap: out of range bn={d}", .{bn});
    }

    var ind = ip.dinode.addrs[layout.NDIRECT];
    if (ind == 0) {
        if (!for_write) return 0;
        ind = balloc.alloc();
        if (ind == 0) return 0;
        ip.dinode.addrs[layout.NDIRECT] = ind;
        // Zero-fill the new indirect block so unused entries read back as 0.
        const zbuf = bufcache.bread(ind);
        @memset(&zbuf.data, 0);
        bufcache.bwrite(zbuf);
        bufcache.brelse(zbuf);
    }

    const buf = bufcache.bread(ind);
    const slots: [*]u32 = @ptrCast(@alignCast(&buf.data[0]));
    var addr = slots[ix];
    if (addr == 0 and for_write) {
        addr = balloc.alloc();
        if (addr == 0) {
            bufcache.brelse(buf);
            return 0;
        }
        slots[ix] = addr;
        bufcache.bwrite(buf);
    }
    bufcache.brelse(buf);
    return addr;
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

        const dblk = bmap(ip, bn, false);
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

/// Write `n` bytes from `src` to inode `ip` starting at offset `off`.
/// Returns bytes actually written (may be < n if disk fills) or -1 on
/// bad arguments.
pub fn writei(ip: *InMemInode, src: [*]const u8, off: u32, n: u32) i32 {
    if (off + n > layout.MAX_FILE_BLOCKS * layout.BLOCK_SIZE) return -1;

    var written: u32 = 0;
    while (written < n) {
        const cur_off = off + written;
        const bn = cur_off / layout.BLOCK_SIZE;
        const within = cur_off % layout.BLOCK_SIZE;
        const remain_block = layout.BLOCK_SIZE - within;
        const remain_total = n - written;
        const chunk = if (remain_block < remain_total) remain_block else remain_total;

        const blk = bmap(ip, bn, true);
        if (blk == 0) break; // out of disk

        const buf = bufcache.bread(blk);
        var i: u32 = 0;
        while (i < chunk) : (i += 1) {
            buf.data[within + i] = src[written + i];
        }
        bufcache.bwrite(buf);
        bufcache.brelse(buf);
        written += chunk;
    }

    if (off + written > ip.dinode.size) {
        ip.dinode.size = off + written;
    }
    iupdate(ip);
    return @intCast(written);
}
