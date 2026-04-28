# shell-and-userland: Further Learning Resources

---

## Books

**[Advanced Programming in the UNIX Environment (APUE) — Stevens & Rago, Chapter 8, 9, 13](https://www.amazon.com/Advanced-Programming-UNIX-Environment-3rd/dp/0321637739)**
- Process control, signals, daemon processes. The shell + init pattern is described in detail. Difficulty: Intermediate.

**[The Art of UNIX Programming — Eric S. Raymond](http://www.catb.org/~esr/writings/taoup/)**
- Free online. Chapter 7 on multiprocessing, chapter 11 on interfaces. The "Unix philosophy" framing of why fork+exec exists. Difficulty: Beginner.

**[Build Your Own Shell — many tutorials](https://brennan.io/2015/01/16/write-a-shell-in-c/)**
- One of many "build a shell" walkthroughs. C-based, ~300 lines. Direct comparison with `ccc`'s sh.zig possible. Difficulty: Beginner.

**[The Unix Programming Environment — Kernighan & Pike](https://www.amazon.com/Unix-Programming-Environment-Prentice-Hall-Software/dp/013937681X)**
- Chapter 5 introduces shell programming and 1970s shell internals. Difficulty: Beginner.

---

## Specifications

**[POSIX 2001 — Shell & Utilities](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html)**
- The standardized sh grammar and behavior. `ccc`'s sh is a small subset. Difficulty: Reference.

**[The RISC-V Linux psABI — System V ABI Initial Process Stack](https://github.com/riscv-non-isa/riscv-elf-psabi-doc)**
- The argv tail layout that `proc.exec` builds. Difficulty: Reference.

---

## Comparable code

**[xv6-riscv: `user/sh.c`](https://github.com/mit-pdos/xv6-riscv/blob/riscv/user/sh.c)**
- The parent of `ccc`'s shell. ~270 lines. Has more features (pipes!) than `ccc`'s. Difficulty: Intermediate.

**[xv6-riscv: `user/init.c`](https://github.com/mit-pdos/xv6-riscv/blob/riscv/user/init.c)**
- The parent of `init_shell.zig`. Direct comparison shows the loop pattern. Difficulty: Beginner.

**[Stephen Brennan's `lsh` — a 200-line shell in C](https://github.com/brenns10/lsh)**
- Educational. Shorter than xv6's. Tutorial blog post linked. Difficulty: Beginner.

**[bash — `bash` itself](https://git.savannah.gnu.org/cgit/bash.git/tree/)**
- The real thing. ~100k lines. Read once for perspective on what a "real" shell looks like. Difficulty: Advanced.

**[Plan 9's `rc`](https://9p.io/plan9/rc/index.html)**
- A shell with very different design from sh/bash. Worth reading for "what could a shell be?" Difficulty: Intermediate.

---

## Tutorials & articles

**[Tutorial - Write a Shell in C](https://brennan.io/2015/01/16/write-a-shell-in-c/)**
- Step by step, ~30 minutes to read. Shape matches `ccc`'s sh.zig. Difficulty: Beginner.

**[The Architecture of Open Source Applications — Bash](https://www.aosabook.org/en/bash.html)**
- Free online. The internal architecture of bash. Read after the simple shell tutorials. Difficulty: Advanced.

**["What's the difference between a builtin and an external command?" (various StackOverflow)](https://unix.stackexchange.com/questions/tagged/builtin)**
- Worth understanding because the why is more interesting than the what.

---

## Tools

**`zig build run -- --disk shell-fs.img kernel-fs.elf`**
- Drop into the actual `ccc` shell. Type `ls /bin`, `cat /etc/motd`, `echo foo > /tmp/bar`, etc. Most fun way to interact with the codebase.

**[`bash --noprofile --norc -c '...'`](https://www.gnu.org/software/bash/manual/html_node/Command-Line-Options.html)**
- Run bash with no init scripts to see the bare minimum behavior. Compare to `ccc`'s sh.

**`strace -f bash -c 'ls > /tmp/x'`**
- Watch a real bash do the same redirect. Compare the syscalls to what `ccc`'s sh would emit.

---

## Advanced topics not in `ccc`

The following are real-shell features `ccc` skips. Reading about each can illuminate what you'd add next:

- **Pipes** (`|`): the `pipe(2)` syscall + dup2 between two children.
- **Globbing** (`*.txt`): expand patterns before exec.
- **Variables and quoting**: `$HOME`, `"$x"` vs `'$x'`.
- **Command substitution**: `$(cmd)` runs cmd, splices output.
- **Job control**: `Ctrl+Z`, `bg`, `fg`, foreground/background process groups.
- **Signals**: `SIGTERM`, `SIGINT`, `trap` builtin.

Each of these would add 100-1000 lines to a teaching shell. None are needed for `ccc`'s Phase 3 demo.

---

## When you're ready

You've finished the topics. Now read the **Walkthroughs** — they tie everything together by following one user-visible action through the entire stack:

- **[journey-of-an-ecall](#journey-of-an-ecall)**: the simplest end-to-end syscall trace.
- **[what-happens-when-you-type-cat-motd](#what-happens-when-you-type-cat-motd)**: the most-educational single page on this site.
- **[rv32-in-a-browser-tab](#rv32-in-a-browser-tab)**: how the same Zig core ships to CLI and browser.
