# tests/programs/kernel/boot.S — Phase 2 Plan 2.C kernel M-mode boot shim.
#
# Task 2 state: minimum machinery to drop into S-mode at `kmain`. No
# delegation, no timer, no trap vector — anything unexpected hangs.
# Task 18 adds the rest.

.section .text.init, "ax", @progbits
.balign 4
.globl _M_start
_M_start:
    # Initialise stack pointer (we run on the shared kernel stack in both
    # M and S — M only uses it briefly during boot).
    la      sp, _kstack_top

    # Zero BSS. Both _bss_start and _bss_end are 4-byte aligned per the
    # linker script (everything is 4KB-aligned).
    la      t0, _bss_start
    la      t1, _bss_end
1:  beq     t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    # Configure mstatus for the mret drop: MPP=01 (S), MPIE=0, MIE=0.
    # The 2.A Phase-2 CPU honours these on mret: privilege <- MPP, SIE <-
    # SPIE implicitly (we're not using S-mode interrupts yet).
    li      t0, 0x1800           # MPP_MASK = bits 12:11
    csrc    mstatus, t0          # clear MPP (currently =11/M from reset)
    li      t0, 0x0800           # MPP = 01 (S) in bits 12:11
    csrs    mstatus, t0

    # mepc <- kmain (the Zig entry point).
    la      t0, kmain
    csrw    mepc, t0

    # Drop to S-mode.
    mret
