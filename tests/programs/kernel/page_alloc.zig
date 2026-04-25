// tests/programs/kernel/page_alloc.zig — physical-page free-list allocator.
//
// Phase 3.B replaces Phase 2's bump allocator. The free-list links every
// 4 KB page in [heap_start, RAM_END) by reusing the page itself as its
// own list node — the first u32 of a free page is `next` (a PA, with 0
// meaning end-of-list). `alloc()` pops the head and returns a zeroed
// page; `free(pa)` pushes back. Both run in O(1).
//
// We pre-link in PA-descending order so `init()` walks the available
// region once. The first allocation returns the LOWEST physical page,
// not the highest — kmain therefore knows that early allocations land
// near `heap_start` (a useful debugging invariant).
//
// Out-of-memory returns null. Callers that should panic instead use
// `allocZeroPage()` — a shim wrapping `alloc()` with a panic on null.

const kprintf = @import("kprintf.zig");

pub const PAGE_SIZE: u32 = 4096;
pub const RAM_END: u32 = 0x8800_0000; // 128 MiB RAM ceiling

extern const _end: u8;

pub const FreeList = struct {
    head: u32,

    pub fn empty() FreeList {
        return .{ .head = 0 };
    }

    pub fn pushPage(self: *FreeList, pa: u32) void {
        const slot: *volatile u32 = @ptrFromInt(pa);
        slot.* = self.head;
        self.head = pa;
    }

    pub fn pop(self: *FreeList) ?u32 {
        if (self.head == 0) return null;
        const pa = self.head;
        const slot: *volatile u32 = @ptrFromInt(pa);
        self.head = slot.*;
        return pa;
    }
};

var fl: FreeList = .empty();
var heap_start: u32 = 0;

pub fn heapStart() u32 {
    return heap_start;
}

pub fn init() void {
    const end_addr: u32 = @intCast(@intFromPtr(&_end));
    heap_start = alignForward(end_addr);

    // Walk the heap region in descending order so `pop` returns the
    // lowest-PA page first.
    var pa: u32 = (RAM_END - PAGE_SIZE);
    while (pa >= heap_start) : (pa -%= PAGE_SIZE) {
        fl.pushPage(pa);
        if (pa == heap_start) break; // avoid wraparound below heap_start
    }
}

pub fn alloc() ?u32 {
    const pa = fl.pop() orelse return null;
    const slice: [*]volatile u8 = @ptrFromInt(pa);
    var i: u32 = 0;
    while (i < PAGE_SIZE) : (i += 1) slice[i] = 0;
    return pa;
}

pub fn free(pa: u32) void {
    // NOTE: double-free is NOT detected. If `pa` is already in the free
    // list this call creates a cycle, silently corrupting freeCount() and
    // causing alloc() to hand out the same page twice. The caller (e.g.
    // proc.free() in Task 4) must ensure `pa` is not already free.
    if ((pa & (PAGE_SIZE - 1)) != 0) {
        kprintf.panic("page_alloc.free: misaligned pa {x}", .{pa});
    }
    if (pa < heap_start or pa >= RAM_END) {
        kprintf.panic("page_alloc.free: pa {x} out of range", .{pa});
    }
    fl.pushPage(pa);
}

pub fn freeCount() u32 {
    var n: u32 = 0;
    var p = fl.head;
    while (p != 0) {
        n += 1;
        const slot: *volatile u32 = @ptrFromInt(p);
        p = slot.*;
    }
    return n;
}

pub fn allocZeroPage() u32 {
    return alloc() orelse kprintf.panic("page_alloc: out of RAM", .{});
}

fn alignForward(x: u32) u32 {
    const mask: u32 = PAGE_SIZE - 1;
    return (x + mask) & ~mask;
}

test "free-list pop returns most-recently pushed page" {
    if (@import("builtin").os.tag != .freestanding) {
        const std = @import("std");
        var buf: [3 * PAGE_SIZE]u8 align(PAGE_SIZE) = undefined;
        var local = FreeList.empty();
        local.pushPage(@intFromPtr(&buf[0]));
        local.pushPage(@intFromPtr(&buf[PAGE_SIZE]));
        local.pushPage(@intFromPtr(&buf[2 * PAGE_SIZE]));
        try std.testing.expectEqual(@intFromPtr(&buf[2 * PAGE_SIZE]), local.pop().?);
        try std.testing.expectEqual(@intFromPtr(&buf[PAGE_SIZE]), local.pop().?);
        try std.testing.expectEqual(@intFromPtr(&buf[0]), local.pop().?);
        try std.testing.expectEqual(@as(?u32, null), local.pop());
    }
}
