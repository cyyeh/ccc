# Walkthrough: What Happens When You Type `cat /etc/motd`

> Twelve hops, six topics, every kernel subsystem. The single most-educational page on this site.

You're in the `ccc` shell. You type `cat /etc/motd` and press Enter. Twenty milliseconds later you see `hello from phase 3`. This walkthrough explains everything that happened.

It assumes you've read all nine topics. We're tying them together.

The setup: `kernel-fs.elf` is running with `--disk shell-fs.img --input cat_input.txt` (the input file just contains `cat /etc/motd\nexit\n`). The kernel has booted, `init_shell` has fork+execed `sh`, and sh is at the prompt.

Each "hop" is a privilege boundary or significant subsystem transition. Let's count them.

---

## Hop 1: A keystroke arrives via `--input`

The shell is sleeping in `console.read` (cooked mode, waiting for `\n`). Its `wfi` is a no-op via the SIE-window pattern; the scheduler is doing `idleSpin`.

`idleSpin` calls `pump.drainOne(io, uart)`. `RxPump`:

1. Reads one byte from `cat_input.txt`. Let's say the first byte: `'c'` (0x63).
2. Calls `uart.pushRx(0x63)`.
3. `pushRx` checks the FIFO: it's empty. Adds 'c'. FIFO has 1 byte. Calls `plic.assertSource(10)` since the FIFO went empty → non-empty.

Now `plic.pending |= (1 << 10)`, and via `plic.hasPendingForS()` → `mip.SEIP = 1` (live overlay).

