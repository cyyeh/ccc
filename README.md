# ccc — Claude Code Computer

Building a working RISC-V computer from scratch in Zig — emulator, kernel,
OS, networking, and a tiny text-mode web browser. No Linux. No TLS. No
graphics.

**Live demo:** [https://cyyeh.github.io/ccc/web/](https://cyyeh.github.io/ccc/web/)
— `ccc` cross-compiled to `wasm32-freestanding`, running `hello.elf` in your
browser. Same Zig core as the CLI; new ~80-line entry point for the browser.

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
| `zig build kernel-user` | Build the Plan 2.C user payload to a flat binary (`zig-out/userprog.bin`) |
| `zig build kernel-elf` (or `kernel`) | Build the Plan 2.C `kernel.elf` (M-mode boot shim + S-mode kernel + embedded user blob) |
| `zig build e2e-kernel` | Run `ccc kernel.elf` and assert stdout matches `hello from u-mode\nticks observed: N\n` with N > 0 (Phase 2 §Definition of done) |
| `zig build qemu-diff-kernel` | Diff the kernel.elf trace against `qemu-system-riscv32` (debug aid; needs QEMU installed) |
| `zig build fixtures` | Build `tests/fixtures/minimal.elf` (used only by `src/elf.zig` tests) |
| `zig build riscv-tests` | Assemble + link + run the official `rv32ui/um/ua/mi/si-p-*` conformance suite (67 tests) |
| `zig build wasm` | Cross-compile `demo/web_main.zig` to `wasm32-freestanding` (installed to `zig-out/web/ccc.wasm`; powers the live web demo) |

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

## Web demo

Live: [https://cyyeh.github.io/ccc/web/](https://cyyeh.github.io/ccc/web/)

The browser demo cross-compiles the same emulator core
(`cpu.zig` / `memory.zig` / `elf.zig` / `devices/*.zig`) to
`wasm32-freestanding` via a thin entry point at `demo/web_main.zig`
(plus a one-file `src/lib.zig` shim that exposes the emulator as a
single named module). `hello.elf` is embedded into the wasm at
compile time; the JS side fetches `ccc.wasm`, instantiates it with
no imports, calls a single `run(trace) -> i32` export, and copies
the captured UART output out of linear memory via `outputPtr()` /
`outputLen()`. Zero JS dependencies, zero WASM imports.

The page renders a terminal-style session — typed `$ ./ccc hello.elf`
prompt followed by the captured `hello world` output. A
`show instruction trace` checkbox enables `cpu.trace_writer` and
exposes the per-instruction CPU log in a collapsible panel below the
output.

Local dev:

    ./scripts/stage-web.sh              # zig build wasm + copy into web/
    python3 -m http.server -d . 8000
    open http://localhost:8000/web/

CI: `.github/workflows/pages.yml` runs the existing `zig build test`
+ every `e2e-*` step on every PR; on push to `main` it builds the
wasm and deploys the deck + demo to Pages. Pages source must be set
to "GitHub Actions" in repo settings (one-time manual step).

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

**Phase 2 — Bare-metal kernel — complete.**

Plans 2.A (emulator S-mode + Sv32 paging), 2.B (trap delegation + async
interrupts), 2.C (kernel skeleton: boot shim, page table, S-mode trap
dispatcher, `write`/`exit` demo), and 2.D (Process struct + scheduler
stub + `yield` + tick counter) are merged.

The Phase 2 §Definition of done demo:

    $ zig build e2e-kernel
    # passes: stdout matches "hello from u-mode\nticks observed: N\n" with N > 0

    $ zig build kernel && zig build run -- zig-out/bin/kernel.elf
    hello from u-mode
    ticks observed: 19

Three privilege levels active in a single run: M-mode boot shim (sets up
delegation + CLINT, forwards MTI to SSIP on each tick), S-mode kernel
(manages Sv32 page table, trap dispatcher, syscalls `write`/`exit`/`yield`,
increments tick counter), U-mode user program (writes, yields, busy-loops,
exits). The scheduler stub always re-picks the single process; Phase 3
will swap in a real picker behind the same `sched.schedule()` interface.

Debug aids: `zig build qemu-diff-kernel` runs `scripts/qemu-diff-kernel.sh`,
which compares per-instruction traces between our emulator and QEMU.
Requires `qemu-system-riscv32`; not a CI gate.

Next: **Phase 3 — multi-process OS + filesystem + shell.**

## Layout

```
src/
  main.zig          # CLI entry point (ELF default, --raw fallback)
  lib.zig           # re-export shim consumed by the wasm build (one named module)
  cpu.zig           # hart state: regs, PC, privilege, CSRs, LR/SC reservation
  decoder.zig       # RV32I + M + A + Zifencei + Zicsr + mret/wfi decoder
  execute.zig       # instruction execution (trap-routing)
  memory.zig        # RAM + MMIO dispatch (UART, CLINT, PLIC, halt, tohost)
  csr.zig           # CSR read/write with field masks + privilege checks
  trap.zig          # synchronous trap entry + mret exit
  elf.zig           # ELF32 loader (entry + tohost symbol resolution)
  trace.zig         # --trace one-line-per-instruction formatter
  devices/
    uart.zig        # NS16550A UART
    halt.zig        # test-only halt device at 0x00100000
    clint.zig       # Core-Local Interruptor (msip, mtimecmp, mtime) — comptime clock branch for wasm
    plic.zig        # Platform-Level Interrupt Controller (Phase 3, in progress)
demo/
  web_main.zig      # freestanding wasm entry — embeds hello.elf, exports run/outputPtr/outputLen + tracePtr/traceLen
web/                # GitHub Pages root (https://cyyeh.github.io/ccc/web/)
  index.html        # demo page (terminal-style typed-command UI + optional trace panel)
  demo.css          # palette matches the deck
  demo.js           # ~80 lines: instantiate, type cmd, call run(), copy output, render trace
  README.md         # how the demo works + how to add another ELF
tests/
  programs/
    hello/          # RV32I hello-world encoder + expected output
    mul_demo/       # RV32IMA demo encoder (prints "42\n")
    trap_demo/      # Plan 1.C privilege demo (prints "trap ok\n")
    kernel/         # Phase 2 kernel: boot.S, kmain.zig, sched, proc, vm,
                    # syscall, trap, kprintf, mtimer, trampoline, uart,
                    # linker.ld, verify_e2e.zig, user/ (U-mode payload)
  fixtures/         # tiny hand-crafted ELF used only by elf.zig tests
  riscv-tests/      # upstream submodule: riscv-software-src/riscv-tests
  riscv-tests-shim/ # riscv_test.h + weak trap handlers for the test env
  riscv-tests-p.ld  # linker script for the 'p' (physical/M-mode) environment
  riscv-tests-s.ld  # linker script for the rv32si-p-* family (S-mode test body)
docs/
  superpowers/
    specs/          # design docs per phase (brainstormed + approved)
    plans/          # implementation plans per phase
  references/       # notes on RISC-V specifics (traps, etc.)
scripts/
  qemu-diff.sh         # per-instruction trace diff vs. qemu-system-riscv32
  qemu-diff-kernel.sh  # same, scoped to kernel.elf (Phase 2 debug aid)
  stage-web.sh         # local dev: zig build wasm + copy ccc.wasm into web/
.github/
  workflows/
    pages.yml       # CI: test on every PR; build wasm + deploy Pages on push to main
build.zig           # build graph: ccc + tests + demos + fixtures + riscv-tests + wasm
build.zig.zon       # pinned Zig version + dependencies
```

The roadmap lives at
[`docs/superpowers/specs/2026-04-23-from-scratch-computer-roadmap.md`](docs/superpowers/specs/2026-04-23-from-scratch-computer-roadmap.md).

## License

[MIT](LICENSE)
