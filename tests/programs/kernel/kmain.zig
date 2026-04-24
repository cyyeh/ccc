// tests/programs/kernel/kmain.zig — Phase 2 Plan 2.C kernel S-mode entry.
//
// Task 3 state: same observable behavior as Task 2 ("ok\n" + exit 0), but
// emitted via uart.writeBytes so the helper is exercised before Task 8
// adds Sv32 paging under it.

const uart = @import("uart.zig");

const HALT_MMIO: *volatile u8 = @ptrFromInt(0x00100000);

export fn kmain() callconv(.c) noreturn {
    uart.writeBytes("ok\n");
    HALT_MMIO.* = 0;
    while (true) asm volatile ("wfi");
}
