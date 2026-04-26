# tests/programs/kernel/mtimer.S — Phase 2 Plan 2.C M-mode timer ISR.
#
# Called from m_trap_vector (boot.S) when mcause = 0x80000007 (MTI).
# On entry, all GPRs hold the caller's values; we must not perturb any
# of them except through save/restore, because sp at this point is
# either S-mode kernel's sp or U-mode's sp and we have no M-mode stack.
#
# Strategy: stash caller's t0 into mscratch, use t0 as the scratch-area
# base, then save t1/t2 and (via mscratch) t0 into m_scratch_area. We
# use t0/t1/t2 as working registers during the mtimecmp advance; at
# the end we reload all three from m_scratch_area with `t2` as the base
# so the last load (t2 itself) can safely overwrite its own base.
#
# Steps:
#   1. Save t0, t1, t2 to m_scratch_area.
#   2. Advance mtimecmp = mtime + TIMESLICE (clears MTIP edge).
#   3. Set mip.SSIP (delegated to S per mideleg[SSIP]=1).
#   4. Restore t0, t1, t2.
#   5. mret.

.equ CLINT_MTIMECMP_LO, 0x02004000
.equ CLINT_MTIMECMP_HI, 0x02004004
.equ CLINT_MTIME_LO,    0x0200BFF8
.equ CLINT_MTIME_HI,    0x0200BFFC
.equ TIMESLICE,         10000

.section .bss, "aw", @nobits
.balign 4
.globl m_scratch_area
m_scratch_area:
    .space 12             # 3 slots of 4 bytes: t0, t1, t2

.section .text, "ax", @progbits
.balign 4
.globl m_timer_isr
m_timer_isr:
    # Save caller's t0 via mscratch so we can use t0 as scratch-area base.
    csrw    mscratch, t0
    la      t0, m_scratch_area
    sw      t1, 4(t0)
    sw      t2, 8(t0)
    csrr    t1, mscratch         # t1 = caller's t0
    sw      t1, 0(t0)

    # mtimecmp = mtime + TIMESLICE. Reload t1/t2 with mtime {lo, hi}.
    li      t1, CLINT_MTIME_LO
    lw      t1, 0(t1)            # t1 = mtime_lo
    li      t2, CLINT_MTIME_HI
    lw      t2, 0(t2)            # t2 = mtime_hi
    li      t0, TIMESLICE
    add     t1, t1, t0
    sltu    t0, t1, t0           # carry out of low add
    add     t2, t2, t0
    li      t0, CLINT_MTIMECMP_LO
    sw      t1, 0(t0)
    li      t0, CLINT_MTIMECMP_HI
    sw      t2, 0(t0)

    # Forward to S-mode via mideleg[SSIP]=1.
    csrsi   mip, 2               # sets bit 1 = SSIP

    # Restore caller's t0/t1/t2. Use t2 as the base so the final load
    # (t2 itself) overwrites the base with its saved value in one step.
    la      t2, m_scratch_area
    lw      t0, 0(t2)
    lw      t1, 4(t2)
    lw      t2, 8(t2)

    mret
