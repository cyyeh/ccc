// tests/programs/kernel/kmain.zig — Phase 3.B kernel S-mode entry.
//
// Phase 3.B: the singleton `the_process` is replaced by `ptable[0]`.
// sscratch / trampoline references now point at &ptable[0], whose first
// field is `tf` (offset 0), preserving the trampoline invariant.
// Task 9: satp written inline before s_return_to_user; sched import removed.

const std = @import("std");
const uart = @import("uart.zig");
const vm = @import("vm.zig");
const page_alloc = @import("page_alloc.zig");
const kprintf = @import("kprintf.zig");
const trap = @import("trap.zig");
const proc = @import("proc.zig");
const boot_config = @import("boot_config");
const elfload = @import("elfload.zig");
pub const USERPROG_ELF: []const u8 = boot_config.USERPROG_ELF;

const SATP_MODE_SV32: u32 = 1 << 31;

extern fn s_trap_entry() void;
extern fn s_return_to_user(tf: *trap.TrapFrame) noreturn;

// Linker symbol: top of the 16 KB kernel stack. Used to populate
// ptable[0].kstack_top so the trampoline can switch to it on trap entry.
// (Trampoline still uses `la sp, _kstack_top` directly; Task 5 will
// wire kstack_top through the Process struct for per-process stacks.)
extern const _kstack_top: u8;

export fn kmain() callconv(.c) noreturn {
    page_alloc.init();
    proc.cpuInit();
    const root_pa = vm.allocRoot() orelse kprintf.panic("allocRoot OOM", .{});
    vm.mapKernelAndMmio(root_pa);
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
    const entry = elfload.load(USERPROG_ELF, root_pa, allocFn, mapFn, lookupFn, vm.USER_RWX) catch |err| {
        kprintf.panic("elfload PID 1 failed: {s}", .{@errorName(err)});
    };
    if (!vm.mapUserStack(root_pa)) kprintf.panic("mapUserStack PID 1 failed", .{});

    // Initialize the single process.
    const p = &proc.ptable[0];
    p.* = std.mem.zeroes(proc.Process);
    p.tf.sepc = entry;
    p.tf.sp = vm.USER_STACK_TOP;
    p.satp = SATP_MODE_SV32 | (root_pa >> 12);
    p.pgdir = root_pa;
    p.kstack_top = @intCast(@intFromPtr(&_kstack_top));
    p.kstack = p.kstack_top - 0x4000; // Phase 2 has a 16 KB linker-supplied stack
    p.state = .Runnable;
    p.pid = 1;
    @memcpy(p.name[0..4], "init");

    // Install the S-mode trap vector and sscratch.
    const tf_addr: u32 = @intCast(@intFromPtr(&proc.ptable[0]));
    const stvec_val: u32 = @intCast(@intFromPtr(&s_trap_entry));
    asm volatile (
        \\ csrw stvec, %[stv]
        \\ csrw sscratch, %[ss]
        :
        : [stv] "r" (stvec_val),
          [ss] "r" (tf_addr),
        : .{ .memory = true }
    );

    // Enable sie.SSIE so forwarded timer ticks deliver in S-mode.
    // (U-mode delivery is always on as a consequence of lower-privilege
    // semantics; this bit matters for any S-mode-originated SSI once the
    // kernel grows nested structures — defense-in-depth for Plan 3+.)
    const SIE_SSIE: u32 = 1 << 1;
    asm volatile ("csrs sie, %[b]"
        :
        : [b] "r" (SIE_SSIE),
        : .{ .memory = true }
    );

    // Configure sstatus.SPP = 0 (U) and sstatus.SPIE = 1 so sret lands
    // in U with SIE=1 after the privilege transition.
    //   SPP is bit 8, SPIE is bit 5, SIE is bit 1.
    const SSTATUS_SPP: u32 = 1 << 8;
    const SSTATUS_SPIE: u32 = 1 << 5;
    asm volatile (
        \\ csrc sstatus, %[spp]
        \\ csrs sstatus, %[spie]
        :
        : [spp] "r" (SSTATUS_SPP),
          [spie] "r" (SSTATUS_SPIE),
        : .{ .memory = true }
    );

    // Flip on Sv32 translation inline (Task 9: sched.context_switch_to removed).
    asm volatile (
        \\ csrw satp, %[s]
        \\ sfence.vma zero, zero
        :
        : [s] "r" (proc.ptable[0].satp),
        : .{ .memory = true }
    );

    // Jump to the trampoline's return-to-user path with a0 = &ptable[0].tf.
    // Since @offsetOf(Process, "tf") == 0, &ptable[0] is the TrapFrame ptr.
    s_return_to_user(@ptrCast(&proc.ptable[0]));
}

// Keep `uart` in the reachable set for potential early-boot panic printing.
comptime {
    _ = uart;
}
