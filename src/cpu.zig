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

    pub fn run(self: *Cpu) StepError!void {
        while (true) {
            self.step() catch |err| switch (err) {
                error.Halt => return,
                else => return err,
            };
        }
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

test "Cpu.run halts cleanly when program writes to halt MMIO" {
    var halt = @import("devices/halt.zig").Halt.init();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var uart = @import("devices/uart.zig").Uart.init(&aw.writer);
    var mem = try Memory.init(std.testing.allocator, &halt, &uart);
    defer mem.deinit();

    // Hand-encoded program at RAM_BASE:
    //   lui   t0, 0x100        ; t0 = 0x00100000 (halt MMIO)
    //   sb    zero, 0(t0)      ; *t0 = 0 → halt
    const RAM_BASE = @import("memory.zig").RAM_BASE;
    try mem.storeWord(RAM_BASE, 0x001002B7); // lui t0, 0x100
    try mem.storeWord(RAM_BASE + 4, 0x00028023); // sb zero, 0(t0)

    var cpu = Cpu.init(&mem, RAM_BASE);
    try cpu.run();
    try std.testing.expectEqual(@as(?u8, 0), halt.exit_code);
}

test "Cpu.run propagates UnsupportedInstruction" {
    var halt = @import("devices/halt.zig").Halt.init();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var uart = @import("devices/uart.zig").Uart.init(&aw.writer);
    var mem = try Memory.init(std.testing.allocator, &halt, &uart);
    defer mem.deinit();

    const RAM_BASE = @import("memory.zig").RAM_BASE;
    try mem.storeWord(RAM_BASE, 0x00000073); // ECALL

    var cpu = Cpu.init(&mem, RAM_BASE);
    try std.testing.expectError(StepError.UnsupportedInstruction, cpu.run());
}
