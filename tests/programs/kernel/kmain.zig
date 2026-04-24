// tests/programs/kernel/kmain.zig — Phase 2 Plan 2.C kernel S-mode entry.
//
// Task 7 state: proves Sv32 paging works under a bare kernel. After the
// csrw satp + sfence.vma, every load/fetch/store walks the page table we
// just built. uart.writeBytes, the halt MMIO store, and the `wfi` spin
// all go through translation.
//
// No traps handled yet (stvec is not installed) — a page fault here
// would be fatal. Task 10 adds the trap plumbing.

const uart = @import("uart.zig");
const vm = @import("vm.zig");
const page_alloc = @import("page_alloc.zig");

const SATP_MODE_SV32: u32 = 1 << 31;

const HALT_MMIO: *volatile u8 = @ptrFromInt(0x00100000);

export fn kmain() callconv(.c) noreturn {
    page_alloc.init();
    const root_pa = vm.allocRoot();
    vm.mapKernelAndMmio(root_pa);

    const satp_val: u32 = SATP_MODE_SV32 | (root_pa >> 12);
    asm volatile (
        \\ csrw satp, %[satp]
        \\ sfence.vma zero, zero
        :
        : [satp] "r" (satp_val),
        : .{ .memory = true }
    );

    uart.writeBytes("ok\n");
    HALT_MMIO.* = 0;
    while (true) asm volatile ("wfi");
}
