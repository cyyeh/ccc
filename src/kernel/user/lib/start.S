# src/kernel/user/lib/start.S — Phase 3.E userland entry point.
#
# proc.exec sets sp to the System-V tail:
#   sp+0:        argc        (u32)
#   sp+4:        argv[0]     (u32 — pointer to first arg string)
#   sp+8:        argv[1]     (u32)
#   ...
#   sp+4+4*argc: 0           (NULL terminator)
#   sp+...:      argv strings, NUL-terminated
#
# We pass (argc, argv) to main via a0/a1 per RV32 calling convention,
# then ecall exit on return.

.section .text._start, "ax", @progbits
.globl _start
_start:
    lw   a0, 0(sp)        # a0 = argc
    addi a1, sp, 4        # a1 = &argv[0]
    call main             # main(argc, argv) -> a0 = exit status
    li   a7, 93           # SYS_exit
    ecall
1:  j    1b               # never returns
