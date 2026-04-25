const std = @import("std");

pub const CLINT_BASE: u32 = 0x0200_0000;
pub const CLINT_SIZE: u32 = 0x1_0000; // 64 KB, matches spec memory map

const OFF_MSIP: u32 = 0x0000;
const OFF_MTIMECMP: u32 = 0x4000;
const OFF_MTIME: u32 = 0xBFF8;

pub const ClintError = error{UnexpectedRegister};

pub const ClockSourceFn = *const fn () i128;

fn defaultClockSource() i128 {
    // Zig 0.16 removed `std.time.nanoTimestamp`; fall back to a direct
    // `clock_gettime(MONOTONIC, ...)` via libc. Any failure (unlikely on
    // supported hosts) collapses to 0 — mtime just freezes until the next
    // successful read.
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const sec: i128 = @intCast(ts.sec);
    const nsec: i128 = @intCast(ts.nsec);
    return sec * 1_000_000_000 + nsec;
}

pub const Clint = struct {
    msip: u32 = 0,
    mtimecmp: u64 = 0,
    clock_source: ClockSourceFn,
    /// Anchor for mtime: nanosecond timestamp taken at init. mtime advances
    /// relative to this anchor so the first read is ~0 rather than some
    /// enormous wall-clock value.
    epoch_ns: i128,

    pub fn init(clock_source: ClockSourceFn) Clint {
        return .{
            .clock_source = clock_source,
            .epoch_ns = clock_source(),
        };
    }

    pub fn initDefault() Clint {
        return init(&defaultClockSource);
    }

    /// Convert (now - epoch) nanoseconds to ticks at 10 MHz nominal
    /// (100 ns per tick → divide by 100).
    fn mtime(self: *const Clint) u64 {
        const now = self.clock_source();
        const delta = now - self.epoch_ns;
        if (delta < 0) return 0;
        const ticks: u128 = @intCast(@divTrunc(delta, 100));
        return @truncate(ticks);
    }

    /// Returns true when the CLINT's MTIP output line is asserted. Per Phase 2
    /// spec §Devices: `mip.MTIP` is raised when `mtime >= mtimecmp` AND
    /// `mtimecmp != 0`. The `mtimecmp != 0` guard avoids spurious MTIP before
    /// any software programs the timer (both registers start at 0, so without
    /// the guard `0 >= 0` would fire forever).
    pub fn isMtipPending(self: *const Clint) bool {
        if (self.mtimecmp == 0) return false;
        return self.mtime() >= self.mtimecmp;
    }

    pub fn readByte(self: *const Clint, offset: u32) ClintError!u8 {
        return switch (offset) {
            0x0000...0x0003 => blk: {
                const idx: u2 = @truncate(offset - OFF_MSIP);
                break :blk @truncate(self.msip >> (@as(u5, idx) * 8));
            },
            0x4000...0x4007 => blk: {
                const idx: u3 = @truncate(offset - OFF_MTIMECMP);
                break :blk @truncate(self.mtimecmp >> (@as(u6, idx) * 8));
            },
            0xBFF8...0xBFFF => blk: {
                const idx: u3 = @truncate(offset - OFF_MTIME);
                break :blk @truncate(self.mtime() >> (@as(u6, idx) * 8));
            },
            else => 0, // lenient: unmapped CLINT offsets read as zero
        };
    }

    pub fn writeByte(self: *Clint, offset: u32, value: u8) ClintError!void {
        switch (offset) {
            0x0000...0x0003 => {
                const idx: u2 = @truncate(offset - OFF_MSIP);
                const shift: u5 = @as(u5, idx) * 8;
                const mask: u32 = ~(@as(u32, 0xFF) << shift);
                self.msip = (self.msip & mask) | (@as(u32, value) << shift);
            },
            0x4000...0x4007 => {
                const idx: u3 = @truncate(offset - OFF_MTIMECMP);
                const shift: u6 = @as(u6, idx) * 8;
                const mask: u64 = ~(@as(u64, 0xFF) << shift);
                self.mtimecmp = (self.mtimecmp & mask) | (@as(u64, value) << shift);
            },
            0xBFF8...0xBFFF => {},
            else => {},
        }
    }
};

