# memory-and-mmio: Practice & Self-Assessment

> Read the analysis and beginner guide first. Section answers follow each section.

---

## Section 1: True or False (10 questions)

**1.** RAM in `ccc` starts at physical address `0x80000000` and defaults to 128 MB.

**2.** Memory-mapped I/O means devices appear as ranges of physical addresses; the same `lw`/`sw` instructions used for RAM access do device access too.

**3.** Sv32 page tables in `ccc` support both 4 KB and 4 MB pages.

**4.** When the CPU is in M-mode, `satp` controls the page table for translation.

**5.** A PTE with `R = W = X = 0` and `V = 1` is a *pointer* (non-leaf) PTE in the Sv32 walk.

**6.** A misaligned word load (address not divisible by 4) in `ccc` returns the unaligned bytes successfully — it's only a problem on real hardware.

**7.** Writing any byte to address `0x00100000` (the halt MMIO) terminates the emulator.

**8.** The `tohost` MMIO range is part of every RISC-V system; it's defined by the privileged spec.

**9.** `mstatus.MPRV` affects load/store privilege but never affects instruction fetch.

**10.** When `mstatus.MXR = 1`, a PTE with `X = 1, R = 0` becomes effectively readable.

### Answers

1. **True.** `RAM_BASE = 0x80000000`; `RAM_SIZE_DEFAULT = 128 * 1024 * 1024`. The `--memory <MB>` flag overrides the size.
2. **True.** Same instructions, different physical-address regions. The dispatch happens inside `loadBytePhysical`/`storeBytePhysical`.
3. **False.** `ccc` supports only 4 KB pages. A leaf PTE at L1 (which would represent a 4 MB superpage) is *rejected* — the translate function returns a page fault.
4. **False.** M-mode is *always* identity-mapped, regardless of `satp`. Translation only happens when `effective_priv != .M` and `satp.MODE == 1`.
5. **True.** Pointer PTEs have V=1 with R=W=X=0; leaf PTEs have at least one of R/W/X set.
6. **False.** Misaligned accesses return `MemoryError.MisalignedAccess` → executor traps with `load_addr_misaligned`. Some real RISC-V chips support unaligned via slow path, but `ccc` chose strict alignment to keep the model simple.
7. **True.** `Halt.writeByte` returns `error.Halt` for any byte write inside `[0x00100000, 0x00100008)`. The byte's value sets the exit code.
8. **False.** `tohost` is a `riscv-tests`-specific convention, not part of any spec. It's installed only when the ELF loader sees the symbol.
9. **True.** `effectivePriv` checks `access != .fetch` before applying MPRV.
10. **True.** From the analysis: `effective_readable = pte_r or (pte_x and cpu.csr.mstatus_mxr)`. MXR lets the kernel read code as data.

---

## Section 2: Multiple Choice (8 questions)

**1.** In `ccc`'s memory map, which of these address ranges is the UART?
- A. `0x0010_0000` – `0x0010_0008`
- B. `0x0200_0000` – `0x020F_FFFF`
- C. `0x1000_0000` – `0x1000_00FF`
- D. `0x8000_0000` – `0x8800_0000`

**2.** A 32-bit virtual address splits into VPN[1] / VPN[0] / offset. How many bits is each, in Sv32?
- A. 8 / 8 / 16
- B. 9 / 9 / 14
- C. 10 / 10 / 12
- D. 11 / 11 / 10

**3.** What does `Memory.translate` return when called with `effective_priv == .M`?
- A. The result of a full Sv32 walk.
- B. The virtual address unchanged (identity).
- C. An error if `satp.MODE = 1`.
- D. Always 0.

**4.** Which of these PTE bit values describes a "kernel-only readable+writable+executable code page"?
- A. `V=1, R=1, W=1, X=1, U=0`
- B. `V=1, R=1, W=1, X=1, U=1`
- C. `V=0, R=1, W=1, X=1, U=0`
- D. `V=1, R=0, W=0, X=0, U=0`

**5.** Why does `loadWordPhysical` have a fast path for RAM but not for MMIO?
- A. Because MMIO is always misaligned.
- B. Because RAM accesses are by far the most common, and `std.mem.readInt` is faster than four byte-by-byte calls.
- C. Because MMIO devices return errors on word loads.
- D. There is no fast path.

**6.** What's the difference between a `MemoryError.OutOfBounds` and a `TranslationError.LoadPageFault`?
- A. They're synonyms; the executor treats them identically.
- B. OutOfBounds means the *physical* address isn't in any device or RAM range; LoadPageFault means *translation* couldn't produce a valid PA.
- C. OutOfBounds is for stores; LoadPageFault is for loads.
- D. OutOfBounds is fatal; LoadPageFault is recoverable.

**7.** Which of these is NOT a Sv32 PTE flag bit?
- A. V (valid)
- B. R (read)
- C. P (present — like x86)
- D. U (user)

**8.** What's the purpose of A/D bits in PTEs, and how does `ccc` handle them?
- A. They mark "ABI" and "Disabled"; `ccc` ignores them.
- B. A = "accessed", D = "dirty". `ccc` updates them in-place during the walk (hardware-walk semantics).
- C. A = "atomic", D = "dirty"; `ccc` raises a fault to the OS for both.
- D. They're unused in Sv32 (only in Sv39).

### Answers

