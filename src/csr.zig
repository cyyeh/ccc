const std = @import("std");
const cpu_mod = @import("cpu.zig");
const Cpu = cpu_mod.Cpu;
const PrivilegeMode = cpu_mod.PrivilegeMode;

// S-mode CSR addresses (Phase 2.A).
pub const CSR_SSTATUS    : u12 = 0x100;
pub const CSR_SIE        : u12 = 0x104;
pub const CSR_STVEC      : u12 = 0x105;
pub const CSR_SCOUNTEREN : u12 = 0x106;
pub const CSR_SSCRATCH   : u12 = 0x140;
pub const CSR_SEPC       : u12 = 0x141;
pub const CSR_SCAUSE     : u12 = 0x142;
pub const CSR_STVAL      : u12 = 0x143;
pub const CSR_SIP        : u12 = 0x144;
pub const CSR_SATP       : u12 = 0x180;

// satp field constants (RV32 Sv32).
// Bit 31: MODE — 0 = Bare (no translation), 1 = Sv32.
// Bits 30:22: ASID — WARL 0 in our implementation.
// Bits 21:0: PPN — physical page number of root page table.
pub const SATP_MODE_BARE : u32 = 0;
pub const SATP_MODE_SV32 : u32 = 1;
pub const SATP_MODE_MASK : u32 = 1 << 31;
pub const SATP_PPN_MASK  : u32 = (1 << 22) - 1;
// ASID bits 30:22 — WARL 0 in our implementation.

// sstatus visible/writable field mask (RV32).
// S-mode can see and modify: SIE (1), SPIE (5), SPP (8), SUM (18), MXR (19).
// UBE (6), VS/FS/XS (9-16), SD (31) are WARL-zero or read-only in our subset.
const SSTATUS_WRITABLE_MASK: u32 =
    (1 << 1)  |  // SIE
    (1 << 5)  |  // SPIE
    (1 << 8)  |  // SPP
    (1 << 18) |  // SUM
    (1 << 19);   // MXR
const SSTATUS_READ_MASK: u32 = SSTATUS_WRITABLE_MASK; // no read-only bits in our subset

// sie/sip masked-view constants.
// S-mode can see SSIE(1)/STIE(5)/SEIE(9) through sie and SSIP(1)/STIP(5)/SEIP(9) through sip.
// Writes to sip are limited to SSIP(1) only; STIP and SEIP are M/hardware-maintained.
const SIE_MASK       : u32 = (1 << 1) | (1 << 5) | (1 << 9); // SSIE | STIE | SEIE
const SIP_READ_MASK  : u32 = (1 << 1) | (1 << 5) | (1 << 9); // SSIP | STIP | SEIP reads
const SIP_WRITE_MASK : u32 = (1 << 1);                        // only SSIP writable from S

// Writable (software-visible) CSR addresses we implement in Phase 1.
pub const CSR_MSTATUS: u12 = 0x300;
pub const CSR_MISA: u12 = 0x301;
// medeleg / mideleg: M-mode exception/interrupt delegation to S-mode.
// Plan 2.B turns these into first-class WARL registers — see
// MEDELEG_WRITABLE / MIDELEG_WRITABLE for the set of persisted bits.
// Storage lives in cpu.csr.medeleg / cpu.csr.mideleg (cpu.zig).
pub const CSR_MEDELEG: u12 = 0x302;
pub const CSR_MIDELEG: u12 = 0x303;
pub const CSR_MIE: u12 = 0x304;
pub const CSR_MTVEC: u12 = 0x305;
pub const CSR_MCOUNTEREN: u12 = 0x306;
pub const CSR_MSCRATCH: u12 = 0x340;
pub const CSR_MEPC: u12 = 0x341;
pub const CSR_MCAUSE: u12 = 0x342;
pub const CSR_MTVAL: u12 = 0x343;
pub const CSR_MIP: u12 = 0x344;

// Read-only (hardwired) CSR addresses.
pub const CSR_MVENDORID: u12 = 0xF11;
pub const CSR_MARCHID: u12 = 0xF12;
pub const CSR_MIMPID: u12 = 0xF13;
pub const CSR_MHARTID: u12 = 0xF14;

