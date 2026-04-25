const std = @import("std");
const plic_dev = @import("plic.zig");

pub const UART_BASE: u32 = 0x1000_0000;
pub const UART_SIZE: u32 = 0x100;

const RX_CAPACITY: u16 = 256;

// 16550 register offsets we care about.
const REG_THR: u32 = 0x00; // Transmit Holding Register (write)
const REG_RBR: u32 = 0x00; // Receive Buffer Register (read) — stubbed
const REG_IER: u32 = 0x01;
const REG_FCR: u32 = 0x02;
const REG_LCR: u32 = 0x03;
const REG_MCR: u32 = 0x04;
const REG_LSR: u32 = 0x05; // Line Status Register
const REG_MSR: u32 = 0x06;
const REG_SR: u32 = 0x07; // Scratch

const LSR_THRE: u8 = 0x20; // Transmit Holding Register Empty
const LSR_TEMT: u8 = 0x40; // Transmitter Empty

pub const UartError = error{
    UnexpectedRegister,
    WriteFailed,
};

pub const Uart = struct {
    writer: *std.Io.Writer,
    // Echo-back state for poke-and-peek registers.
    ier: u8 = 0,
    lcr: u8 = 0,
    mcr: u8 = 0,
    sr: u8 = 0,
    rx_buf: [RX_CAPACITY]u8 = [_]u8{0} ** RX_CAPACITY,
    rx_head: u16 = 0,
    rx_tail: u16 = 0,
    rx_count: u16 = 0,
    /// Set by main.zig after construction. Tests set it directly.
    plic: ?*plic_dev.Plic = null,

    pub fn init(writer: *std.Io.Writer) Uart {
        return .{ .writer = writer };
    }

    pub fn pushRx(self: *Uart, b: u8) bool {
        if (self.rx_count >= RX_CAPACITY) return false;
        const was_empty = self.rx_count == 0;
        self.rx_buf[self.rx_tail] = b;
        self.rx_tail = (self.rx_tail + 1) % RX_CAPACITY;
        self.rx_count += 1;
        if (was_empty) {
            if (self.plic) |p| p.assertSource(10);
        }
        return true;
    }

    pub fn rxLen(self: *const Uart) u16 {
        return self.rx_count;
    }

    fn popRx(self: *Uart) u8 {
        if (self.rx_count == 0) return 0;
        const b = self.rx_buf[self.rx_head];
        self.rx_head = (self.rx_head + 1) % RX_CAPACITY;
        self.rx_count -= 1;
        if (self.rx_count == 0) {
            if (self.plic) |p| p.deassertSource(10);
        }
        return b;
    }

    pub fn readByte(self: *Uart, offset: u32) UartError!u8 {
        return switch (offset) {
            REG_RBR => self.popRx(),
            REG_IER => self.ier,
            REG_FCR => 0, // FCR/IIR: read returns 0
            REG_LCR => self.lcr,
            REG_MCR => self.mcr,
            REG_LSR => blk: {
                var v: u8 = LSR_THRE | LSR_TEMT;
                if (self.rx_count > 0) v |= 0x01; // DR (Data Ready) bit
                break :blk v;
            },
            REG_MSR => 0,
            REG_SR => self.sr,
            else => UartError.UnexpectedRegister,
        };
    }

    pub fn writeByte(self: *Uart, offset: u32, value: u8) UartError!void {
        switch (offset) {
            REG_THR => {
                self.writer.writeByte(value) catch return UartError.WriteFailed;
            },
            REG_IER => self.ier = value,
            REG_FCR => {}, // accept, no-op
            REG_LCR => self.lcr = value,
            REG_MCR => self.mcr = value,
            REG_LSR => {}, // read-only on real hardware; ignore writes
            REG_MSR => {},
            REG_SR => self.sr = value,
            else => return UartError.UnexpectedRegister,
        }
    }
};

