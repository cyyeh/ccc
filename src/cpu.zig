const std = @import("std");

pub const Cpu = struct {
    regs: [32]u32,
    pc: u32,

    pub fn init() Cpu {
        return .{
            .regs = [_]u32{0} ** 32,
            .pc = 0,
        };
    }

    pub fn readReg(self: *const Cpu, idx: u5) u32 {
        if (idx == 0) return 0;
        return self.regs[idx];
    }

    pub fn writeReg(self: *Cpu, idx: u5, value: u32) void {
        if (idx == 0) return; // x0 hardwired to zero
        self.regs[idx] = value;
    }
};

test "x0 is hardwired to zero — write is a no-op" {
    var cpu = Cpu.init();
    cpu.writeReg(0, 0xDEADBEEF);
    try std.testing.expectEqual(@as(u32, 0), cpu.readReg(0));
}

test "writeReg/readReg round-trip for x1" {
    var cpu = Cpu.init();
    cpu.writeReg(1, 0xCAFEBABE);
    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), cpu.readReg(1));
}

test "all registers initialise to zero" {
    const cpu = Cpu.init();
    var i: u5 = 0;
    while (true) : (i += 1) {
        try std.testing.expectEqual(@as(u32, 0), cpu.readReg(i));
        if (i == 31) break;
    }
}