1. **C.** `UART_BASE = 0x10000000`, size 0x100. Don't confuse with the block device at `0x10001000`.
2. **C.** 10 / 10 / 12. The 12-bit offset matches a 4 KB page; 10 + 10 = 20 bits of VPN match the 22-bit PPN minus 2 (the unused upper bits in Sv32).
3. **B.** Identity. From `translate`: `if (effective_priv == .M) return va;`.
4. **A.** V=1 (valid), R=W=X=1 (full perms), U=0 (kernel-only). A user-only would have U=1; an invalid would have V=0.
5. **B.** RAM access is the hot path; the `std.mem.readInt` fast path skips the 4 byte-by-byte routes that the MMIO path requires for uniformity.
6. **B.** OutOfBounds = no device or RAM owns this PA; LoadPageFault = the page-table walk failed (V=0 PTE, permission denied, etc.).
7. **C.** P (present) is x86 terminology. Sv32 has V (valid) instead.
8. **B.** Hardware-walk semantics. The alternative — trap on A=0 or D=0 — would require the OS to handle it, which `ccc` declined to add.

---

## Section 3: Scenario Analysis (3 scenarios)

**Scenario 1: A subtle MMIO bug**

You're adding a new MMIO device — say, a real-time clock at `0x0300_0000` size `0x10`. You add `inRange` checks in both `loadBytePhysical` and `storeBytePhysical`. The first test of "load from RTC offset 0" returns 0 instead of the expected current time.

1. The cascade in `loadBytePhysical` does NOT short-circuit on the first match — list at least one *other* possible cause for the zero return that involves the new device's own code.
2. What's the *minimum* test you should write to confirm the device is actually wired in?

**Scenario 2: Reading the kernel's first PTE**

The kernel's identity map for the kernel text is set up at PA `0x80100000`. You want to verify the L1 entry at index 512 (since `VPN[1] = (0x80000000 >> 22) = 0x200 = 512`) is correct.

1. Where do you find the L1 root table address?
2. What value should the L1 PTE at index 512 hold (specifically, what `PPN` and what flag bits)?
3. If the L1 PTE has `R=W=X=1` (a leaf at L1 — superpage), `ccc` would do what?

**Scenario 3: Adding a new page-fault scenario**

A user program does `lw a0, 0(a1)` where `a1 = 0x00010000` and the L0 PTE for that VPN has `R=0, W=1, X=0, U=1, V=1`. The CPU is in U-mode.

1. What does `translate` return?
2. The executor catches the error — which `trap.Cause` does it pass to `trap.enter`?
3. After the trap, what would the kernel see in `mcause`, `mtval`, and `mepc`?

### Analysis

**Scenario 1: A new MMIO device**

1. The cascade *does* short-circuit on first match (each `if (inRange...) return ...;`), so a 0 return likely means: (a) your `inRange` check isn't matching the address you tested, (b) the device's `readByte(0)` returns 0 (maybe you forgot to populate the time field), (c) the address you tested isn't actually inside the range you declared, or (d) RTC_BASE was not added before RAM_BASE in the cascade and the address fell through. Worth checking each.
2. A direct test in `memory.zig`: store a known byte to the RTC range via `storeBytePhysical`, load it back, assert. Skip the executor entirely. Like:
   ```zig
   try mem.storeBytePhysical(RTC_BASE, 0x42);
   try expectEqual(0x42, try mem.loadBytePhysical(RTC_BASE));
   ```

**Scenario 2: Reading the kernel's first PTE**

1. The L1 root table address is in `cpu.csr.satp & 0x003F_FFFF) << 12`. With satp PPN = 0x80100, root_pa = 0x80100000.
2. The L1 PTE at index 512 should hold a *pointer* to the L0 table (R=W=X=0, V=1) for the kernel text region. Pointer to whatever the kernel allocated for that L0 page. `makePointerPte(l0_table_pa)` builds the right value: `(l0_pa >> 12) << 10 | PTE_V`.
3. If the L1 PTE were a leaf (R=W=X=1, V=1), `ccc` would treat it as a 4 MB superpage attempt. Per `memory.zig`'s `translate`: `if ((l1_pte & (PTE_R | PTE_W | PTE_X)) != 0) return pageFaultFor(access);` — superpage rejected → page fault. The kernel must build only L0-leaf maps.

**Scenario 3: Load with W=1 only PTE**

1. `translate` walks: L1 OK, L0 PTE has V=1, R=W=X != 0 (W=1), so it's a leaf. Permission check for `.load` access: `effective_readable = pte_r or (pte_x and mxr) = false or (false and ...) = false`. So it returns `LoadPageFault`.
2. The executor's `loadTrapCause` maps `error.LoadPageFault` → `trap.Cause.load_page_fault`. Calls `trap.enter(.load_page_fault, va, cpu)`.
3. `mcause = 13` (load page fault), `mtval = 0x00010000` (the faulting VA), `mepc = pre_pc` (the address of the `lw` instruction). `cpu.privilege` flips to M.

---

## Section 4: Reflection Questions

1. **MMIO as a design choice.** Some architectures use *port-mapped I/O* (a separate `in`/`out` instruction) instead of memory-mapped I/O. What are the trade-offs? Why does RISC-V use MMIO exclusively?

2. **Why not superpages?** `ccc` rejects 4 MB superpages. What's the cost? When would you add them? What's the second-order benefit (TLB sizing) that doesn't apply because `ccc` has no TLB?

3. **The hardware-walk choice for A/D bits.** The spec allows two implementations. `ccc` chose the simpler one (hardware updates A/D in-place). What's the *practical* downside of the trap-based alternative? When would a real OS prefer the trap-based variant?

4. **Identity maps everywhere.** The kernel identity-maps every page it cares about. What happens if you map *one less page* than the kernel actually uses? Where does the failure show up?

5. **MPRV's role.** `ccc`'s kernel doesn't use MPRV (it's S-mode normally). When *would* an OS use MPRV? Sketch the workflow.
