const std = @import("std");
const cpu_mod = @import("cpu.zig");
const decoder = @import("decoder.zig");
const csr_mod = @import("csr.zig");
const trap = @import("trap.zig");
const MemoryError = @import("memory.zig").MemoryError;

/// Map a memory error at a load site to the appropriate trap cause.
/// A Halt error is not a trap — it's the halt-MMIO signal and we
/// re-raise it so it propagates out of cpu.step to terminate the run.
fn loadTrapCause(e: MemoryError) !trap.Cause {
    return switch (e) {
        error.MisalignedAccess => trap.Cause.load_addr_misaligned,
        error.OutOfBounds, error.UnexpectedRegister, error.WriteFailed => trap.Cause.load_access_fault,
        error.Halt => error.Halt,
    };
}

fn storeTrapCause(e: MemoryError) !trap.Cause {
    return switch (e) {
        error.MisalignedAccess => trap.Cause.store_addr_misaligned,
        error.OutOfBounds, error.UnexpectedRegister, error.WriteFailed => trap.Cause.store_access_fault,
        error.Halt => error.Halt,
    };
}

pub const ExecuteError = error{
    Halt,
    FatalTrap,
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
            const target = cpu.pc +% @as(u32, @bitCast(instr.imm));
            // RV32 without C: instruction targets must be 4-byte aligned.
            // Trap on the JAL itself (mepc stays at pc), NOT on the target —
            // otherwise rd would already be written. riscv-tests rv32mi-ma_fetch
            // asserts `bnez t1, fail` right after a trapped JAL/JALR.
            if (target & 3 != 0) {
                trap.enter(.instr_addr_misaligned, target, cpu);
                return;
            }
            const link = cpu.pc +% 4;
            cpu.writeReg(instr.rd, link);
            cpu.pc = target;
        },
        .jalr => {
            const target = (cpu.readReg(instr.rs1) +% @as(u32, @bitCast(instr.imm))) & ~@as(u32, 1);
            if (target & 3 != 0) {
                trap.enter(.instr_addr_misaligned, target, cpu);
                return;
            }
            const link = cpu.pc +% 4;
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
                const target = cpu.pc +% @as(u32, @bitCast(instr.imm));
                if (target & 3 != 0) {
                    trap.enter(.instr_addr_misaligned, target, cpu);
                    return;
                }
                cpu.pc = target;
            } else {
                cpu.pc +%= 4;
            }
        },
        .lb, .lh, .lw, .lbu, .lhu => {
            const addr = cpu.readReg(instr.rs1) +% @as(u32, @bitCast(instr.imm));
            const value: u32 = switch (instr.op) {
                .lb => blk: {
                    const byte = cpu.memory.loadByte(addr) catch |e| {
                        const cause = loadTrapCause(e) catch return ExecuteError.Halt;
                        trap.enter(cause, addr, cpu);
                        return;
                    };
                    break :blk @bitCast(@as(i32, @as(i8, @bitCast(byte))));
                },
                .lbu => blk: {
                    const byte = cpu.memory.loadByte(addr) catch |e| {
                        const cause = loadTrapCause(e) catch return ExecuteError.Halt;
                        trap.enter(cause, addr, cpu);
                        return;
                    };
                    break :blk @as(u32, byte);
                },
                .lh => blk: {
                    const half = cpu.memory.loadHalfword(addr) catch |e| {
                        const cause = loadTrapCause(e) catch return ExecuteError.Halt;
                        trap.enter(cause, addr, cpu);
                        return;
                    };
                    break :blk @bitCast(@as(i32, @as(i16, @bitCast(half))));
                },
                .lhu => blk: {
                    const half = cpu.memory.loadHalfword(addr) catch |e| {
                        const cause = loadTrapCause(e) catch return ExecuteError.Halt;
                        trap.enter(cause, addr, cpu);
                        return;
                    };
                    break :blk @as(u32, half);
                },
                .lw => cpu.memory.loadWord(addr) catch |e| {
                    const cause = loadTrapCause(e) catch return ExecuteError.Halt;
                    trap.enter(cause, addr, cpu);
                    return;
                },
                else => unreachable,
            };
            cpu.writeReg(instr.rd, value);
            cpu.pc +%= 4;
        },
        .sb => {
            const addr = cpu.readReg(instr.rs1) +% @as(u32, @bitCast(instr.imm));
            const value: u8 = @truncate(cpu.readReg(instr.rs2));
            cpu.memory.storeByte(addr, value) catch |e| {
                const cause = storeTrapCause(e) catch return ExecuteError.Halt;
                trap.enter(cause, addr, cpu);
                return;
            };
            cpu.pc +%= 4;
        },
        .sh => {
            const addr = cpu.readReg(instr.rs1) +% @as(u32, @bitCast(instr.imm));
            const value: u16 = @truncate(cpu.readReg(instr.rs2));
            cpu.memory.storeHalfword(addr, value) catch |e| {
                const cause = storeTrapCause(e) catch return ExecuteError.Halt;
                trap.enter(cause, addr, cpu);
                return;
            };
            cpu.pc +%= 4;
        },
        .sw => {
            const addr = cpu.readReg(instr.rs1) +% @as(u32, @bitCast(instr.imm));
            cpu.memory.storeWord(addr, cpu.readReg(instr.rs2)) catch |e| {
                const cause = storeTrapCause(e) catch return ExecuteError.Halt;
                trap.enter(cause, addr, cpu);
                return;
            };
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
        .csrrw, .csrrs, .csrrc => {
            const rs1_val = cpu.readReg(instr.rs1);
            const do_read = (instr.op != .csrrw) or (instr.rd != 0);
            const do_write = (instr.op == .csrrw) or (instr.rs1 != 0);
            const old: u32 = if (do_read) blk: {
                break :blk csr_mod.csrRead(cpu, instr.csr) catch {
                    trap.enter(.illegal_instruction, instr.raw, cpu);
                    return;
                };
            } else 0;
            if (do_write) {
                const new: u32 = switch (instr.op) {
                    .csrrw => rs1_val,
                    .csrrs => old | rs1_val,
                    .csrrc => old & ~rs1_val,
                    else => unreachable,
                };
                csr_mod.csrWrite(cpu, instr.csr, new) catch {
                    trap.enter(.illegal_instruction, instr.raw, cpu);
                    return;
                };
            }
            if (instr.rd != 0) cpu.writeReg(instr.rd, old);
            cpu.pc +%= 4;
        },
        .csrrwi, .csrrsi, .csrrci => {
            // rs1 slot holds the 5-bit zero-extended uimm; not a register index.
            const uimm: u32 = instr.rs1;
            const do_read = (instr.op != .csrrwi) or (instr.rd != 0);
            const do_write = (instr.op == .csrrwi) or (uimm != 0);
            const old: u32 = if (do_read) blk: {
                break :blk csr_mod.csrRead(cpu, instr.csr) catch {
                    trap.enter(.illegal_instruction, instr.raw, cpu);
                    return;
                };
            } else 0;
            if (do_write) {
                const new: u32 = switch (instr.op) {
                    .csrrwi => uimm,
                    .csrrsi => old | uimm,
                    .csrrci => old & ~uimm,
                    else => unreachable,
                };
                csr_mod.csrWrite(cpu, instr.csr, new) catch {
                    trap.enter(.illegal_instruction, instr.raw, cpu);
                    return;
                };
            }
            if (instr.rd != 0) cpu.writeReg(instr.rd, old);
            cpu.pc +%= 4;
        },
        .ecall => {
            const cause: trap.Cause = switch (cpu.privilege) {
                .M => .ecall_from_m,
                .U => .ecall_from_u,
                else => .ecall_from_u, // reserved modes treated as U (shouldn't happen)
            };
            trap.enter(cause, 0, cpu);
        },
        .ebreak => {
            trap.enter(.breakpoint, 0, cpu);
        },
        .mret => {
            if (cpu.privilege != .M) {
                trap.enter(.illegal_instruction, instr.raw, cpu);
                return;
            }
            trap.exit_mret(cpu);
        },
        .wfi => {
            if (cpu.privilege != .M) {
                trap.enter(.illegal_instruction, instr.raw, cpu);
                return;
            }
            // Phase 1 has no interrupt sources; wfi is a no-op (advance PC).
            cpu.pc +%= 4;
        },
        .sret => {
            // Full sret execution is Task 11 (Plan 2.A). Until then, treat as
            // illegal so the opcode is covered in the exhaustive switch and any
            // accidental use is visible as a trap rather than a silent hang.
            trap.enter(.illegal_instruction, instr.raw, cpu);
        },
        .sfence_vma => {
            // Real sfence.vma behavior (TLB flush) is Task 12 (Plan 2.A).
            // Until then, trap illegal so the variant is covered in the
            // exhaustive switch and any accidental use is visible.
            trap.enter(.illegal_instruction, instr.raw, cpu);
        },
        .mul, .mulh, .mulhsu, .mulhu => {
            const a = cpu.readReg(instr.rs1);
            const b = cpu.readReg(instr.rs2);
            const result: u32 = switch (instr.op) {
                .mul => a *% b,
                .mulh => blk: {
                    const as: i64 = @as(i32, @bitCast(a));
                    const bs: i64 = @as(i32, @bitCast(b));
                    const prod: i64 = as * bs;
                    break :blk @truncate(@as(u64, @bitCast(prod)) >> 32);
                },
                .mulhu => blk: {
                    const au: u64 = a;
                    const bu: u64 = b;
                    const prod: u64 = au * bu;
                    break :blk @truncate(prod >> 32);
                },
                .mulhsu => blk: {
                    const as: i64 = @as(i32, @bitCast(a));
                    const bu: i64 = @intCast(b); // unsigned rs2, zero-extended
                    const prod: i64 = as * bu;
                    break :blk @truncate(@as(u64, @bitCast(prod)) >> 32);
                },
                else => unreachable,
            };
            cpu.writeReg(instr.rd, result);
            cpu.pc +%= 4;
        },
        .div, .divu, .rem, .remu => {
            const a = cpu.readReg(instr.rs1);
            const b = cpu.readReg(instr.rs2);
            const result: u32 = switch (instr.op) {
                .div => blk: {
                    if (b == 0) break :blk 0xFFFF_FFFF; // div-by-zero → -1
                    const as: i32 = @bitCast(a);
                    const bs: i32 = @bitCast(b);
                    if (as == std.math.minInt(i32) and bs == -1) break :blk a; // overflow → INT_MIN
                    break :blk @bitCast(@divTrunc(as, bs));
                },
                .divu => if (b == 0) @as(u32, 0xFFFF_FFFF) else a / b,
                .rem => blk: {
                    if (b == 0) break :blk a; // div-by-zero → dividend
                    const as: i32 = @bitCast(a);
                    const bs: i32 = @bitCast(b);
                    if (as == std.math.minInt(i32) and bs == -1) break :blk 0; // overflow → 0
                    break :blk @bitCast(@rem(as, bs));
                },
                .remu => if (b == 0) a else a % b,
                else => unreachable,
            };
            cpu.writeReg(instr.rd, result);
            cpu.pc +%= 4;
        },
        .fence_i => {
            // No I-cache to invalidate; single hart, fetch-from-memory every step.
            cpu.pc +%= 4;
        },
        .lr_w => {
            const addr = cpu.readReg(instr.rs1);
            if (addr & 3 != 0) {
                trap.enter(.load_addr_misaligned, addr, cpu);
                return;
            }
            const val = cpu.memory.loadWord(addr) catch |e| {
                const cause = loadTrapCause(e) catch return ExecuteError.Halt;
                trap.enter(cause, addr, cpu);
                return;
            };
            cpu.reservation = addr;
            cpu.writeReg(instr.rd, val);
            cpu.pc +%= 4;
        },
        .sc_w => {
            const addr = cpu.readReg(instr.rs1);
            if (addr & 3 != 0) {
                trap.enter(.store_addr_misaligned, addr, cpu);
                return;
            }
            const holds = (cpu.reservation != null and cpu.reservation.? == addr);
            if (holds) {
                cpu.memory.storeWord(addr, cpu.readReg(instr.rs2)) catch |e| {
                    cpu.reservation = null;
                    const cause = storeTrapCause(e) catch return ExecuteError.Halt;
                    trap.enter(cause, addr, cpu);
                    return;
                };
            }
            cpu.reservation = null;
            cpu.writeReg(instr.rd, if (holds) @as(u32, 0) else @as(u32, 1));
            cpu.pc +%= 4;
        },
        .amoswap_w, .amoadd_w, .amoxor_w, .amoand_w, .amoor_w,
        .amomin_w, .amomax_w, .amominu_w, .amomaxu_w => {
            const addr = cpu.readReg(instr.rs1);
            if (addr & 3 != 0) {
                trap.enter(.store_addr_misaligned, addr, cpu);
                return;
            }
            const old = cpu.memory.loadWord(addr) catch |e| {
                const cause = loadTrapCause(e) catch return ExecuteError.Halt;
                trap.enter(cause, addr, cpu);
                return;
            };
            const rs2_val = cpu.readReg(instr.rs2);
            const new: u32 = switch (instr.op) {
                .amoswap_w => rs2_val,
                .amoadd_w => old +% rs2_val,
                .amoxor_w => old ^ rs2_val,
                .amoand_w => old & rs2_val,
                .amoor_w => old | rs2_val,
                .amomin_w => if (@as(i32, @bitCast(old)) < @as(i32, @bitCast(rs2_val))) old else rs2_val,
                .amomax_w => if (@as(i32, @bitCast(old)) > @as(i32, @bitCast(rs2_val))) old else rs2_val,
                .amominu_w => if (old < rs2_val) old else rs2_val,
                .amomaxu_w => if (old > rs2_val) old else rs2_val,
                else => unreachable,
            };
            cpu.memory.storeWord(addr, new) catch |e| {
                const cause = storeTrapCause(e) catch return ExecuteError.Halt;
                trap.enter(cause, addr, cpu);
                return;
            };
            cpu.writeReg(instr.rd, old);
            cpu.pc +%= 4;
        },
        .illegal => {
            trap.enter(.illegal_instruction, instr.raw, cpu);
        },
    }
}

