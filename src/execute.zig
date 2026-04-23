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
        .jal => {
            const link = cpu.pc +% 4;
            const target = cpu.pc +% @as(u32, @bitCast(instr.imm));
            cpu.writeReg(instr.rd, link);
            cpu.pc = target;
        },
        .jalr => {
            const link = cpu.pc +% 4;
            const target = (cpu.readReg(instr.rs1) +% @as(u32, @bitCast(instr.imm))) & ~@as(u32, 1);
            cpu.writeReg(instr.rd, link);
            cpu.pc = target;
        },
        .beq, .bne, .blt, .bge, .bltu, .bgeu => {
            const a = cpu.readReg(instr.rs1);
            const b = cpu.readReg(instr.rs2);
            const taken = switch (instr.op) {
                .beq => a == b,
                .bne => a != b,
                .blt => @as(i32, @bitCast(a)) < @as(i32, @bitCast(b)),
                .bge => @as(i32, @bitCast(a)) >= @as(i32, @bitCast(b)),
                .bltu => a < b,
                .bgeu => a >= b,
                else => unreachable,
            };
            if (taken) {
                cpu.pc = cpu.pc +% @as(u32, @bitCast(instr.imm));
            } else {
                cpu.pc +%= 4;
            }
        },
        .lb, .lh, .lw, .lbu, .lhu => {
            const addr = cpu.readReg(instr.rs1) +% @as(u32, @bitCast(instr.imm));
            const value: u32 = switch (instr.op) {
                .lb => blk: {
                    const byte = cpu.memory.loadByte(addr) catch |e| return mapMemErr(e);
                    break :blk @bitCast(@as(i32, @as(i8, @bitCast(byte))));
                },
                .lbu => blk: {
                    const byte = cpu.memory.loadByte(addr) catch |e| return mapMemErr(e);
                    break :blk @as(u32, byte);
                },
                .lh => blk: {
                    const half = cpu.memory.loadHalfword(addr) catch |e| return mapMemErr(e);
                    break :blk @bitCast(@as(i32, @as(i16, @bitCast(half))));
                },
                .lhu => blk: {
                    const half = cpu.memory.loadHalfword(addr) catch |e| return mapMemErr(e);
                    break :blk @as(u32, half);
                },
                .lw => cpu.memory.loadWord(addr) catch |e| return mapMemErr(e),
                else => unreachable,
            };
            cpu.writeReg(instr.rd, value);
            cpu.pc +%= 4;
        },
        .sb => {
            const addr = cpu.readReg(instr.rs1) +% @as(u32, @bitCast(instr.imm));
            const value: u8 = @truncate(cpu.readReg(instr.rs2));
            cpu.memory.storeByte(addr, value) catch |e| return mapMemErr(e);
            cpu.pc +%= 4;
        },
        .sh => {
            const addr = cpu.readReg(instr.rs1) +% @as(u32, @bitCast(instr.imm));
            const value: u16 = @truncate(cpu.readReg(instr.rs2));
            cpu.memory.storeHalfword(addr, value) catch |e| return mapMemErr(e);
            cpu.pc +%= 4;
        },
        .sw => {
            const addr = cpu.readReg(instr.rs1) +% @as(u32, @bitCast(instr.imm));
            cpu.memory.storeWord(addr, cpu.readReg(instr.rs2)) catch |e| return mapMemErr(e);
            cpu.pc +%= 4;
        },
        .addi, .slti, .sltiu, .xori, .ori, .andi => {
            const a = cpu.readReg(instr.rs1);
            const imm_u: u32 = @bitCast(instr.imm);
            const result: u32 = switch (instr.op) {
                .addi => a +% imm_u,
                .slti => if (@as(i32, @bitCast(a)) < instr.imm) 1 else 0,
                .sltiu => if (a < imm_u) 1 else 0,
                .xori => a ^ imm_u,
                .ori => a | imm_u,
                .andi => a & imm_u,
                else => unreachable,
            };
            cpu.writeReg(instr.rd, result);
            cpu.pc +%= 4;
        },
        .slli, .srli, .srai => {
            const a = cpu.readReg(instr.rs1);
            const shamt: u5 = @intCast(instr.imm & 0x1F);
            const result: u32 = switch (instr.op) {
                .slli => a << shamt,
                .srli => a >> shamt,
                .srai => @bitCast(@as(i32, @bitCast(a)) >> shamt),
                else => unreachable,
            };
            cpu.writeReg(instr.rd, result);
            cpu.pc +%= 4;
        },
        .add, .sub, .sll, .slt, .sltu, .xor_, .srl, .sra, .or_, .and_ => {
            const a = cpu.readReg(instr.rs1);
            const b = cpu.readReg(instr.rs2);
            const shamt: u5 = @intCast(b & 0x1F);
            const result: u32 = switch (instr.op) {
                .add => a +% b,
                .sub => a -% b,
                .sll => a << shamt,
                .slt => if (@as(i32, @bitCast(a)) < @as(i32, @bitCast(b))) 1 else 0,
                .sltu => if (a < b) 1 else 0,
                .xor_ => a ^ b,
                .srl => a >> shamt,
                .sra => @bitCast(@as(i32, @bitCast(a)) >> shamt),
                .or_ => a | b,
                .and_ => a & b,
                else => unreachable,
            };
            cpu.writeReg(instr.rd, result);
            cpu.pc +%= 4;
        },
        .fence => {
            cpu.pc +%= 4;
        },
        .ecall, .ebreak => return ExecuteError.UnsupportedInstruction,
        .illegal => return ExecuteError.IllegalInstruction,
    }
}