// mstatus field bit positions (RV32 M-view). Storage is split into per-field
// booleans/integers in CsrFile; these constants are kept for compatibility
// with existing tests and trap.zig code that checks individual bits.
pub const MSTATUS_SIE: u32 = 1 << 1; // S Interrupt Enable
pub const MSTATUS_MIE: u32 = 1 << 3; // Machine Interrupt Enable
pub const MSTATUS_SPIE: u32 = 1 << 5; // Previous SIE
pub const MSTATUS_MPIE: u32 = 1 << 7; // Previous MIE (saved on trap entry)
pub const MSTATUS_SPP_SHIFT: u5 = 8; // Previous S privilege (1 bit)
pub const MSTATUS_SPP_MASK: u32 = @as(u32, 0x1) << MSTATUS_SPP_SHIFT;
pub const MSTATUS_MPP_SHIFT: u5 = 11; // Previous privilege (2 bits, 12:11)
pub const MSTATUS_MPP_MASK: u32 = @as(u32, 0b11) << MSTATUS_MPP_SHIFT;
pub const MSTATUS_MPRV: u32 = 1 << 17; // Modify PRiVilege
pub const MSTATUS_SUM: u32 = 1 << 18; // Supervisor User Memory access
pub const MSTATUS_MXR: u32 = 1 << 19; // Make eXecutable Readable
pub const MSTATUS_TVM: u32 = 1 << 20; // Trap Virtual Memory
pub const MSTATUS_TSR: u32 = 1 << 22; // Trap SRET
// All writable bits (Phase 2.A — excludes UIE bit 0, TW bit 21, SD bit 31).
pub const MSTATUS_WRITABLE: u32 =
    MSTATUS_SIE | MSTATUS_MIE | MSTATUS_SPIE | MSTATUS_MPIE |
    MSTATUS_SPP_MASK | MSTATUS_MPP_MASK |
    MSTATUS_MPRV | MSTATUS_SUM | MSTATUS_MXR | MSTATUS_TVM | MSTATUS_TSR;

// mtvec field bits. BASE is bits 31:2 (word-aligned); MODE is bits 1:0.
// Phase 1 only honors MODE=0 (direct); MODE=1 (vectored) is stored
// (writes aren't rejected) but trap.enter always jumps to BASE.
pub const MTVEC_MODE_MASK: u32 = 0b11;
pub const MTVEC_BASE_MASK: u32 = ~MTVEC_MODE_MASK;

// mepc is 4-byte aligned in Phase 1 (no compressed extension).
// The low two bits read-as-zero per spec.
pub const MEPC_ALIGN_MASK: u32 = ~@as(u32, 0b11);

// medeleg WARL mask — bits that correspond to delegatable synchronous
// exception causes in our Phase 2 subset. ECALL_FROM_S (bit 9) and
// ECALL_FROM_M (bit 11) are deliberately excluded: the Phase 2 spec
// routes these to M-mode with no delegation. Reserved bits (10, 14, 16+)
// are also excluded to keep the register deterministic.
// Access-fault bits (1 = inst, 5 = load, 7 = store/AMO) are spec-
// delegatable, but the Phase 2 boot shim never programs them and our
// emulator's memory model can't raise them (no unreadable RAM, no PMP).
// Excluded from the Phase 2 subset; revisit if a later phase needs them.
pub const MEDELEG_WRITABLE: u32 =
    (1 << 0)  | // inst addr misaligned
    (1 << 2)  | // illegal instruction
    (1 << 3)  | // breakpoint
    (1 << 4)  | // load addr misaligned
    (1 << 6)  | // store addr misaligned
    (1 << 8)  | // ECALL from U
    (1 << 12) | // inst page fault
    (1 << 13) | // load page fault
    (1 << 15);  // store/AMO page fault

// mideleg WARL mask — only S-level interrupt bits. M-level interrupts
// (MSIP=3, MTIP=7, MEIP=11) cannot be delegated (spec §3.1.9).
pub const MIDELEG_WRITABLE: u32 =
    (1 << 1) | // SSIP
    (1 << 5) | // STIP
    (1 << 9);  // SEIP

// misa value: MXL=01 (RV32), extensions A+I+M+S+U.
// Bit positions (from RISC-V spec misa chapter):
//   'A' = bit 0, 'I' = bit 8, 'M' = bit 12, 'S' = bit 18, 'U' = bit 20
//   MXL lives in the top 2 bits: 31:30.
// Numeric value: 0x40141101
pub const MISA_VALUE: u32 =
    (@as(u32, 0b01) << 30) | // MXL = RV32
    (@as(u32, 1) << 20) | // U
    (@as(u32, 1) << 18) | // S
    (@as(u32, 1) << 12) | // M
    (@as(u32, 1) << 8) | // I
    (@as(u32, 1) << 0); // A

