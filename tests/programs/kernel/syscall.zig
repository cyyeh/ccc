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
    // Emit the Phase 2 §Definition of done trailer: "ticks observed: N\n".
    // We read the counter AFTER the scheduler has had a chance to bump it
    // one last time (the ticks live in proc.cur(), touched by the
    // SSI handler in trap.zig).
    kprintf.print("ticks observed: {d}\n", .{proc.cur().ticks_observed});
    const halt: *volatile u8 = @ptrFromInt(0x00100000);
    halt.* = @intCast(status & 0xFF);
    // Unreachable — halt MMIO terminates the emulator on the store above.
    while (true) asm volatile ("wfi");
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
