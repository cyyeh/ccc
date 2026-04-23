# RISC-V M-mode + U-mode + ECALL Traps

Reference notes for the minimal two-mode RISC-V privilege model we'll use in
the emulator and kernel. Skipping S-mode (and H-mode) keeps the design small
while still giving us a real syscall boundary.

## The privilege levels

RISC-V defines up to 4 levels. A minimal system uses just two:

| Mode | Encoding | Purpose |
|------|----------|---------|
| **M-mode** (Machine) | `11` | Highest privilege. Runs firmware/kernel. Full CSR and memory access. Always present. |
| **U-mode** (User) | `00` | Lowest privilege. Runs applications. No privileged CSRs, no privileged instructions. |

Between them sit optional **S-mode** (supervisor, for an OS kernel with an
MMU) and **H-mode** (hypervisor). Both are skipped in a two-mode design.

## ECALL — the crossing instruction

`ecall` is the only way U-mode code asks M-mode for anything. It deliberately
raises an exception so that control transfers through the trap mechanism.
There is no "privileged call" instruction in RISC-V; you trap and let the
handler decide what to do.

## The trap sequence (U → M)

When user code executes `ecall`:

### 1. Hardware (automatic, one cycle)

- `mepc  ← pc` — address of the `ecall`
- `mcause ← 8` — exception code = "ECALL from U-mode"
  (ECALL from M-mode would be `11`)
- `mtval ← 0` — no faulting address for ecall
- `mstatus.MPP ← 00` — remember we came from U-mode
- `mstatus.MPIE ← MIE`, then `MIE ← 0` — disable interrupts during the trap
- `pc ← mtvec` — jump to the trap handler

### 2. Handler (your M-mode code)

- Save caller registers
- Read `mcause` and dispatch on the syscall number
  (Linux-style convention: number in `a7`, args in `a0`–`a5`, return in `a0`)
- Do the work
- **Advance `mepc` by 4** — otherwise `mret` re-executes the `ecall` forever

### 3. Return

`mret` — the machine-mode return instruction:

- `pc ← mepc`
- `mstatus.MIE ← MPIE`
- privilege level ← `MPP` (back to U-mode)

## Relevant CSRs

| CSR | Purpose |
|-----|---------|
| `mtvec` | Base address of trap handler (+ mode bits: Direct or Vectored) |
| `mepc`  | PC that was interrupted; `mret` restores from here |
| `mcause`| Why we trapped (high bit = interrupt vs exception; low bits = code) |
| `mtval` | Fault-specific value (bad address, illegal instruction, etc.) |
| `mstatus` | Global status: `MIE`, `MPIE`, `MPP`, etc. |
| `mie` / `mip` | Interrupt enable / pending bits |
| `mscratch` | Free scratch register — typical use: swap with `sp` to get kernel stack |

## Common `mcause` values

| Cause | Meaning |
|-------|---------|
| `0`   | Instruction address misaligned |
| `1`   | Instruction access fault |
| `2`   | Illegal instruction |
| `3`   | Breakpoint (`ebreak`) |
| `4`   | Load address misaligned |
| `5`   | Load access fault |
| `6`   | Store/AMO address misaligned |
| `7`   | Store/AMO access fault |
| `8`   | **ECALL from U-mode** |
| `9`   | ECALL from S-mode (unused in two-mode setup) |
| `11`  | ECALL from M-mode |

Interrupts use the same `mcause` register but with the high bit set.

## mtvec modes

- **Direct** (`MODE = 0`): all traps jump to `BASE`.
- **Vectored** (`MODE = 1`): interrupts jump to `BASE + 4 × cause`;
  exceptions still jump to `BASE`.

ECALL is an exception, so vectored mode doesn't change where it lands.

## Syscall ABI (typical)

Matches the Linux RISC-V convention — easy to adopt even for a custom kernel:

| Register | Role |
|----------|------|
| `a7`     | Syscall number |
| `a0`–`a5`| Arguments |
| `a0`     | Return value |
| `a1`     | Second return value (rare) |

## Gotchas

- **Forgetting `mepc += 4`** → infinite `ecall` loop. The trap re-enters on
  the same instruction forever.
- **`mtvec` not set before entering U-mode** → first trap jumps to address 0.
- **`mret` from a mode without `MPP` set up** → privilege-level confusion.
- **Compressed ISA:** plain `ecall` is always 4 bytes, so `+= 4` is correct.
  If you later add C-extension support and use a 2-byte trapping
  instruction, you'd advance by 2 there.
- **`mscratch` swap trick:** at trap entry, swap `sp` with `mscratch` using
  `csrrw sp, mscratch, sp` so the handler runs on a known kernel stack even
  if user `sp` was garbage. Swap back before `mret`.
- **Don't clobber `mepc`/`mcause`** before reading them — a nested trap
  (fault inside the handler) will overwrite them.

## Why this two-mode setup is popular

- **No MMU, no page tables.** M-mode can use PMP (Physical Memory
  Protection) to sandbox U-mode regions instead.
- **Clean syscall boundary** without the complexity of an OS kernel in
  S-mode.
- **Maps directly to embedded RTOS designs** and educational CPUs — which
  is the right starting point for a from-scratch RISC-V computer before
  adding S-mode and virtual memory.

## Relevance to this project

- **Phase 1 (emulator):** implement `ecall`, `mret`, and the CSRs above.
  Decode exception codes, update `mepc`/`mcause`/`mstatus` on trap entry,
  restore them on `mret`.
- **Phase 2 (kernel):** write the M-mode trap handler. Define a syscall
  ABI (start with `write` to UART so user programs can print). This is
  where the "user-mode program calls `write()` and the kernel prints it"
  demo comes from.
- **Phase 3+:** if/when we add S-mode, most of this generalizes —
  `sepc`/`scause`/`stvec`/`sret` mirror the M-mode equivalents.

## Further reading

- RISC-V Privileged ISA spec, chapters on Machine-Level ISA and Trap
  Handling (authoritative reference).
- `riscv-tests/isa/rv32mi-p-*` — the privileged-mode tests are a good
  concrete target for Phase 1's trap implementation.
