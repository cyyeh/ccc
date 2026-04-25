// tests/programs/kernel/sched.zig — Phase 3.B scheduler stub.
//
// schedule() returns proc.cur() (currently always &ptable[0]). Task 9
// will swap in the real round-robin loop and wire in CPU-local state so
// the picker can select among Runnable processes.
//
// Phase 3.B callers:
//   - kmain.zig: boot tail-calls context_switch_to(&ptable[0]) before
//     jumping to s_return_to_user (initial satp write).
//   - trap.zig (SSI branch): calls schedule() after incrementing ticks.
//   - syscall.zig (sys_yield): calls schedule().
//
// context_switch_to is only called from boot; the SSI and yield paths
// skip it because satp is already correct with a single process. Task 9
// will reinstate it when the picker can return a different process.

const proc = @import("proc.zig");

pub fn schedule() *proc.Process {
    return proc.cur();
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
