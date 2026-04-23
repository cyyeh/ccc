# ccc — Claude Code Computer

Building a working RISC-V computer from scratch in Zig — emulator, kernel,
OS, networking, and a tiny text-mode web browser. No Linux. No TLS. No
graphics.

## Goal

Go from an empty repo to `browse http://test-server/` rendering a page in
our own terminal browser, with every layer written ourselves:

1. A RISC-V CPU emulator
2. A bare-metal kernel with traps, page tables, and privilege transitions
3. A multi-process OS with a filesystem and shell
4. A from-scratch network stack (Ethernet → ARP → IP → ICMP → UDP → TCP → DNS)
5. An HTTP/1.0 client and a terminal HTML renderer

## Phases

| # | Phase | Rough effort | Demo |
|---|-------|--------------|------|
| 0 | Toolchain & Zig warm-up | 2–4 weeks | asm hello world runs in QEMU |
| 1 | RISC-V CPU emulator | 2–4 months | `ccc hello.elf` prints `hello world` |
| 2 | Bare-metal kernel | 2–3 months | user program calls `write()`, kernel prints it |
| 3 | Multi-process OS + FS + shell | 3–4 months | boot to a shell, run our own programs |
| 4 | Network stack | 3–6 months | `ping 1.1.1.1` from inside our OS |
| 5 | HTTP/1.0 client + text browser | 1–3 months | browse plain-HTTP pages by link number |

Total scope: roughly 12–20 months of focused part-time work.

## Design choices

- **Language:** Zig (version pinned per-phase).
- **ISA:** RV32I + M + A + Zicsr + Zifencei. Single hart. No F/D, no C.
- **Privilege (Phase 1):** M-mode + U-mode only; S-mode and Sv32 land in Phase 2.
- **Devices (Phase 1):** NS16550A UART + CLINT timer. 128 MB RAM at `0x80000000`.
- **Host platform:** macOS. Phase 4 may move to a Linux VM for TAP/TUN.
- **Decomposition rule:** one phase's spec at a time — brainstorm → spec →
  plan → implementation, then repeat.

## Building

The project uses Zig's build system. `build.zig` declares the build graph
and `build.zig.zon` pins the minimum Zig version (0.16.0).

| Command | What it does |
|---|---|
| `zig build` | Compile `ccc` and install to `zig-out/bin/` |
| `zig build run -- <args>` | Build and execute `ccc`, forwarding args after `--` |
| `zig build test` | Run all unit tests reachable from `src/main.zig` |
| `zig build hello` | Build the hand-crafted RV32I hello-world binary to `zig-out/hello.bin` |
| `zig build e2e` | Encode → emulate → assert stdout equals `hello world\n` (RV32I) |
| `zig build mul-demo` | Build the hand-crafted RV32IMA demo binary to `zig-out/mul_demo.bin` |
| `zig build e2e-mul` | Encode → emulate → assert stdout equals `42\n` (exercises M + A + Zifencei) |

The `hello`/`e2e` and `mul-demo`/`e2e-mul` step pairs are worth a closer
look: each has a small host-side encoder under `tests/programs/` that
emits a raw binary, which the corresponding `e2e*` step feeds to
`ccc --raw 0x80000000` and checks the UART output. All artifacts
(encoder, binary, emulator run) are wired into the build graph so
changes propagate automatically. The `e2e` demo covers RV32I only; the
`e2e-mul` demo additionally exercises M (`mul`, `divu`, `remu`), A
(`amoswap.w`), and Zifencei (`fence.i`).

Cross-compilation and optimization flags are exposed via the standard
`-Dtarget=…` and `-Doptimize=…` options.

## Status

Currently on **Phase 1 — RISC-V CPU emulator**. Plans 1.A (RV32I) and
1.B (M + A + Zifencei) are merged. Plan 1.C (Zicsr + privilege + traps)
is next.

## Layout

```
src/
  main.zig          # CLI entry point
  cpu.zig           # hart state: registers, PC, CSRs
  decoder.zig       # RV32I + M + A + Zicsr + Zifencei decoder
  execute.zig       # instruction execution
  memory.zig        # RAM + MMIO dispatch
  devices/
    uart.zig        # NS16550A UART
    halt.zig        # test-only halt device
tests/
  programs/
    hello/          # RV32I hello-world encoder + expected output
docs/
  superpowers/
    specs/          # design docs per phase (brainstormed + approved)
    plans/          # implementation plans per phase
  references/       # notes on RISC-V specifics (traps, etc.)
build.zig           # build graph: ccc binary, tests, hello, e2e
build.zig.zon       # pinned Zig version + dependencies
```

The roadmap lives at
[`docs/superpowers/specs/2026-04-23-from-scratch-computer-roadmap.md`](docs/superpowers/specs/2026-04-23-from-scratch-computer-roadmap.md).

## License

[MIT](LICENSE)
