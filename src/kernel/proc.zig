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
const vm = @import("vm.zig");

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
    vm.unmapUser(p.pgdir, p.sz, .free_root);

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

const SSTATUS_SIE: u32 = 1 << 1;

inline fn disableSie() void {
    asm volatile ("csrc sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SIE),
        : .{ .memory = true }
    );
}

/// xv6-style sleep on `chan` (a u32 used purely as identity).
///
/// In 3.C, sleep is only ever invoked from a syscall handler — and trap
/// entry sets `sstatus.SIE = 0` automatically — so the explicit
/// `disableSie()` here is defensive. Even so, we keep it: if 3.E (or
/// later) adds a non-trap sleeper (e.g., a kernel idle thread), the
/// call-site stays correct without revisiting sleep.
///
/// We deliberately do NOT re-enable SIE on return. The natural
/// `s_return_to_user → sret` rotation (`SPIE → SIE`) restores
/// `SIE = 1` for U-mode. Re-enabling SIE here would leak `SIE = 1`
/// back into the trap-handler's residual instructions (killed-check +
/// s_return_to_user), where a freshly-fired SSI could nest into
/// trap.zig and clobber the trapframe. (xv6's invariant: S-mode runs
/// with interrupts disabled; only U-mode runs with them on.)
pub fn sleep(chan: u32) void {
    const p = cur();

    disableSie();
    p.chan = chan;
    p.state = .Sleeping;
    sched();

    // We're back. Clear chan; SIE intentionally stays disabled.
    p.chan = 0;
}

/// Wake every Sleeping process that's blocked on `chan`. Idempotent —
/// non-Sleeping procs and unrelated chans are skipped silently. Caller
/// holds no special interrupt state; this is safe to call from both
/// process context (e.g. proc.exit waking parent) and ISR context
/// (3.D's block-device ISR waking the bufcache waiter).
pub fn wakeup(chan: u32) void {
    var i: u32 = 0;
    while (i < NPROC) : (i += 1) {
        const p = &ptable[i];
        if (p.state == .Sleeping and p.chan == chan) {
            p.state = .Runnable;
        }
    }
}

/// Set the kill flag on `pid`'s process. If the target is sleeping, also
/// flip it to Runnable so the killed-check on syscall return fires. No
/// effect if `pid` is unknown or refers to an Unused slot. Returns true
/// iff a matching slot was found.
pub fn kill(pid: u32) bool {
    var i: u32 = 0;
    while (i < NPROC) : (i += 1) {
        const p = &ptable[i];
        if (p.pid == pid and p.state != .Unused) {
            p.killed = 1;
            if (p.state == .Sleeping) p.state = .Runnable;
            return true;
        }
    }
    return false;
}

const SATP_MODE_SV32: u32 = 1 << 31;

/// Full-AS fork. Returns child pid in parent (positive), 0 in child,
/// or -1 on failure. The child resumes at the same instruction as the
/// parent's post-ecall (s_trap_dispatch advanced sepc by 4 BEFORE
/// dispatching, so child.tf.sepc inherits the post-advance value).
pub fn fork() i32 {
    const parent = cur();

    const child = alloc() orelse return -1;

    // Allocate a root pgdir and map kernel + MMIO into it.
    const new_root = vm.allocRoot() orelse {
        freeKstackOnly(child);
        return -1;
    };
    vm.mapKernelAndMmio(new_root);

    // Copy user .text/.data/.bss/heap (VA 0..sz).
    vm.copyUvm(parent.pgdir, new_root, parent.sz) catch {
        vm.unmapUser(new_root, parent.sz, .free_root);
        freeKstackOnly(child);
        return -1;
    };

    // Copy the user stack (above sz; copyUvm doesn't reach it).
    vm.copyUserStack(parent.pgdir, new_root) catch {
        vm.unmapUser(new_root, vm.USER_STACK_TOP, .free_root);
        freeKstackOnly(child);
        return -1;
    };

    // Wire process state. tf is copied wholesale (including sepc), then
    // overridden so child sees a0 = 0 from the same ecall. Parent's tf
    // is untouched here; the syscall dispatcher writes child.pid into
    // parent.tf.a0 on return.
    child.pgdir = new_root;
    child.satp = SATP_MODE_SV32 | (new_root >> 12);
    child.sz = parent.sz;
    child.tf = parent.tf;
    child.tf.a0 = 0;
    child.parent = parent;
    @memcpy(&child.name, &parent.name);
    child.state = .Runnable;

    return @as(i32, @intCast(child.pid));
}

