# rv32-cpu-and-decode: Practice & Self-Assessment

> Complete these after reading the analysis and the beginner guide. Answers at each section's end. Where a question has a `ccc`-specific answer, the quiz tells you to point at a file.

---

## Section 1: True or False (10 questions)

**1.** RISC-V instructions can be 16, 32, or 48 bits depending on the encoding. `ccc` supports all three.

**2.** `x0` is a register that physically exists in the `Cpu` struct's `regs[32]` array, but writes to it are silently dropped.

**3.** Every RV32 instruction is exactly 4 bytes long, so `pc` advances by 4 on sequential execution.

**4.** The `decoder.decode(word: u32) -> Instruction` function returns an `Instruction` struct that includes the original raw word as a field.

**5.** Branch targets in RISC-V are encoded as relative offsets from PC, with the low bit always implicit zero (since instructions are 2-byte aligned without C extension).

**6.** In `ccc`, `lr.w` clears the reservation. The reservation is set by `sc.w`.

**7.** Async interrupts can be taken in the middle of executing an instruction.

**8.** `Cpu.privilege` starts at `M` after `Cpu.init`. The boot shim transitions to S, then to U.

**9.** `wfi` in `ccc`'s emulator blocks the host process for up to 10 seconds wall-clock waiting for a deliverable interrupt.

**10.** RV32 `addi a0, a0, -1` decrements `a0` by one. The `-1` is encoded in the I-type immediate field as a 12-bit two's-complement.

### Answers

1. **False.** `ccc` is RV32 only and skips the C (compressed) extension, so all instructions are exactly 32 bits. The spec allows 16 / 32 / 48 / 64 / 80+ bit instructions in principle (depending on extensions); `ccc` chose the simplest path.
2. **True.** `cpu.regs[0]` has storage, but `writeReg(0, _)` returns early and `readReg(0)` returns 0 unconditionally. See `src/emulator/cpu.zig`.
3. **True.** Without the C extension, every instruction is 32-bit and 4-byte aligned. JAL/JALR/branch targets must be 4-aligned or trap.
4. **True.** `Instruction.raw: u32` carries the original word so `--trace` can print the encoding alongside the disassembly.
5. **False.** Branches are 4-byte aligned without C, so the *low two* bits are zero. (With C they'd be 2-byte aligned. `ccc` doesn't have C.)
6. **False.** It's the other way: `lr.w` SETS the reservation; `sc.w` CHECKS and CLEARS it (success or failure). Traps also clear it.
7. **False.** Per spec, async interrupts are taken at instruction boundaries. `cpu.step()` enforces this with `if (check_interrupt(self)) return;` *before* fetching.
8. **True.** See `Cpu.init`; `.privilege = .M`. The boot shim's `mret` is the M→S transition.
9. **True.** `idleSpin` spins for up to 10 seconds. The cap is a defensive timeout; under normal operation an interrupt arrives much sooner.
10. **True.** I-type immediate is 12 bits, sign-extended to 32. `-1` encoded in 12 bits is `0xFFF`. The encoding for `addi a0, a0, -1` is `0xFFF50513`.

---

## Section 2: Multiple Choice (8 questions)

**1.** What does the I-type immediate decoder do with a value whose top bit (bit 11) is set?
- A. Treats it as zero.
- B. Sign-extends bit 11 to fill bits 31:12 with 1s.
- C. Returns an error.
- D. Multiplies it by 2.

**2.** In `ccc`, `Cpu.step()` does the following at the very start of each iteration. Which is FIRST?
- A. Fetch the next instruction word.
- B. Service deferred block-device IRQs by asserting PLIC source 1.
- C. Decode the instruction.
- D. Check if a halt is pending.

**3.** `addi a0, zero, 42` encodes to which 32-bit hex value?
- A. `0x02A00513`
- B. `0x0002A013`
- C. `0x0002A513`
- D. `0x42000013`

