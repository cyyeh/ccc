// src/kernel/uart.zig — kernel-side NS16550A UART helper.
//
// We only ever transmit; receive is not implemented in Phase 2. The
// emulator's uart.zig forwards THR stores straight to stdout, so
// writeByte is effectively a putchar.

pub const UART_THR: u32 = 0x10000000;

pub fn writeByte(b: u8) void {
    const thr: *volatile u8 = @ptrFromInt(UART_THR);
    thr.* = b;
}

pub fn writeBytes(s: []const u8) void {
    for (s) |b| writeByte(b);
}