const halt_dev = @import("devices/halt.zig");
const uart_dev = @import("devices/uart.zig");
const clint_dev = @import("devices/clint.zig");
const mem_mod = @import("memory.zig");

// Test fixture: Uart holds `*std.Io.Writer` pointing into the rig's `aw`,
// so the rig MUST NOT be moved/copied after init. Fill-in-place pattern
// keeps addresses stable.
const Rig = struct {
    halt: halt_dev.Halt,
    uart: uart_dev.Uart,
    clint: clint_dev.Clint,
    aw: std.Io.Writer.Allocating,
    mem: mem_mod.Memory,
    cpu: cpu_mod.Cpu,

    fn init(self: *Rig, allocator: std.mem.Allocator, entry: u32) !void {
        self.halt = halt_dev.Halt.init();
        self.aw = .init(allocator);
        self.uart = uart_dev.Uart.init(&self.aw.writer);
        self.clint = clint_dev.Clint.init(&clint_dev.zeroClock);
        self.mem = try mem_mod.Memory.init(allocator, &self.halt, &self.uart, &self.clint, null, mem_mod.RAM_SIZE_DEFAULT);
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

test "ECALL from U-mode traps with mcause=8, mepc=PC" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE + 0x100);
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    try dispatch(.{ .op = .ecall, .raw = 0x73 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 8), rig.cpu.csr.mcause);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x100, rig.cpu.csr.mepc);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x200, rig.cpu.pc);
    try std.testing.expectEqual(@import("cpu.zig").PrivilegeMode.M, rig.cpu.privilege);
}

