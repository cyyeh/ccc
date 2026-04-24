// tests/programs/kernel/proc.zig — Phase 2 Plan 2.D Process struct + singleton.
//
// Phase 2 has exactly one process; Phase 3 will add a process table. The
// struct layout is fixed here and referenced from:
//   - trampoline.S via `la t0, the_process` (relies on @offsetOf(Process,"tf")==0)
//   - kmain.zig during boot to populate fields
//   - trap.zig (the SSI handler increments ticks_observed)
//   - sched.zig (schedule returns &the_process)
//   - syscall.zig (sys_exit reads ticks_observed)
//
// `extern struct` is required for predictable field layout — Zig's default
// struct layout reorders fields for packing. `State` is tagged `u32` so
// the enum has a well-defined ABI size inside an extern struct.

const std = @import("std");
const trap = @import("trap.zig");

pub const State = enum(u32) {
    Runnable = 0,
    Running = 1,
    Exited = 2,
};

pub const Process = extern struct {
    tf: trap.TrapFrame, // MUST be first — trampoline.S depends on offset 0.
    satp: u32,
    kstack_top: u32,
    state: State,
    ticks_observed: u32,
    exit_code: u32,
};

pub export var the_process: Process = undefined;

comptime {
    std.debug.assert(@offsetOf(Process, "tf") == 0);
    // TrapFrame is 128 bytes (29 GPRs * 4 + sepc * 4 = 32*4), so satp follows at offset 128.
    std.debug.assert(@offsetOf(Process, "satp") == trap.TF_SIZE);
}
