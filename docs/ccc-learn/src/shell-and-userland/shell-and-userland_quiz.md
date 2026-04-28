# shell-and-userland: Practice & Self-Assessment

---

## Section 1: True or False (10 questions)

**1.** The shell is a kernel feature; you can't replace it.

**2.** `init_shell` re-launches the shell when sh exits with non-zero status.

**3.** `cd` is a builtin because changing directory in a forked child wouldn't affect the shell.

**4.** Redirects (`>`) are syntactic sugar for the kernel; the kernel knows about `>`.

**5.** `dup2(old, new)` makes `new` point at the same File struct as `old`.

**6.** Across `execve`, the fd table is reset.

**7.** `_start` is the very first instruction any user program runs.

**8.** `usys.S` has 19 syscall stubs in `ccc`.

**9.** `printf` in `ccc`'s userland is buffered for performance.

**10.** `echo`, `cat`, `ls` are external programs (separate ELFs).

### Answers

1. **False.** The shell is `sh.zig`, a U-mode user program. `init_shell` could exec a different shell.
2. **True.** It loops as long as sh keeps exiting non-zero. Status 0 → init exits too.
3. **True.** A child's chdir would change the child's cwd; the child then exits; the shell's cwd is unchanged.
4. **False.** The kernel knows nothing about `>`. The shell parses it and uses dup2 to wire fds.
5. **True.** `dup2` is the redirect primitive. Both fds become refcount-shared on the same File.
6. **False.** *Critically*, fd table is preserved across exec. That's why redirects work.
7. **True.** `_start` is in `start.S`; it parses argc/argv, calls main, exits with main's return.
8. **True.** Each is two instructions (`li a7, NN; ecall; ret`).
9. **False.** It's unbuffered — every byte hits a `write` syscall directly. Slow but simple.
10. **True.** `/bin/echo`, `/bin/cat`, `/bin/ls` are separate ELFs baked into `shell-fs.img`.

---

## Section 2: Multiple Choice (8 questions)

**1.** When you type `cd /tmp` at the shell, what happens at the kernel level?
- A. Shell forks; child execs `/bin/cd /tmp`.
- B. Shell calls `chdir("/tmp")` directly. No fork.
- C. Kernel built-in.
- D. The line is ignored.

**2.** What does `init_shell` do if `wait4` returns and `status != 0`?
- A. Exit 0.
- B. Loop and re-fork sh.
- C. Print an error and halt.
- D. Sleep for 1 second, then exit.

**3.** Which is the standard way to redirect stdout to a file in the shell?
- A. The shell calls `redirect_stdout(fd)`.
- B. `open` + `close(1)` + `dup2(fd, 1)` + `close(fd)` + `execve`.
- C. The kernel intercepts `>` and handles it.
- D. The shell writes a config file the kernel reads.

**4.** `_start` is responsible for:
- A. Allocating a heap.
- B. Setting up trap handlers.
- C. Reading argc/argv from the stack and calling main; ecall'ing exit afterward.
- D. Loading the ELF.

**5.** A user program calls `write(1, "hi", 2)`. The kernel-side path:
- A. Direct UART write.
- B. Lookup fd 1 → File. If Console-type: `console.write` → UART. If Inode-type: `file.write` → `writei` → bufcache → block.
- C. Just `printf`.
- D. Trap to firmware.

**6.** Why are `echo`, `cat`, etc. external programs and not builtins?
- A. They're too complex to be built in.
- B. To exercise fork+exec; if they were builtins, the redirect machinery wouldn't matter.
- C. The kernel doesn't allow builtins.
- D. They use too much memory.

**7.** What's the maximum size of the user's argv (in `ccc`)?
- A. 4 bytes.
- B. The whole user stack page (one 4 KB page).
- C. 16 KB.
- D. Unlimited.

**8.** When sh exits 0, what happens?
- A. Kernel halts immediately.
- B. init_shell's wait4 returns; init exits 0; PID 1 exit triggers kernel halt.
- C. Shell relaunches itself.
- D. Nothing visible.