**4.** Which Zig operator does `ccc` use for register arithmetic?
- A. `+` and `-` (default — Zig traps on overflow).
- B. `+%` and `-%` (wrapping arithmetic).
- C. Custom helpers.
- D. `@addWithOverflow`.

**5.** The `B`-type immediate (used by `beq` and friends) encodes its 13-bit signed offset across which named bits in the instruction word?
- A. Bits 31:20 (contiguous, sign-extended).
- B. Bits 31:25 || 11:7 (two contiguous chunks).
- C. Bits 31|7|30:25|11:8 (scrambled, with implicit ×2).
- D. Bits 31|19:12|20|30:21 (J-type style).

**6.** Why does `wfi` need an "escape hatch" (`step_mode`) for the wasm build but not for the CLI build?
- A. Wasm doesn't support 64-bit timers.
- B. Wasm runs in a Web Worker that can't block on the JS event loop indefinitely without freezing the tab.
- C. Wasm has a different instruction set.
- D. The wasm build doesn't include the CLINT.

**7.** Which of these is NOT in `ccc`'s `Op` enum?
- A. `ecall`
- B. `mret`
- C. `c.lwsp` (compressed)
- D. `wfi`

**8.** When `dispatch` sees `instr.op == .illegal`, what happens?
- A. The emulator panics.
- B. `trap.enter(.instr_illegal, ...)` is called and dispatch returns.
- C. The instruction is silently treated as a NOP.
- D. The CPU halts.

### Answers

1. **B.** I-type is signed; bit 11 is the sign bit. `decoder.zig`'s `immI` does the sign-extend.
2. **B.** Step 1 services the deferred block IRQ before checking interrupts. See the `if (self.memory.block.pending_irq)` block in `cpu.step`.
3. **A.** Verify by hand: opcode `0x13` (I-type ALU), rd=10 (a0), rs1=0, funct3=0, imm=42=0x2A → `0x02A00513`. The interactive's encoder will confirm.
4. **B.** `+%` / `-%` everywhere PC + register math happens. RV math wraps mod 2³².
5. **C.** B-type bits are scrambled. `decoder.zig`'s `immB` reassembles them piece by piece.
6. **B.** Web Worker thread shouldn't block ≥10s. The `step_mode` short-circuit makes `wfi` return immediately.
7. **C.** `c.lwsp` is a compressed (C-extension) instruction. `ccc` skips the C extension entirely.
8. **B.** Illegal-instruction traps go through `trap.enter`; `mcause = 2`, `mtval = pc`.

---

## Section 3: Scenario Analysis (3 scenarios)

**Scenario 1: A subtle bug**

You're implementing the `srli` (shift right logical, immediate) instruction. In `decoder.zig`, you handle opcode `0x13` and `funct3 = 5`. You read the shift amount from the I-immediate's bottom 5 bits, dispatch to `srli`, and call it a day. The conformance test `rv32ui-p-srai` fails. Why?

1. What did you forget?
2. Where in `decoder.zig` is the right place to make the distinction?

**Scenario 2: Tracing a phantom write**

You enable `--trace` and run `ccc kernel.elf`. The trace shows:

```
[M] 0x80000010 30200073 mret           ← privilege flips here
[U] 0x80001000 02a00513 addi a0, zero, 42 → a0=0x0000002a
[U] 0x80001004 00000013 addi zero, zero, 0 → (no rd write)
```

1. Why does the third line not show `→ zero=...` even though `zero` is the destination register?
2. What would the line look like for `mret` itself (line 1) — does the trace include any post-state delta?

**Scenario 3: Adding a new ISA extension**

You decide to add `andn` (bitwise and-not) — a Zbb extension instruction. It's R-type, opcode `0x33`, funct3 `0x7`, funct7 `0x20`.

1. Which two files do you need to edit at minimum?
2. After editing those, what's the smallest test you should write to confirm correctness?
3. The instruction `and a0, a0, a1` already lives at `0x33 / funct3=7 / funct7=0`. How is your new instruction distinguished?

