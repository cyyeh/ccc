const std = @import("std");
const decoder = @import("decoder.zig");
const execute = @import("execute.zig");
const trap = @import("trap.zig");
const mem_mod = @import("memory.zig");
const Memory = mem_mod.Memory;
const MemoryError = mem_mod.MemoryError;
const clint_dev = @import("devices/clint.zig");
const plic_dev = @import("devices/plic.zig");

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
        // Plan 3.A Task 12: service deferred device IRQs from the previous
        // instruction's MMIO writes. The block device sets pending_irq inside
        // performTransfer; we drain it here at the next instruction boundary
        // so the PLIC sees the source-1 assertion atomically with respect to
        // the instruction stream.
        if (self.memory.block.pending_irq) {
            self.memory.plic.assertSource(1);
            self.memory.block.pending_irq = false;
        }

        // Plan 2.B: check for deliverable async interrupts BEFORE fetching.
        // If one is taken, the PC has been redirected to the trap vector
        // and the instruction that would have been fetched this cycle is
        // not executed — per RISC-V spec, interrupts are taken at the
        // boundary between instructions.
        if (check_interrupt(self)) return;

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

    /// Idle the CPU until a deliverable interrupt arrives or 10s wall-clock
    /// elapses. Called by execute.zig's wfi arm.
    ///
    /// Each iteration: service deferred device IRQs (block); poll host stdin
    /// (if a UART pump is wired); check for deliverable interrupts. If a trap
    /// fires, return early — the caller's step() will detect cpu.trap_taken
    /// and skip the +4 PC advance. If nothing happens, sleep ~1 ms and loop.
    pub fn idleSpin(self: *Cpu) void {
        const max_ns: i128 = 10_000_000_000; // 10 s
        const start = monotonicNs();
        while (true) {
            // Service deferred block IRQ.
            if (self.memory.block.pending_irq) {
                self.memory.plic.assertSource(1);
                self.memory.block.pending_irq = false;
            }
            // Drain host stdin if a pump is configured (Task 16 wires this).
            if (self.memory.uart.rx_pump) |pump| {
                pump.drainAvailable(self.memory.uart);
            }
            // Did we just get something interrupt-worthy?
            if (check_interrupt(self)) return;

            if (monotonicNs() - start > max_ns) return;
            // 1 ms sleep — short enough to keep tests fast, long enough to
            // not chew CPU when truly idle. Zig 0.16 has no top-level
            // std.Thread.sleep; go through libc nanosleep directly.
            sleepMs(1);
        }
    }
};

/// Monotonic timestamp in nanoseconds via libc clock_gettime. Mirrors the
/// approach in devices/clint.zig because Zig 0.16 removed std.time.nanoTimestamp.
fn monotonicNs() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const sec: i128 = @intCast(ts.sec);
    const nsec: i128 = @intCast(ts.nsec);
    return sec * 1_000_000_000 + nsec;
}

/// Sleep for `ms` milliseconds via libc nanosleep. Best-effort: an EINTR/early
/// wakeup just shortens the iteration, which is harmless — idleSpin loops.
fn sleepMs(ms: u32) void {
    const ns_per_ms: i64 = 1_000_000;
    var req: std.c.timespec = .{
        .sec = @intCast(@divTrunc(ms, 1000)),
        .nsec = @intCast(@as(i64, @intCast(ms % 1000)) * ns_per_ms),
    };
    _ = std.c.nanosleep(&req, null);
}

