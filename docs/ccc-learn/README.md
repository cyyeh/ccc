# ccc-learn

> ⚠️ This learning platform is an AI-generated companion for the [ccc](https://github.com/cyyeh/ccc) codebase. It explains *what shipped* in Phases 1–3 of `ccc` — RISC-V emulator, bare-metal kernel, multi-process OS with filesystem and shell — through structured analyses, beginner guides, interactive demos, code-cases, quizzes, and curated reading lists. Cross-check claims against the source code before quoting them.

A from-scratch RV32 computer in Zig, taught one layer at a time.

The codebase goes from an empty repo to a working text-mode browser; this site goes from "what is a CPU register?" to "trace a single `ecall` through the whole stack." Topics are stacked bottom-up — each one strictly depends on the ones before it. The three **Walkthroughs** at the end stitch multiple topics together by following one concrete user-visible action through the entire system.

## Topics

### rv32-cpu-and-decode

- [rv32-cpu-and-decode - In-Depth Analysis](src/rv32-cpu-and-decode/rv32-cpu-and-decode_analysis.md) — Hart state, RV32IMA + Zicsr + Zifencei decoding, the execute dispatch, LR/SC reservation, and how `ccc`'s decoder/executor split up the work.
- [rv32-cpu-and-decode - Beginner Guide](src/rv32-cpu-and-decode/rv32-cpu-and-decode_guide.md) — Plain-language tour of "what is a CPU?" using kitchen analogies — registers, instructions, fetch/decode/execute, why RISC-V is "reduced."
- [rv32-cpu-and-decode - Interactive](src/rv32-cpu-and-decode/rv32-cpu-and-decode_interactive.html) — Encode RV32 instructions field-by-field, watch the decoder split them, step-execute a tiny program with live register state.
- [rv32-cpu-and-decode - Code Cases](src/rv32-cpu-and-decode/rv32-cpu-and-decode_cases.md) — Real artifacts from the codebase: the `hello.elf` instruction trace, the `mul_demo` walk, the LR/SC reservation race, the rv32mi conformance suite.
- [rv32-cpu-and-decode - Practice Quiz](src/rv32-cpu-and-decode/rv32-cpu-and-decode_quiz.md) — Mixed questions on RV32 encoding, the decoder dispatch, register conventions, atomics, and `ccc`-specific implementation choices.
- [rv32-cpu-and-decode - Further Reading](src/rv32-cpu-and-decode/rv32-cpu-and-decode_resources.md) — RISC-V manuals, books on emulator construction, comparable open-source RV32 emulators, and recommended Zig reading.

### memory-and-mmio

- [memory-and-mmio - In-Depth Analysis](src/memory-and-mmio/memory-and-mmio_analysis.md) — Physical RAM at `0x80000000`, the MMIO dispatcher (UART/CLINT/PLIC/block/halt), Sv32 page tables and `translateForLoad/Store/Fetch`.
- [memory-and-mmio - Beginner Guide](src/memory-and-mmio/memory-and-mmio_guide.md) — Why "memory-mapped I/O" is just hooks on certain addresses, what a page table is in everyday terms, and how `ccc` decides where each load/store goes.
- [memory-and-mmio - Interactive](src/memory-and-mmio/memory-and-mmio_interactive.html) — A virtual-to-physical address translator: type a virtual address + a `satp`, watch the L1 → L0 PTE walk; an MMIO region inspector; an Sv32 PTE flag-bit decoder.
- [memory-and-mmio - Code Cases](src/memory-and-mmio/memory-and-mmio_cases.md) — How a UART write becomes a function call, why PLIC needs 4 MB of address space for almost no state, the kernel's first identity map, page-fault stories.
- [memory-and-mmio - Practice Quiz](src/memory-and-mmio/memory-and-mmio_quiz.md) — MMIO dispatch, Sv32 layout, PTE flag semantics, the difference between R/W/X bits and U-bit, dirty-bit handling.
- [memory-and-mmio - Further Reading](src/memory-and-mmio/memory-and-mmio_resources.md) — RISC-V Privileged spec on Sv32, OSTEP paging chapter, xv6's `vm.c`, and notes on QEMU's softmmu.

### csrs-traps-and-privilege

- [csrs-traps-and-privilege - In-Depth Analysis](src/csrs-traps-and-privilege/csrs-traps-and-privilege_analysis.md) — M/S/U privilege, the CSR machine room (mstatus/mtvec/medeleg/mideleg/mip/mie/sip/sie/sepc/scause), sync vs async traps, mret/sret, the M→S→U handoff.
- [csrs-traps-and-privilege - Beginner Guide](src/csrs-traps-and-privilege/csrs-traps-and-privilege_guide.md) — "Why does a CPU need different modes?" Privilege as a trust hierarchy, traps as the only legal way to ask permission, delegation as a shortcut.
- [csrs-traps-and-privilege - Interactive](src/csrs-traps-and-privilege/csrs-traps-and-privilege_interactive.html) — Trap-routing visualizer: pick a trap cause + delegation mask + current mode, watch where it lands; CSR field decoder; mret/sret state-machine.
- [csrs-traps-and-privilege - Code Cases](src/csrs-traps-and-privilege/csrs-traps-and-privilege_cases.md) — The `trap_demo` round-trip, the boot shim's delegation setup, the SIE-window bug fixed in Plan 3.E, why `wfi` had to advance `sepc`.
- [csrs-traps-and-privilege - Practice Quiz](src/csrs-traps-and-privilege/csrs-traps-and-privilege_quiz.md) — When does an mret pop privilege? What does `medeleg[ECALL_S]` set imply? Difference between `mip.MTIP` and `mip.SSIP`?
- [csrs-traps-and-privilege - Further Reading](src/csrs-traps-and-privilege/csrs-traps-and-privilege_resources.md) — Privileged ISA spec, "RISC-V Reader" trap chapter, `notes/traps.md` in the codebase, comparable docs from xv6-riscv.

### devices-uart-clint-plic-block

- [devices-uart-clint-plic-block - In-Depth Analysis](src/devices-uart-clint-plic-block/devices-uart-clint-plic-block_analysis.md) — NS16550A UART (TX + 256B RX FIFO), CLINT (msip + mtimecmp + mtime), PLIC (32 sources, S-context, claim/complete), the simple block device, and how MMIO addresses dispatch.
- [devices-uart-clint-plic-block - Beginner Guide](src/devices-uart-clint-plic-block/devices-uart-clint-plic-block_guide.md) — "What's a peripheral?" UART as a slow pipe, timer as a metronome, IRQ controller as a switchboard, block device as a tiny disk.
- [devices-uart-clint-plic-block - Interactive](src/devices-uart-clint-plic-block/devices-uart-clint-plic-block_interactive.html) — Feed bytes into a simulated UART RX FIFO and watch PLIC claim/complete; explore CLINT's `mtimecmp` triggering MTIP; play with the block device CMD register.
- [devices-uart-clint-plic-block - Code Cases](src/devices-uart-clint-plic-block/devices-uart-clint-plic-block_cases.md) — Tracing one keystroke from the host stdin into the FIFO; how `--input` paces bytes one-per-iteration; the `plic_block_test` integration ELF; `e2e-snake` timer interrupts.
- [devices-uart-clint-plic-block - Practice Quiz](src/devices-uart-clint-plic-block/devices-uart-clint-plic-block_quiz.md) — UART register semantics, level vs edge triggering, claim/complete protocol, why the block device's CMD register is "submit on write."
- [devices-uart-clint-plic-block - Further Reading](src/devices-uart-clint-plic-block/devices-uart-clint-plic-block_resources.md) — NS16550A datasheet, RISC-V PLIC + CLINT specs, virtio-blk for contrast, OSDev wiki.

### kernel-boot-and-syscalls

- [kernel-boot-and-syscalls - In-Depth Analysis](src/kernel-boot-and-syscalls/kernel-boot-and-syscalls_analysis.md) — `boot.S` (M-mode), the M→S handoff, `kmain`, page-table bootstrap, `s_trap_entry` trampoline, the syscall ABI (`a7` = number, `a0..a5` = args), `swtch.S` context switch, the SIE window.
- [kernel-boot-and-syscalls - Beginner Guide](src/kernel-boot-and-syscalls/kernel-boot-and-syscalls_guide.md) — Boot in plain English: "first instruction at reset," handing the keys from M to S, what a syscall actually *is*, why context-switching feels like teleporting.
- [kernel-boot-and-syscalls - Interactive](src/kernel-boot-and-syscalls/kernel-boot-and-syscalls_interactive.html) — Interactive boot timeline (M → S → U with annotated CSR writes); a syscall dispatch flowchart with hover-to-see-handler; a register-save layout for `swtch.S`.
- [kernel-boot-and-syscalls - Code Cases](src/kernel-boot-and-syscalls/kernel-boot-and-syscalls_cases.md) — The first-ever U-mode `write` in `kernel.elf`; how `e2e-kernel` proves the round-trip; the `s_kernel_trap_entry` SIE-window arm; the trampoline page mapping trick.
- [kernel-boot-and-syscalls - Practice Quiz](src/kernel-boot-and-syscalls/kernel-boot-and-syscalls_quiz.md) — Why does the boot shim run in M-mode? What's in a `Context`? How does `swtch.S` know where to return?
- [kernel-boot-and-syscalls - Further Reading](src/kernel-boot-and-syscalls/kernel-boot-and-syscalls_resources.md) — xv6-riscv chapter on traps, OSTEP "Limited Direct Execution," RISC-V Privileged spec, Linux's `entry.S`.

### processes-fork-exec-wait

- [processes-fork-exec-wait - In-Depth Analysis](src/processes-fork-exec-wait/processes-fork-exec-wait_analysis.md) — `Process` struct, the static `ptable[NPROC=16]`, the round-robin scheduler, `fork` (copyUvm), `execve` (rebuild + System-V argv), `wait4`, `exit`, the kill-flag, sleep/wakeup channels.
- [processes-fork-exec-wait - Beginner Guide](src/processes-fork-exec-wait/processes-fork-exec-wait_guide.md) — Process as a "cassette tape"; fork as photocopying; exec as swapping the contents in place; the parent/child split in two-line C.
- [processes-fork-exec-wait - Interactive](src/processes-fork-exec-wait/processes-fork-exec-wait_interactive.html) — Process state-machine simulator (Unused/Embryo/Sleeping/Runnable/Running/Zombie); a fork/exec/wait timeline with two PIDs; a kill-flag walkthrough.
- [processes-fork-exec-wait - Code Cases](src/processes-fork-exec-wait/processes-fork-exec-wait_cases.md) — `init` reaping `/bin/hello`; `^C` killing `cat`; the OOM-rollback path in `copyUvm`; the System-V argv layout `execve` builds.
- [processes-fork-exec-wait - Practice Quiz](src/processes-fork-exec-wait/processes-fork-exec-wait_quiz.md) — What's the diff between `fork` and `clone`? Where's the kill-flag checked? What happens to children when their parent exits?
- [processes-fork-exec-wait - Further Reading](src/processes-fork-exec-wait/processes-fork-exec-wait_resources.md) — APUE process chapters, OSTEP "Process API" + "Scheduling," xv6's `proc.c`, Linux's `do_fork`.

### filesystem-internals

- [filesystem-internals - In-Depth Analysis](src/filesystem-internals/filesystem-internals_analysis.md) — On-disk layout (boot + super + bitmap + inode table + data); the bufcache LRU; balloc; inode + `bmap` (direct + indirect, lazy alloc on `for_write`); dirent; `namei`/`nameiparent`; the `mkfs` host tool.
- [filesystem-internals - Beginner Guide](src/filesystem-internals/filesystem-internals_guide.md) — Filesystem as a library catalog; inodes as index cards; the bitmap as a "this seat is taken" board; namei as walking down hallways.
- [filesystem-internals - Interactive](src/filesystem-internals/filesystem-internals_interactive.html) — On-disk layout visualizer (4 MB image broken down block by block); a `namei` path-walker; an inode `bmap` calculator with direct + indirect math.
- [filesystem-internals - Code Cases](src/filesystem-internals/filesystem-internals_cases.md) — `e2e-persist` proving writes survive emulator restart; `itrunc` on `nlink == 0`; the lazy-alloc story for `bmap`; how `mkfs` lays out an empty `/tmp/`.
- [filesystem-internals - Practice Quiz](src/filesystem-internals/filesystem-internals_quiz.md) — How many bytes does one direct block address? What's the max file size? When does `iput` call `itrunc`? Why does `bget` sleep?
- [filesystem-internals - Further Reading](src/filesystem-internals/filesystem-internals_resources.md) — OSTEP file-system chapters, xv6's `fs.c` (the parent of `ccc`'s FS), "Filesystem Hierarchy Standard," and notes on V6 Unix.

