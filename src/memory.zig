const std = @import("std");
const halt_dev = @import("devices/halt.zig");
const uart_dev = @import("devices/uart.zig");
const clint_dev = @import("devices/clint.zig");

pub const RAM_BASE: u32 = 0x8000_0000;
pub const RAM_SIZE_DEFAULT: usize = 128 * 1024 * 1024;

pub const MemoryError = error{
    OutOfBounds,
    MisalignedAccess,
    UnexpectedRegister,
    WriteFailed,
    Halt,
};

pub const Memory = struct {
    ram: []u8,
    halt: *halt_dev.Halt,
    uart: *uart_dev.Uart,
    clint: *clint_dev.Clint,
    /// If set, writes inside [tohost_addr, tohost_addr+8) terminate the run
    /// via `MemoryError.Halt`. Used by riscv-tests which signal pass/fail by
    /// writing to a `tohost` symbol.
    tohost_addr: ?u32,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        halt: *halt_dev.Halt,
        uart: *uart_dev.Uart,
        clint: *clint_dev.Clint,
        tohost_addr: ?u32,
        ram_size: usize,
    ) !Memory {
        const ram = try allocator.alloc(u8, ram_size);
        @memset(ram, 0);
        return .{
            .ram = ram,
            .halt = halt,
            .uart = uart,
            .clint = clint,
            .tohost_addr = tohost_addr,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Memory) void {
        self.allocator.free(self.ram);
    }

    fn ramOffset(self: *const Memory, addr: u32) MemoryError!usize {
        if (addr < RAM_BASE) return MemoryError.OutOfBounds;
        const offset = addr - RAM_BASE;
        if (offset >= self.ram.len) return MemoryError.OutOfBounds;
        return @as(usize, offset);
    }

    fn inRange(addr: u32, base: u32, size: u32) bool {
        return addr >= base and addr < base +% size;
    }

    fn inTohost(self: *const Memory, addr: u32) bool {
        const base = self.tohost_addr orelse return false;
        return addr >= base and addr < base +% 8;
    }

    pub fn loadByte(self: *Memory, addr: u32) MemoryError!u8 {
        if (inRange(addr, uart_dev.UART_BASE, uart_dev.UART_SIZE)) {
            return self.uart.readByte(addr - uart_dev.UART_BASE) catch |e| switch (e) {
                error.UnexpectedRegister => MemoryError.UnexpectedRegister,
                error.WriteFailed => MemoryError.WriteFailed,
            };
        }
        if (inRange(addr, halt_dev.HALT_BASE, halt_dev.HALT_SIZE)) {
            return 0;
        }
        if (inRange(addr, clint_dev.CLINT_BASE, clint_dev.CLINT_SIZE)) {
            return self.clint.readByte(addr - clint_dev.CLINT_BASE) catch |e| switch (e) {
                error.UnexpectedRegister => MemoryError.UnexpectedRegister,
            };
        }
        const off = try self.ramOffset(addr);
        return self.ram[off];
    }

    pub fn loadHalfword(self: *Memory, addr: u32) MemoryError!u16 {
        if (addr & 1 != 0) return MemoryError.MisalignedAccess;
        const lo = try self.loadByte(addr);
        const hi = try self.loadByte(addr + 1);
        return (@as(u16, hi) << 8) | @as(u16, lo);
    }

    pub fn loadWord(self: *Memory, addr: u32) MemoryError!u32 {
        if (addr & 3 != 0) return MemoryError.MisalignedAccess;
        // Fast path for RAM:
        if (addr >= RAM_BASE) {
            const off = try self.ramOffset(addr);
            if (off + 4 > self.ram.len) return MemoryError.OutOfBounds;
            return std.mem.readInt(u32, self.ram[off..][0..4], .little);
        }
        // Generic byte-by-byte path for MMIO:
        const b0 = try self.loadByte(addr);
        const b1 = try self.loadByte(addr + 1);
        const b2 = try self.loadByte(addr + 2);
        const b3 = try self.loadByte(addr + 3);
        return (@as(u32, b3) << 24) | (@as(u32, b2) << 16) |
            (@as(u32, b1) << 8) | @as(u32, b0);
    }

    pub fn storeByte(self: *Memory, addr: u32, value: u8) MemoryError!void {
        if (inRange(addr, uart_dev.UART_BASE, uart_dev.UART_SIZE)) {
            self.uart.writeByte(addr - uart_dev.UART_BASE, value) catch |e| switch (e) {
                error.UnexpectedRegister => return MemoryError.UnexpectedRegister,
                error.WriteFailed => return MemoryError.WriteFailed,
            };
            return;
        }
        if (inRange(addr, halt_dev.HALT_BASE, halt_dev.HALT_SIZE)) {
            self.halt.writeByte(addr - halt_dev.HALT_BASE, value) catch |e| switch (e) {
                error.Halt => return MemoryError.Halt,
            };
            return;
        }
        if (inRange(addr, clint_dev.CLINT_BASE, clint_dev.CLINT_SIZE)) {
            self.clint.writeByte(addr - clint_dev.CLINT_BASE, value) catch |e| switch (e) {
                error.UnexpectedRegister => return MemoryError.UnexpectedRegister,
            };
            return;
        }
        // tohost: any write inside the 8-byte region halts the run. We still
        // commit the byte to RAM so post-mortem inspection sees the value.
        if (self.inTohost(addr)) {
            const off = try self.ramOffset(addr);
            self.ram[off] = value;
            // Record the low byte of the first tohost write as exit code so
            // `halt.exit_code` reflects the riscv-tests pass/fail convention
            // (TESTNUM<<1 | 1; value 1 = pass, anything else = TESTNUM).
            if (self.halt.exit_code == null) {
                self.halt.exit_code = value;
            }
            return MemoryError.Halt;
        }
        const off = try self.ramOffset(addr);
        self.ram[off] = value;
    }

    pub fn storeHalfword(self: *Memory, addr: u32, value: u16) MemoryError!void {
        if (addr & 1 != 0) return MemoryError.MisalignedAccess;
        try self.storeByte(addr, @truncate(value));
        try self.storeByte(addr + 1, @truncate(value >> 8));
    }

    pub fn storeWord(self: *Memory, addr: u32, value: u32) MemoryError!void {
        if (addr & 3 != 0) return MemoryError.MisalignedAccess;
        if (addr >= RAM_BASE and !self.inTohost(addr)) {
            const off = try self.ramOffset(addr);
            if (off + 4 > self.ram.len) return MemoryError.OutOfBounds;
            std.mem.writeInt(u32, self.ram[off..][0..4], value, .little);
            return;
        }
        try self.storeByte(addr, @truncate(value));
        try self.storeByte(addr + 1, @truncate(value >> 8));
        try self.storeByte(addr + 2, @truncate(value >> 16));
        try self.storeByte(addr + 3, @truncate(value >> 24));
    }
};

