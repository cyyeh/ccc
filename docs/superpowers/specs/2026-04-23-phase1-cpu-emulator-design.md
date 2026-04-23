# Phase 1 — RISC-V CPU Emulator (Design)

**Project:** From-Scratch Computer (directory `ccc/`).
**Phase:** 1 of 6 — see `2026-04-23-from-scratch-computer-roadmap.md`.
**Status:** Approved design, ready for implementation planning.

## Goal

Write a RISC-V CPU emulator in Zig that can run a cross-compiled bare-metal
"hello world" program. The hello world runs in U-mode and calls `ecall` to
invoke a syscall; an M-mode trap monitor we link in alongside it handles the
syscall and writes the bytes to UART.

## Definition of done

- `ccc hello.elf` prints `hello world\n` to host stdout.
- The emulator passes the relevant subset of the official `riscv-tests`
  suite (rv32ui, rv32um, rv32ua, rv32mi).
- The same `hello.elf` runs in both our emulator and QEMU `riscv32 virt`
  and produces identical UART output.
- An instruction trace (`--trace`) prints one line per executed
  instruction.

## Scope

### In scope

- ISA: **RV32I + M + A + Zicsr + Zifencei** (~60 instructions plus 6 CSR
  ops plus a handful of system ops like `mret`, `wfi`, `ecall`, `ebreak`).
- Privilege levels: **M-mode + U-mode** with synchronous trap handling
  (ECALL, illegal instruction, misaligned access).
- Devices: **NS16550A UART** (output-focused), **CLINT** timer (registers
  exist; interrupt delivery is wired in Phase 2).
- Memory: **128 MB RAM** at `0x80000000`, a tiny boot ROM at
  `0x00001000`.
- Boot model: **ELF loading** (default), with a `--raw <addr>` fallback
  for early bring-up.
- Testing: Zig per-instruction unit tests, riscv-tests integration,
  end-to-end hello world, a QEMU-diff debug harness.
- Debug: `--trace` flag, register/memory dump on unhandled trap.

### Out of scope (deferred to later phases)

- S-mode privilege (Phase 2).
- Sv32 page tables / virtual memory (Phase 2).
- Process scheduling, fork/exec (Phase 3).
- PLIC interrupt controller (Phase 2 if needed; basic CLINT timer
  interrupts are also Phase 2).
- Block device, filesystem (Phase 3).
- Network device, TCP/IP (Phase 4).
- GDB remote stub (later phase if needed).
- C extension (compressed instructions) — skipped intentionally.
- Multiple harts (SMP) — single-core only.
- Floating-point F/D extensions — never planned.

## Architecture

### Component diagram

```
                    ┌──────────────┐
                    │   main.zig   │
                    │  CLI loader  │
                    └──────┬───────┘
                           │
                           ▼
         ┌───────────────────────────────────┐
         │            cpu.zig                │
         │  - 32 GPRs (x0..x31)              │
         │  - PC                             │
         │  - CSRs (mtvec, mepc, mcause, …)  │
         │  - privilege mode (M/U)           │
         │  - step() / run() loop            │
         └───┬──────────┬──────────┬─────────┘
             │          │          │
             ▼          ▼          ▼
       ┌────────┐  ┌────────┐  ┌────────┐
       │decoder │  │execute │  │  trap  │
       │  .zig  │  │  .zig  │  │  .zig  │
       └────────┘  └───┬────┘  └────────┘
                       │
                       ▼
               ┌──────────────┐
               │  memory.zig  │
               │ load/store + │
               │ MMIO dispatch│
               └──┬────────┬──┘
                  │        │
                  ▼        ▼
          ┌─────────┐  ┌─────────┐
          │uart.zig │  │clint.zig│
          │  16550A │  │  timer  │
          └─────────┘  └─────────┘
```

### Per-instruction data flow

1. `cpu.step()` fetches 4 bytes at `PC` via `memory.loadWord(PC)`.
2. `decoder.decode(word)` returns a tagged-union `Instruction`.
3. `execute.dispatch(instr, &cpu)` mutates CPU state, possibly issuing
   memory operations.
4. Memory operations in MMIO ranges go through `memory.zig`'s device
   dispatch.
5. On any synchronous exception (illegal opcode, misaligned access,
   ECALL), `trap.zig` updates CSRs and redirects `PC` to `mtvec`.
6. Control returns to `cpu.run()`, which loops until a halt.

### Module responsibilities

- **`cpu.zig`** — owns hart state (registers, CSRs, PC, privilege).
  Exposes `step()` and `run()`. Knows nothing about specific
  instructions.
