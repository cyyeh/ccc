# Hand-crafted RV32IMA demo

`encode_mul_demo.zig` is a Zig host-side program that emits a raw RISC-V
binary exercising every ISA extension added in Plan 1.B: **M** (`mul`,
`divu`, `remu`), **A** (`amoswap.w`), and **Zifencei** (`fence.i`).

Run by hand:

```
zig build mul-demo
zig build run -- --raw 0x80000000 zig-out/mul_demo.bin
```

Expected output: `42\n`.

The program:

1. Loads 6 and 7 into t1/t2 and computes 6×7=42 via `mul`.
2. Atomically swaps 42 into a scratch RAM slot with `amoswap.w`, leaving
   the slot's previous value (0) in t5.
3. Formats 42 into two ASCII digits using `divu`/`remu` (÷10 and rem 10).
4. Issues `fence.i` as a no-op I-cache barrier (just to exercise the
   opcode; we have no I-cache).
5. Writes `'4'`, `'2'`, `'\n'` to the UART THR at 0x10000000.
6. Writes 0 to the halt MMIO at 0x00100000 to exit.

This is scaffolding for Plan 1.B only. Plan 1.D will replace hand-crafted
binaries with cross-compiled Zig programs that run in U-mode via the
M-mode monitor.
