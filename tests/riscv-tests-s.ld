/*
 * Linker script for rv32si-p-* riscv-tests (Phase 2).
 * Layout mirrors tests/riscv-tests-p.ld; the test preamble itself (from
 * env/p/riscv_test.h) sets up M-mode CSRs and drops into S-mode for the
 * test body.
 */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  .tohost ALIGN(0x1000) : { *(.tohost) }
  .text : { *(.text) }
  .data ALIGN(0x1000) : { *(.data) }
  .bss ALIGN(0x1000) : { *(.bss) }
  _end = .;
}
