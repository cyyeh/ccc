// tests/programs/kernel/kmain.zig — Phase 2 Plan 2.C kernel S-mode entry.
//
// Task 17 state: end-to-end U-mode entry. Maps user program, installs
// S-mode trap vector, writes satp, jumps to trampoline's s_return_to_user
// which sret's to user _start. Syscall handling is already in place from
// Tasks 10-12.
//
// Plan 2.C does NOT enable `sie.SSIE` yet — timer handling arrives in
// Tasks 18-20. This task intentionally runs without interrupts so the
// control flow for the happy path is unambiguous.

const std = @import("std");
const uart = @import("uart.zig");
const vm = @import("vm.zig");
const page_alloc = @import("page_alloc.zig");
const trap = @import("trap.zig");
const user_blob = @import("user_blob");

pub const USER_BLOB: []const u8 = user_blob.BLOB;

const SATP_MODE_SV32: u32 = 1 << 31;

pub export var the_tf: trap.TrapFrame = std.mem.zeroes(trap.TrapFrame);

extern fn s_trap_entry() void;
extern fn s_return_to_user(tf: *trap.TrapFrame) noreturn;

export fn kmain() callconv(.c) noreturn {
    page_alloc.init();
    const root_pa = vm.allocRoot();
    vm.mapKernelAndMmio(root_pa);
    vm.mapUser(root_pa, USER_BLOB.ptr, @intCast(USER_BLOB.len));

    // Initialize the user trap frame.
    the_tf = std.mem.zeroes(trap.TrapFrame);
    the_tf.sepc = vm.USER_TEXT_VA; // _start lives at VA 0x00010000
    the_tf.sp = vm.USER_STACK_TOP;

    // Install the S-mode trap vector and sscratch.
    const tf_addr: u32 = @intCast(@intFromPtr(&the_tf));
    const stvec_val: u32 = @intCast(@intFromPtr(&s_trap_entry));
    asm volatile (
        \\ csrw stvec, %[stv]
        \\ csrw sscratch, %[ss]
        :
        : [stv] "r" (stvec_val),
          [ss] "r" (tf_addr),
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

    // Flip on Sv32 translation.
    const satp_val: u32 = SATP_MODE_SV32 | (root_pa >> 12);
    asm volatile (
        \\ csrw satp, %[satp]
        \\ sfence.vma zero, zero
        :
        : [satp] "r" (satp_val),
        : .{ .memory = true }
    );

    // Jump to the trampoline's return-to-user path with a0 = &the_tf.
    s_return_to_user(&the_tf);
}

// Suppress "unused" on uart; uart is transitively used by syscall/kprintf
// but kmain also retains it for potential early-boot panic printing.
comptime {
    _ = uart;
}
