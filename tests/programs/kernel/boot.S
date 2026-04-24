# tests/programs/kernel/boot.S — Phase 2 Plan 2.C kernel M-mode boot shim.
#
# Task 1 leaves this as a non-functional stub that just spins. Task 2 fills
# in the real M->S transition. Task 18 adds delegation + CLINT + MTI setup.
#
# Entry symbol _M_start is referenced from linker.ld's ENTRY directive.

.section .text.init, "ax", @progbits
.balign 4
.globl _M_start
_M_start:
1:  j 1b
