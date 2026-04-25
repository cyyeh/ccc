// tests/programs/kernel/user/userprog2.zig — Phase 3.B PID 2 payload.
//
// Same shape as userprog.zig: write a message, yield, busy-loop, exit.
// Different message lets the multi-proc verifier distinguish PID 1 vs.
// PID 2 output. The busy-loop is shorter (10k vs. 100k) so PID 2
// finishes first and PID 1's exit triggers the halt + ticks-trailer.

const MSG = "[2] hello from u-mode\n"; // 22 bytes

export const msg2 linksection(".rodata") = [_]u8{
    '[', '2', ']', ' ',
    'h', 'e', 'l', 'l', 'o', ' ', 'f', 'r', 'o', 'm', ' ',
    'u', '-', 'm', 'o', 'd', 'e', '\n',
};

comptime {
    if (MSG.len != 22) @compileError("MSG must be 22 bytes (see _start's a2)");
    if (msg2.len != 22) @compileError("msg2 array length must match MSG.len");
}

export fn _start() linksection(".text.init") callconv(.naked) noreturn {
    asm volatile (
        \\ li   a7, 64
        \\ li   a0, 1
        \\ la   a1, msg2
        \\ li   a2, 22
        \\ ecall
        \\ li   a7, 124
        \\ ecall
        \\ li   t0, 10000
        \\ 1:
        \\ addi t0, t0, -1
        \\ bnez t0, 1b
        \\ li   a7, 93
        \\ li   a0, 0
        \\ ecall
        \\ 2:
        \\ j    2b
    );
}
