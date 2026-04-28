# processes-fork-exec-wait: Code Cases

> Real artifacts that exercise the process subsystem.

---

### Case 1: `init` reaping `/bin/hello` (Plan 3.C, 2026-04)

**Background**

Plan 3.C's deliverable was a working fork+exec+wait+exit cycle. The demo: `init` (PID 1) forks; the child execs `/bin/hello`, which prints `hello from /bin/hello\n` and exits; the parent reaps and prints `init: reaped`.

**What happened**

`src/kernel/user/init.zig`:

```zig
fn main() noreturn {
    const child = fork();
    if (child == 0) {
        const argv = [_]?[*:0]const u8{ "hello", null };
        _ = execve("/bin/hello", &argv, null);
        // execve returned → it failed
        _ = exit(1);
        unreachable;
    }
    // parent
    var status: i32 = 0;
    _ = wait4(child, &status, 0, null);
    _ = printf("init: reaped\n", .{});
    _ = exit(0);
}
```

`zig build kernel-fork && zig build run -- zig-out/bin/kernel-fork.elf` produces:

```
hello from /bin/hello
init: reaped
ticks observed: 3
```

The verifier `tests/e2e/fork.zig` asserts that exact output (modulo the tick count).

**Relevance**

This single test exercises every line of `proc.fork`, `proc.exec`, `proc.exit`, `proc.wait4`. If `copyUvm` leaks a page, run after run shows decreasing free count. If `exec` doesn't free the old image, same. If `wait` doesn't actually reap the slot, subsequent forks fail.

**References**

- `src/kernel/user/init.zig`, `src/kernel/user/hello.zig`
- `src/kernel/proc.zig` (`fork`, `exec`, `wait4`, `exit`)
- `tests/e2e/fork.zig`
- `build.zig` target `e2e-fork`

---

### Case 2: `^C` killing `cat` (Plan 3.F, 2026-04)

**Background**

The Phase 3 §Definition of Done requires "`^C` cancels foreground program." `tests/e2e/cancel.zig` is the proof.

**What happened**

The test pipes 10 bytes through `--input`: `cat\n\x03exit\n`.

1. Shell reads `cat\n`, fork+execs `/bin/cat`. Cat reads stdin (which has 0 bytes left for now), blocks in `console.read`.
2. The next byte from `--input` arrives: `\x03` (Control-C).
3. UART RX → PLIC → console.feedByte → console recognizes 0x03 → calls `proc.kill(fg_pid=2)`.
4. PID 2's `console.read` returns -1 (because `console.read` checks the kill flag).
5. PID 2's syscall handler returns. Dispatch sees `p.killed = true`. Calls `proc.exit(p, 1)`.
6. Shell's `wait` returns. Shell prints `^C\n` echo, then `$ ` prompt.
7. `--input`'s next byte is `e` (start of `exit`). Shell tokenizes `exit\n`, executes the builtin, exits cleanly.

The asserted output:

```
$ cat
^C
$ exit
```

If any step in the kill chain breaks, the test deadlocks (cat never returns) or the output diverges.

**References**

- `src/kernel/proc.zig` (`kill`)
- `src/kernel/console.zig` (`feedByte` → 0x03 arm)
- `src/kernel/syscall.zig` (`p.killed` check after every dispatch)
- `tests/e2e/cancel.zig`

---

### Case 3: The OOM-rollback path in `copyUvm` (Plan 3.B, 2026-04)

**Background**

`vm.copyUvm` walks the parent's PTEs, allocating a fresh page in the child for each. If allocation fails partway through, the child's partial address space must be torn down — otherwise we leak.

**What happened**

When `proc.fork` was first written, the OOM path was:

```zig
fn copyUvm(parent: *PageTable, child: *PageTable, sz: u32) !void {
    for (i = 0; i < sz; i += PAGE_SIZE) {
        const ppa = walk(parent, i).?;
        const cpa = page_alloc.alloc() orelse return error.OutOfMemory; // ← leaks!
        memcpy(cpa, ppa, PAGE_SIZE);
        mapPages(child, i, PAGE_SIZE, cpa, perms);
    }
}
```

A test (`page_alloc_fork_test`) added in Plan 3.B kept forking until OOM. After ~30 iterations, the free count would be much lower than the available pool — leaks were happening.

**The fix** was to track progress and unwind:

```zig
fn copyUvm(parent: *PageTable, child: *PageTable, sz: u32) !void {
    var done: u32 = 0;
    errdefer vm.unmapUser(child, 0, done);   // free pages mapped so far
    while (done < sz) : (done += PAGE_SIZE) {
        const ppa = walk(parent, done).?;
        const cpa = page_alloc.alloc() orelse return error.OutOfMemory;
        memcpy(cpa, ppa, PAGE_SIZE);
        mapPages(child, done, PAGE_SIZE, cpa, perms);
    }
}
```

`unmapUser` walks the partial table, frees each PTE's PA, frees the L0 table pages. The `errdefer` runs only on the error path. After the fix, the test ran indefinitely with stable free count.

**Relevance**

This is a classic OOM-correctness bug. The fix isn't deep code change — it's about making the cleanup path automatic via Zig's `errdefer`. This pattern is used throughout `ccc`'s kernel.

**References**

- `src/kernel/vm.zig` (`copyUvm` + `unmapUser`)
- `src/kernel/proc.zig` (similar pattern in `fork`)

