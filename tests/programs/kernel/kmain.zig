// tests/programs/kernel/kmain.zig — Phase 2 Plan 2.C kernel S-mode entry.
//
// Task 9 state: paging still works (from Task 7); `the_tf` is exported
// for trampoline.S to reach via `la`. kmain does not yet install stvec
// or jump into the trampoline — that happens in Tasks 13 and 17.

const std = @import("std");
const uart = @import("uart.zig");
const vm = @import("vm.zig");
const page_alloc = @import("page_alloc.zig");
const trap = @import("trap.zig");
const user_blob = @import("user_blob");

pub const USER_BLOB: []const u8 = user_blob.BLOB;

const SATP_MODE_SV32: u32 = 1 << 31;

const HALT_MMIO: *volatile u8 = @ptrFromInt(0x00100000);

// Exported so trampoline.S can reference via `la the_tf`. Initial zero
// values are placeholders; Task 17 fills them in before the first sret.
pub export var the_tf: trap.TrapFrame = std.mem.zeroes(trap.TrapFrame);

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