**Topics involved:** [devices-uart-clint-plic-block](#devices-uart-clint-plic-block).

---

## Hop 2: `check_interrupt` fires SEI

`idleSpin` returns to its top of loop, calls `check_interrupt`:

- Effective `mip = cpu.csr.mip | (clint.MTIP << 7) | (plic.SEIP << 9)`. SEIP bit is set.
- `pending_enabled = mip & mie`. Assume `mie.SEIE = 1`. SEI passes.
- Walk `INTERRUPT_PRIORITY_ORDER`: MEI=11 not pending; MSI not pending; MTI not pending; **SEI=9 IS pending+enabled**.
- Delegation: `mideleg.SEI = 1`, current ≠ M, so target = S.
- Deliverability: current = S, target = S → consult `sstatus.SIE`. Since the SIE window is open, SIE = 1 → deliverable.

Fires `enter_interrupt(9, cpu)`:

- `sepc = cur_pc` (the wfi).
- `scause = (1 << 31) | 9 = 0x80000009`.
- `stval = 0`.
- `mstatus.SPP = 1` (was S — scheduler).
- `mstatus.SPIE = 1`, `mstatus.SIE = 0`.
- `cpu.privilege = S` (already was).
- `pc = stvec`.

The `stvec` for the SIE window is `s_kernel_trap_entry` (the alternate entry that doesn't try to swap satp or sp).

**Topics:** [csrs-traps-and-privilege](#csrs-traps-and-privilege), [devices-uart-clint-plic-block](#devices-uart-clint-plic-block).

---

## Hop 3: `s_kernel_trap_entry` claims the source

`s_kernel_trap_entry` saves callee-saved regs to the scheduler's stack. Calls `s_kernel_trap_dispatch` (or similar). Dispatcher:

- `scause` has bit 31 set; cause = 9 (S external interrupt).
- Calls `plic.claim()`. Walks PLIC sources, picks priority-leader: source 10. Atomically clears `plic.pending bit 10`. Returns 10.
- Calls `uart.isr()`.

`uart.isr` reads `uart.RBR` (offset 0) until empty, calling `console.feedByte(b)` for each byte. For our 'c': drains it. FIFO empty → `plic.deassertSource(10)` (level-triggered: source 10 stays asserted as long as FIFO has data; now it doesn't, so deassert).

Calls `plic.complete(10)` (kernel-side write to PLIC complete register).

**Topics:** [devices-uart-clint-plic-block](#devices-uart-clint-plic-block), [console-and-editor](#console-and-editor).

---

## Hop 4: `console.feedByte` echoes and buffers

`feedByte('c')`:

- Cooked mode. Not a control char.
- Append to input_buf at index `e`. `e++`.
- Echo: `uart.putByte('c')` → THR → host stdout → user sees 'c' on screen.

The buffer hasn't been committed yet (no `\n` seen). The shell's `read` is still sleeping.

`feedByte` returns. ISR returns. Dispatcher returns. `s_kernel_trap_entry` restores callee-saved regs, `sret`s. CPU resumes the scheduler's wfi point.

**Topics:** [console-and-editor](#console-and-editor).

---

## Hops 5-N: bytes 'a', 't', ' ', '/', 'e', 't', 'c', '/', 'm', 'o', 't', 'd'

Each repeats Hops 1-4. Each time:
- `pump.drainOne` pushes one byte.
- PLIC fires; SEI; trap; uart.isr; feedByte appends + echoes.
- The user sees `cat /etc/motd` appear character-by-character on screen.

After 14 such cycles (`c`, `a`, `t`, ` `, `/`, `e`, `t`, `c`, `/`, `m`, `o`, `t`, `d`, `\n`), the buffer holds the 14-byte line.

The 14th byte is `\n`. This time `feedByte`:
- Append '\n', echo '\n'.
- Commit the line: `w = e`.
- `wakeup(&input_buf)` — wakes any sleeping reader.

**Topics:** [console-and-editor](#console-and-editor).

---

## Hop ~16: Shell wakes up

Shell was sleeping in `console.read` on `&input_buf`. It's now Runnable. Eventually scheduler picks it. `swtch` into shell.

Shell's `console.read` re-checks the loop condition: `r != w` (line is committed). Copies bytes from `input_buf[r..w]` to user buffer. Advances `r`. Returns 14 bytes.

**Topics:** [processes-fork-exec-wait](#processes-fork-exec-wait), [console-and-editor](#console-and-editor).

---

## Hop ~17: Shell tokenizes & forks

Shell's `main` loop processes the line `cat /etc/motd\n`:

1. Tokenize: `["cat", "/etc/motd"]`.
2. Not a builtin (cd, pwd, exit).
3. No redirects.
4. Fork.

`fork` is syscall #220 → `sys_fork(p)`:

- `proc.alloc()` finds Unused slot 1 (PID 2). Marks Embryo.
- `vm.copyUvm(parent.pt, child.pt, parent.sz)` walks every L0 PTE, allocates a fresh page in child, memcopies, mapPages.
- Copy trap frame. Set child's `a0 = 0`.
- Copy fd table (refcount++ on each File).
- Copy cwd.
- `state = .Runnable`.
- Return child's PID (= 2) to parent.

Parent's `a0 = 2`. Child's `a0 = 0`. Both Runnable.

**Topics:** [processes-fork-exec-wait](#processes-fork-exec-wait).

---

## Hop ~18: Scheduler swtches to child; child execs cat

Eventually the scheduler picks PID 2 (the child). swtch → child resumes after fork in user space. Child's code:

```zig
if (pid == 0) {
    const argv = [_]?[*:0]const u8{ "cat", "/etc/motd", null };
    _ = execve("/bin/cat", &argv, null);
    _ = exit(127);
}
```

`execve` is syscall #221 → `sys_execve`:

1. `namei("/bin/cat", cwd)` walks `/`, `bin`, `cat` → inode 5 (a File). Each step: `dirlookup` reads the directory's contents (via `readi` → `bmap` → `bread`).
2. Allocate kernel scratch buffer (64 KB on the kernel stack or a page).
3. `inode.readi(inode_5, scratch_buf, 0, 64KB)` reads the cat ELF (~4 KB). Reads happen via bufcache; bufcache may need to fault block 9 (or wherever cat's data lives) from disk.
4. Now hop into a sub-walkthrough...

**Topics:** [filesystem-internals](#filesystem-internals), [shell-and-userland](#shell-and-userland).

---

## Sub-hop 18a: A bufcache miss → block IRQ

Suppose cat's data block isn't in the bufcache. `bread(9)`:

- `bget(9)` finds an Unused (or LRU) buffer, marks LOCKED, sets `block_id = 9`, `valid = false`.
- Returns the buf.
- `bread` sees `!valid`, calls `block.submit(9, &buf.data, .Read)`.
- `block.submit` writes SECTOR=9, BUFFER_PA=&buf.data, CMD=1 to the MMIO block device.
- The CMD-byte-0xB write triggers `block.performTransfer`. Reads 4 KB from `shell-fs.img` host file at offset 9 * 4096. Copies into RAM at &buf.data. Sets STATUS = Ready, `pending_irq = true`.
- `bread` calls `proc.sleep(&block.req)`. Process sleeps.

Next instruction: `cpu.step` services `pending_irq`, asserts PLIC source 1.

`check_interrupt` fires SEI again. Trap. `s_trap_entry` (this time the user-process variant, since cat is what was running), saves regs, calls dispatch. Dispatch sees scause = (1<<31)|9. Calls `block.isr()`. block.isr finds the request, marks complete, `wakeup(&block.req)`.

Trap returns. Cat is woken. Scheduler eventually picks it. `bread` continues: `valid = true` (the data's there). Read the bytes. Continue exec.

**Topics:** [filesystem-internals](#filesystem-internals), [devices-uart-clint-plic-block](#devices-uart-clint-plic-block).

---

## Hop 18b: exec finishes building child

5. `elfload.load` walks PT_LOAD segments in scratch. For each: allocate pages, copy bytes, install PTEs in the new page table.
6. Allocate one more page for the new user stack at `0x7FFFF000`.
7. `copyUserStack` builds the System-V argv tail: argc=2, argv0_ptr → "cat\0", argv1_ptr → "/etc/motd\0", NULL, env NULL.
8. Atomically swap: free old page table, install new one. Update `p.sz`. Update trapframe: `sepc = entry`, `sp = stack_top`, `a0 = argc`.
9. Return.

When `s_trap_entry` exits, `sret` lands in cat's `_start` at the new entry.

**Topics:** [kernel-boot-and-syscalls](#kernel-boot-and-syscalls), [memory-and-mmio](#memory-and-mmio), [shell-and-userland](#shell-and-userland).

---

## Hop ~19: cat runs

`_start` reads argc=2, argv. Calls `main(2, ["cat", "/etc/motd"])`.

cat's main:

```zig
fn main(argc, argv) i32 {
    if (argc <= 1) cat_fd(0);
    else {
        var i: u32 = 1;
        while (i < argc) : (i += 1) {
            const fd = openat(AT_FDCWD, argv[i], O_RDONLY);
            if (fd < 0) continue;
            cat_fd(fd);
            close(fd);
        }
    }
    return 0;
}
```

`openat(AT_FDCWD, "/etc/motd", O_RDONLY)`:

- Syscall #56. `sys_openat`:
  - `namei("/etc/motd", cwd)` — walk `/`, `etc`, `motd` → inode 9 (File, size 19, addrs[0] = some block).
  - `file.alloc(.Inode, ...)` — allocate File slot, set `ip = inode 9`, `off = 0`.
  - Find first free fd in `p.ofile` (= 3). Install. Return 3.

`cat_fd(3)`:

```zig
var buf: [512]u8 = undefined;
while (true) {
    const n = read(3, &buf, 512);
    if (n <= 0) break;
    write(1, &buf, n);
}
```

`read(3, ...)`:

- Syscall #63. `sys_read`:
  - Look up fd 3 → File of type Inode, ip = inode 9, off = 0.
  - `inode.readi(ip, scratch, 0, 512)`.
  - `bmap(ip, 0, false)` → returns the disk block of inode 9's data (some block in the 7..1024 range).
  - `bread(blk)` — bufcache hit (we just loaded it for the exec; or miss → block IRQ → ...).
  - Copy 19 bytes to scratch (file size is 19). Update File.off += 19. Return 19.
- Sys_read returns 19.

`write(1, &buf, 19)`:

- Syscall #64. `sys_write`:
  - fd 1 → File of type Console.
  - setSum(); for each of 19 bytes, `console.putByte(byte)` → UART THR. The host stdout sees `hello from phase 3\n`.
  - clearSum(); return 19.

`read(3, ...)` again:

- `readi(ip, scratch, 19, 512)`. `bmap(ip, 0, false)` → block. `bread`. But File.off (19) >= ip.size (19) → no bytes to read. Return 0.

`cat_fd` exits the loop. `close(3)` → fd 3 freed → File refcount drops → if 0, iput on inode 9. (refcount might still be > 0 if someone else has it open, but here it was just us; iput triggers but nlink > 0, so no itrunc.)

Cat's main returns 0. `_start` calls exit(0).

**Topics:** All six Phase 3 topics.

---

## Hop ~20: cat exits, shell reaps

`exit(0)` → syscall #93 → `sys_exit(p, 0)` → `proc.exit(p, 0)`:

- Reparent children (none).
- `wakeup(p.parent)` — wake up the shell.
- Mark Zombie. xstate = 0.
- Yield.

Scheduler picks shell. Shell's `wait4(child, ...)`:

- Loop ptable for a Zombie child of shell. Find it.
- Copy xstate to user buffer. Free the slot (`proc.free`). Return PID.

Shell's `main` loop iterates. Print `$ ` prompt. Block in `read(0, ...)`.

**Topics:** [processes-fork-exec-wait](#processes-fork-exec-wait).

---

## Hops 21+: Hops 1-N for `exit\n`

The remaining `--input` bytes (`exit\n`) come through the same sequence: pump → PLIC → trap → ISR → feedByte (echo + buffer + commit on \n) → shell read returns. Shell sees `exit`. Builtin: shell exits 0.

`init_shell`'s `wait4` returns. Status 0 → init exits 0. PID 1 exit → kernel halts.

End of session. The user has seen:

```
$ cat /etc/motd
hello from phase 3
$ exit
ticks observed: N
```

(The "ticks observed" is printed by init at exit.)

---

## What you just witnessed

That was *every* major subsystem of `ccc` in action:

- [rv32-cpu-and-decode](#rv32-cpu-and-decode): every instruction executed.
- [memory-and-mmio](#memory-and-mmio): every MMIO access (UART, PLIC, block) + every Sv32 walk.
- [csrs-traps-and-privilege](#csrs-traps-and-privilege): SEI traps, ecall traps, sret returns. ~15+ trap entries total.
- [devices-uart-clint-plic-block](#devices-uart-clint-plic-block): UART RX, PLIC routing, block I/O.
- [kernel-boot-and-syscalls](#kernel-boot-and-syscalls): syscall ABI, trap dispatch, swtch.
- [processes-fork-exec-wait](#processes-fork-exec-wait): fork, exec, wait, exit cycle.
- [filesystem-internals](#filesystem-internals): namei, readi, bmap, bufcache.
- [console-and-editor](#console-and-editor): cooked-mode line discipline.
- [shell-and-userland](#shell-and-userland): shell loop, tokenize, fork+exec.

About 30 distinct privilege transitions. About 5 disk reads (each potentially via block IRQ). About 30 user-visible bytes printed.

If you can hold this trace in your head, you understand `ccc` end to end.
