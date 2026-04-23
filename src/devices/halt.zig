const std = @import("std");

pub const HALT_BASE: u32 = 0x0010_0000;
pub const HALT_SIZE: u32 = 8;

pub const HaltError = error{Halt};

pub const Halt = struct {
    exit_code: ?u8 = null,

    pub fn init() Halt {
        return .{};
    }

    pub fn writeByte(self: *Halt, offset: u32, value: u8) HaltError!void {
        _ = offset; // entire range maps to halt
        self.exit_code = value;
        return HaltError.Halt;
    }
};

test "writing any byte sets exit_code and returns error.Halt" {
    var halt = Halt.init();
    try std.testing.expectError(HaltError.Halt, halt.writeByte(0, 42));
    try std.testing.expectEqual(@as(?u8, 42), halt.exit_code);
}

test "exit_code is null before any write" {
    const halt = Halt.init();
    try std.testing.expectEqual(@as(?u8, null), halt.exit_code);
}
