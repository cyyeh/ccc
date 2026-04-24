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

| # | Phase | Demo |
|---|-------|------|
| 1 | RISC-V CPU emulator | `ccc hello.elf` prints `hello world` |
| 2 | Bare-metal kernel | user program calls `write()`, kernel prints it |
| 3 | Multi-process OS + FS + shell | boot to a shell, run our own programs |
| 4 | Network stack | `ping 1.1.1.1` from inside our OS |
| 5 | HTTP/1.0 client + text browser | browse plain-HTTP pages by link number |

## Design choices

- **Language:** Zig (version pinned per-phase).
- **ISA:** RV32I + M + A + Zicsr + Zifencei. Single hart. No F/D, no C.
- **Privilege:** M-mode + S-mode + U-mode. Sv32 paging (4 KB pages, no
  superpages, no TLB model).
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
| `zig build hello` | Build the hand-crafted RV32I hello-world binary |
| `zig build e2e` | Encode → emulate → assert stdout equals `hello world\n` (RV32I) |
| `zig build mul-demo` | Build the hand-crafted RV32IMA demo binary |
| `zig build e2e-mul` | Encode → emulate → assert stdout equals `42\n` (M + A + Zifencei) |
| `zig build trap-demo` | Build the hand-crafted Plan 1.C privilege/trap demo binary |
| `zig build e2e-trap` | M→U→ecall→M→UART→halt round-trip; stdout equals `trap ok\n` |
| `zig build hello-elf` | Build the Zig-compiled `hello.elf` (M-mode monitor + U-mode Zig payload) |
| `zig build e2e-hello-elf` | Run `ccc hello.elf` and assert stdout equals `hello world\n` (Phase 1 §Definition of done) |
| `zig build fixtures` | Build `tests/fixtures/minimal.elf` (used only by `src/elf.zig` tests) |
| `zig build riscv-tests` | Assemble + link + run the official `rv32ui/um/ua/mi/si-p-*` conformance suite (67 tests) |

## Running programs

By default `ccc` loads an ELF32 RISC-V executable:

    zig build hello-elf                          # build the demo ELF
    zig build run -- zig-out/bin/hello.elf       # prints "hello world"

For hand-crafted raw binaries (the `e2e`, `e2e-mul`, `e2e-trap` demos),
pass the load address with `--raw`:

    zig build run -- --raw 0x80000000 path/to/program.bin

Extra flags:

    --trace              Print one line per executed instruction to stderr.
    --halt-on-trap       Stop on first unhandled trap; dump regs/CSRs.
    --memory <MB>        Override RAM size (default: 128).

ISA coverage: RV32I + M + A + Zicsr + Zifencei, M/S/U privilege,
synchronous traps with delegation, async interrupt delivery, Sv32
paging. `--trace` renders a `[M]`/`[S]`/`[U]` privilege column, plus
a synthetic `--- interrupt N (<name>) taken in <old>, now <new> ---`
marker on async trap entry.

## Status

**Phase 1 — RISC-V CPU emulator — complete.**

Plans 1.A (RV32I), 1.B (M + A + Zifencei), 1.C (Zicsr + privilege + traps
+ CLINT + ELF + `--trace` + riscv-tests), and 1.D (monitor + Zig
`hello.elf` + QEMU-diff + rv32mi conformance) are merged.

The Phase 1 §Definition of done demo:

    $ zig build e2e-hello-elf
    # passes: stdout equals "hello world\n"

    $ zig build hello-elf && zig build run -- zig-out/bin/hello.elf
    hello world

**Plan 2.B (emulator trap delegation + async interrupts) merged.**

The emulator now supports, in addition to the Plan 2.A surface:

- `medeleg` / `mideleg` WARL storage; synchronous trap routing to S when
  the cause bit is delegated and the current privilege is < M.
- Asynchronous interrupt delivery: per-instruction-boundary check of
  `mip & mie` with delegation via `mideleg` and per-privilege enable
  gating (`mstatus.MIE` / `mstatus.SIE`).
- CLINT `mtime >= mtimecmp && mtimecmp != 0` drives live `mip.MTIP`;
  writes to `mip.MTIP` are silently dropped (hardware-only signal).
- `--trace` emits a synthetic marker on async interrupt entry:
  `--- interrupt N (<name>) taken in <old>, now <new> ---`.
- `rv32si-p-*` conformance now also includes `sbreak` and `ma_fetch`.
  Only `dirty` remains excluded — it depends on Sv32 superpages, which
  the Phase 2 spec permanently rejects.

The end-to-end `CLINT → M MTI ISR → mip.SSIP → S SSI ISR` forwarding
round-trip is validated by a dedicated integration test in
`src/cpu.zig` — the substrate Plan 2.C's kernel `mtimer.S` will
consume.

Next: **Plan 2.C — kernel skeleton (M-mode boot shim, single page
table, sret-to-U, user `write`+`exit` demo)**.

## Layout

```
src/
  main.zig          # CLI entry point (ELF default, --raw fallback)
  cpu.zig           # hart state: regs, PC, privilege, CSRs, LR/SC reservation
  decoder.zig       # RV32I + M + A + Zifencei + Zicsr + mret/wfi decoder
  execute.zig       # instruction execution (trap-routing)
  memory.zig        # RAM + MMIO dispatch (UART, CLINT, halt, tohost)
  csr.zig           # CSR read/write with field masks + privilege checks
  trap.zig          # synchronous trap entry + mret exit
  elf.zig           # ELF32 loader (entry + tohost symbol resolution)
  trace.zig         # --trace one-line-per-instruction formatter
  devices/
    uart.zig        # NS16550A UART
    halt.zig        # test-only halt device at 0x00100000
    clint.zig       # Core-Local Interruptor (msip, mtimecmp, mtime)
tests/
  programs/
    hello/          # RV32I hello-world encoder + expected output
    mul_demo/       # RV32IMA demo encoder (prints "42\n")
    trap_demo/      # Plan 1.C privilege demo (prints "trap ok\n")
  fixtures/         # tiny hand-crafted ELF used only by elf.zig tests
  riscv-tests/      # upstream submodule: riscv-software-src/riscv-tests
  riscv-tests-p.ld  # linker script for the 'p' (physical/M-mode) environment
  riscv-tests-s.ld  # linker script for the rv32si-p-* family (S-mode test body)
docs/
  superpowers/
    specs/          # design docs per phase (brainstormed + approved)
    plans/          # implementation plans per phase
  references/       # notes on RISC-V specifics (traps, etc.)
build.zig           # build graph: ccc + tests + demos + fixtures + riscv-tests
build.zig.zon       # pinned Zig version + dependencies
```

The roadmap lives at
[`docs/superpowers/specs/2026-04-23-from-scratch-computer-roadmap.md`](docs/superpowers/specs/2026-04-23-from-scratch-computer-roadmap.md).

## License

[MIT](LICENSE)
