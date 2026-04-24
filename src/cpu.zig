const std = @import("std");
const decoder = @import("decoder.zig");
const execute = @import("execute.zig");
const trap = @import("trap.zig");
const mem_mod = @import("memory.zig");
const Memory = mem_mod.Memory;
const MemoryError = mem_mod.MemoryError;
const clint_dev = @import("devices/clint.zig");

pub const StepError = error{
    Halt,
    FatalTrap,
};

/// RISC-V privilege levels, spec §Privilege & trap model.
/// Encoding matches the `mstatus.MPP` / `sstatus.SPP` field encoding:
///   0b00 = U, 0b01 = S, 0b11 = M.
/// The reserved H-mode value (0b10) is kept so `@enumFromInt(mstatus_mpp)`
/// is total for any u2 value. csrWrite clamps 0b10 to 0b00 (U) before it
/// reaches storage, so this variant normally cannot arise, but the variant
/// exists as a type-level safety net for defensive reads.
/// Phase 1 implemented U and M only. Phase 2 adds S.
pub const PrivilegeMode = enum(u2) {
    U = 0b00,
    S = 0b01,
    reserved_h = 0b10,
    M = 0b11,
};

/// Writable CSR storage. Read-only CSRs (misa, mhartid, mvendorid,
/// marchid, mimpid) live as constants in csr.zig — they have no storage.
/// Field semantics live in csr.zig's mask constants and its csrRead /
/// csrWrite functions; this struct is just the bytes.
///
/// mstatus is split into per-field storage because the fields are scattered
/// across bit positions and may need to be accessed independently by the
/// trap and S-mode subsystems. The flat mstatus_XYZ naming lets trap.zig
/// read fields directly without helper functions.
pub const CsrFile = struct {
    // mstatus — split into per-field storage (Plan 2.A Task 2)
    mstatus_sie: bool = false, // bit 1  — S Interrupt Enable
    mstatus_mie: bool = false, // bit 3  — M Interrupt Enable
    mstatus_spie: bool = false, // bit 5  — Previous SIE (saved on S-trap entry)
    mstatus_mpie: bool = false, // bit 7  — Previous MIE (saved on M-trap entry)
    mstatus_spp: u1 = 0, // bit 8  — Previous S-mode privilege (0=U, 1=S)
    mstatus_mpp: u2 = 0, // bits 12:11 — Previous M-mode privilege
    mstatus_mprv: bool = false, // bit 17 — Modify PRiVilege
    mstatus_sum: bool = false, // bit 18 — Supervisor User Memory access
    mstatus_mxr: bool = false, // bit 19 — Make eXecutable Readable
    mstatus_tvm: bool = false, // bit 20 — Trap Virtual Memory
    mstatus_tsr: bool = false, // bit 22 — Trap SRET
    // M-mode trap/interrupt CSRs
    mtvec: u32 = 0,
    mepc: u32 = 0,
    mcause: u32 = 0,
    mtval: u32 = 0,
    mie: u32 = 0,
    mip: u32 = 0,
    // Plan 2.B: trap delegation registers. Controlled by M; read by trap
    // routing logic in trap.zig and the interrupt boundary check in
    // cpu.check_interrupt. WARL-masked by csr.zig per the Phase 2 spec.
    medeleg: u32 = 0,
    mideleg: u32 = 0,
    // mscratch (0x340): M-mode scratch register. Software-writable, no side
    // effects, no hardware reads. Included in Plan 1.D so rv32mi-csr passes;
    // the spec's CSR list didn't call it out but the riscv-tests suite
    // assumes it exists.
    mscratch: u32 = 0,
    // mcounteren (0x306): controls U-mode access to time/cycle/instret.
    // Phase 1 doesn't implement those counters, so this register is
    // software-visible state only — writes stored, reads returned. Added
    // for rv32mi-csr conformance.
    mcounteren: u32 = 0,
    // scounteren (0x106): S-mode analog of mcounteren. Same rationale —
    // counters aren't implemented, register is software-visible only.
    scounteren: u32 = 0,
    // S-mode CSRs (placeholders for Tasks 4, 5, 6, 7, etc.)
    stvec: u32 = 0,
    sscratch: u32 = 0,
    sepc: u32 = 0,
    scause: u32 = 0,
    stval: u32 = 0,
    satp: u32 = 0,
};

