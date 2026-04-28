# rv32-cpu-and-decode: In-Depth Analysis

## Introduction

The CPU is a state machine. State: 32 general-purpose registers, a program counter, a privilege level, a bag of CSRs, and a pointer to memory. Behavior: a loop that fetches a 32-bit word from `memory[pc]`, decodes it into an `Instruction` record, and dispatches on its opcode. That's it. Every other layer in `ccc` — the kernel, the scheduler, the filesystem, the shell — runs because that loop runs.

This topic walks the loop end-to-end: the **`Cpu` struct** that holds the state, the **`decoder`** that maps a 32-bit word to an `Instruction`, the **`execute.dispatch`** that applies it, and the **`step`** driver that wires everything together. Wherever helpful, we show what *shipped* in `ccc/src/emulator/` rather than reciting the RISC-V Privileged spec.

> **What this topic covers:** RV32I + M + A + Zicsr + Zifencei + privileged (`mret`/`sret`/`wfi`/`sfence.vma`). What it doesn't: floating-point (F/D), compressed (C), 64-bit (RV64) — `ccc` declined them all in its design choices.

---

## Part 1: The CPU as a struct

### Hart state (`src/emulator/cpu.zig`)

`Cpu` is a plain Zig struct. Read the field list and you've seen most of what a CPU "is":

```zig
pub const Cpu = struct {
    regs: [32]u32,            // x0..x31 — x0 is hardwired to zero
    pc: u32,                  // program counter
    memory: *Memory,          // RAM + MMIO behind one pointer
    reservation: ?u32,        // LR/SC reservation address, or null
    privilege: PrivilegeMode, // current mode: M / S / U
    csr: CsrFile,             // every writable CSR's storage
    halt_on_trap: bool,       // CLI flag: dump on first unhandled trap
    trap_taken: bool,         // tripwire for halt_on_trap
    trace_writer: ?*std.Io.Writer, // --trace pipe, if any
    step_mode: bool,          // wasm: don't block in WFI
    ...
};
```

A few things to notice up front:

