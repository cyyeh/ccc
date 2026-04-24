# Phase 3 — Multi-Process OS + Filesystem + Shell (Design)

**Project:** From-Scratch Computer (directory `ccc/`).
**Phase:** 3 of 6 — see `2026-04-23-from-scratch-computer-roadmap.md`.
**Status:** Approved design, ready for implementation planning.

## Goal

Boot a multi-process, Unix-shaped kernel inside our Phase 2 emulator
(extended with a PLIC, UART RX, and a simple block device). The kernel
runs `/bin/sh` from a real on-disk filesystem. The shell forks/execs the
standard utilities (`ls`, `cat`, `echo`, `mkdir`, `rm`, `edit`),
supports `<` `>` `>>` redirects, and `cd` / `pwd` / `exit` builtins. A
cursor-moving editor lets you modify a file and persist the change
across emulator restarts via a host-backed disk image.

## Definition of done

- `zig build kernel` produces `kernel.elf`. `zig build mkfs` and
  `zig build fs-img` produce `fs.img` from
  `tests/programs/kernel/userland/fs/` on the host.
- `ccc --disk fs.img kernel.elf` boots, runs `/bin/init`, which `exec`s
  `/bin/sh`, prints `$ ` and reads from UART.
- A scripted e2e session passes:
  ```
  $ ls /bin
  cat   echo   edit   ls    mkdir   rm    sh
  $ cat /etc/motd
  hello from phase 3
  $ echo replaced > /etc/motd
  $ cat /etc/motd
  replaced
  $ edit /etc/motd
  (cursor up, edit "replaced again", ^S, ^X)
  $ cat /etc/motd
  replaced again
  $ exit
  ```
  After reboot on the same `fs.img`, `cat /etc/motd` still shows
  `replaced again`.
- `^C` in the shell cancels a foreground program (proves kill-flag).
- `riscv-tests` (rv32ui/um/ua/mi/si all `-p-*`) still pass.
- All Phase 1 e2e tests (`e2e`, `e2e-mul`, `e2e-trap`, `e2e-hello-elf`)
  and the Phase 2 e2e test (`e2e-kernel`) still pass unchanged.
- New e2e tests pass: `e2e-multiproc-stub`, `e2e-fork`, `e2e-fs`,
  `e2e-shell`, `e2e-editor`, `e2e-persist`.
- `--trace` works across the new external-interrupt path; PLIC
  claim/complete shows up as synthetic marker lines.

## Scope

### In scope

- **Emulator additions:** PLIC (32 sources, single S-mode hart
  context); UART RX with a host-stdin pump; block device (4-register
  MMIO + async + IRQ); `--disk PATH` flag; `--input PATH` flag for
  scripted RX; WFI that idles the step loop until the next
  interrupt-edge.
