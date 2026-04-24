// tests/programs/kernel/syscall.zig — syscall table.
//
// Task 11 state: sys_write implemented; sys_exit still stubbed. Task 12
// finishes both and dispatch.

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

pub fn dispatch(tf: *trap.TrapFrame) void {
    _ = tf;
    @import("kprintf.zig").panic("syscall.dispatch: not implemented (Task 11 stub)", .{});
}

// Keep sys_write file-scope-callable; Task 12 wires dispatch().
pub const sys_write = sysWrite;
