# processes-fork-exec-wait: In-Depth Analysis

## Introduction

In Phase 2, the kernel ran exactly one user process. That's a useful starting point — it proves the trap path and syscall ABI work — but it's not an OS. An OS has *many* processes, switching between them, creating new ones, cleaning up old ones. Phase 3.B–3.C of `ccc` adds that.

This topic covers `src/kernel/{proc.zig, sched.zig}` plus the `swtch.S` introduced in [kernel-boot-and-syscalls](#kernel-boot-and-syscalls). The four classic Unix syscalls — **fork**, **exec**, **wait**, **exit** — are the API. Plus a kill flag for `^C` semantics.

By the end of Phase 3.C, `kernel-fork.elf` boots, PID 1 (`init`) forks, the child execs `/bin/hello` and prints, and the parent reaps. The full Phase 3.D+E shell extends this to "fork+exec the user's typed command, wait, repeat."

---

## Part 1: The `Process` struct

`proc.zig` defines:

```zig
pub const Process = extern struct {
    state: State,                 // Unused / Embryo / Sleeping / Runnable / Running / Zombie
    pid: u32,                     // 1-based; 0 = unallocated slot
    parent: ?*Process,            // for wait4 + reparenting
    sz: u32,                      // user heap size in bytes (sbrk)
    pagetable: ?*[1024]u32,       // L1 root PA → page table
    kstack: u32,                  // virtual address of the kernel stack page
    trapframe: ?*Trapframe,       // user-regs save area (mapped in user pt too)
    ctx: Context,                 // callee-saved kernel regs + ra + sp
    chan: ?*anyopaque,            // sleep channel; non-null iff state == Sleeping
    killed: bool,                 // set by proc.kill, checked on syscall return
    xstate: i32,                  // exit code, populated by exit
    name: [16]u8,                 // for debug
    ofile: [NOFILE]?*File,        // 16-deep open-file table
    cwd: ?*Inode,                 // current working dir
    cwd_path: [CWD_PATH_MAX]u8,   // cached absolute path string
    cwd_path_len: u32,
};
```

The `ptable[NPROC=16]` array of these is statically allocated. `pid = 0` marks "unused"; PIDs 1..16 correspond to slots 0..15 with `pid = slot_idx + 1`.

State transitions:

```
Unused → Embryo → Runnable ⇄ Running → Zombie → Unused
                          ↘ Sleeping ↗
```

- **Embryo** is the brief window between `proc.alloc` (allocated slot) and `proc.exec`/`proc.fork` filling in the address space + trap frame. Only `proc.alloc` and the very next setup code see this state.
- **Runnable** = "schedulable; will run on next pick."
- **Running** = "currently on the CPU."
- **Sleeping** = "blocked on a channel pointer; `wakeup(chan)` will return it to Runnable."
- **Zombie** = "exited, but parent hasn't `wait`ed yet. Slot held until reaped."

---

## Part 2: The page allocator (`page_alloc.zig`)

Before processes can have address spaces, the kernel needs a page allocator. `ccc`'s is a simple **free list**:

```zig
pub fn alloc() ?u32   // returns physical address of a 4 KB page, or null
pub fn free(pa: u32) void
pub fn freeCount() u32
```

Internally, free pages are linked through their first 4 bytes: `*(u32*)pa = next_free_pa; free_head = pa`. The kmain initialization adds `[end_of_kernel_image, RAM_END)` in 4 KB chunks.

Allocator panics if `alloc` is called when free list is empty (`ccc` doesn't OOM-recover at this layer; high-level callers like `copyUvm` do).

---

## Part 3: `fork` — the photocopier

`sys_fork` calls `proc.fork(parent)`. It:

1. **Allocate a new slot.** `proc.alloc` finds an Unused slot, sets it to Embryo.
2. **Copy the address space.** `vm.copyUvm(parent.pagetable, child.pagetable, parent.sz)` walks every L0 PTE in the parent, allocates a fresh page in the child, copies the bytes, installs the same VA→new-PA mapping. Permissions copied verbatim.
3. **Copy the trap frame.** Child's regs == parent's regs at the moment of fork.
4. **Set child's `a0 = 0`.** This is how the child distinguishes "I'm the child" — its return value from `fork` is 0, while the parent gets the child's PID.
5. **Copy fd table.** Each fd in `parent.ofile[i]` is `file.dup`-ed (refcount++) into `child.ofile[i]`.
6. **Copy cwd.** `child.cwd = file.idup(parent.cwd)`.
7. **Set `parent`, `name`.**
8. **Mark Runnable.** Now eligible for scheduling.
9. **Parent returns child's PID.**

The child's `a0 = 0` trick is RISC-V/Linux-style fork. It avoids needing a separate "am I the child?" register — same syscall, two return values, depending on which process is reading them.

### `copyUvm` — and OOM rollback

`copyUvm` is the heavy lifter. For each page:

```zig
for (vpn = 0; vpn < parent.sz / PAGE_SIZE; vpn++) {
    const parent_pa = vm.walk(parent.pt, vpn * PAGE_SIZE).?;
    const child_pa = page_alloc.alloc() orelse {
        // OOM: roll back everything we've done
        vm.unmapUser(child.pt, 0, vpn * PAGE_SIZE);
        // free the L0 tables we allocated
        return error.OutOfMemory;
    };
    @memcpy(@as([*]u8, @ptrFromInt(child_pa))[0..PAGE_SIZE], @as([*]u8, @ptrFromInt(parent_pa)));
    vm.mapPages(child.pt, vpn * PAGE_SIZE, PAGE_SIZE, child_pa, /* perms */);
}
```

The OOM rollback is the messy part. If we've already mapped 100 pages and the 101st can't be allocated, those 100 pages must be unmapped *and* freed (otherwise we leak). `unmapUser` walks the partial table and frees each PTE's PA via `page_alloc.free`. Then we free the L0 tables themselves. Then the L1 root.

Getting this right took effort. The integration point is `proc.copyUserStack` for the `argv` tail; `vm.unmapUser` for the rollback path. See `tests/e2e/fork.zig` for the OOM-resilience proof.

---

## Part 4: `execve` — replacing in place

`sys_execve(path, argv, envp)` calls `proc.exec(p, path, argv)`. It:

1. **Resolve the path.** `namei(path)` returns an inode (`/bin/hello` → its inode).
2. **Load the ELF into a kernel scratch buffer.** `inode.readi(ip, kbuf, 0, 64KB)`.
3. **Build a fresh address space.** New page table; walk the ELF's `PT_LOAD` segments; for each, allocate pages, copy bytes, set permissions.
4. **Set up the user stack.** Allocate one page at a high VA. Copy argv strings into it. Build the System-V argv tail layout (argc, argv0_ptr, ..., NULL, env0_ptr, ..., NULL).
5. **Atomic swap.** Replace `p.pagetable` with the new one; free the old one entirely. Update `p.sz`. Update `p.trapframe.sepc = entry`, `p.trapframe.sp = stack_top`, and `p.trapframe.a0 = argc`.
6. **Return.**

When the kernel `sret`s after the syscall, the user resumes at the *new* program's entry, with the fresh stack and a fresh address space. The old program is gone.

The "atomic swap" step is critical: until `pagetable` is reassigned, the old page table is the live one. If something fails before that (file too big, malformed ELF, OOM), the old image continues — the `exec` syscall returns -1.

### The argv tail

System-V says argv lives at the top of the user stack as:

```
high addr
   ...
[ envp[N] = NULL ]
[ envp[N-1] (ptr to env string) ]
   ...
[ envp[0] (ptr to env string) ]
[ argv[N] = NULL ]
[ argv[N-1] (ptr to "arg N-1") ]
   ...
[ argv[0] (ptr to program name) ]
[ argc ]    <-- sp points here
   ...
low addr (heap grows up from here)
```

The user's `_start` (in `start.S`) reads argc from `*sp`, argv from `sp + 4`, calls `main(argc, argv)`. `ccc`'s exec builds this layout in the new stack page before swapping.

---

## Part 5: `wait4` and `exit`

`sys_exit(status)` calls `proc.exit(p, status)`:

1. **Reparent children.** For each Process whose parent is `p`, set `parent = init` (PID 1).
2. **Wakeup `init`.** `wakeup(init)` — in case init was waiting on its (newly-adopted) children.
3. **Wakeup `p.parent`.** So `wait4` returns.
4. **Mark Zombie.** `p.state = .Zombie`. `p.xstate = status`.
5. **Yield.** Scheduler picks something else.

The exited proc's resources are *not* freed yet. The slot is held in Zombie state until `wait4` reaps it.

`sys_wait4(pid, &status, ...)`:

1. **Disable interrupts** (lock the ptable).
2. **Loop:** scan for any child of `p` (or the specific PID) that's `.Zombie`.
3. **If found:** copy `xstate` to user, free the child's slot (`proc.free`), return the PID. Re-enable interrupts.
4. **If not found, but children exist:** sleep on `p` (channel = self). Some child's exit will wake us.
5. **If no children at all:** return -1 (ECHILD). Re-enable interrupts.

The sleep-on-self pattern is elegant: any child's exit wakes the parent, who re-checks. No need for explicit signals or pipes between the two.

---

## Part 6: The `killed` flag and `^C`

How does `^C` kill a foreground process? `console.feedByte(0x03)` is the entry point:

1. Console reads `^C` from the line discipline.
2. Calls `proc.kill(fg_pid)`.
3. `kill` sets `target.killed = true`. If target is Sleeping, also makes it Runnable so it can wake up to die.
4. The next time the target returns from a syscall, `syscall.dispatch` checks `p.killed` and calls `proc.exit(p, 1)` instead of returning normally.

This is a soft kill — the target finishes its current syscall (or wakes from its sleep), and only then dies. There's no asynchronous async safety problem because the kill flag is checked at well-defined points.

`tests/e2e/cancel.zig` proves this works: pipe `cat\n\x03exit\n` and assert `cat\n^C\n$ exit` appears in stdout.

---

## Part 7: The scheduler

`sched.schedule` is the loop:

```zig
pub fn schedule() noreturn {
    while (true) {
        var found = false;
        for (&proc.ptable) |*p| {
            if (p.state != .Runnable) continue;
            p.state = .Running;
            cpu.proc = p;
            swtch(&cpu.scheduler_ctx, &p.ctx);
            cpu.proc = null;
            found = true;
        }
        if (!found) idle_with_sie_window();
    }
}
```

Round-robin: walk the ptable, swtch into every Runnable in order. When a process yields back (via `yield`, `exit`, or a trap that ends in scheduling), the inner loop continues to the next.

When no process is Runnable (e.g., all are sleeping on disk I/O), enter the SIE-window `wfi` so a device IRQ can wake one.

### `yield`

`yield()` is just:

```zig
pub fn yield() void {
    const p = cur();
    p.state = .Runnable;
    swtch(&p.ctx, &cpu.scheduler_ctx);
}
```

Mark self Runnable, swtch into the scheduler. The scheduler's loop will swtch into something *else* (if anything's runnable) before swtch'ing back here later.

### `sleep` and `wakeup`

```zig
pub fn sleep(chan: *anyopaque) void {
    const p = cur();
    p.chan = chan;
    p.state = .Sleeping;
    swtch(&p.ctx, &cpu.scheduler_ctx);
    // ... re-enter here when wakeup'd ...
    p.chan = null;
}

pub fn wakeup(chan: *anyopaque) void {
    for (&proc.ptable) |*p| {
        if (p.state == .Sleeping and p.chan == chan) p.state = .Runnable;
    }
}
```

Channels are just opaque pointers — `&block.req`, the address of an inode's lock, the parent process's address. Wakeup matches on pointer equality. Multiple processes can sleep on the same channel; wakeup wakes them all.

This pattern is xv6-classic. Simple, correct, and slow (linear scan of ptable per wakeup) — but fine for `NPROC = 16`.

---

## Summary & Key Takeaways

1. **Static `ptable[16]`.** No dynamic alloc; PIDs are slot indices. Maxes out at 16 concurrent processes.

2. **Six states.** Unused → Embryo → Runnable ⇄ Running → Zombie → Unused. Plus Sleeping as a side branch.

3. **`fork` photocopies the address space.** `vm.copyUvm` walks parent PTEs, allocates fresh pages in child, copies bytes. OOM rollback unmaps partial work.

4. **`execve` rebuilds in place.** Parse ELF, build new pt, swap atomic. Old image gone, fd/cwd preserved.

5. **`exit` marks Zombie + wakes parent.** Resources held until `wait` reaps. Children reparent to PID 1.

6. **`wait4` sleeps on self.** A child's exit wakes us; we re-scan for a zombie child.

7. **`killed` flag is the soft `^C`.** Set asynchronously; checked on every syscall return.

8. **`swtch` is the only thread-mode change.** The scheduler `swtch`'s into a process; a `yield`/`exit`/`sleep` `swtch`'s back.

9. **Sleep/wakeup uses opaque pointers as channels.** Pointer equality matches. Linear-scan wakeup; fine at small scale.

10. **The argv tail is System-V layout.** argc + argv ptrs + NULL + envp + NULL on the stack at sp.
