# hello — the Phase 1 "hello world" demos

Two flavours of hello-world live in this directory:

## 1. `hello.bin` — hand-crafted raw binary (Plan 1.A)

`encode_hello.zig` is a host Zig program that emits a raw RV32I binary
implementing a minimal boot loop: UART-write each byte of `"hello world\n"`,
then write to the halt MMIO. No privilege switches, no ELF, no monitor.

```
zig build hello           # produces zig-out/bin/hello.bin
zig build e2e             # runs it through ccc and asserts output
```

This is the Plan 1.A end-to-end test. It exercises RV32I + UART + halt MMIO
and nothing else.

## 2. `hello.elf` — cross-compiled Zig + M-mode monitor (Plan 1.D)

The Phase 1 §Definition of done demo. Exercises the whole emulator:

- ELF32 loader (Plan 1.C): parses `hello.elf` and sets `PC ← e_entry`.
- `monitor.S`: M-mode entry (`_start`) sets `sp`, installs `mtvec`, clears
  `mstatus.MPP` (so post-mret privilege = U), sets `mepc = u_entry`, `mret`s.
- `hello.zig`: U-mode naked function does `write(1, msg, 12)` via ecall
  (a7=64), then `exit(0)` via ecall (a7=93).
- `monitor.S` trap handler: catches both ecalls. `sys_write` copies bytes
  from `*a1` to UART THR. `sys_exit` writes to the halt MMIO.
- Halt MMIO: emulator exits with code `a0`.

Build & run:

```
zig build hello-elf       # produces zig-out/bin/hello.elf
zig build e2e-hello-elf   # runs it through ccc and asserts "hello world\n"
```

Run manually with tracing:

```
./zig-out/bin/ccc --trace zig-out/bin/hello.elf 2>trace.log
head -20 trace.log
```

## Files

| File | Purpose |
|---|---|
| `encode_hello.zig` | Plan 1.A host encoder → hello.bin |
| `monitor.S` | Plan 1.D M-mode trap monitor |
| `hello.zig` | Plan 1.D U-mode payload (naked, inline-asm ecalls) |
| `linker.ld` | Plan 1.D linker script (places .text.init at 0x80000000) |
