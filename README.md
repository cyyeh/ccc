# ccc — Claude Code Computer

Building a working RISC-V computer from scratch in Zig — emulator, kernel,
OS, networking, and a tiny text-mode web browser. No Linux. No TLS. No
graphics.

**Live demo:** [https://cyyeh.github.io/ccc/web/](https://cyyeh.github.io/ccc/web/)
— `ccc` cross-compiled to `wasm32-freestanding`, running RV32 binaries in
your browser. Pick `snake.elf` (default — WASD to play) or `hello.elf` (auto-runs + shows the instruction trace). Same Zig core as the CLI; the browser hosts
the emulator in a Web Worker that drives execution in chunks.

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
- **Devices:** NS16550A UART + CLINT timer (Phase 1). 128 MB RAM at `0x80000000`.
  Plan 3.A adds:
  - **PLIC** (`0x0c00_0000`, 4 MB) — 32 sources × 1 S-mode hart context.
  - **Block device** (`0x1000_1000`, 16 B) — 4 KB sectors, host-file-backed via `--disk`.
  - **UART RX** — 256-byte FIFO, level IRQ via PLIC source 10.
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
| `zig build kernel-user` | Build the Phase 3.B user payload (`zig-out/userprog.elf`, embedded by the kernel) |
| `zig build kernel-user2` | Build the Phase 3.B PID 2 user payload (`zig-out/userprog2.elf`, embedded by `kernel-multi.elf`) |
| `zig build kernel-elf` (or `kernel`) | Build the single-proc `kernel.elf` (M-mode boot shim + S-mode kernel + embedded `userprog.elf`) |
| `zig build kernel-multi` | Build the multi-proc `kernel-multi.elf` (same kernel objects + both `userprog*.elf`) |
| `zig build kernel-fork` | Build the Phase 3.C `kernel-fork.elf` (same kernel objects + embedded `init.elf` + `hello.elf`) |
| `zig build e2e-kernel` | Run `ccc kernel.elf` and assert stdout matches `hello from u-mode\nticks observed: N\n` with N > 0 (Phase 2 §Definition of done) |
| `zig build e2e-multiproc-stub` | Run `ccc kernel-multi.elf` and assert stdout contains both `hello from u-mode\n` and `[2] hello from u-mode\n`, plus a `ticks observed: N\n` trailer (Plan 3.B milestone) |
| `zig build e2e-fork` | Boot `kernel-fork.elf`; `init` forks `/bin/hello`; parent reaps; emulator returns 0 (Plan 3.C milestone) |
| `zig build qemu-diff-kernel` | Diff the kernel.elf trace against `qemu-system-riscv32` (debug aid; needs QEMU installed) |
| `zig build plic-block-test` | Build the Phase 3.A integration test ELF (asm-only S-mode program) |
| `zig build e2e-plic-block` | Build a 4 MB test image, run `ccc --disk … plic_block_test.elf`, assert exit 0 (Plan 3.A milestone: full CMD → IRQ → trap → claim path) |
| `zig build snake-elf` | Build the Phase 3 snake demo ELF (M-mode RV32, CLINT timer IRQ + UART poll, 32×16 ASCII game) |
| `zig build snake-test` | Run `programs/snake/game.zig` unit tests on the native target (pure game logic, target-independent) |
| `zig build run-snake` | Play `snake.elf` in the CLI under stty raw mode (single-keystroke WASD/q/SPACE input) |
| `zig build e2e-snake` | Pipe `tests/e2e/snake_input.txt` through `--input`, assert stdout contains `GAME OVER` + `score: 0` (~4 s wall clock) |
| `zig build fixtures` | Build `tests/fixtures/minimal.elf` (used only by `src/emulator/elf.zig` tests) |
| `zig build riscv-tests` | Assemble + link + run the official `rv32ui/um/ua/mi/si-p-*` conformance suite (67 tests) |
| `zig build wasm` | Cross-compile `demo/web_main.zig` to `wasm32-freestanding` (installed to `zig-out/web/ccc.wasm`); also installs `hello.elf` and `snake.elf` into `zig-out/web/` for the demo to fetch at runtime |

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
    --disk PATH          Back the block device with this 4 MB host file.
    --input PATH         Stream this file's bytes into the UART RX FIFO.
    --disk-latency CYC   Reserved (no-op in Phase 3.A).

ISA coverage: RV32I + M + A + Zicsr + Zifencei, M/S/U privilege,
synchronous traps with delegation, async interrupt delivery, Sv32
paging. `--trace` renders a `[M]`/`[S]`/`[U]` privilege column, plus
synthetic markers on async events:

    --- interrupt N (<name>) taken in <old>, now <new> ---
    --- interrupt 9 (supervisor external, src N) taken in <old>, now <new> ---
    --- block: read sector S at PA 0x<P> ---

## Web demo

Live: [https://cyyeh.github.io/ccc/web/](https://cyyeh.github.io/ccc/web/) — see [`web/README.md`](web/README.md) for architecture, controls, programs, local dev, and how to add another ELF.

CI: `.github/workflows/pages.yml` runs the existing `zig build test`
+ every `e2e-*` step on every PR; on push to `main` it builds the
wasm and deploys the deck + demo to Pages. Pages source must be set
to "GitHub Actions" in repo settings (one-time manual step).

## Status

**Phase 3 Plan C done — fork / exec / wait / exit / kill-flag.** Plan 3.A
merged: PLIC, simple block device, UART RX, `--disk` and `--input` flags,
real `wfi` idle. Plan 3.B merged: free-list page allocator, `ptable[NPROC=16]`,
round-robin scheduler with `swtch`, kernel-side ELF32 loader,
`getpid`/`sbrk`/`yield` syscalls, second embedded user ELF,
`e2e-multiproc-stub` running PID 1 + PID 2. Plan 3.C merged: `fork` (full
address-space copy), `execve` (in-place AS rebuild + System-V argv tail),
`wait4` (sleep on self until zombie child), `exit` (reparent + zombie + wake
parent), and `kill` flag (`^C`-style poison checked on syscall return);
`e2e-fork` runs `init` → fork → exec `/bin/hello` → parent reaps to exit 0.

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

**Phase 3 — multi-process OS + filesystem + shell — in progress.**

Plan 3.A (emulator: PLIC + simple block device + UART RX + `--disk`/`--input`
flags + real `wfi` idle) is merged. The CPU now blocks in `wfi` until an
async interrupt is pending; the PLIC routes UART RX (source 10) and block
completion (source 1) into S-mode external interrupts; the block device
serves 4 KB sectors out of a host-backed file at `0x1000_1000`.

Plan 3.B (kernel-side multi-process foundation) is merged. `page_alloc.zig`
is now a free-list (`alloc`/`free`/`freeCount`); the kernel keeps a static
`ptable[NPROC=16]` of `Process` records with per-proc kernel stacks and saved
`Context` (callee-saved kernel regs); a round-robin scheduler runs on its
own kernel stack and `swtch`-es into the next `Runnable` proc; a kernel-side
ELF32 loader (`elfload.zig`) walks `PT_LOAD` segments and installs user
PTEs via callback. New syscalls land: `getpid` (#172), `sbrk` (#214), and
real `yield` (#124, now drives the scheduler). A second `kernel-multi.elf`
build embeds two user ELFs (`userprog.elf` + `userprog2.elf`) and hand-creates
PID 1 + PID 2 at boot; `e2e-multiproc-stub` runs both processes through the
scheduler interleaving:

    $ zig build kernel-multi && zig build run -- zig-out/bin/kernel-multi.elf
    [2] hello from u-mode
    hello from u-mode
    ticks observed: 23

Single-proc `e2e-kernel` regression continues to pass byte-for-byte.

Plan 3.C (fork / exec / wait / exit / kill-flag) is merged. New VM helpers
(`unmapUser`, `copyUvm`, `copyUserStack` with rollback on OOM) and a real
`proc.free` reaper enable a full address-space copy in `fork`; `execve`
rebuilds the address space in place and lays out the System-V argv tail;
`wait4` sleeps on self until a zombie child appears; `exit` reparents
children, marks the proc zombie, and wakes the parent; a `killed` flag
(set by `proc.kill`, checked on every syscall return) is the `^C`-style
poison primitive. A new `kernel-fork.elf` embeds two ELFs (`init.elf` +
`hello.elf`); `init` forks `/bin/hello`, the child execs and prints, and
the parent `wait`s and prints `init: reaped` before exiting 0:

    $ zig build kernel-fork && zig build run -- zig-out/bin/kernel-fork.elf
    hello from /bin/hello
    init: reaped
    ticks observed: 3

Next: Plan 3.D — filesystem + shell.

## Layout

```
src/
  emulator/
    main.zig          # CLI entry point (ELF default, --raw fallback; --disk/--input/--trace/etc.)
    lib.zig           # re-export shim consumed by demo/web_main.zig (wasm build)
    cpu.zig           # hart state: regs, PC, privilege, CSRs, LR/SC reservation; idleSpin (wfi)
    decoder.zig       # RV32IMA + Zicsr + Zifencei + mret/sret/wfi/sfence.vma decoder
    execute.zig       # instruction execution + trap-routing; wfi → cpu.idleSpin
    memory.zig        # RAM + MMIO dispatch (UART, CLINT, PLIC, block, halt, tohost) + Sv32 translation
    csr.zig           # M/S CSRs with field masks, privilege checks, live MTIP/SEIP from devices
    trap.zig          # sync + async trap entry, mret/sret exit, medeleg/mideleg routing
    elf.zig           # ELF32 loader (entry + tohost symbol resolution)
    trace.zig         # --trace one-line-per-instruction formatter + interrupt/block markers
    devices/
      uart.zig        # NS16550A UART (TX + 256B RX FIFO + level IRQ via PLIC src 10)
      halt.zig        # test-only halt device at 0x00100000
      clint.zig       # Core-Local Interruptor (msip, mtimecmp, mtime; raises mip.MTIP; comptime clock branch for wasm)
      plic.zig        # Platform-Level Interrupt Controller (32 sources, S-context, claim/complete)
      block.zig       # Simple MMIO block device (4 KB sectors, host-file-backed via --disk)
  kernel/             # Phase 2/3: M-mode boot + S-mode kernel + ptable scheduler + ELF-loaded userprogs
    kmain.zig         # S-mode entry; allocates PID 1, builds address space, switches to scheduler
    boot.S            # M-mode boot shim
    trampoline.S      # user/kernel trampoline
    mtimer.S          # mtimer ISR
    swtch.S           # context switch
    elfload.zig       # in-kernel ELF32 loader (PT_LOAD walker + page-table installer)
    vm.zig            # Sv32 page table + copyUvm/unmapUser/freeLeavesInL0
    proc.zig          # Process struct, fork/exec/wait/exit/kill, sleep/wakeup
    sched.zig         # round-robin scheduler + swtch
    syscall.zig       # syscall dispatch (write/exit/yield/getpid/sbrk/fork/execve/wait4/...)
    trap.zig          # S-mode trap dispatcher; killed-flag check on syscall return
    page_alloc.zig    # free-list page allocator
    kprintf.zig       # kernel print helper
    uart.zig          # kernel-side UART driver
    linker.ld         # kernel.elf load layout
    user/
      userprog.zig    # PID 1 user payload (embedded into kernel.elf)
      userprog2.zig   # PID 2 user payload (embedded into kernel-multi.elf)
      init.zig        # init userland for kernel-fork.elf (fork+exec+wait)
      hello.zig       # hello userland for kernel-fork.elf (write+exit)
      user_linker.ld  # user-side linker script
demo/
  web_main.zig        # freestanding wasm entry — runStart/runStep/setMtimeNs/pushInput/consumeOutput, fixed 2 MB ELF buffer (programs fetched at runtime, not embedded)
programs/
  hello/              # Phase 1: RV32I hello-world encoder + Phase 1.D Zig-compiled hello.elf
  snake/              # Phase 3 demo: bare M-mode RV32 snake game + game.zig pure-logic
  mul_demo/           # Phase 1: RV32IMA demo encoder (prints "42\n")
  trap_demo/          # Phase 1.C: privilege demo (prints "trap ok\n")
  plic_block_test/    # Phase 3.A: asm-only integration test (CMD → IRQ → trap → claim → halt)
tests/
  e2e/                # host-side end-to-end verifiers (Zig programs that spawn ccc and assert stdout)
    kernel.zig        # Plan 2.D verifier (Phase 2 §Definition of done)
    multiproc.zig     # Plan 3.B verifier (PID 1 + PID 2 interleaving)
    fork.zig          # Plan 3.C verifier (fork/exec/wait/exit)
    snake.zig         # snake e2e verifier (deterministic input → GAME OVER)
  fixtures/           # tiny hand-crafted ELF used only by elf.zig tests
  riscv-tests/        # upstream submodule: riscv-software-src/riscv-tests
  riscv-tests-shim/   # weak handlers + riscv_test.h overrides for the shared test env
  riscv-tests-p.ld    # linker script for the 'p' (physical/M-mode) environment
  riscv-tests-s.ld    # linker script for the rv32si-p-* family (S-mode test body)
web/                  # GitHub Pages root (https://cyyeh.github.io/ccc/web/)
  index.html          # demo page (program selector + focusable terminal + auto-trace panel)
  demo.css            # palette matches the deck
  demo.js             # main thread: Worker host, ANSI renderer, program-select handler, keystroke filter
  runner.js           # Web Worker: chunked runStep loop, ELF fetch, output/trace drain
  ansi.js             # ~120-line ANSI subset interpreter (CSI 2J/H/?25, UTF-8 reassembly)
  ccc.wasm            # built artifact (~30 KB; emulator core only) — gitignored
  hello.elf           # built artifact (~10 KB; fetched at runtime) — gitignored
  snake.elf           # built artifact (~1.4 MB Debug; fetched at runtime) — gitignored
  README.md           # how the demo works + how to add another ELF
scripts/
  qemu-diff.sh           # debug aid: per-instruction trace diff vs qemu-system-riscv32
  qemu-diff-kernel.sh    # same, scoped to kernel.elf (Phase 2 debugging)
  stage-web.sh           # local dev: zig build wasm + copy ccc.wasm + hello.elf + snake.elf into web/
  run-snake.sh           # CLI snake wrapper (stty raw mode + restore on exit)
docs/
  superpowers/
    specs/          # design docs per phase (brainstormed + approved)
    plans/          # implementation plans per phase
  references/       # notes on RISC-V specifics (traps, etc.)
.github/
  workflows/
    pages.yml       # CI: test on every PR; build wasm + deploy Pages on push to main
build.zig           # build graph: ccc + tests + demos + fixtures + riscv-tests + plic-block-test + wasm
build.zig.zon       # pinned Zig version + dependencies
```

The roadmap lives at
[`docs/superpowers/specs/2026-04-23-from-scratch-computer-roadmap.md`](docs/superpowers/specs/2026-04-23-from-scratch-computer-roadmap.md).

## License

[MIT](LICENSE)
