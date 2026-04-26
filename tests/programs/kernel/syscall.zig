// tests/programs/kernel/syscall.zig — Phase 3.B syscall table.
//
// Syscalls dispatched in Phase 3.B:
//   - 64  (write): copies user bytes to UART via SSTATUS.SUM.
//   - 93  (exit):  delegates to proc.exit (reparent + zombie + wake parent;
//                  PID 1 also prints "ticks observed: N\n" and halts).
//   - 124 (yield): calls proc.yield() to voluntarily relinquish the CPU.
//
// proc.cur() is used for any per-process state reads (currently always
// &ptable[0] until Task 9 wires in a real CPU-local picker). Future
// tasks add syscall 172 (getpid) and 214 (sbrk).
//
// ABI unchanged: a7 = syscall number, a0..a5 = args, a0 = return.

const trap = @import("trap.zig");
const uart = @import("uart.zig");
const proc = @import("proc.zig");
const page_alloc = @import("page_alloc.zig");
const vm = @import("vm.zig");

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

pub fn sysExit(status: u32) noreturn {
    proc.exit(@bitCast(status));
}

fn sysYield() u32 {
    proc.yield();
    return 0;
}

fn sysGetpid() u32 {
    return proc.cur().pid;
}

fn sysSbrk(incr_signed: u32) u32 {
    const incr: i32 = @bitCast(incr_signed);
    const p = proc.cur();
    const old_sz = p.sz;

    if (incr > 0) {
        const new_sz = old_sz + @as(u32, @intCast(incr));
        const PAGE_SIZE: u32 = 4096;
        const old_top = (old_sz + PAGE_SIZE - 1) & ~@as(u32, PAGE_SIZE - 1);
        const new_top = (new_sz + PAGE_SIZE - 1) & ~@as(u32, PAGE_SIZE - 1);
        var va: u32 = old_top;
        while (va < new_top) : (va += PAGE_SIZE) {
            const pa = page_alloc.alloc() orelse return @bitCast(@as(i32, -12)); // -ENOMEM
            vm.mapPage(p.pgdir, va, pa, vm.USER_RW);
        }
        p.sz = new_sz;
    } else if (incr < 0) {
        // 3.B accepts but doesn't unmap. 3.E will properly unmap and free.
        const dec: u32 = @intCast(-incr);
        if (dec > old_sz) return @bitCast(@as(i32, -22)); // -EINVAL
        p.sz = old_sz - dec;
    }
    return old_sz;
}

pub fn dispatch(tf: *trap.TrapFrame) void {
    switch (tf.a7) {
        64 => tf.a0 = sysWrite(tf.a0, tf.a1, tf.a2),
        93 => sysExit(tf.a0),
        124 => tf.a0 = sysYield(),
        172 => tf.a0 = sysGetpid(),
        214 => tf.a0 = sysSbrk(tf.a0),
        else => tf.a0 = @bitCast(@as(i32, -38)), // -ENOSYS
    }
}
