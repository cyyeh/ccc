# csrs-traps-and-privilege: Code Cases

> Real artifacts from the codebase that illustrate CSRs, traps, and privilege transitions in action.

---

### Case 1: `trap_demo` — three privilege levels in one ELF (Plan 1.C, 2026-04)

**Background**

The Phase 1.C milestone needed a single-program demo proving M / S / U all work correctly with traps. `programs/trap_demo/encoder.zig` produces a hand-crafted RV32 binary that prints `trap ok\n` and halts.

**What happened**

The program does:
1. M-mode boots at `0x80000000`. Sets `mtvec` to a tiny in-line trap handler.
2. M-mode sets up `mepc = u_mode_entry` and `MPP = U`, then `mret`.
3. CPU now in U-mode at `u_mode_entry`. Executes `ecall`.
4. `ecall` traps. Cause = 8 (`ecall_from_u`). `medeleg` was left zero, so target = M. Privilege flips to M; PC = mtvec.
5. M-mode trap handler reads `mcause`, sees 8, dispatches to "do the syscall" — which writes `trap ok\n` to UART, then writes any byte to halt MMIO.
6. Halt MMIO → `MemoryError.Halt` → `cpu.run` returns.

The `e2e-trap` test (`tests/e2e/trap.zig`) asserts stdout == `"trap ok\n"`. If any of the privilege transitions or CSR writes are wrong, the test fails.

**Relevance to csrs-traps-and-privilege**

This is the smallest possible demonstration of M↔U with a syscall pattern. Every line of `trap.enter` and `exit_mret` is exercised. If `mstatus_mie` weren't cleared on entry, async interrupts (none pending in this demo, but...) would mess up the round-trip. If `mepc` weren't restored, the program would re-enter `ecall` infinitely.

**References**

- `programs/trap_demo/encoder.zig`
- `src/emulator/trap.zig` (`enter`, `exit_mret`)
- `tests/e2e/trap.zig`
- `build.zig` target `e2e-trap`

---

### Case 2: The boot shim's delegation setup (Plan 2.B → 2.C, 2026-04)

**Background**

When `kernel.elf` boots, the M-mode shim (`src/kernel/boot.S`) needs to delegate as much as possible to S so the kernel doesn't need a tower of M-mode trap forwarders. The shim sets `medeleg` and `mideleg` once, near the top of boot.

**What happened**

The boot shim:

```
csrwi medeleg, 0xB1FF   # delegate: misaligned/access faults, illegal,
                        # ecall_u, page faults — basically everything S
                        # can handle.
csrwi mideleg, 0x222    # delegate: SSI (1), STI (5), SEI (9) — all S-level
                        # interrupts. Keep MTI/MEI/MSI at M.
```

(The actual hex is computed; this is the conceptual mask.)

After this, every page fault, every U-ecall, every illegal-instr fires straight into S without M intervention. The kernel's S-mode trap handler in `src/kernel/trap.zig` becomes the only handler that runs in normal operation.

**Relevance to csrs-traps-and-privilege**

Without delegation, every trap would round-trip through M. With delegation, the boot shim becomes a one-time bootstrap and S handles all per-syscall traffic. The bit positions in `medeleg`/`mideleg` directly correspond to `Cause` enum values in `trap.zig`.

**References**

- `src/kernel/boot.S` (M-mode bootstrap)
- `src/emulator/csr.zig` (`MEDELEG_MASK`, `MIDELEG_MASK` — what bits are writable)
- `src/kernel/trap.zig` (S-mode dispatcher that handles delegated traps)

---

### Case 3: The MTI → SSIP chain — boot shim forwarding the timer (Plan 2.B, 2026-04)

**Background**

`ccc`'s boot shim wants to keep MTI (machine timer interrupt) at M-mode (so M can do firmware-level timekeeping) but the *kernel* needs a tick. The trick: the M-mode MTI handler synthesizes an SSI (S software interrupt) that the kernel's S-mode handler then sees.

**What happened**

The shim sets `mie.MTIE = 1` (enable MTI) and points `mtvec` at a tiny ISR. The ISR does:

1. Move `mtimecmp` far into the future (so MTI doesn't immediately re-fire).
2. Set `mip.SSIP = 1` (this bit is software-writable and routes to S since SSIP is in `mideleg`).
3. `mret`.

After mret, the CPU is back in S-mode (or U if that's where it was). The pending SSI is *immediately* deliverable: `cpu.check_interrupt` sees `mip.SSIP & sie.SSIE & deliverable_at_S` → fires `enter_interrupt(1, cpu)` → S handles it.

The kernel's S-trap handler reads `scause = (1 << 31) | 1`, recognizes the SSI as a "timer tick" (by convention), bumps the tick counter, clears `sip.SSIP`, and `sret`s.

**Relevance to csrs-traps-and-privilege**

This pattern shows how `mip.SSIP` is the only software-set interrupt-pending bit, and how it's used as a software-IPI between privilege levels. The integration test in `cpu.zig` named `"integration: CLINT → M MTI ISR → mip.SSIP → S SSI ISR end-to-end"` is the regression for it.

**References**

- `src/kernel/boot.S` (the MTI ISR)
- `src/kernel/mtimer.S`
- `src/emulator/cpu.zig` (the integration test)

---

### Case 4: The `wfi`-during-idle SIE-window bug (Plan 3.E, 2026-04)

**Background**

In Plan 3.E, the shell ran but the FS demo would hang on the first block-device IRQ. Tracing showed: scheduler executed `wfi`, block IRQ fired, but the trap never delivered.

**Diagnosis**

`wfi` calls `cpu.idleSpin`. While idling, the block device asserts PLIC source 1 → `mip.SEIP` becomes pending. But the scheduler had `sie.SSIE = 0` (so it could safely manipulate ptable without re-entry). At an instruction boundary, `check_interrupt` looks for pending+enabled+deliverable: `mip.SEIP=1 & sie.SEIE=0 → 0` → no delivery. The IRQ stays pending forever.

**Fix**

The scheduler now has a brief "SIE window" around `wfi`:

1. Save current `stvec` to `sscratch`.
2. Set `stvec` to `s_kernel_trap_entry` (a separate trap entry that handles "trap took during scheduler").
3. Enable `sie.SSIE | sie.SEIE | sie.STIE` for the next instruction only.
4. `wfi` (or jump back to the scheduler's pick-loop).
5. The window auto-closes when the trap fires (because trap entry sets `SIE=0`).

The new entry point `s_kernel_trap_entry` lives in `src/kernel/trampoline.S`. It's careful: the trap fired *while running on the scheduler's stack*, not a per-process kstack, so it can't safely enter the regular S-trap handler. Instead it just claims the IRQ from PLIC, runs the device ISR (which probably wakes a sleeper), and returns to the scheduler.

There's also a related sub-fix: `wfi` had to advance `sepc` past the `wfi` itself before returning, otherwise re-entering the scheduler would try to fetch from the wrong address.

**Relevance to csrs-traps-and-privilege**

This is the messiest CSR-related bug in `ccc`. The fix shows how subtle the interaction between privilege, interrupt-enable, and `wfi` can be. The SIE window pattern is also documented in xv6 (where it's called the "intena/intr_off" pattern) — `ccc` evolved its own version.

**References**

- `src/kernel/sched.zig` (the SIE window setup)
- `src/kernel/trampoline.S` (`s_kernel_trap_entry`)
- `src/emulator/cpu.zig` test `"WFI returns promptly when a deliverable interrupt arrives during idle"`

---

### Case 5: An `ecall_from_u` round-trip in 12 instructions (Plan 2.D, 2026-04)

**Background**

When the U-mode user program executes a syscall, here's the actual register/CSR state at each step. Take `userprog.zig`'s call to `write(1, "hello from u-mode\n", 18)`.

**What happened**

Pre-trap (U-mode):
- `pc = 0x10000280` (somewhere in the user's `_start`)
- `a7 = 64` (write syscall #)
- `a0 = 1`, `a1 = address of string`, `a2 = 18`
- `cpu.privilege = .U`
- `mstatus.SIE = 1` (S-mode interrupts enabled — they were set by sret)

Execute `ecall` → cause = 8.

Trap entry (delegated to S):
- `sepc = 0x10000280` (address of the ecall)
- `scause = 8`
- `stval = 0`
- `mstatus.SPP = 0` (was U)
- `mstatus.SPIE = 1` (was SIE)
- `mstatus.SIE = 0` (now disabled)
- `cpu.privilege = .S`
- `pc = stvec.BASE = 0x80000800` (kernel's `s_trap_entry`)

Kernel handler runs. Eventually:
- Decodes cause; calls `syscall.zig`'s dispatch. Sees a7=64, calls `sys_write`.
- `sys_write` writes the bytes to UART (via the file table; for fd 1, calls `console.write`).
- `sys_write` returns 18.
- Handler stores 18 in the trap frame's `a0` slot.
- Handler does `sepc += 4`. Now `sepc = 0x10000284`.
- Handler executes `sret`.

`sret` exit:
- `pc = 0x10000284`
- `cpu.privilege = .U` (from SPP)
- `mstatus.SIE = 1` (from SPIE)
- `mstatus.SPIE = 1` (reset)
- `mstatus.SPP = 0` (reset)

Post-trap (U-mode):
- `a0 = 18` (the syscall return)
- All other registers preserved (the trap frame restored them).
- Program continues at the instruction after `ecall`.

**Relevance to csrs-traps-and-privilege**

Every CSR field touched by `enter` and `exit_sret` plays a role here. If `SPP` weren't restored correctly, the user would end up in S with kernel privileges. If `sepc += 4` weren't done, the user would re-execute `ecall` infinitely. If `SIE` weren't restored, U-mode would run with interrupts off (and never preempt).

**References**

- `src/kernel/user/userprog.zig` (the user program)
- `src/kernel/trap.zig` (S-mode handler)
- `src/kernel/syscall.zig` (the dispatch)
- `tests/e2e/kernel.zig` (asserts the round-trip prints "hello from u-mode\n")

---

### Case 6: `mscratch` — the CSR no spec demanded (Plan 1.D, 2026-04)

**Background**

`mscratch` is a "machine scratch register" — software-only, no hardware reads. Plan 1.D didn't mention it, but the `riscv-tests rv32mi-csr` test wrote to it and read back, expecting the value to round-trip.

**Diagnosis & fix**

When the test ran, it failed with "expected 0xDEADBEEF, got 0." Tracing showed `csrrw` to address 0x340 was being treated as "read-only" — the write was discarded.

The fix: add `mscratch: u32 = 0` to `CsrFile`, plus the read/write arms in `csr.zig`. Three-line patch.

This is the only CSR `ccc` added that's not load-bearing for the kernel — it exists purely because `riscv-tests` assumes it does.

**Relevance to csrs-traps-and-privilege**

`mscratch` is a window into the standard "spec doesn't require, suite assumes" gap. Real RISC-V chips ship `mscratch` because it's useful as a kernel-private save slot during M-trap entry (xv6 uses it that way). `ccc`'s kernel doesn't, but the storage is harmless.

**References**

- `src/emulator/cpu.zig` (`mscratch` field in `CsrFile`)
- `src/emulator/csr.zig` (read/write dispatch)
- `tests/riscv-tests/isa/rv32mi/csr.S`