- **Kernel — process model:**
  - Free-list page allocator (replaces Phase 2's bump).
  - `NPROC = 16` static process table.
  - Real round-robin preemptive scheduler with `swtch` context switch.
  - Sleep/wakeup on `chan` pointer (xv6-style).
  - `fork` (full copy), `exec` (kernel-side ELF32), `wait`, `exit`,
    `getpid`, `sbrk`, kill-flag for `^C` (no real signals).
- **Kernel — files & FS:**
  - File table (`NFILE = 64`) + per-process fd table (`NOFILE = 16`).
  - File ops: `open`, `close`, `read`, `write`, `lseek`, `fstat`,
    `chdir`, `getcwd`, `mkdir`, `unlink`. (No `dup` — shell redirects
    close-then-open at the expected fd. No `stat`-by-path —
    `open` + `fstat` covers it.)
  - Block-device driver, buffer cache (`NBUF = 16` × 4 KB, LRU + sleep
    on busy buffer), inode FS (4 KB blocks, 64 inodes, single-level
    indirect, 4 MB total disk).
  - Console "file" backing fd 0/1/2; line discipline with echo,
    backspace, `^C`, `^D`, line-complete on `\n`.
- **Userland:** stdlib (`start.S`, syscall stubs, `printf`, `strlen`,
  …); binaries: `init`, `sh`, `ls`, `cat`, `echo`, `mkdir`, `rm`,
  `edit`.
- **Host tool:** `mkfs.zig` walks a host directory and emits a valid
  4 MB `fs.img`.

### Out of scope (deferred or never)

- Copy-on-write fork — full copy is fine at our scale.
- Real signals (`sigaction`, masks, `sigreturn`) — kill-flag suffices
  for `^C`.
- Pipes — Phase 4 unifies fd types when sockets arrive.
- FS journaling / crash safety — accept that `kill -9 ccc` mid-write
  may corrupt the image.
- Job control / background `&` / process groups / sessions / TTYs.
- Multiple harts; true ASIDs; mmap; chmod / chown / users / file
  modes; tab completion / shell history; `select`/`poll`; floating
  point.
- Snake — held as an optional add-on after the demo passes.

## Architecture

### Emulator modules — Phase 3 deltas

| Module | Phase 3 additions |
|---|---|
| `cpu.zig` | External-interrupt delivery (cause `0x8000_0009` = S-external, `0x8000_000B` = M-external); WFI now blocks the step-loop until the next interrupt-edge instead of busy-stepping; honor `mip.MEIP` / `mip.SEIP` against `mie.MEIE` / `sie.SEIE`. |
| `trap.zig` | External-interrupt entry path; priority `MEI > MSI > MTI > SEI > SSI > STI` (priority resolution already implemented in 2.B; Phase 3 just adds the SEI/MEI sources). |
| `memory.zig` | Two new MMIO ranges: PLIC at `0x0c00_0000` (4 MB), block device at `0x1000_1000` (16 B). |
| `devices/uart.zig` | RX FIFO (256 B); a stdin-drain pump runs in the emulator's idle path (and inside WFI); non-empty FIFO raises PLIC IRQ #10. |
| `devices/plic.zig` | **NEW.** 32 sources × 1 hart context. Per-source priority, per-context threshold + enable bits, pending bits, claim/complete. ~120 lines. |
| `devices/block.zig` | **NEW.** 4 registers (`SECTOR`, `BUFFER`, `CMD`, `STATUS`); on `CMD` write, perform 4 KB transfer immediately and assert PLIC IRQ #1 on the next instruction boundary. ~80 lines. |
| `main.zig` | `--disk PATH` and `--input PATH` flags. |

**Block-device timing model.** Transfers are logically asynchronous,
but we don't model real disk latency: `CMD` write copies the 4 KB
synchronously from the host file (or to it), then the device raises
its IRQ line on the next CPU instruction boundary. This gives a real
interrupt path (kernel must save context, claim, dispatch, complete,
wake the waiter) without modeling fake delays. A `--disk-latency
CYCLES` flag is reserved for future polish, no-op in Phase 3.

**UART RX pump.** macOS-friendly, single-threaded approach: when
`--input` is omitted, the emulator's main loop, in its idle path, does
a non-blocking `poll(stdin, 0)` and drains any available bytes into
the FIFO. WFI yields to the same poll. With `--input FILE`, the file
is streamed into the FIFO as space frees up; EOF after the file is
exhausted. No host threads.

### Kernel modules — full Phase 3 layout

```
tests/programs/kernel/
├── build.zig                 builds kernel.elf + userland binaries + fs.img
├── linker.ld                 unchanged (kernel at 0x80000000)
├── boot.S                    M-mode boot shim — same as 2.C, plus PLIC enable bits
├── mtimer.S                  M-mode timer ISR — unchanged
├── trampoline.S              S-mode trap entry/exit — unchanged structurally
├── kmain.zig                 init order: page_alloc → vm → console → plic → block → bufcache → fs → proc → init
├── page_alloc.zig            free-list page allocator (replaces 2.C's bump)
├── vm.zig                    Sv32 page-table build/walk/free; map_user/unmap_user; copy_uvm
├── plic.zig                  PLIC driver: enable, set_priority, claim, complete
├── uart.zig                  TX (unchanged) + RX FIFO drain in ISR
├── console.zig               line discipline: echo, ^H, ^U, ^C (sets kill_flag), ^D (EOF), wakes line-readers
├── kprintf.zig               unchanged
├── trap.zig                  S-mode dispatcher: syscall, SSIP-timer, S-external (PLIC), page fault, kill-flag check on syscall return
├── syscall.zig               full syscall surface (table)
├── elfload.zig               kernel-side ELF32 loader (program-headers → mapped pages)
├── proc.zig                  Process struct, NPROC=16 table, alloc/free/copy_uvm; fork/exec/wait/exit/kill/sleep/wakeup
├── sched.zig                 round-robin pick from process table; idle hart loop runs WFI when nothing runnable
├── file.zig                  open-file struct, NFILE=64 table; per-proc fd table (NOFILE=16); ref counting
├── block.zig                 block-device driver: enqueue, sleep on completion, ISR wakes waiter
├── fs/
│   ├── layout.zig            on-disk constants: SB block, inode region, bitmap region, data region
│   ├── bufcache.zig          NBUF=16 buffers; bget/brelse/bread/bwrite; lock + sleep on busy buf
│   ├── balloc.zig            block bitmap allocator (alloc/free)
│   ├── inode.zig             on-disk inode + in-memory inode cache (NINODE=32); ialloc, iget, iput, ilock; bmap; readi/writei with single indirect
│   ├── dir.zig               dirlookup, dirlink, dirunlink; flat 16-byte records
│   ├── path.zig              namei, nameiparent — absolute or relative to proc.cwd
│   └── fsops.zig             open/create/read/write/mkdir/unlink/stat/lseek glue
└── userland/
    ├── lib/
    │   ├── start.S           _start: argc/argv from sp; call main; ecall exit
    │   ├── usys.S            one-line ecall stubs per syscall
    │   ├── ulib.zig          memmove, memcmp, strlen, strcmp, atoi
    │   └── uprintf.zig       printf for fd
    ├── linker.ld             user .text at 0x1000, sbrk-region above
    ├── init.zig              forks /bin/sh and waitpid-loops
    ├── sh.zig                line editor + parser + fork/exec/redirect
    ├── ls.zig
    ├── cat.zig
    ├── echo.zig
    ├── mkdir.zig
    ├── rm.zig
    ├── edit.zig              cursor-moving editor (~450 lines)
    └── fs/                   contents to bake into fs.img by mkfs.zig
        ├── bin/              (populated at build time with userland binaries)
        └── etc/motd
```

### Static-table policy (no kernel heap)

Phase 3 keeps Phase 2's "no dynamic kernel allocator" invariant. All
bounded counts live in kernel `.bss`:

| Table | Size | Per-entry size | Notes |
|---|---|---|---|
| Process table | `NPROC = 16` | ~200 B | Per-proc kernel stack (4 KB) is page-allocator-owned. |
| File table | `NFILE = 64` | 16 B | Refcounted "open file" descriptions. |
| Per-proc fd table | `NOFILE = 16` | 4 B per slot | Indices into file table. |
| In-memory inode cache | `NINODE = 32` | ~80 B | Refcounted; backed by on-disk inodes. |
| Buffer cache | `NBUF = 16` | 4 KB + ~32 B header | LRU; sleep on busy. |

If we hit a "I need a heap" feeling we re-evaluate, but the entire
xv6 kernel runs on equivalent table sizes, so this should hold.

## Memory layout

### Physical address space

| Address | Size | Purpose | Phase |
|---|---|---|---|
| `0x0000_1000` | 4 KB | Boot ROM (reserved, unused) | 1 |
| `0x0010_0000` | 8 B | Halt MMIO | 1 |
| `0x0200_0000` | 64 KB | CLINT | 1 |
| **`0x0c00_0000`** | **4 MB** | **PLIC** | **NEW (3.A)** |
| `0x1000_0000` | 256 B | NS16550A UART (gains RX path) | 1, extended |
| **`0x1000_1000`** | **16 B** | **Block device (simple MMIO)** | **NEW (3.A)** |
| `0x8000_0000` | 128 MB | RAM | 1 |

PLIC and block-device addresses match (or sit in free slots within)
QEMU's `virt` machine, so `qemu-diff` can reach the same MMIO if we
ever extend the harness.

### Block device register map

Offsets relative to `0x1000_1000`:

| Off | Reg | Size | RW | Behavior |
|---|---|---|---|---|
| `0x0` | `SECTOR` | u32 | RW | Sector index (sector size = 4 KB; 1024 sectors total). |
| `0x4` | `BUFFER` | u32 | RW | Physical address (4-byte-aligned) of guest's 4 KB buffer. |
| `0x8` | `CMD` | u32 | W | `1` = read disk→RAM, `2` = write RAM→disk, `0` = reset. Other = error. |
| `0xC` | `STATUS` | u32 | R | `0` = ready / last-op-ok, `1` = busy (never observed — synchronous from CPU's POV), `2` = error, `3` = no-media (no `--disk`). |

Writing `CMD` performs the transfer immediately, sets `STATUS`, and on
the next CPU instruction boundary asserts the PLIC IRQ #1 edge. The
kernel reads `STATUS` after the interrupt to verify success.

### PLIC layout (legacy QEMU `virt`-compatible subset)

| Range | Purpose |
|---|---|
| `0x0c00_0004 – 0x0c00_007C` | Per-source priority (sources 1..31), u32 each, value 0..7. |
| `0x0c00_1000 – 0x0c00_1004` | Pending bits for sources 0..31 (read-only). |
| `0x0c00_2080 – 0x0c00_2084` | S-mode hart-context enable bits. |
| `0x0c20_1000` | S-mode threshold. |
| `0x0c20_1004` | S-mode claim/complete (read = claim, write = complete). |

Single hart context (S-mode); M-mode never takes external interrupts
in our system. Real sources used: IRQ #1 = block, IRQ #10 = UART RX.
Other source IDs are reserved.

### Per-process virtual address space (Sv32)

Every process gets one root page table; all share the kernel + MMIO
direct-mapped tail.

| VA range | Purpose | Perm | Per-proc / shared |
|---|---|---|---|
| `0x0000_1000 – 0x000F_FFFF` | User `.text`/`.rodata`/`.data`/`.bss`, then heap (`sbrk`-grown) | U, R/W/X per segment; heap R+W | per-proc |
| `0x0010_0000 – 0x0010_0FFF` | Halt MMIO (S-only, identity-mapped) | S, R+W | shared |
| `0x0200_0000 – 0x0200_FFFF` | CLINT (S-only) | S, R+W | shared |
| `0x0c00_0000 – 0x0c3F_FFFF` | PLIC (S-only) | S, R+W | shared |
| `0x1000_0000 – 0x1000_1FFF` | UART + block device (S-only) | S, R+W | shared |
| `0x8000_0000 – 0x87FF_FFFF` | Kernel direct map | S, R/W/X per page, `G=1` | shared |
| `0x0FFF_E000 – 0x0FFF_FFFF` | User stack (8 KB), grows down from `0x1000_0000` | U, R+W | per-proc |

User text now starts at `0x0000_1000` (not Phase 2's `0x0001_0000`) so
page 0 is unmapped — null-pointer dereferences fault cleanly. User
stack moved from Phase 2's `0x0003_0000` to `0x0FFF_E000` (top of the
user half) so heap (`sbrk`) and stack don't collide for any reasonable
program size.

Kernel reads/writes user memory via `sstatus.SUM = 1` for the duration
of the copy. Phase 3 still panics on kernel-origin page faults; safe
because syscall callers either pass kernel addresses, fixed user-stack
addresses, or addresses inside known-mapped user `.rodata`/heap, all of
which we validate before touching.

## Devices

- **UART (`0x1000_0000`)** — Phase 2 added TX. Phase 3 adds RX:
  256-byte FIFO, IRQ #10 raised whenever the FIFO is non-empty (level,
  not edge — kernel keeps consuming until drained). `LSR` register
  bit 0 = "data ready" reflects FIFO non-empty.
- **CLINT (`0x0200_0000`)** — unchanged from Phase 2.
- **PLIC (`0x0c00_0000`)** — new. See layout above.
- **Block device (`0x1000_1000`)** — new. See register map above.
- **Halt MMIO (`0x0010_0000`)** — unchanged.
- **Boot ROM** — still reserved, still unused.

## Privilege & trap model

Phase 2's M/S/U story holds. Phase 3 changes one thing: external
interrupts are delegated to S, so the kernel's `s_trap_dispatch`
gains a third async case alongside the timer and syscalls.

### Delegation (deltas from Phase 2)

```
medeleg                              // unchanged from Phase 2
mideleg = (1<<1)   // SSIP — timer-forwarded path (Phase 2)
        | (1<<9)   // SEIP — supervisor external (Phase 3, NEW)
// MTIP (bit 7) still NOT delegated — M-mode handles CLINT.
// MEIP (bit 11) NOT delegated — M-mode never takes external; we
// don't enable mie.MEIE.
```

Boot shim additions:
- `sie.SEIE = 1` (enable supervisor external).
- PLIC: enable bits for source 1 (block) and source 10 (UART RX);
  threshold = 0; per-source priority = 1.
- `mie.MEIE = 0` (M-mode never takes external).

### External-interrupt flow (the new path)

```
device      M-mode boot                CPU instr.    PLIC + S-mode trap.zig
─────────   ────────────────────       ──────────    ──────────────────────
block/uart  set medeleg[ext]?          boundary
            NO — externals stay in M?  check         (on take)
            Actually: mideleg[SEIP]=1  mip.SEIP ?    ┌─ csr.read scause = 0x80000009
boot.S sets:                           sie.SEIE?    │  irq = plic.claim()
  mideleg[SEIP] = 1                    AND          │  switch (irq) {
  PLIC enable bits for src 1, 10       sstatus.SIE  │   case 1:
  PLIC threshold = 0                   OR cur < S   │     block.isr();
  mie.MEIE = 0                         ─────►       │     break;
  sie.SEIE = 1                         deliver to S │   case 10:
                                                    │     uart.drain_to_console();
device asserts irq line                             │     break;
  → PLIC pending[irq] |= 1                          │  }
  → if any enabled+priority>thresh                  │  plic.complete(irq)
    ⇒ raises mip.SEIP edge                          │  // sret ⇒ resume
                                                    └──
```

`block.isr()` reads `STATUS`, sets `req.err`, sets `req.state = .Done`,
calls `wakeup(&req)`.

`uart.drain_to_console()` reads bytes out of the UART RX FIFO until
empty, feeds each through console line discipline, and calls
`wakeup(&console.line_buf)` once at the end if any complete lines were
produced.

### Trace deltas

`--trace` gains:

- `--- interrupt 9 (S-external, PLIC src N) taken in <old>, now <new> ---`
  inserted between instructions when an external interrupt is taken.
- `--- block: read sector 42 into 0x80100000 ---` printed when the
  device performs a transfer.

## Process model

### `Process` struct

```zig
pub const State = enum { Unused, Embryo, Sleeping, Runnable, Running, Zombie };

pub const Context = extern struct {
    // Callee-saved kernel regs swapped by swtch().
    ra: u32, sp: u32,
    s0: u32, s1: u32, s2: u32, s3: u32, s4: u32, s5: u32,
    s6: u32, s7: u32, s8: u32, s9: u32, s10: u32, s11: u32,
};

pub const Process = struct {
    // Identity & relationships
    pid: u32,
    parent: ?*Process,            // null for init only
    state: State,

    // Address space
    satp: u32,                    // top-level page table PPN | MODE bits
    pgdir: *[1024]Pte,            // root, kernel-direct-mapped
    sz: u32,                      // user heap high-water-mark (sbrk)

    // Kernel-side execution context
    kstack: [*]u8,                // 4 KB, page-allocator-owned
    kstack_top: usize,
    tf: TrapFrame,                // unchanged from Phase 2
    context: Context,             // saved kernel regs for swtch

    // Wait / sleep / kill
    chan: ?usize,                 // sleeping on this address
    killed: bool,                 // ^C sets; checked at syscall return
    xstate: i32,                  // exit status, harvested by parent

    // Filesystem context
    cwd: *Inode,                  // ref-counted
    ofile: [NOFILE]?*File,        // per-proc fd table

    // Naming (debug aid)
    name: [16]u8,
};

pub var ptable: [NPROC]Process = undefined;   // .bss; NPROC = 16
```

PIDs allocated from a monotonic `next_pid` counter starting at 1; not
reused (32-bit room is more than enough for any realistic Phase 3 run).

### State diagram

```
                   sched picks
Unused ──alloc──► Embryo ──setup──► Runnable ◄───────── Running
   ▲                                   ▲                   │
   │                                   │ wakeup            │ sleep
   │                                Sleeping ◄─────────────┤
   │                                                       │ exit
   │                                  Zombie ◄─────────────┘
   └──── parent harvests via wait() ────┘
```

### Scheduler

Round-robin, preempted by the timer (the SSIP-forwarded path from
Phase 2 already does this — we just stop ignoring the result of
`schedule()`).

```zig
pub fn scheduler() noreturn {
    while (true) {
        var picked: ?*Process = null;
        for (&ptable) |*p| {
            if (p.state == .Runnable) { picked = p; break; }
        }
        if (picked) |p| {
            p.state = .Running;
            cpu.cur = p;
            csr.write_satp(p.satp);
            asm volatile ("sfence.vma zero, zero" ::: "memory");
            swtch(&cpu.context, &p.context);
            cpu.cur = null;
        } else {
            asm volatile ("wfi");
        }
    }
}
```

`swtch` saves callee-saved kernel registers to the outgoing context
and restores them from the incoming one (~30 lines of asm). The
scheduler runs on its own kernel stack (`cpu.scheduler_stack`),
separate from any process's kernel stack — so a process can sleep
partway through a syscall and the scheduler resumes cleanly elsewhere.

### `fork()`

```zig
pub fn fork() i32 {
    const parent = cpu.cur.?;
    const child = alloc() orelse return -1;          // grabs Unused slot

    if (vm.copy_uvm(parent.pgdir, child.pgdir, parent.sz)) |_| {} else {
        free(child); return -1;
    }
    child.sz = parent.sz;
    child.parent = parent;
    child.tf = parent.tf;                            // resume at same insn
    child.tf.a0 = 0;                                 // child sees fork() == 0

    for (parent.ofile, 0..) |maybe_f, i| {
        if (maybe_f) |f| { child.ofile[i] = file.dup(f); }
    }
    child.cwd = inode.dup(parent.cwd);

    @memcpy(&child.name, &parent.name);
    const pid = child.pid;
    child.state = .Runnable;
    return @intCast(pid);                            // parent sees child's pid
}
```

`copy_uvm` walks every user PTE in the parent, allocates a fresh frame
per leaf, `memcpy`s 4 KB, and installs the new mapping with the same
flags in the child's page table. No COW.

### `exec()`

Kernel-side ELF32 loader (`elfload.zig`). On a successful exec:

1. Resolve `path` via `namei` to an inode; verify regular file with
   U+R+X.
2. Validate ELF header: magic, class=32, machine=RISCV, type=EXEC,
   `e_phnum > 0`.
3. Build a new pgdir, mapped with kernel + MMIO + nothing user yet.
4. For each `PT_LOAD` program header: allocate
   `ceil(p_memsz / 4 KB)` pages, map at `p_vaddr` with permissions
   from `p_flags`, `readi` `p_filesz` bytes from the inode into the
   range. Page allocator zeroes pages, so `p_memsz > p_filesz` tail
   is clean.
5. Allocate user stack at `0x0FFF_E000` (8 KB, two pages, the high
   guard page left unmapped — fault on overflow).
6. Build initial stack frame: `argc`, `argv[]`, `argv[i]` strings,
   null terminators (System-V tail).
7. Replace process address space: free the old pgdir's user region;
   install new pgdir; set `tf.sepc = e_entry`, `tf.sp = stack_top`,
   `tf.a0 = argc`, `tf.a1 = argv_ptr`.
8. Return to user via the standard trap-return path.

If any step fails before step 7, we tear down the partial new pgdir
and return `-1` to the caller without disturbing the running process.

### `exit()` and `wait()`

`exit(status)`:

1. Close every fd (`file.close(p.ofile[i])` decrements ref, frees on
   zero).
2. `iput(p.cwd)`.
3. Reparent every child of `p` to `init` (so the child still has a
   reaper).
4. Set `p.xstate = status`, `p.state = Zombie`, `wakeup(p.parent)`.
5. Call `sched()` and never return; the parent will `free()` us in
   `wait`.

`wait(int *xstatus)`:

1. Loop: scan ptable for a child of self.
2. If any child is `Zombie`: harvest pid, copy xstate to user, free
   its kstack and user pages and pgdir, mark `Unused`, return pid.
3. If we have children but none zombie: `sleep(self)` and repeat.
4. If no children at all: return `-1`.

### Sleep / wakeup

xv6-style. `chan` is a pointer used as an ID; both sleeper and waker
name the same address.

```zig
pub fn sleep(chan: usize) void {
    const p = cpu.cur.?;
    p.chan = chan;
    p.state = .Sleeping;
    sched();              // returns when state goes back to Runnable
    p.chan = null;
}

pub fn wakeup(chan: usize) void {
    for (&ptable) |*p| {
        if (p.state == .Sleeping and p.chan == chan) p.state = .Runnable;
    }
}
```

Used by `wait()`, `block.zig`, `bufcache`, `console.zig`. We disable
`sstatus.SIE` from "set chan" through "swtch into scheduler" (and
re-enable inside the scheduler loop) to close the classic
sleep-then-yield race.

No locks in Phase 3 — single-hart, async paths only touch shared state
at well-defined points (claim/wakeup) where the sleeper isn't in the
middle of a critical section by construction.

### Kill flag (`^C` path, no real signals)

The console has two modes, switched by `console_set_mode(mode)`
(syscall 5001): **cooked** (default) and **raw**. The shell uses
cooked. The editor switches to raw on entry and back to cooked on
exit.

In **cooked mode**, the line discipline echoes characters, handles
backspace (`^H`) and line-kill (`^U`), and on byte `0x03` (`^C`):

1. Echoes `^C\n` and clears the line buffer (any in-progress line is
   discarded — `read` does not return).
2. If `console.fg_pid != 0`, calls `proc.kill(fg_pid)`, which sets
   `target.killed = true` and, if `target` is `Sleeping`, makes it
   `Runnable` so it can observe the flag.

Every syscall return path checks `cur.killed` before `sret`-ing back
to user. If set, the syscall jumps to `exit(-1)` instead.

`fg_pid` is `0` (no foreground) by default. The shell sets
`fg_pid = child_pid` via `set_fg_pid(child_pid)` (syscall 5000) before
each `wait` and resets it to `0` after `wait` returns — so the shell
itself is never the kill target, and no shell-side immunity is needed.

In **raw mode**, the line discipline is bypassed: every byte
(including `0x03`) is delivered straight to the reader's buffer with
no echo, no line-buffering, and no kill-call. The editor reads
`ESC [ A/B/C/D` (arrow keys) and other control bytes this way.

## Filesystem

### On-disk layout (4 MB total, 1024 × 4 KB blocks)

```
block 0       boot sector (zeros, reserved)
block 1       superblock
block 2       block-bitmap (one bit per data block)
blocks 3..6   inode table (4 blocks reserved; 64 inodes × 64 B fits in 1)
blocks 7..1023 data blocks (1017 of them)
```

```zig
// fs/layout.zig
pub const BLOCK_SIZE   = 4096;
pub const NBLOCKS      = 1024;
pub const NINODES      = 64;
pub const INODES_PER_BLOCK = BLOCK_SIZE / @sizeOf(DiskInode);  // 64

pub const SUPERBLOCK_BLK   = 1;
pub const BITMAP_BLK       = 2;
pub const INODE_START_BLK  = 3;
pub const DATA_START_BLK   = 7;

pub const SuperBlock = extern struct {
    magic: u32,        // 0xC3CC_F500  ('ccc' + fs marker)
    nblocks: u32,
    ninodes: u32,
    bitmap_blk: u32,
    inode_start: u32,
    data_start: u32,
    dirty: u32,        // set by mount, cleared by clean shutdown
};
```

### Inodes

```zig
pub const NDIRECT   = 12;
pub const NINDIRECT = BLOCK_SIZE / @sizeOf(u32);     // 1024
pub const MAX_FILE_BLOCKS = NDIRECT + NINDIRECT;     // 1036 → 4.04 MB max

pub const FileType = enum(u16) { Free = 0, File = 1, Dir = 2 };

pub const DiskInode = extern struct {
    type: FileType,                  // u16
    nlink: u16,                      // hard-link count
    size: u32,                       // bytes
    addrs: [NDIRECT + 1]u32,         // 12 direct + 1 indirect
    _reserved: [12]u8,               // pad to 64 B
};

pub const InMemInode = struct {
    inum: u32,
    refs: u32,             // in-cache ref count
    valid: bool,           // disk read complete?
    dinode: DiskInode,     // cached on-disk copy
    busy: bool,            // sleep-locked while in use
};
```

`bmap(inode, bn) → block#` translates a logical file block index to a
disk block, allocating the indirect block (and the leaf data block)
lazily on write. Reads past EOF return zero without going to disk.

### Directories

Flat 16-byte records:

```
struct DirEntry { u16 inum; u8 name[14]; }   // name[0]==0 means free
```

A directory is a regular file containing a packed array of `DirEntry`.
`dirlookup(dir, name)` linear-scans; `dirlink(dir, name, inum)` finds
the first free slot (or appends). Names are at most 13 bytes + NUL.

`.` and `..` are real `DirEntry` records, allocated by `mkdir`. Root
inode is hard-coded as inum 1; its `..` points back to itself.

### Path resolution

```zig
pub fn namei(path: []const u8) !*InMemInode { … }
pub fn nameiparent(path: []const u8, name: *[14]u8) !*InMemInode { … }
```

Both walk left-to-right. Absolute paths start at the root inode;
relative paths start at `cur.cwd`. Iterative, no recursion.
Maximum component length 13 bytes; total path length capped at 256.

### Buffer cache

```zig
pub const NBUF = 16;

pub const Buf = struct {
    block: u32,
    dirty: bool,
    valid: bool,
    refs: u32,
    busy: bool,            // sleep-locked
    data: [BLOCK_SIZE]u8 align(4),
    next_lru: ?*Buf,
    prev_lru: ?*Buf,
};
pub var bcache: [NBUF]Buf = undefined;     // .bss; 64 KB
```

API:

- `bget(blk)` → `*Buf`, sleep-locked, possibly stale.
- `bread(blk)` → `bget` + (if invalid) `block.read(blk, buf.data); valid = true`.
- `bwrite(buf)` → enqueues a disk write, sleeps until the ISR wakes
  us, clears `dirty`.
- `brelse(buf)` releases the lock, bumps LRU, decrements refcount,
  wakes any waiters on the same buffer.

LRU eviction picks the least-recently-released, refcount-zero buffer.
Panic-on-no-evictable triggers if every buffer is in active use — at
NBUF=16 with ~3 buffers needed per syscall, this should never happen
in Phase 3.

We do **not** implement xv6's logging layer. A `kill -9 ccc` mid-write
can leave the FS inconsistent. Acceptable for Phase 3; Phase 5 may
revisit. Boot prints a "fs may be inconsistent" warning if `dirty == 1`
in the superblock; `init` clears it on clean shutdown (when `sh`
returns from a clean `exit`).

### Block I/O driver (`block.zig`)

```zig
const ReqState = enum { Idle, Pending, Done };
pub var req: struct {
    state: ReqState = .Idle,
    err: bool = false,
    waiter: ?*Process = null,
} = .{};

pub fn read(blk: u32, dst: [*]u8) void {
    submit(blk, dst, CMD_READ);
}

pub fn write(blk: u32, src: [*]const u8) void {
    submit(blk, src, CMD_WRITE);
}

fn submit(blk: u32, buf: anytype, cmd: u32) void {
    req.state = .Pending;
    req.waiter = cpu.cur;
    mmio.write(BLK + 0x0, blk);
    mmio.write(BLK + 0x4, @intFromPtr(buf));
    mmio.write(BLK + 0x8, cmd);
    while (req.state != .Done) sleep(@intFromPtr(&req));
    if (req.err) panic("block I/O error", .{});
    req.state = .Idle;
}

// Called from PLIC dispatcher on IRQ #1
pub fn isr() void {
    req.err = (mmio.read(BLK + 0xC) != 0);
    req.state = .Done;
    wakeup(@intFromPtr(&req));
}
```

The "single outstanding request" simplification (one global `req`, no
queue) is fine while sleep/wakeup serializes us — only one process
sits in `submit` at a time because the bufcache's per-buf lock chokes
everyone else into sleep before they reach the device.

### Syscall surface

| # | Name | Args | Return | Phase |
|---|---|---|---|---|
| 17 | `getcwd(buf, sz)` | u32, u32 | bytes / `-ERANGE` | 3 |
| 49 | `chdir(path)` | u32 | 0 / -1 | 3 |
| 56 | `openat(dirfd, path, flags)` | u32, u32, u32 | fd / -1 | 3 |
| 57 | `close(fd)` | u32 | 0 / -1 | 3 |
| 62 | `lseek(fd, off, whence)` | u32, i32, u32 | new_off / -1 | 3 |
| 63 | `read(fd, buf, n)` | u32, u32, u32 | bytes / 0 / -1 | 3 |
| 64 | `write(fd, buf, n)` | u32, u32, u32 | bytes / -1 | 2 (extended in 3) |
| 80 | `fstat(fd, statbuf)` | u32, u32 | 0 / -1 | 3 |
| 93 | `exit(status)` | i32 | does not return | 2 |
| 124 | `yield()` | — | 0 | 2 |
| 172 | `getpid()` | — | pid | 3 |
| 214 | `sbrk(incr)` | i32 | old break / -1 | 3 |
| 220 | `clone` (used as `fork()`) | — | 0 in child / pid in parent | 3 |
| 221 | `execve(path, argv, envp)` | u32, u32, u32 (envp ignored) | does not return on success / -1 | 3 |
| 260 | `wait4(pid, status, options, rusage)` | u32, u32, u32, u32 (only pid + status meaningful) | pid / -1 | 3 |
| 34 | `mkdirat(dirfd, path)` | u32, u32 | 0 / -1 | 3 |
| 35 | `unlinkat(dirfd, path, flags)` | u32, u32, u32 | 0 / -1 | 3 |
| 5000 | `set_fg_pid(pid)` | u32 | 0 | 3 (shell-only) |
| 5001 | `console_set_mode(mode)` | u32 (0 = cooked, 1 = raw) | 0 | 3 (editor-only) |

Numbers picked from the Linux RISC-V (asm-generic) table where one
exists; locally numbered (5000+) for the two non-Linux ones. `clone`
is degraded to flagless `fork`. `dirfd` in the `*at` syscalls is
ignored — paths are always either absolute or resolved relative to
`cwd`. `sbrk` reuses Linux's `brk` slot (214) but takes an increment
and returns the previous break — sbrk-style ergonomics, not Linux's
absolute-address `brk` semantics.

### `mkfs.zig` (host tool)

A small Zig program that runs on the host. Walks an input directory
tree, computes inode and block counts, lays out a 4 MB image:

```
$ zig build mkfs
$ zig-out/bin/mkfs                     \
    --root tests/programs/kernel/userland/fs/  \
    --bin  zig-out/userland/bin/      \
    --out  zig-out/fs.img
```

- `--root` populates everything outside `/bin` (e.g., `/etc/motd`).
- `--bin` is the directory of kernel-built userland ELFs; copied into
  `/bin/`.
- `--out` is the output image path (4 MB).

`zig build fs-img` is a convenience target that runs userland + mkfs.

## Userland

Approximate sizes; final numbers will land per plan.

| Binary | Approx LoC | Notes |
|---|---|---|
| `init` | 30 | `exec("/bin/sh", ["sh"])`; if `sh` exits, restart it. |
| `sh` | ~350 | Line editor (`^H`, `^U`, `^C` cancels current line, `^D` exits on empty); tokenizer (whitespace + `<` `>` `>>`); per-command fork; redirect by close-then-open at expected fd; `cd`/`pwd`/`exit` builtins; `set_fg_pid(child)` before each `wait`. |
| `ls` | ~70 | Open path, read DirEntry records if dir, print stat info if file. |
| `cat` | ~40 | Open each arg, copy to fd 1 in 4 KB chunks; with no args, copy fd 0 → fd 1. |
| `echo` | ~25 | Print argv joined by space, plus newline. |
| `mkdir` | ~25 | `mkdirat(0, argv[1])`. |
| `rm` | ~25 | `unlinkat(0, argv[1], 0)`. |
| `edit` | ~450 | `console_set_mode(1)` on entry, `console_set_mode(0)` on exit; load file into a 16 KB buffer (cap); main loop reads one keystroke; arrow keys via `ESC [ A/B/C/D`; printable inserts at cursor; backspace deletes; `^S` rewrites file; `^X` exits. ANSI cursor positioning for redraws. |

User stdlib (`userland/lib/`):

- `start.S`: parses `argc`/`argv` from `sp`, calls `main(argc, argv)`,
  `ecall exit`.
- `usys.S`: one `ecall` stub per syscall (~50 lines).
- `ulib.zig`: `memmove`, `memcmp`, `strlen`, `strcmp`, `atoi`.
- `uprintf.zig`: 60-line `printf(fd, fmt, ...)`.

## Testing strategy

### 1. Emulator unit tests (in 3.A and onward)

- PLIC: enable/threshold/claim/complete; priority + threshold gating;
  pending edge generation; multiple sources at differing priorities.
- UART RX: FIFO push/pop; level-IRQ assertion when non-empty.
- Block device: read/write transfers; `--disk` open/missing; error
  status on bad CMD; IRQ #1 raised after transfer.
- WFI: cpu blocks until next interrupt-edge.

### 2. Kernel unit tests (in 3.B and onward)

- `page_alloc`: alloc, free, alloc-after-free, exhaustion.
- `swtch`: round-trip preserves callee-saved regs.
- `copy_uvm`: parent and child observe independent writes after fork.
- `elfload`: hand-crafted minimal RV32 ELF; missing `PT_LOAD` rejected;
  bad magic rejected.
- `bufcache`: LRU ordering; sleep-on-busy; multiple readers wait.
- `bmap`: direct vs. indirect block; allocation on first write.
- `namei`: `/`, `/a`, `/a/b`, `..`, repeated `..`, missing component,
  too-long path.
- `fork`: PID monotonic; ofile dup'd; cwd dup'd.
- `wait`: reparenting on exit; sleep when no zombie children.
- Sleep-yield race: synthetic test with timer fired during sleep
  setup.

### 3. `riscv-tests` integration

rv32{ui,um,ua,mi,si}-p-* unchanged from Phase 2. Must still pass after
every Phase 3 plan lands.

### 4. Kernel e2e (`zig build e2e-*`)

One per plan, plus the existing e2e tests:

| Test | What it asserts | Plan |
|---|---|---|
| `e2e-multiproc-stub` | Two embedded ELFs as PID 1 + PID 2, both print, both exit. | 3.B |
| `e2e-fork` | `init` forks `hello`, parent waits, both exit. | 3.C |
| `e2e-fs` | `init` opens `/etc/motd`, reads, writes to fd 1, exits. | 3.D |
| `e2e-shell` | Scripted session via `--input`: `ls`, `echo>`, `cat<`, `rm`, `exit`. | 3.E |
| `e2e-editor` | Scripted editor session: open, cursor-edit, save, quit. | 3.F |
| `e2e-persist` | `ccc` invoked twice on same `fs.img`; second run sees first's writes. | 3.F |

### 5. QEMU-diff

Extended only opportunistically. PLIC and block addresses match QEMU's
`virt`, but the kernel's behavior diverges from anything QEMU runs
natively. Skip unless a specific bug pulls us back.

### 6. Regression coverage

Phase 1 (`e2e`, `e2e-mul`, `e2e-trap`, `e2e-hello-elf`) and Phase 2
(`e2e-kernel`) pass after every plan. Hooks already wired in
`build.zig`.

## Project structure

```
ccc/
├── build.zig                                  + kernel-userland targets, mkfs, fs-img
├── src/                                       emulator (Phase 3 deltas above)
│   ├── devices/
│   │   ├── plic.zig                          NEW (3.A)
│   │   ├── block.zig                         NEW (3.A)
│   │   ├── uart.zig                          + RX FIFO
│   │   └── clint.zig                         unchanged
│   └── …                                     other modules per Architecture
├── tests/
│   ├── programs/
│   │   ├── hello/, mul_demo/, trap_demo/,
│   │   │   hello_elf/                        Phase 1, unchanged
│   │   └── kernel/                           Phase 2 layout, heavily extended
│   ├── fixtures/                             unchanged
│   ├── riscv-tests/                          unchanged (rv32si already added in 2.A)
│   ├── riscv-tests-p.ld                      unchanged
│   └── riscv-tests-s.ld                      unchanged (from 2.A)
├── scripts/
│   ├── qemu-diff.sh                          unchanged
│   └── qemu-diff-kernel.sh                   unchanged
└── docs/superpowers/specs/                   + this spec
```

## CLI

```
ccc [--trace] [--halt-on-trap] [--memory MB] [--disk PATH]
    [--input PATH] [--disk-latency CYCLES] <elf>
```

- `--disk PATH`: back the block device with this file. Opened
  `O_RDWR`. Without the flag, the device reports "no media" and any
  `CMD` write fails with `STATUS = 3`.
- `--input PATH`: stream this file's contents into the UART RX FIFO
  as space frees up; EOF after exhaustion. Used by scripted e2e tests.
  Without it, the emulator drains `stdin` non-blockingly in the idle
  path.
- `--disk-latency CYCLES`: reserved, no-op in Phase 3.

## Implementation plan decomposition

Six plans:

- **3.A — Emulator: PLIC + UART RX + block device + `--disk`**
  `devices/plic.zig`, `devices/block.zig`, RX FIFO in `devices/uart.zig`,
  WFI idle, `--disk`, `--input`, full unit-test coverage. **No kernel
  changes.** Milestone: a tiny S-mode test program (lives in
  `tests/programs/plic_block_test/` — same shape as Phase 2's kernel
  skeleton: M-mode boot → drop to S → run test → exit via halt MMIO)
  writes a sector via MMIO, sleeps in WFI, takes the PLIC interrupt,
  claims, reads back, completes.
- **3.B — Kernel multi-process foundation**
  Free-list `page_alloc`; static `ptable[NPROC=16]`; round-robin
  scheduler with `swtch`; kernel-side ELF32 loader; `getpid`, `sbrk`,
  `yield` syscalls. Phase 2's `userprog.bin` is rebuilt as an ELF
  (`userprog.elf`), embedded via `@embedFile`, and run as PID 1
  through the new ELF loader and scheduler. Milestone: `e2e-kernel`
  still passes; `e2e-multiproc-stub` boots two embedded ELFs as
  PID 1 + PID 2 (set up by hand at boot, before `fork` exists), both
  print, both exit.
- **3.C — fork / exec / wait / exit / kill-flag**
  Full process lifecycle. `init` is now an embedded ELF that forks an
  embedded `hello` ELF, waits, exits. `set_fg_pid` and
  `console_set_mode` syscalls accept-and-discard (no console RX yet).
  Milestone: `e2e-fork` boots; init forks; child prints; parent reaps;
  both exit; emulator returns 0.
- **3.D — Bufcache + block driver in kernel + FS read path**
  `block.zig` driver, `fs/bufcache.zig`, rest of `fs/*.zig`,
  `mkfs.zig`, `fs-img` build target. New syscalls: `openat`, `close`,
  `read`, `lseek`, `fstat`, `chdir`, `getcwd`. `init` is now loaded
  **from `fs.img`** instead of embedded. Milestone: `e2e-fs` runs an
  `init` that opens `/etc/motd`, reads it, `write`s it to fd 1, exits.
- **3.E — FS write path + console fd + shell + utilities**
  `write`/`mkdirat`/`unlinkat`. Console as fd 0/1/2 with line
  discipline. User stdlib (`start.S`, `usys.S`, `ulib.zig`,
  `uprintf.zig`). Userland: `sh`, `ls`, `cat`, `echo`, `mkdir`, `rm`.
  Milestone: `e2e-shell` pipes a scripted session in via `--input`:
  `ls /bin\necho hi > /tmp/x\ncat /tmp/x\nrm /tmp/x\nexit\n` —
  output matches expected transcript.
- **3.F — Editor + persistence + final demo**
  `edit` userland binary; `console_set_mode` raw-mode path actually
  wired into the line discipline; `e2e-persist` runs `ccc` twice on
  the same `fs.img`. Polish trace formatting; doc updates. Milestone:
  hit Definition of Done.

## Risks and open questions

- **PLIC vs. CLINT priority interactions.** Spec priority is
  `MEI > MSI > MTI > SEI > SSI > STI`. Phase 3 produces SEI (PLIC) and
  SSI (timer-forwarded). The first time both pend simultaneously,
  unit-test it explicitly in 3.B; expect SEI first, SSI on the next
  instruction boundary. Priority-resolution code path is already there
  from 2.B.
- **Sleep-then-yield race.** A process sets state to Sleeping but is
  interrupted before calling `sched()`, while its waker fires. Without
  locks (single-hart) this can still bite if the wake path runs in an
  ISR while the would-be sleeper is mid-state-change. Mitigation:
  disable `sstatus.SIE` from "set chan" through "swtch into
  scheduler"; re-enable inside the scheduler loop. Documented in
  `proc.zig`.
- **No-logging FS corruption.** `kill -9 ccc` mid-`bwrite` can leave
  bitmap and inode out of sync. Acceptable for Phase 3; superblock
  carries a `dirty` bit so we can warn on next boot. A future logging
  layer (~150 lines) lifts this.
- **Editor's 16 KB file cap.** Sized for the demo (`/etc/motd` is one
  line). Trivial to lift if we want to edit larger files.
