# From-Scratch Computer — Project Roadmap

This is the index for a multi-phase project to build a working RISC-V
computer from scratch in Zig, capable of booting our own kernel and running
our own programs (including a tiny HTTP/1.0 text browser).

## Top-level decisions

- **Goal shape:** RISC-V emulator + custom OS + custom networking + custom
  text-mode browser. Browse a small set of plain-HTTP pages on a server we
  control. No Linux. No TLS. No graphics.
- **Implementation language:** Zig (specific version pinned in Phase 1
  spec). The developer is new to Zig and will run `ziglings` exercises in
  parallel during Phase 1.
- **CPU architecture:** RISC-V, RV32 family. Exact extension set (I, M, A,
  optional Zicsr/Zifencei) pinned in the Phase 1 spec.
- **Host platform:** macOS. Phase 4 (networking) may switch development to
  a Linux VM if Mac TAP/TUN setup proves too painful.
- **Decomposition rule:** This project is too large for a single spec.
  Each phase gets its own brainstorm → spec → plan → implementation
  cycle. We never write more than one phase's spec at a time.

## Phases

### Phase 0 — Toolchain & Zig warm-up (~2-4 weeks)

Install pinned Zig + RISC-V cross-compile target + QEMU. Build a tiny
RISC-V assembly "hello world" running in QEMU as a sanity check on the
toolchain. Run `ziglings` exercises in parallel to build Zig fluency.

**Demo:** `zig build` produces a RISC-V binary; sample asm hello world
runs in QEMU.

### Phase 1 — RISC-V CPU emulator (~2-4 months)

Write the emulator in Zig. Implement the chosen RV32 extension set plus
minimal devices (UART for console, a timer). Pass the official RISC-V
test suite (riscv-tests). Run a cross-compiled bare-metal hello world.

**Demo:** `our-emulator hello.bin` prints "hello world".

### Phase 2 — Bare-metal kernel (~2-3 months)

Boot a kernel inside the emulator. Trap/exception handlers, page tables
(Sv32), M↔S↔U privilege transitions. One user program runs and makes
syscalls.

**Demo:** a user-mode program calls `write()` and the kernel prints it.

### Phase 3 — Multi-process OS + filesystem + shell (~3-4 months)

Process scheduler, fork/exec, block device driver, simple filesystem,
custom shell, basic utilities (`ls`, `cat`, `echo`, a tiny editor),
perhaps a Snake game.

**Demo:** boot to a shell prompt, run our own programs, edit files.

### Phase 4 — Network stack (~3-6 months — the hard one)

Network device driver, then layer-by-layer up the stack: Ethernet → ARP
→ IP → ICMP → UDP → TCP → DNS.

**Demo:** `ping 1.1.1.1` works from inside our OS; a TCP echo client
works.

### Phase 5 — HTTP/1.0 client + minimal text browser (~1-3 months)

HTTP/1.0 client (no TLS), URL parsing, tiny HTML parser (paragraphs,
headings, links), terminal renderer, link navigation by typing numbers.

**Demo:** `browse http://test-server/` shows a page; clicking links by
typing numbers loads the next page.

## Total scope

~12-20 months of focused part-time work, plus the Zig learning curve.

## Status

Currently brainstorming **Phase 1**. Each phase's spec lands in this
directory as `YYYY-MM-DD-phase<N>-<topic>-design.md` once brainstormed
and approved.
