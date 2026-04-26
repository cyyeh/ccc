// src/kernel/fs/bufcache.zig — Phase 3.D buffer cache.
//
// NBUF=16 fixed-size buffer cache. Each buffer is 4 KB + ~32 B of
// metadata. Doubly-linked LRU list with the most-recently-released
// buffer at the head. Sleep-locked on `busy`; reference-counted via
// `refs`.
//
// API:
//   init():       set up the LRU list, mark every buffer invalid.
//   bget(blk):    sleep-lock + return a buffer for blk; loads from disk
//                 lazily (caller must use bread for content).
//   bread(blk):   bget + (if invalid) block.read into buf.data + valid=true.
//   bwrite(buf):  block.write from buf.data + dirty=false. Unused by 3.D.
//   brelse(buf):  release lock, bump LRU, decrement refs, wake waiters.

const std = @import("std");
const layout = @import("layout.zig");
const proc = @import("../proc.zig");
const block = @import("../block.zig");
const kprintf = @import("../kprintf.zig");

pub const NBUF: u32 = 16;
const SENTINEL_BLOCK: u32 = 0xFFFF_FFFF;

pub const Buf = struct {
    block: u32,
    valid: bool,
    dirty: bool,
    refs: u32,
    busy: bool,
    data: [layout.BLOCK_SIZE]u8 align(4),
    next: ?*Buf,
    prev: ?*Buf,
};

pub var bcache: [NBUF]Buf = undefined;
var head: ?*Buf = null;
var tail: ?*Buf = null;

pub fn init() void {
    var i: u32 = 0;
    while (i < NBUF) : (i += 1) {
        bcache[i].block = SENTINEL_BLOCK;
        bcache[i].valid = false;
        bcache[i].dirty = false;
        bcache[i].refs = 0;
        bcache[i].busy = false;
        bcache[i].next = null;
        bcache[i].prev = null;
    }

    // Wire LRU list: head <-> bcache[0] <-> bcache[1] <-> ... <-> bcache[NBUF-1] <-> tail
    head = &bcache[0];
    tail = &bcache[NBUF - 1];
    var k: u32 = 0;
    while (k < NBUF) : (k += 1) {
        bcache[k].prev = if (k == 0) null else &bcache[k - 1];
        bcache[k].next = if (k == NBUF - 1) null else &bcache[k + 1];
    }
}

fn detach(b: *Buf) void {
    if (b.prev) |p| p.next = b.next else head = b.next;
    if (b.next) |n| n.prev = b.prev else tail = b.prev;
    b.prev = null;
    b.next = null;
}

fn attachFront(b: *Buf) void {
    b.next = head;
    b.prev = null;
    if (head) |h| h.prev = b;
    head = b;
    if (tail == null) tail = b;
}

pub fn bget(blk: u32) *Buf {
    // Pass 1: search for an existing buffer for blk.
    var cur: ?*Buf = head;
    while (cur) |b| : (cur = b.next) {
        if (b.block == blk) {
            b.refs += 1;
            while (b.busy) proc.sleep(@intFromPtr(b));
            b.busy = true;
            return b;
        }
    }

    // Pass 2: pick LRU evictee — search tail→head for refs==0 && !busy.
    cur = tail;
    while (cur) |b| : (cur = b.prev) {
        if (b.refs == 0 and !b.busy) {
            b.block = blk;
            b.valid = false;
            b.dirty = false;
            b.refs = 1;
            b.busy = true;
            return b;
        }
    }

    kprintf.panic("bcache: no evictable buffer", .{});
}

pub fn bread(blk: u32) *Buf {
    const b = bget(blk);
    if (!b.valid) {
        block.read(blk, @as(u32, @intCast(@intFromPtr(&b.data[0]))));
        b.valid = true;
    }
    return b;
}

pub fn bwrite(b: *Buf) void {
    block.write(b.block, @as(u32, @intCast(@intFromPtr(&b.data[0]))));
    b.dirty = false;
}

pub fn brelse(b: *Buf) void {
    proc.wakeup(@intFromPtr(b));
    b.busy = false;
    b.refs -= 1;

    // Move b to the head of the LRU list (most recently released).
    detach(b);
    attachFront(b);
}

test "init wires a 16-element doubly-linked list" {
    if (@import("builtin").os.tag != .freestanding) {
        init();
        // Walk head→tail counting nodes.
        var cur: ?*Buf = head;
        var n: u32 = 0;
        var prev: ?*Buf = null;
        while (cur) |b| : ({
            prev = b;
            cur = b.next;
        }) {
            try std.testing.expectEqual(prev, b.prev);
            n += 1;
        }
        try std.testing.expectEqual(@as(u32, NBUF), n);
        try std.testing.expectEqual(prev, tail);
    }
}

test "detach + attachFront moves a buffer to the head" {
    if (@import("builtin").os.tag != .freestanding) {
        init();
        const target = &bcache[5];
        detach(target);
        attachFront(target);
        try std.testing.expectEqual(@as(?*Buf, target), head);
        try std.testing.expectEqual(@as(?*Buf, null), target.prev);
    }
}
