# Hand-crafted hello world

`encode_hello.zig` is a Zig program that emits a raw RISC-V binary at
`hello.bin`.

Build the binary and run the end-to-end demo:

    zig build hello
    zig build run -- --raw 0x80000000 zig-out/hello.bin

The binary contains a tiny RV32I program followed by the string
`hello world\n\0` at offset `0x100`. The program loops: read a byte from
the string, write it to UART, advance the pointer; when it hits `\0` it
writes to the halt MMIO and the emulator exits.

The automated end-to-end test runs the built binary through the emulator
and asserts the UART output equals `hello world\n`:

    zig build e2e

This is throwaway scaffolding for Plan 1.A. Plan 1.D replaces it with a
proper Zig-cross-compiled hello world that runs in U-mode through the
M-mode monitor.
