# Phase 3 snake.elf — M-mode boot + idle loop + trap stub.
#
# Boot sequence:
#   1. Set sp = _stack_top.
#   2. Clear .bss (Zig module-level state lives here and assumes zero-init).
#   3. Install trap_vector at mtvec.
#   4. Enable mstatus.MIE and mie.MTIE.
#   5. Program first mtimecmp = mtime + period (1.25M ticks @ 10 MHz = 125 ms).
#   6. Enter wfi loop.
#
# CLINT MMIO (per src/devices/clint.zig):
#   mtime     = 0x0200BFF8 (64-bit, low at 0x0200BFF8)
#   mtimecmp  = 0x02004000 (64-bit, low at 0x02004000)
#
# trap_vector is a stub for this task — just returns via mret without doing
# anything. T10 fills it in with caller-saved save/restore + call snakeTrap.

.section .text.init, "ax", @progbits
.globl _start
_start:
    # 1. sp.
    la      sp, _stack_top

    # 2. Clear .bss [_bss_start, _bss_end).
    la      t0, _bss_start
    la      t1, _bss_end
bss_clear_loop:
    bgeu    t0, t1, bss_clear_done
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       bss_clear_loop
bss_clear_done:

    # 3. Install trap vector (direct mode; address must be 4-byte aligned).
    la      t0, trap_vector
    csrw    mtvec, t0

    # 4. Enable timer interrupt.
    li      t0, (1 << 7)              # mie.MTIE = bit 7
    csrs    mie, t0
    li      t0, (1 << 3)              # mstatus.MIE = bit 3
    csrs    mstatus, t0

    # 5. Program first mtimecmp = mtime + 1_250_000 ticks (125 ms @ 10 MHz).
    li      t1, 0x0200BFF8            # mtime addr
    li      t2, 0x02004000            # mtimecmp addr
    lw      a0, 0(t1)                 # mtime low
    lw      a1, 4(t1)                 # mtime high
    li      t3, 1250000               # period (low word)
    add     a0, a0, t3
    sltu    t4, a0, t3                # carry
    add     a1, a1, t4                # propagate carry into high
    sw      a0, 0(t2)
    sw      a1, 4(t2)

    # 6. Enter wfi loop. The CPU sleeps until any enabled interrupt fires.
    # When MTI fires, trap_vector runs, returns here, we wfi again.
idle:
    wfi
    j       idle

# ---- Trap vector (stub) -------------------------------------------------
# T10 replaces this with the real save/restore + call snakeTrap.
.balign 4
.globl trap_vector
trap_vector:
    mret
