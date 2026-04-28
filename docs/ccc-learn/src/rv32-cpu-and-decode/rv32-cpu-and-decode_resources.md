# rv32-cpu-and-decode: Further Learning Resources

A curated list of where to go next once `ccc`'s emulator clicks. Bias toward primary specs (so you can fact-check `ccc`) and "build it yourself" books (so you can extend `ccc`).

---

## Books

**[The RISC-V Reader: An Open Architecture Atlas — David Patterson & Andrew Waterman](http://www.riscvbook.com/)**
- The friendliest introduction to RISC-V. Covers the unprivileged ISA in plain language, with worked examples for every instruction class. Difficulty: Beginner.

**[Computer Organization and Design RISC-V Edition — Patterson & Hennessy](https://www.elsevier.com/books/computer-organization-and-design-risc-v-edition/patterson/978-0-12-820331-6)**
- The canonical undergrad textbook for "what is a CPU?" Recently updated to use RISC-V instead of MIPS as the running example. The pipelining + caches chapters go beyond `ccc`'s emulator, but the early chapters dovetail perfectly. Difficulty: Beginner-to-Intermediate.

**[Writing a Simple Operating System from Scratch — Nick Blundell](https://www.cs.bham.ac.uk/~exr/lectures/opsys/10_11/lectures/os-dev.pdf)**
- A free PDF that builds an x86 OS in a few hundred pages. Not RISC-V, but the *approach* is identical to `ccc`'s phase decomposition. Difficulty: Intermediate.

**[Writing an Interpreter in Go — Thorsten Ball](https://interpreterbook.com/)**
- Looks unrelated, but the decode→dispatch architecture in this book is essentially what `decoder.zig` + `execute.zig` do. The pattern for "parse then walk a tagged union" is universal. Difficulty: Beginner-to-Intermediate.

---

## Specifications (primary sources — read these to fact-check anything)

**[RISC-V Unprivileged ISA Manual (Volume I)](https://riscv.org/technical/specifications/)**
- The base spec for RV32I/RV32M/RV32A/Zicsr/Zifencei. Free PDF. The encoding tables in the back are the source of truth for `decoder.zig`'s field layouts. Difficulty: Reference.

**[RISC-V Privileged Architecture Manual (Volume II)](https://riscv.org/technical/specifications/)**
- M/S/U mode, CSRs, traps, paging. We dive deep into this in [csrs-traps-and-privilege](#csrs-traps-and-privilege) and [memory-and-mmio](#memory-and-mmio); but the chapter on the CSR list (Chapter 2) is also where `ccc`'s `csr.zig` started. Difficulty: Reference.

**[The RISC-V Instruction Set Manual ASCII version](https://github.com/riscv/riscv-isa-manual)**
- The repo behind the official PDFs. PRs against this repo are how the spec evolves. Useful when you want to read the *why* behind a recent change. Difficulty: Reference.

---

## Online courses & lectures

**[CS61C — Great Ideas in Computer Architecture (UC Berkeley)](https://inst.eecs.berkeley.edu/~cs61c/)**
- Free lecture videos and labs. RISC-V from the silicon up. The undergrad version of "what is a CPU?" — labs include building a single-cycle CPU in Logisim. Difficulty: Beginner.

**[The MIT 6.S081 Operating Systems Course](https://pdos.csail.mit.edu/6.S081/)**
- Free. Uses xv6-riscv (the codebase that inspired `ccc`'s kernel). Each lecture has a corresponding chapter in the xv6 book. Difficulty: Intermediate.

**[Build a 65c02-based computer from scratch — Ben Eater](https://eater.net/8bit/)**
- Not RISC-V, but the YouTube series builds an actual functioning CPU on a breadboard, talking through fetch / decode / execute / interrupts. If `ccc`'s software emulator feels abstract, watching Ben hand-toggle a bus will fix that. Difficulty: Beginner.

---

## Comparable open-source RV32 emulators

**[rvemu (Asami Doi)](https://github.com/d0iasm/rvemu)**
- A RISC-V emulator in Rust. Single-hart, RV64. Reading it side-by-side with `ccc/src/emulator/` is a great cross-reference for how `decode` + `dispatch` are structured. Difficulty: Intermediate.

**[Spike (riscv-isa-sim)](https://github.com/riscv-software-src/riscv-isa-sim)**
- The reference RISC-V ISA simulator. C++. Heavyweight (RV64 + extensions + microarch options) but the *de facto* "is my emulator behavior correct?" arbiter. Difficulty: Advanced.

**[QEMU's RISC-V backend](https://www.qemu.org/docs/master/system/target-riscv.html)**
- A production-quality emulator with TCG (binary translation), full SBI, virtio, and SMP support. `ccc/scripts/qemu-diff.sh` literally diffs `ccc`'s `--trace` output against `qemu-system-riscv32` to catch regressions. Difficulty: Advanced.

**[xv6-riscv](https://github.com/mit-pdos/xv6-riscv)**
- Not an emulator, but the kernel `ccc`'s kernel was modeled after. Reading xv6's `kernel/main.c` and `kernel/trap.c` is the single best companion reading for the kernel topics. Difficulty: Intermediate.

---

## Zig-specific resources

**[ziglang.org/learn](https://ziglang.org/learn/)**
- Official Zig docs. The "language reference" is the source of truth for `comptime`, `@bitCast`, error unions, and the freestanding target. Difficulty: Reference.

**[Andrew Kelley's "What is Zig's Comptime?" talk](https://www.youtube.com/watch?v=UpEBjP6X3VQ)**
- Comptime is what makes `ccc`'s `clint.zig` host-aware without runtime branches. This 30-minute talk is the cleanest explanation. Difficulty: Beginner.

**[Zig.guide — Sobeston](https://zig.guide/)**
- A community-maintained tutorial that's been kept up-to-date with recent Zig versions. Difficulty: Beginner.

---

## Articles & deep dives

**[Stephen Marz: Adventures in OS Development (RISC-V series)](https://osblog.stephenmarz.com/)**
- A long-running blog that builds an OS in Rust on RISC-V. Has chapters on the decoder, MMIO, the PLIC, paging — same scope as `ccc`'s phases. Difficulty: Intermediate.

**[Nikola Smiljanić: Writing a RISC-V Emulator in C++](https://nikola.io/2021/01/15/risc-v.html)**
- A short series. The "decode" post in particular is a clean walkthrough of immediate-extraction code. Difficulty: Intermediate.

**[Tinyemu (Fabrice Bellard)](https://bellard.org/tinyemu/)**
- Bellard (of QEMU and ffmpeg fame) wrote a tiny RISC-V emulator that fits in a browser — the spiritual ancestor of `ccc`'s wasm demo. The "compact" emulator code is worth a read for ideas. Difficulty: Advanced.

---

## Tools

**[GodBolt Compiler Explorer](https://godbolt.org/) — RISC-V target**
- Type C, see the RV32 assembly. Invaluable for "what does this expression actually compile to?" Difficulty: Beginner.

**[`riscv64-elf-gcc` toolchain](https://github.com/riscv-collab/riscv-gnu-toolchain)**
- The official cross-compiler. `ccc` uses Zig's built-in cross-compilation instead of this, but for assembly fixtures and the `riscv-tests` submodule, this is what builds them. Difficulty: Reference.

**[`gdb-multiarch` + `ccc`'s --trace](https://www.gnu.org/software/gdb/)**
- Not a fancy debugger setup, but for stepping through ELF programs with source-level info, gdb-multiarch attached over serial is the standard tool. `ccc` doesn't ship a gdb stub — the `--trace` flag fills that role for now.

---

## When you're ready to move on

After `rv32-cpu-and-decode` clicks, the natural next step is **[memory-and-mmio](#memory-and-mmio)** — what the loads and stores in this topic *actually do*. After that, **[csrs-traps-and-privilege](#csrs-traps-and-privilege)**, which explains why the `Cpu` struct has `csr` and `privilege` fields and what they're for.
