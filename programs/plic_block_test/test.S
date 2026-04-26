# programs/plic_block_test/test.S — Phase 3.A integration test S-mode body.

.equ BLK_BASE,      0x10001000
.equ BLK_SECTOR,    0
.equ BLK_BUFFER,    4
.equ BLK_CMD,       8
.equ BLK_STATUS,    0xC

.equ PLIC_CLAIM_S,  0x0c201004
.equ HALT_BASE,     0x00100000
.equ TARGET_PA,     0x80100000

.section .text, "ax", @progbits
.balign 4
.globl s_main
s_main:
    # Program block: SECTOR=0, BUFFER=0x80100000, CMD=1 (read).
    li      t0, BLK_BASE
    sw      zero, BLK_SECTOR(t0)
    li      t1, TARGET_PA
    sw      t1, BLK_BUFFER(t0)
    li      t1, 1
    sw      t1, BLK_CMD(t0)

    # WFI — wait for interrupt.
1:  wfi
    j       1b   # if wfi returns without trap, loop (defensive)

.balign 4
.globl s_trap_vector
s_trap_vector:
    # Verify scause = 0x80000009 (interrupt | SEI).
    csrr    t0, scause
    li      t1, 0x80000009
    bne     t0, t1, fail

    # Claim from PLIC; expect 1.
    li      t0, PLIC_CLAIM_S
    lw      t1, 0(t0)
    li      t2, 1
    bne     t1, t2, fail

    # Block STATUS should be 0 (Ready).
    li      t0, BLK_BASE
    lw      t1, BLK_STATUS(t0)
    bnez    t1, fail

    # Read magic byte from RAM.
    li      t0, TARGET_PA
    lbu     t1, 0(t0)
    li      t2, 0xCC
    bne     t1, t2, fail

    # Complete (write claim).
    li      t0, PLIC_CLAIM_S
    li      t1, 1
    sw      t1, 0(t0)

    # Halt with exit code 0.
    li      t0, HALT_BASE
    sb      zero, 0(t0)
    j       .

fail:
    li      t0, HALT_BASE
    li      t1, 1
    sb      t1, 0(t0)
    j       .
