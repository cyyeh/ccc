# Emulator ↔ kernel boundary: how guest code boots

Reference notes on how a RISC-V binary (the kernel, or a freestanding
user program) gets from an ELF file on disk to executing on the emulated
CPU. Useful when trying to understand which code runs first, why
`boot.S` knows the addresses it knows, and what role ELF plays as the
bridge between the build output and the emulator.

Q&A format, distilled from a working session.

## Q1 — What's the relationship between `src/kernel/boot.S` and `src/emulator/`?

They sit on opposite sides of a hardware/software boundary.

**`src/emulator/`** is a bare-metal RV32 CPU emulator written in Zig:

- ISA core: `cpu.zig`, `decoder.zig`, `execute.zig`, `csr.zig`, `trap.zig`
- 128 MB of RAM at `0x80000000` (`memory.zig`)
- MMIO devices in `devices/`: `clint.zig`, `uart.zig`, `plic.zig`,
  `block.zig`, `halt.zig`

It is the *machine* — simulated hardware.

**`src/kernel/boot.S`** is *guest* code that runs on top of that machine.
The kernel linker script drops it at `0x80000000` (`linker.ld:24-28`,
`ENTRY(_M_start)`), which is exactly where the emulator starts fetching
after loading `kernel.elf`. It's the first M-mode instructions the
emulated CPU executes on reset.

The coupling between the two is the **MMIO map**: `boot.S` hard-codes
addresses that `src/emulator/devices/` defines.

| `boot.S` reference | Emulator side |
|---|---|
| `CLINT_MTIMECMP_LO = 0x02004000`, `CLINT_MTIME_LO = 0x0200BFF8` (`boot.S:24-27`) | `CLINT_BASE = 0x0200_0000` + `OFF_MTIMECMP = 0x4000`, `OFF_MTIME = 0xBFF8` (`devices/clint.zig:4-9`) |
| Panic path stores `0xFF` to `0x00100000` (`boot.S:117-119`) | `HALT_BASE = 0x0010_0000`; any byte write halts with that exit code (`devices/halt.zig:3-19`) |
| `mret`, `csrw mtvec`, `mie`, `mstatus` updates | Implemented by the emulator's CSR + trap logic (`csr.zig`, `trap.zig`, `execute.zig`) |

So: emulator = simulated hardware platform; `boot.S` = the kernel's
reset vector that talks to that platform's CLINT and halt MMIO regions
to set up timer interrupts and then `mret`s into `kmain`.

## Q2 — Is `boot.S` the first program the emulator runs?

Only when the program you give the emulator *is* the kernel.

The emulator (`src/emulator/main.zig`) is a general RV32 host: it loads
any ELF you pass on the command line and starts the CPU at that ELF's
entry point. So:

- **`ccc kernel.elf`** → entry point is `_M_start` (`boot.S:39`, declared
  by `ENTRY(_M_start)` in `linker.ld:17`). That's the first instruction
  the emulator executes, in M-mode at PC=`0x80000000`.
- **`ccc hello.elf`** or **`ccc snake.elf`** (the demo programs) → those
  are standalone bare-metal programs with their own entry stubs.
  `boot.S` is not linked in and never runs. See
  [`snake-execution.md`](./snake-execution.md) for snake's M-mode-only
  boot path.

The emulator has no built-in firmware/BIOS; whatever ELF you point it
at *is* "the program." `boot.S` is the first program *of the kernel*,
not the first thing the emulator can ever run.

## Q3 — What is ELF?

**ELF** = **Executable and Linkable Format**. It's the standard binary
container on Linux and most Unix-like systems — used for executables,
object files (`.o`), and shared libraries (`.so`). Originated in Unix
System V around 1989.

An ELF file has three things the emulator cares about:

1. **ELF header** — magic number `0x7F 'E' 'L' 'F'`, target ISA (here:
   RV32), and the **entry point** (the PC value to start execution at).
2. **Program headers (segments)** — each `PT_LOAD` segment says "copy
   these bytes from the file to this virtual address with these
   permissions." This is the loader's view.
3. **Section headers** — `.text`, `.rodata`, `.data`, `.bss`, etc.
   This is the linker's view.

In this project:

- The build produces `kernel.elf` and user programs like `hello.elf`
  and `snake.elf`. Inspect with `riscv64-elf-readelf -h <file>` or
  `file zig-out/bin/<name>.elf`.
- **`src/emulator/elf.zig`** parses the ELF: validates the header,
  walks `PT_LOAD` segments, copies each one into emulated RAM at its
  physical address, then sets `cpu.pc` to the ELF's entry point —
  that's where execution begins.
- **`src/kernel/linker.ld`** is the linker script that *produces* the
  kernel ELF: it puts `.text.init` (containing `boot.S`) at
  `0x80000000` and sets `ENTRY(_M_start)` so the ELF header records
  `_M_start` as the entry point. The emulator then jumps there on
  load.

ELF is the bridge between "compiled program on disk" and "bytes loaded
into the emulated CPU's memory at the right addresses." It's also why
the same emulator can run the kernel and a freestanding user program
with no code changes — both are just ELFs with different entry points
and load addresses.