test "ECALL from M-mode traps with mcause=11" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.privilege = .M;
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    try dispatch(.{ .op = .ecall, .raw = 0x73 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 11), rig.cpu.csr.mcause);
}

test "EBREAK traps with mcause=3 (breakpoint)" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    try dispatch(.{ .op = .ebreak, .raw = 0x100073 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 3), rig.cpu.csr.mcause);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x200, rig.cpu.pc);
}

test "MUL: 6 * 7 = 42" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 6);
    rig.cpu.writeReg(2, 7);
    try dispatch(.{ .op = .mul, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 42), rig.cpu.readReg(3));
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.pc);
}

test "MUL: wraps on unsigned overflow (low 32 bits only)" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    // 0x10000 * 0x10000 = 0x100000000, low 32 bits = 0
    rig.cpu.writeReg(1, 0x10000);
    rig.cpu.writeReg(2, 0x10000);
    try dispatch(.{ .op = .mul, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.readReg(3));
}

test "MULH: high bits of signed × signed (negative × negative = positive)" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    // -1 * -1 = 1. High 32 bits of 1 (as 64-bit signed) = 0.
    rig.cpu.writeReg(1, 0xFFFF_FFFF); // -1
    rig.cpu.writeReg(2, 0xFFFF_FFFF); // -1
    try dispatch(.{ .op = .mulh, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.readReg(3));
}