pub const CsrError = error{IllegalInstruction};

/// Returns the minimum PrivilegeMode required to access a CSR.
/// RISC-V encodes this in address bits 9:8: 0b00=U, 0b01=S, 0b10=H (treated
/// as S here), 0b11=M.
fn requiredPriv(addr: u12) PrivilegeMode {
    const priv_bits: u2 = @intCast((addr >> 8) & 0x3);
    return switch (priv_bits) {
        0b00 => .U,
        0b01 => .S,
        0b10 => .S, // hypervisor — treat as S for our purposes
        0b11 => .M,
    };
}

/// Returns error.IllegalInstruction if `priv` is below the minimum required
/// to access `addr`.
fn checkAccess(addr: u12, priv: PrivilegeMode) CsrError!void {
    const need = requiredPriv(addr);
    const priv_rank = @intFromEnum(priv);
    const need_rank = @intFromEnum(need);
    if (priv_rank < need_rank) return CsrError.IllegalInstruction;
}

fn satpTvmCheck(cpu: *const Cpu) CsrError!void {
    if (cpu.privilege == .S and cpu.csr.mstatus_tvm) return CsrError.IllegalInstruction;
}

/// Inner read — no privilege check. Used by the sstatus alias arm to read
/// mstatus without re-triggering the privilege guard.
fn csrReadUnchecked(cpu: *const Cpu, addr: u12) CsrError!u32 {
    return switch (addr) {
        CSR_SSTATUS => (try csrReadUnchecked(cpu, CSR_MSTATUS)) & SSTATUS_READ_MASK,
        CSR_SIE => cpu.csr.mie & SIE_MASK,
        CSR_SIP => cpu.csr.mip & SIP_READ_MASK,
        CSR_SATP => blk: {
            try satpTvmCheck(cpu);
            break :blk cpu.csr.satp;
        },
        CSR_MSTATUS => blk: {
            var v: u32 = 0;
            if (cpu.csr.mstatus_sie) v |= 1 << 1;
            if (cpu.csr.mstatus_mie) v |= 1 << 3;
            if (cpu.csr.mstatus_spie) v |= 1 << 5;
            if (cpu.csr.mstatus_mpie) v |= 1 << 7;
            v |= @as(u32, cpu.csr.mstatus_spp) << 8;
            v |= @as(u32, cpu.csr.mstatus_mpp) << 11;
            if (cpu.csr.mstatus_mprv) v |= 1 << 17;
            if (cpu.csr.mstatus_sum) v |= 1 << 18;
            if (cpu.csr.mstatus_mxr) v |= 1 << 19;
            if (cpu.csr.mstatus_tvm) v |= 1 << 20;
            if (cpu.csr.mstatus_tsr) v |= 1 << 22;
            break :blk v;
        },
        CSR_MISA => MISA_VALUE,
        CSR_MEDELEG => cpu.csr.medeleg,
        CSR_MIDELEG => cpu.csr.mideleg,
        CSR_MIE => cpu.csr.mie,
        CSR_STVEC      => cpu.csr.stvec,
        CSR_SCOUNTEREN => cpu.csr.scounteren,
        CSR_SSCRATCH   => cpu.csr.sscratch,
        CSR_SEPC     => cpu.csr.sepc,
        CSR_SCAUSE   => cpu.csr.scause,
        CSR_STVAL    => cpu.csr.stval,
        CSR_MTVEC => cpu.csr.mtvec,
        CSR_MCOUNTEREN => cpu.csr.mcounteren,
        CSR_MSCRATCH => cpu.csr.mscratch,
        CSR_MEPC => cpu.csr.mepc & MEPC_ALIGN_MASK,
        CSR_MCAUSE => cpu.csr.mcause,
        CSR_MTVAL => cpu.csr.mtval,
        CSR_MIP => cpu.csr.mip,
        CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID => 0,
        else => CsrError.IllegalInstruction,
    };
}

