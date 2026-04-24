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
    ecall_from_s = 9,
    ecall_from_m = 11,
    instr_page_fault = 12,
    load_page_fault = 13,
    store_page_fault = 15,
};

/// Spec-mandated interrupt priority order (RISC-V privileged spec §3.1.9).
/// Higher indices earlier in the array lose to lower indices. Used by
/// cpu.check_interrupt to pick which pending+enabled+deliverable bit wins.
/// Cause codes: MEI=11, MSI=3, MTI=7, SEI=9, SSI=1, STI=5.
pub const INTERRUPT_PRIORITY_ORDER = [_]u32{ 11, 3, 7, 9, 1, 5 };

/// Interrupt-cause bit 31 marker per RISC-V spec: scause/mcause have the
/// high bit set to 1 for async interrupts, 0 for synchronous exceptions.
pub const INTERRUPT_CAUSE_FLAG: u32 = 1 << 31;

/// Take a synchronous trap. Implements spec §Trap entry and §Exception
/// delegation (§3.1.8).
///
/// Routing:
///   if cpu.privilege != .M AND (medeleg >> cause_code) & 1 == 1
///     → target = S; write S-CSRs; privilege ← S; pc ← stvec.BASE
///   else
///     → target = M; write M-CSRs; privilege ← M; pc ← mtvec.BASE
///
/// Both paths:
///   - capture the trapping PC (mepc/sepc ← cpu.pc, 4-byte aligned)
///   - store cause and tval
///   - save previous interrupt-enable and previous privilege into the
///     target privilege's mstatus fields (MPP/MPIE/MIE for M,
///     SPP/SPIE/SIE for S)
///   - clear the target privilege's IE bit
///   - clear cpu.reservation (LR/SC invariant; trap handlers may run
///     arbitrary code)
///   - set cpu.trap_taken = true for the halt-on-trap check
pub fn enter(cause: Cause, tval: u32, cpu: *Cpu) void {
    const cause_code: u32 = @intFromEnum(cause);
    const delegated = (cpu.csr.medeleg >> @intCast(cause_code)) & 1 == 1;
    const target: PrivilegeMode = if (cpu.privilege != .M and delegated) .S else .M;

    switch (target) {
        .M => {
            cpu.csr.mepc = cpu.pc & csr.MEPC_ALIGN_MASK;
            cpu.csr.mcause = cause_code;
            cpu.csr.mtval = tval;
            cpu.csr.mstatus_mpp = @intFromEnum(cpu.privilege);
            cpu.csr.mstatus_mpie = cpu.csr.mstatus_mie;
            cpu.csr.mstatus_mie = false;
            cpu.privilege = .M;
            cpu.pc = cpu.csr.mtvec & csr.MTVEC_BASE_MASK;
        },
        .S => {
            cpu.csr.sepc = cpu.pc & csr.MEPC_ALIGN_MASK;
            cpu.csr.scause = cause_code;
            cpu.csr.stval = tval;
            // SPP is a 1-bit field: 1 = S, 0 = U. M cannot reach here
            // (target == .S requires cpu.privilege != .M).
            cpu.csr.mstatus_spp = if (cpu.privilege == .S) 1 else 0;
            cpu.csr.mstatus_spie = cpu.csr.mstatus_sie;
            cpu.csr.mstatus_sie = false;
            cpu.privilege = .S;
            cpu.pc = cpu.csr.stvec & csr.MTVEC_BASE_MASK;
        },
        else => unreachable, // U cannot be a trap target; reserved_h is CSR-clamped out
    }
    cpu.reservation = null;
    cpu.trap_taken = true;
}