fn mapMemErr(e: mem_mod.MemoryError) ExecuteError {
    return switch (e) {
        error.OutOfBounds => ExecuteError.OutOfBounds,
        error.MisalignedAccess => ExecuteError.MisalignedAccess,
        error.UnexpectedRegister => ExecuteError.UnexpectedRegister,
        error.WriteFailed => ExecuteError.WriteFailed,
        error.Halt => ExecuteError.Halt,
    };
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

test "JAL stores pc+4 in rd, jumps to pc+offset" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try dispatch(.{ .op = .jal, .rd = 1, .imm = 16 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.readReg(1));
    try std.testing.expectEqual(mem_mod.RAM_BASE + 16, rig.cpu.pc);
}

test "JAL with rd=x0 still jumps but discards link" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try dispatch(.{ .op = .jal, .rd = 0, .imm = -8 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.readReg(0));
    try std.testing.expectEqual(mem_mod.RAM_BASE -% 8, rig.cpu.pc);
}

test "JALR uses rs1+imm for target, clears low bit" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(2, mem_mod.RAM_BASE + 0x101); // odd target
    try dispatch(.{ .op = .jalr, .rd = 1, .rs1 = 2, .imm = 0 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.readReg(1));
    // RISC-V spec: PC = (rs1 + imm) & ~1
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x100, rig.cpu.pc);
}

test "BEQ taken: jumps when rs1 == rs2" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 42);
    rig.cpu.writeReg(2, 42);
    try dispatch(.{ .op = .beq, .rs1 = 1, .rs2 = 2, .imm = 12 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 12, rig.cpu.pc);
}

test "BEQ not-taken: pc += 4 when rs1 != rs2" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 42);
    rig.cpu.writeReg(2, 0);
    try dispatch(.{ .op = .beq, .rs1 = 1, .rs2 = 2, .imm = 12 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.pc);
}

test "BLT signed: -1 < 1" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, @bitCast(@as(i32, -1)));
    rig.cpu.writeReg(2, 1);
    try dispatch(.{ .op = .blt, .rs1 = 1, .rs2 = 2, .imm = 8 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 8, rig.cpu.pc);
}

test "BLTU unsigned: 0xFFFF_FFFF NOT < 1" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0xFFFF_FFFF);
    rig.cpu.writeReg(2, 1);
    try dispatch(.{ .op = .bltu, .rs1 = 1, .rs2 = 2, .imm = 8 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.pc);
}

test "LB sign-extends a negative byte" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeByte(mem_mod.RAM_BASE + 0x40, 0xFF); // -1 as i8
    rig.cpu.writeReg(1, mem_mod.RAM_BASE);
    try dispatch(.{ .op = .lb, .rd = 2, .rs1 = 1, .imm = 0x40 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), rig.cpu.readReg(2));
}

test "LBU zero-extends" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeByte(mem_mod.RAM_BASE + 0x40, 0xFF);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE);
    try dispatch(.{ .op = .lbu, .rd = 2, .rs1 = 1, .imm = 0x40 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x0000_00FF), rig.cpu.readReg(2));
}

test "LH sign-extends a negative halfword" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeHalfword(mem_mod.RAM_BASE + 0x40, 0x8000);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE);
    try dispatch(.{ .op = .lh, .rd = 2, .rs1 = 1, .imm = 0x40 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_8000), rig.cpu.readReg(2));
}

test "LW round-trip" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 0xDEAD_BEEF);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE);
    try dispatch(.{ .op = .lw, .rd = 2, .rs1 = 1, .imm = 0x40 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), rig.cpu.readReg(2));
}