- **`decoder.zig`** — pure function: 32-bit word in, `Instruction` tagged
  union out. No state. Easy to unit-test in isolation.
- **`execute.zig`** — per-instruction execution. Big switch on the
  `Instruction` tag. Calls into `memory.zig` for loads/stores and
  `trap.zig` for `ecall`/`ebreak`/illegal.
- **`memory.zig`** — owns the address space. Routes accesses to RAM or to
  an MMIO device based on address range. Returns errors for accesses to
  unmapped addresses (which become traps).
- **`trap.zig`** — encapsulates the trap entry/exit sequence. Updates
  CSRs, switches privilege, redirects `PC`.
- **`devices/uart.zig`** — NS16550A model. Owns no PC-visible state
  except its registers; `write(byte)` reaches host stdout.
- **`devices/clint.zig`** — CLINT model. `mtime` driven by host
  monotonic clock; `mtimecmp` writable; interrupt edge stubbed in
  Phase 1.
- **`elf.zig`** — pure ELF32 loader: parse, copy segments to memory,
  return entry point.
- **`trace.zig`** — formatted per-instruction trace output.
- **`main.zig`** — argv parsing, wires modules together, runs.

This carving puts each module behind a small interface, so Phase 2 can
add S-mode and paging by extending `cpu.zig` + `trap.zig` + `memory.zig`
without touching the decoder or device models.

## Memory layout

Mirrors QEMU `riscv32 virt` (subset):

