# ccc — Claude Code Computer

Building a working RISC-V computer from scratch in Zig — emulator, kernel,
OS, networking, and a tiny text-mode web browser. No Linux. No TLS. No
graphics.

## Goal

Go from an empty repo to `browse http://test-server/` rendering a page in
our own terminal browser, with every layer written ourselves:

1. A RISC-V CPU emulator
2. A bare-metal kernel with traps, page tables, and privilege transitions
3. A multi-process OS with a filesystem and shell
4. A from-scratch network stack (Ethernet → ARP → IP → ICMP → UDP → TCP → DNS)
5. An HTTP/1.0 client and a terminal HTML renderer

## Phases

| # | Phase | Rough effort | Demo |
|---|-------|--------------|------|
| 0 | Toolchain & Zig warm-up | 2–4 weeks | asm hello world runs in QEMU |
| 1 | RISC-V CPU emulator | 2–4 months | `ccc hello.elf` prints `hello world` |
| 2 | Bare-metal kernel | 2–3 months | user program calls `write()`, kernel prints it |
| 3 | Multi-process OS + FS + shell | 3–4 months | boot to a shell, run our own programs |
| 4 | Network stack | 3–6 months | `ping 1.1.1.1` from inside our OS |
| 5 | HTTP/1.0 client + text browser | 1–3 months | browse plain-HTTP pages by link number |

Total scope: roughly 12–20 months of focused part-time work.

## Design choices

- **Language:** Zig (version pinned per-phase).
- **ISA:** RV32I + M + A + Zicsr + Zifencei. Single hart. No F/D, no C.
- **Privilege (Phase 1):** M-mode + U-mode only; S-mode and Sv32 land in Phase 2.
- **Devices (Phase 1):** NS16550A UART + CLINT timer. 128 MB RAM at `0x80000000`.
- **Host platform:** macOS. Phase 4 may move to a Linux VM for TAP/TUN.
- **Decomposition rule:** one phase's spec at a time — brainstorm → spec →
  plan → implementation, then repeat.

## Status

Currently on **Phase 1 — RISC-V CPU emulator**. Design is approved;
implementation plan 1.A (minimum viable emulator) is drafted.

## Layout

```
docs/
  superpowers/
    specs/        # design docs per phase (brainstormed + approved)
    plans/        # implementation plans per phase
  references/     # notes on RISC-V specifics (traps, etc.)
```

The roadmap lives at
[`docs/superpowers/specs/2026-04-23-from-scratch-computer-roadmap.md`](docs/superpowers/specs/2026-04-23-from-scratch-computer-roadmap.md).

## License

[MIT](LICENSE)