test "MULH: high bits when result spans more than 32 bits" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    // 0x40000000 * 2 = 0x80000000 as i64 (= 2^31). High 32 bits = 0.
    // Try something bigger: 0x40000000 * 4 = 0x100000000. High = 1.
    rig.cpu.writeReg(1, 0x40000000);
    rig.cpu.writeReg(2, 4);
    try dispatch(.{ .op = .mulh, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 1), rig.cpu.readReg(3));
}

test "MULHU: high bits of unsigned × unsigned" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    // 0xFFFFFFFF * 0xFFFFFFFF = 0xFFFFFFFE_00000001. High = 0xFFFFFFFE.
    rig.cpu.writeReg(1, 0xFFFF_FFFF);
    rig.cpu.writeReg(2, 0xFFFF_FFFF);
    try dispatch(.{ .op = .mulhu, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFE), rig.cpu.readReg(3));
}

test "MULHSU: signed × unsigned, rs1 negative" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    // -1 (as i32) * 0xFFFFFFFF (as u32) = -0xFFFFFFFF (as i64) = 0xFFFFFFFF_00000001
    // High 32 bits = 0xFFFFFFFF.
    rig.cpu.writeReg(1, 0xFFFF_FFFF); // -1 signed
    rig.cpu.writeReg(2, 0xFFFF_FFFF); // 4294967295 unsigned
    try dispatch(.{ .op = .mulhsu, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), rig.cpu.readReg(3));
}