| Address      | Size   | Purpose                                  |
|--------------|--------|------------------------------------------|
| `0x00001000` | 4 KB   | Boot ROM region (reserved, **unused in Phase 1**; populated in Phase 2 to match QEMU's reset bootstrap) |
| `0x00100000` | 8 B    | Halt MMIO ("test finisher")              |
| `0x02000000` | 64 KB  | CLINT (`msip`, `mtimecmp`, `mtime`)      |
| `0x10000000` | 256 B  | NS16550A UART                            |
| `0x80000000` | 128 MB | Main RAM                                 |

In Phase 1 we cheat the reset sequence: rather than start at the boot
ROM and bootstrap into RAM, we set `PC ← e_entry` directly when loading
the ELF. The boot-ROM region is reserved in the address map so Phase 2
can populate it without re-shuffling addresses.

The halt MMIO address (`0x00100000`) is intentionally chosen to overlap
with QEMU `virt`'s SiFive test/finisher device. Behavior in Phase 1:
write any byte → emulator exits; the value's low byte becomes the host
process exit code. Phase 2 may extend this to full QEMU-finisher
compatibility (encoding `0x5555`/`0x3333` for pass/fail) if a tool we
care about needs it.

## Privilege & trap model

### Modes

- **M-mode (Machine):** highest. All CSRs accessible. The Phase 1 monitor
  lives here.
- **U-mode (User):** lowest. CSR access traps as illegal. The hello
  world payload runs here.

### CSRs implemented

Read-only IDs: `mhartid` (= 0), `mvendorid` (= 0), `marchid` (= 0),
`mimpid` (= 0), `misa` (encodes MXL=RV32, extensions I+M+A+U; **no S
bit** in Phase 1).

Read-write trap state:

- `mstatus` — `MIE`, `MPIE`, `MPP` fields used; rest read-back-as-written
  or zeroed.
- `mtvec` — trap vector base address (we support direct mode only;
  vectored-mode bit ignored in Phase 1).
- `mepc` — trap return PC.
- `mcause` — trap cause code.
- `mtval` — auxiliary value (faulting address for memory traps; 0
  otherwise).
- `mie`, `mip` — present but largely stubbed in Phase 1 (no interrupts
  delivered yet).

### Trap entry (synchronous exception)

1. `mepc ← PC of trapping instruction`.
2. `mcause ← cause code` (e.g., 8 = ECALL_FROM_U, 2 = illegal
   instruction).
3. `mtval ← faulting address or 0`.
4. `mstatus.MPP ← current privilege mode`; `mstatus.MPIE ← mstatus.MIE`;
   `mstatus.MIE ← 0`.
5. Privilege ← M.
6. `PC ← mtvec.BASE`.

### Trap exit (`mret`)

1. `PC ← mepc`.
2. Privilege ← `mstatus.MPP`.
3. `mstatus.MIE ← mstatus.MPIE`; `mstatus.MPIE ← 1`; `mstatus.MPP ← U`.

### `wfi` behavior in Phase 1

`wfi` (Wait For Interrupt) is treated as a no-op (advance PC, continue).
Phase 1 has no interrupt sources wired, so a faithful "wait until
interrupt" would hang forever. Phase 2 will give it real semantics once
timer interrupts exist.

### The Phase 1 monitor

A small M-mode shim (~50 lines of asm + Zig), linked into every test ELF
alongside the U-mode payload. It:

1. Sets `mtvec` to its own trap handler.
2. Sets `mstatus.MPP = U`, `mepc = U-mode entry`, then `mret`s into
   U-mode.
3. On ECALL_FROM_U, dispatches by `a7`:
   - `a7 == 64` (`write`): args `a0=fd, a1=buf, a2=len`. For `fd ∈ {1,
     2}`, copy `len` bytes from RAM at `a1` to UART. Return `a0=len`.
   - `a7 == 93` (`exit`): write 0 to halt MMIO, halting the emulator.
   - Anything else: `a0 ← -ENOSYS`, `mret` back.

Syscall numbers chosen to match the Linux RISC-V ABI subset, so Zig's
freestanding RISC-V build can target them directly. The monitor itself
is teaching scaffolding only — the real kernel arrives in Phase 2.

## Devices

### NS16550A UART (`0x10000000`)

Phase 1 implements just enough for byte-by-byte output:

| Offset | Name | Phase 1 behavior                                       |
|--------|------|--------------------------------------------------------|
| 0x00   | THR  | **Write** → byte goes to host stdout.                  |
| 0x00   | RBR  | Read returns 0; receive is stubbed (Phase 2 wires it). |
| 0x05   | LSR  | Read returns `0x60` (THRE + TEMT, "always ready").     |
| 0x01   | IER  | Writes accepted, no-op.                                |
| 0x02   | FCR/IIR | Writes accepted no-op; reads return 0.              |
| 0x03   | LCR  | Writes accepted, stored, read-back.                    |
| 0x04   | MCR  | Writes accepted, stored, read-back.                    |
| 0x06   | MSR  | Reads return 0.                                        |
| 0x07   | SR   | Scratch — read/write fully modelled.                   |

DLL/DLM divisor latches are write-no-op, read-zero. We don't model
baud-rate timing.

### CLINT (`0x02000000`)

Registers exist; interrupt delivery is **stubbed to never fire** in
Phase 1 (the trap handler can read them but no interrupt edges are
generated):

| Offset    | Name        | Phase 1 behavior                              |
|-----------|-------------|-----------------------------------------------|
| 0x0000    | `msip`      | 32-bit; writes accepted; never raises an IRQ. |
| 0x4000    | `mtimecmp`  | 64-bit; writes accepted.                      |
| 0xBFF8    | `mtime`     | 64-bit; reads return host monotonic ticks at a 10 MHz nominal rate. |

### Halt MMIO (`0x00100000`)

Writing any byte to this address terminates the emulator with the
written byte as exit code (truncated to u8). Used by the monitor's
`exit()` and by riscv-tests' termination convention.

## Boot model

### ELF (default)

`ccc <file.elf>`:

1. Parse ELF header. Verify `EI_CLASS = ELFCLASS32`, `e_machine =
   EM_RISCV`, `e_type = ET_EXEC`.
2. For each `PT_LOAD` program header:
   - Copy `[p_offset, p_offset + p_filesz)` from file → RAM at
     `p_paddr`.
   - Zero `[p_paddr + p_filesz, p_paddr + p_memsz)` (BSS).
3. `PC ← e_entry`. Privilege ← M (the monitor runs first).

### Raw fallback

`ccc --raw 0x80000000 <file.bin>`:

1. Copy file bytes into RAM at the given address.
2. `PC ← that address`. Privilege ← M.

## Testing strategy

### 1. Per-instruction unit tests (`tests/unit/`)

For each instruction, set up a `Cpu`, execute one step, assert post-state.
Coverage target: every encoded instruction at least once with
representative inputs (positive, negative, zero, sign-extension boundary,
overflow). Around 200–300 small Zig `test` blocks.

### 2. riscv-tests integration (`tests/riscv-tests/`)

Official RISC-V conformance suite, included as a git submodule. Each
test is a tiny ELF that exercises one instruction or feature; on success
it writes a magic value to the halt MMIO. Our test runner builds the
suite and runs each ELF through the emulator.

Coverage subset for Phase 1:

- `rv32ui-p-*` — user-mode base integer
- `rv32um-p-*` — multiply / divide
- `rv32ua-p-*` — atomics
- `rv32mi-p-*` — machine-mode (CSRs, traps)

### 3. End-to-end hello world (`tests/programs/hello/`)

`hello.zig` is a freestanding Zig program that performs `write(1, "hello
world\n", 12)` and `exit(0)` via inline-asm `ecall`s. Build pipeline:

```
zig build-exe \
    -target riscv32-freestanding-none \
    -mcpu generic_rv32+m+a+zicsr+zifencei \
    -OReleaseSmall \
    hello.zig
```

linked with `monitor.S` and a small `linker.ld` that places the monitor
at the entry point and the U-mode payload elsewhere in RAM. The test
runs the resulting ELF through the emulator and asserts `"hello
world\n"` appears in captured stdout.

### 4. QEMU-diff harness (debug aid, not CI)

`scripts/qemu-diff.sh <file.elf>`:

1. Run in QEMU: `qemu-system-riscv32 -machine virt -bios none -kernel
   <file.elf> -nographic -singlestep -d in_asm,cpu` → trace A.
2. Run in our emulator: `ccc --trace <file.elf>` → trace B.
3. Diff A and B, line by line, on `(PC, instruction, register state)`.
   First divergence is almost always the bug.

This is a tool we run by hand when stuck, not part of the CI suite.

## Project structure

```
ccc/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig                  # CLI entrypoint
│   ├── cpu.zig                   # hart state + step/run loop
│   ├── decoder.zig               # instruction decode
│   ├── execute.zig               # per-instruction execution
│   ├── memory.zig                # address-space + MMIO dispatch
│   ├── trap.zig                  # exception/ECALL handling
│   ├── elf.zig                   # ELF32 loader
│   ├── trace.zig                 # instruction tracing
│   └── devices/
│       ├── uart.zig              # NS16550A
│       └── clint.zig             # timer
├── tests/
│   ├── unit/                     # per-instruction Zig tests
│   ├── programs/
│   │   └── hello/
│   │       ├── hello.zig         # U-mode payload
│   │       ├── monitor.S         # M-mode trap monitor
│   │       ├── linker.ld
│   │       └── build.zig         # builds the test ELF
│   └── riscv-tests/              # git submodule
├── scripts/
│   └── qemu-diff.sh              # debug harness
└── docs/
    └── superpowers/specs/        # roadmap + per-phase specs
```

## CLI

```
usage: ccc [options] <program>

Run a RISC-V program in the emulator.

Arguments:
  <program>           Path to ELF file (default) or raw binary (with --raw).

Options:
  --raw <addr>        Treat <program> as a raw binary loaded at <addr> (hex).
  --trace             Print one line per executed instruction.
  --memory <MB>       Override RAM size (default: 128).
  --halt-on-trap      Stop on first unhandled trap (default: enter trap handler).
  -h, --help          Show this help.
```

## Risks and open questions

- **Zig version churn.** Zig is pre-1.0 and breaking changes happen
  between minor versions. Mitigation: pin Zig version in
  `build.zig.zon`. Target Zig 0.16.x at project start; re-evaluate at
  each phase boundary.
- **riscv-tests build dependencies.** The official suite typically
  expects `riscv-gnu-toolchain`, which is awkward to install on Mac.
  Mitigation: try Zig's built-in cross-compile first (it can produce
  freestanding RISC-V ELFs); fall back to a Docker image of the
  toolchain if needed; worst case, port a hand-picked subset.