pub const Cpu = struct {
    regs: [32]u32,
    pc: u32,
    memory: *Memory,
    // LR/SC reservation: address last reserved by lr.w, or null.
    // Set by lr.w, cleared by sc.w (on success or failure). Plan 1.C
    // will additionally clear this on trap entry; Plan 1.B has no traps.
    reservation: ?u32,
    // Current privilege level. Starts in M; a monitor drops to U via mret,
    // and synchronous traps return control to M. Phase 1 used only U and M;
    // Phase 2 adds S. The reserved_h variant exists only to round-trip the
    // mstatus.MPP bit field losslessly (see trap.zig).
    privilege: PrivilegeMode,
    csr: CsrFile,
    // If true, an unhandled trap prints a dump and halts instead of
    // entering the trap handler. Wired by --halt-on-trap in main.zig.
    halt_on_trap: bool = false,
    // Set to true when a trap is taken; checked by run() to halt if
    // halt_on_trap is set.
    trap_taken: bool = false,
    // Optional writer for instruction trace. Wired by --trace in main.zig.
    trace_writer: ?*std.Io.Writer = null,

    pub fn init(memory: *Memory, entry: u32) Cpu {
        return .{
            .regs = [_]u32{0} ** 32,
            .pc = entry,
            .memory = memory,
            .reservation = null,
            .privilege = .M,
            .csr = .{},
            .halt_on_trap = false,
            .trap_taken = false,
            .trace_writer = null,
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
        const pre_pc = self.pc;
        const pre_priv = self.privilege; // captured before any fetch/execute may trap-switch privilege
        // Instruction fetch: translate using the current privilege directly —
        // MPRV is non-applicable to fetch per the spec, so we intentionally
        // bypass `effectivePriv` and the translating `loadWord` wrapper.
        const pa = self.memory.translate(pre_pc, .fetch, self.privilege, self) catch |e| switch (e) {
            error.InstPageFault => {
                trap.enter(.instr_page_fault, pre_pc, self);
                return;
            },
            else => unreachable, // translate only returns TranslationError variants
        };
        const word = self.memory.loadWordPhysical(pa) catch |e| switch (e) {
            error.Halt => return StepError.Halt,
            error.MisalignedAccess => {
                trap.enter(.instr_addr_misaligned, pre_pc, self);
                return;
            },
            else => {
                trap.enter(.instr_access_fault, pre_pc, self);
                return;
            },
        };
        const instr = decoder.decode(word);
        const pre_rd = self.regs[instr.rd];
        execute.dispatch(instr, self) catch |e| switch (e) {
            error.Halt => return StepError.Halt,
            error.FatalTrap => return StepError.FatalTrap,
        };
        if (self.trace_writer) |tw| {
            const post_rd = self.regs[instr.rd];
            @import("trace.zig").formatInstr(tw, pre_priv, pre_pc, instr, pre_rd, post_rd, self.pc) catch {};
        }
    }

    pub fn run(self: *Cpu) StepError!void {
        while (true) {
            self.trap_taken = false;
            self.step() catch |err| switch (err) {
                error.Halt => return,
                error.FatalTrap => return err,
            };
            if (self.trap_taken and self.halt_on_trap) {
                return StepError.FatalTrap;
            }
        }
    }
};

/// Compute the effective `mip` for the interrupt-boundary check. This is
/// cpu.csr.mip OR'd with CLINT's live MTIP bit. We never store MTIP in
/// cpu.csr.mip — the bit is always derived here and inside csrRead.
fn pendingInterrupts(cpu: *const Cpu) u32 {
    var mip = cpu.csr.mip;
    if (cpu.memory.clint.isMtipPending()) mip |= 1 << 7;
    return mip;
}

/// Returns true if an interrupt would be deliverable at `target` given the
/// current privilege level and the relevant global-enable bit.
/// Spec §3.1.6.1 / §3.1.9 rule:
///   current < target → always taken (lower privilege can't mask higher)
///   current == target → consult global enable (MIE for M, SIE for S)
///   current > target → never taken this cycle (pend until we drop down)
fn interruptDeliverableAt(target: PrivilegeMode, cpu: *const Cpu) bool {
    const target_rank = @intFromEnum(target);
    const current_rank = @intFromEnum(cpu.privilege);
    if (current_rank < target_rank) return true;
    if (current_rank > target_rank) return false;
    return switch (target) {
        .M => cpu.csr.mstatus_mie,
        .S => cpu.csr.mstatus_sie,
        else => false,
    };
}

/// Check for a deliverable async interrupt at the current instruction
/// boundary. If one exists, enter the trap and return true; otherwise
/// return false (caller proceeds with the fetch).
///
/// Priority uses the RISC-V spec order exposed in trap.INTERRUPT_PRIORITY_ORDER.
/// For each cause code in that order, we consult the effective mip AND mie
/// to see if it's pending+enabled, then route via mideleg to determine the
/// target privilege (but never delegate when cpu.privilege == .M), then
/// apply the deliverability rule above. The first cause passing all three
/// gates wins.
pub fn check_interrupt(cpu: *Cpu) bool {
    const effective_mip = pendingInterrupts(cpu);
    const pending_enabled = effective_mip & cpu.csr.mie;
    if (pending_enabled == 0) return false;

    for (trap.INTERRUPT_PRIORITY_ORDER) |cause_code| {
        const bit = @as(u32, 1) << @intCast(cause_code);
        if ((pending_enabled & bit) == 0) continue;

        const delegated = (cpu.csr.mideleg & bit) != 0;
        const target: PrivilegeMode =
            if (cpu.privilege != .M and delegated) .S else .M;

        if (!interruptDeliverableAt(target, cpu)) continue;

        trap.enter_interrupt(cause_code, cpu);
        return true;
    }

    return false;
}

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
    var clint = clint_dev.Clint.init(&clint_dev.zeroClock);
    var mem = try Memory.init(std.testing.allocator, &halt, &uart, &clint, null, mem_mod.RAM_SIZE_DEFAULT);
    defer mem.deinit();

    // Hand-encoded program at RAM_BASE:
    //   lui   t0, 0x100        ; t0 = 0x00100000 (halt MMIO)
    //   sb    zero, 0(t0)      ; *t0 = 0 → halt
    const RAM_BASE = @import("memory.zig").RAM_BASE;
    try mem.storeWordPhysical(RAM_BASE, 0x001002B7); // lui t0, 0x100
    try mem.storeWordPhysical(RAM_BASE + 4, 0x00028023); // sb zero, 0(t0)

    var cpu = Cpu.init(&mem, RAM_BASE);
    try cpu.run();
    try std.testing.expectEqual(@as(?u8, 0), halt.exit_code);
}