### console-and-editor

- [console-and-editor - In-Depth Analysis](src/console-and-editor/console-and-editor_analysis.md) — Cooked-mode line discipline (echo, backspace, `^C`/`^U`/`^D`, `\n` commit), Raw mode for the editor, UART RX → PLIC → `console.feedByte` flow, ANSI escape subset, `edit.zig`'s 16 KB buffer + redraw loop.
- [console-and-editor - Beginner Guide](src/console-and-editor/console-and-editor_guide.md) — "Why doesn't pressing 'a' just send 'a'?" Cooked vs raw mode in plain terms; what `^C` actually does; how an ANSI cursor move works.
- [console-and-editor - Interactive](src/console-and-editor/console-and-editor_interactive.html) — ANSI escape sandbox (type a sequence, see the cursor move on a fake terminal); cooked vs raw simulator (compare keystrokes); editor key-map cheatsheet.
- [console-and-editor - Code Cases](src/console-and-editor/console-and-editor_cases.md) — `e2e-cancel` proving the `^C` chain; `e2e-editor` showing `heYllo`; how `--input` interleaves with cooked echo; the `wfi`/SIE-window bug story.
- [console-and-editor - Practice Quiz](src/console-and-editor/console-and-editor_quiz.md) — When does cooked mode echo? What does `^U` do? How does the editor land the cursor at byte offset N? Why is `\x1b[2J\x1b[H` "clear and home"?
- [console-and-editor - Further Reading](src/console-and-editor/console-and-editor_resources.md) — Termios docs, ANSI/VT100 escape references, `notes/console.md`, books on terminal-emulator internals.