---

### Case 4: The System-V argv layout `execve` builds (Plan 3.E, 2026-04)

**Background**

When `init_shell` does `execve("/bin/sh", argv = ["sh", null], envp = null)`, the kernel must lay out the argv tail on the new user stack precisely so `_start` can parse it.

**What happened**

`proc.exec` allocates one page (`USTACK_VA = 0x7FFFF000` to `0x80000000`), then writes from the top down:

1. **String area:** "sh\0" at `0x80000000 - 3 = 0x7FFFFFFD`.
2. **Align to 4:** down to `0x7FFFFFFC`.
3. **envp[0] = NULL:** at `0x7FFFFFFC`. (envp pointer arr always ends in NULL.)
4. **argv[1] = NULL:** at `0x7FFFFFF8`.
5. **argv[0] = ptr to "sh\0":** at `0x7FFFFFF4`. Value: `0x7FFFFFFD`.
6. **argc = 1:** at `0x7FFFFFF0`. **`sp = 0x7FFFFFF0`.**

`_start` reads:
- `argc = *(int*)sp = 1`.
- `argv = (char**)(sp + 4) = 0x7FFFFFF4`.
- `argv[0]` points to `"sh\0"`.
- `argv[1] = NULL` (terminator).
- `envp = (char**)(sp + 4 + (argc + 1) * 4) = 0x7FFFFFFC`.
- `envp[0] = NULL`.

Then it calls `main(1, argv)`. The user program sees the shell-like argc/argv it expects.

`proc.copyUserStack` is the helper that does this layout. It's careful with: alignment (every pointer is 4-byte aligned), buffer-overflow safety (the page is exactly 4 KB; the layout must fit), and the rollback path on OOM.

**Relevance**

If the layout is wrong by a single 4 bytes, the user's `_start` reads garbage. Symptoms: random crashes, wrong argc, segfaults reading argv[0]. The `tests/e2e/shell.zig` is the regression — it relies on shell programs receiving argv correctly.

**References**

- `src/kernel/proc.zig` (`exec` → `copyUserStack`)
- `src/kernel/user/lib/start.S` (the `_start` that reads argc/argv)
- The RISC-V psABI doc (the "Initial Process Stack" section)

---

### Case 5: The kill-flag check after every syscall dispatch (Plan 3.E, 2026-04)

**Background**

The kill flag is set asynchronously (by another process or interrupt handler). For it to actually kill the target, the target has to *check* it at known safe points. `ccc` checks once: at the end of `syscall.dispatch`.

**What happened**

```zig
pub fn dispatch(p: *Process) void {
    p.trapframe.a0 = switch (syscall_num) { ... };
    p.trapframe.sepc += 4;
    if (p.killed) {
        proc.exit(p, 1);
        // never returns
    }
}
```

That `if` is the entire kill-flag mechanism on the syscall side.

**Why this works**

A process spends 99% of its time either:
- Running user code (no syscall in flight).
- Inside a syscall, possibly sleeping.

For the running case: the next time it does *anything* observable (a syscall), the check triggers.

For the sleeping case: `proc.kill` flips `state` from Sleeping to Runnable, so it wakes up. Whatever syscall it was sleeping inside returns (often with -EINTR or similar — `console.read` returns -1 in `ccc`). The syscall handler returns, dispatch checks `killed`, calls `exit`.

**The corner case**

What if a process is killed while *outside* a syscall — in the middle of a long `for` loop in user space? Nothing happens. The process keeps running. Only when it eventually does a syscall (or takes a trap, e.g., a page fault) does the kill take effect.

This is a deliberate design choice: no preemptive signal delivery. POSIX signals would deliver async, but `ccc` doesn't have signals. The shell-`^C` use case is the main motivator, and shells *always* have a foreground process that's blocked on `read` or busy doing syscalls.

**References**

- `src/kernel/syscall.zig` (the dispatch tail)
- `src/kernel/proc.zig` (`kill`)
- `src/kernel/console.zig` (cooked-mode `^C` handling)

---

### Case 6: The single-process `kernel-multi.elf` test (Plan 3.B, 2026-04)

**Background**

Plan 3.B added the multi-process foundation (free-list page allocator, ptable, scheduler, `swtch`). Before fork existed, the demo had to hand-create two processes at boot.

**What happened**

`kernel-multi.elf` embeds *two* user ELFs (`userprog.elf` and `userprog2.elf`). The `kmain` for this build:

1. Allocates ptable[0] for PID 1, copies `userprog.elf` in.
2. Allocates ptable[1] for PID 2, copies `userprog2.elf` in.
3. Both Runnable. Calls `sched.schedule()`.
4. Scheduler picks PID 1 → runs → yields.
5. Scheduler picks PID 2 → runs → yields.
6. Both alternate, each printing its message.
7. Both exit. Tick count printed. Halt.

`tests/e2e/multiproc.zig` asserts both `hello from u-mode\n` and `[2] hello from u-mode\n` appear in the output. The interleaving order doesn't matter.

This was the proof-point that the scheduler + swtch worked *without* fork. Once it passed, Plan 3.C added `fork` to make process creation dynamic.

**References**

- `src/kernel/user/userprog2.zig` (the second user payload)
- `src/kernel/kmain.zig` (the multi-proc setup arm)
- `tests/e2e/multiproc.zig`
- `build.zig` target `e2e-multiproc-stub`