// Test fixture: the Uart embeds `*std.Io.Writer` pointing into the rig's
// `aw` field, so the rig MUST NOT be moved/copied after init. We use a
// fill-in-place pattern (init takes `*TestRig`) to guarantee stable addresses.
const TestRig = struct {
    halt: halt_dev.Halt,
    uart: uart_dev.Uart,
    clint: clint_dev.Clint,
    aw: std.Io.Writer.Allocating,
    mem: Memory,

    fn init(self: *TestRig, allocator: std.mem.Allocator) !void {
        self.halt = halt_dev.Halt.init();
        self.aw = .init(allocator);
        self.uart = uart_dev.Uart.init(&self.aw.writer);
        self.clint = clint_dev.Clint.init(&clint_dev.fixtureClock);
        self.mem = try Memory.init(allocator, &self.halt, &self.uart, &self.clint, null, RAM_SIZE_DEFAULT);
    }

    fn deinit(self: *TestRig) void {
        self.mem.deinit();
        self.aw.deinit();
    }
};

test "RAM byte round-trip via routed Memory" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    try rig.mem.storeByte(RAM_BASE + 100, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), try rig.mem.loadByte(RAM_BASE + 100));
}

test "store to UART THR forwards to writer" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    try rig.mem.storeByte(uart_dev.UART_BASE, 'X');
    try rig.mem.storeByte(uart_dev.UART_BASE, 'Y');
    try std.testing.expectEqualStrings("XY", rig.aw.written());
}

test "store to halt MMIO returns error.Halt" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    try std.testing.expectError(MemoryError.Halt, rig.mem.storeByte(halt_dev.HALT_BASE, 7));
    try std.testing.expectEqual(@as(?u8, 7), rig.halt.exit_code);
}

test "word store/load is little-endian (in RAM)" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    try rig.mem.storeWord(RAM_BASE, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u8, 0xEF), try rig.mem.loadByte(RAM_BASE));
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), try rig.mem.loadWord(RAM_BASE));
}

test "out-of-RAM access (and not in any device range) returns OutOfBounds" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    try std.testing.expectError(MemoryError.OutOfBounds, rig.mem.loadByte(0x4000_0000));
}

test "misaligned word load returns MisalignedAccess" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    try std.testing.expectError(MemoryError.MisalignedAccess, rig.mem.loadWord(RAM_BASE + 1));
}

test "word load from CLINT mtime returns nonzero after clock advances" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    clint_dev.fixture_clock_ns = 0;
    rig.clint.epoch_ns = 0;
    clint_dev.fixture_clock_ns = 10_000; // 100 ticks
    const v = try rig.mem.loadWord(clint_dev.CLINT_BASE + 0xBFF8);
    try std.testing.expectEqual(@as(u32, 100), v);
}
