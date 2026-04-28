# kernel-boot-and-syscalls: In-Depth Analysis

## Introduction

We've spent four topics on hardware. Now we *use* it. The kernel is the layer that takes a freshly booted CPU and turns it into something programmable: page tables built, devices initialized, syscalls dispatched, processes scheduled.

Phase 2 of `ccc` covers Plans 2.A–2.D — the bare-metal kernel. By the end of Phase 2, `zig build e2e-kernel` boots `kernel.elf`, runs a U-mode program that calls `write()`, prints `hello from u-mode`, and observes `ticks observed: N` from the timer. This topic is about how that one demo works end to end: M-mode boot shim, S-mode kernel entry, page-table bootstrap, trap dispatcher, syscall ABI, context switch.

Source files: `src/kernel/{boot.S, kmain.zig, vm.zig, trap.zig, trampoline.S, syscall.zig, swtch.S, sched.zig}`.

---

## Part 1: M-mode boot — `boot.S`

The CPU starts at `RAM_BASE = 0x80000000` in M-mode, with no paging, no interrupts, regs zero. `boot.S` is the very first code that runs. Its job:

1. Set up the kernel's stack pointer (`sp`) — temporary, in BSS.
2. Set `mtvec` to the M-mode trap vector (a tiny hand-written ISR for MTI forwarding).
3. Set up trap delegation (`medeleg` for sync exceptions, `mideleg` for async).
4. Configure the CLINT for the first timer interrupt.
5. Hand off to S-mode by setting `mepc = kmain` and `mret`.

The trick at step 5: `mret` pops the privilege from `mstatus.MPP`, which the boot code pre-set to S. The CPU lands at `kmain` (in `kmain.zig`) running in S-mode.

`boot.S` is small — a couple dozen lines of asm. It's the only code that runs in M-mode during normal execution. After `mret`, M-mode is only re-entered for the timer ISR (which forwards MTI to SSIP, then `mret`s back).

### The MTI → SSIP forwarder (`mtimer.S`)

The M-mode timer ISR's job is to keep the timer interrupt alive *and* notify the S-mode kernel. It:

