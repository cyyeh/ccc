const std = @import("std");
const cpu_mod = @import("cpu.zig");
const csr = @import("csr.zig");
const Cpu = cpu_mod.Cpu;
const PrivilegeMode = cpu_mod.PrivilegeMode;

/// Synchronous exception cause codes — spec §Privilege & trap model
/// and docs/references/riscv-traps.md §Common mcause values.
/// Interrupt causes (high bit set) aren't raised in Phase 1.
pub const Cause = enum(u32) {
    instr_addr_misaligned = 0,
    instr_access_fault = 1,
    illegal_instruction = 2,
    breakpoint = 3,
    load_addr_misaligned = 4,
    load_access_fault = 5,
    store_addr_misaligned = 6,
    store_access_fault = 7,
    ecall_from_u = 8,
    ecall_from_m = 11,
};

/// Take a synchronous trap. Implements spec §Trap entry:
///   1. mepc  ← cpu.pc (the trapping instruction's address)
///   2. mcause ← cause
///   3. mtval  ← tval (faulting address for memory traps; 0 otherwise;
///               the raw 32-bit instruction word for illegal-instruction)
///   4. mstatus.MPP  ← current privilege mode
///   5. mstatus.MPIE ← mstatus.MIE; mstatus.MIE ← 0
///   6. privilege ← M; pc ← mtvec.BASE (direct mode only in Phase 1)
/// Always clears cpu.reservation (trap handlers may run arbitrary code
/// that makes the LR/SC reservation meaningless).
pub fn enter(cause: Cause, tval: u32, cpu: *Cpu) void {
    cpu.csr.mepc = cpu.pc & csr.MEPC_ALIGN_MASK;
    cpu.csr.mcause = @intFromEnum(cause);
    cpu.csr.mtval = tval;

    // mstatus updates in one pass.
    var ms = cpu.csr.mstatus;
    // MPP ← current priv (clear first, then OR in the new value).
    ms &= ~csr.MSTATUS_MPP_MASK;
    ms |= (@as(u32, @intFromEnum(cpu.privilege)) << csr.MSTATUS_MPP_SHIFT) & csr.MSTATUS_MPP_MASK;
    // MPIE ← MIE, then MIE ← 0.
    if ((ms & csr.MSTATUS_MIE) != 0) {
        ms |= csr.MSTATUS_MPIE;
    } else {
        ms &= ~csr.MSTATUS_MPIE;
    }
    ms &= ~csr.MSTATUS_MIE;
    cpu.csr.mstatus = ms;

    cpu.privilege = .M;
    cpu.pc = cpu.csr.mtvec & csr.MTVEC_BASE_MASK;
    cpu.reservation = null;
}

/// Return from trap via mret. Implements spec §Trap exit:
///   1. pc ← mepc
///   2. privilege ← mstatus.MPP
///   3. mstatus.MIE ← mstatus.MPIE
///      mstatus.MPIE ← 1
///      mstatus.MPP ← U (least-privileged supported mode)
/// MPP values not supported by the implementation (0b01 = S, 0b10 = H)
/// are normalized to U, matching RISC-V WARL semantics.
pub fn exit_mret(cpu: *Cpu) void {
    cpu.pc = cpu.csr.mepc & csr.MEPC_ALIGN_MASK;

    const mpp_bits: u2 = @truncate((cpu.csr.mstatus & csr.MSTATUS_MPP_MASK) >> csr.MSTATUS_MPP_SHIFT);
    cpu.privilege = switch (mpp_bits) {
        0b00 => .U,
        0b11 => .M,
        else => .U, // unsupported modes read back as U
    };

    var ms = cpu.csr.mstatus;
    if ((ms & csr.MSTATUS_MPIE) != 0) {
        ms |= csr.MSTATUS_MIE;
    } else {
        ms &= ~csr.MSTATUS_MIE;
    }
    ms |= csr.MSTATUS_MPIE; // MPIE ← 1
    ms &= ~csr.MSTATUS_MPP_MASK; // MPP ← 0b00 (U)
    cpu.csr.mstatus = ms;
}

// --- tests ---

const Memory = @import("memory.zig").Memory;

test "enter sets mepc, mcause, mtval; jumps to mtvec; switches to M" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0100);
    cpu.privilege = .U;
    cpu.csr.mtvec = 0x8000_0400; // direct mode (MODE=00)
    cpu.csr.mstatus = csr.MSTATUS_MIE; // MIE=1, MPIE=0, MPP=00

    enter(.ecall_from_u, 0, &cpu);

    try std.testing.expectEqual(@as(u32, 0x8000_0100), cpu.csr.mepc);
    try std.testing.expectEqual(@intFromEnum(Cause.ecall_from_u), cpu.csr.mcause);
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.mtval);
    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0400), cpu.pc);
    try std.testing.expectEqual(@as(u32, csr.MSTATUS_MPIE), cpu.csr.mstatus & (csr.MSTATUS_MPP_MASK | csr.MSTATUS_MPIE | csr.MSTATUS_MIE));
}

test "enter masks mtvec MODE bits (direct mode only in Phase 1)" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0200);
    cpu.csr.mtvec = 0x8000_0403; // BASE=0x80000400, MODE=01 (vectored bits set)
    enter(.illegal_instruction, 0, &cpu);
    try std.testing.expectEqual(@as(u32, 0x8000_0400), cpu.pc);
}

test "enter from M-mode sets MPP=M" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0100);
    cpu.privilege = .M;
    enter(.illegal_instruction, 0xDEADBEEF, &cpu);
    const mpp_bits: u2 = @truncate((cpu.csr.mstatus & csr.MSTATUS_MPP_MASK) >> csr.MSTATUS_MPP_SHIFT);
    try std.testing.expectEqual(@as(u2, 0b11), mpp_bits);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), cpu.csr.mtval);
}

test "enter clears reservation (LR/SC invariant)" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0100);
    cpu.reservation = 0x8000_0500;
    enter(.illegal_instruction, 0, &cpu);
    try std.testing.expect(cpu.reservation == null);
}

test "exit_mret restores PC from mepc, privilege from MPP" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0400);
    cpu.privilege = .M;
    cpu.csr.mepc = 0x8000_0108;
    cpu.csr.mstatus = csr.MSTATUS_MPIE;

    exit_mret(&cpu);

    try std.testing.expectEqual(@as(u32, 0x8000_0108), cpu.pc);
    try std.testing.expectEqual(PrivilegeMode.U, cpu.privilege);
    try std.testing.expectEqual(
        csr.MSTATUS_MIE | csr.MSTATUS_MPIE,
        cpu.csr.mstatus & (csr.MSTATUS_MPP_MASK | csr.MSTATUS_MPIE | csr.MSTATUS_MIE),
    );
}

test "exit_mret with MPP=M restores M-mode" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0400);
    cpu.privilege = .M;
    cpu.csr.mepc = 0x8000_0500;
    cpu.csr.mstatus = csr.MSTATUS_MPP_MASK | csr.MSTATUS_MPIE;
    exit_mret(&cpu);
    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
}

test "exit_mret unsupported MPP (reserved_s) normalizes to U" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0400);
    cpu.privilege = .M;
    cpu.csr.mepc = 0x8000_0200;
    cpu.csr.mstatus = (@as(u32, 0b01) << csr.MSTATUS_MPP_SHIFT) | csr.MSTATUS_MPIE;
    exit_mret(&cpu);
    try std.testing.expectEqual(PrivilegeMode.U, cpu.privilege);
}