/// Take an asynchronous interrupt. Mirrors `enter` but:
///   - `cause_code` is the bare interrupt cause (0..15); bit 31 is set
///     in the scause/mcause write.
///   - consults `mideleg` instead of `medeleg`.
///   - `mtval` / `stval` are always written 0 (interrupts have no fault
///     value in the RV32 privileged spec).
///   - emits a trace marker if `cpu.trace_writer` is set, BEFORE the
///     privilege switch so the marker reflects the pre-interrupt state.
///
/// The caller (cpu.check_interrupt) is expected to have already gated
/// on mstatus.MIE / mstatus.SIE per the current privilege mode; this
/// function does not re-check those bits.
pub fn enter_interrupt(cause_code: u32, cpu: *Cpu) void {
    const delegated = (cpu.csr.mideleg >> @intCast(cause_code)) & 1 == 1;
    const target: PrivilegeMode = if (cpu.privilege != .M and delegated) .S else .M;
    const cause_reg = INTERRUPT_CAUSE_FLAG | cause_code;
    const from_priv = cpu.privilege;

    if (cpu.trace_writer) |tw| {
        @import("trace.zig").formatInterruptMarker(tw, cause_code, from_priv, target) catch {};
    }

    switch (target) {
        .M => {
            cpu.csr.mepc = cpu.pc & csr.MEPC_ALIGN_MASK;
            cpu.csr.mcause = cause_reg;
            cpu.csr.mtval = 0;
            cpu.csr.mstatus_mpp = @intFromEnum(cpu.privilege);
            cpu.csr.mstatus_mpie = cpu.csr.mstatus_mie;
            cpu.csr.mstatus_mie = false;
            cpu.privilege = .M;
            cpu.pc = cpu.csr.mtvec & csr.MTVEC_BASE_MASK;
        },
        .S => {
            cpu.csr.sepc = cpu.pc & csr.MEPC_ALIGN_MASK;
            cpu.csr.scause = cause_reg;
            cpu.csr.stval = 0;
            cpu.csr.mstatus_spp = if (cpu.privilege == .S) 1 else 0;
            cpu.csr.mstatus_spie = cpu.csr.mstatus_sie;
            cpu.csr.mstatus_sie = false;
            cpu.privilege = .S;
            cpu.pc = cpu.csr.stvec & csr.MTVEC_BASE_MASK;
        },
        else => unreachable,
    }
    cpu.reservation = null;
    cpu.trap_taken = true;
}

/// Return from trap via mret. Implements spec §Trap exit:
///   1. pc ← mepc
///   2. privilege ← mstatus.MPP
///   3. mstatus.MIE ← mstatus.MPIE
///      mstatus.MPIE ← 1
///      mstatus.MPP ← U (0b00, least-privileged mode, after restoring caller)
/// MPP=0b10 (reserved H-mode) is clamped to 0b00 (U) at the csrWrite level,
/// so exit_mret never observes it. All other u2 values (U, S, M) map to
/// valid PrivilegeMode variants and are used directly via @enumFromInt.
pub fn exit_mret(cpu: *Cpu) void {
    cpu.pc = cpu.csr.mepc & csr.MEPC_ALIGN_MASK;

    // Restore privilege from MPP. The write path clamps 0b10 (reserved H) to
    // 0b00, so only U=0b00, S=0b01, M=0b11 reach here — all valid enum values.
    cpu.privilege = @enumFromInt(cpu.csr.mstatus_mpp);

    // MIE ← MPIE; MPIE ← 1; MPP ← U (0b00).
    cpu.csr.mstatus_mie = cpu.csr.mstatus_mpie;
    cpu.csr.mstatus_mpie = true;
    cpu.csr.mstatus_mpp = @intFromEnum(PrivilegeMode.U);
}

/// Return from trap via sret. Implements spec §Supervisor Trap Return:
///   1. pc       ← sepc
///   2. privilege ← if SPP==1 then S else U
///   3. mstatus.SIE  ← mstatus.SPIE
///      mstatus.SPIE ← 1
///      mstatus.SPP  ← 0 (U)
pub fn exit_sret(cpu: *Cpu) void {
    cpu.pc = cpu.csr.sepc;
    cpu.privilege = if (cpu.csr.mstatus_spp == 1) .S else .U;
    cpu.csr.mstatus_sie = cpu.csr.mstatus_spie;
    cpu.csr.mstatus_spie = true;
    cpu.csr.mstatus_spp = 0;
}

// --- tests ---

const Memory = @import("memory.zig").Memory;

test "enter sets mepc, mcause, mtval; jumps to mtvec; switches to M" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0100);
    cpu.privilege = .U;
    cpu.csr.mtvec = 0x8000_0400; // direct mode (MODE=00)
    cpu.csr.mstatus_mie = true; // MIE=1, MPIE=0, MPP=00

    enter(.ecall_from_u, 0, &cpu);

    try std.testing.expectEqual(@as(u32, 0x8000_0100), cpu.csr.mepc);
    try std.testing.expectEqual(@intFromEnum(Cause.ecall_from_u), cpu.csr.mcause);
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.mtval);
    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0400), cpu.pc);
    // After trap from U: MPP=U(0b00), MPIE=true (was MIE=true), MIE=false.
    try std.testing.expectEqual(@as(u2, 0b00), cpu.csr.mstatus_mpp); // MPP=U
    try std.testing.expect(cpu.csr.mstatus_mpie); // MPIE ← old MIE
    try std.testing.expect(!cpu.csr.mstatus_mie); // MIE cleared
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
    try std.testing.expectEqual(@as(u2, 0b11), cpu.csr.mstatus_mpp);
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
    // Set up: MPP=U(0b00), MPIE=true, MIE=false.
    cpu.csr.mstatus_mpp = @intFromEnum(PrivilegeMode.U);
    cpu.csr.mstatus_mpie = true;
    cpu.csr.mstatus_mie = false;

    exit_mret(&cpu);

    try std.testing.expectEqual(@as(u32, 0x8000_0108), cpu.pc);
    try std.testing.expectEqual(PrivilegeMode.U, cpu.privilege);
    // After mret: MIE ← old MPIE (true), MPIE ← 1, MPP ← U.
    try std.testing.expect(cpu.csr.mstatus_mie); // MIE ← MPIE (was true)
    try std.testing.expect(cpu.csr.mstatus_mpie); // MPIE ← 1
    try std.testing.expectEqual(@as(u2, 0b00), cpu.csr.mstatus_mpp); // MPP ← U
}

