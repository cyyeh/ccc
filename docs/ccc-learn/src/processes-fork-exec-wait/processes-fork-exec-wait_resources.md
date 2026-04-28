# processes-fork-exec-wait: Further Learning Resources

---

## Books

**[Advanced Programming in the UNIX Environment (APUE) — W. Richard Stevens & Stephen A. Rago](https://www.amazon.com/Advanced-Programming-UNIX-Environment-3rd/dp/0321637739)**
- Chapters 8 (Process Control) and 10 (Signals) are the canonical fork/exec/wait reference. Difficulty: Intermediate.

**[Operating Systems: Three Easy Pieces — §5 ("Process API")](http://pages.cs.wisc.edu/~remzi/OSTEP/cpu-api.pdf)**
- Free online. The "Why does Unix do fork() this weird way?" answer in plain English. Difficulty: Beginner.

**[xv6 book — Chapter 7 (Scheduling) and Chapter 4.6 (Code: System call arguments)](https://pdos.csail.mit.edu/6.S081/2024/xv6/book-riscv-rev3.pdf)**
- The closest companion to `ccc`'s scheduler. The `swtch` semantics map perfectly. Difficulty: Beginner-to-Intermediate.

**[The Linux Programming Interface — Michael Kerrisk](https://man7.org/tlpi/)**
- The encyclopedic reference for Linux process management. Vastly more depth than POSIX needs, but invaluable when the spec gets vague. Difficulty: Advanced.

---

## Specifications

**[POSIX 2001 — Process Management](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V1_chap02.html)**
- The standardized fork/exec/wait/exit semantics. `ccc` follows POSIX where possible. Difficulty: Reference.

**[The RISC-V psABI — Initial Process Stack](https://github.com/riscv-non-isa/riscv-elf-psabi-doc)**
- The argv tail layout that `proc.exec` builds. Difficulty: Reference.

---

## Comparable code

**[xv6-riscv: `kernel/proc.c`](https://github.com/mit-pdos/xv6-riscv/blob/riscv/kernel/proc.c)**
- The parent of `ccc`'s `proc.zig`. Read line-for-line; the algorithms are identical. Difficulty: Intermediate.

**[Linux: `kernel/fork.c`](https://github.com/torvalds/linux/blob/master/kernel/fork.c)**
- Production-grade fork. `do_fork`, `clone`, the `task_struct` lifecycle. ~3000 lines of much harder than xv6. Difficulty: Advanced.

**[FreeBSD: `sys/kern/kern_fork.c`](https://github.com/freebsd/freebsd-src/blob/main/sys/kern/kern_fork.c)**
- Different lineage from Linux; cleaner in places, messier in others. Worth comparing. Difficulty: Advanced.

---

## Lectures

**[MIT 6.S081 Lecture 8 (page faults), 9 (multiprocessors and locking)](https://pdos.csail.mit.edu/6.S081/2024/schedule.html)**
- Free videos. Pair with the xv6 book chapters.

**[Stanford CS 140 — Pintos](https://web.stanford.edu/class/cs140/projects/pintos/pintos.html)**
- The course's projects include implementing fork-equivalent (Pintos uses x86, but the kernel concepts are identical).

---

## Articles

**["Implementing Fork in xv6 — A Walkthrough"](https://blog.cs.umich.edu/operating-systems-fork/)**
- Various walkthroughs exist; search for ones that pair commentary with line-by-line xv6 code. Difficulty: Intermediate.

**["The Cost of fork()" — Bryan Cantrill](https://www.brendangregg.com/blog/2016-09-26/linux-fork-pain.html)**
- Why fork+exec is sometimes considered a performance liability and what alternatives exist (vfork, posix_spawn, clone+execve directly). Difficulty: Intermediate.

**["A Brief Introduction to Real-Time Signals"](https://lwn.net/Articles/85257/)**
- The `^C` mechanism in `ccc` is *not* real signals; this LWN article explains what real signals are and why `ccc` (and most teaching kernels) skip them. Difficulty: Advanced.

---

## Tools

**`ps -ef` and `pstree`**
- On any Unix host. See zombies, parents, children, the actual process tree. Compare to `ccc`'s `ptable` mental model.

**[`strace -f -e fork,execve,wait4 ./script.sh`](https://man7.org/linux/man-pages/man1/strace.1.html)**
- Watch a real shell's process management. The pattern is exactly what `sh.zig` does in `ccc`.

**`zig build run -- --trace --halt-on-trap kernel-fork.elf 2>&1 | grep -E '(ecall|fork|exec)'`**
- See every syscall the kernel-fork demo makes. Useful for understanding the syscall density of even tiny user programs.

---

## When you're ready

Next: **[filesystem-internals](#filesystem-internals)** — the on-disk filesystem the shell reads from. Once you have processes that can `exec`, you need to give them somewhere to find programs. That's the FS.