/// Inner write — no privilege check. Used by the sstatus alias arm to write
/// mstatus without re-triggering the privilege guard.
fn csrWriteUnchecked(cpu: *Cpu, addr: u12, value: u32) CsrError!void {
    switch (addr) {
        CSR_SSTATUS => {
            const current = try csrReadUnchecked(cpu, CSR_MSTATUS);
            const merged  = (current & ~SSTATUS_WRITABLE_MASK) | (value & SSTATUS_WRITABLE_MASK);
            try csrWriteUnchecked(cpu, CSR_MSTATUS, merged);
        },
        CSR_SIE => cpu.csr.mie = (cpu.csr.mie & ~SIE_MASK) | (value & SIE_MASK),
        CSR_SIP => cpu.csr.mip = (cpu.csr.mip & ~SIP_WRITE_MASK) | (value & SIP_WRITE_MASK),
        CSR_SATP => {
            try satpTvmCheck(cpu);
            // MODE: accept 0 (Bare) or 1 (Sv32); anything else clamps to Bare.
            const mode_bit = value & SATP_MODE_MASK;
            const ppn      = value & SATP_PPN_MASK;
            // ASID bits 30:22 — WARL 0 in our implementation; silently dropped.
            cpu.csr.satp = mode_bit | ppn;
        },
        CSR_MSTATUS => {
            cpu.csr.mstatus_sie = (value & (1 << 1)) != 0;
            cpu.csr.mstatus_mie = (value & (1 << 3)) != 0;
            cpu.csr.mstatus_spie = (value & (1 << 5)) != 0;
            cpu.csr.mstatus_mpie = (value & (1 << 7)) != 0;
            cpu.csr.mstatus_spp = @intCast((value >> 8) & 0x1);
            // MPP is WARL: only U (0b00), S (0b01), and M (0b11) are valid.
            // The reserved H-mode value (0b10) is clamped to U (0b00).
            const mpp_raw: u2 = @intCast((value >> 11) & 0x3);
            cpu.csr.mstatus_mpp = if (mpp_raw == 0b10) 0 else mpp_raw;
            cpu.csr.mstatus_mprv = (value & (1 << 17)) != 0;
            cpu.csr.mstatus_sum = (value & (1 << 18)) != 0;
            cpu.csr.mstatus_mxr = (value & (1 << 19)) != 0;
            cpu.csr.mstatus_tvm = (value & (1 << 20)) != 0;
            cpu.csr.mstatus_tsr = (value & (1 << 22)) != 0;
        },
        // medeleg / mideleg: WARL — store only the bits Plan 2.B permits.
        // See MEDELEG_WRITABLE / MIDELEG_WRITABLE comments above for the
        // rationale behind each included/excluded bit.
        CSR_MEDELEG => cpu.csr.medeleg = value & MEDELEG_WRITABLE,
        CSR_MIDELEG => cpu.csr.mideleg = value & MIDELEG_WRITABLE,
        CSR_MIE => cpu.csr.mie = value,
        CSR_STVEC      => cpu.csr.stvec      = value,
        CSR_SCOUNTEREN => cpu.csr.scounteren = value,
        CSR_SSCRATCH   => cpu.csr.sscratch   = value,
        CSR_SEPC     => cpu.csr.sepc     = value,
        CSR_SCAUSE   => cpu.csr.scause   = value,
        CSR_STVAL    => cpu.csr.stval    = value,
        // mtvec.MODE is WARL; Phase 1 only supports direct (MODE=00). Force
        // the low two bits to 0 on write — the rv32mi-illegal test probes the
        // MODE bit to decide whether to busy-wait for a vectored interrupt,
        // and vectored support without interrupt delivery would deadlock it.
        CSR_MTVEC => cpu.csr.mtvec = value & MTVEC_BASE_MASK,
        CSR_MCOUNTEREN => cpu.csr.mcounteren = value,
        CSR_MSCRATCH => cpu.csr.mscratch = value,
        CSR_MEPC => cpu.csr.mepc = value & MEPC_ALIGN_MASK,
        CSR_MCAUSE => cpu.csr.mcause = value,
        CSR_MTVAL => cpu.csr.mtval = value,
        CSR_MIP => cpu.csr.mip = value,
        // Read-only / hardwired — accept writes silently (WARL behavior).
        CSR_MISA, CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID => {},
        else => return CsrError.IllegalInstruction,
    }
}

/// Read a CSR. Access is checked against the CSR's minimum privilege level
/// encoded in address bits 9:8. Unknown addresses also trap.
pub fn csrRead(cpu: *const Cpu, addr: u12) CsrError!u32 {
    try checkAccess(addr, cpu.privilege);
    return csrReadUnchecked(cpu, addr);
}

