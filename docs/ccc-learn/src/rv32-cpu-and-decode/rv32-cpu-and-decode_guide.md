# rv32-cpu-and-decode: A Beginner's Guide

## What Is a CPU?

Imagine a very, very fast cook in a tiny kitchen. The kitchen has:

- **32 little jars** on a shelf labeled `x0` through `x31`. Each jar can hold a 32-bit number.
- **One big book of recipes** sitting on the counter. Recipes are numbered.
- **A bookmark** showing which recipe to do next.
- **A pantry** (memory) where ingredients live, addressed by a number.

The cook does the same thing forever:

1. **Look at the bookmark.** What's the next recipe number?
2. **Read that recipe** out of the book.
3. **Do what it says** — usually, take stuff from a few jars, do a tiny bit of math, and put the result in another jar.
4. **Move the bookmark forward.**
5. Goto 1.

That's a CPU. The bookmark is the **program counter** (PC). The jars are **registers**. The book of recipes is your program in memory. The recipes themselves are called **instructions**.

In `ccc/src/emulator/cpu.zig`, that whole picture is one Zig struct:

```zig
pub const Cpu = struct {
    regs: [32]u32,          // the 32 jars
    pc: u32,                // the bookmark
    memory: *Memory,        // pointer to the pantry
    privilege: PrivilegeMode,
    csr: CsrFile,           // a side-shelf for special status registers
    ...
};
```

If you can read that, you can read the rest of the CPU. The whole CPU is data.

---

## Part 1: Why Are There 32 Jars?

It's a tradeoff. Fewer jars → more trips to the pantry (slow). More jars → bigger encoding for "which jar?" (recipe gets fatter).

RISC-V picked 32 because it's the sweet spot most architectures land on. Five bits encode "which of the 32 jars?" (2⁵ = 32). That leaves room in a 32-bit recipe for an opcode plus three jars (one destination + two sources) plus a small constant.

**One jar is special: `x0` is always zero.** You can "write" to it but the write is silently ignored. Why? Because every program needs a constant zero, and giving it a register slot saves an instruction every time you need one. RISC-V's "zero everywhere" trick is one of the reasons it's so clean.

In `ccc`:

```zig
pub fn writeReg(self: *Cpu, idx: u5, value: u32) void {
    if (idx == 0) return; // x0 hardwired to zero
    self.regs[idx] = value;
}
```

Two lines, one comment. That's how the spec's "x0 = 0 forever" rule gets enforced.

---

## Part 2: What Does an Instruction Look Like?

A recipe in our book is exactly **32 bits** (4 bytes). Every recipe has the same length — that's the "RISC" in RISC-V (Reduced Instruction Set Computer). Compare with x86, where instructions can be 1–15 bytes long; just *finding* where one ends is hard. With RV32, you bump the bookmark by 4 and you're done.

Inside those 32 bits:

- **The lowest 7 bits** say what *kind* of recipe it is (opcode).
- The other 25 bits encode the rest: which jars, what constant, what flavor.

Example: `addi a0, zero, 42` ("Take jar `zero`, add 42, put result in jar `a0`.")

Encoded in 32 bits: `0x02A00513`. Or in binary:

```
 31    20    19  15  14 12  11  7   6        0
 |-----------|------|------|-----|----------|
   42 (imm)   zero  funct3   a0    opcode
                    (= 0)         (= 0010011)
                    "addi"
```

`decoder.zig` peels these fields off:

```zig
pub fn opcode(word: u32) u7 { return @truncate(word & 0x7F); }   // bits 6:0
pub fn rd(word: u32) u5    { return @truncate((word >> 7) & 0x1F); } // bits 11:7
pub fn rs1(word: u32) u5   { return @truncate((word >> 15) & 0x1F); }// bits 19:15
...
```

Bit-shift, bit-mask, done.

**Why aren't all instructions formatted the same?** Because some need a destination + 2 sources, some need a destination + 1 source + a constant, some are just "jump to this offset," some are "store this value at this address." RISC-V has six formats, each chosen to fit a different kind of instruction. The five-letter mnemonics in the spec — R, I, S, B, U, J — name them. The decoder has one helper per format that pulls out the immediate (the "constant" part):

```zig
pub fn immI(word: u32) i32 { ... }   // I-type: constant is bits 31:20, sign-extended
pub fn immU(word: u32) i32 { ... }   // U-type: constant is bits 31:12 in upper half
```

The B and J formats scramble the immediate bits across the word. That's a hardware optimization (it puts each *named* bit at the same position across formats so the silicon can extract them with fewer wires). For us reading software, it's just bookkeeping in the decoder.

---

## Part 3: The Forever Loop

Here's the heart of the CPU, simplified:

```
forever:
    word = memory[pc]              # fetch
    instr = decode(word)            # decode
    do_what_it_says(instr)          # execute
    pc = pc + 4                     # advance bookmark (unless it was a jump)
```

In real `ccc/src/emulator/cpu.zig`:

```zig
pub fn step(self: *Cpu) StepError!void {
    if (check_interrupt(self)) return;            // any IRQ to take?
    const word = self.memory.loadWordPhysical(...) catch ...;
    const instr = decoder.decode(word);
    execute.dispatch(instr, self) catch ...;
    // (trace logging if --trace is on)
}
```

The `check_interrupt` step at the top is "is the doorbell ringing?" We'll come back to that in [csrs-traps-and-privilege](#csrs-traps-and-privilege). For now, picture it as: if the timer or a device wants the CPU's attention, drop everything and run the doorbell handler.

---

## Part 4: How Does the CPU "Do What the Recipe Says"?

`execute.dispatch` is a giant switch statement. There are ~70 different instructions in RV32IMA + Zicsr; each one gets its own arm:

