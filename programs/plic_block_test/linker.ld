OUTPUT_ARCH("riscv")
ENTRY(_M_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128M
}

SECTIONS {
    . = 0x80000000;

    .text : {
        KEEP(*(.text.init))
        *(.text .text.*)
    } > RAM

    .bss : {
        _bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    /DISCARD/ : {
        *(.note.*) *(.comment) *(.eh_frame) *(.eh_frame_hdr) *(.riscv.attributes)
    }
}