test "DIV: 42 / 6 = 7" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 42);
    rig.cpu.writeReg(2, 6);
    try dispatch(.{ .op = .div, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 7), rig.cpu.readReg(3));
}

test "DIV: signed truncation toward zero (-7 / 2 = -3, not -4)" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, @bitCast(@as(i32, -7)));
    rig.cpu.writeReg(2, 2);
    try dispatch(.{ .op = .div, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -3))), rig.cpu.readReg(3));
}

test "DIV: division by zero returns -1 (all ones)" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 42);
    rig.cpu.writeReg(2, 0);
    try dispatch(.{ .op = .div, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), rig.cpu.readReg(3));
}

test "DIV: signed overflow (INT_MIN / -1) returns INT_MIN" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0x8000_0000); // INT_MIN
    rig.cpu.writeReg(2, @bitCast(@as(i32, -1)));
    try dispatch(.{ .op = .div, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), rig.cpu.readReg(3));
}

test "DIVU: unsigned divide by zero returns all-ones" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 42);
    rig.cpu.writeReg(2, 0);
    try dispatch(.{ .op = .divu, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), rig.cpu.readReg(3));
}

test "DIVU: large unsigned divide" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0xFFFF_FFFE); // 4294967294
    rig.cpu.writeReg(2, 2);
    try dispatch(.{ .op = .divu, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x7FFF_FFFF), rig.cpu.readReg(3));
}

test "REM: 42 % 6 = 0" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 42);
    rig.cpu.writeReg(2, 6);
    try dispatch(.{ .op = .rem, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.readReg(3));
}

test "REM: result takes sign of dividend (-7 rem 2 = -1)" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, @bitCast(@as(i32, -7)));
    rig.cpu.writeReg(2, 2);
    try dispatch(.{ .op = .rem, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -1))), rig.cpu.readReg(3));
}

test "REM: division by zero returns dividend" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 42);
    rig.cpu.writeReg(2, 0);
    try dispatch(.{ .op = .rem, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 42), rig.cpu.readReg(3));
}

test "REM: signed overflow (INT_MIN rem -1) returns 0" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0x8000_0000); // INT_MIN
    rig.cpu.writeReg(2, @bitCast(@as(i32, -1)));
    try dispatch(.{ .op = .rem, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.readReg(3));
}

test "REMU: unsigned remainder by zero returns dividend" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 42);
    rig.cpu.writeReg(2, 0);
    try dispatch(.{ .op = .remu, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 42), rig.cpu.readReg(3));
}

test "FENCE.I is a no-op, advances PC by 4" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try dispatch(.{ .op = .fence_i }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.pc);
}