```zig
pub fn dispatch(instr: Instruction, cpu: *Cpu) !void {
    switch (instr.op) {
        .add => {
            const a = cpu.readReg(instr.rs1);
            const b = cpu.readReg(instr.rs2);
            cpu.writeReg(instr.rd, a +% b);     // wrapping add
            cpu.pc +%= 4;
        },
        .addi => {
            const a = cpu.readReg(instr.rs1);
            cpu.writeReg(instr.rd, a +% @as(u32, @bitCast(instr.imm)));
            cpu.pc +%= 4;
        },
        .beq => { ... taken branch checks ... },
        .lw  => { ... memory load with trap on fault ... },
        ...
    }
}
```

Notice the `+%` instead of `+`. That's Zig saying "wrap on overflow, don't trap." RISC-V arithmetic wraps modulo 2³² (16 + 4 billion = 16, basically). Zig's default `+` would crash on overflow, so we use the wrapping version everywhere.

#### Example: A Real Round-Trip

```
addi a0, zero, 42          # 0x02A00513
```

1. `step()` fetches the word `0x02A00513` from memory.
2. `decode()` returns `Instruction { op = .addi, rd = 10, rs1 = 0, imm = 42 }`.
3. `dispatch()` enters the `.addi` arm:
   - reads `regs[0]` → `0` (because x0 is always zero)
   - computes `0 +% 42` → `42`
   - writes `42` to `regs[10]` (the `a0` register)
   - bumps `pc` by 4
4. Loop ends; next iteration fetches the *next* recipe.

That's it. The whole CPU is doing this 100 million times a second on a real chip — and 100 thousand times a second in our software emulator, which is plenty for a working OS.

---

## Part 5: What's Special About `lui`, `auipc`, `jal`, `lr.w`?

A few instructions deserve a beginner mention because their names are weird:

- **`lui rd, imm`** — "Load Upper Immediate." `rd = imm << 12`. Used to build a 32-bit constant in two steps: `lui` for the upper 20 bits, then `addi` for the lower 12. RISC-V doesn't have "load 32-bit constant" in one instruction; this is the workaround.
- **`auipc rd, imm`** — "Add Upper Immediate to PC." Like `lui` but adds the result to PC. Used to compute PC-relative addresses (e.g., to resolve a global symbol without a wide constant load).
- **`jal rd, offset`** — "Jump And Link." Sets `rd = pc + 4` (return address) and `pc = pc + offset`. This is how function calls happen on RISC-V — `rd` is conventionally `ra` (x1).
- **`lr.w rd, (rs1)`** / **`sc.w rd, rs2, (rs1)`** — "Load-Reserved" and "Store-Conditional." This pair is RISC-V's way of doing atomic operations. `lr.w` reads memory *and* sets a "reservation" on that address. `sc.w` writes memory *only if* the reservation is still set, otherwise it fails (returns 1 in `rd` instead of 0). On a single-hart machine like `ccc`, the reservation is essentially trivial — no other CPU can invalidate it. But the API is there because the spec demands it, and Phase 4's network stack might want it.

---

## Part 6: But Wait, How Does the Bookmark Get *to* the First Recipe?

When you boot a real RISC-V machine, the PC starts at a hardware-defined reset address. In `ccc`, **the entry point comes from the ELF file's header**:

```zig
// src/emulator/main.zig — when we load an ELF:
const entry = elf.entry_point;      // from the ELF header
var cpu = Cpu.init(&memory, entry); // PC starts here
```

The `hello.elf` we ship has its entry point at `0x80000000` (the start of RAM). The bootloader for the kernel `kernel.elf` is at the same address — the M-mode boot shim, which we'll cover in [kernel-boot-and-syscalls](#kernel-boot-and-syscalls).

For hand-crafted demos that aren't ELFs (like the early `--raw 0x80000000` mode), `main.zig` has a fallback path that loads the bytes at the given address and starts PC there too.

---

## Part 7: What's NOT Here?

`ccc` skips:

- **F and D extensions** — floating-point. We use only integer arithmetic. (Reason: shells, filesystems, and HTTP don't need floats.)
- **The C extension** — compressed (16-bit) instructions. They'd cut binary size by ~30% but complicate every fetch (now the PC can be 2-byte-aligned). Not worth the complexity for a teaching emulator.
- **64-bit (RV64)** — `ccc` is RV32 only. Pointers are 32 bits, page tables are smaller (Sv32 instead of Sv39), and the whole system fits in 128 MB of RAM.
- **Multiple harts** — single CPU. No SMP, no cache-coherence model, no TLB shootdowns. Atomics are correct but trivial.

These are deliberate choices, not omissions. Each removed feature would have added pages of code and weeks of debugging without making the system more *educational*.

---

## Quick Reference

| Concept | One-liner |
|---------|-----------|
| Register | One of 32 32-bit "jars." `x0` is hardwired to zero. |
| PC | The "bookmark" — address of the next instruction to fetch. |
| Instruction | A 32-bit recipe word. Always 4 bytes (no C extension here). |
| Opcode | Low 7 bits of the instruction — picks the kind of recipe. |
| Decode | Take the 32-bit word apart into (op, rd, rs1, rs2, imm). |
| Dispatch | One big switch on `op`; do what the recipe says. |
| Wrapping arithmetic | `+%`, `-%` — RV math wraps mod 2³². |
| `lui` + `addi` | Build a 32-bit constant in two instructions. |
| `lr.w` + `sc.w` | Atomic primitives. Reservation tracked as `?u32` in `Cpu`. |
| `wfi` | "Sleep until something interrupts me." `cpu.idleSpin` does the actual waiting. |

If you're confused about anything here, the **Interactive** tab has a working encoder/decoder you can poke at.