/// Full process exit. Reparents children to PID 1 (init), marks self
/// Zombie, wakes the parent (which may be sleeping in wait()). Never
/// returns. PID 1's exit additionally prints the canonical
/// "ticks observed: N\n" trailer and halts the emulator (preserves
/// e2e-kernel and e2e-multiproc-stub regression behavior).
pub fn exit(status: i32) noreturn {
    const p = cur();

    // Reparent every child of `p` to PID 1 (init). PID 1 is hard-wired
    // to slot 0; if 3.D ever changes that, this lookup needs to scan
    // ptable for pid==1.
    const init_proc = &ptable[0];
    var i: u32 = 0;
    while (i < NPROC) : (i += 1) {
        const c = &ptable[i];
        if (c.parent == p) c.parent = init_proc;
    }

    p.xstate = status;
    p.state = .Zombie;

    // Wake the parent if it's sleeping in wait() (parent sleeps on its
    // own pointer). Guard against PID 1's null parent.
    if (p.parent) |par| {
        wakeup(@as(u32, @intCast(@intFromPtr(par))));
    }

    // PID 1 special-case: same trailer + halt as Phase 2 / 3.B.
    // Preserves e2e-kernel and e2e-multiproc-stub byte-for-byte.
    if (p.pid == 1) {
        kprintf.print("ticks observed: {d}\n", .{p.ticks_observed});
        const halt: *volatile u8 = @ptrFromInt(0x00100000);
        halt.* = @as(u8, @truncate(@as(u32, @bitCast(status)) & 0xFF));
        while (true) asm volatile ("wfi");
    }

    // Non-PID-1 exit: yield forever; scheduler will skip Zombies; parent
    // will reap us in wait(). The loop is defensive — if a future
    // scheduler bug picks us anyway, we just yield again.
    while (true) sched();
}

const SSTATUS_SUM: u32 = 1 << 18;

inline fn setSum() void {
    asm volatile ("csrs sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SUM),
        : .{ .memory = true }
    );
}

inline fn clearSum() void {
    asm volatile ("csrc sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SUM),
        : .{ .memory = true }
    );
}

/// xv6-style wait. Returns the harvested child pid, or -1 if `cur` has
/// no children. Sleeps if children exist but none are Zombie.
///
/// `status_user_va`: if non-zero, the harvested xstate is written there
/// (via SUM=1) before we return.
pub fn wait(status_user_va: u32) i32 {
    const me = cur();
    while (true) {
        var has_children = false;
        var i: u32 = 0;
        while (i < NPROC) : (i += 1) {
            const c = &ptable[i];
            if (c.parent != me) continue;
            if (c.state == .Unused) continue;
            has_children = true;
            if (c.state == .Zombie) {
                if (status_user_va != 0) {
                    setSum();
                    const sp: *volatile i32 = @ptrFromInt(status_user_va);
                    sp.* = c.xstate;
                    clearSum();
                }
                const pid = c.pid;
                free(c);
                return @as(i32, @intCast(pid));
            }
        }
        if (!has_children) return -1;
        sleep(@as(u32, @intCast(@intFromPtr(me))));
    }
}

const elfload = @import("elfload.zig");
const boot_config = @import("boot_config");

const MAX_PATH: u32 = 256;
const MAX_ARGS: u32 = 8;
const MAX_ARG_LEN: u32 = 64;

/// Copy a NUL-terminated user string into `buf`. Returns the slice up
/// to (but not including) the NUL. Returns null on truncation (string
/// longer than buf) or NUL not found within MAX_PATH bytes.
fn copyStrFromUser(user_va: u32, buf: []u8) ?[]u8 {
    setSum();
    defer clearSum();
    var i: u32 = 0;
    while (i < buf.len) : (i += 1) {
        const p: *const volatile u8 = @ptrFromInt(user_va + i);
        const c = p.*;
        buf[i] = c;
        if (c == 0) return buf[0..i];
    }
    return null;
}