test "msip round-trips byte-wise" {
    var c = Clint.init(&zeroClock);
    try c.writeByte(0x0000, 0x12);
    try c.writeByte(0x0001, 0x34);
    try c.writeByte(0x0002, 0x56);
    try c.writeByte(0x0003, 0x78);
    try std.testing.expectEqual(@as(u8, 0x12), try c.readByte(0x0000));
    try std.testing.expectEqual(@as(u8, 0x34), try c.readByte(0x0001));
    try std.testing.expectEqual(@as(u8, 0x56), try c.readByte(0x0002));
    try std.testing.expectEqual(@as(u8, 0x78), try c.readByte(0x0003));
    try std.testing.expectEqual(@as(u32, 0x78563412), c.msip);
}

test "mtimecmp round-trips byte-wise (all 8 bytes)" {
    var c = Clint.init(&zeroClock);
    try c.writeByte(0x4000, 0x01);
    try c.writeByte(0x4001, 0x23);
    try c.writeByte(0x4002, 0x45);
    try c.writeByte(0x4003, 0x67);
    try c.writeByte(0x4004, 0x89);
    try c.writeByte(0x4005, 0xAB);
    try c.writeByte(0x4006, 0xCD);
    try c.writeByte(0x4007, 0xEF);
    try std.testing.expectEqual(@as(u64, 0xEFCDAB8967452301), c.mtimecmp);
}

test "mtime returns monotonic, anchored ticks (via fixture clock)" {
    fixture_clock_ns = 0;
    var c = Clint.init(&fixtureClock);
    try std.testing.expectEqual(@as(u8, 0), try c.readByte(0xBFF8));
    fixture_clock_ns = 1000;
    try std.testing.expectEqual(@as(u8, 10), try c.readByte(0xBFF8));
}

test "writing mtime is silently dropped (Phase 1)" {
    fixture_clock_ns = 0;
    var c = Clint.init(&fixtureClock);
    try c.writeByte(0xBFF8, 0xFF);
    fixture_clock_ns = 100;
    try std.testing.expectEqual(@as(u8, 1), try c.readByte(0xBFF8));
}

test "isMtipPending: returns false when mtimecmp is zero (Phase 2 guard)" {
    fixture_clock_ns = 1_000_000; // mtime = 10_000 ticks
    var c = Clint.init(&fixtureClock);
    // Default mtimecmp = 0 → spec says MTIP stays clear.
    try std.testing.expect(!c.isMtipPending());
}

test "isMtipPending: false when mtime < mtimecmp, true when mtime >= mtimecmp" {
    fixture_clock_ns = 0;
    var c = Clint.init(&fixtureClock);
    // Set mtimecmp = 100 ticks.
    try c.writeByte(0x4000, 100);
    try c.writeByte(0x4001, 0);
    try c.writeByte(0x4002, 0);
    try c.writeByte(0x4003, 0);
    try c.writeByte(0x4004, 0);
    try c.writeByte(0x4005, 0);
    try c.writeByte(0x4006, 0);
    try c.writeByte(0x4007, 0);
    // mtime = 0 → not pending.
    try std.testing.expect(!c.isMtipPending());
    // Advance clock: 100 ticks × 100 ns/tick = 10_000 ns → mtime = 100.
    fixture_clock_ns = 10_000;
    try std.testing.expect(c.isMtipPending());
    // Advance further: strictly > mtimecmp also pending.
    fixture_clock_ns = 20_000;
    try std.testing.expect(c.isMtipPending());
}

test "isMtipPending: becomes false again after mtimecmp is moved past mtime" {
    fixture_clock_ns = 0;
    var c = Clint.init(&fixtureClock);
    try c.writeByte(0x4000, 50);
    fixture_clock_ns = 10_000;   // mtime = 100 ticks > mtimecmp = 50
    try std.testing.expect(c.isMtipPending());
    // Reprogram mtimecmp to 200 — the standard "ack timer" move.
    try c.writeByte(0x4000, 200);
    try std.testing.expect(!c.isMtipPending());
}

// --- test fixtures (must be `pub` so other tests can use them) ---

pub var fixture_clock_ns: i128 = 0;

pub fn zeroClock() i128 {
    return 0;
}

pub fn fixtureClock() i128 {
    return fixture_clock_ns;
}
