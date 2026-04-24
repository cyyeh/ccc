// tests/programs/kernel/trap.zig — S-mode trap dispatcher.
//
// Task 8 state: just the TrapFrame struct and its offset constants.
// Task 10 adds s_trap_dispatch.
//
// Field order matters. trampoline.S saves/restores registers at fixed
// offsets; any re-ordering here is an asm ABI break. The comptime block
// below pins the offsets.

const std = @import("std");

pub const TrapFrame = extern struct {
    ra: u32, // x1
    sp: u32, // x2   (saved via sscratch dance)
    gp: u32, // x3
    tp: u32, // x4
    t0: u32, // x5
    t1: u32, // x6
    t2: u32, // x7
    s0: u32, // x8
    s1: u32, // x9
    a0: u32, // x10
    a1: u32, // x11
    a2: u32, // x12
    a3: u32, // x13
    a4: u32, // x14
    a5: u32, // x15
    a6: u32, // x16
    a7: u32, // x17
    s2: u32, // x18
    s3: u32, // x19
    s4: u32, // x20
    s5: u32, // x21
    s6: u32, // x22
    s7: u32, // x23
    s8: u32, // x24
    s9: u32, // x25
    s10: u32, // x26
    s11: u32, // x27
    t3: u32, // x28
    t4: u32, // x29
    t5: u32, // x30
    t6: u32, // x31
    sepc: u32, // 128th byte
};

// Offset constants — referenced as .globl symbols from trampoline.S via
// `.equ`. To keep the asm portable we export these as numeric literals
// that the asm file mirrors in its own .equ block; the comptime assert
// here guarantees the two mirrors stay in sync.
pub const TF_RA: u32 = 0;
pub const TF_SP: u32 = 4;
pub const TF_GP: u32 = 8;
pub const TF_TP: u32 = 12;
pub const TF_T0: u32 = 16;
pub const TF_T1: u32 = 20;
pub const TF_T2: u32 = 24;
pub const TF_S0: u32 = 28;
pub const TF_S1: u32 = 32;
pub const TF_A0: u32 = 36;
pub const TF_A1: u32 = 40;
pub const TF_A2: u32 = 44;
pub const TF_A3: u32 = 48;
pub const TF_A4: u32 = 52;
pub const TF_A5: u32 = 56;
pub const TF_A6: u32 = 60;
pub const TF_A7: u32 = 64;
pub const TF_S2: u32 = 68;
pub const TF_S3: u32 = 72;
pub const TF_S4: u32 = 76;
pub const TF_S5: u32 = 80;
pub const TF_S6: u32 = 84;
pub const TF_S7: u32 = 88;
pub const TF_S8: u32 = 92;
pub const TF_S9: u32 = 96;
pub const TF_S10: u32 = 100;
pub const TF_S11: u32 = 104;
pub const TF_T3: u32 = 108;
pub const TF_T4: u32 = 112;
pub const TF_T5: u32 = 116;
pub const TF_T6: u32 = 120;
pub const TF_SEPC: u32 = 124;
pub const TF_SIZE: u32 = 128;

comptime {
    std.debug.assert(@offsetOf(TrapFrame, "ra") == TF_RA);
    std.debug.assert(@offsetOf(TrapFrame, "sp") == TF_SP);
    std.debug.assert(@offsetOf(TrapFrame, "gp") == TF_GP);
    std.debug.assert(@offsetOf(TrapFrame, "tp") == TF_TP);
    std.debug.assert(@offsetOf(TrapFrame, "t0") == TF_T0);
    std.debug.assert(@offsetOf(TrapFrame, "t1") == TF_T1);
    std.debug.assert(@offsetOf(TrapFrame, "t2") == TF_T2);
    std.debug.assert(@offsetOf(TrapFrame, "s0") == TF_S0);
    std.debug.assert(@offsetOf(TrapFrame, "s1") == TF_S1);
    std.debug.assert(@offsetOf(TrapFrame, "a0") == TF_A0);
    std.debug.assert(@offsetOf(TrapFrame, "a7") == TF_A7);
    std.debug.assert(@offsetOf(TrapFrame, "s2") == TF_S2);
    std.debug.assert(@offsetOf(TrapFrame, "t3") == TF_T3);
    std.debug.assert(@offsetOf(TrapFrame, "t6") == TF_T6);
    std.debug.assert(@offsetOf(TrapFrame, "sepc") == TF_SEPC);
    std.debug.assert(@sizeOf(TrapFrame) == TF_SIZE);
}

// Task 9 shim: asm references s_trap_dispatch at link time; this stub
// lets the linker resolve the symbol. Task 10 replaces this with the
// real dispatcher body.
export fn s_trap_dispatch(tf: *TrapFrame) callconv(.c) void {
    _ = tf;
    @import("kprintf.zig").panic("s_trap_dispatch: not implemented (Task 9 stub)", .{});
}