test "LR.W loads a word and records a reservation" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x80, 0xCAFEBABE);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x80);
    try dispatch(.{ .op = .lr_w, .rd = 2, .rs1 = 1 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), rig.cpu.readReg(2));
    try std.testing.expectEqual(@as(?u32, mem_mod.RAM_BASE + 0x80), rig.cpu.reservation);
}

test "SC.W succeeds when reservation matches, writes 0 to rd" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.reservation = mem_mod.RAM_BASE + 0x80;
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x80);
    rig.cpu.writeReg(2, 0xDEADBEEF);
    try dispatch(.{ .op = .sc_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.readReg(3)); // 0 = success
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x80));
    try std.testing.expect(rig.cpu.reservation == null); // cleared after SC.W
}

test "SC.W fails when no reservation is held, writes nonzero to rd" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.reservation = null;
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x80);
    rig.cpu.writeReg(2, 0xDEADBEEF);
    try dispatch(.{ .op = .sc_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expect(rig.cpu.readReg(3) != 0); // nonzero = failure
    // Memory must NOT be updated on SC.W failure.
    try std.testing.expectEqual(@as(u32, 0), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x80));
}

test "SC.W fails when reservation address doesn't match" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.reservation = mem_mod.RAM_BASE + 0x40; // reserved at 0x40
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x80); // writing to 0x80
    rig.cpu.writeReg(2, 0xDEADBEEF);
    try dispatch(.{ .op = .sc_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expect(rig.cpu.readReg(3) != 0);
    try std.testing.expect(rig.cpu.reservation == null); // cleared regardless
}

test "LR.W on misaligned address traps with cause=load_addr_misaligned" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x81); // misaligned
    try dispatch(.{ .op = .lr_w, .rd = 2, .rs1 = 1 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x200, rig.cpu.pc);
    try std.testing.expectEqual(
        @intFromEnum(@import("trap.zig").Cause.load_addr_misaligned),
        rig.cpu.csr.mcause,
    );
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x81, rig.cpu.csr.mtval);
}

test "SC.W on misaligned address traps with cause=store_addr_misaligned" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x81); // misaligned
    rig.cpu.writeReg(2, 0xDEADBEEF);
    try dispatch(.{ .op = .sc_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x200, rig.cpu.pc);
    try std.testing.expectEqual(
        @intFromEnum(@import("trap.zig").Cause.store_addr_misaligned),
        rig.cpu.csr.mcause,
    );
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x81, rig.cpu.csr.mtval);
}

test "AMOSWAP.W returns old value, stores rs2" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 0xAAAA);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x40);
    rig.cpu.writeReg(2, 0xBBBB);
    try dispatch(.{ .op = .amoswap_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xAAAA), rig.cpu.readReg(3));       // old
    try std.testing.expectEqual(@as(u32, 0xBBBB), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x40)); // new
}

test "AMOADD.W returns old value, stores (old + rs2) with wrap" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 10);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x40);
    rig.cpu.writeReg(2, 32);
    try dispatch(.{ .op = .amoadd_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 10), rig.cpu.readReg(3));
    try std.testing.expectEqual(@as(u32, 42), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x40));
}

test "AMOXOR.W: old XOR rs2" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 0x0F0F_0F0F);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x40);
    rig.cpu.writeReg(2, 0xFF00_FF00);
    try dispatch(.{ .op = .amoxor_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x0F0F_0F0F), rig.cpu.readReg(3));
    try std.testing.expectEqual(@as(u32, 0xF00F_F00F), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x40));
}

test "AMOAND.W: old AND rs2" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 0xFFFF_FFFF);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x40);
    rig.cpu.writeReg(2, 0x0000_FFFF);
    try dispatch(.{ .op = .amoand_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), rig.cpu.readReg(3));
    try std.testing.expectEqual(@as(u32, 0x0000_FFFF), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x40));
}

test "AMOOR.W: old OR rs2" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 0x0000_00FF);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x40);
    rig.cpu.writeReg(2, 0xFF00_0000);
    try dispatch(.{ .op = .amoor_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFF00_00FF), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x40));
}

test "AMOMIN.W signed: min(-1, 0) = -1" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 0xFFFF_FFFF); // -1 as i32
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x40);
    rig.cpu.writeReg(2, 0);
    try dispatch(.{ .op = .amomin_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), rig.cpu.readReg(3));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x40));
}

