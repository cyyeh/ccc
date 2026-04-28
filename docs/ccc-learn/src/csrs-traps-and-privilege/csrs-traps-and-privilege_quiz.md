# csrs-traps-and-privilege: Practice & Self-Assessment

---

## Section 1: True or False (10 questions)

**1.** When a synchronous trap fires, `mepc` is set to `pc + 4`.

**2.** `mret` can be executed from U-mode.

**3.** The cause register's bit 31 distinguishes async interrupts from sync exceptions.

**4.** With `medeleg.ECALL_FROM_U = 1`, an ecall from U-mode bypasses M and lands directly in S.

**5.** `mstatus.MIE` controls whether M-level interrupts can fire when current privilege is M.

**6.** `mstatus.MPP` is overwritten on every trap entry to hold the previous privilege level.

**7.** `wfi` in `ccc` blocks the host process forever if no interrupt arrives.

**8.** Reading `mip` from S-mode is allowed; reading `mstatus` from S-mode is not.

**9.** The instruction `csrrw x0, mtvec, t0` writes `t0` to `mtvec` without reading the old value.

**10.** Each privilege level has its own `tvec` — `mtvec` for M, `stvec` for S, `utvec` for U.

### Answers

1. **False.** `mepc` holds the *trapping* instruction's PC. The handler must add 4 manually for ecall (not for page faults — those should retry the same instruction).
2. **False.** `mret` is M-only. Calling from U raises `illegal_instruction`.
3. **True.** `mcause` / `scause` have the high bit set for async, clear for sync.
4. **True.** Plus `cpu.privilege != .M` (M can never delegate to S; M-trap stays M-trap).
5. **True.** When current = M, MIE gates M-level interrupts. When current is *lower* than M, M-level interrupts are *always* deliverable regardless of MIE.
6. **True.** Specifically: `MPP ← old privilege` on M-trap entry; `SPP ← old privilege` (1-bit, S/U only) on S-trap entry.
7. **False.** `idleSpin` has a 10-second wall-clock cap; it returns even if no interrupt arrives.
8. **False.** Both readable from S; both writable from S (`sstatus` is a subset view of `mstatus`).
9. **True.** With `rd = x0`, the read is discarded — Zicsr semantics make this efficient.
10. **False.** No `utvec` exists in this RISC-V variant (it would be for the N-extension which `ccc` skips). M and S each have their own; U-mode traps go to S or M.

---

## Section 2: Multiple Choice (8 questions)

**1.** A trap fires from U-mode with cause `instr_page_fault` (12). `medeleg & (1<<12) = 1`. Where does it go?
- A. M-mode.
- B. S-mode.
- C. U-mode (somehow).
- D. The CPU halts.

**2.** What does `mret` do to `mstatus.MPP`?
- A. Sets it to 0 (U) as the next-trap default.
- B. Saves the current privilege there.
- C. Leaves it untouched.
- D. Sets it to whatever was in MPIE.

**3.** Why does `mstatus.MIE` get cleared on M-trap entry?
- A. To save the previous value.
- B. So the trap handler runs with interrupts disabled until it explicitly re-enables.
- C. It doesn't — only S-trap entry clears SIE.
- D. So `mret` can restore it.

**4.** Which CSR holds the *pointer to the L1 page table*?
- A. `mtvec`
- B. `satp`
- C. `mepc`
- D. `pte`

**5.** What's the priority order RISC-V mandates for pending interrupts?
- A. SSI > STI > SEI > MSI > MTI > MEI
- B. MEI > MSI > MTI > SEI > SSI > STI
- C. By cause code, smallest first
- D. Implementation-defined

**6.** Which of these `mstatus` field combinations is the *kernel* observing right after entering an S-trap from U?
- A. SPP=1, SPIE=0, SIE=0
- B. SPP=0, SPIE=1, SIE=0
- C. SPP=0, SPIE=1, SIE=1
- D. SPP=1, SPIE=1, SIE=1

(Assume the user had SIE=1 right before the trap.)

**7.** When `mstatus.MPRV = 1` and `cpu.privilege = .M`, what happens to *fetches*?
- A. They use MPP's privilege.
- B. They use M's privilege (MPRV doesn't affect fetch).
- C. They cause an illegal-instruction trap.
- D. They use whichever privilege `cpu.privilege` was before MPRV was set.

**8.** Why does `cpu.reservation` get cleared on every trap entry?
- A. To prevent stale LR/SC reservations from surviving across context switches.
- B. To save memory.
- C. The spec says so but `ccc` doesn't actually do it.
- D. It's only cleared on `mret`.

### Answers

