// tests/programs/kernel/kmain.zig — Phase 2 Plan 2.D kernel S-mode entry.
//
// Difference from 2.C: the standalone `the_tf` is gone. The trapframe is
// now the first field of `proc.the_process`, so sscratch / trampoline
// references point at the same memory via the new symbol `the_process`.
// Boot also routes through `sched.context_switch_to` for the initial
// satp write so Plan 3 has one code path to edit when the switch becomes
// non-trivial.

const std = @import("std");
const uart = @import("uart.zig");
const vm = @import("vm.zig");
const page_alloc = @import("page_alloc.zig");
const trap = @import("trap.zig");
const proc = @import("proc.zig");
const sched = @import("sched.zig");
const user_blob = @import("user_blob");

pub const USER_BLOB: []const u8 = user_blob.BLOB;

const SATP_MODE_SV32: u32 = 1 << 31;

extern fn s_trap_entry() void;
extern fn s_return_to_user(tf: *trap.TrapFrame) noreturn;

// Linker symbol: top of the 16 KB kernel stack. Used to populate
// the_process.kstack_top so the trampoline can switch to it on trap entry.
// (Plan 2.C's trampoline hard-codes `la sp, _kstack_top`; Plan 3 will
// want this per-process. 2.D stores it but trampoline still uses the
// linker symbol directly — wiring it through is Phase 3 scope.)
extern const _kstack_top: u8;

export fn kmain() callconv(.c) noreturn {
    page_alloc.init();
    const root_pa = vm.allocRoot();
    vm.mapKernelAndMmio(root_pa);
    vm.mapUser(root_pa, USER_BLOB.ptr, @intCast(USER_BLOB.len));

    // Initialize the single process.
    proc.the_process = std.mem.zeroes(proc.Process);
    proc.the_process.tf.sepc = vm.USER_TEXT_VA; // _start lives at VA 0x00010000
    proc.the_process.tf.sp = vm.USER_STACK_TOP;
    proc.the_process.satp = SATP_MODE_SV32 | (root_pa >> 12);
    proc.the_process.kstack_top = @intCast(@intFromPtr(&_kstack_top));
    proc.the_process.state = .Runnable;
    // ticks_observed, exit_code already zero from zeroes().

    // Install the S-mode trap vector and sscratch.
    const tf_addr: u32 = @intCast(@intFromPtr(&proc.the_process));
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

    // Flip on Sv32 translation via the scheduler's context-switch helper.
    // Plan 3 will reroute SSI + yield here too; 2.D only uses it from boot.
    sched.context_switch_to(&proc.the_process);

    // Jump to the trampoline's return-to-user path with a0 = &the_process.tf.
    // Since @offsetOf(Process, "tf") == 0, &the_process is the TrapFrame ptr.
    s_return_to_user(@ptrCast(&proc.the_process));
}

// Keep `uart` in the reachable set for potential early-boot panic printing.
comptime {
    _ = uart;
}
