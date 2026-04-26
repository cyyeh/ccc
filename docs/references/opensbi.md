# OpenSBI and our kernel

Reference notes on what OpenSBI is, how it relates to our current
implementation, and when (if ever) we'd need to adopt it.

## What is OpenSBI?

[OpenSBI](https://github.com/riscv-software-src/opensbi) is the reference
implementation of the **RISC-V Supervisor Binary Interface (SBI)** — a
standardized ABI between an S-mode kernel and the M-mode firmware running
underneath it. It's the equivalent of UEFI / PSCI in the RISC-V world.

Two roles in one binary:

1. **M-mode firmware** — runs at boot, sets up CSRs, delegates traps, then
   drops the kernel into S-mode.
2. **SBI runtime** — stays resident; the kernel makes `ecall`s into M-mode to
   request console I/O, timer programming, IPIs, remote fences, shutdown,
   etc.

The SBI ABI is versioned. Common extensions:

| Extension | EID | Purpose |
|-----------|-----|---------|
| Legacy console putchar | `0x01` | Early-boot console output |
| TIME | `0x54494D45` | Set per-hart timer (`sbi_set_timer`) |
| IPI | `0x735049` | Send IPI to a hart mask |
| RFENCE | `0x52464E43` | Remote `sfence.vma` / `fence.i` |
| HSM | `0x48534D` | Hart State Management (start/stop/suspend) |
| SRST | `0x53525354` | System reset (shutdown / reboot) |

## Where we stand today

Our kernel does **not** use OpenSBI. It rolls its own M-mode shim:

- **M-mode boot shim** — `src/kernel/boot.S:1-97`
  - Zeroes BSS, programs `mtvec`
  - Sets `medeleg` / `mideleg` to forward U→S faults and SSIP into S-mode
  - Programs CLINT (`mtimecmp = mtime + TIMESLICE`), enables `mie.MTIE`
  - Sets `mstatus.MPP = S`, `mepc = kmain`, then `mret` into S-mode
- **S-mode kernel** — `src/kernel/kmain.zig:27` onward
  - Owns paging, scheduler, syscalls, ELF loading
  - Talks to devices directly:
    - UART MMIO at `0x10000000` (`uart.zig:7`)
    - CLINT MMIO at `0x0200_0000` (`mtimer.S:21-69`)
- **U → S syscalls** — `ecall` from U-mode, dispatched via
  `s_trap_entry` in `trampoline.S` and `syscall.zig:111-120`
  (write / exit / yield / getpid / sbrk). No S → M ecalls anywhere.

So architecturally we're at:

```
U-mode app   (ecall, syscall ABI)
   │
S-mode kernel   (paging, scheduler, drivers)
   │
M-mode shim   (boot.S — 97 lines)
   │
Emulator      (no firmware layer)
```

The "OpenSBI shape" exists, but inlined as 97 lines of assembly instead of a
real SBI implementation.

## When we'd need OpenSBI

We'd adopt OpenSBI the moment we stop being our own M-mode firmware:

1. **Real RISC-V hardware** (HiFive, VisionFive, PolarFire, …). Board ROMs
   expect to hand off to an SBI implementation; the standard chain is
   ROM → OpenSBI → S-mode kernel.
2. **QEMU `-bios default`** — QEMU ships OpenSBI as the default `-bios` for
   `-machine virt`. The moment we boot via `-bios` instead of `-kernel`-as-
   M-mode-entry, we're already on OpenSBI and must call SBI for console /
   timer.
3. **SMP / multi-hart** — `sbi_send_ipi` and `sbi_rfence_*` are painful to
   roll yourself across many harts; the SBI ABI does the heavy lifting.
4. **Clean reset / shutdown** (SRST, HSM) — SBI gives a portable shutdown
   path instead of board-specific MMIO pokes.

## When we don't need it

Right now: never. Reasons to stay on the M-mode shim:

- Our emulator has no firmware layer — the kernel ELF *is* the entry point.
- Single hart, no SMP — IPIs and remote fences aren't a concern.
- Direct MMIO is simpler to teach and debug than an SBI call layer.
- Adding OpenSBI would mean a build dependency, a separate firmware blob,
  and an extra trap path on every console write — pure overhead for the
  toy environment.

## What migration would look like

If we ever flip the switch, the work is mostly mechanical:

1. **Delete `boot.S`** — OpenSBI handles M-mode init and drops us in S-mode
   at `kmain` directly.
2. **Replace direct UART writes** in `uart.zig` with an `sbi_call`
   wrapper invoking the legacy console putchar (EID `0x01`) or the newer
   DBCN extension.
3. **Replace direct CLINT pokes** in `mtimer.S` with `sbi_set_timer`
   (EID `0x54494D45`).
4. **Add an `sbi.zig`** — a thin wrapper around `ecall` with `a7` = EID,
   `a6` = FID, args in `a0..a5`, returning `(error, value)` in `a0`/`a1`.
5. **Update boot flow** — switch QEMU invocation from `-kernel kernel.elf`
   (loads at `0x80000000` as M-mode entry) to `-bios opensbi.bin
   -kernel kernel.elf` (OpenSBI loads at `0x80000000`, kernel at
   `0x80200000`).

The S-mode trap handler, scheduler, paging, and syscall dispatch all stay
the same — those live entirely in S-mode and don't care what's underneath.

## TL;DR

- **Today**: bare-metal S-mode kernel + custom 97-line M-mode shim. No SBI,
  no OpenSBI.
- **Need OpenSBI**: only when targeting real hardware, QEMU `-bios default`,
  SMP, or wanting portable shutdown/reset.
- **Migration cost**: low — the M-mode shim and a handful of MMIO sites are
  the only things that change.
