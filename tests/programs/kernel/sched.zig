// tests/programs/kernel/sched.zig — Phase 3.B round-robin scheduler.
//
// Runs forever on cpu.sched_stack_top. Loop:
//   1. Scan ptable for the first Runnable proc.
//   2. If found: cpu.cur = p; p.state = Running; csrw satp from p.satp;
//      sfence.vma; swtch into p.context.
//   3. On return (p yielded back), cpu.cur = null. Continue.
//   4. If no Runnable proc and at least one Embryo or Sleeping or Running
//      exists, loop. (We'll WFI here in 3.D when there's something to wait
//      on; for now the timer tick keeps poking us.)
//   5. If every slot is Unused or Zombie, halt the system via the halt
//      MMIO with status from the most-recently-zombied proc (or 0).

const proc = @import("proc.zig");

pub fn scheduler() noreturn {
    var start: u32 = 0; // round-robin start index: advances past last-picked slot
    while (true) {
        var picked: ?*proc.Process = null;
        var any_alive = false;
        var last_xstatus: i32 = 0;

        var j: u32 = 0;
        while (j < proc.NPROC) : (j += 1) {
            const i = (start + j) % proc.NPROC;
            const p = &proc.ptable[i];
            switch (p.state) {
                .Runnable => {
                    picked = p;
                    start = (i + 1) % proc.NPROC; // next scan starts after this slot
                    any_alive = true;
                    break;
                },
                .Embryo, .Sleeping, .Running => any_alive = true,
                .Zombie => {
                    last_xstatus = p.xstate;
                    any_alive = true; // a zombie is still alive until reaped
                },
                .Unused => {},
            }
        }

        if (picked) |p| {
            proc.cpu.cur = p;
            p.state = .Running;
            // Update sscratch to point at p's trapframe so that the next
            // trap entry (csrrw sp,sscratch,sp) swaps with the right
            // process's struct and the post-dispatch "csrr a0,sscratch"
            // retrieves the correct tf pointer for s_return_to_user.
            // This is critical for multi-proc: without it, a trap firing
            // while process N is in U-mode would save/restore the wrong tf.
            const p_addr: u32 = @intCast(@intFromPtr(p));
            asm volatile (
                \\ csrw sscratch, %[pa]
                \\ csrw satp, %[s]
                \\ sfence.vma zero, zero
                :
                : [pa] "r" (p_addr),
                  [s] "r" (p.satp),
                : .{ .memory = true }
            );
            proc.swtch(&proc.cpu.sched_context, &p.context);
            // p has yielded back; swtch left us here.
            proc.cpu.cur = null;
            continue;
        }

        if (!any_alive) {
            // No runnable, no embryo/sleeping/zombie — halt with last
            // observed exit status (or 0).
            const halt: *volatile u8 = @ptrFromInt(0x00100000);
            halt.* = @truncate(@as(u32, @bitCast(last_xstatus)));
            while (true) asm volatile ("wfi");
        }
        // Else: spin (timer tick will fire and re-enter sched's caller —
        // but we're not anyone's callee. We just busy-loop until something
        // becomes Runnable. 3.D adds proper WFI here.)
    }
}
