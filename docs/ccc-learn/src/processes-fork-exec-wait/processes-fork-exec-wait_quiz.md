# processes-fork-exec-wait: Practice & Self-Assessment

---

## Section 1: True or False (10 questions)

**1.** `ccc`'s `ptable` holds up to 16 concurrent processes.

**2.** PID 0 is reserved as "no process" and never assigned to a running program.

**3.** A process in Zombie state takes up no resources.

**4.** `fork` returns the same value to parent and child.

**5.** `execve` preserves the file descriptor table across the image swap.

**6.** A child of an exited parent gets reparented to PID 0.

**7.** `wait4` is non-blocking by default.

**8.** Setting `p.killed = true` immediately stops the process.

**9.** The user's `_start` reads argc and argv from the stack tail.

**10.** `swtch` saves the trap frame.

### Answers

1. **True.** `NPROC = 16` in `proc.zig`.
2. **True.** PID 0 = "unallocated slot." PIDs are 1-based.
3. **False.** Zombies hold their `ptable` slot until reaped. Most resources (memory, fds) are freed at exit, but the slot stays.
4. **False.** Parent gets the child's PID; child gets 0. The "two return values" idiom is the entire mechanism for distinguishing them.
5. **True.** That's *why* the fork+exec pattern works — the shell can dup/redirect fds in the child between fork and exec, and exec preserves them.
6. **False.** Reparented to PID 1 (`init`). PID 0 is unused; PID 1 is `init`.
7. **False.** Default behavior blocks until a child exits (or no children, in which case returns -1). Non-blocking is a flag (`WNOHANG`).
8. **False.** Sets the flag. The flag is checked at known safe points (syscall return), so the kill takes effect on the next syscall return — not immediately.
9. **True.** That's the System-V argv-tail convention.
10. **False.** `swtch` saves only callee-saved kernel regs (`ra`, `sp`, `s0..s11`) into the `Context`. The trap frame is for *user* state, saved by `s_trap_entry`.

---

## Section 2: Multiple Choice (8 questions)

**1.** What does `proc.alloc` return?
- A. A new physical page.
- B. A pointer to an Unused slot in `ptable`, marked Embryo.
- C. The PID of the next process.
- D. A new file descriptor.

**2.** When the parent calls `fork`, what value does the child see returned?
- A. The parent's PID.
- B. The child's own PID.
- C. 0.
- D. -1.

**3.** What does `vm.copyUvm` need to do on OOM?
- A. Panic the kernel.
- B. Return an error and free any pages it has already allocated for the child.
- C. Return success and let the caller deal with it.
- D. Retry forever.

**4.** Which of these is the channel that `wait4` sleeps on?
- A. `&proc.ptable`
- B. `p` (a pointer to the parent itself)
- C. `null`
- D. `&p.parent`

**5.** What's the `argv` tail's `argc` field positioned relative to?
- A. The top of the page.
- B. The bottom — `sp` points right at it.
- C. Wherever the kernel decides.
- D. After the strings.

**6.** What does `proc.kill` do if the target is in `Sleeping` state?
- A. Sets `killed = true` and leaves it Sleeping.
- B. Sets `killed = true` and flips state to Runnable.
- C. Calls `exit(p, 1)` directly.
- D. Returns -1.

**7.** Which is true about the `xstate` field?
- A. It's the process's name.
- B. It holds the exit status, populated by `exit`, read by `wait4`.
- C. It's a pointer to the trap frame.
- D. It's the saved syscall return value.

**8.** When the scheduler can't find any Runnable process, what does it do?
- A. Halts the system.
- B. Spins forever in a tight loop.
- C. Executes `wfi` with the SIE-window pattern.
- D. Calls `proc.exit`.

### Answers

1. **B.** `alloc` finds an Unused slot, marks Embryo, returns pointer.
2. **C.** Child gets 0. Parent gets the child's PID.
3. **B.** Free anything allocated so far, return error. The `errdefer` pattern.
4. **B.** Each process is its own channel; a child's exit calls `wakeup(p.parent)`.
5. **B.** `sp` points at `argc`. `_start` reads `*(int*)sp` for argc, `(char**)(sp + 4)` for argv.
6. **B.** Soft kill: set the flag *and* wake up so the syscall return path can act on it.
7. **B.** Stored on exit, read by wait4, copied to user.
8. **C.** SIE-window `wfi` so device IRQs (e.g., disk completion) can wake a sleeper.

