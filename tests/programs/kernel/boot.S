# tests/programs/kernel/boot.S — Phase 2 Plan 2.C kernel M-mode boot shim.
#
# Task 16 state: M->S drop (Task 2) + delegation (this task). CLINT and
# mtvec arrive in Task 18.
#
# Delegation: route delegatable synchronous exceptions to S-mode, and
# delegate SSIP (the software-software interrupt we use to forward
# timer ticks from M to S).

# medeleg bit layout (spec §Delegation). We mirror the Phase 2 spec
# exactly; Plan 2.B already implemented the CSR.
.equ MEDELEG_INST_MISALIGN,  (1 <<  0)
.equ MEDELEG_ILLEGAL,        (1 <<  2)
.equ MEDELEG_BREAKPOINT,     (1 <<  3)
.equ MEDELEG_LOAD_MISALIGN,  (1 <<  4)
.equ MEDELEG_STORE_MISALIGN, (1 <<  6)
.equ MEDELEG_ECALL_U,        (1 <<  8)
.equ MEDELEG_INST_PF,        (1 << 12)
.equ MEDELEG_LOAD_PF,        (1 << 13)
.equ MEDELEG_STORE_PF,       (1 << 15)

.equ MIDELEG_SSIP, (1 << 1)

.section .text.init, "ax", @progbits
.balign 4
.globl _M_start
_M_start:
    # Stack.
    la      sp, _kstack_top

    # Zero BSS.
    la      t0, _bss_start
    la      t1, _bss_end
1:  beq     t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    # medeleg: delegate the exceptions U-mode can raise.
    li      t0, (MEDELEG_INST_MISALIGN | MEDELEG_ILLEGAL | MEDELEG_BREAKPOINT | \
                 MEDELEG_LOAD_MISALIGN  | MEDELEG_STORE_MISALIGN | MEDELEG_ECALL_U | \
                 MEDELEG_INST_PF        | MEDELEG_LOAD_PF        | MEDELEG_STORE_PF)
    csrw    medeleg, t0

    # mideleg: delegate SSIP (supervisor software interrupt). MTIP is
    # NOT delegable (hardwired 0 per Plan 2.B's MIDELEG_WRITABLE mask).
    li      t0, MIDELEG_SSIP
    csrw    mideleg, t0

    # mstatus.MPP = S (01).
    li      t0, 0x1800           # MPP_MASK = bits 12:11
    csrc    mstatus, t0
    li      t0, 0x0800           # MPP = 01 (S)
    csrs    mstatus, t0

    # mepc <- kmain.
    la      t0, kmain
    csrw    mepc, t0

    mret