test "AMOMAX.W signed: max(-1, 0) = 0" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 0xFFFF_FFFF);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x40);
    rig.cpu.writeReg(2, 0);
    try dispatch(.{ .op = .amomax_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x40));
}

test "AMOMINU.W unsigned: min(0xFFFFFFFF, 0) = 0" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 0xFFFF_FFFF);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x40);
    rig.cpu.writeReg(2, 0);
    try dispatch(.{ .op = .amominu_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x40));
}

test "AMOMAXU.W unsigned: max(0xFFFFFFFF, 0) = 0xFFFFFFFF" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 0xFFFF_FFFF);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x40);
    rig.cpu.writeReg(2, 0);
    try dispatch(.{ .op = .amomaxu_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x40));
}

test "CSRRW swaps: rd gets old CSR, CSR gets rs1" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mtvec = 0xDEAD_BEE0;
    rig.cpu.writeReg(1, 0xCAFE_BABC);
    try dispatch(.{ .op = .csrrw, .rd = 2, .rs1 = 1, .csr = 0x305, .raw = 0 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEE0), rig.cpu.readReg(2));
    try std.testing.expectEqual(@as(u32, 0xCAFE_BABC), rig.cpu.csr.mtvec);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.pc);
}

test "CSRRW with rd=x0 suppresses CSR read (no trap on write-only CSRs)" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mtvec = 0x1111_1110;
    rig.cpu.writeReg(1, 0x2222_2220);
    try dispatch(.{ .op = .csrrw, .rd = 0, .rs1 = 1, .csr = 0x305, .raw = 0 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x2222_2220), rig.cpu.csr.mtvec);
}

test "CSRRS sets bits: new = old | rs1, rd = old" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mcause = 0xAAAA_AAAA;
    rig.cpu.writeReg(1, 0x5555_5555);
    try dispatch(.{ .op = .csrrs, .rd = 2, .rs1 = 1, .csr = 0x342, .raw = 0 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xAAAA_AAAA), rig.cpu.readReg(2));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), rig.cpu.csr.mcause);
}

test "CSRRS with rs1=x0 suppresses CSR write (read-only effect)" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mcause = 0xAAAA_AAAA;
    rig.cpu.writeReg(5, 0x1234_5678);
    try dispatch(.{ .op = .csrrs, .rd = 5, .rs1 = 0, .csr = 0x342, .raw = 0 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xAAAA_AAAA), rig.cpu.readReg(5));
    try std.testing.expectEqual(@as(u32, 0xAAAA_AAAA), rig.cpu.csr.mcause);
}

test "CSRRC clears bits: new = old & ~rs1, rd = old" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mtval = 0xFF00_FF00;
    rig.cpu.writeReg(1, 0x0F0F_0F0F);
    try dispatch(.{ .op = .csrrc, .rd = 2, .rs1 = 1, .csr = 0x343, .raw = 0 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFF00_FF00), rig.cpu.readReg(2));
    try std.testing.expectEqual(@as(u32, 0xF000_F000), rig.cpu.csr.mtval);
}

test "CSRRWI writes zero-extended uimm to CSR, rd gets old value" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mepc = 0x8000_1000;
    try dispatch(.{ .op = .csrrwi, .rd = 2, .rs1 = 0x1F, .csr = 0x341, .raw = 0 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x8000_1000), rig.cpu.readReg(2));
    // mepc forces 4-byte alignment on write → 31 & ~3 = 28 = 0x1C.
    try std.testing.expectEqual(@as(u32, 0x0000_001C), rig.cpu.csr.mepc);
}

test "CSRRSI with uimm=0 suppresses CSR write" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    // 0x0000_1880 = MPIE(bit7)=1, MPP(bits12:11)=0b11(M). SPP=0.
    rig.cpu.csr.mstatus_mpie = true;
    rig.cpu.csr.mstatus_mpp = 0b11;
    try dispatch(.{ .op = .csrrsi, .rd = 2, .rs1 = 0, .csr = 0x300, .raw = 0 }, &rig.cpu);
    // csrrsi with uimm=0 is a read-only CSR access — no write, rd gets old value.
    try std.testing.expectEqual(@as(u32, 0x0000_1880), rig.cpu.readReg(2));
    // mstatus unchanged after a no-write access.
    try std.testing.expectEqual(@as(u32, 0x0000_1880), try csr_mod.csrRead(&rig.cpu, csr_mod.CSR_MSTATUS));
}