1. **B.** Delegation rule: `cpu.privilege != .M AND medeleg bit set` → S.
2. **A.** `mret` resets MPP to U (so the next trap has a clean default).
3. **B.** Disabled inside the handler; the handler re-enables explicitly if needed (e.g., the SIE window for `wfi`).
4. **B.** `satp.PPN` (bits 21:0) shifted left 12 = root_pa. `satp.MODE` (bit 31) selects Bare or Sv32.
5. **B.** MEI > MSI > MTI > SEI > SSI > STI. See `INTERRUPT_PRIORITY_ORDER` in `trap.zig`.
6. **B.** SPP=0 (was U), SPIE=1 (saved old SIE=1), SIE=0 (cleared on entry).
7. **B.** MPRV is *load/store* only. Fetches always use `cpu.privilege` directly.
8. **A.** Trap handlers run arbitrary code; an LR-without-SC across a context switch could falsely succeed. Spec mandates the clear.

---

## Section 3: Scenario Analysis (3 scenarios)

**Scenario 1: A trap that won't deliver**

You wire up a new device that asserts a PLIC source. The kernel can read its registers and the PLIC's pending bit is set, but the kernel never sees the SEI trap. Stepping through `cpu.check_interrupt`, you find `mip.SEIP & mie.SEIE = 1`, but `interruptDeliverableAt(.S, cpu)` returns false.

1. What three conditions need to be true for an SEI to deliver to S-mode?
2. Which one is your most likely culprit?

**Scenario 2: A double-trap loop**

You're testing the kernel and find that one specific user program triggers a page fault, the kernel handler runs, but then *immediately* page-faults itself, M-mode catches that, and the system locks.

1. The kernel's handler page-faulted while doing what?
2. Why did delegation fail this time (the second-fault going to M instead of S)?
3. Two ways to fix it.

**Scenario 3: Adding `cycle` and `instret` counters**

The `cycle` and `instret` user-readable CSRs (addresses 0xC00 and 0xC02) provide cycle and instruction counts. `ccc` doesn't implement them. You decide to add them.

1. Where do you add storage?
2. Which CSR access function needs to handle the new addresses?
3. Why does `mcounteren` (already implemented as software-visible state) become *meaningful* once you add these?

### Analysis

**Scenario 1: A trap that won't deliver**

1. Three conditions for SEI delivery to S:
   - Pending: `mip.SEIP = 1` (set by PLIC's `hasPendingForS()`).
   - Enabled: `mie.SEIE = 1`.
   - Deliverable at the current privilege: lower-priv → always; equal → consult `sie.SIE`; higher → never.
2. Most likely: `mstatus.SIE = 0`. The kernel disabled S interrupts (e.g., for a critical section) and never re-enabled them. Or: the kernel is in S-mode (current == target) and SIE is needed. Use the SIE window pattern from Case 4.

**Scenario 2: A double-trap loop**

1. The kernel's handler probably dereferenced a user pointer without first verifying it was mapped. E.g., reading `argv[0]` without checking that the argv page exists in the user's page table.
2. The second fault was *from S-mode*. Delegation rule: if `cpu.privilege == .M`, no delegation. But the second fault was from S, not M. So... actually, S-from-S faults, by spec, can still go to M unless `medeleg` says otherwise — and even if `medeleg.LOAD_PAGE_FAULT = 1`, the rule is `cpu.privilege != .M`, which S satisfies. So the second fault *should* go to S. But: the S handler clobbered `sepc` already! When the second fault saves `sepc`, it overwrites the original ecall's `sepc`. That's the lockup: even if the second handler returned, `sret` jumps to the wrong place.
3. Fix options:
   - Don't dereference user pointers without verifying first (use `copy_from_user` style with explicit checks).
   - Save `sepc` to a stack slot before doing anything that might fault, restore before `sret`.

**Scenario 3: Adding `cycle` and `instret`**

1. Storage: add fields to a step-counter on `Cpu` or expose CLINT's `mtime` for `cycle`. `instret` would need a counter incremented in `cpu.step`.
2. The dispatch in `csr.zig`'s `csrRead` — add cases for 0xC00 (cycle), 0xC01 (time), 0xC02 (instret), and their high counterparts (0xC80, 0xC81, 0xC82) for the upper 32 bits.
3. `mcounteren` controls whether U-mode can read these counters. Bit 0 enables `cycle` from U, bit 1 enables `time`, bit 2 enables `instret`. Once the counters are real, `mcounteren = 0` would make U-reads trap with illegal-instr. `scounteren` is the S-mode analog.

---

## Section 4: Reflection Questions

1. **Why two trap-vector CSRs?** Why does RISC-V have `mtvec` and `stvec` separately? Why not a single CSR that gets repointed by software at each privilege boundary?

2. **The "M is not lower than M" rule.** Why does the spec forbid M from delegating to S? What attack would be possible if it didn't?

3. **`mret` resetting MPP to U.** What's the reasoning for "next-trap default = U"? Why not "next-trap default = M"?

4. **Why is `mtval` always 0 for interrupts?** What information would be lost if you wanted to know "*which* PLIC source caused SEI?" and how does `ccc` work around it (hint: `peekHighestPendingForS` in the trace marker)?

5. **The wfi-window pattern.** Could you avoid the SIE window by structuring the kernel differently (e.g., never wfi'ing inside critical sections)? What would the cost be?
