/* Linker script for snake.elf (Phase 3 demo). Mirrors hello/linker.ld
 * but exposes _bss_start / _bss_end so monitor.S can zero BSS before
 * Zig code (which has lots of mutable module-level state) runs. */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128M
}

SECTIONS {
    . = 0x80000000;

    .text.init : { KEEP(*(.text.init)) } > RAM
    .text      : { *(.text .text.*) }    > RAM
    .rodata    : { *(.rodata .rodata.*) } > RAM
    .data      : { *(.data .data.*) }    > RAM

    .bss : {
        _bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    /* 16 KB stack — snake's tick handler nests one frame deep, but
     * the Zig render path uses fixed buffers, so 16 KB is generous. */
    . = ALIGN(16);
    . = . + 0x4000;
    _stack_top = .;

    /* tohost: a 4-byte word the program writes to halt the emulator.
     * src/elf.zig resolves this symbol at load time and routes writes
     * to mem.tohost_addr → halt device. Same convention as riscv-tests
     * and hello.elf (hello hardcodes 0x00100000 instead, but both
     * paths end up at the halt MMIO). */
    . = ALIGN(8);
    tohost = .;
    . = . + 8;

    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.eh_frame)
        *(.riscv.attributes)
    }
}
