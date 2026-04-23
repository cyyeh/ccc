const std = @import("std");

pub const RAM_BASE: u32 = 0x8000_0000;
pub const RAM_SIZE: usize = 128 * 1024 * 1024; // 128 MB

pub const MemoryError = error{
    OutOfBounds,
    MisalignedAccess,
};

pub const Memory = struct {
    ram: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Memory {
        const ram = try allocator.alloc(u8, RAM_SIZE);
        @memset(ram, 0);
        return .{ .ram = ram, .allocator = allocator };
    }

    pub fn deinit(self: *Memory) void {
        self.allocator.free(self.ram);
    }

    fn ramOffset(addr: u32) MemoryError!usize {
        if (addr < RAM_BASE) return MemoryError.OutOfBounds;
        const offset = addr - RAM_BASE;
        if (offset >= RAM_SIZE) return MemoryError.OutOfBounds;
        return @as(usize, offset);
    }

    pub fn loadByte(self: *const Memory, addr: u32) MemoryError!u8 {
        const off = try ramOffset(addr);
        return self.ram[off];
    }

    pub fn loadHalfword(self: *const Memory, addr: u32) MemoryError!u16 {
        if (addr & 1 != 0) return MemoryError.MisalignedAccess;
        const off = try ramOffset(addr);
        if (off + 2 > RAM_SIZE) return MemoryError.OutOfBounds;
        return std.mem.readInt(u16, self.ram[off..][0..2], .little);
    }

    pub fn loadWord(self: *const Memory, addr: u32) MemoryError!u32 {
        if (addr & 3 != 0) return MemoryError.MisalignedAccess;
        const off = try ramOffset(addr);
        if (off + 4 > RAM_SIZE) return MemoryError.OutOfBounds;
        return std.mem.readInt(u32, self.ram[off..][0..4], .little);
    }

    pub fn storeByte(self: *Memory, addr: u32, value: u8) MemoryError!void {
        const off = try ramOffset(addr);
        self.ram[off] = value;
    }

    pub fn storeHalfword(self: *Memory, addr: u32, value: u16) MemoryError!void {
        if (addr & 1 != 0) return MemoryError.MisalignedAccess;
        const off = try ramOffset(addr);
        if (off + 2 > RAM_SIZE) return MemoryError.OutOfBounds;
        std.mem.writeInt(u16, self.ram[off..][0..2], value, .little);
    }

    pub fn storeWord(self: *Memory, addr: u32, value: u32) MemoryError!void {
        if (addr & 3 != 0) return MemoryError.MisalignedAccess;
        const off = try ramOffset(addr);
        if (off + 4 > RAM_SIZE) return MemoryError.OutOfBounds;
        std.mem.writeInt(u32, self.ram[off..][0..4], value, .little);
    }
};

test "store/load byte round-trips" {
    var mem = try Memory.init(std.testing.allocator);
    defer mem.deinit();
    try mem.storeByte(RAM_BASE + 100, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), try mem.loadByte(RAM_BASE + 100));
}

test "word store/load is little-endian" {
    var mem = try Memory.init(std.testing.allocator);
    defer mem.deinit();
    try mem.storeWord(RAM_BASE + 0, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u8, 0xEF), try mem.loadByte(RAM_BASE + 0));
    try std.testing.expectEqual(@as(u8, 0xBE), try mem.loadByte(RAM_BASE + 1));
    try std.testing.expectEqual(@as(u8, 0xAD), try mem.loadByte(RAM_BASE + 2));
    try std.testing.expectEqual(@as(u8, 0xDE), try mem.loadByte(RAM_BASE + 3));
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), try mem.loadWord(RAM_BASE + 0));
}

test "halfword store/load is little-endian" {
    var mem = try Memory.init(std.testing.allocator);
    defer mem.deinit();
    try mem.storeHalfword(RAM_BASE + 0, 0xBEEF);
    try std.testing.expectEqual(@as(u8, 0xEF), try mem.loadByte(RAM_BASE + 0));
    try std.testing.expectEqual(@as(u8, 0xBE), try mem.loadByte(RAM_BASE + 1));
    try std.testing.expectEqual(@as(u16, 0xBEEF), try mem.loadHalfword(RAM_BASE + 0));
}

test "out-of-RAM access returns OutOfBounds" {
    var mem = try Memory.init(std.testing.allocator);
    defer mem.deinit();
    try std.testing.expectError(MemoryError.OutOfBounds, mem.loadByte(0));
    try std.testing.expectError(MemoryError.OutOfBounds, mem.loadByte(0x9000_0000));
}

test "misaligned word load returns MisalignedAccess" {
    var mem = try Memory.init(std.testing.allocator);
    defer mem.deinit();
    try std.testing.expectError(MemoryError.MisalignedAccess, mem.loadWord(RAM_BASE + 1));
}