test "exit_mret with MPP=M restores M-mode" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0400);
    cpu.privilege = .M;
    cpu.csr.mepc = 0x8000_0500;
    cpu.csr.mstatus_mpp = @intFromEnum(PrivilegeMode.M); // MPP=0b11
    cpu.csr.mstatus_mpie = true;
    exit_mret(&cpu);
    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
}

test "exit_mret MPP=S (0b01) restores S-mode privilege" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0400);
    cpu.privilege = .M;
    cpu.csr.mepc = 0x8000_0200;
    cpu.csr.mstatus_mpp = @intFromEnum(PrivilegeMode.S); // MPP=0b01
    cpu.csr.mstatus_mpie = true;
    exit_mret(&cpu);
    // Phase 2.A: S-mode is now a valid PrivilegeMode, so MPP=S restores S.
    try std.testing.expectEqual(PrivilegeMode.S, cpu.privilege);
}

test "page-fault Cause enum values match spec" {
    try std.testing.expectEqual(@as(u32, 12), @intFromEnum(Cause.instr_page_fault));
    try std.testing.expectEqual(@as(u32, 13), @intFromEnum(Cause.load_page_fault));
    try std.testing.expectEqual(@as(u32, 15), @intFromEnum(Cause.store_page_fault));
}

test "ecall_from_s Cause has value 9" {
    try std.testing.expectEqual(@as(u32, 9), @intFromEnum(Cause.ecall_from_s));
}

test "trap.enter sets mcause and mtval for a load page fault" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8001_0000);
    cpu.privilege = .U;
    cpu.csr.mtvec = 0x8000_1000;
    cpu.csr.mstatus_mie = true;

    enter(.load_page_fault, 0xDEAD_BEEF, &cpu);

    try std.testing.expectEqual(@as(u32, 13), cpu.csr.mcause);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), cpu.csr.mtval);
    try std.testing.expectEqual(@as(u32, 0x8001_0000), cpu.csr.mepc);
    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
    try std.testing.expectEqual(@as(u2, @intFromEnum(PrivilegeMode.U)), cpu.csr.mstatus_mpp);
    try std.testing.expectEqual(true, cpu.csr.mstatus_mpie);
    try std.testing.expectEqual(false, cpu.csr.mstatus_mie);
    try std.testing.expectEqual(@as(u32, 0x8000_1000), cpu.pc);
}

test "enter from U with delegated cause routes to S (sepc, scause, stval, stvec)" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0100);
    cpu.privilege = .U;
    cpu.csr.mtvec = 0x8000_0400;
    cpu.csr.stvec = 0x8000_0500;
    cpu.csr.mstatus_sie = true;
    cpu.csr.medeleg = 1 << @intFromEnum(Cause.ecall_from_u); // bit 8

    enter(.ecall_from_u, 0, &cpu);

    // S-mode entry CSRs got written.
    try std.testing.expectEqual(@as(u32, 0x8000_0100), cpu.csr.sepc);
    try std.testing.expectEqual(@intFromEnum(Cause.ecall_from_u), cpu.csr.scause);
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.stval);
    // Privilege ← S, PC ← stvec.BASE (direct mode only).
    try std.testing.expectEqual(PrivilegeMode.S, cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0500), cpu.pc);
    // sstatus transition: SPP ← U (0), SPIE ← old SIE (true), SIE ← 0.
    try std.testing.expectEqual(@as(u1, 0), cpu.csr.mstatus_spp);
    try std.testing.expect(cpu.csr.mstatus_spie);
    try std.testing.expect(!cpu.csr.mstatus_sie);
    // M-mode CSRs untouched.
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.mepc);
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.mcause);
}

