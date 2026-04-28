# processes-fork-exec-wait: A Beginner's Guide

## What's a "Process"?

A process is one running program plus all its state. State includes:
- Its memory (the page table maps virtual pages to physical RAM).
- Its registers (saved when it's not running).
- Its open files (file descriptor table).
- Its current working directory.
- Its parent and children.
- Whether it's running, sleeping, zombie, etc.

Two browser tabs = two processes (modern browsers actually have many more, but conceptually). `ls` and `cat` running in your terminal = two processes. The kernel tracks them in a `ptable` (process table) — a fixed-size array. `ccc` allows 16.

---

## fork: The Photocopy Machine

In Unix, the way to *create* a new process is `fork()`. It's an unusual API: one call, two returns.

- The current process calls `fork()`.
- Suddenly there are *two* processes — the original (parent) and a brand new copy (child). Both are running the same code at the same line.
- The parent's `fork()` returns the child's PID (a positive integer).
- The child's `fork()` returns 0.

That's the whole API. The convention:

```c
pid_t pid = fork();
if (pid == 0) {
    // child code
} else if (pid > 0) {
    // parent code; child PID = pid
} else {
    // fork failed (-1)
}
```

The child gets:
- A copy of the parent's memory (every byte; lazily on real systems via copy-on-write, but eagerly in `ccc`).
- A copy of the parent's registers.
- A copy of the parent's open files (with shared file positions; `dup` semantics).
- A copy of the parent's cwd.

But:
- A new PID.
- `parent.parent = parent`.
- `a0 = 0` in the child's trap frame (so the child sees `fork() == 0`).

Why this weird API? Because it's *simple* on the kernel side: copy the page table, copy the trap frame, you're done. And it's flexible on the user side: the child can do anything before becoming a different program.

---

## exec: Replace Yourself

`fork()` alone makes a clone, which isn't very useful. The companion is `execve(path, argv, envp)`, which **replaces the current process's image** with a different program.

```c
if (fork() == 0) {
    // we're the child
    execve("/bin/ls", argv, envp);
    // execve returns only on failure
    exit(1);
}
// parent
wait(&status);
```

After `execve` succeeds:
- The current PID's memory is replaced with `/bin/ls`'s ELF segments.
- Stack is rebuilt with new argv/envp.
- Registers reset; PC = `_start` of the new program.
- File descriptors are *preserved* (this is huge — it's how shells implement redirection).

The "fork + exec" pattern is *the* Unix way to launch a new program. The two-step decomposition (fork, then exec) lets the child reconfigure between them — close fds, change directory, set up redirects, etc. — before the new program runs.

---

## wait: Reap a Child

When a child exits, its slot in `ptable` becomes "Zombie" state. The slot is held until the parent calls `wait()` to read the exit status. Without `wait`, you'd have a **zombie process** sitting around forever.

```c
int status;
pid_t pid = wait(&status);
// pid = the (now-reaped) child's PID
// status = the child's exit code, encoded
```

`wait` blocks until any child has exited. There's a fancier `waitpid(pid, ...)` to wait for a specific child.

If the parent itself exits before its children (the children are "orphaned"), they get **reparented** to PID 1 (`init`). `init`'s job — among other things — is to call `wait()` in a loop forever, reaping any orphans that exit. The shell's `init_shell` does this in `ccc`.

---

## exit: Disappear

```c
exit(0);  // success
exit(1);  // failure
```

`exit` doesn't return. The kernel:
- Reparents the children of this process to PID 1.
- Closes all the process's open files.
- Marks the slot as Zombie with the exit code stored.
- Wakes up the parent (in case it was `wait`ing).
- Schedules someone else.

The slot stays in Zombie state until the parent's `wait` reaps it.

---

## A Worked Example: Running `ls /tmp` from a Shell

The shell sees the user typed `ls /tmp\n`. The shell's code:

```c
int pid = fork();
if (pid == 0) {
    // child
    execve("/bin/ls", &["/bin/ls", "/tmp", NULL], envp);
    // execve only returns on failure
    exit(1);
} else if (pid > 0) {
    // parent
    int status;
    wait(&status);
}
```

What happens:

1. Shell calls `fork`. Two processes now exist; one resumes as parent, one as child, both at the line right after `fork`.
2. Child branch: child sees `pid == 0`. Calls `execve`.
3. Kernel rebuilds child's address space with `/bin/ls`. Sets `argc=2`, argv pointers to `["/bin/ls", "/tmp", NULL]`.
4. `sret` to child's new `_start`. ls runs.
5. ls reads /tmp (via `openat` + `read`), prints entries to fd 1.
6. ls calls `exit(0)`.
7. Kernel marks ls's slot Zombie. Wakes up the shell.
8. Shell's `wait` returns the child's PID and status. The shell prints the prompt again.

That's the whole shell-launches-a-program flow. It's how every Unix shell works.

---

## What's a "Zombie"?

Zombies are processes that have exited but haven't been reaped. They take up a `ptable` slot but no other resources (their memory was freed at exit). They wait for the parent's `wait()` to read their exit code and free the slot.

Why hold the slot? Because the parent might want to know *which* child exited and *what its status was*. Without holding the slot, that info would be lost.

Tools like `ps` show zombies as state `Z`. They're harmless but they consume a slot, so a buggy parent that never `wait`s leaks slots.

---

## Why is `^C` Tricky?

When you press `^C`, the foreground program needs to die. But the program might be in the middle of a syscall — say, `read()` blocked on the keyboard. You can't just delete it from memory; data structures could be inconsistent.

`ccc`'s solution is the **kill flag**:

1. `^C` arrives; console line discipline detects byte 0x03.
2. Calls `proc.kill(fg_pid)`. Sets `target.killed = true`. If target is Sleeping, also makes it Runnable.
3. The target wakes from its sleep (or finishes its current syscall).
4. On the way back to user mode, `syscall.dispatch` checks `p.killed`. If set, calls `proc.exit(p, 1)` instead of returning normally.

So the target gets to finish its current syscall safely, but never returns to user code. This is a much simpler model than POSIX signals, and it's enough for shell-style `^C`.

---

## Quick Reference

| Concept | One-liner |
|---------|-----------|
| Process | A running program + its memory + regs + fds + cwd. |
| `ptable[NPROC]` | Static array of `Process` slots. PID = slot+1. |
| State | Unused / Embryo / Sleeping / Runnable / Running / Zombie. |
| `fork` | Photocopy the parent. Child gets a new PID; both return. |
| `execve` | Replace current image with a different program. fds preserved. |
| `wait4` | Block until a child exits; read its status; free the slot. |
| `exit` | Mark self Zombie, wake parent, give up CPU. |
| Zombie | Exited but not yet reaped. Slot held until `wait`. |
| Reparent | Orphans get adopted by PID 1 (`init`). |
| Kill flag | Soft kill mechanism. Set on `^C`; checked on syscall return. |
| Sleep / wakeup | Channel-based blocking. `chan` is any pointer. |
| `swtch` | The 14-instr asm context switch. Saves/loads callee-saved regs. |
