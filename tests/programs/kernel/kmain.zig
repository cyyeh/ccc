// tests/programs/kernel/kmain.zig — Phase 2 Plan 2.C kernel S-mode entry.
//
// Task 2 state: proves the M->S drop works. Writes "ok\n" to the UART MMIO
// directly, then stores 0 to halt MMIO (emulator exits with code 0).
// Paging is disabled at this stage (satp == 0 == Bare), so raw PAs work.

const UART_THR: *volatile u8 = @ptrFromInt(0x10000000);
const HALT_MMIO: *volatile u8 = @ptrFromInt(0x00100000);

export fn kmain() callconv(.c) noreturn {
    UART_THR.* = 'o';
    UART_THR.* = 'k';
    UART_THR.* = '\n';
    HALT_MMIO.* = 0;
    // Unreachable: halt MMIO terminates the emulator on the store above.
    while (true) asm volatile ("wfi");
}