test "enter from S with delegated cause routes to S, SPP=S" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0200);
    cpu.privilege = .S;
    cpu.csr.stvec = 0x8000_0600;
    cpu.csr.medeleg = 1 << @intFromEnum(Cause.breakpoint); // bit 3
    cpu.csr.mstatus_sie = true;

    enter(.breakpoint, 0, &cpu);

    try std.testing.expectEqual(PrivilegeMode.S, cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0600), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x8000_0200), cpu.csr.sepc);
    // SPP ← S (coming from S).
    try std.testing.expectEqual(@as(u1, 1), cpu.csr.mstatus_spp);
    // sstatus side-effects on S-from-S entry mirror the U-from-U case:
    // SPIE ← old SIE (true), SIE cleared.
    try std.testing.expect(cpu.csr.mstatus_spie);
    try std.testing.expect(!cpu.csr.mstatus_sie);
    // scause carries the cause code (no bit 31 for sync traps).
    try std.testing.expectEqual(@intFromEnum(Cause.breakpoint), cpu.csr.scause);
}

test "enter from U without delegation routes to M (baseline)" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0100);
    cpu.privilege = .U;
    cpu.csr.mtvec = 0x8000_0400;
    cpu.csr.medeleg = 0; // nothing delegated

    enter(.ecall_from_u, 0, &cpu);

    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0400), cpu.pc);
    try std.testing.expectEqual(@intFromEnum(Cause.ecall_from_u), cpu.csr.mcause);
    // S-mode CSRs untouched.
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.scause);
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.sepc);
}

test "enter from M never delegates even if medeleg bit is set" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0300);
    cpu.privilege = .M;
    cpu.csr.mtvec = 0x8000_0700;
    cpu.csr.stvec = 0x8000_0800;
    cpu.csr.medeleg = 0xFFFF_FFFF;

    enter(.illegal_instruction, 0xDEAD_BEEF, &cpu);

    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0700), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), cpu.csr.mtval);
}

test "enter with delegation clears reservation and sets trap_taken" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0100);
    cpu.privilege = .U;
    cpu.reservation = 0x8000_0500;
    cpu.csr.medeleg = 1 << 8;

    enter(.ecall_from_u, 0, &cpu);

    try std.testing.expect(cpu.reservation == null);
    try std.testing.expect(cpu.trap_taken);
}

test "enter_interrupt from U, SSIP delegated, routes to S with interrupt flag" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0100);
    cpu.privilege = .U;
    cpu.csr.stvec = 0x8000_0500;
    cpu.csr.mideleg = 1 << 1; // delegate SSIP

    enter_interrupt(1, &cpu); // cause code 1 = supervisor software

    try std.testing.expectEqual(PrivilegeMode.S, cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0500), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x8000_0100), cpu.csr.sepc);
    try std.testing.expectEqual(@as(u32, 0x8000_0001), cpu.csr.scause); // bit 31 | 1
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.stval);
}

test "enter_interrupt from S, MTIP not delegated, routes to M" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0300);
    cpu.privilege = .S;
    cpu.csr.mtvec = 0x8000_0700;
    cpu.csr.mideleg = 0; // MTIP cannot be delegated anyway, but set to zero explicitly

    enter_interrupt(7, &cpu); // cause code 7 = machine timer

    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0700), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x8000_0007), cpu.csr.mcause); // bit 31 | 7
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.mtval);
    try std.testing.expectEqual(@as(u2, @intFromEnum(PrivilegeMode.S)), cpu.csr.mstatus_mpp);
}

test "enter_interrupt from M stays in M regardless of mideleg" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0400);
    cpu.privilege = .M;
    cpu.csr.mtvec = 0x8000_0800;
    cpu.csr.mideleg = (1 << 1) | (1 << 5) | (1 << 9); // all S-int delegated

    enter_interrupt(1, &cpu); // even though mideleg[1]=1, M never delegates

    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0800), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x8000_0001), cpu.csr.mcause);
}

test "INTERRUPT_PRIORITY_ORDER spans MEI MSI MTI SEI SSI STI in spec order" {
    try std.testing.expectEqual(@as(usize, 6), INTERRUPT_PRIORITY_ORDER.len);
    try std.testing.expectEqual(@as(u32, 11), INTERRUPT_PRIORITY_ORDER[0]); // MEI
    try std.testing.expectEqual(@as(u32, 3),  INTERRUPT_PRIORITY_ORDER[1]); // MSI
    try std.testing.expectEqual(@as(u32, 7),  INTERRUPT_PRIORITY_ORDER[2]); // MTI
    try std.testing.expectEqual(@as(u32, 9),  INTERRUPT_PRIORITY_ORDER[3]); // SEI
    try std.testing.expectEqual(@as(u32, 1),  INTERRUPT_PRIORITY_ORDER[4]); // SSI
    try std.testing.expectEqual(@as(u32, 5),  INTERRUPT_PRIORITY_ORDER[5]); // STI
}
