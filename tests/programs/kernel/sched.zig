// tests/programs/kernel/sched.zig — Phase 2 Plan 2.D scheduler stub.
//
// Phase 2 has one process, so schedule() is a constant function. The real
// purpose of this file is to exercise the "pick + switch" code path — the
// satp write and sfence.vma in context_switch_to — so Phase 3 can slot in
// a real picker by only changing schedule() and how context_switch_to is
// reached (e.g., only call it when the pick actually differs).
//
// Plan 2.D callers:
//   - kmain.zig: boot tail calls context_switch_to(&the_process) right
//     before jumping to s_return_to_user.
//   - trap.zig (SSI branch): calls schedule() after incrementing ticks.
//   - syscall.zig (sys_yield): calls schedule().
//
// Neither the SSI branch nor sys_yield call context_switch_to — with one
// process, satp is already correct. Adding a redundant switch there would
// make the hot path ~20 cycles slower for no benefit; Plan 3 will reinstate
// when the picker can return a new process.

const proc = @import("proc.zig");

pub fn schedule() *proc.Process {
    return &proc.the_process;
}

pub fn context_switch_to(p: *proc.Process) void {
    asm volatile (
        \\ csrw satp, %[satp]
        \\ sfence.vma zero, zero
        :
        : [satp] "r" (p.satp),
        : .{ .memory = true }
    );
}
