// tests/programs/kernel/page_alloc.zig — physical-page bump allocator.
//
// Phase 2 has one process and never frees pages; a bump is sufficient
// and deterministic. `next_pa` starts at the first 4KB boundary at or
// after `_end` (linker symbol = 4KB-aligned by linker.ld) and advances
// by PAGE_SIZE on every alloc. Every returned page is zeroed.
//
// Kernel is direct-mapped at 0x80000000+, so the physical address
// returned doubles as the virtual address for use during kernel walks.

pub const PAGE_SIZE: u32 = 4096;
pub const RAM_END: u32 = 0x8800_0000; // 128 MiB RAM ceiling; panic past this

// Linker symbol: first byte past all kernel sections (stack included).
extern const _end: u8;

var next_pa: u32 = 0;

pub fn init() void {
    const end_addr: u32 = @intCast(@intFromPtr(&_end));
    next_pa = alignForward(end_addr);
}

pub fn allocZeroPage() u32 {
    if (next_pa + PAGE_SIZE > RAM_END) {
        @import("kprintf.zig").panic(
            "page_alloc: out of RAM at {x}",
            .{next_pa},
        );
    }
    const pa = next_pa;
    next_pa += PAGE_SIZE;
    const slice: [*]volatile u8 = @ptrFromInt(pa);
    var i: u32 = 0;
    while (i < PAGE_SIZE) : (i += 1) slice[i] = 0;
    return pa;
}

/// Test/debug hook: current bump position.
pub fn heapPos() u32 {
    return next_pa;
}

fn alignForward(x: u32) u32 {
    const mask: u32 = PAGE_SIZE - 1;
    return (x + mask) & ~mask;
}