/// Write a CSR. Access is checked against the CSR's minimum privilege level
/// encoded in address bits 9:8. Read-only CSRs silently drop writes (WARL).
/// mstatus and mtvec honor field masks; mepc zeros the low two bits.
pub fn csrWrite(cpu: *Cpu, addr: u12, value: u32) CsrError!void {
    try checkAccess(addr, cpu.privilege);
    try csrWriteUnchecked(cpu, addr, value);
}

test "mstatus round-trips through writable mask" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    // Write all-ones; only writable bits should survive. MPP bits 12:11 = 0b11
    // (M-mode) — valid, not clamped. So the full MSTATUS_WRITABLE mask applies.
    try csrWrite(&cpu, CSR_MSTATUS, 0xFFFF_FFFF);
    try std.testing.expectEqual(MSTATUS_WRITABLE, try csrRead(&cpu, CSR_MSTATUS));
}

test "misa reads back constant RV32IMASU value" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try std.testing.expectEqual(MISA_VALUE, try csrRead(&cpu, CSR_MISA));
    // Writes to misa are silently dropped.
    try csrWrite(&cpu, CSR_MISA, 0);
    try std.testing.expectEqual(MISA_VALUE, try csrRead(&cpu, CSR_MISA));
}

test "mhartid/mvendorid/marchid/mimpid all read zero" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try std.testing.expectEqual(@as(u32, 0), try csrRead(&cpu, CSR_MHARTID));
    try std.testing.expectEqual(@as(u32, 0), try csrRead(&cpu, CSR_MVENDORID));
    try std.testing.expectEqual(@as(u32, 0), try csrRead(&cpu, CSR_MARCHID));
    try std.testing.expectEqual(@as(u32, 0), try csrRead(&cpu, CSR_MIMPID));
}

test "U-mode CSR read/write traps as illegal" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    cpu.privilege = .U;
    try std.testing.expectError(CsrError.IllegalInstruction, csrRead(&cpu, CSR_MSTATUS));
    try std.testing.expectError(CsrError.IllegalInstruction, csrWrite(&cpu, CSR_MSTATUS, 1));
}

test "unknown CSR address traps as illegal" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try std.testing.expectError(CsrError.IllegalInstruction, csrRead(&cpu, 0xABC));
    try std.testing.expectError(CsrError.IllegalInstruction, csrWrite(&cpu, 0xABC, 0));
}

test "mepc forces 4-byte alignment on read and write" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MEPC, 0x8000_1003); // unaligned low bits
    try std.testing.expectEqual(@as(u32, 0x8000_1000), try csrRead(&cpu, CSR_MEPC));
}

test "mstatus MPP of 0b10 (reserved H) normalizes to 00 (U) — WARL" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MSTATUS, @as(u32, 0b10) << MSTATUS_MPP_SHIFT);
    try std.testing.expectEqual(@as(u2, 0b00), cpu.csr.mstatus_mpp);
}

test "mstatus MPP of 0b01 (S) round-trips" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MSTATUS, @as(u32, 0b01) << MSTATUS_MPP_SHIFT);
    try std.testing.expectEqual(@as(u2, 0b01), cpu.csr.mstatus_mpp);
}

test "mstatus MPP of 11 (M) round-trips" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MSTATUS, @as(u32, 0b11) << MSTATUS_MPP_SHIFT);
    try std.testing.expectEqual(@as(u2, 0b11), cpu.csr.mstatus_mpp);
}

test "mtvec MODE bits forced to 0 on write — WARL, vectored unsupported" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MTVEC, 0x8000_0401); // BASE=0x80000400, MODE=01 (vectored)
    try std.testing.expectEqual(@as(u32, 0x8000_0400), try csrRead(&cpu, CSR_MTVEC));
}

test "mscratch round-trips full 32 bits" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MSCRATCH, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), try csrRead(&cpu, CSR_MSCRATCH));
}

test "mcause round-trips full 32 bits (interrupt high bit + cause)" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MCAUSE, 0x8000_0007);
    try std.testing.expectEqual(@as(u32, 0x8000_0007), try csrRead(&cpu, CSR_MCAUSE));
}

