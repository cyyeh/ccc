# src/kernel/user/lib/usys.S — Phase 3.E syscall stubs.
#
# One stub per syscall the userland calls: load syscall number into a7,
# pass-through a0..a5 (registers already populated by the Zig caller),
# ecall, return whatever the kernel put in a0.

.macro SYSCALL name, num
    .section .text.\name, "ax", @progbits
    .globl \name
\name:
    li   a7, \num
    ecall
    ret
.endm

SYSCALL getcwd,         17
SYSCALL mkdirat,        34
SYSCALL unlinkat,       35
SYSCALL chdir,          49
SYSCALL openat,         56
SYSCALL close,          57
SYSCALL lseek,          62
SYSCALL read,           63
SYSCALL write,          64
SYSCALL fstat,          80
SYSCALL exit,           93
SYSCALL yield,          124
SYSCALL getpid,         172
SYSCALL sbrk,           214
SYSCALL fork,           220
SYSCALL exec,           221
SYSCALL wait,           260
SYSCALL set_fg_pid,     5000
SYSCALL console_set_mode, 5001
