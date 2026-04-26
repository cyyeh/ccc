# programs/plic_block_test/boot.S — Phase 3.A integration test M-mode shim.

.equ MIDELEG_SEIP, (1 << 9)
.equ MIE_NONE,      0
.equ SIE_SEIE,      (1 << 9)
.equ MSTATUS_MPP_S, (1 << 11)        # MPP=01 (S)
.equ MSTATUS_SIE,   (1 << 1)
.equ PLIC_PRIORITY_1, 0x0c000004
.equ PLIC_ENABLE_S,   0x0c002080
.equ PLIC_THRESHOLD_S,0x0c201000

.section .text.init, "ax", @progbits
.balign 4
.globl _M_start
_M_start:
    la      sp, _bss_end
    addi    sp, sp, 1024              # tiny stack

    # Zero BSS.
    la      t0, _bss_start
    la      t1, _bss_end
1:  beq     t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    # mtvec → panic vector (any M-mode trap = test failure).
    la      t0, m_panic
    csrw    mtvec, t0

    # mideleg.SEIP = 1.
    li      t0, MIDELEG_SEIP
    csrw    mideleg, t0

    # mie = 0 (M takes nothing).
    csrw    mie, zero

    # PLIC: priority src 1 = 1.
    li      t0, PLIC_PRIORITY_1
    li      t1, 1
    sw      t1, 0(t0)
    # Enable src 1 for S.
    li      t0, PLIC_ENABLE_S
    li      t1, (1 << 1)
    sw      t1, 0(t0)
    # Threshold = 0.
    li      t0, PLIC_THRESHOLD_S
    sw      zero, 0(t0)

    # stvec → s_trap_vector.
    la      t0, s_trap_vector
    csrw    stvec, t0

    # sie.SEIE = 1.
    li      t0, SIE_SEIE
    csrw    sie, t0

    # Drop to S at s_main with sstatus.SIE=1.
    li      t0, MSTATUS_SIE
    csrs    sstatus, t0
    li      t0, MSTATUS_MPP_S
    csrs    mstatus, t0
    la      t0, s_main
    csrw    mepc, t0
    mret

# M-mode panic: halt with exit code 2.
.globl m_panic
m_panic:
    li      t0, 0x00100000
    li      t1, 2
    sb      t1, 0(t0)
    j       m_panic