/// Copy the argv pointer array + the strings it points to. argv_user_va
/// is the user VA of a `[*:null]?[*:0]u8`-style array. Returns argc on
/// success, null on overflow / truncation.
fn copyArgvFromUser(
    argv_user_va: u32,
    arg_storage: *[MAX_ARGS][MAX_ARG_LEN]u8,
    arg_lens: *[MAX_ARGS]u32,
) ?u32 {
    if (argv_user_va == 0) {
        return 0;
    }
    var argc: u32 = 0;
    while (argc < MAX_ARGS) : (argc += 1) {
        setSum();
        const slot: *const volatile u32 = @ptrFromInt(argv_user_va + argc * 4);
        const arg_ptr = slot.*;
        clearSum();
        if (arg_ptr == 0) return argc;
        const slice = copyStrFromUser(arg_ptr, &arg_storage[argc]) orelse return null;
        arg_lens[argc] = @intCast(slice.len);
    }
    // Hit MAX_ARGS without seeing the NULL terminator — refuse the call.
    return null;
}

/// In-place exec. Build new user AS in scratch, then commit by tearing
/// down the old AS and pointing cur at the new one. On any failure
/// before commit, the calling proc is untouched and we return -1.
pub fn exec(path_user_va: u32, argv_user_va: u32) i32 {
    const PAGE_SIZE = vm.PAGE_SIZE;

    // 1. Copy path string out of user space.
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = copyStrFromUser(path_user_va, &path_buf) orelse return -1;

    // 2. Copy argv strings out of user space (before old AS is torn down).
    var arg_storage: [MAX_ARGS][MAX_ARG_LEN]u8 = undefined;
    var arg_lens: [MAX_ARGS]u32 = undefined;
    const argc = copyArgvFromUser(argv_user_va, &arg_storage, &arg_lens) orelse return -1;

    // 3. Look up the embedded blob.
    const blob = boot_config.lookupBlob(path) orelse return -1;

    // 4. Build new pgdir + map kernel/MMIO.
    const new_root = vm.allocRoot() orelse return -1;
    vm.mapKernelAndMmio(new_root);

    // 5. Load PT_LOADs into new pgdir.
    const allocFn = struct {
        fn f() ?u32 {
            return page_alloc.alloc();
        }
    }.f;
    const mapFn = struct {
        fn f(pgd: u32, va: u32, pa: u32, flags: u32) void {
            vm.mapPage(pgd, va, pa, flags);
        }
    }.f;
    const lookupFn = struct {
        fn f(pgd: u32, va: u32) ?u32 {
            return vm.lookupPA(pgd, va);
        }
    }.f;
    const entry = elfload.load(blob, new_root, allocFn, mapFn, lookupFn, vm.USER_RWX) catch {
        vm.unmapUser(new_root, 0, .free_root);
        return -1;
    };

    // 6. Allocate user stack in new pgdir.
    if (!vm.mapUserStack(new_root)) {
        vm.unmapUser(new_root, vm.USER_TEXT_VA + 0x10000, .free_root);
        return -1;
    }

    // 7. Build the System-V argv tail at the top of the new user stack.
    //
    // Layout (low -> high VA):
    //   [argc:u32] [argv[0]:u32] ... [argv[argc-1]:u32] [NULL:u32]
    //   [str0\0] [str1\0] ... [strN-1\0] [pad to 16-byte align]
    //
    // We place this so the final byte sits at USER_STACK_TOP - 1, then
    // sp = argc address (lowest byte of the tail).

    var strings_total: u32 = 0;
    var k: u32 = 0;
    while (k < argc) : (k += 1) strings_total += arg_lens[k] + 1;

    const ptr_array_bytes: u32 = 4 + (argc + 1) * 4; // argc + (argc+1)*ptr
    const tail_unaligned = ptr_array_bytes + strings_total;
    const tail_size = (tail_unaligned + 15) & ~@as(u32, 15);

    const sp_user_va = vm.USER_STACK_TOP - tail_size;

    // The tail spans at most 2 pages (USER_STACK_PAGES = 2; tail_size
    // bounded by ptr_array_bytes (≤ 40) + strings_total (≤ 8*65 = 520)
    // = 560 bytes, well under one page). For simplicity we still do
    // per-byte writes via lookupPA + page-offset arithmetic.

    var off: u32 = 0;
    while (off < tail_size) : (off += 1) {
        const va = sp_user_va + off;
        const page_va = va & ~@as(u32, PAGE_SIZE - 1);
        const page_off = va - page_va;
        const pa = vm.lookupPA(new_root, page_va) orelse {
            // Should never happen — mapUserStack just mapped both stack pages.
            vm.unmapUser(new_root, vm.USER_TEXT_VA + 0x10000, .free_root);
            return -1;
        };
        const dst: *volatile u8 = @ptrFromInt(pa + page_off);
        dst.* = 0; // pre-zero
    }

    // Helper: write a u32 at sp_user_va + off via PA lookup.
    const writeU32 = struct {
        fn f(root: u32, sp_va: u32, byte_off: u32, value: u32) void {
            const va_lo = sp_va + byte_off;
            const PS: u32 = 4096;
            const page_va = va_lo & ~@as(u32, PS - 1);
            const page_off = va_lo - page_va;
            const pa = @import("vm.zig").lookupPA(root, page_va).?;
            const dst: *volatile u32 = @ptrFromInt(pa + page_off);
            dst.* = value;
        }
    }.f;

    // Helper: write a byte at sp_user_va + off via PA lookup.
    const writeByte = struct {
        fn f(root: u32, sp_va: u32, byte_off: u32, value: u8) void {
            const va_lo = sp_va + byte_off;
            const PS: u32 = 4096;
            const page_va = va_lo & ~@as(u32, PS - 1);
            const page_off = va_lo - page_va;
            const pa = @import("vm.zig").lookupPA(root, page_va).?;
            const dst: *volatile u8 = @ptrFromInt(pa + page_off);
            dst.* = value;
        }
    }.f;

    // Write argc.
    writeU32(new_root, sp_user_va, 0, argc);

    // Compute and write argv[i] pointers (USER VAs into the strings region).
    var strings_off: u32 = ptr_array_bytes;
    var ai: u32 = 0;
    while (ai < argc) : (ai += 1) {
        const arg_va = sp_user_va + strings_off;
        writeU32(new_root, sp_user_va, 4 + ai * 4, arg_va);
        // Copy the bytes of arg_storage[ai][0..arg_lens[ai]] + NUL.
        var bi: u32 = 0;
        while (bi < arg_lens[ai]) : (bi += 1) {
            writeByte(new_root, sp_user_va, strings_off + bi, arg_storage[ai][bi]);
        }
        writeByte(new_root, sp_user_va, strings_off + arg_lens[ai], 0);
        strings_off += arg_lens[ai] + 1;
    }
    // Final NULL pointer in argv array.
    writeU32(new_root, sp_user_va, 4 + argc * 4, 0);

    // 8. Commit.
    const me = cur();
    const old_pgdir = me.pgdir;
    const old_sz = me.sz;

    me.pgdir = new_root;
    me.satp = SATP_MODE_SV32 | (new_root >> 12);
    me.sz = vm.USER_TEXT_VA + 0x10000; // 3.E will refine to real high-water
    me.tf.sepc = entry;
    me.tf.sp = sp_user_va;
    me.tf.a1 = sp_user_va + 4; // argv pointer is just past argc
    // Do NOT touch tf.a0 — the syscall dispatch arm overwrites it with
    // exec's return value below. We return argc so a0 lands as argc,
    // satisfying the System-V `_start(argc, argv)` calling convention.

    // Switch to new translation; the s_return_to_user path will run on it.
    asm volatile (
        \\ csrw satp, %[s]
        \\ sfence.vma zero, zero
        :
        : [s] "r" (me.satp),
        : .{ .memory = true }
    );

    // Tear down the old AS now that we're committed.
    vm.unmapUser(old_pgdir, old_sz, .free_root);

    return @as(i32, @intCast(argc));
}