test "Cpu.init sets reservation to null" {
    var dummy_mem: Memory = undefined;
    const cpu = Cpu.init(&dummy_mem, 0);
    try std.testing.expect(cpu.reservation == null);
}

test "Cpu.init starts in M-mode" {
    var dummy_mem: Memory = undefined;
    const cpu = Cpu.init(&dummy_mem, 0);
    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
}

test "PrivilegeMode has M, S, and U" {
    const m = PrivilegeMode.M;
    const s = PrivilegeMode.S;
    const u = PrivilegeMode.U;
    try std.testing.expect(m != s);
    try std.testing.expect(s != u);
    try std.testing.expect(u != m);
}

test "instruction page fault: step() from unmapped PC in U-mode updates mcause and mtval" {
    var halt = @import("devices/halt.zig").Halt.init();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var uart = @import("devices/uart.zig").Uart.init(&aw.writer);
    var clint = clint_dev.Clint.init(&clint_dev.zeroClock);
    var mem = try Memory.init(std.testing.allocator, &halt, &uart, &clint, null, mem_mod.RAM_SIZE_DEFAULT);
    defer mem.deinit();

    // Point satp at an empty root page (all zero RAM → L1 PTE.V=0 → fetch fault).
    const root_pa: u32 = 0x8010_0000;
    const faulting_pc: u32 = 0x0001_0000; // unmapped virtual address

    // CPU starts in M-mode; switch to U-mode and set up Sv32 with empty root.
    var cpu = Cpu.init(&mem, faulting_pc);
    cpu.privilege = .U;
    cpu.csr.satp = (1 << 31) | (root_pa >> 12);
    cpu.csr.mtvec = 0x8000_1000;

    // step() will attempt to fetch from faulting_pc, translation will fault,
    // trap.enter sets mcause/mtval/mepc, and step() returns normally.
    try cpu.step();

    try std.testing.expectEqual(
        @as(u32, @intFromEnum(trap.Cause.instr_page_fault)),
        cpu.csr.mcause,
    );
    try std.testing.expectEqual(@as(u32, faulting_pc), cpu.csr.mtval);
    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_1000), cpu.pc);
}

test "CsrFile default has zero medeleg and mideleg" {
    var dummy_mem: Memory = undefined;
    const cpu = Cpu.init(&dummy_mem, 0);
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.medeleg);
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.mideleg);
}

const trap_mod = @import("trap.zig");
const halt_dev_t = @import("devices/halt.zig");
const uart_dev_t = @import("devices/uart.zig");

const CpuRig = struct {
    halt: halt_dev_t.Halt,
    aw: std.Io.Writer.Allocating,
    uart: uart_dev_t.Uart,
    clint: clint_dev.Clint,
    mem: Memory,
    cpu: Cpu,
    fn deinit(self: *CpuRig) void {
        self.mem.deinit();
        self.aw.deinit();
        std.testing.allocator.destroy(self);
    }
};