### Analysis

**Scenario 1: SRLI vs SRAI**

1. Both `srli` and `srai` use opcode `0x13`, funct3 `5`. The distinction is in the high bits of the I-immediate: `srli` has `funct7 == 0x00`, `srai` has `funct7 == 0x20`. (Yes — even though the I-immediate is normally 12 bits, the shift instructions reuse the upper 7 bits as a `funct7` encoding for the variant.)
2. In `decoder.zig`'s `0x13` arm, you'd check `bits 31:25` (or `funct7(word)`) and pick `.srli` vs `.srai` based on the value. The current code does exactly that:
   ```zig
   mnemonic = (f3 === 5 && f7 === 0x20) ? 'srai' : (f3 === 5 ? 'srli' : ...);
   ```

**Scenario 2: The phantom write**

1. The third line's `addi zero, zero, 0` is the canonical NOP. Its `rd` is `x0`, which never accepts writes. `--trace` checks `if (instr.rd != 0)` before printing the delta — so writes to `x0` produce no `→ ...` text. (The `pre_rd`/`post_rd` capture happens regardless, but the formatter elides them.)
2. `mret` is more interesting. It writes to `pc` (the trap-frame's mepc), `privilege` (popped from MPP), and `mstatus` (MIE/MPIE bits flipped). The `--trace` formatter only shows `rd` deltas; `mret` has `rd = 0`, so no integer-register delta is printed. But the next line's `[M]→[U]` privilege change *is* visible because the privilege column updates. Async interrupt markers and the privilege column together tell the privilege story.

**Scenario 3: Adding `andn`**

1. `decoder.zig` (add `.andn` to the `Op` enum and a decode arm) and `execute.zig` (add a `.andn` case in `dispatch` that does `cpu.writeReg(rd, rs1_val & ~rs2_val)`).
2. A unit test in `execute.zig` test block that hand-encodes an `andn` instruction at `RAM_BASE`, runs `cpu.step()`, and asserts the result. Pattern matches the existing `Cpu.step()` test cases.
3. By `funct7`. `and` is `funct7 = 0x00`; `andn` is `funct7 = 0x20`. The `0x33` arm in `decoder.zig` already inspects `funct7` (e.g., to distinguish `add` from `sub`) — `andn` slots into the same dispatch.

---

## Section 4: Reflection Questions

1. **The "everything is data" argument.** Read `src/emulator/cpu.zig`'s `Cpu` struct + `decoder.zig`'s `Instruction` + `execute.zig`'s `dispatch`. Make the case (in your own words) for why a CPU is "just" a state machine with a switch statement. What invariants would break if you removed wrapping arithmetic? If you stored `regs[0]` as actually-zero instead of guarding writes? If you stopped clearing the LR/SC reservation on traps?

2. **What's the simplest extension you'd add?** Imagine `ccc` wanted RV32 + Zbb (bitmanipulation: `andn`, `orn`, `xnor`, `clz`, `ctz`, `cpop`, ...). Which files change? Which tests need to grow? What about `--trace` formatting?

3. **Privilege as a software construct.** `Cpu.privilege` is a `u2` Zig enum. There's no actual "M-mode hardware bit" — the value is just a number that other code reads to make decisions (CSR access checks, MMIO permission, interrupt routing). What does this teach you about how privilege "works" on real silicon?

4. **The decoder vs dispatch split.** Why does `ccc` separate the decoder (extract fields) from the executor (do the thing)? What benefits does this give? When would you merge them?

5. **`step_mode` as a design pattern.** The flag lets one `Cpu` struct serve both a blocking CLI host and a non-blocking browser host with no other changes. Where else does the codebase use comptime or runtime flags to support multiple build targets cleanly? What happens if you forget to set/clear `step_mode` correctly in a new caller?
