// tests/programs/kernel/user/userprog.zig — Plan 2.D U-mode payload.
//
// Naked `_start` does: write(1, msg, 18); yield(); busy-loop 100k; exit(0).
// The busy-loop is there so wall-clock time advances enough that at least
// one timer tick fires while we're in U-mode — guaranteeing
// `ticks_observed > 0` when the kernel's sys_exit prints it.
//
// Syscall ABI (matches Linux RISC-V subset):
//   a7 = syscall #, a0..a5 = args, a0 = return.
//   write (64): fd=a0, buf=a1, len=a2
//   yield (124): (no args)
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
        \\ li   a7, 124
        \\ ecall
        \\ li   t0, 100000
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
