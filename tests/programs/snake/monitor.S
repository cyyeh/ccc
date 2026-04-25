# Phase 3 snake.elf — minimal skeleton. Boots, halts via tohost.
# Full boot + trap setup arrives in T9.

.section .text.init, "ax", @progbits
.globl _start
_start:
    la      sp, _stack_top
    # Write 1 to tohost low byte → halt with exit code 0.
    # The halt MMIO encoding is "low byte = exit code"; non-zero
    # value in tohost signals "test passed" per riscv-tests convention,
    # which our halt device interprets as exit_code = 0.
    la      t0, tohost
    li      t1, 1
    sw      t1, 0(t0)
1:  j       1b
