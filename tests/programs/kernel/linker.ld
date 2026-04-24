/* Linker script for kernel.elf (Phase 2 Plan 2.C).
 *
 * Layout:
 *   0x80000000  .text.init  (boot.S: _M_start)
 *               .text       (kernel Zig + trampoline.S + mtimer.S)
 *               .rodata     (kernel rodata + embedded userprog.bin)
 *               .data
 *               .bss
 *               (16 KB kernel stack)
 *   _end (4 KB aligned — page_alloc.init bumps from here)
 *
 * All sections are 4 KB-aligned so vm.mapKernelAndMmio can apply
 * section-appropriate permissions on a per-page basis.
 */

OUTPUT_ARCH("riscv")
ENTRY(_M_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128M
}

SECTIONS {
    . = 0x80000000;

    .text : {
        _text_start = .;
        KEEP(*(.text.init))
        *(.text .text.*)
        . = ALIGN(4096);
        _text_end = .;
    } > RAM

    .rodata : {
        _rodata_start = .;
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(4096);
        _rodata_end = .;
    } > RAM

    .data : {
        _data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4096);
        _data_end = .;
    } > RAM

    .bss : {
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4096);
        _bss_end = .;
    } > RAM

    /* Kernel stack: 16 KB = 4 pages. */
    . = ALIGN(16);
    _kstack_bottom = .;
    . = . + 0x4000;
    _kstack_top = .;

    . = ALIGN(4096);
    _end = .;

    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.eh_frame)
        *(.riscv.attributes)
    }
}
