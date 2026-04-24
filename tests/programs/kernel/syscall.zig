// tests/programs/kernel/syscall.zig — syscall table.
//
// Phase 2 Plan 2.C supports write(64) + exit(93). yield(124) arrives in
// Plan 2.D when the scheduler lands.

const trap = @import("trap.zig");
const uart = @import("uart.zig");

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
    const halt: *volatile u8 = @ptrFromInt(0x00100000);
    halt.* = @intCast(status & 0xFF);
    // Unreachable — halt MMIO terminates the emulator on the store above.
    while (true) asm volatile ("wfi");
}

pub fn dispatch(tf: *trap.TrapFrame) void {
    switch (tf.a7) {
        64 => tf.a0 = sysWrite(tf.a0, tf.a1, tf.a2),
        93 => sysExit(tf.a0),
        124 => {
            // yield — not implemented in Plan 2.C; Plan 2.D adds it.
            tf.a0 = @bitCast(@as(i32, -38)); // -ENOSYS
        },
        else => tf.a0 = @bitCast(@as(i32, -38)), // -ENOSYS
    }
}