### shell-and-userland

- [shell-and-userland - In-Depth Analysis](src/shell-and-userland/shell-and-userland_analysis.md) — `sh.zig` (line read, token split, redirect `< > >>`, builtins `cd`/`pwd`/`exit`), the fork+exec pattern, the user stdlib (`_start`, `usys.S`, `printf`, O_* constants), all the utilities (`ls`/`cat`/`echo`/`mkdir`/`rm`).
- [shell-and-userland - Beginner Guide](src/shell-and-userland/shell-and-userland_guide.md) — A shell is "a forever-loop that asks for a line, splits it into words, and runs the first word as a program." Plain explanations of redirects, builtins, exit codes.
- [shell-and-userland - Interactive](src/shell-and-userland/shell-and-userland_interactive.html) — Shell pipeline visualizer: type a command, see token splits, fd dup table, fork tree; a redirect explainer; an `_start` register-by-register stack-tail dissector.
- [shell-and-userland - Code Cases](src/shell-and-userland/shell-and-userland_cases.md) — `echo hi > /tmp/x` end-to-end; the `init_shell` fork-exec-sh-wait loop; `ls` calling `Stat` on every entry; `rm`'s `unlinkat` flow.
- [shell-and-userland - Practice Quiz](src/shell-and-userland/shell-and-userland_quiz.md) — Why is `cd` a builtin? What does `init_shell` do when `sh` exits non-zero? How does redirect `>` change the child's fd 1?
- [shell-and-userland - Further Reading](src/shell-and-userland/shell-and-userland_resources.md) — APUE shell + signals chapters, "Build Your Own Shell," xv6's `sh.c`, the System-V argv ABI doc.

## Walkthroughs

### journey-of-an-ecall

- [journey-of-an-ecall](src/cross-topic/journey-of-an-ecall.md) — Pick one syscall and trace it end-to-end: userland `_start` → `usys.S` → `ecall` → trampoline → `s_trap_entry` → `s_kernel_trap_dispatch` → `syscall.zig` → handler → return path. With annotated stack frames at each step.

### what-happens-when-you-type-cat-motd

- [what-happens-when-you-type-cat-motd](src/cross-topic/what-happens-when-you-type-cat-motd.md) — Single command, full stack: keystroke through `--input` → UART RX FIFO → PLIC → cooked-mode echo → shell tokenize → fork → execve → namei → readi → write to fd 1 → UART TX → host stdout.

### rv32-in-a-browser-tab

- [rv32-in-a-browser-tab](src/cross-topic/rv32-in-a-browser-tab.md) — How the same Zig core ships as both a CLI and a browser demo: `wasm32-freestanding`, comptime CLINT clock branch, Web Worker chunked execution, ANSI rendering in JS, ELFs fetched at runtime not embedded.
