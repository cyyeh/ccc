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