1. Pushes mtimecmp far into the future (so MTI doesn't immediately re-fire).
2. Sets `mip.SSIP = 1` (software-set bit; routes to S since `mideleg.SSI = 1`).
3. `mret`.

After `mret`, the CPU is back in S (or U, wherever it was). `cpu.check_interrupt` immediately sees `mip.SSIP & sie.SSIE` pending+enabled+deliverable → fires `enter_interrupt(1, cpu)` → trap to S. The kernel's S-mode trap handler treats SSI as "timer tick from M."

This MTI-to-SSIP indirection means the kernel never has to leave S-mode for normal timer handling — clean, no M↔S round-trips. The only M-mode entry per tick is the brief forwarder.

---

## Part 2: S-mode entry — `kmain`

`kmain.zig`'s `kmain` runs once per boot, in S-mode. It:

1. **Initializes the page allocator.** `page_alloc.zig` is a free-list of 4 KB pages. `kmain` gives it the range `[end_of_kernel, RAM_END)` — every byte not used by the kernel image.
2. **Builds the kernel page table.** Identity-maps the kernel text/data, the trampoline page, the device MMIO regions. Maps a kernel stack at high memory.
3. **Sets `satp`** to enable Sv32 with this root table. `sfence.vma` (no-op in `ccc`) for spec compliance.
4. **Sets `stvec`** to the trampoline's `s_trap_entry`. Trap routing now works for U→S faults.
5. **Allocates PID 1.** The first user process. Builds its page table, copies the user-program code in, sets up its trap frame.
6. **Calls `sched.init()`** which sets up the scheduler context.
7. **Calls `sched.schedule()`** which `swtch`'s into the scheduler's context loop.

After step 7, `kmain` never returns. The scheduler runs forever, picking processes and `swtch`-ing into them.

### What's the trampoline?

A page mapped at the same VA in *every* address space. It contains `s_trap_entry` (and `s_kernel_trap_entry`). Why? Because when a trap fires, the kernel needs to immediately access trap-handling code — but that code shouldn't depend on any specific page table being installed. By having the trampoline mapped identically everywhere, `stvec` can point to it and the trap handler can begin execution before swapping page tables.

`ccc`'s trampoline is a single 4 KB page. The kernel maps it identity into the kernel page table; every user page table also maps it (read+execute, kernel-only).

---

## Part 3: The trap dispatcher — `trap.zig`

When a U-mode program does `ecall`, the CPU traps to S, lands at `stvec` = `s_trap_entry` (in `trampoline.S`). `s_trap_entry`:

1. **Saves the user's registers** into the per-process trap frame (allocated in the process struct, mapped at a fixed VA).
2. **Switches to the kernel page table** by writing `satp`.
3. **Switches to the kernel stack** by reading the per-process kstack pointer.
4. **Calls `s_kernel_trap_dispatch`** in `trap.zig`.

`s_kernel_trap_dispatch` is the kernel's "what kind of trap was this?" decoder:

```zig
pub fn dispatch(...) void {
    const cause = read scause;
    if (cause & (1 << 31) != 0) {
        // Async interrupt
        const code = cause & 0x7FFFFFFF;
        switch (code) {
            1 => /* SSI: timer tick */,
            5 => /* STI: not used */,
            9 => /* SEI: PLIC claim, dispatch device ISR */,
            else => panic,
        }
    } else {
        // Sync exception
        switch (cause) {
            8 => /* ECALL_U: dispatch syscall */,
            12, 13, 15 => /* page fault: kill process or signal */,
            2 => /* illegal: kill */,
            else => panic,
        }
    }
}
```

After dispatch, the handler returns. `s_trap_entry`'s tail:

5. **Restore user regs** from the trap frame.
6. **Switch back to the user page table** via `satp`.
7. **`sret`** — pops privilege, jumps to `sepc`.

The user resumes at the instruction after `ecall`. (The dispatcher must have done `sepc += 4` for ecalls; for page faults, `sepc` is left alone so the instruction can re-execute after the kernel maps the page.)

---

## Part 4: The syscall ABI

`ccc` follows the standard RISC-V Linux ABI:

- **`a7`** holds the syscall number.
- **`a0..a5`** hold up to 6 arguments.
- **`a0`** holds the return value (or negative errno on error).

`syscall.zig` has a giant switch:

```zig
pub fn dispatch(p: *Process) void {
    const syscall_num = p.trapframe.a7;
    p.trapframe.a0 = switch (syscall_num) {
        64 => sys_write(p),   // write(fd, buf, len)
        93 => sys_exit(p),    // exit(status)
        124 => sys_yield(p),  // yield()
        172 => sys_getpid(p), // getpid()
        214 => sys_sbrk(p),   // sbrk(incr)
        220 => sys_fork(p),   // fork()
        221 => sys_execve(p), // execve(path, argv, envp)
        260 => sys_wait4(p),  // wait4(pid, &status, options, &rusage)
        56  => sys_openat(p), // openat(dirfd, path, flags, mode)
        57  => sys_close(p),  // close(fd)
        63  => sys_read(p),   // read(fd, buf, count)
        62  => sys_lseek(p),
        80  => sys_fstat(p),
        49  => sys_chdir(p),
        17  => sys_getcwd(p),
        34  => sys_mkdirat(p),
        35  => sys_unlinkat(p),
        else => -1,           // ENOSYS
    };
    // sepc += 4 so the user resumes past ecall
    p.trapframe.sepc += 4;
    // Check kill flag — if set, exit instead of returning
    if (p.killed) proc.exit(p, 1);
}
```

Each `sys_*` reads its arguments from the trap frame, does its thing, returns the result. The dispatcher stores it back into `a0`.

### Reading user pointers — `SSTATUS.SUM`

When `sys_write` needs to copy `len` bytes from the user's buffer at `a1` to UART:

1. The user pointer is a *user* virtual address. The kernel's page table doesn't map user pages.
2. The user's page table *does* map them, with U=1.

The kernel's `satp` is currently the kernel's page table (we switched at `s_trap_entry`). So a direct load from `a1` would page-fault (U=1, kernel privilege ≠ U).

The fix: the kernel sets `mstatus.SUM = 1` before reading user pointers. SUM ("Supervisor User Memory") allows S-mode loads/stores to U-pages. After the read, SUM is cleared.

But wait — we switched `satp` to the kernel's page table at `s_trap_entry`. The user's page table isn't installed. How does the kernel even *find* the user's pages?

Answer: `s_trap_entry` *doesn't always* swap page tables. In `ccc`'s setup, the kernel page table identity-maps user RAM regions too (via `vm.copyUvmIntoKernel` or similar). Or the kernel inspects the user's page table by walking it manually. (The exact approach varies by codebase; check `src/kernel/syscall.zig` for the actual pattern.)

`ccc`'s `sys_write` uses `setSum`/`clearSum` helpers (`csrs sstatus, ...` and `csrc sstatus, ...`) around the user-pointer access.

---

## Part 5: Context switch — `swtch.S`

When the scheduler picks a different process, it has to save the current process's kernel state and restore the next one's. `swtch.S` is 14 instructions:

```
swtch:
    sw ra, 0(a0)
    sw sp, 4(a0)
    sw s0, 8(a0)
    ...
    sw s11, 52(a0)
    ; Now load from new context (a1)
    lw ra, 0(a1)
    lw sp, 4(a1)
    lw s0, 8(a1)
    ...
    lw s11, 52(a1)
    ret
```

The function's signature: `swtch(old_ctx: *Context, new_ctx: *Context)`. It saves `ra`, `sp`, `s0..s11` (the *callee-saved* registers, per the RV calling convention) into `old_ctx`, then loads them from `new_ctx`. The `ret` at the end pops the new `ra` into PC — and the next instruction executes is wherever the new context was suspended.

Why only callee-saved? Because the *caller* of `swtch` (in our case, `sched.schedule` or `sys_yield`) is responsible for preserving caller-saved regs across the call already. `swtch` only needs to handle the regs that survive a function call.

This is **cooperative** in form — `swtch` is a function call. The scheduler invokes it on behalf of the current process. From the process's view, `swtch` "took a long time to return" — long enough for many other processes to have run.

---

## Part 6: The scheduler — `sched.zig`

`sched.zig` is short — ~110 lines. The scheduler's main loop:

```zig
pub fn schedule() noreturn {
    while (true) {
        for (&proc.ptable) |*p| {
            if (p.state != .Runnable) continue;
            p.state = .Running;
            current_proc = p;
            swtch(&sched_ctx, &p.ctx);
            // p has yielded back; loop continues
            current_proc = null;
        }
        // No runnable proc; idle
        wfi_with_sie_window();
    }
}
```

(Pseudocode — actual code has more bookkeeping.)

When a process `swtch`'s out (via `yield` or because it traps), control returns to the scheduler's `swtch` call site, which loops to find the next Runnable.

If no process is runnable (all blocked/sleeping), the scheduler executes `wfi`. The SIE window pattern from [csrs-traps-and-privilege](#csrs-traps-and-privilege) ensures the wfi can be interrupted by device IRQs.

---

## Part 7: The "first ever U-mode write"

Putting it all together, the Phase 2 §Definition of Done:

```
$ zig build kernel && zig build run -- zig-out/bin/kernel.elf
hello from u-mode
ticks observed: 19
```

What happens:

1. Boot. M-mode `boot.S` runs.
2. `mret` → S-mode at `kmain`.
3. `kmain` builds page tables, allocates PID 1, copies the user program into PID 1's address space.
4. `sched.schedule()` picks PID 1, `swtch`'s into it, which `sret`s into U-mode.
5. PID 1's `_start` calls `write(1, "hello from u-mode\n", 18)`.
6. `write` is a `usys.S` stub: `li a7, 64; ecall; ret`.
7. `ecall` traps to S. `s_trap_entry` saves user regs, switches to kernel pt + kstack, calls dispatch.
8. Dispatch sees scause = 8 (ECALL_U), calls `sys_write`.
9. `sys_write` sets SUM, copies 18 bytes from user buffer to UART (via `console.write`), clears SUM, returns 18.
10. Dispatch advances `sepc += 4`, checks killed flag, returns.
11. `s_trap_entry` restores user regs, sets satp to user pt, `sret`s.
12. PID 1 returns from `write`, calls `yield` (so the timer can run), eventually calls `exit(0)`.
13. Timer fires repeatedly during this; each MTI → MTI ISR → SSIP → S-trap → tick counter++. The kernel prints `ticks observed: N` when PID 1 exits.

That's the bridge from "raw CPU" to "running user program with system calls." Everything from here on is more code, not more concepts.

---

## Summary & Key Takeaways

1. **Boot starts in M-mode at `RAM_BASE`.** `boot.S` sets up CSRs and `mret`s into S-mode at `kmain`.

2. **`kmain` is the kernel's main.** Builds page tables, sets `satp` and `stvec`, allocates PID 1, hands off to scheduler.

3. **The trampoline is a per-address-space-mapped page** containing `s_trap_entry`. Lets trap handlers run before page tables swap.

4. **`s_trap_entry` is asm.** Saves user regs, swaps satp + sp, calls C/Zig dispatcher, restores, `sret`s.

5. **Trap dispatch decodes scause.** Bit 31 distinguishes async from sync; remaining bits give the cause.

6. **Syscall ABI: `a7` = number, `a0..a5` = args, `a0` = return.** `sepc += 4` after ecall before sret.

7. **`SSTATUS.SUM` lets the kernel read user pages.** Set, read, clear. Fetch is never affected by SUM.

8. **`swtch.S` is 14 instructions.** Saves callee-saved kernel regs into old `Context`; loads from new. Returns into the new context's `ra`.

9. **The scheduler is a `for (&ptable) |p|` loop.** Picks a Runnable, `swtch`'es in. On no-runnable, `wfi` with the SIE window.

10. **MTI is forwarded by M to S as SSIP.** Lets the kernel handle timer ticks in S-mode without M↔S round-trips per tick.
