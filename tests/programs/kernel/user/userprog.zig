// tests/programs/kernel/user/userprog.zig — Plan 2.C U-mode payload.
//
// Naked `_start` makes two ecalls (write + exit) and spins.
// Syscall ABI (matches Linux RISC-V subset):
//   a7 = syscall #, a0..a5 = args, a0 = return.
//   write (64): fd=a0, buf=a1, len=a2
//   exit  (93): status=a0 → halts emulator via kernel sys_exit

const MSG = "hello from u-mode\n";

export const msg linksection(".rodata") = [_]u8{
    'h', 'e', 'l', 'l', 'o', ' ', 'f', 'r', 'o', 'm',
    ' ', 'u', '-', 'm', 'o', 'd', 'e', '\n',
};

comptime {
    if (MSG.len != 18) @compileError("MSG must be 18 bytes (see _start's a2)");
    if (msg.len != 18) @compileError("msg array length must match MSG.len");
}

export fn _start() linksection(".text.init") callconv(.naked) noreturn {
    asm volatile (
        \\ li   a7, 64
        \\ li   a0, 1
        \\ la   a1, msg
        \\ li   a2, 18
        \\ ecall
        \\ li   a7, 93
        \\ li   a0, 0
        \\ ecall
        \\ 1:
        \\ j    1b
    );
}
