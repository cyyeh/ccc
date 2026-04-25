/* Linker script for userprog.elf (Plan 2.C U-mode payload).
 *
 * Layout:
 *   0x00010000  .text.init   (_start, naked asm)
 *               .text        (catch-all)
 *               .rodata      (msg)
 *   ...
 *
 * Contiguous — elfload.load maps PT_LOAD segments in Phase 3.B.
 * Permission tightening is a Plan 3+ concern.
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
    USER (rwx) : ORIGIN = 0x00010000, LENGTH = 64K
}

SECTIONS {
    . = 0x00010000;
    _user_start = .;

    .text : {
        KEEP(*(.text.init))
        *(.text .text.*)
    } > USER

    .rodata : {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > USER

    .data : {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > USER

    .bss : {
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
    } > USER

    _user_end = .;

    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.riscv.attributes)
    }
}