### Answers

1. **B.** chdir is a syscall the shell calls directly.
2. **B.** Loop and re-fork. Allows `^C` killing the shell to recover gracefully.
3. **B.** That's the dup2 dance, in the child between fork and exec.
4. **C.** That's the System-V ABI entry point's job.
5. **B.** File-table dispatch: Console vs Inode.
6. **B.** They're not just simpler in implementation — they're also tests of the entire machinery. Make echo a builtin and you can't test fork+exec.
7. **B.** One page (4 KB) — the user stack page. Anything larger needs more pages allocated.
8. **B.** PID 1 exit is the kernel's "we're done" signal.

---

## Section 3: Scenario Analysis (3 scenarios)

**Scenario 1: Adding a `ps` command**

You want to add `ps` to list running processes.

1. Where would `ps` get the process list from? (Hint: `ccc` has no `/proc`.)
2. Could you add a syscall like `getprocstats(buf, len)` to expose the ptable?
3. What's the security concern with this on a multi-user system? (`ccc` doesn't have users; ignore for now.)

**Scenario 2: A pipe (`|`)**

You want `ls | wc` (pass ls's stdout to wc's stdin).

1. What kernel facility would you need that `ccc` doesn't have?
2. Sketch the shell's flow for handling `|`.
3. How would the two children's stdout/stdin be connected?

**Scenario 3: A buggy `_start`**

You're porting `_start` from another OS and forget to call exit after main returns. What happens?

1. Where does the user code go after `main` returns?
2. Does the program crash? Hang?
3. How would you debug this?

### Analysis

**Scenario 1: Adding `ps`**

1. The kernel's `ptable` array. No FS-based `/proc` in `ccc`.
2. Yes — a new syscall like `getprocstats` would copy a snapshot of `ptable[].pid, .state, .name` to a user buffer. Add to `syscall.zig`'s table; add the dispatch arm.
3. On a real system: process info reveals what users are running. `ps -ef` shows command lines (often containing passwords). On a multi-user box, you'd want to restrict info — Linux's `/proc` does fine-grained perms.

**Scenario 2: Pipes**

1. The `pipe()` syscall — creates a pair of fds (read end + write end) with kernel-side buffer.
2. Shell tokenizes "ls | wc" → recognizes `|` between ls and wc. Calls `pipe(p)` → p[0] read, p[1] write. Forks twice. Child A: `dup2(p[1], 1); close(p[0]); close(p[1]); execve(ls)`. Child B: `dup2(p[0], 0); close(p[0]); close(p[1]); execve(wc)`. Parent: `close(p[0]); close(p[1]); wait4(both)`.
3. The pipe is the connector. ls writes to its fd 1 (= p[1]); kernel buffers; wc reads from fd 0 (= p[0]); kernel hands over the bytes.

**Scenario 3: A buggy `_start`**

1. After `main` returns, control falls through to whatever's next in memory. Could be:
   - The exit ecall (if `_start` has it after `call main`).
   - Random instructions (if not).
   - An `unreachable` trap (in some toolchains).
2. Most likely: random instructions execute, eventually hitting an illegal-instruction trap or page-faulting on a stack underflow. The user process then exits via the trap handler killing it.
3. Debug: `--trace --halt-on-trap` would show the bad instruction. Or read `_start` source carefully — the `li a7, 93; ecall` after `call main` is the standard.

---

## Section 4: Reflection Questions

1. **The shell as user program.** What's the conceptual win of making the shell a user program instead of a kernel feature? What's the cost?

2. **Why fork before exec, even for redirects?** Sketch a "spawn" syscall API that combined them. What features would you lose?

3. **`init`'s eternal loop.** What happens if `init` itself crashes? In `ccc`? In Linux?

4. **The 19-syscall vocabulary.** That's enough for a working shell. What's the *minimum* number of syscalls to support a shell? (Hint: lots of work was done in the 1970s to find this.)

5. **Builtins vs externals.** Why does bash have `echo` as both a builtin AND `/usr/bin/echo`? When does each one win?
