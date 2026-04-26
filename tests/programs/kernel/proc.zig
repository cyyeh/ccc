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
const page_alloc = @import("page_alloc.zig");
const kprintf = @import("kprintf.zig");

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

pub const Cpu = extern struct {
    cur: ?*Process,
    sched_context: Context,
    sched_stack_top: u32,
};

comptime {
    std.debug.assert(@sizeOf(Cpu) == 64); // 4 (?*Process) + 56 (Context) + 4 (sched_stack_top)
}

pub var cpu: Cpu = undefined;

// The scheduler runs on its OWN dedicated kernel stack rather than borrowing
// a stack from any process. This means a process that sleeps mid-syscall
// (e.g. Task 3.D's sleep) leaves its kernel stack untouched while the
// scheduler resumes here — the same rationale as xv6; we land it now in 3.B
// for clean ordering before the scheduler loop is wired in Task 9.
pub fn cpuInit() void {
    cpu = std.mem.zeroes(Cpu);
    const stack = page_alloc.alloc() orelse kprintf.panic("cpuInit: no scheduler stack", .{});
    cpu.sched_stack_top = stack + page_alloc.PAGE_SIZE;
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
    return cpu.cur orelse &ptable[0];
}

pub fn alloc() ?*Process {
    var i: u32 = 0;
    while (i < NPROC) : (i += 1) {
        const p = &ptable[i];
        if (p.state == .Unused) {
            p.* = std.mem.zeroes(Process);
            p.state = .Embryo;
            p.pid = nextPid();
            const ks = page_alloc.alloc() orelse {
                p.* = std.mem.zeroes(Process); // restore Unused state (.Unused == 0)
                return null;
            };
            p.kstack = ks;
            p.kstack_top = ks + page_alloc.PAGE_SIZE;
            p.context.ra = @intCast(@intFromPtr(&forkret));
            p.context.sp = p.kstack_top - 16; // 16-byte aligned first frame
            return p;
        }
    }
    return null;
}

pub fn free(p: *Process) void {
    // Tear down user-space mappings + free leaf frames + free L0 tables
    // + free the L1 root. Kernel + MMIO leaves are preserved (G=1,
    // !PTE_U). vm.unmapUser walks the full pgdir; sz is a 3.E hint, not
    // used in 3.C.
    @import("vm.zig").unmapUser(p.pgdir, p.sz, .free_root);

    // Free the kernel stack page.
    page_alloc.free(p.kstack);

    // Zero the slot. State.Unused == 0 so the slot is immediately reusable.
    p.* = std.mem.zeroes(Process);
}

/// Used by fork's error-rollback path AFTER `alloc()` succeeded but
/// BEFORE `pgdir` was populated. Frees only the kstack and zeroes the
/// slot — does NOT call vm.unmapUser (which would walk an invalid pgdir).
pub fn freeKstackOnly(p: *Process) void {
    page_alloc.free(p.kstack);
    p.* = std.mem.zeroes(Process);
}

var next_pid: u32 = 1;
fn nextPid() u32 {
    const p = next_pid;
    next_pid += 1;
    return p;
}

// Initial entry for newly-allocated processes. Reached via the first
// swtch into the proc — its context.ra is set to this address by alloc().
//
// 3.B body: just call s_return_to_user(&cur.tf). We're already on the
// new proc's kstack (swtch loaded sp from context.sp = kstack_top - 16),
// so srets cleanly into U-mode. 3.C will add lock release here when
// locks arrive.
extern fn s_return_to_user(tf: *trap.TrapFrame) noreturn;

export fn forkret() callconv(.c) noreturn {
    // The scheduler set cpu.cur before swtch'ing into us; this assertion
    // catches any future bug that swtch's into a fresh proc with cpu.cur
    // still null.
    const p = cpu.cur orelse @import("kprintf.zig").panic("forkret: cpu.cur is null", .{});
    s_return_to_user(&p.tf);
}

/// Save current process state and switch to the scheduler context. The
/// scheduler picks the next runnable proc and swtch's back into us when
/// our turn comes. Until kmain wires `cpu.sched_context.ra` to the real
/// scheduler entry (Task 14), `sched()` is a no-op so the existing
/// single-proc boot path keeps working unchanged.
pub fn sched() void {
    if (cpu.sched_context.ra == 0) return;
    const p = cur();
    swtch(&p.context, &cpu.sched_context);
}

/// User-facing yield: mark current Runnable, switch to scheduler. Phase
/// 3.B's scheduler may pick the same proc back immediately, which is
/// fine — yield is just a "scheduling point".
pub fn yield() void {
    const p = cur();
    p.state = .Runnable;
    sched();
    p.state = .Running;
}
