# csrs-traps-and-privilege: Further Learning Resources

---

## Specifications

**[RISC-V Privileged ISA Manual — Chapters 2 (CSRs) and 3 (Trap model)](https://riscv.org/technical/specifications/)**
- The source of truth. The CSR list in §2.2, the trap-routing rules in §3.1.6, the delegation table in §3.1.8 — every line in `trap.zig` traces back to this. Difficulty: Reference.

**[`docs/references/riscv-traps.md` in the ccc repo](https://github.com/cyyeh/ccc/tree/main/docs/references)**
- Notes the project authors wrote while implementing Plan 1.C. Common `mcause` values, what each bit of `mstatus` does in `ccc`'s context. Difficulty: Reference.

---

## Books

**[xv6: a simple, Unix-like teaching operating system (RISC-V edition) — Cox et al.](https://pdos.csail.mit.edu/6.S081/2024/xv6/book-riscv-rev3.pdf)**
- Free PDF. Chapter 4 ("Traps and system calls") walks through xv6's trap path, which is closely modeled by `ccc`'s. Pair the two for a deep understanding. Difficulty: Beginner-to-Intermediate.

**[Operating Systems: Three Easy Pieces — §6 ("Mechanism: Limited Direct Execution")](http://pages.cs.wisc.edu/~remzi/OSTEP/cpu-mechanisms.pdf)**
- The conceptual underpinning: why does the OS *need* privilege transitions? What goes wrong without them? Difficulty: Beginner.

**[The RISC-V Reader — Patterson & Waterman](http://www.riscvbook.com/)**
- The "Privileged Architecture" appendix is a friendly walkthrough of the same material as the official spec. Difficulty: Beginner.

---

## Comparable code

**[xv6-riscv: `kernel/trampoline.S`](https://github.com/mit-pdos/xv6-riscv/blob/riscv/kernel/trampoline.S)**
- The user/kernel trampoline that `ccc` cribbed from. Compare line-for-line. Difficulty: Intermediate.

**[xv6-riscv: `kernel/trap.c`](https://github.com/mit-pdos/xv6-riscv/blob/riscv/kernel/trap.c)**
- The S-mode trap dispatcher. `ccc/src/kernel/trap.zig` follows the same shape. Difficulty: Intermediate.

**[OpenSBI](https://github.com/riscv-software-src/opensbi)**
- A production M-mode firmware for RISC-V. What `ccc`'s boot shim is, but for real boards. The `firmware/` and `lib/sbi/` directories are dense but illustrate "M-mode at scale." Difficulty: Advanced.

**[QEMU's `target/riscv/op_helper.c`](https://github.com/qemu/qemu/blob/master/target/riscv/op_helper.c)**
- Functions like `helper_mret` and `helper_sret`. Read alongside `trap.zig`'s `exit_mret`/`exit_sret`. Difficulty: Advanced.

---

## Lectures & courses

**[MIT 6.S081 Lectures 6 & 7 (system call entry, page faults)](https://pdos.csail.mit.edu/6.S081/2024/schedule.html)**
- The lectures that match the xv6 chapter on traps. Free videos. Difficulty: Intermediate.

**[CS 162 (Berkeley): Lecture on Interrupts](https://cs162.org/static/lectures/)**
- Covers the OS perspective on hardware traps in the abstract — applies to RISC-V even though the slides use x86 examples. Difficulty: Beginner.

---

## Articles

**["Privilege Mode Transitions" — Stephen Marz](https://osblog.stephenmarz.com/ch4.html)**
- Part of the Rust-on-RISC-V OS series. The chapter on trap routing is concise and matches `ccc`'s approach almost exactly. Difficulty: Intermediate.

**["What is the difference between mret, sret, and uret?" (Stack Overflow)](https://stackoverflow.com/questions/tagged/risc-v)**
- Various answers on the RISC-V tag walk through specific scenarios. Useful for "why does my code crash on `sret`?" debugging. Difficulty: Beginner.

---

## Tools

**`zig build run -- --trace --halt-on-trap kernel.elf`**
- The codebase's own debugging combo. `--trace` emits one line per instruction *plus* interrupt markers; `--halt-on-trap` stops at the first unhandled trap and dumps registers. Indispensable for trap-related debugging.

**[`scripts/qemu-diff.sh`](https://github.com/cyyeh/ccc/blob/main/scripts/qemu-diff.sh)**
- Diffs `ccc`'s instruction trace against `qemu-system-riscv32` with the same input. If a trap routes to the wrong privilege or saves the wrong CSRs, this catches it. Requires QEMU installed.

---

## When you're ready

Next: **[devices-uart-clint-plic-block](#devices-uart-clint-plic-block)** — the four MMIO devices that produce the interrupts that drive the trap machinery you just learned.
