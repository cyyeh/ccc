# kernel-boot-and-syscalls: Further Learning Resources

---

## Books

**[xv6 book — Chapters 3 (Page tables) and 4 (Traps and system calls)](https://pdos.csail.mit.edu/6.S081/2024/xv6/book-riscv-rev3.pdf)**
- The closest companion to `ccc`'s kernel. Free PDF. Read alongside `src/kernel/`. Difficulty: Beginner-to-Intermediate.

**[Operating Systems: Three Easy Pieces — §6 ("Limited Direct Execution")](http://pages.cs.wisc.edu/~remzi/OSTEP/cpu-mechanisms.pdf)**
- The conceptual model of why kernel privilege exists. Free online. Difficulty: Beginner.

**[Advanced Programming in the UNIX Environment (APUE) — Stevens & Rago, Chapter 8](https://www.amazon.com/Advanced-Programming-UNIX-Environment-3rd/dp/0321637739)**
- Process API from the user side: fork, exec, wait, signals. The "what does the syscall *look like* to user programs" perspective. Difficulty: Intermediate.

---

## Specifications

**[RISC-V Privileged ISA — §3 (Trap mechanism), §4 (Sv32 paging)](https://riscv.org/technical/specifications/)**
- The mechanism `s_trap_entry` and `vm.zig` implement. Difficulty: Reference.

**[The RISC-V Linux ABI (psABI)](https://github.com/riscv-non-isa/riscv-elf-psabi-doc)**
- The argument-passing rules for `_start` and syscalls. Difficulty: Reference.

---

## Comparable code

**[xv6-riscv: `kernel/main.c`](https://github.com/mit-pdos/xv6-riscv/blob/riscv/kernel/main.c)**
- xv6's `kmain` analog. Read side-by-side with `ccc/src/kernel/kmain.zig`. Difficulty: Intermediate.

**[xv6-riscv: `kernel/swtch.S`](https://github.com/mit-pdos/xv6-riscv/blob/riscv/kernel/swtch.S)**
- 14-instruction context switch. Almost line-identical to `ccc`'s. Difficulty: Intermediate.

**[Linux: `arch/riscv/kernel/entry.S`](https://github.com/torvalds/linux/blob/master/arch/riscv/kernel/entry.S)**
- Production-grade trap entry. Lots more bookkeeping than `ccc`'s — perf counters, ftrace, audit, etc. Difficulty: Advanced.

**[OpenSBI: `lib/sbi/sbi_init.c`](https://github.com/riscv-software-src/opensbi)**
- Real M-mode firmware boot. What `boot.S` is, but for production hardware. Difficulty: Advanced.

---

## Lectures

**[MIT 6.S081 Lectures 4–7](https://pdos.csail.mit.edu/6.S081/2024/schedule.html)**
- Page tables, traps, system calls, scheduling. Free videos. Pair with the xv6 book.

**[Stanford CS 140 ("OS Concepts")](https://cs140.stanford.edu/)**
- Pintos-based undergrad OS course. Different code but same concepts.

---

## Articles

**["How a system call works" — various authors](https://www.kernel.org/doc/html/latest/process/adding-syscalls.html)**
- Linux kernel docs on adding a syscall. Even if you don't end up patching Linux, the walk-through illuminates the kernel's view. Difficulty: Intermediate.

**["The Cost of Context Switching"](https://blog.tsunanet.net/2010/11/how-long-does-it-take-to-make-context.html)**
- A classic blog post on real-hardware context-switch costs. `ccc`'s emulator hides these costs, but reading this gives perspective on what production OSes optimize. Difficulty: Intermediate.

---

## Tools

**`zig build run -- --trace kernel.elf | head -200`**
- The cleanest way to see boot in action: every instruction from `0x80000000` to the first user-mode `addi`. The privilege column flips from `[M]` to `[S]` to `[U]` exactly where you'd expect.

**[`scripts/qemu-diff-kernel.sh`](https://github.com/cyyeh/ccc/blob/main/scripts/qemu-diff-kernel.sh)**
- Diffs `ccc`'s `--trace` output for `kernel.elf` against `qemu-system-riscv32`. If a CSR write or trap routing differs from QEMU, this catches it. Requires QEMU.

---

## When you're ready

Next: **[processes-fork-exec-wait](#processes-fork-exec-wait)** — how the kernel manages multiple processes. We've shown one process; now we make N.
