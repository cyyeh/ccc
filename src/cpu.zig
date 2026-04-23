const std = @import("std");
const decoder = @import("decoder.zig");
const execute = @import("execute.zig");
const Memory = @import("memory.zig").Memory;
const MemoryError = @import("memory.zig").MemoryError;

pub const StepError = error{
    UnsupportedInstruction,
    IllegalInstruction,
    Halt,
    OutOfBounds,
    MisalignedAccess,
    UnexpectedRegister,
    WriteFailed,
};

pub const Cpu = struct {
    regs: [32]u32,
    pc: u32,
    memory: *Memory,

    pub fn init(memory: *Memory, entry: u32) Cpu {
        return .{
            .regs = [_]u32{0} ** 32,
            .pc = entry,
            .memory = memory,
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

    pub fn step(self: *Cpu) StepError!void {
        const word = self.memory.loadWord(self.pc) catch |e| return mapMemErr(e);
        const instr = decoder.decode(word);
        return execute.dispatch(instr, self) catch |e| @errorCast(e);
    }

    fn mapMemErr(e: MemoryError) StepError {
        return switch (e) {
            error.OutOfBounds => StepError.OutOfBounds,
            error.MisalignedAccess => StepError.MisalignedAccess,
            error.UnexpectedRegister => StepError.UnexpectedRegister,
            error.WriteFailed => StepError.WriteFailed,
            error.Halt => StepError.Halt,
        };
    }
};

test "x0 is hardwired to zero — write is a no-op" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    cpu.writeReg(0, 0xDEADBEEF);
    try std.testing.expectEqual(@as(u32, 0), cpu.readReg(0));
}

test "writeReg/readReg round-trip for x1" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    cpu.writeReg(1, 0xCAFEBABE);
    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), cpu.readReg(1));
}

test "all registers initialise to zero" {
    var dummy_mem: Memory = undefined;
    const cpu = Cpu.init(&dummy_mem, 0);
    var i: u5 = 0;
    while (true) : (i += 1) {
        try std.testing.expectEqual(@as(u32, 0), cpu.readReg(i));
        if (i == 31) break;
    }
}