/// Compute the effective `mip` for the interrupt-boundary check. This is
/// cpu.csr.mip OR'd with CLINT's live MTIP bit and PLIC's live SEIP bit.
/// We never store MTIP or SEIP in cpu.csr.mip — those bits are always
/// derived here and inside csrRead.
fn pendingInterrupts(cpu: *const Cpu) u32 {
    var mip = cpu.csr.mip;
    if (cpu.memory.clint.isMtipPending()) mip |= 1 << 7;
    if (cpu.memory.plic.hasPendingForS()) mip |= 1 << 9;
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
    var plic = plic_dev.Plic.init();
    var block = @import("devices/block.zig").Block.init();
    var mem = try Memory.init(std.testing.allocator, &halt, &uart, &clint, &plic, &block, std.testing.io, null, mem_mod.RAM_SIZE_DEFAULT);
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
    var plic = plic_dev.Plic.init();
    var block = @import("devices/block.zig").Block.init();
    var mem = try Memory.init(std.testing.allocator, &halt, &uart, &clint, &plic, &block, std.testing.io, null, mem_mod.RAM_SIZE_DEFAULT);
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
const block_dev_t = @import("devices/block.zig");

const CpuRig = struct {
    halt: halt_dev_t.Halt,
    aw: std.Io.Writer.Allocating,
    uart: uart_dev_t.Uart,
    clint: clint_dev.Clint,
    plic: plic_dev.Plic,
    block: block_dev_t.Block,
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
    rig.plic = plic_dev.Plic.init();
    rig.block = block_dev_t.Block.init();
    rig.mem = try Memory.init(
        std.testing.allocator, &rig.halt, &rig.uart, &rig.clint, &rig.plic, &rig.block,
        std.testing.io, null, mem_mod.RAM_SIZE_DEFAULT,
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

test "Cpu.step() takes pending MTI before fetching the next instruction" {
    var rig = try cpuRig();
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.mtvec = 0x8000_0400;
    rig.cpu.csr.mie = 1 << 7;
    rig.cpu.csr.mstatus_mie = false; // U-mode: MIE ignored, lower privilege always takes
    rig.clint.mtimecmp = 50;
    clint_dev.fixture_clock_ns = 10_000;

    const saved_pc = rig.cpu.pc;
    try rig.cpu.step();

    try std.testing.expectEqual(PrivilegeMode.M, rig.cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0400), rig.cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x8000_0007), rig.cpu.csr.mcause);
    try std.testing.expectEqual(saved_pc, rig.cpu.csr.mepc);
}

test "Cpu.step() with no pending interrupts runs the fetched instruction" {
    var rig = try cpuRig();
    defer rig.deinit();
    try rig.mem.storeWordPhysical(mem_mod.RAM_BASE, 0x00000013); // nop
    const saved_pc = rig.cpu.pc;

    try rig.cpu.step();

    try std.testing.expectEqual(saved_pc + 4, rig.cpu.pc);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.csr.mcause);
}