test "mstatus SIE bit is writable and readable" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MSTATUS, 1 << 1);
    try std.testing.expectEqual(@as(u32, 1 << 1), try csrRead(&cpu, CSR_MSTATUS) & (1 << 1));
}

test "mstatus SPIE bit is writable and readable" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MSTATUS, 1 << 5);
    try std.testing.expectEqual(@as(u32, 1 << 5), try csrRead(&cpu, CSR_MSTATUS) & (1 << 5));
}

test "mstatus SPP bit is writable and readable" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MSTATUS, 1 << 8);
    try std.testing.expectEqual(@as(u32, 1 << 8), try csrRead(&cpu, CSR_MSTATUS) & (1 << 8));
}

test "mstatus MPRV bit is writable and readable" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MSTATUS, 1 << 17);
    try std.testing.expectEqual(@as(u32, 1 << 17), try csrRead(&cpu, CSR_MSTATUS) & (1 << 17));
}

test "mstatus SUM bit is writable and readable" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MSTATUS, 1 << 18);
    try std.testing.expectEqual(@as(u32, 1 << 18), try csrRead(&cpu, CSR_MSTATUS) & (1 << 18));
}

test "mstatus MXR bit is writable and readable" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MSTATUS, 1 << 19);
    try std.testing.expectEqual(@as(u32, 1 << 19), try csrRead(&cpu, CSR_MSTATUS) & (1 << 19));
}

test "mstatus TVM bit is writable and readable" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MSTATUS, 1 << 20);
    try std.testing.expectEqual(@as(u32, 1 << 20), try csrRead(&cpu, CSR_MSTATUS) & (1 << 20));
}

test "mstatus TSR bit is writable and readable" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MSTATUS, 1 << 22);
    try std.testing.expectEqual(@as(u32, 1 << 22), try csrRead(&cpu, CSR_MSTATUS) & (1 << 22));
}

test "mstatus UIE and TW remain zero (WARL)" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MSTATUS, 0xFFFFFFFF);
    const v = try csrRead(&cpu, CSR_MSTATUS);
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 0)); // UIE
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 21)); // TW
}

test "misa encodes RV32 I+M+A+S+U" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    const v = try csrRead(&cpu, CSR_MISA);
    // MXL = 01 (RV32) in bits 31:30
    try std.testing.expectEqual(@as(u32, 0b01), (v >> 30) & 0x3);
    // extensions: I (bit 8), M (bit 12), A (bit 0), S (bit 18), U (bit 20)
    try std.testing.expect((v & (1 << 8))  != 0);   // I
    try std.testing.expect((v & (1 << 12)) != 0);   // M
    try std.testing.expect((v & (1 << 0))  != 0);   // A
    try std.testing.expect((v & (1 << 18)) != 0);   // S
    try std.testing.expect((v & (1 << 20)) != 0);   // U
}

test "stvec round-trip" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_STVEC, 0x8000_1000);
    try std.testing.expectEqual(@as(u32, 0x8000_1000), try csrRead(&cpu, CSR_STVEC));
}

test "sscratch round-trip" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_SSCRATCH, 0xdead_beef);
    try std.testing.expectEqual(@as(u32, 0xdead_beef), try csrRead(&cpu, CSR_SSCRATCH));
}

test "scounteren round-trip" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_SCOUNTEREN, 0x0000_0007);
    try std.testing.expectEqual(@as(u32, 0x0000_0007), try csrRead(&cpu, CSR_SCOUNTEREN));
}

test "sepc round-trip" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_SEPC, 0x1234_5678);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), try csrRead(&cpu, CSR_SEPC));
}

test "scause round-trip" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_SCAUSE, 0x8000_0005);
    try std.testing.expectEqual(@as(u32, 0x8000_0005), try csrRead(&cpu, CSR_SCAUSE));
}

test "stval round-trip" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_STVAL, 0x0001_0000);
    try std.testing.expectEqual(@as(u32, 0x0001_0000), try csrRead(&cpu, CSR_STVAL));
}

test "sstatus reads the S-visible subset of mstatus" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    // set a full bag of mstatus bits via the M-mode write path
    try csrWrite(&cpu, CSR_MSTATUS,
        (1 << 1)  | (1 << 3)  | (1 << 5)  | (1 << 7) |
        (1 << 8)  | (3 << 11) | (1 << 17) | (1 << 18) |
        (1 << 19) | (1 << 20) | (1 << 22));
    // read sstatus — should expose only the S-visible bits
    const s = try csrRead(&cpu, CSR_SSTATUS);
    const expected: u32 = (1 << 1) | (1 << 5) | (1 << 8) | (1 << 18) | (1 << 19);
    try std.testing.expectEqual(expected, s);
}

