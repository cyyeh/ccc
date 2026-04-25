// tests/programs/kernel/proc.zig — Phase 3.B process table.
//
// Phase 3.B replaces the Phase 2 singleton `the_process` with a static
// process table `ptable[NPROC]`. Key design points:
//
//   - `pub export var ptable` makes `ptable` asm-visible; `la t0, ptable`
//     in trampoline.S resolves to &ptable[0], whose first field is `tf`
//     (offset 0), preserving the trampoline's sscratch invariant.
//   - `Context` (added in Task 2) is embedded in Process for per-process
//     kernel-context save/restore by the scheduler.
//   - `cur()` returns &ptable[0] until the Task-9 CPU-local scheduler is
//     wired; trap.zig/syscall.zig use it to read the current process.
//   - `KSTACK_TOP_OFFSET == 144`: tf(128 bytes) + satp(4) + pgdir(4) +
//     sz(4) + kstack(4) = 144; comptime asserts pin this.

const std = @import("std");
const trap = @import("trap.zig");

pub extern fn swtch(old: *Context, new: *Context) void;

pub const Context = extern struct {
    ra: u32,
    sp: u32,
    s0: u32, s1: u32, s2: u32, s3: u32, s4: u32, s5: u32,
    s6: u32, s7: u32, s8: u32, s9: u32, s10: u32, s11: u32,
};

pub const CTX_RA: u32 = 0;
pub const CTX_SP: u32 = 4;
pub const CTX_S0: u32 = 8;
pub const CTX_S1: u32 = 12;
pub const CTX_S2: u32 = 16;
pub const CTX_S3: u32 = 20;
pub const CTX_S4: u32 = 24;
pub const CTX_S5: u32 = 28;
pub const CTX_S6: u32 = 32;
pub const CTX_S7: u32 = 36;
pub const CTX_S8: u32 = 40;
pub const CTX_S9: u32 = 44;
pub const CTX_S10: u32 = 48;
pub const CTX_S11: u32 = 52;
pub const CTX_SIZE: u32 = 56;

comptime {
    std.debug.assert(@offsetOf(Context, "ra") == CTX_RA);
    std.debug.assert(@offsetOf(Context, "sp") == CTX_SP);
    std.debug.assert(@offsetOf(Context, "s0") == CTX_S0);
    std.debug.assert(@offsetOf(Context, "s11") == CTX_S11);
    std.debug.assert(@sizeOf(Context) == CTX_SIZE);
}

pub const NPROC: u32 = 16;

pub const State = enum(u32) {
    Unused = 0,
    Embryo = 1,
    Sleeping = 2,
    Runnable = 3,
    Running = 4,
    Zombie = 5,
};

pub const Process = extern struct {
    tf: trap.TrapFrame,    // offset 0 — trampoline.S depends on this
    satp: u32,             // offset 128
    pgdir: u32,            // offset 132
    sz: u32,               // offset 136
    kstack: u32,           // offset 140
    kstack_top: u32,       // offset 144 — referenced by trampoline.S
    state: State,
    pid: u32,
    chan: u32,
    killed: u32,
    xstate: i32,
    ticks_observed: u32,
    context: Context,
    name: [16]u8,
    parent: ?*Process,
};

pub const KSTACK_TOP_OFFSET: u32 = 144;

comptime {
    std.debug.assert(@offsetOf(Process, "tf") == 0);
    std.debug.assert(@offsetOf(Process, "satp") == trap.TF_SIZE);
    std.debug.assert(@offsetOf(Process, "kstack_top") == KSTACK_TOP_OFFSET);
    std.debug.assert(@offsetOf(Process, "pgdir") == 132);
    std.debug.assert(@offsetOf(Process, "sz") == 136);
    std.debug.assert(@offsetOf(Process, "kstack") == 140);
}

// Static process table. `pub export var` so trampoline.S can resolve
// `la t0, ptable` — the symbol address equals &ptable[0], whose first
// field is `tf` (offset 0), preserving the trampoline's existing
// "trapframe lives at sscratch" invariant.
// Slots are zero-initialized by boot.S's BSS clear; State.Unused == 0
// guarantees all 16 slots start as Unused without explicit init.
pub export var ptable: [NPROC]Process = undefined;

/// Phase 3.B "current process" accessor. Until the scheduler boots
/// (Task 9, where `cpu.cur` becomes meaningful), this returns
/// `&ptable[0]` so trap/syscall code keeps working unchanged.
pub fn cur() *Process {
    return &ptable[0];
}