test "integration: CLINT → M MTI ISR → mip.SSIP → S SSI ISR end-to-end" {
    clint_dev.fixture_clock_ns = 0;
    var halt = @import("devices/halt.zig").Halt.init();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var uart = @import("devices/uart.zig").Uart.init(&aw.writer);
    var clint = clint_dev.Clint.init(&clint_dev.fixtureClock);
    var plic = plic_dev.Plic.init();
    var block = @import("devices/block.zig").Block.init();
    var mem = try Memory.init(
        std.testing.allocator, &halt, &uart, &clint, &plic, &block, std.testing.io, null, mem_mod.RAM_SIZE_DEFAULT,
    );
    defer mem.deinit();

    // --- Program layout ---
    // 0x80000000  reset: setup delegation, CSRs, drop to U at 0x80001000
    // 0x80000400  M-mode MTI ISR
    // 0x80000600  S-mode SSI ISR
    // 0x80000800  sentinel word (starts 0, S ISR writes 1)
    // 0x80001000  U-mode infinite loop

    const RAM_BASE = mem_mod.RAM_BASE;

    // --- Reset code @ 0x80000000 ---
    // csrrwi zero, mideleg, 2      # mideleg = (1<<1) = SSIP
    try mem.storeWordPhysical(RAM_BASE + 0x000, 0x30315073);
    // lui t0, 0x80000; addi t0, t0, 0x400  (pre-compute mtvec target)
    try mem.storeWordPhysical(RAM_BASE + 0x004, 0x800002B7); // lui t0, 0x80000
    try mem.storeWordPhysical(RAM_BASE + 0x008, 0x40028293); // addi t0, t0, 0x400
    // csrw mtvec, t0 (0x305)
    try mem.storeWordPhysical(RAM_BASE + 0x00C, 0x30529073);
    // lui t0, 0x80000; addi t0, t0, 0x600  → stvec
    try mem.storeWordPhysical(RAM_BASE + 0x010, 0x800002B7);
    try mem.storeWordPhysical(RAM_BASE + 0x014, 0x60028293);
    // csrw stvec, t0 (0x105)
    try mem.storeWordPhysical(RAM_BASE + 0x018, 0x10529073);
    // li t0, (1<<7) | (1<<1)        # MTIE | SSIE
    try mem.storeWordPhysical(RAM_BASE + 0x01C, 0x08200293); // addi t0, x0, 0x82
    // csrw mie, t0
    try mem.storeWordPhysical(RAM_BASE + 0x020, 0x30429073);
    // csrrsi zero, mstatus, 0x8     # MIE = 1
    try mem.storeWordPhysical(RAM_BASE + 0x024, 0x30046073);
    // csrrsi zero, sstatus, 0x2     # SIE = 1
    try mem.storeWordPhysical(RAM_BASE + 0x028, 0x10016073);
    // li t1, 100; write mtimecmp = 100
    //   CLINT_MTIMECMP = 0x02004000
    try mem.storeWordPhysical(RAM_BASE + 0x02C, 0x06400313); // addi t1, x0, 100
    try mem.storeWordPhysical(RAM_BASE + 0x030, 0x020043B7); // lui t2, 0x2004
    try mem.storeWordPhysical(RAM_BASE + 0x034, 0x0063A023); // sw t1, 0(t2)
    try mem.storeWordPhysical(RAM_BASE + 0x038, 0x0003A223); // sw zero, 4(t2)
    // lui t0, 0x80001; csrw mepc, t0
    try mem.storeWordPhysical(RAM_BASE + 0x03C, 0x800012B7);
    try mem.storeWordPhysical(RAM_BASE + 0x040, 0x34129073);
    // mret
    try mem.storeWordPhysical(RAM_BASE + 0x044, 0x30200073);

    // --- M-mode MTI ISR @ 0x80000400 ---
    //   Ack by moving mtimecmp far into the future; forward to SSIP; mret.
    //   li t0, -1; lui t2, 0x2004; sw t0, 0(t2); sw t0, 4(t2)
    //   csrrsi zero, mip, 0x2       # set SSIP
    //   mret
    try mem.storeWordPhysical(RAM_BASE + 0x400, 0xFFF00293); // addi t0, x0, -1
    try mem.storeWordPhysical(RAM_BASE + 0x404, 0x020043B7); // lui t2, 0x2004
    try mem.storeWordPhysical(RAM_BASE + 0x408, 0x0053A023); // sw t0, 0(t2)
    try mem.storeWordPhysical(RAM_BASE + 0x40C, 0x0053A223); // sw t0, 4(t2)
    try mem.storeWordPhysical(RAM_BASE + 0x410, 0x34416073); // csrrsi zero, mip, 0x2
    try mem.storeWordPhysical(RAM_BASE + 0x414, 0x30200073); // mret

    // --- S-mode SSI ISR @ 0x80000600 ---
    // Clear SSIP via sip; compute sentinel address via auipc+addi; write
    // 1 to sentinel; loop forever.
    //   csrrci zero, sip, 0x2     # clear SSIP
    //   auipc  t0, 0x0             # t0 = 0x80000604
    //   addi   t0, t0, 0x1FC       # t0 = 0x80000800 (sentinel VA)
    //   addi   t1, x0, 1
    //   sw     t1, 0(t0)
    //   loop: j loop
    try mem.storeWordPhysical(RAM_BASE + 0x600, 0x14417073); // csrrci zero, sip, 0x2
    try mem.storeWordPhysical(RAM_BASE + 0x604, 0x00000297); // auipc t0, 0x0
    try mem.storeWordPhysical(RAM_BASE + 0x608, 0x1FC28293); // addi t0, t0, 0x1FC
    try mem.storeWordPhysical(RAM_BASE + 0x60C, 0x00100313); // addi t1, x0, 1
    try mem.storeWordPhysical(RAM_BASE + 0x610, 0x0062A023); // sw t1, 0(t0)
    try mem.storeWordPhysical(RAM_BASE + 0x614, 0x0000006F); // loop: j self

    // --- U-mode loop @ 0x80001000 ---
    //   j 0   (loop forever; MTI will interrupt us)
    try mem.storeWordPhysical(RAM_BASE + 0x1000, 0x0000006F);

    // Sentinel starts at zero.
    try mem.storeWordPhysical(RAM_BASE + 0x800, 0);

    var cpu = Cpu.init(&mem, RAM_BASE);

    // Step through reset, then drop into U, then let CLINT fire.
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        cpu.step() catch |e| switch (e) { error.Halt, error.FatalTrap => break };
    }
    // Now advance the wall clock so MTIP fires at the next boundary.
    clint_dev.fixture_clock_ns = 20_000; // mtime = 200, mtimecmp = 100 → pending
    i = 0;
    while (i < 200) : (i += 1) {
        cpu.step() catch |e| switch (e) { error.Halt, error.FatalTrap => break };
        const sentinel = try mem.loadWordPhysical(RAM_BASE + 0x800);
        if (sentinel == 1) break;
    }
    const sentinel = try mem.loadWordPhysical(RAM_BASE + 0x800);
    try std.testing.expectEqual(@as(u32, 1), sentinel);
    // Final privilege should be S (SSI ISR loops there).
    try std.testing.expectEqual(PrivilegeMode.S, cpu.privilege);
}

