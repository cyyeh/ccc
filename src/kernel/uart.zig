// src/kernel/uart.zig — kernel-side NS16550A UART helper.
//
// Phase 3.E adds the RX path. The emulator's uart.zig forwards THR
// stores straight to stdout (writeByte), and now also fills an RX FIFO
// from --input or stdin. PLIC source 10 fires whenever the FIFO is
// non-empty (level-triggered).

const console = @import("console.zig");

pub const UART_BASE: u32 = 0x1000_0000;
pub const UART_THR: u32 = UART_BASE + 0x0; // transmit hold (write)
pub const UART_RBR: u32 = UART_BASE + 0x0; // receive buffer (read)
pub const UART_LSR: u32 = UART_BASE + 0x5; // line status
pub const LSR_THRE: u8 = 1 << 5; // transmitter empty
pub const LSR_DR: u8 = 1 << 0; // data ready

pub fn writeByte(b: u8) void {
    const thr: *volatile u8 = @ptrFromInt(UART_THR);
    thr.* = b;
}

pub fn writeBytes(s: []const u8) void {
    for (s) |b| writeByte(b);
}

/// Read one byte from the RX FIFO. Returns null if the FIFO is empty.
pub fn readByte() ?u8 {
    const lsr: *const volatile u8 = @ptrFromInt(UART_LSR);
    if ((lsr.* & LSR_DR) == 0) return null;
    const rbr: *const volatile u8 = @ptrFromInt(UART_RBR);
    return rbr.*;
}

/// PLIC src 10 ISR. Drain the FIFO into the console line discipline.
/// MUST loop until the FIFO is empty — IRQ is level-triggered, so any
/// remaining bytes would re-enter us immediately.
pub fn isr() void {
    while (readByte()) |b| {
        console.feedByte(b);
    }
}
