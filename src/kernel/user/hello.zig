// src/kernel/user/hello.zig — Phase 3.C exec target.
//
// Naked _start: write(1, msg, 22); exit(0).
// Same shape as Plan 3.B userprog.zig.

const MSG = "hello from /bin/hello\n";

export const msg linksection(".rodata") = [_]u8{
    'h', 'e', 'l', 'l', 'o', ' ', 'f', 'r', 'o', 'm', ' ',
    '/', 'b', 'i', 'n', '/', 'h', 'e', 'l', 'l', 'o', '\n',
};

comptime {
    if (MSG.len != 22) @compileError("MSG must be 22 bytes (see _start's a2)");
    if (msg.len != 22) @compileError("msg array length must match MSG.len");
}

export fn _start() linksection(".text.init") callconv(.naked) noreturn {
    asm volatile (
        \\ li   a7, 64
        \\ li   a0, 1
        \\ la   a1, msg
        \\ li   a2, 22
        \\ ecall
        \\ li   a7, 93
        \\ li   a0, 0
        \\ ecall
        \\1: j 1b
    );
}
