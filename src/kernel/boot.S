# src/kernel/boot.S — Phase 2 Plan 2.C kernel M-mode boot shim.
#
# Task 18 state: full M-mode boot. Set mtvec to m_trap_vector (which
# routes MTI to m_timer_isr in mtimer.S, panics on anything else),
# delegate U->S synchronous traps + SSIP, enable mie.MTIE + mstatus.MIE,
# program CLINT mtimecmp = mtime + TIMESLICE, drop to S at kmain.

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

.equ MIE_MTIE, (1 << 7)
.equ MSTATUS_MIE, (1 << 3)

# CLINT register addresses.
.equ CLINT_MTIMECMP_LO, 0x02004000
.equ CLINT_MTIMECMP_HI, 0x02004004
.equ CLINT_MTIME_LO,    0x0200BFF8
.equ CLINT_MTIME_HI,    0x0200BFFC

# Timer quantum: 10,000 CLINT ticks per slice. At the emulator's
# 10 MHz nominal CLINT rate, that's ~1 ms — short enough that even a
# brief user program guarantees multiple ticks fire, but long enough
# that the per-tick overhead (~30 instructions for the M-ISR +
# M→S SSIP forwarding + S-mode handler) stays well under 10%.
.equ TIMESLICE, 10000

.section .text.init, "ax", @progbits
.balign 4
.globl _M_start
_M_start:
    la      sp, _kstack_top

    # Zero BSS.
    la      t0, _bss_start
    la      t1, _bss_end
1:  beq     t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    # Install M-mode trap vector.
    la      t0, m_trap_vector
    csrw    mtvec, t0

    # medeleg.
    li      t0, (MEDELEG_INST_MISALIGN | MEDELEG_ILLEGAL | MEDELEG_BREAKPOINT | \
                 MEDELEG_LOAD_MISALIGN  | MEDELEG_STORE_MISALIGN | MEDELEG_ECALL_U | \
                 MEDELEG_INST_PF        | MEDELEG_LOAD_PF        | MEDELEG_STORE_PF)
    csrw    medeleg, t0

    # mideleg: SSIP.
    li      t0, MIDELEG_SSIP
    csrw    mideleg, t0

    # mie.MTIE = 1.
    li      t0, MIE_MTIE
    csrs    mie, t0

    # Program CLINT: mtimecmp = mtime + TIMESLICE.
    li      t2, CLINT_MTIME_LO
    lw      t0, 0(t2)            # t0 = mtime low
    li      t2, CLINT_MTIME_HI
    lw      t1, 0(t2)            # t1 = mtime high
    li      t2, TIMESLICE
    add     t0, t0, t2
    sltu    t2, t0, t2           # carry detect
    add     t1, t1, t2
    li      t2, CLINT_MTIMECMP_LO
    sw      t0, 0(t2)
    li      t2, CLINT_MTIMECMP_HI
    sw      t1, 0(t2)

    # mstatus.MIE = 1 (async MTI can now reach M).
    li      t0, MSTATUS_MIE
    csrs    mstatus, t0

    # mstatus.MPP = S (01).
    li      t0, 0x1800           # MPP_MASK = bits 12:11
    csrc    mstatus, t0
    li      t0, 0x0800           # MPP = 01 (S)
    csrs    mstatus, t0

    # mepc <- kmain.
    la      t0, kmain
    csrw    mepc, t0

    mret


# ---- M-mode trap vector. ----------------------------------------------
# Direct mode (MODE=0). cause 7 + interrupt bit = MTI -> m_timer_isr
# (defined in mtimer.S). Anything else panics by storing 0xFF to halt
# MMIO and spinning.
.balign 4
.globl m_trap_vector
m_trap_vector:
    # Use mscratch as a single-word scratch slot to stash t0 without
    # touching sp (sp at this point is the S-mode kernel stack or the
    # user stack, and we must not perturb either).
    csrrw   t0, mscratch, t0     # swap t0 <-> mscratch
    csrr    t0, mcause
    # Check for MTI: cause = 0x80000007.
    li      x31, 0x80000007
    beq     t0, x31, m_trap_is_mti
    # Not MTI -> panic. Restore t0 first, then fall through.
    csrrw   t0, mscratch, t0
    li      x31, 0x00100000
    li      x30, 0xFF
    sb      x30, 0(x31)
1:  j       1b

m_trap_is_mti:
    # Restore t0 and jump to m_timer_isr (defined in mtimer.S).
    csrrw   t0, mscratch, t0
    j       m_timer_isr
