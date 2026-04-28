# devices-uart-clint-plic-block: Practice & Self-Assessment

---

## Section 1: True or False (10 questions)

**1.** Writing a byte to address `0x10000000` (UART THR) prints it on stdout.

**2.** The UART RX FIFO in `ccc` holds 1024 bytes.

**3.** PLIC source 0 is reserved as "no source" and cannot be used by any device.

**4.** Reading the PLIC claim register *clears* the chosen source's pending bit atomically.

**5.** The CLINT's `mtime` is stored in a CSR.

**6.** The block device sets `STATUS = NoMedia` when no host file or slice is attached.

**7.** PLIC source 10 is wired to the UART RX (FIFO non-empty).

**8.** The block device's IRQ asserts immediately when the kernel writes CMD.

**9.** `mtimecmp` writes have no immediate visible effect; MTIP only flips on the next `mtime` advance.

**10.** The halt MMIO at `0x00100000` accepts both reads and writes; reads return 0.

### Answers

1. **True.** That's the entire TX path.
2. **False.** 256 bytes (`RX_CAPACITY = 256` in `uart.zig`).
3. **True.** ID 0 is "no source" — `claim` returns 0 if no pending source qualifies.
4. **True.** `claim()` atomically computes the highest-priority pending+enabled+(prio>threshold) source and clears its pending bit.
5. **False.** `mtime` is *MMIO* at `0x0200_BFF8`, not a CSR. (The spec sometimes calls it a "memory-mapped register" but it's accessed via load/store, not csrr*.)
6. **True.** When both `disk_slice` and `disk_file` are null, `performTransfer` returns NoMedia.
7. **True.** UART RX uses source 10; block device uses source 1.
8. **False.** `pending_irq = true` is set, but the actual `plic.assertSource(1)` happens at the *next* `cpu.step` boundary (the deferred-IRQ pattern).
9. **False.** `MTIP` is computed live: `mtime >= mtimecmp` is recomputed on every `mip` read. So setting `mtimecmp = 0` makes MTIP fire immediately if `mtime > 0`.
10. **True.** Halt reads return 0; writes terminate the run with the byte value as exit code.

---

## Section 2: Multiple Choice (8 questions)

**1.** When the UART RX FIFO transitions from empty to non-empty, what happens?
- A. The kernel is interrupted directly via `mip.SEIP`.
- B. The UART calls `plic.assertSource(10)`; whether the kernel is interrupted depends on PLIC config.
- C. Nothing happens until the kernel polls.
- D. `mip.MTIP` is set.

**2.** In the PLIC, what does writing to the *complete* register do?
- A. Nothing — it's a no-op for this PLIC variant.
- B. Re-allows the source's pending bit to be set by future device asserts.
- C. Atomically asserts the source.
- D. Re-claims the source.

**3.** Why does the block device defer IRQ assertion to the next instruction boundary?
- A. To save power.
- B. To preserve the spec rule that interrupts fire only at instruction boundaries.
- C. Because the host file I/O is slow.
- D. It doesn't — the IRQ asserts immediately.

**4.** Which device is *core-local* (per-hart, not shared)?
- A. UART
- B. CLINT
- C. PLIC
- D. Block

**5.** The wasm build sets `mtime` how?
- A. Via libc's `clock_gettime`.
- B. Via the WASI `clock_time_get` syscall.
- C. Via a JS-supplied override read by an alternate `clock_source`.
- D. It's hardcoded to 0.

**6.** The block device's CMD register is at offset 0x8 (4 bytes). What writes the high byte?
- A. The kernel always writes byte 0xB last.
- B. The MMIO byte-by-byte path writes bytes 0, 1, 2, 3 in order — so byte 0xB is byte 3.
- C. The kernel must explicitly call `block.trigger()`.
- D. The IRQ fires regardless of write order.

**7.** Which interrupt has the highest priority in `INTERRUPT_PRIORITY_ORDER`?
- A. STI (S timer)
- B. SSI (S software)
- C. MEI (M external)
- D. SEI (S external)

**8.** The UART has an `IER` register. What does setting bit 0 do in `ccc`?
- A. Enables the THR-empty interrupt.
- B. Enables the RX-data-available interrupt; conceptually it would, but `ccc` ignores IER and always asserts source 10 on FIFO non-empty.
- C. Resets the FIFO.
- D. Toggles the modem-control lines.

### Answers

1. **B.** PLIC mediates. Source 10's priority must be > threshold and the source must be enabled in the S-context's enable mask, and SIE/SEIE must be set, etc.
2. **B.** complete is "I'm done with this IRQ; allow it to re-pend." The pending bit was already cleared on claim.
3. **B.** Spec rule: interrupts taken between instructions. The block device transfer happens during a store; the IRQ shouldn't be visible to the same instruction.
4. **B.** CLINT = "core-local interruptor" — per-hart. PLIC is shared across harts (in real systems; `ccc` has one).
5. **C.** The freestanding default returns 0; `web_main.zig` passes a custom `webClock` that reads `mtime_ns_override` (set by JS).
6. **B.** The kernel writes CMD as `sw`. `storeWordPhysical`'s MMIO fall-through breaks it into byte-stores in offset order; byte 3 (offset 0xB) writes last.
7. **C.** MEI > MSI > MTI > SEI > SSI > STI. From `trap.zig`'s `INTERRUPT_PRIORITY_ORDER`.
8. **B.** `ccc` accepts writes to IER but ignores the value. The PLIC source 10 assertion is unconditional on FIFO non-empty.

---

## Section 3: Scenario Analysis (3 scenarios)

**Scenario 1: A keystroke that doesn't show up**

The user types 'q' in the demo. The byte makes it through `pushRx`, but the shell never sees it. Stepping through, you see PLIC source 10 *is* asserted, but the kernel's trap handler doesn't fire.

1. List four conditions that all need to hold for the trap to fire.
2. Which one is most likely missing?

**Scenario 2: Adding a second UART**

You want to add a second UART at `0x10000200`. Same NS16550A behavior, RX gets PLIC source 11.

1. Which files need editing? List at least three.
2. What changes does `memory.zig` need?
3. What does the kernel need to learn about?

**Scenario 3: Why does the block device need `pending_irq` instead of asserting directly?**

You're refactoring `block.zig` and consider removing `pending_irq` — just have `performTransfer` call `plic.assertSource(1)` directly. What breaks?

### Analysis

**Scenario 1: A keystroke that doesn't show up**

1. Conditions for SEI delivery to S:
   - PLIC source 10 priority > threshold (priority must be set, threshold must be 0 or below).
   - PLIC source 10 enabled in the S-context's enable mask.
   - `mip.SEIP = 1` (PLIC's `hasPendingForS()` returns true).
   - `mie.SEIE = 1`.
   - `mideleg.SEI = 1` (so SEI delegates to S; otherwise it goes to M).
   - SIE deliverability rule: current priv < S, OR current = S and `sstatus.SIE = 1`.
2. Most likely missing: **priority not set** (defaults to 0, which is "off" — must be ≥ 1 to be deliverable). Or **enable_s bit 10 not set**. The kernel's PLIC init in `src/kernel/plic.zig` should set both — easy to forget for a newly-added source.

**Scenario 2: Adding a second UART**

1. Files to edit:
   - `src/emulator/devices/uart.zig` — could go second instance with same struct, or refactor to take a base address parameter.
   - `src/emulator/memory.zig` — add a UART2_BASE/UART2_SIZE check; route in both `loadBytePhysical` and `storeBytePhysical`.
   - `src/kernel/uart.zig` — kernel-side driver, second instance + ISR.
   - Probably `main.zig` — wire the second instance into Memory.
2. `memory.zig` needs new `inRange` checks for the second range; the cascade in both load and store paths.
3. The kernel needs to: register a second device source (PLIC source 11), enable it in the S-context, install an ISR, and have a way to refer to it (a second file-table backing? a unified console with two backings?).

**Scenario 3: No pending_irq**

If `performTransfer` called `plic.assertSource(1)` directly:

- The transfer happens *during* the kernel's `sw` to CMD-byte-3.
- That `sw` is one instruction. `cpu.step` is currently inside `dispatch` for that store.
- The PLIC source assertion would set `mip.SEIP = 1`.
- But `check_interrupt` only runs *between* instructions, at the top of `cpu.step`. So this `sw` would complete normally.
- *Next* instruction: `cpu.step` checks interrupts. SEIP is set. Trap fires.
- ... So actually, in this single-threaded emulator, removing `pending_irq` would *probably* still work?

But: it violates the spec invariant cleanly. The `pending_irq` deferred pattern *also* gives `cpu.step` a chance to emit the `--- block: ... ---` trace marker between the previous instruction and the upcoming interrupt marker. Without `pending_irq`, the marker would appear *during* the `sw`'s trace line — confusing in trace output. So the deferral is partly for correctness (defensive against future multi-step instructions) and partly for tracing clarity.

---

## Section 4: Reflection Questions

1. **Why level-triggered for UART RX?** What would go wrong with edge-triggered? Sketch a race condition.

2. **PLIC's 4 MB reservation.** Reading `plic.zig`, you see most of the address space is unhandled. What's the implementation cost-vs-correctness tradeoff for an OS that *might* one day support more contexts?

3. **CLINT vs PLIC: why two interrupt mechanisms?** The timer could have been a PLIC source. Why isn't it?

4. **The `disk_slice` design.** What if you wanted the wasm demo's writes to *persist* across page reloads? Sketch the design (hint: `localStorage` is a tempting starter).

5. **A new hypothetical device — a frame buffer.** If you wanted a graphical pixel buffer at `0x2000_0000` (1 MB = 1024×1024 grayscale), what changes? What's the IRQ story?
