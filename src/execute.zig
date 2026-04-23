const std = @import("std");
const cpu_mod = @import("cpu.zig");
const decoder = @import("decoder.zig");

pub const ExecuteError = error{
    UnsupportedInstruction,
    IllegalInstruction,
    Halt,
    OutOfBounds,
    MisalignedAccess,
    UnexpectedRegister,
    WriteFailed,
};

pub fn dispatch(instr: decoder.Instruction, cpu: *cpu_mod.Cpu) ExecuteError!void {
    switch (instr.op) {
        .lui => {
            cpu.writeReg(instr.rd, @bitCast(instr.imm));
            cpu.pc +%= 4;
        },
        .auipc => {
            const result: u32 = cpu.pc +% @as(u32, @bitCast(instr.imm));
            cpu.writeReg(instr.rd, result);
            cpu.pc +%= 4;
        },
        .illegal => return ExecuteError.IllegalInstruction,
    }
}

const halt_dev = @import("devices/halt.zig");
const uart_dev = @import("devices/uart.zig");
const mem_mod = @import("memory.zig");

// Test fixture: Uart holds `*std.Io.Writer` pointing into the rig's `aw`,
// so the rig MUST NOT be moved/copied after init. Fill-in-place pattern
// keeps addresses stable.
const Rig = struct {
    halt: halt_dev.Halt,
    uart: uart_dev.Uart,
    aw: std.Io.Writer.Allocating,
    mem: mem_mod.Memory,
    cpu: cpu_mod.Cpu,

    fn init(self: *Rig, allocator: std.mem.Allocator, entry: u32) !void {
        self.halt = halt_dev.Halt.init();
        self.aw = .init(allocator);
        self.uart = uart_dev.Uart.init(&self.aw.writer);
        self.mem = try mem_mod.Memory.init(allocator, &self.halt, &self.uart);
        self.cpu = cpu_mod.Cpu.init(&self.mem, entry);
    }

    fn deinit(self: *Rig) void {
        self.mem.deinit();
        self.aw.deinit();
    }
};

test "LUI loads upper-20-bit immediate into rd, lower 12 bits zero" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try dispatch(.{ .op = .lui, .rd = 5, .imm = @as(i32, @bitCast(@as(u32, 0x1000_0000))) }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x1000_0000), rig.cpu.readReg(5));
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.pc);
}

test "AUIPC = pc + imm" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE + 0x100);
    defer rig.deinit();
    try dispatch(.{ .op = .auipc, .rd = 1, .imm = @as(i32, @bitCast(@as(u32, 0x8000_0000))) }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x100 +% 0x8000_0000, rig.cpu.readReg(1));
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x100 + 4, rig.cpu.pc);
}
