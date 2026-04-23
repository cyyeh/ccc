const std = @import("std");

pub const UART_BASE: u32 = 0x1000_0000;
pub const UART_SIZE: u32 = 0x100;

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

    pub fn init(writer: *std.Io.Writer) Uart {
        return .{ .writer = writer };
    }

    pub fn readByte(self: *Uart, offset: u32) UartError!u8 {
        return switch (offset) {
            REG_RBR => 0, // input stubbed in Plan 1.A
            REG_IER => self.ier,
            REG_FCR => 0, // FCR/IIR: read returns 0
            REG_LCR => self.lcr,
            REG_MCR => self.mcr,
            REG_LSR => LSR_THRE | LSR_TEMT,
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