test "step asserts PLIC IRQ #1 when block has pending_irq set, then clears the flag" {
    var rig = try cpuRig();
    defer rig.deinit();

    // Manually set pending_irq as if performTransfer just ran.
    rig.cpu.memory.block.pending_irq = true;
    // Place a NOP at PC so step proceeds normally after IRQ delivery.
    try rig.mem.storeWordPhysical(rig.cpu.pc, 0x00000013); // addi x0,x0,0 (nop)

    _ = rig.cpu.step() catch {};
    try std.testing.expect((rig.cpu.memory.plic.pending & (1 << 1)) != 0);
    try std.testing.expect(!rig.cpu.memory.block.pending_irq);
}

test "WFI returns promptly when a deliverable interrupt arrives during idle" {
    var rig = try cpuRig();
    defer rig.deinit();

    // Configure delegation + enable so SEIP delivers to S.
    rig.cpu.privilege = .U;                              // U < S → trap deliverable regardless of sstatus.SIE
    rig.cpu.csr.stvec = 0x8000_0500;
    rig.cpu.csr.mideleg = 1 << 9;                        // delegate SEIP to S
    rig.cpu.csr.mie = 1 << 9;                            // SEIE
    // PLIC: src 1 priority 1, enabled, threshold 0.
    try rig.cpu.memory.plic.writeByte(0x0004, 1);
    try rig.cpu.memory.plic.writeByte(0x2080, 0x02);

    // Pre-arm block IRQ so the first idleSpin iteration asserts PLIC src 1
    // and check_interrupt fires immediately.
    rig.cpu.memory.block.pending_irq = true;

    // Place WFI at PC. (U-mode wfi traps illegal in our model, but here we'll
    // test idleSpin directly to keep the unit-level concern pure.)
    rig.cpu.idleSpin();

    // After idleSpin returns: PLIC src 1 was asserted, the trap was taken,
    // privilege flipped to S, PC redirected to stvec.
    // Plan note: pending bit stays set until claim; what we test is: trap was taken.
    try std.testing.expect((rig.cpu.memory.plic.pending & (1 << 1)) != 0);
    try std.testing.expectEqual(@import("cpu.zig").PrivilegeMode.S, rig.cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0500), rig.cpu.pc);
    try std.testing.expectEqual(@as(u32, (1 << 31) | 9), rig.cpu.csr.scause);
    try std.testing.expect(!rig.cpu.memory.block.pending_irq); // serviced
}