/// Allocates a CpuRig on the heap so that internal pointers (mem→clint,
/// mem→uart, cpu→mem, uart→writer) remain stable across the return. Callers
/// must `defer rig.deinit()` which frees both the heap object and the RAM.
fn cpuRig() !*CpuRig {
    clint_dev.fixture_clock_ns = 0;
    const rig = try std.testing.allocator.create(CpuRig);
    rig.halt = halt_dev_t.Halt.init();
    rig.aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    rig.uart = uart_dev_t.Uart.init(&rig.aw.writer);
    rig.clint = clint_dev.Clint.init(&clint_dev.fixtureClock);
    rig.mem = try Memory.init(
        std.testing.allocator, &rig.halt, &rig.uart, &rig.clint, null,
        mem_mod.RAM_SIZE_DEFAULT,
    );
    rig.cpu = Cpu.init(&rig.mem, mem_mod.RAM_BASE);
    return rig;
}

test "check_interrupt: no pending → returns false, cpu state unchanged" {
    var rig = try cpuRig();
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.mie = 0xFFFF_FFFF & @import("csr.zig").MIE_MASK;
    const taken = check_interrupt(&rig.cpu);
    try std.testing.expect(!taken);
    try std.testing.expectEqual(PrivilegeMode.U, rig.cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.csr.mcause);
}

test "check_interrupt: MTIP pending, MIE+MTIE set in M-mode → M-trap taken" {
    var rig = try cpuRig();
    defer rig.deinit();
    rig.cpu.privilege = .M;
    rig.cpu.csr.mtvec = 0x8000_0400;
    rig.cpu.csr.mstatus_mie = true;
    rig.cpu.csr.mie = 1 << 7;
    rig.clint.mtimecmp = 50;
    clint_dev.fixture_clock_ns = 10_000;

    const taken = check_interrupt(&rig.cpu);
    try std.testing.expect(taken);
    try std.testing.expectEqual(PrivilegeMode.M, rig.cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0007), rig.cpu.csr.mcause);
    try std.testing.expectEqual(@as(u32, 0x8000_0400), rig.cpu.pc);
}

test "check_interrupt: M-mode with MIE=0 → MTIP pending but not taken" {
    var rig = try cpuRig();
    defer rig.deinit();
    rig.cpu.privilege = .M;
    rig.cpu.csr.mtvec = 0x8000_0400;
    rig.cpu.csr.mstatus_mie = false;
    rig.cpu.csr.mie = 1 << 7;
    rig.clint.mtimecmp = 50;
    clint_dev.fixture_clock_ns = 10_000;

    try std.testing.expect(!check_interrupt(&rig.cpu));
    try std.testing.expectEqual(PrivilegeMode.M, rig.cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.csr.mcause);
}

test "check_interrupt: U-mode always allows M-interrupt regardless of MIE" {
    var rig = try cpuRig();
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.mtvec = 0x8000_0400;
    rig.cpu.csr.mstatus_mie = false;
    rig.cpu.csr.mie = 1 << 7;
    rig.clint.mtimecmp = 50;
    clint_dev.fixture_clock_ns = 10_000;

    try std.testing.expect(check_interrupt(&rig.cpu));
    try std.testing.expectEqual(PrivilegeMode.M, rig.cpu.privilege);
}

test "check_interrupt: SSIP delegated, in U → trap taken at S" {
    var rig = try cpuRig();
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.stvec = 0x8000_0600;
    rig.cpu.csr.mideleg = 1 << 1;
    rig.cpu.csr.mstatus_sie = false;
    rig.cpu.csr.mie = 1 << 1;
    rig.cpu.csr.mip = 1 << 1;

    try std.testing.expect(check_interrupt(&rig.cpu));
    try std.testing.expectEqual(PrivilegeMode.S, rig.cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0001), rig.cpu.csr.scause);
    try std.testing.expectEqual(@as(u32, 0x8000_0600), rig.cpu.pc);
}

test "check_interrupt: priority order — MTI beats SSI when both pending at U" {
    var rig = try cpuRig();
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.mtvec = 0x8000_0400;
    rig.cpu.csr.stvec = 0x8000_0600;
    rig.cpu.csr.mideleg = 1 << 1;
    rig.cpu.csr.mie = (1 << 7) | (1 << 1);
    rig.cpu.csr.mip = 1 << 1;
    rig.clint.mtimecmp = 50;
    clint_dev.fixture_clock_ns = 10_000;

    try std.testing.expect(check_interrupt(&rig.cpu));
    // MTI beats SSI in priority order.
    try std.testing.expectEqual(PrivilegeMode.M, rig.cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0007), rig.cpu.csr.mcause);
}
