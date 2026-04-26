// src/kernel/user/init.zig — Phase 3.C PID 1 payload.
//
// Behavior:
//   1. fork()
//   2. child:  execve("/bin/hello", ["hello", NULL], NULL); on failure exit(1)
//   3. parent: wait4(child_pid, &status, 0, 0); print "init: reaped\n"; exit(0)
//
// Naked _start with inline ecalls — same shape as Plan 3.B userprog.zig.
// 3.E will rewrite this against the userland stdlib (start.S + usys.S).
//
// .rodata layout:
//   path      : "/bin/hello\0"        (11 bytes)
//   arg0      : "hello\0"             (6 bytes)
//   reaped_msg: "init: reaped\n"      (13 bytes)
// .data (mutable) layout:
//   argv      : [&arg0, NULL]         (8 bytes)
//   status    : i32                   (wait's output)

export const path linksection(".rodata") = [_]u8{
    '/', 'b', 'i', 'n', '/', 'h', 'e', 'l', 'l', 'o', 0,
};

export const arg0 linksection(".rodata") = [_]u8{
    'h', 'e', 'l', 'l', 'o', 0,
};

export const reaped_msg linksection(".rodata") = [_]u8{
    'i', 'n', 'i', 't', ':', ' ', 'r', 'e', 'a', 'p', 'e', 'd', '\n',
};

// Mutable argv array — pointer slots filled by _start's la instructions.
// Plan 3.E userland-stdlib will move this out of .data into a stack-built
// argv; until then we use a fixed .data layout because naked asm can't
// easily build pointer arrays on the stack.
export var argv linksection(".data") = [_]u32{ 0, 0 };

export var status linksection(".bss") = @as(i32, 0);

export fn _start() linksection(".text.init") callconv(.naked) noreturn {
    asm volatile (
        \\ // argv[0] = &arg0; argv[1] = 0
        \\ la   t0, argv
        \\ la   t1, arg0
        \\ sw   t1, 0(t0)
        \\ sw   zero, 4(t0)
        \\
        \\ // fork()
        \\ li   a7, 220
        \\ ecall
        \\ beqz a0, child
        \\
        \\ // parent: save child pid in s1 (callee-saved, survives ecall)
        \\ mv   s1, a0
        \\
        \\ // wait4(s1, &status, 0, 0)
        \\ li   a7, 260
        \\ mv   a0, s1
        \\ la   a1, status
        \\ li   a2, 0
        \\ li   a3, 0
        \\ ecall
        \\
        \\ // write(1, reaped_msg, 13)
        \\ li   a7, 64
        \\ li   a0, 1
        \\ la   a1, reaped_msg
        \\ li   a2, 13
        \\ ecall
        \\
        \\ // exit(0)
        \\ li   a7, 93
        \\ li   a0, 0
        \\ ecall
        \\
        \\ // unreachable
        \\1: j 1b
        \\
        \\child:
        \\ // execve("/bin/hello", argv, 0)
        \\ li   a7, 221
        \\ la   a0, path
        \\ la   a1, argv
        \\ li   a2, 0
        \\ ecall
        \\
        \\ // exec failure: exit(1)
        \\ li   a7, 93
        \\ li   a0, 1
        \\ ecall
        \\2: j 2b
    );
}
