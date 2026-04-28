# memory-and-mmio: Further Learning Resources

A short list of the specs and books that explain memory + MMIO + paging beyond what `ccc` ships.

---

## Specifications (primary sources)

**[RISC-V Privileged Architecture Manual — §4 (Supervisor-Level ISA)](https://riscv.org/technical/specifications/)**
- Section 4.3 covers Sv32. The exact sequence `Memory.translate` follows is straight from this chapter. Keep a copy open while reading `memory.zig`. Difficulty: Reference.

**[Volume I: User-Level ISA — §2.6 (Memory Model)](https://riscv.org/technical/specifications/)**
- The relaxed memory model and the role of `fence`. For Phase 4 (network stack), this matters more than for the single-hart Phase 1–3. Difficulty: Reference.

**[NS16550A UART datasheet](http://byterunner.com/16550.html)**
- The MMIO register layout that `ccc/src/emulator/devices/uart.zig` follows. The "1979 vintage" register set still ships in modern QEMU, real hardware, and now `ccc`. Difficulty: Reference.

---

## Books

**[Operating Systems: Three Easy Pieces — Remzi & Andrea Arpaci-Dusseau](http://pages.cs.wisc.edu/~remzi/OSTEP/)**
- Free, online, undergrad-level. Chapters 13–24 ("The Abstraction: Address Spaces" through "Beyond Physical Memory") are the gold standard plain-English explanation of paging, page tables, TLB, and faults. If `memory.zig`'s `translate` is opaque, read OSTEP first. Difficulty: Beginner.

**[Computer Organization and Design RISC-V Edition — Patterson & Hennessy](https://www.elsevier.com/books/computer-organization-and-design-risc-v-edition/patterson/978-0-12-820331-6)**
- §5.7 covers virtual memory in the RV context. Pairs well with reading the privileged spec. Difficulty: Beginner-to-Intermediate.

**[The Linux Memory Manager — Mel Gorman](https://www.kernel.org/doc/gorman/)**
- A free book that's old (Linux 2.4) but still the cleanest end-to-end picture of how a real production OS treats virtual memory. Skip the SMP-specific bits. Difficulty: Advanced.

---

## Comparable code — read alongside `memory.zig`

**[xv6-riscv: `kernel/vm.c`](https://github.com/mit-pdos/xv6-riscv/blob/riscv/kernel/vm.c)**
- The kernel-side analog of `ccc/src/kernel/vm.zig`. The `walk()` function is what `Memory.translate` does, only on the *creating* side. xv6 also documents Sv39 (RV64); `ccc` is Sv32. Difficulty: Intermediate.

**[QEMU's `target/riscv/cpu_helper.c`](https://github.com/qemu/qemu/blob/master/target/riscv/cpu_helper.c)**
- Production-grade Sv32/Sv39/Sv48 walker. Read `riscv_cpu_tlb_fill` and trace down. The TLB integration is what `ccc` skipped. Difficulty: Advanced.

**[Spike: `riscv/mmu.cc`](https://github.com/riscv-software-src/riscv-isa-sim/blob/master/riscv/mmu.cc)**
- The reference implementation. If `ccc` ever differs from spec on a Sv32 corner, Spike is the arbiter. Difficulty: Advanced.

---

## Online courses

**[MIT 6.S081 Lectures 4–5 (paging + page tables)](https://pdos.csail.mit.edu/6.S081/2024/schedule.html)**
- The xv6-RISC-V course's paging lectures. ~90 minutes of video each, with assigned reading from the xv6 book. Free. Difficulty: Intermediate.

**[Carnegie Mellon's 15-410 Operating Systems](https://www.cs.cmu.edu/~410/)**
- The "Pebbles" project from this course is a kernel built from scratch on x86, with a paging milestone. Different ISA, but the *concepts* (and the debugging horror stories) translate. Difficulty: Advanced.

---

## Articles & deep dives

**["Anatomy of a Program in Memory" — Gustavo Duarte](https://manybutfinite.com/post/anatomy-of-a-program-in-memory/)**
- A one-page diagram-heavy walkthrough of how a Linux x86 process's virtual memory is laid out. The shapes are the same on RISC-V. Difficulty: Beginner.

**["What every programmer should know about memory" — Ulrich Drepper](https://www.akkadia.org/drepper/cpumemory.pdf)**
- A 100-page paper. Goes far beyond `ccc`'s scope — caches, NUMA, prefetching — but §4 ("Virtual Memory") is the canonical short paging tutorial. Difficulty: Intermediate.

**["The TLB and the cost of paging"](https://lwn.net/Articles/156878/)**
- LWN article on what the TLB does and what missing one costs. `ccc` has no TLB. Reading this gives you a sense of what production emulators (QEMU) and hardware have to optimize. Difficulty: Intermediate.

---

## Tools

**[`hexdump -C`](https://man.openbsd.org/hexdump.1) and `xxd`**
- For inspecting `fs.img` or `shell-fs.img` to see exactly what `mkfs` laid out. Indispensable for debugging FS layout (next topic). Difficulty: Beginner.

**[Compiler Explorer (godbolt.org)](https://godbolt.org/)**
- Type a C function with a struct dereference, see the RISC-V load/store sequence. Useful for understanding why RV needs `lui` + `addi` to build addresses. Difficulty: Beginner.

---

## When you're ready

After memory + MMIO + paging clicks, the natural next step is **[csrs-traps-and-privilege](#csrs-traps-and-privilege)**. The PTE walks above all return *errors* — `LoadPageFault`, `StorePageFault`, `InstPageFault`. Where do those errors *go*? Into traps. The next topic is the trap machinery that catches them.
