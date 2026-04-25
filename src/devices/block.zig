const std = @import("std");

pub const BLOCK_BASE: u32 = 0x1000_1000;
pub const BLOCK_SIZE: u32 = 0x10;

pub const SECTOR_BYTES: u32 = 4096;
pub const NSECTORS: u32 = 1024; // 4 MB total disk

pub const BlockError = error{UnexpectedRegister};

pub const Status = enum(u32) {
    Ready    = 0,
    Busy     = 1,    // never produced in Phase 3.A
    Error    = 2,
    NoMedia  = 3,
};

pub const Cmd = enum(u32) {
    None  = 0,
    Read  = 1,
    Write = 2,
};

pub const Block = struct {
    sector: u32 = 0,
    buffer_pa: u32 = 0,
    status: u32 = @intFromEnum(Status.NoMedia),
    /// Raised by writeByte(CMD) when a transfer completes (or fails).
    /// Polled by cpu.step at the top of each cycle to assert PLIC src 1.
    pending_irq: bool = false,
    /// Optional host-file backing. When null, every CMD sets STATUS=NoMedia.
    disk_file: ?std.Io.File = null,

    pub fn init() Block {
        return .{};
    }

    pub fn readByte(self: *const Block, offset: u32) BlockError!u8 {
        return switch (offset) {
            0x0...0x3 => @truncate(self.sector >> @as(u5, @intCast((offset - 0x0) * 8))),
            0x4...0x7 => @truncate(self.buffer_pa >> @as(u5, @intCast((offset - 0x4) * 8))),
            0x8...0xB => 0,             // CMD reads as 0
            0xC...0xF => @truncate(self.status >> @as(u5, @intCast((offset - 0xC) * 8))),
            else => BlockError.UnexpectedRegister,
        };
    }

    pub fn writeByte(self: *Block, offset: u32, value: u8) BlockError!void {
        switch (offset) {
            0x0...0x3 => {
                const shift: u5 = @intCast((offset - 0x0) * 8);
                self.sector = (self.sector & ~(@as(u32, 0xFF) << shift)) | (@as(u32, value) << shift);
            },
            0x4...0x7 => {
                const shift: u5 = @intCast((offset - 0x4) * 8);
                self.buffer_pa = (self.buffer_pa & ~(@as(u32, 0xFF) << shift)) | (@as(u32, value) << shift);
            },
            0x8...0xB => {
                // CMD: in Task 10 we accept and drop. Tasks 11/12 will react.
            },
            0xC...0xF => {
                // STATUS: writes ignored.
            },
            else => return BlockError.UnexpectedRegister,
        }
    }
};

test "default status is NoMedia (no --disk)" {
    const b = Block.init();
    try std.testing.expectEqual(@as(u8, 3), try b.readByte(0xC));
}

test "SECTOR byte round-trip" {
    var b = Block.init();
    try b.writeByte(0x0, 0x12);
    try b.writeByte(0x1, 0x34);
    try b.writeByte(0x2, 0x56);
    try b.writeByte(0x3, 0x78);
    try std.testing.expectEqual(@as(u32, 0x78563412), b.sector);
    try std.testing.expectEqual(@as(u8, 0x12), try b.readByte(0x0));
    try std.testing.expectEqual(@as(u8, 0x78), try b.readByte(0x3));
}

test "BUFFER byte round-trip" {
    var b = Block.init();
    try b.writeByte(0x4, 0xAA);
    try b.writeByte(0x5, 0xBB);
    try b.writeByte(0x6, 0xCC);
    try b.writeByte(0x7, 0xDD);
    try std.testing.expectEqual(@as(u32, 0xDDCCBBAA), b.buffer_pa);
}

test "CMD read returns 0 (write-only)" {
    var b = Block.init();
    try b.writeByte(0x8, 0x01);
    try std.testing.expectEqual(@as(u8, 0), try b.readByte(0x8));
}

test "out-of-range offset returns UnexpectedRegister" {
    var b = Block.init();
    try std.testing.expectError(BlockError.UnexpectedRegister, b.readByte(0x10));
    try std.testing.expectError(BlockError.UnexpectedRegister, b.writeByte(0x10, 0));
}