1. **x0 is enforced in software.** `writeReg(0, anything)` is a no-op; `readReg(0)` returns 0 unconditionally. The 32-element `regs` array technically has storage at index 0, but no code path observes it. This matches the spec's "hardwired to zero" without needing special silicon.
2. **`privilege` is a Zig `enum(u2)` with four variants.** M, S, U map to RISC-V's `mstatus.MPP` field encoding directly (`0b11`/`0b01`/`0b00`). The fourth variant — `reserved_h = 0b10` — exists *only* to make `@enumFromInt(mstatus_mpp)` total for any `u2`. `csrWrite` clamps `0b10` to U before storage, so the variant never legally appears. This is a Zig-specific detail; in C you'd just have a plain enum and a `default` switch arm.
3. **`reservation` is an optional u32.** `null` = no reservation; `Some(addr)` = the address last reserved by `lr.w`. The spec allows broader granularity (a "reservation set"), but `ccc` uses exact address match — simpler, and on a single-hart machine no race is observable.
4. **`step_mode` is a wasm escape hatch.** When the browser demo wants to execute one instruction at a time (so it doesn't freeze the JS Worker thread), it sets `step_mode = true`; this short-circuits `idleSpin` so a `wfi` doesn't actually spin for 10 seconds.

### CSR storage

`CsrFile` is a flat struct of every writable CSR. It has 30+ fields. Some highlights:

- **`mstatus` is split per-field.** Rather than storing the 32-bit `mstatus` value and bit-twiddling on every read/write, `ccc` stores `mstatus_sie: bool`, `mstatus_mie: bool`, `mstatus_spp: u1`, `mstatus_mpp: u2`, etc., each in their own struct field. Reads happen everywhere (the trap dispatcher, the interrupt-deliverable check, the `mret`/`sret` arms), and a flat layout is faster, more readable, and eliminates a class of bit-mask bugs.
- **Read-only CSRs aren't stored.** `misa`, `mhartid`, `mvendorid`, `marchid`, `mimpid` are computed on read in `csr.zig` from constants. There's no field for them in `CsrFile`.

`MIP` (machine interrupt pending) is a special case: storage exists, but the **MTIP** and **SEIP** bits in it are always overlaid with live device state. Whenever code reads `mip`, the read returns `cpu.csr.mip | (CLINT.isMtipPending() << 7) | (PLIC.hasPendingForS() << 9)`. This means the CPU never has to "poll" the timer or interrupt controller — the bits just appear when you look for them.

---

## Part 2: Decoding RV32

### The six instruction formats

RISC-V is a fixed-32-bit ISA (without the C extension, which `ccc` skips). Every instruction has the same opcode in bits `[6:0]`. The other 25 bits are organized into one of six **formats** depending on what kind of instruction it is:

| Format | Used for | Layout |
|--------|----------|--------|
| **R** | reg-reg ops (`add`, `sub`, `and`, ...) | `funct7 \| rs2 \| rs1 \| funct3 \| rd \| opcode` |
| **I** | reg-imm ops, loads, `jalr`, `csrr*`, `ecall` | `imm[11:0] \| rs1 \| funct3 \| rd \| opcode` |
| **S** | stores | `imm[11:5] \| rs2 \| rs1 \| funct3 \| imm[4:0] \| opcode` |
| **B** | conditional branches | `imm[12\|10:5] \| rs2 \| rs1 \| funct3 \| imm[4:1\|11] \| opcode` |
| **U** | `lui`, `auipc` | `imm[31:12] \| rd \| opcode` |
| **J** | `jal` | `imm[20\|10:1\|11\|19:12] \| rd \| opcode` |

Notice the immediate encoding for **B-type** and **J-type**: the bits aren't contiguous. They're scrambled across positions in the instruction word. The reason is silicon-level: by placing each *named bit* (e.g., bit 12 of the immediate) at the same physical position across formats, the chip can wire fewer multiplexers when extracting an immediate. The cost is paid in software, where the decoder has to reassemble the immediate piece by piece.

`decoder.zig` exposes one helper per format:

```zig
pub fn immI(word: u32) i32 { ... }   // I-type: bits 31:20, sign-extended
pub fn immS(word: u32) i32 { ... }   // S-type: bits 31:25 || 11:7
pub fn immB(word: u32) i32 { ... }   // B-type: bits 31|7|30:25|11:8, ×2
pub fn immU(word: u32) i32 { ... }   // U-type: bits 31:12 → upper 20
pub fn immJ(word: u32) i32 { ... }   // J-type: bits 31|19:12|20|30:21, ×2
```

The `B` and `J` immediates are implicitly multiplied by 2 (because the low bit is always zero — RISC-V instructions are 4-byte aligned without C). `immJ` and `immB` reassemble bits and then sign-extend bit 12 / bit 20 to fill the high bits of the result.

### The `Op` enum and `decode()`

Once the immediate is extracted, `decoder.decode(word: u32) -> Instruction` switches on the **opcode** (the low 7 bits) to choose the format and the operation:

```zig
pub fn decode(word: u32) Instruction {
    return switch (opcode(word)) {
        0b0110111 => .{ .op = .lui,   .rd = rd(word), .imm = immU(word), ... },
        0b0010111 => .{ .op = .auipc, .rd = rd(word), .imm = immU(word), ... },
        0b1101111 => .{ .op = .jal,   .rd = rd(word), .imm = immJ(word), ... },
        ...
    };
}
```

Most opcodes uniquely identify the operation (`0b0110111` is always `lui`). A few opcodes hold a *family* of operations distinguished by `funct3` and/or `funct7`:

- `0b0110011` (R-type ALU) splits on `funct3 + funct7` to pick `add`/`sub`/`sll`/`slt`/`sltu`/`xor`/`srl`/`sra`/`or`/`and` — and, with `funct7 = 0x01`, the M-extension's `mul`/`mulh`/`mulhsu`/`mulhu`/`div`/`divu`/`rem`/`remu`.
- `0b1110011` (system) splits on `funct3` and the immediate field to pick `ecall`/`ebreak`/`mret`/`sret`/`wfi`/`sfence.vma`/`csrrw`/`csrrs`/`csrrc`/`csrrwi`/`csrrsi`/`csrrci`.

Anything `decode` can't make sense of returns `.op = .illegal`. The dispatch later turns that into an `instr_illegal` trap.

The output is an `Instruction`:

```zig
pub const Instruction = struct {
    op: Op,
    rd: u5 = 0,
    rs1: u5 = 0, // for csrr*i, this slot holds the 5-bit uimm (NOT a register)
    rs2: u5 = 0,
    imm: i32 = 0,
    csr: u12 = 0,
    raw: u32 = 0,
};
```

`raw` is the original 32-bit word, retained so `--trace` can print the encoding alongside the decoded mnemonic.

---

## Part 3: Executing instructions

### `execute.dispatch`

`execute.zig` has one giant switch on `instr.op`. Each arm:

1. Reads operands (`cpu.readReg(rs1)`, etc.).
2. Computes the result.
3. Writes back to `rd` (or memory, or PC).
4. Advances `pc` — either `pc +%= 4` (sequential), `pc = target` (taken branch / jump), or, on a trap, `pc = stvec/mtvec` (set by `trap.enter`).

A few subtleties shipped:

**Wrapping arithmetic.** RISC-V integer arithmetic wraps mod 2³². Zig's `+` traps on overflow, so `ccc` uses `+%` (wrapping add) everywhere PC and register math happens:

```zig
.add => {
    const a = cpu.readReg(instr.rs1);
    const b = cpu.readReg(instr.rs2);
    cpu.writeReg(instr.rd, a +% b);
    cpu.pc +%= 4;
},
```

**Alignment checks before writes.** `jal` and `jalr` must trap on misaligned targets *without* writing the link register. `ccc`'s `jal` arm computes the target, checks alignment, traps if misaligned, then writes `rd`. The order matters: `riscv-tests rv32mi-ma_fetch` literally checks `bnez t1, fail` right after a trapping JAL/JALR, asserting that `t1` (the link register) is still zero.

**Trap routing on memory faults.** Loads can fault three ways: misaligned, unmapped/protection (`load_page_fault`), or out-of-bounds physical access (`load_access_fault`). The `loadTrapCause` helper maps each `MemoryError` to the right `trap.Cause`:

```zig
fn loadTrapCause(e: LoadOrTransError) !trap.Cause {
    return switch (e) {
        error.MisalignedAccess => trap.Cause.load_addr_misaligned,
        error.OutOfBounds, error.UnexpectedRegister, error.WriteFailed
            => trap.Cause.load_access_fault,
        error.Halt => error.Halt,
        error.LoadPageFault => trap.Cause.load_page_fault,
        ...
    };
}
```

The `error.Halt` case isn't a trap at all — it's the halt-MMIO sentinel, propagated up to `cpu.run` so it terminates the whole emulator.

### LR/SC and atomics

`A` extension instructions are dispatched through the same switch. `lr.w` reads memory *and* sets `cpu.reservation = addr`. `sc.w` checks `cpu.reservation == addr`, then either writes and clears the reservation (success, `rd = 0`) or just clears it (failure, `rd = 1`).

The reservation is also cleared:
- On any trap (per the spec).
- On `sc.w` failure or success.
- On *any* `sc.w` to a non-matching address.

Single-hart emulation makes this nearly trivial — there's no other hart that could invalidate the reservation between LR and SC. The `reservation: ?u32` field exists so future multi-hart work has a hook, and so the `sc.w` semantics are correct relative to interrupts (which clear reservations).

The AMO instructions (`amoadd.w`, `amoswap.w`, etc.) execute in three steps: load, compute, store — atomically from the guest's point of view, since the emulator is single-threaded host-side.

---

## Part 4: The `step()` driver

`Cpu.step()` is the big loop. Every "tick" of the emulated CPU runs through it once:

```zig
pub fn step(self: *Cpu) StepError!void {
    // 1. Service deferred block-device IRQ from the *previous* instruction.
    if (self.memory.block.pending_irq) {
        self.memory.plic.assertSource(1);
        self.memory.block.pending_irq = false;
        ...
    }

    // 2. Check for async interrupts at the instruction boundary.
    if (check_interrupt(self)) return;  // PC has been redirected

    // 3. Fetch.
    const pa = self.memory.translate(self.pc, .fetch, ...) catch ...;
    const word = self.memory.loadWordPhysical(pa) catch ...;

    // 4. Decode.
    const instr = decoder.decode(word);

    // 5. Execute.
    execute.dispatch(instr, self) catch ...;

    // 6. Emit a trace line if --trace is on.
    if (self.trace_writer) |tw| { trace.formatInstr(tw, ...) }
}
```

Step 1 is subtle. The block device runs synchronously inside `memory.zig` — when the guest writes the CMD register, the transfer happens *during* that store instruction. But the IRQ shouldn't be visible to the same instruction that triggered it. So `block.pending_irq = true` defers the assertion to the *next* instruction boundary, which is here.

Step 2 enforces the spec rule that interrupts are taken **between** instructions, never mid-instruction. `check_interrupt` consults the effective `mip` (storage OR'd with live device pending), masks against `mie`, walks the priority order, applies delegation routing through `mideleg`, and finally checks if the target privilege actually allows delivery (the spec rule: lower current → always taken; equal → consult `MIE`/`SIE`; higher current → never).

Step 3's `translate` is privilege-aware — fetches always use the current privilege, *not* an MPRV-translated effective privilege (the spec explicitly excludes MPRV from instruction fetch).

### `idleSpin` and `wfi`

When `wfi` executes, `execute.zig` calls `cpu.idleSpin()`. That function:

- Returns immediately if `step_mode` is set (wasm escape).
- Otherwise spins for up to **10 seconds wall-clock** in 1 ms sleep increments, draining `--input` bytes through `uart.rx_pump`, servicing block IRQs, and checking for deliverable interrupts on each iteration.
- Returns when an interrupt is taken (and `cpu.trap_taken` is set, so `step` knows not to advance PC after the WFI), or when 10 s elapses (defensive — should not normally happen).

The 10 s timeout is a safety net: if a guest gets stuck in WFI with no interrupt source, the emulator returns rather than hanging forever.

---

## Part 5: How privilege levels participate in fetch

Fetch uses **`cpu.privilege` directly**. This is correct per the spec (`§4.1.1`: "Instruction fetches are not affected by `MPRV`"). For loads and stores, however, `effectivePriv()` is used, which substitutes `cpu.csr.mstatus_mpp` if `MPRV=1` and current privilege is M.

This distinction matters for the kernel. When the kernel needs to read user memory (e.g., to copy the path string in an `openat` syscall), it sets `MPRV=1` to make its loads go through user-privilege translation, performs the access, then clears `MPRV`. Fetch is never affected — the kernel's own code keeps running at S-mode privilege the whole time.

---

## Part 6: A concrete encoding

Take **`addi a0, zero, 42`**:
- I-type, opcode `0b0010011`
- `rd = 10` (a0), `rs1 = 0` (zero), `funct3 = 0`, `imm = 42`
- Encoded: `0x02A00513`

Hand-verify: `0x02A00513`
- bits `[6:0]` = `0b0010011` ✓ (opcode for I-type ALU)
- bits `[11:7]` = `0b01010` = 10 ✓ (rd = a0)
- bits `[14:12]` = `0b000` ✓ (funct3 = 0 = addi)
- bits `[19:15]` = `0b00000` = 0 ✓ (rs1 = zero)
- bits `[31:20]` = `0b000000101010` = 42 ✓ (imm)

After `decode`: `Instruction{op=.addi, rd=10, rs1=0, imm=42, ...}`.
After `dispatch`: `regs[10] = 0 +% 42 = 42`, `pc +%= 4`.
After `--trace`: prints `[M] 0x80000000 02a00513 addi a0, zero, 42 → a0=0x0000002a`.

This is the entire CPU executing one instruction. The other ~70 instructions in `Op` follow the same pattern.

---

## Summary & Key Takeaways

1. **A CPU is a struct.** `Cpu` holds 32 regs, a PC, a privilege level, a CSR file, and a memory pointer. Everything else is a method on it.

2. **`x0` is hardwired in software.** Writes ignored, reads return zero. The 32nd register slot exists, but is never observed.

3. **Decoding RV32 = format-aware bit extraction.** Six formats (R, I, S, B, U, J) with one immediate-builder per format. The B and J immediates have scrambled bit positions for silicon reasons; the decoder reassembles them.

4. **`decode()` returns a flat `Instruction` record** with `op`, `rd`, `rs1`, `rs2`, `imm`, `csr`, `raw`. Illegal instructions decode to `op = .illegal`, which `dispatch` converts to a trap.

5. **`dispatch` is one giant switch.** Each arm reads operands, computes, writes `rd`, and bumps `pc +%= 4` — except branches/jumps (which set `pc = target` after alignment check) and traps (where `trap.enter` redirects PC).

6. **Wrapping arithmetic is explicit.** `+%` and `-%` everywhere PC and register math happens, because RISC-V wraps mod 2³² and Zig's default `+` traps on overflow.

7. **Memory faults route through `loadTrapCause`/`storeTrapCause`** to the right `trap.Cause`. The halt-MMIO sentinel is a special `error.Halt` that bypasses traps and propagates up to terminate the run.

8. **LR/SC reservations are tracked as `?u32`.** Single-hart emulation makes the spec's reservation semantics nearly trivial — no other hart can invalidate.

9. **`step()` is the orchestrator.** Service deferred IRQs → check async interrupts at the boundary → fetch → decode → execute → trace. Interrupts are taken *between* instructions, never mid-instruction.

10. **Privilege participates in fetch directly.** No MPRV magic on instruction fetch. Loads/stores use `effectivePriv()` which honors MPRV; fetch always uses `cpu.privilege`.

11. **`wfi` calls `idleSpin`**, which blocks for up to 10 s wall-clock waiting for a deliverable interrupt — *unless* `step_mode` is set (the wasm path), which makes WFI a no-op so the browser tab doesn't freeze.
