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

pub extern fn swtch(old: *Context, new: *Context) void;

pub const State = enum(u32) {
    Runnable = 0,
    Running = 1,
    Exited = 2,
};

pub const Context = extern struct {
    ra: u32,
    sp: u32,
    s0: u32, s1: u32, s2: u32, s3: u32, s4: u32, s5: u32,
    s6: u32, s7: u32, s8: u32, s9: u32, s10: u32, s11: u32,
};

pub const CTX_RA: u32 = 0;
pub const CTX_SP: u32 = 4;
pub const CTX_S0: u32 = 8;
pub const CTX_S1: u32 = 12;
pub const CTX_S2: u32 = 16;
pub const CTX_S3: u32 = 20;
pub const CTX_S4: u32 = 24;
pub const CTX_S5: u32 = 28;
pub const CTX_S6: u32 = 32;
pub const CTX_S7: u32 = 36;
pub const CTX_S8: u32 = 40;
pub const CTX_S9: u32 = 44;
pub const CTX_S10: u32 = 48;
pub const CTX_S11: u32 = 52;
pub const CTX_SIZE: u32 = 56;

comptime {
    std.debug.assert(@offsetOf(Context, "ra") == CTX_RA);
    std.debug.assert(@offsetOf(Context, "sp") == CTX_SP);
    std.debug.assert(@offsetOf(Context, "s0") == CTX_S0);
    std.debug.assert(@offsetOf(Context, "s11") == CTX_S11);
    std.debug.assert(@sizeOf(Context) == CTX_SIZE);
}

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
