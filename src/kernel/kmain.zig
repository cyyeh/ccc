// src/kernel/kmain.zig — Phase 3.B kernel S-mode entry.
//
// Phase 3.B: kmain allocates PID 1 via proc.alloc(), builds its address
// space with elfload.load(), marks it Runnable, then switches into
// scheduler(). No more single-process tail-call to s_return_to_user;
// the scheduler + forkret path takes over from here.

const std = @import("std");
const uart = @import("uart.zig");
const vm = @import("vm.zig");
const page_alloc = @import("page_alloc.zig");
const proc = @import("proc.zig");
const sched = @import("sched.zig");
const elfload = @import("elfload.zig");
const kprintf = @import("kprintf.zig");
const boot_config = @import("boot_config");
const plic = @import("plic.zig");
const block = @import("block.zig");
const bufcache = @import("fs/bufcache.zig");
const inode = @import("fs/inode.zig");
const file = @import("file.zig");
const console = @import("console.zig");

const SATP_MODE_SV32: u32 = 1 << 31;

extern fn s_trap_entry() void;

// Keep `uart` in the reachable set for early-boot panic printing.
comptime {
    _ = uart;
}

export fn kmain() callconv(.c) noreturn {
    page_alloc.init();
    proc.cpuInit();

    if (boot_config.FS_DEMO) {
        // FS-mode boot: bufcache + inode cache up; PLIC ready for IRQ #1
        // (block); exec /bin/init from disk into PID 1's AS.
        bufcache.init();
        inode.init();

        plic.setPriority(plic.IRQ_BLOCK, 1);
        plic.enable(plic.IRQ_BLOCK);
        plic.setThreshold(0);
        plic.setPriority(plic.IRQ_UART_RX, 1);
        plic.enable(plic.IRQ_UART_RX);
        // (threshold already set to 0 above; same threshold gates both sources)
        console.init();

        const init_p = proc.alloc() orelse kprintf.panic("kmain: alloc init", .{});
        @memcpy(init_p.name[0..4], "init");
        const init_root = vm.allocRoot() orelse kprintf.panic("kmain: allocRoot init", .{});
        init_p.pgdir = init_root;
        init_p.satp = SATP_MODE_SV32 | (init_root >> 12);
        vm.mapKernelAndMmio(init_root);
        init_p.sz = 0;
        init_p.cwd = 0; // lazy-root

        // Phase 3.E: initialize file table + install console fds 0/1/2 onto
        // init so /bin/init inherits stdin/stdout/stderr.
        file.init();

        const console_fidx = file.alloc() orelse kprintf.panic("kmain: file.alloc console", .{});
        file.ftable[console_fidx].type = .Console;
        file.ftable[console_fidx].ip = null;
        file.ftable[console_fidx].off = 0;
        // alloc gave us ref_count=1; bring to 3 (one per fd 0/1/2).
        _ = file.dup(console_fidx);
        _ = file.dup(console_fidx);
        init_p.ofile[0] = console_fidx;
        init_p.ofile[1] = console_fidx;
        init_p.ofile[2] = console_fidx;

        // Install S-mode trap setup BEFORE exec — exec calls block.read
        // which sleeps, which transitively requires the IRQ + trap path
        // to be ready.
        const stvec_val_fs: u32 = @intCast(@intFromPtr(&s_trap_entry));
        const sscratch_val_fs: u32 = @intCast(@intFromPtr(init_p));
        asm volatile (
            \\ csrw stvec, %[stv]
            \\ csrw sscratch, %[ss]
            :
            : [stv] "r" (stvec_val_fs),
              [ss] "r" (sscratch_val_fs),
            : .{ .memory = true });
        const SIE_BITS_FS: u32 = (1 << 1) | (1 << 9); // SSIE | SEIE
        asm volatile ("csrs sie, %[b]"
            :
            : [b] "r" (SIE_BITS_FS),
            : .{ .memory = true });
        const SSTATUS_SPP_FS: u32 = 1 << 8;
        const SSTATUS_SPIE_FS: u32 = 1 << 5;
        asm volatile (
            \\ csrc sstatus, %[spp]
            \\ csrs sstatus, %[spie]
            :
            : [spp] "r" (SSTATUS_SPP_FS),
              [spie] "r" (SSTATUS_SPIE_FS),
            : .{ .memory = true });

        // Set up sched_context BEFORE exec so that proc.sleep (called by
        // bufcache.bread inside exec.readi) can actually yield to the
        // scheduler instead of busy-spinning. Without this, the no-op
        // sched() returns immediately and the SIE=0 spin never lets the
        // block IRQ fire — deadlock.
        proc.cpu.sched_context.ra = @intCast(@intFromPtr(&sched.scheduler));
        proc.cpu.sched_context.sp = proc.cpu.sched_stack_top;

        // Make cur() return PID 1 so exec writes into its trapframe.
        proc.cpu.cur = init_p;

        // exec("/bin/init", NULL).
        const init_path = "/bin/init\x00";
        const path_va = @as(u32, @intCast(@intFromPtr(&init_path[0])));
        const rc = proc.exec(path_va, 0);
        if (rc < 0) kprintf.panic("kmain: exec /bin/init failed", .{});

        // exec ran on init_p's stack and called proc.sleep, leaving
        // init_p.context pointing inside sleep(). Re-arm it to forkret
        // so the next scheduler swtch enters via the trapframe + sret
        // path, not by re-running sleep's epilogue on a stale stack.
        init_p.context = std.mem.zeroes(proc.Context);
        init_p.context.ra = @intCast(@intFromPtr(&proc.forkret));
        init_p.context.sp = init_p.kstack_top - 16;
        init_p.state = .Runnable;
        proc.cpu.cur = null;

        var bootstrap_fs: proc.Context = std.mem.zeroes(proc.Context);
        proc.swtch(&bootstrap_fs, &proc.cpu.sched_context);
        unreachable;
    }

    if (boot_config.FORK_DEMO) {
        const init_p = proc.alloc() orelse kprintf.panic("kmain: alloc init", .{});
        @memcpy(init_p.name[0..4], "init");
        const init_root = vm.allocRoot() orelse kprintf.panic("kmain: allocRoot init", .{});
        init_p.pgdir = init_root;
        init_p.satp = SATP_MODE_SV32 | (init_root >> 12);
        vm.mapKernelAndMmio(init_root);

        const allocFn_fork = struct {
            fn f() ?u32 {
                return page_alloc.alloc();
            }
        }.f;
        const mapFn_fork = struct {
            fn f(pgdir: u32, va: u32, pa: u32, flags: u32) void {
                vm.mapPage(pgdir, va, pa, flags);
            }
        }.f;
        const lookupFn_fork = struct {
            fn f(pgdir: u32, va: u32) ?u32 {
                return vm.lookupPA(pgdir, va);
            }
        }.f;

        const entry_init = elfload.load(boot_config.INIT_ELF, init_root, allocFn_fork, mapFn_fork, lookupFn_fork, vm.USER_RWX) catch |err|
            kprintf.panic("elfload init: {s}", .{@errorName(err)});
        if (!vm.mapUserStack(init_root)) kprintf.panic("mapUserStack init", .{});
        init_p.tf.sepc = entry_init;
        init_p.tf.sp = vm.USER_STACK_TOP;
        init_p.sz = vm.USER_TEXT_VA + 0x10000;
        init_p.state = .Runnable;

        // Phase 3.E: initialize file table + install console fds 0/1/2 onto
        // init so /bin/init inherits stdin/stdout/stderr.
        file.init();

        const console_fidx = file.alloc() orelse kprintf.panic("kmain: file.alloc console", .{});
        file.ftable[console_fidx].type = .Console;
        file.ftable[console_fidx].ip = null;
        file.ftable[console_fidx].off = 0;
        // alloc gave us ref_count=1; bring to 3 (one per fd 0/1/2).
        _ = file.dup(console_fidx);
        _ = file.dup(console_fidx);
        init_p.ofile[0] = console_fidx;
        init_p.ofile[1] = console_fidx;
        init_p.ofile[2] = console_fidx;

        // Skip the single + multi setup blocks below — install stvec + sscratch
        // + sstatus and jump into scheduler() the same way they do.
        const stvec_val_fork: u32 = @intCast(@intFromPtr(&s_trap_entry));
        const sscratch_val_fork: u32 = @intCast(@intFromPtr(init_p));
        asm volatile (
            \\ csrw stvec, %[stv]
            \\ csrw sscratch, %[ss]
            :
            : [stv] "r" (stvec_val_fork),
              [ss] "r" (sscratch_val_fork),
            : .{ .memory = true });

        const SIE_BITS_F: u32 = (1 << 1) | (1 << 9); // SSIE | SEIE
        asm volatile ("csrs sie, %[b]"
            :
            : [b] "r" (SIE_BITS_F),
            : .{ .memory = true });

        const SSTATUS_SPP_F: u32 = 1 << 8;
        const SSTATUS_SPIE_F: u32 = 1 << 5;
        asm volatile (
            \\ csrc sstatus, %[spp]
            \\ csrs sstatus, %[spie]
            :
            : [spp] "r" (SSTATUS_SPP_F),
              [spie] "r" (SSTATUS_SPIE_F),
            : .{ .memory = true });

        var bootstrap_fork: proc.Context = std.mem.zeroes(proc.Context);
        proc.cpu.sched_context.ra = @intCast(@intFromPtr(&sched.scheduler));
        proc.cpu.sched_context.sp = proc.cpu.sched_stack_top;
        proc.swtch(&bootstrap_fork, &proc.cpu.sched_context);
        unreachable;
    }

    // Allocate PID 1.
    const pid1 = proc.alloc() orelse kprintf.panic("kmain: proc.alloc PID 1", .{});
    @memcpy(pid1.name[0..4], "init");

    // Build PID 1's address space.
    const root = vm.allocRoot() orelse kprintf.panic("kmain: allocRoot PID 1", .{});
    pid1.pgdir = root;
    pid1.satp = SATP_MODE_SV32 | (root >> 12);
    vm.mapKernelAndMmio(root);

    const allocFn = struct {
        fn f() ?u32 {
            return page_alloc.alloc();
        }
    }.f;
    const mapFn = struct {
        fn f(pgdir: u32, va: u32, pa: u32, flags: u32) void {
            vm.mapPage(pgdir, va, pa, flags);
        }
    }.f;
    const lookupFn = struct {
        fn f(pgdir: u32, va: u32) ?u32 {
            return vm.lookupPA(pgdir, va);
        }
    }.f;

    const entry = elfload.load(boot_config.USERPROG_ELF, root, allocFn, mapFn, lookupFn, vm.USER_RWX) catch |err| {
        kprintf.panic("elfload PID 1: {s}", .{@errorName(err)});
    };
    if (!vm.mapUserStack(root)) kprintf.panic("mapUserStack PID 1", .{});

    pid1.tf.sepc = entry;
    pid1.tf.sp = vm.USER_STACK_TOP;
    pid1.sz = vm.USER_TEXT_VA + 0x10000; // initial brk above text region
    pid1.state = .Runnable;

    // Phase 3.E: sysWrite routes through file.write, so each user proc's
    // ofile[0..2] must point at a Console-typed file entry. Without this
    // wiring, write(1, ...) returns -1 and the user payload's "hello from
    // u-mode" output disappears. Install one shared console entry; PID 1
    // gets fds 0/1/2 dup'd onto it, and (if MULTI_PROC) PID 2 gets the
    // same.
    file.init();
    const console_fidx = file.alloc() orelse kprintf.panic("kmain: file.alloc console", .{});
    file.ftable[console_fidx].type = .Console;
    file.ftable[console_fidx].ip = null;
    file.ftable[console_fidx].off = 0;
    _ = file.dup(console_fidx);
    _ = file.dup(console_fidx);
    pid1.ofile[0] = console_fidx;
    pid1.ofile[1] = console_fidx;
    pid1.ofile[2] = console_fidx;

    // Optional: PID 2.
    if (boot_config.MULTI_PROC) {
        const pid2 = proc.alloc() orelse kprintf.panic("kmain: alloc PID 2", .{});
        @memcpy(pid2.name[0..5], "init2");
        const root2 = vm.allocRoot() orelse kprintf.panic("kmain: allocRoot PID 2", .{});
        pid2.pgdir = root2;
        pid2.satp = SATP_MODE_SV32 | (root2 >> 12);
        vm.mapKernelAndMmio(root2);
        const entry2 = elfload.load(boot_config.USERPROG2_ELF, root2, allocFn, mapFn, lookupFn, vm.USER_RWX) catch |err| {
            kprintf.panic("elfload PID 2: {s}", .{@errorName(err)});
        };
        if (!vm.mapUserStack(root2)) kprintf.panic("mapUserStack PID 2", .{});
        pid2.tf.sepc = entry2;
        pid2.tf.sp = vm.USER_STACK_TOP;
        pid2.sz = vm.USER_TEXT_VA + 0x10000;
        pid2.state = .Runnable;

        _ = file.dup(console_fidx);
        _ = file.dup(console_fidx);
        _ = file.dup(console_fidx);
        pid2.ofile[0] = console_fidx;
        pid2.ofile[1] = console_fidx;
        pid2.ofile[2] = console_fidx;
    }

    // Install the S-mode trap vector + sscratch (will be overwritten on
    // each schedule, but a non-null initial value matters in case the
    // first schedule races a tick — defense-in-depth).
    const stvec_val: u32 = @intCast(@intFromPtr(&s_trap_entry));
    const sscratch_val: u32 = @intCast(@intFromPtr(pid1));
    asm volatile (
        \\ csrw stvec, %[stv]
        \\ csrw sscratch, %[ss]
        :
        : [stv] "r" (stvec_val),
          [ss] "r" (sscratch_val),
        : .{ .memory = true });

    // sie.SSIE for forwarded timer ticks; sie.SEIE for PLIC externals (3.D).
    const SIE_BITS: u32 = (1 << 1) | (1 << 9); // SSIE | SEIE
    asm volatile ("csrs sie, %[b]"
        :
        : [b] "r" (SIE_BITS),
        : .{ .memory = true });

    // sstatus: SPP=0, SPIE=1 — for whoever sret's first.
    const SSTATUS_SPP: u32 = 1 << 8;
    const SSTATUS_SPIE: u32 = 1 << 5;
    asm volatile (
        \\ csrc sstatus, %[spp]
        \\ csrs sstatus, %[spie]
        :
        : [spp] "r" (SSTATUS_SPP),
          [spie] "r" (SSTATUS_SPIE),
        : .{ .memory = true });

    // Switch onto the scheduler stack and jump into scheduler(). swtch
    // saves the (irrelevant) caller context to a throwaway and jumps
    // into scheduler() with sp = sched_stack_top.
    var bootstrap: proc.Context = std.mem.zeroes(proc.Context);
    proc.cpu.sched_context.ra = @intCast(@intFromPtr(&sched.scheduler));
    proc.cpu.sched_context.sp = proc.cpu.sched_stack_top;
    proc.swtch(&bootstrap, &proc.cpu.sched_context);
    unreachable;
}