test "CSRRCI with nonzero uimm clears bits" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mie = 0x0000_0FFF;
    try dispatch(.{ .op = .csrrci, .rd = 2, .rs1 = 0x0F, .csr = 0x304, .raw = 0 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x0000_0FFF), rig.cpu.readReg(2));
    try std.testing.expectEqual(@as(u32, 0x0000_0FF0), rig.cpu.csr.mie);
}

test "illegal opcode traps with cause=illegal_instruction, mtval=raw word" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    try dispatch(.{ .op = .illegal, .raw = 0xFFFFFFFF }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x200, rig.cpu.pc);
    try std.testing.expectEqual(
        @intFromEnum(@import("trap.zig").Cause.illegal_instruction),
        rig.cpu.csr.mcause,
    );
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), rig.cpu.csr.mtval);
}

test "U-mode CSR access traps with cause=illegal_instruction" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    try dispatch(
        .{ .op = .csrrw, .rd = 1, .rs1 = 2, .csr = 0x300, .raw = 0xDEADBEEF },
        &rig.cpu,
    );
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x200, rig.cpu.pc);
    try std.testing.expectEqual(
        @intFromEnum(@import("trap.zig").Cause.illegal_instruction),
        rig.cpu.csr.mcause,
    );
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), rig.cpu.csr.mtval);
}

test "AMO on misaligned address traps with cause=store_addr_misaligned" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x41); // misaligned
    rig.cpu.writeReg(2, 1);
    try dispatch(.{ .op = .amoadd_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x200, rig.cpu.pc);
    try std.testing.expectEqual(
        @intFromEnum(@import("trap.zig").Cause.store_addr_misaligned),
        rig.cpu.csr.mcause,
    );
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x41, rig.cpu.csr.mtval);
}

test "MRET in M-mode: PC←mepc, privilege←MPP, MIE←MPIE, MPIE←1, MPP←U" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE + 0x400);
    defer rig.deinit();
    rig.cpu.privilege = .M;
    rig.cpu.csr.mepc = mem_mod.RAM_BASE + 0x108;
    // Set up: MPP=U(0b00), MPIE=true, MIE=false.
    rig.cpu.csr.mstatus_mpp = @intFromEnum(cpu_mod.PrivilegeMode.U);
    rig.cpu.csr.mstatus_mpie = true;
    rig.cpu.csr.mstatus_mie = false;
    try dispatch(.{ .op = .mret, .raw = 0x30200073 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x108, rig.cpu.pc);
    try std.testing.expectEqual(cpu_mod.PrivilegeMode.U, rig.cpu.privilege);
    // After mret: MIE ← MPIE (was true), MPIE ← 1, MPP ← U.
    try std.testing.expect(rig.cpu.csr.mstatus_mie);
    try std.testing.expect(rig.cpu.csr.mstatus_mpie);
    try std.testing.expectEqual(@as(u2, 0b00), rig.cpu.csr.mstatus_mpp);
}

test "MRET in U-mode traps as illegal-instruction" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    try dispatch(.{ .op = .mret, .raw = 0x30200073 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x200, rig.cpu.pc);
    try std.testing.expectEqual(
        @intFromEnum(@import("trap.zig").Cause.illegal_instruction),
        rig.cpu.csr.mcause,
    );
}

test "WFI in M-mode is a no-op (advances PC by 4)" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.privilege = .M;
    try dispatch(.{ .op = .wfi, .raw = 0x10500073 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.pc);
}

test "WFI in U-mode traps as illegal-instruction" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    try dispatch(.{ .op = .wfi, .raw = 0x10500073 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x200, rig.cpu.pc);
    try std.testing.expectEqual(
        @intFromEnum(@import("trap.zig").Cause.illegal_instruction),
        rig.cpu.csr.mcause,
    );
}

test "halt-on-trap propagates FatalTrap from cpu.run" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.halt_on_trap = true;
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    try rig.mem.storeWord(mem_mod.RAM_BASE, 0xFFFFFFFF);
    try std.testing.expectError(@import("cpu.zig").StepError.FatalTrap, rig.cpu.run());
    try std.testing.expectEqual(
        @intFromEnum(@import("trap.zig").Cause.illegal_instruction),
        rig.cpu.csr.mcause,
    );
}
