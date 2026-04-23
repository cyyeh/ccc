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

/// Two-level RISC-V privilege, spec §Privilege & trap model.
/// Encoding matches the `mstatus.MPP` field: 0b00 = U, 0b11 = M.
/// The two reserved middle values (0b01 = S, 0b10 = H) never appear in
/// Phase 1 but we keep them in the enum so bit-level round-trips through
/// mstatus are total; `trap.exit_mret` normalizes them to U (spec: WARL
/// unsupported modes read back as the least-privileged supported mode).
pub const PrivilegeMode = enum(u2) {
    U = 0b00,
    reserved_s = 0b01,
    reserved_h = 0b10,
    M = 0b11,
};

/// Writable CSR storage. Read-only CSRs (misa, mhartid, mvendorid,
/// marchid, mimpid) live as constants in csr.zig — they have no storage.
/// Field semantics live in csr.zig's mask constants and its csrRead /
/// csrWrite functions; this struct is just the bytes.
pub const CsrFile = struct {
    mstatus: u32 = 0,
    mtvec: u32 = 0,
    mepc: u32 = 0,
    mcause: u32 = 0,
    mtval: u32 = 0,
    mie: u32 = 0,
    mip: u32 = 0,
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
    // and synchronous traps return control to M. Phase 1 never uses the
    // reserved_s/reserved_h variants; they exist only to round-trip the
    // mstatus.MPP bit field losslessly (see trap.zig).
    privilege: PrivilegeMode,
    csr: CsrFile,
    // If true, an unhandled trap prints a dump and halts instead of
    // entering the trap handler. Wired by --halt-on-trap in main.zig.
    halt_on_trap: bool = false,
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
        const word = self.memory.loadWord(pre_pc) catch |e| switch (e) {
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
            @import("trace.zig").formatInstr(tw, pre_pc, instr, pre_rd, post_rd, self.pc) catch {};
        }
    }

    pub fn run(self: *Cpu) StepError!void {
        while (true) {
            self.step() catch |err| switch (err) {
                error.Halt => return,
                else => return err,
            };
        }
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
    var clint = clint_dev.Clint.init(&clint_dev.zeroClock);
    var mem = try Memory.init(std.testing.allocator, &halt, &uart, &clint, null, mem_mod.RAM_SIZE_DEFAULT);
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
