// src/kernel/fs/balloc.zig — Phase 3.D block bitmap allocator.
//
// One bit per block in NBLOCKS. Blocks 0..6 (boot/super/bitmap/inodes)
// are reserved-set by mkfs. blocks 7..1023 are the data region.
//
// 3.D read path doesn't call alloc/free — the bitmap is consulted only
// indirectly via mkfs-set bits, and bmap reads inode.dinode.addrs.
// We land the full API here so 3.E (write path) can call it without
// revisiting this file.

const std = @import("std");
const layout = @import("layout.zig");
const bufcache = @import("bufcache.zig");
const kprintf = @import("../kprintf.zig");

inline fn bitOf(b: *bufcache.Buf, blk: u32) u8 {
    return (b.data[blk / 8] >> @intCast(blk % 8)) & 1;
}

inline fn setBit(b: *bufcache.Buf, blk: u32) void {
    b.data[blk / 8] |= (@as(u8, 1) << @intCast(blk % 8));
}

inline fn clearBit(b: *bufcache.Buf, blk: u32) void {
    b.data[blk / 8] &= ~(@as(u8, 1) << @intCast(blk % 8));
}

/// Returns true if blk is currently free (bit cleared).
pub fn isFree(blk: u32) bool {
    if (blk >= layout.NBLOCKS) return false;
    const b = bufcache.bread(layout.BITMAP_BLK);
    defer bufcache.brelse(b);
    return bitOf(b, blk) == 0;
}

/// Allocate the first free block ≥ DATA_START_BLK; mark it allocated;
/// write the bitmap back. Returns 0 (invalid block) on full disk.
pub fn alloc() u32 {
    const b = bufcache.bread(layout.BITMAP_BLK);
    defer bufcache.brelse(b);
    var blk: u32 = layout.DATA_START_BLK;
    while (blk < layout.NBLOCKS) : (blk += 1) {
        if (bitOf(b, blk) == 0) {
            setBit(b, blk);
            bufcache.bwrite(b);
            return blk;
        }
    }
    return 0;
}

/// Free a previously-allocated data block. Panics if blk is reserved.
pub fn free(blk: u32) void {
    if (blk < layout.DATA_START_BLK or blk >= layout.NBLOCKS) {
        kprintf.panic("balloc.free: invalid blk {d}", .{blk});
    }
    const b = bufcache.bread(layout.BITMAP_BLK);
    defer bufcache.brelse(b);
    clearBit(b, blk);
    bufcache.bwrite(b);
}

test "bitOf / setBit / clearBit on a synthetic buffer" {
    if (@import("builtin").os.tag != .freestanding) {
        var b: bufcache.Buf = undefined;
        b.data = std.mem.zeroes([layout.BLOCK_SIZE]u8);
        try std.testing.expectEqual(@as(u8, 0), bitOf(&b, 100));
        setBit(&b, 100);
        try std.testing.expectEqual(@as(u8, 1), bitOf(&b, 100));
        try std.testing.expectEqual(@as(u8, 0), bitOf(&b, 99));
        try std.testing.expectEqual(@as(u8, 0), bitOf(&b, 101));
        clearBit(&b, 100);
        try std.testing.expectEqual(@as(u8, 0), bitOf(&b, 100));
    }
}