test "writing to THR sends byte to writer" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var uart = Uart.init(&aw.writer);
    try uart.writeByte(REG_THR, 'A');
    try uart.writeByte(REG_THR, 'B');
    try std.testing.expectEqualStrings("AB", aw.written());
}

test "LSR always reports ready" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var uart = Uart.init(&aw.writer);
    const lsr = try uart.readByte(REG_LSR);
    try std.testing.expectEqual(@as(u8, LSR_THRE | LSR_TEMT), lsr);
}

test "LCR/MCR/IER/SR round-trip" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var uart = Uart.init(&aw.writer);
    try uart.writeByte(REG_LCR, 0x83);
    try uart.writeByte(REG_MCR, 0x0B);
    try uart.writeByte(REG_IER, 0x05);
    try uart.writeByte(REG_SR, 0xAA);
    try std.testing.expectEqual(@as(u8, 0x83), try uart.readByte(REG_LCR));
    try std.testing.expectEqual(@as(u8, 0x0B), try uart.readByte(REG_MCR));
    try std.testing.expectEqual(@as(u8, 0x05), try uart.readByte(REG_IER));
    try std.testing.expectEqual(@as(u8, 0xAA), try uart.readByte(REG_SR));
}

test "RBR (read of THR offset) returns 0 (input stubbed)" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var uart = Uart.init(&aw.writer);
    try std.testing.expectEqual(@as(u8, 0), try uart.readByte(REG_RBR));
}

test "pushRx empty -> non-empty raises PLIC src 10" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var plic = @import("plic.zig").Plic.init();
    var uart = Uart.init(&aw.writer);
    uart.plic = &plic;
    _ = uart.pushRx(0x41);
    try std.testing.expect((plic.pending & (1 << 10)) != 0);
}

test "pushRx then RBR read returns the byte" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var plic = @import("plic.zig").Plic.init();
    var uart = Uart.init(&aw.writer);
    uart.plic = &plic;
    _ = uart.pushRx(0x41);
    try std.testing.expectEqual(@as(u8, 0x41), try uart.readByte(0x00));
}

test "draining FIFO via RBR clears PLIC src 10" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var plic = @import("plic.zig").Plic.init();
    var uart = Uart.init(&aw.writer);
    uart.plic = &plic;
    _ = uart.pushRx(0x41);
    _ = try uart.readByte(0x00);
    try std.testing.expectEqual(@as(u32, 0), plic.pending & (1 << 10));
}

test "LSR.DR (bit 0) reflects FIFO non-empty" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var plic = @import("plic.zig").Plic.init();
    var uart = Uart.init(&aw.writer);
    uart.plic = &plic;
    var lsr = try uart.readByte(0x05);
    try std.testing.expectEqual(@as(u8, 0), lsr & 0x01);
    _ = uart.pushRx(0x41);
    lsr = try uart.readByte(0x05);
    try std.testing.expectEqual(@as(u8, 0x01), lsr & 0x01);
    _ = try uart.readByte(0x00);
    lsr = try uart.readByte(0x05);
    try std.testing.expectEqual(@as(u8, 0), lsr & 0x01);
}

test "FIFO drops bytes when full (256 capacity)" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var plic = @import("plic.zig").Plic.init();
    var uart = Uart.init(&aw.writer);
    uart.plic = &plic;
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        try std.testing.expect(uart.pushRx(@truncate(i & 0xFF)));
    }
    try std.testing.expect(!uart.pushRx(0xFF)); // full → false
}

test "FIFO is FIFO (first in, first out)" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var plic = @import("plic.zig").Plic.init();
    var uart = Uart.init(&aw.writer);
    uart.plic = &plic;
    _ = uart.pushRx(0x10);
    _ = uart.pushRx(0x20);
    _ = uart.pushRx(0x30);
    try std.testing.expectEqual(@as(u8, 0x10), try uart.readByte(0x00));
    try std.testing.expectEqual(@as(u8, 0x20), try uart.readByte(0x00));
    try std.testing.expectEqual(@as(u8, 0x30), try uart.readByte(0x00));
}