- **fork copying entire address space.** With max user `sz` ≈ 64 KB
  and NPROC = 16, worst-case full table is ~1 MB of user RAM —
  comfortable inside our 128 MB. COW becomes the answer if this ever
  pinches; not Phase 3.
- **UART RX flow control.** A 256-byte FIFO can overflow under heavy
  `--input` streaming. Mitigation: the pump stops feeding the FIFO
  when full; bytes back up in the host file (lseek-based), so nothing
  is dropped. Trade-off: blocked emulator main loop until FIFO drains,
  fine for our test loads.
- **`set_fg_pid` and `console_set_mode` non-Linux syscalls.** No
  Linux ABI mirror. Chosen to keep us out of full POSIX signals and
  termios. If Phase 5 ever ports outside userland, we wrap them in
  libc-equivalent helpers and never expose to "outside" code.
- **Zig version churn.** Same risk as every phase. Re-pin
  `build.zig.zon` at Phase 3 start. Userland builds now produce ELFs
  the kernel loads — keep an eye on default `.eh_frame` / `.note.*`
  sections; we ignore non-`PT_LOAD` headers, so they should pass
  through.

## Roughly what success looks like at the end of Phase 3

```
$ zig build test                   # all unit tests pass (Phase 1 + 2 + 3)
$ zig build riscv-tests            # rv32{ui,um,ua,mi,si}-p-* all pass
$ zig build e2e                    # e2e + e2e-mul + e2e-trap + e2e-hello-elf
                                   #  + e2e-kernel + e2e-multiproc-stub
                                   #  + e2e-fork + e2e-fs + e2e-shell
                                   #  + e2e-editor + e2e-persist all pass

$ zig build kernel && zig build fs-img
$ zig build run -- --disk zig-out/fs.img zig-out/bin/kernel.elf
$ ls /bin
cat   echo   edit   ls    mkdir   rm    sh
$ cat /etc/motd
hello from phase 3
$ echo replaced > /etc/motd
$ edit /etc/motd
(arrow keys, type "replaced again", ^S, ^X)
$ cat /etc/motd
replaced again
$ exit
[init] sh exited 0; restarting
$ exit
[init] sh exited 0; restarting
^C  (host kills emulator)

$ zig build run -- --disk zig-out/fs.img zig-out/bin/kernel.elf
$ cat /etc/motd
replaced again
$
```

…and you understand every byte from the M-mode boot shim through the
editor's ANSI escapes.
