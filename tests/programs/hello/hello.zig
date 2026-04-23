// Phase 1 U-mode payload for hello.elf.
// Compiled as a Zig object (no main, no _start — the monitor's _start runs first).
// `u_entry` is the post-mret target the monitor installs in mepc.

const MSG: []const u8 = "hello world\n";

// Place the message in .rodata.umode so the linker script can position it
// distinctly from the monitor's .rodata (if any).
export const msg linksection(".rodata.umode") = [_]u8{
    'h', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', '\n',
};

comptime {
    // Size invariant: the inline asm below passes a2=12 as the length, so
    // `msg` MUST be exactly MSG.len bytes. If someone edits MSG, this fires.
    if (MSG.len != 12) @compileError("MSG must be 12 bytes for the inline ecall");
}

// U-mode entry. Naked: no prologue/epilogue, no stack use.
// Syscall ABI (matches Linux RISC-V subset implemented by monitor.S):
//   a7 = syscall number; a0..a2 = args; ecall; a0 = return value.
//   write (64): a0=fd, a1=buf, a2=len -> a0=len-written
//   exit  (93): a0=status -> no return (monitor halts the emulator)
export fn u_entry() linksection(".text.umode") callconv(.naked) noreturn {
    asm volatile (
        \\ # write(1, msg, 12)
        \\ li   a7, 64
        \\ li   a0, 1
        \\ la   a1, msg
        \\ li   a2, 12
        \\ ecall
        \\ # exit(0)
        \\ li   a7, 93
        \\ li   a0, 0
        \\ ecall
        \\ # exit should have halted the emulator; safety loop.
        \\1:
        \\ j    1b
    );
}
