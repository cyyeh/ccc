// tests/programs/kernel/syscall.zig — Phase 3.B syscall table.
//
// Syscalls dispatched in Phase 3.B:
//   - 64  (write): copies user bytes to UART via SSTATUS.SUM.
//   - 93  (exit):  prints "ticks observed: N\n" then halts via MMIO.
//   - 124 (yield): calls proc.yield() to voluntarily relinquish the CPU.
//
// proc.cur() is used for any per-process state reads (currently always
// &ptable[0] until Task 9 wires in a real CPU-local picker). Future
// tasks add syscall 172 (getpid) and 214 (sbrk).
//
// ABI unchanged: a7 = syscall number, a0..a5 = args, a0 = return.

const trap = @import("trap.zig");
const uart = @import("uart.zig");
const kprintf = @import("kprintf.zig");
const proc = @import("proc.zig");

const SSTATUS_SUM: u32 = 1 << 18;

fn setSum() void {
    asm volatile ("csrs sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SUM),
        : .{ .memory = true }
    );
}

fn clearSum() void {
    asm volatile ("csrc sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SUM),
        : .{ .memory = true }
    );
}

fn sysWrite(fd: u32, buf_va: u32, len: u32) u32 {
    if (fd != 1 and fd != 2) {
        return @bitCast(@as(i32, -9)); // -EBADF
    }
    setSum();
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const p: *const volatile u8 = @ptrFromInt(buf_va + i);
        uart.writeByte(p.*);
    }
    clearSum();
    return len;
}

fn sysExit(status: u32) noreturn {
    const p = proc.cur();
    p.xstate = @bitCast(status);
    p.state = .Zombie;

    if (p.pid == 1) {
        // Phase 2 §Definition of done: print "ticks observed: N\n" before
        // halting. We use this proc's own ticks_observed; the multi-proc
        // test arranges for PID 1 to be the last to exit.
        kprintf.print("ticks observed: {d}\n", .{p.ticks_observed});
        const halt: *volatile u8 = @ptrFromInt(0x00100000);
        halt.* = @intCast(status & 0xFF);
        while (true) asm volatile ("wfi");
    }

    // Non-PID-1 proc: yield back to scheduler. 3.C will reap zombies via
    // wait(); for 3.B's multi-proc demo, the scheduler will keep cycling
    // between PID 1 and PID 2 (now Zombie, skipped) until PID 1 exits and
    // halts.
    proc.sched();
    // Should not return — but if it does, panic.
    kprintf.panic("sysExit: zombie woke up", .{});
}

fn sysYield() u32 {
    proc.yield();
    return 0;
}

pub fn dispatch(tf: *trap.TrapFrame) void {
    switch (tf.a7) {
        64 => tf.a0 = sysWrite(tf.a0, tf.a1, tf.a2),
        93 => sysExit(tf.a0),
        124 => tf.a0 = sysYield(),
        else => tf.a0 = @bitCast(@as(i32, -38)), // -ENOSYS
    }
}
