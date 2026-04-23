/* Linker script for hello.elf (Phase 1 §Definition of done demo).
 *
 * Layout:
 *   0x80000000  .text.init    (monitor: _start, trap_vector)
 *               .text.umode   (Zig U-mode code: u_entry)
 *               .rodata.umode (Zig U-mode data: msg)
 *               .text/.rodata (catch-all for any Zig-emitted sections)
 *               .data / .bss
 *   ...
 *   _stack_top  (16-byte aligned, 8 KB above last section)
 *
 * The monitor loads `sp` from _stack_top before mret. Phase 1 has no
 * process scheduling, so one 8 KB stack is all we need.
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128M
}

SECTIONS {
    . = 0x80000000;

    .text.init : {
        KEEP(*(.text.init))
    } > RAM

    .text.umode : {
        *(.text.umode)
        *(.text.umode.*)
    } > RAM

    .rodata.umode : {
        *(.rodata.umode)
        *(.rodata.umode.*)
    } > RAM

    /* Catch-all for any Zig-emitted sections. The compiler may emit
     * .text / .rodata / .data for helpers or literals; hello.zig itself
     * has none, but future edits shouldn't silently drop data. */
    .text    : { *(.text .text.*) } > RAM
    .rodata  : { *(.rodata .rodata.*) } > RAM
    .data    : { *(.data .data.*) } > RAM

    .bss : {
        _bss_start = .;
        *(.bss .bss.*)
        _bss_end = .;
    } > RAM

    /* 8 KB stack above all loaded sections, 16-byte aligned. */
    . = ALIGN(16);
    . = . + 0x2000;
    _stack_top = .;

    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.eh_frame)
        *(.riscv.attributes)
    }
}
