const std = @import("std");
const cpu_mod = @import("cpu.zig");
const Cpu = cpu_mod.Cpu;
const PrivilegeMode = cpu_mod.PrivilegeMode;

// Writable (software-visible) CSR addresses we implement in Phase 1.
pub const CSR_MSTATUS: u12 = 0x300;
pub const CSR_MISA: u12 = 0x301;
pub const CSR_MIE: u12 = 0x304;
pub const CSR_MTVEC: u12 = 0x305;
pub const CSR_MEPC: u12 = 0x341;
pub const CSR_MCAUSE: u12 = 0x342;
pub const CSR_MTVAL: u12 = 0x343;
pub const CSR_MIP: u12 = 0x344;

// Read-only (hardwired) CSR addresses.
pub const CSR_MVENDORID: u12 = 0xF11;
pub const CSR_MARCHID: u12 = 0xF12;
pub const CSR_MIMPID: u12 = 0xF13;
pub const CSR_MHARTID: u12 = 0xF14;

// mstatus field bits we honor in Phase 1. Other bits read-as-zero.
pub const MSTATUS_MIE: u32 = 1 << 3; // Machine Interrupt Enable
pub const MSTATUS_MPIE: u32 = 1 << 7; // Previous MIE (saved on trap entry)
pub const MSTATUS_MPP_SHIFT: u5 = 11; // Previous privilege (2 bits, 12:11)
pub const MSTATUS_MPP_MASK: u32 = @as(u32, 0b11) << MSTATUS_MPP_SHIFT;
pub const MSTATUS_WRITABLE: u32 = MSTATUS_MIE | MSTATUS_MPIE | MSTATUS_MPP_MASK;

// mtvec field bits. BASE is bits 31:2 (word-aligned); MODE is bits 1:0.
// Phase 1 only honors MODE=0 (direct); MODE=1 (vectored) is stored
// (writes aren't rejected) but trap.enter always jumps to BASE.
pub const MTVEC_MODE_MASK: u32 = 0b11;
pub const MTVEC_BASE_MASK: u32 = ~MTVEC_MODE_MASK;

// mepc is 4-byte aligned in Phase 1 (no compressed extension).
// The low two bits read-as-zero per spec.
pub const MEPC_ALIGN_MASK: u32 = ~@as(u32, 0b11);

// misa value: MXL=01 (RV32), extensions I+M+A+U.
// Bit positions (from RISC-V spec misa chapter):
//   'A' = bit 0, 'I' = bit 8, 'M' = bit 12, 'U' = bit 20
//   MXL lives in the top 2 bits: 31:30.
pub const MISA_VALUE: u32 =
    (@as(u32, 0b01) << 30) | // MXL = RV32
    (@as(u32, 1) << 20) | // U
    (@as(u32, 1) << 12) | // M
    (@as(u32, 1) << 8) | // I
    (@as(u32, 1) << 0); // A

pub const CsrError = error{IllegalInstruction};

/// Read a CSR. In U-mode, any CSR access is illegal (Phase 1 has no
/// user-accessible CSRs; time/cycle/instret live in CSR 0xC00+ which
/// we don't implement yet). Unknown addresses also trap.
pub fn csrRead(cpu: *const Cpu, addr: u12) CsrError!u32 {
    if (cpu.privilege != .M) return CsrError.IllegalInstruction;
    return switch (addr) {
        CSR_MSTATUS => cpu.csr.mstatus,
        CSR_MISA => MISA_VALUE,
        CSR_MIE => cpu.csr.mie,
        CSR_MTVEC => cpu.csr.mtvec,
        CSR_MEPC => cpu.csr.mepc & MEPC_ALIGN_MASK,
        CSR_MCAUSE => cpu.csr.mcause,
        CSR_MTVAL => cpu.csr.mtval,
        CSR_MIP => cpu.csr.mip,
        CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID => 0,
        else => CsrError.IllegalInstruction,
    };
}

/// Write a CSR. Read-only CSRs silently drop writes (WARL). mstatus and
/// mtvec honor field masks; mepc zeros the low two bits.
pub fn csrWrite(cpu: *Cpu, addr: u12, value: u32) CsrError!void {
    if (cpu.privilege != .M) return CsrError.IllegalInstruction;
    switch (addr) {
        CSR_MSTATUS => cpu.csr.mstatus = value & MSTATUS_WRITABLE,
        CSR_MIE => cpu.csr.mie = value,
        CSR_MTVEC => cpu.csr.mtvec = value,
        CSR_MEPC => cpu.csr.mepc = value & MEPC_ALIGN_MASK,
        CSR_MCAUSE => cpu.csr.mcause = value,
        CSR_MTVAL => cpu.csr.mtval = value,
        CSR_MIP => cpu.csr.mip = value,
        // Read-only / hardwired — accept writes silently (WARL behavior).
        CSR_MISA, CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID => {},
        else => return CsrError.IllegalInstruction,
    }
}

test "mstatus round-trips through writable mask" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MSTATUS, 0xFFFF_FFFF);
    try std.testing.expectEqual(MSTATUS_WRITABLE, try csrRead(&cpu, CSR_MSTATUS));
}

test "misa reads back constant RV32IMAU value" {
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

test "mcause round-trips full 32 bits (interrupt high bit + cause)" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MCAUSE, 0x8000_0007);
    try std.testing.expectEqual(@as(u32, 0x8000_0007), try csrRead(&cpu, CSR_MCAUSE));
}