- **CLINT host-time clock.** Driving `mtime` from host wall-clock makes
  emulator timing depend on host load. Acceptable for Phase 1 (no
  interrupts wired); revisit in Phase 2.
- **Misaligned access policy.** RV32IMA permits trapping on misaligned
  loads/stores; some hardware handles them transparently. We trap —
  cleaner, exposes bugs early. If a future workload needs transparent
  handling, we reconsider.
- **Endianness.** RISC-V is little-endian. macOS hosts (Intel and Apple
  Silicon) are little-endian. No conversion needed.
- **Mac vs Linux for QEMU diffs.** `qemu-system-riscv32` works on Mac
  (`brew install qemu`) but instruction tracing flag behavior may
  differ slightly across QEMU versions. Pin a QEMU version in
  `scripts/qemu-diff.sh` documentation.

## Roughly what success looks like at the end of Phase 1

You can run, on a Mac:

```
$ zig build test                                      # all unit tests pass
$ zig build riscv-tests                               # all listed riscv-tests pass
$ zig build run -- tests/programs/hello/hello.elf
hello world
$ zig build run -- --trace tests/programs/hello/hello.elf | head -5
80000000  auipc t0, 0x0          x5  := 0x80000000
80000004  addi  t0, t0, 0x40     x5  := 0x80000040
…
```

…and you understand every line of code in the repo because you wrote it.
