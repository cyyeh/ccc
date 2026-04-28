# console-and-editor: Further Learning Resources

---

## Specifications

**[ANSI X3.64 / ECMA-48 — "Control Functions for Coded Character Sets"](https://www.ecma-international.org/wp-content/uploads/ECMA-48_5th_edition_june_1991.pdf)**
- The original spec for ANSI escape sequences. Free PDF. Most of what's in `web/ansi.js` is a tiny subset of this. Difficulty: Reference.

**[VT100 User Guide (DEC, 1978)](https://vt100.net/docs/vt100-ug/)**
- The terminal that defined "ANSI" for most practical purposes. Reading this gives historical context for why escape sequences look the way they do. Difficulty: Reference.

**[POSIX termios — `man 3 termios`](https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/termios.h.html)**
- The standard API for putting a real terminal into raw mode. `ccc`'s console.zig is a much simpler model; termios is what production Unix uses. Difficulty: Reference.

---

## Books

**[The Linux Programming Interface — Chapter 62 (Terminals)](https://man7.org/tlpi/)**
- Encyclopedic chapter on terminal handling. Way more detail than `ccc` needs, but invaluable for "what does termios actually mean?" Difficulty: Intermediate.

**[Build Your Own Text Editor — Salvatore Sanfilippo / kilo](https://github.com/antirez/kilo)**
- A 1000-line C editor with raw-mode termios + ANSI redraw. The shape is *very* close to `ccc`'s `edit.zig`. Difficulty: Beginner-to-Intermediate.

**[The Unix Programming Environment — Kernighan & Pike](https://www.amazon.com/Unix-Programming-Environment-Prentice-Hall-Software/dp/013937681X)**
- The introduction to terminal programming for Unix users. From 1984 but still spot-on for the mental model. Difficulty: Beginner.

---

## Tutorials & articles

**["Build Your Own Text Editor" — viewsourcecode.org](https://viewsourcecode.org/snaptoken/kilo/)**
- A step-by-step tutorial that walks through Salvatore's `kilo` editor. Each chapter incrementally adds features. Pair with reading `edit.zig`. Difficulty: Beginner.

**["A Brief Intro to Terminal Escape Sequences"](https://en.wikipedia.org/wiki/ANSI_escape_code)**
- Wikipedia's article. Surprisingly comprehensive. Includes color codes (`\x1b[31m` = red) which `ccc` doesn't use but real terminals do. Difficulty: Beginner.

**[Bash's Readline Library Documentation](https://www.gnu.org/software/bash/manual/html_node/Readline-Init-File.html)**
- How real shells implement line editing on top of raw-mode termios. (Bash uses raw mode + does its own line discipline; `ccc`'s shell uses cooked mode + relies on the kernel.) Difficulty: Advanced.

---

## Comparable code

**[xv6-riscv: `kernel/console.c`](https://github.com/mit-pdos/xv6-riscv/blob/riscv/kernel/console.c)**
- The parent of `ccc/src/kernel/console.zig`. Same algorithms; same sleep-on-empty pattern. Difficulty: Intermediate.

**[Salvatore's `kilo` editor](https://github.com/antirez/kilo)**
- Single C file, ~1000 lines. Implements raw mode, ANSI redraw, syntax highlighting, search. Worth reading end-to-end. Difficulty: Intermediate.

**[Linux: `drivers/tty/n_tty.c`](https://github.com/torvalds/linux/blob/master/drivers/tty/n_tty.c)**
- Linux's "n_tty" line discipline. Vastly more complex than `ccc`'s — handles UTF-8, control sequences, signals, locking. The principle is the same. Difficulty: Advanced.

---

## Tools

**[`stty -a`](https://man7.org/linux/man-pages/man1/stty.1.html)**
- Show your terminal's current settings (baud, control chars, modes). `stty raw` and `stty -raw` flip cooked/raw on a real Unix host.

**[`infocmp xterm-256color`](https://man7.org/linux/man-pages/man1/infocmp.1m.html)**
- Dumps the terminfo database entry for your terminal: what every escape sequence is. Educational to see how many escape codes exist.

**[`xxd` / `hexdump -C` on `editor_input.txt`](https://github.com/cyyeh/ccc/blob/main/tests/e2e/editor_input.txt)**
- See the actual 43 bytes the editor test pipes through `--input`. ESC sequences and control bytes interleaved with printables.

---

## When you're ready

Last topic: **[shell-and-userland](#shell-and-userland)** — the shell and utilities that *use* the console + filesystem you've now studied. After that, the three Walkthroughs that tie everything together.