test "sstatus write affects only the writable bits of mstatus" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    // pre-populate mstatus with some M-only bits we expect to survive
    try csrWrite(&cpu, CSR_MSTATUS, (1 << 3) | (1 << 7) | (1 << 17) | (1 << 20) | (1 << 22));
    // write all-ones through sstatus
    try csrWrite(&cpu, CSR_SSTATUS, 0xFFFF_FFFF);
    const m = try csrRead(&cpu, CSR_MSTATUS);
    // M-only bits preserved
    try std.testing.expect((m & (1 << 3))  != 0); // MIE
    try std.testing.expect((m & (1 << 7))  != 0); // MPIE
    try std.testing.expect((m & (1 << 17)) != 0); // MPRV
    try std.testing.expect((m & (1 << 20)) != 0); // TVM
    try std.testing.expect((m & (1 << 22)) != 0); // TSR
    // S-writable bits set to 1
    try std.testing.expect((m & (1 << 1))  != 0); // SIE
    try std.testing.expect((m & (1 << 5))  != 0); // SPIE
    try std.testing.expect((m & (1 << 8))  != 0); // SPP
    try std.testing.expect((m & (1 << 18)) != 0); // SUM
    try std.testing.expect((m & (1 << 19)) != 0); // MXR
}

test "sie reads the S-visible bits of mie" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MIE,
        (1 << 1) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 9) | (1 << 11));
    const s = try csrRead(&cpu, CSR_SIE);
    try std.testing.expectEqual(@as(u32, (1 << 1) | (1 << 5) | (1 << 9)), s);
}

test "sie write merges into mie preserving M-only bits" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MIE, (1 << 3) | (1 << 7) | (1 << 11)); // M-only
    try csrWrite(&cpu, CSR_SIE, 0xFFFF_FFFF);
    const m = try csrRead(&cpu, CSR_MIE);
    try std.testing.expect((m & (1 << 3))  != 0); // MSIE
    try std.testing.expect((m & (1 << 7))  != 0); // MTIE
    try std.testing.expect((m & (1 << 11)) != 0); // MEIE
    try std.testing.expect((m & (1 << 1))  != 0); // SSIE
    try std.testing.expect((m & (1 << 5))  != 0); // STIE
    try std.testing.expect((m & (1 << 9))  != 0); // SEIE
}

test "sip reads SSIP/STIP/SEIP from mip" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MIP, (1 << 1) | (1 << 5) | (1 << 9));
    const s = try csrRead(&cpu, CSR_SIP);
    try std.testing.expectEqual(@as(u32, (1 << 1) | (1 << 5) | (1 << 9)), s);
}

test "sip writes only SSIP into mip" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MIP, (1 << 7) | (1 << 5)); // M-only + STIP
    try csrWrite(&cpu, CSR_SIP, 0xFFFF_FFFF);
    const m = try csrRead(&cpu, CSR_MIP);
    try std.testing.expect((m & (1 << 7)) != 0); // MTIP preserved
    try std.testing.expect((m & (1 << 5)) != 0); // STIP preserved (not S-writable via sip)
    try std.testing.expect((m & (1 << 1)) != 0); // SSIP set by sip write
    try std.testing.expect((m & (1 << 9)) == 0); // SEIP NOT set (not in sip write-mask)
}

test "satp accepts MODE=Bare" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_SATP, 0x0000_0000);
    try std.testing.expectEqual(@as(u32, 0), try csrRead(&cpu, CSR_SATP));
}

test "satp accepts MODE=Sv32 with PPN" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    const written: u32 = (1 << 31) | 0x1234; // MODE=Sv32, PPN=0x1234
    try csrWrite(&cpu, CSR_SATP, written);
    try std.testing.expectEqual(written, try csrRead(&cpu, CSR_SATP));
}

test "satp ASID bits are WARL 0" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    const attempt: u32 = (1 << 31) | (0x1FF << 22) | 0x5678;
    try csrWrite(&cpu, CSR_SATP, attempt);
    const v = try csrRead(&cpu, CSR_SATP);
    try std.testing.expectEqual(@as(u32, 0), (v >> 22) & 0x1FF);
    try std.testing.expect((v & (1 << 31)) != 0);
    try std.testing.expectEqual(@as(u32, 0x5678), v & SATP_PPN_MASK);
}

