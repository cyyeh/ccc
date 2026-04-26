// src/kernel/user/fs_init.zig — Phase 3.D /bin/init.
//
// Behavior:
//   1. fd = openat(0, "/etc/motd", 0)
//   2. n  = read(fd, buf, 256)
//   3. write(1, buf, n)   // fd 1 = UART
//   4. close(fd)
//   5. exit(0)
//
// Naked _start with inline ecalls (matches Plan 3.B / 3.C user binaries).
// 3.E will rewrite this against the userland stdlib.

export const path linksection(".rodata") = [_]u8{
    '/', 'e', 't', 'c', '/', 'm', 'o', 't', 'd', 0,
};

export var buf linksection(".bss") = [_]u8{0} ** 256;

export fn _start() linksection(".text.init") callconv(.naked) noreturn {
    asm volatile (
        \\ // openat(0, &path, 0)
        \\ li   a7, 56
        \\ li   a0, 0
        \\ la   a1, path
        \\ li   a2, 0
        \\ ecall
        \\ // a0 = fd; bail out on -1
        \\ bltz a0, fail
        \\ mv   s1, a0       // save fd in s1 (callee-saved)
        \\
        \\ // read(fd, buf, 256)
        \\ li   a7, 63
        \\ mv   a0, s1
        \\ la   a1, buf
        \\ li   a2, 256
        \\ ecall
        \\ // a0 = bytes; on -1 or 0, still try to write 0 + exit cleanly
        \\ bltz a0, fail
        \\ mv   s2, a0       // save n in s2
        \\
        \\ // write(1, buf, s2)
        \\ li   a7, 64
        \\ li   a0, 1
        \\ la   a1, buf
        \\ mv   a2, s2
        \\ ecall
        \\
        \\ // close(s1)
        \\ li   a7, 57
        \\ mv   a0, s1
        \\ ecall
        \\
        \\ // exit(0)
        \\ li   a7, 93
        \\ li   a0, 0
        \\ ecall
        \\1: j 1b
        \\
        \\fail:
        \\ // exit(1)
        \\ li   a7, 93
        \\ li   a0, 1
        \\ ecall
        \\2: j 2b
    );
}
