// tests/programs/kernel/syscall.zig — syscall table.
//
// Task 10 state: just a stub so trap.zig's import resolves. Tasks 11-12
// fill in sys_write, sys_exit, dispatch.

const trap = @import("trap.zig");

pub fn dispatch(tf: *trap.TrapFrame) void {
    _ = tf;
    @import("kprintf.zig").panic("syscall.dispatch: not implemented (Task 10 stub)", .{});
}