test "U-mode cannot read mstatus" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    cpu.privilege = .U;
    try std.testing.expectError(CsrError.IllegalInstruction, csrRead(&cpu, CSR_MSTATUS));
}

test "U-mode cannot read sstatus" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    cpu.privilege = .U;
    try std.testing.expectError(CsrError.IllegalInstruction, csrRead(&cpu, CSR_SSTATUS));
}

test "S-mode cannot read mstatus" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    cpu.privilege = .S;
    try std.testing.expectError(CsrError.IllegalInstruction, csrRead(&cpu, CSR_MSTATUS));
}

test "S-mode can read sstatus" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    cpu.privilege = .S;
    _ = try csrRead(&cpu, CSR_SSTATUS);
}

test "M-mode can read mstatus and sstatus" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    cpu.privilege = .M;
    _ = try csrRead(&cpu, CSR_MSTATUS);
    _ = try csrRead(&cpu, CSR_SSTATUS);
}

test "satp access from S-mode with TVM=1 is illegal" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    cpu.privilege = .S;
    cpu.csr.mstatus_tvm = true;
    try std.testing.expectError(CsrError.IllegalInstruction, csrRead(&cpu, CSR_SATP));
    try std.testing.expectError(CsrError.IllegalInstruction, csrWrite(&cpu, CSR_SATP, 0));
}

test "satp access from S-mode with TVM=0 succeeds" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    cpu.privilege = .S;
    cpu.csr.mstatus_tvm = false;
    _ = try csrRead(&cpu, CSR_SATP);
    try csrWrite(&cpu, CSR_SATP, (1 << 31) | 0x42);
}

test "satp access from M-mode ignores TVM" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    cpu.privilege = .M;
    cpu.csr.mstatus_tvm = true;
    try csrWrite(&cpu, CSR_SATP, (1 << 31) | 0x42);
}

test "medeleg round-trips Phase 2 delegatable bits" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    // Bits we allow: 0 (inst misaligned), 2 (illegal), 3 (breakpoint),
    // 4 (load misaligned), 6 (store misaligned), 8 (ECALL from U),
    // 12/13/15 (page faults).
    const delegatable: u32 =
        (1 << 0) | (1 << 2) | (1 << 3) | (1 << 4) |
        (1 << 6) | (1 << 8) | (1 << 12) | (1 << 13) | (1 << 15);
    try csrWrite(&cpu, CSR_MEDELEG, delegatable);
    try std.testing.expectEqual(delegatable, try csrRead(&cpu, CSR_MEDELEG));
}

test "medeleg masks out ECALL_FROM_M (bit 11) and reserved bits" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MEDELEG, 0xFFFF_FFFF);
    const v = try csrRead(&cpu, CSR_MEDELEG);
    // bit 11 (ECALL_FROM_M) must be zero — M traps cannot be delegated.
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 11));
    // bit 9 (ECALL_FROM_S) — Phase 2 spec: not delegated; hardwired 0 here.
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 9));
    // Bits we allow round-trip to 1.
    try std.testing.expect((v & (1 << 0)) != 0);
    try std.testing.expect((v & (1 << 8)) != 0);
    try std.testing.expect((v & (1 << 12)) != 0);
}

test "mideleg round-trips SSIP/STIP/SEIP" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    const delegatable_ints: u32 = (1 << 1) | (1 << 5) | (1 << 9);
    try csrWrite(&cpu, CSR_MIDELEG, delegatable_ints);
    try std.testing.expectEqual(delegatable_ints, try csrRead(&cpu, CSR_MIDELEG));
}

test "mideleg masks out MSIP/MTIP/MEIP" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MIDELEG, 0xFFFF_FFFF);
    const v = try csrRead(&cpu, CSR_MIDELEG);
    // M-level interrupt bits must be zero — M interrupts cannot be delegated.
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 3));  // MSIP
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 7));  // MTIP
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 11)); // MEIP
    // S-level interrupt bits round-trip.
    try std.testing.expect((v & (1 << 1)) != 0); // SSIP
    try std.testing.expect((v & (1 << 5)) != 0); // STIP
    try std.testing.expect((v & (1 << 9)) != 0); // SEIP
}