test "SB stores low byte of rs2" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, mem_mod.RAM_BASE);
    rig.cpu.writeReg(2, 0xDEAD_BE12);
    try dispatch(.{ .op = .sb, .rs1 = 1, .rs2 = 2, .imm = 8 }, &rig.cpu);
    try std.testing.expectEqual(@as(u8, 0x12), try rig.mem.loadByte(mem_mod.RAM_BASE + 8));
}

test "SW stores full word" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, mem_mod.RAM_BASE);
    rig.cpu.writeReg(2, 0xCAFE_BABE);
    try dispatch(.{ .op = .sw, .rs1 = 1, .rs2 = 2, .imm = 0x10 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xCAFE_BABE), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x10));
}

test "SB to UART address forwards to writer" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0x1000_0000);
    rig.cpu.writeReg(2, 'A');
    try dispatch(.{ .op = .sb, .rs1 = 1, .rs2 = 2, .imm = 0 }, &rig.cpu);
    try std.testing.expectEqualStrings("A", rig.aw.written());
}

test "ADDI computes rs1 + imm with sign extension" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 100);
    try dispatch(.{ .op = .addi, .rd = 2, .rs1 = 1, .imm = -10 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 90), rig.cpu.readReg(2));
}

test "SLTI: signed comparison" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, @bitCast(@as(i32, -5)));
    try dispatch(.{ .op = .slti, .rd = 2, .rs1 = 1, .imm = 0 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 1), rig.cpu.readReg(2));
}

test "SLTIU: unsigned comparison treats imm as unsigned-extended" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 5);
    // imm = -1 → unsigned 0xFFFF_FFFF, so 5 < 0xFFFF_FFFF → 1
    try dispatch(.{ .op = .sltiu, .rd = 2, .rs1 = 1, .imm = -1 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 1), rig.cpu.readReg(2));
}

test "XORI / ORI / ANDI bitwise ops" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0xF0F0_F0F0);
    try dispatch(.{ .op = .xori, .rd = 2, .rs1 = 1, .imm = @bitCast(@as(u32, 0x0F0)) }, &rig.cpu);
    // 0xF0F0_F0F0 ^ 0x0000_00F0 (sign-extended from 0x0F0 = +240) = 0xF0F0_F000
    try std.testing.expectEqual(@as(u32, 0xF0F0_F000), rig.cpu.readReg(2));
}

test "SLLI shifts left by shamt" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 1);
    try dispatch(.{ .op = .slli, .rd = 2, .rs1 = 1, .imm = 4 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 16), rig.cpu.readReg(2));
}

test "SRAI: arithmetic right shift preserves sign" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0xFFFF_FFF0); // -16
    try dispatch(.{ .op = .srai, .rd = 2, .rs1 = 1, .imm = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFC), rig.cpu.readReg(2)); // -4
}

test "SRLI: logical right shift" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0xFFFF_FFF0);
    try dispatch(.{ .op = .srli, .rd = 2, .rs1 = 1, .imm = 4 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x0FFF_FFFF), rig.cpu.readReg(2));
}

test "ADD: rs1 + rs2 wraps mod 2^32" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0xFFFF_FFFF);
    rig.cpu.writeReg(2, 1);
    try dispatch(.{ .op = .add, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.readReg(3));
}

test "SUB: rs1 - rs2 wraps mod 2^32" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0);
    rig.cpu.writeReg(2, 1);
    try dispatch(.{ .op = .sub, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), rig.cpu.readReg(3));
}

test "SLL: shifts by low 5 bits of rs2 only" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 1);
    rig.cpu.writeReg(2, 0xFFFF_FFE0 | 4); // shift amount = 4 (low 5 bits)
    try dispatch(.{ .op = .sll, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 16), rig.cpu.readReg(3));
}

test "SRA: arithmetic right shift preserves sign" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0xFFFF_FFF0);
    rig.cpu.writeReg(2, 4);
    try dispatch(.{ .op = .sra, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), rig.cpu.readReg(3));
}

test "FENCE is a no-op that advances PC" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try dispatch(.{ .op = .fence }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.pc);
}

test "ECALL returns UnsupportedInstruction in Plan 1.A" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try std.testing.expectError(ExecuteError.UnsupportedInstruction, dispatch(.{ .op = .ecall }, &rig.cpu));
}

test "EBREAK returns UnsupportedInstruction in Plan 1.A" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try std.testing.expectError(ExecuteError.UnsupportedInstruction, dispatch(.{ .op = .ebreak }, &rig.cpu));
}
