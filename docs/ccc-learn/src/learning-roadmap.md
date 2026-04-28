# Learning Roadmap

`ccc` is built bottom-up: every layer assumes the one beneath it works. This site follows the same order. If you skip ahead, the pieces won't lock together — Plan 3.E's shell makes no sense without Plan 3.A's PLIC, and Plan 3.A's PLIC makes no sense without Plan 1.C's CSRs.

Spend 1–3 hours per topic if you're new to systems programming. Less if you've worked on a kernel before. The **Walkthroughs** at the end are short but assume every topic — read those last.

---

## Phase 1: Emulator (Plans 1.A → 1.D)

### Layer 1 — The CPU itself

**rv32-cpu-and-decode**

Start here. A CPU is a state machine with 32 registers, a program counter, and a loop that fetches an instruction, decodes it, and executes it. RV32IMA + Zicsr + Zifencei is small enough to read end-to-end in one sitting. Read this before *anything* else.

> *Prereqs:* basic familiarity with C-like languages, hex/binary numbers.

### Layer 2 — Where the bytes live

**memory-and-mmio**

The CPU only knows how to read and write addresses. RAM is one such address range; UART, CLINT, PLIC, and the block device are *also* address ranges that just happen to do something interesting when written to. Sv32 paging is one extra translation step in the middle. Once you grasp that, the kernel's memory map is just bookkeeping.

> *Prereqs:* rv32-cpu-and-decode.

### Layer 3 — Privilege & traps

**csrs-traps-and-privilege**

The CPU needs a way to say "you're not allowed to do that," and a way to ask "may I?" CSRs are the configuration knobs; privilege levels are the trust hierarchy; traps are the only legal way to upgrade privilege. The single hardest topic in this site — but the kernel literally cannot exist without it.

> *Prereqs:* rv32-cpu-and-decode + memory-and-mmio.

### Layer 4 — Plug-in peripherals

**devices-uart-clint-plic-block**

Now we add a serial port (so the CPU can print), a timer (so it can preempt), an interrupt controller (so it can be told "look, the timer fired"), and a disk (so we can persist files). These are the four MMIO devices that anchor the rest of the system.

> *Prereqs:* rv32-cpu-and-decode + memory-and-mmio + csrs-traps-and-privilege.

---

## Phase 2: Bare-metal kernel (Plans 2.A → 2.D)

### Layer 5 — The kernel itself

**kernel-boot-and-syscalls**

Combine layers 1–4: an M-mode boot shim sets up the world, hands off to S-mode, builds a page table, runs a U-mode program, and handles the first ever `ecall`. This topic is the bridge — everything before it is hardware, everything after it runs *on top of* the kernel.

> *Prereqs:* all of Phase 1.

---

## Phase 3: Multi-process OS (Plans 3.A → 3.F)

### Layer 6 — Multiple processes

**processes-fork-exec-wait**

One process is easy. Two is hard. The scheduler picks; `swtch.S` swaps; `fork` photocopies an entire address space; `execve` rebuilds it; `wait` synchronizes; `exit` cleans up. This is the heart of any multitasking OS, and `ccc` implements it in ~600 lines.

> *Prereqs:* kernel-boot-and-syscalls.

### Layer 7 — Persistent storage

**filesystem-internals**

Five layers, bottom-up: bufcache → balloc → inode → dir → path. Each layer is a small abstraction over the one below it. If you've ever wondered "what is an inode, *really*?" — this topic answers it by showing you the 4 MB on-disk image, byte by byte.

> *Prereqs:* processes-fork-exec-wait + devices-uart-clint-plic-block (you need to understand the block device).

### Layer 8 — Talking to humans

**console-and-editor**

The user types things. The OS has to interpret. Cooked-mode line discipline is what turns "h-e-l-l-o-backspace-backspace-y-Enter" into "hey\n" landing in `read()`. Raw mode is the editor's escape hatch. ANSI escapes are how you draw on a 1980s terminal.

> *Prereqs:* devices-uart-clint-plic-block + processes-fork-exec-wait.

### Layer 9 — A real shell

**shell-and-userland**

The capstone. A POSIX-ish shell built on the system you've now read end-to-end. Token-split, redirects, builtins, `fork+exec`, all running through `_start` and the user stdlib. The `init` process loops `fork→exec(sh)→wait` forever.

> *Prereqs:* all of Phase 3.

---

## Walkthroughs (read after all topics)

These three tie everything together by following one concrete user-visible action through the whole stack. They re-cite every topic, but you'll only get the punchline if you've read them.

- **journey-of-an-ecall** — The simplest end-to-end trace: how a single syscall instruction crosses the privilege boundary and gets back home alive.
- **what-happens-when-you-type-cat-motd** — The most-educational single page on this site. Twelve hops, six topics, every kernel subsystem.
- **rv32-in-a-browser-tab** — A different axis: same Zig core, but compiled to wasm and running in your browser tab right now. Shows how clean abstractions make platform portability cheap.

---

## What's *not* here

`ccc` is still planning Phase 4 (network stack: ARP/IP/ICMP/UDP/TCP/DNS) and Phase 5 (HTTP client + text browser). Those phases aren't documented here yet — when they ship, this site will grow.

Phase 1 sub-plan 1.D's QEMU-diff scripts are mentioned but not deep-dived; they're a debugging aid, not a teaching subject.

---

## A quick map back to the codebase

```
ccc/src/emulator/        ← Phase 1 (rv32-cpu, memory, csrs, devices topics)
ccc/src/kernel/          ← Phase 2 + 3 (kernel-boot, processes, filesystem,
                                         console, shell topics)
ccc/src/kernel/userland/ ← what mkfs stages into the disk image
ccc/programs/            ← hand-crafted demos (snake, hello, mul_demo, trap_demo)
ccc/web/ + demo/         ← the wasm browser demo (see rv32-in-a-browser-tab)
ccc/tests/e2e/           ← the proofs that each layer works
```

Whenever a topic mentions a file, that's an absolute path inside the `ccc/` repo — open it side-by-side and read both.