---

## Section 3: Scenario Analysis (3 scenarios)

**Scenario 1: A process leaks zombies**

You write a shell that does `fork+exec` for each command but forgets to `wait`. After 16 commands, the next `fork` fails. Why?

1. What state are all the past children in?
2. How does this affect `proc.alloc`?
3. What's the standard fix? (Hint: the `init` process pattern.)

**Scenario 2: Forking with shared fds**

The shell does `fork`. Both parent and child now have fd 1 pointing at the same `File`. Both write to fd 1. What happens to the file's offset?

1. Does the parent see the child's writes?
2. If both write 100 bytes, what's the file's final size?
3. Does it matter that they share or have separate file struct pointers?

**Scenario 3: A child that exits before the parent waits**

The shell does `fork`. Before the parent's `wait4` runs, the child has already done `exec(/bin/true)` and exited.

1. What state is the child in?
2. What happens when the parent eventually calls `wait4`?
3. Why doesn't the child's exit code get lost in this race?

### Analysis

**Scenario 1: A leaky shell**

1. All past children are in Zombie state. They've exited but not been reaped.
2. After NPROC = 16 zombies accumulate, `proc.alloc` fails — every slot is in use (some Running, some Zombie). `fork` returns -1.
3. The standard fix is to have a `wait()` loop in the parent (or in `init` if the parent doesn't care). Real shells call `wait` after each command. The `init` process pattern is "loop forever calling wait()" so that any orphaned-and-exited child gets reaped, no matter who their original parent was.

**Scenario 2: Shared fds**

In `ccc`'s `fork`, the fd table is duplicated by `file.dup` (refcount++). Both parent and child have fd 1 pointing to the *same* `File` struct, which has a *single* `offset` field.

1. The parent doesn't see the child's writes in any direct sense — they're both writing to the same file (e.g., the UART, or a regular file on disk). The bytes are interleaved.
2. The file's offset advances by 200 bytes total (100 from each), assuming they're appending. The final size = 200 bytes.
3. It absolutely matters. If `fork` *copied* the `File` struct (separate offsets), parent and child would each have their own offset, and writes to a regular file would clobber each other (both starting from offset 0). Sharing means consistent offset bookkeeping. This is *the* mechanism shells rely on for redirection: `cmd > file` opens file (one File struct), forks; child uses fd 1 = that File struct; child execs; child writes increment that struct's offset; parent's open file (fd 1 = original UART, separate File) is unaffected.

**Scenario 3: Child exits before parent waits**

1. Zombie. The exit marked the slot Zombie; the kernel called `wakeup(parent)` but the parent hadn't called `wait` yet, so the wakeup was a no-op.
2. When the parent eventually calls `wait4`, the dispatch loops over `ptable` looking for a child of `parent` in Zombie state. Finds the child immediately (it's been there waiting). Reads `xstate`, copies to user, frees the slot, returns the PID.
3. The exit code is preserved in the child's slot's `xstate` field. As long as no one calls `wait4` and frees the slot, that field holds the value indefinitely. This is *exactly* what zombies are for: they hold the exit status until someone reads it.

---

## Section 4: Reflection Questions

1. **The fork-then-exec pattern.** Why two syscalls instead of one (like Windows' `CreateProcess`)? What's gained, what's lost?

2. **Channel-based sleep/wakeup.** It's pointer-based. What if two unrelated subsystems happen to use the same pointer as a channel? Sketch a bug that could result.

3. **The kill-flag's "checked at known points" rule.** Why is this OK for `^C` but inadequate for, say, real signals? When would you want true async preemption?

4. **`ptable[NPROC=16]`.** Why static? Why so few? What's the cost of making it 1024?

5. **Reparenting to init.** Why is "every orphan goes to PID 1" the right policy? What if PID 1 itself exits?
