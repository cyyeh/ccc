# kernel-boot-and-syscalls: Practice & Self-Assessment

---

## Section 1: True or False (10 questions)

**1.** The very first instruction `ccc`'s kernel runs is in `kmain.zig`.

**2.** `boot.S` runs in M-mode.

**3.** The trampoline page is mapped only in the kernel's page table, not in user page tables.

**4.** `s_trap_entry` saves user registers into the trap frame.

**5.** `swtch.S` saves all 32 general-purpose registers into the old context.

**6.** `mstatus.SUM` allows the kernel to fetch instructions from user pages.

**7.** The syscall return value goes into `a0` of the trap frame, which `s_trap_entry` reloads before `sret`.

**8.** A timer interrupt while running U-mode delegates to S directly (assuming `mideleg.MTI = 1`).

**9.** `kmain` returns to `boot.S` after setup, which then calls the scheduler.

**10.** The user's `_start` is responsible for setting up its own argv from the stack tail.

### Answers

1. **False.** First instruction is in `boot.S` at `0x80000000`, which then `mret`s into `kmain`.
2. **True.** M-mode owns the world at boot.
3. **False.** Trampoline is mapped *in every* page table at the same VA. That's how trap entry can begin executing before `satp` swaps.
4. **True.** `s_trap_entry` is asm in `trampoline.S` that saves all user regs into the trap-frame page.
5. **False.** It saves *only* callee-saved regs (`ra`, `sp`, `s0..s11`). Caller is responsible for the rest per ABI.
6. **False.** SUM affects loads/stores, not fetches. Fetches in S-mode are *never* allowed from U pages, even with SUM.
7. **True.** That's the entire return-value plumbing.
8. **True.** `mideleg.MTI = 1` would route MTI to S. `ccc` keeps MTI at M and forwards via SSIP, but the alternative is valid.
9. **False.** `kmain` calls `sched.schedule` which never returns. `boot.S` is finished after the `mret` to `kmain`.
10. **True.** `start.S` parses argc and argv pointers off `sp` (where `execve` placed them), then calls `main`.

---

## Section 2: Multiple Choice (8 questions)

**1.** Which CSR holds the address `s_trap_entry` (the trap vector)?
- A. `mtvec`
- B. `stvec`
- C. `sepc`
- D. `satp`

**2.** What does the kernel do with `mepc` after dispatching an `ecall_from_u`?
- A. Leave it; `mret` will use it.
- B. The kernel doesn't see `mepc`; it sees `sepc`. And `sepc += 4` so the user resumes past the ecall.
- C. Set it to the next syscall.
- D. Clear it.

**3.** `swtch(&old_ctx, &new_ctx)` does which of these *first*?
- A. Loads the new context.
- B. Calls a Zig helper.
- C. Saves `ra` into `old_ctx`.
- D. Sets `satp`.

**4.** When `sret` runs at the end of `s_trap_entry`, what privilege does the CPU end up in?
- A. Always U.
- B. Always S.
- C. Whatever `sstatus.SPP` was set to before the trap (1=S, 0=U).
- D. M.

**5.** Which two pages are mapped at fixed VAs in *every* address space (kernel and all user)?
- A. RAM and UART.
- B. The trampoline and the trap frame.
- C. The page tables.
- D. The scheduler's stack.

**6.** What's the purpose of `sched_ctx`?
- A. The CPU's current context.
- B. The scheduler's own context — what `swtch` returns into when a process yields.
- C. The user's trap frame.
- D. A reserved CSR.

**7.** Why does `boot.S` set `medeleg = 0xB1FF` (or similar)?
- A. To enable all interrupts.
- B. To delegate every sync exception that S can handle, so M doesn't have to forward.
- C. To set the trap vector.
- D. To clear pending traps.

**8.** What does the user's `_start` do *before* calling `main`?
- A. Allocates a heap.
- B. Initializes the FPU.
- C. Parses argc and argv from the stack tail (`sp` → `[argc, argv0, argv1, ..., NULL]`).
- D. Sets `mtvec`.

### Answers

1. **B.** `stvec` for S-mode traps; `mtvec` for M-mode traps.
2. **B.** sync exceptions land in S (with delegation); the kernel sees `sepc`, advances by 4 for ecall.
3. **C.** First instruction of `swtch.S` is `sw ra, 0(a0)`. The save phase comes before load.
4. **C.** `sret` restores privilege from `sstatus.SPP`. After a U→S trap, SPP=0, so `sret` lands in U.
5. **B.** Trampoline (X-only, kernel-only) and trap frame (R+W, kernel-only).
6. **B.** When a process `swtch`'s out, control returns to the scheduler's `swtch` call site. `sched_ctx` is the saved state of that call.
7. **B.** Delegation routes traps directly to S without M intervention.
8. **C.** The system-V argv tail is `argc, argv0_ptr, argv1_ptr, ..., NULL, env0_ptr, ..., NULL` on the stack. `_start` reads it into argc/argv args, then calls `main`.

---

## Section 3: Scenario Analysis (3 scenarios)

**Scenario 1: A new syscall**

You add `gettimeofday(struct timeval *tv)` as syscall #169.

1. Which two files do you edit at minimum?
2. The implementation needs to read CLINT's `mtime`. Which trick lets the kernel do that without user-page concerns?
3. The user pointer `tv` is a U-mode VA. How does `sys_gettimeofday` write to it?

**Scenario 2: A trap from M-mode**

The M-mode timer ISR (`mtimer.S`) needs to write to `mtimecmp` (CLINT MMIO at `0x02004000`). What if the address is wrong and the write traps with `store_access_fault`?

1. Where does the trap go (M, S, or U)?
2. If the M-mode handler wasn't set up to catch this, what happens?
3. What's the lesson?

**Scenario 3: Adding multi-thread per process**

You want to add a `clone()` syscall like Linux's, where two threads share the same address space. What kernel structures need to change?

### Analysis

**Scenario 1: gettimeofday**

1. `src/kernel/syscall.zig` (add the dispatch arm) and probably `src/kernel/user/lib/usys.S` (add the user-side stub).
2. The kernel page table identity-maps the CLINT MMIO range. So a kernel `lw` from `0x02004000 + 0xBFF8` reaches `mtime` directly. No SUM needed.
3. Set SUM, store the seconds + microseconds at the user VA, clear SUM. Same dance as `sys_write` does for the user buffer.

**Scenario 2: A trap from M-mode**

1. M traps go to M (M can never delegate to S). Cause = `store_access_fault`. PC = `mtvec`. So... right back into the M-mode handler?
2. If the same M-mode handler runs and immediately re-faults the same way, you have an infinite loop. `ccc`'s boot shim sets `mtvec` to a tiny stub that just halts on any unexpected trap; you'd see the emulator stop. With `--halt-on-trap`, you'd get a register dump.
3. Lesson: M-mode code has *no safety net*. There's no higher privilege to catch its mistakes. M-mode code must be paranoid about every load/store/csr write. That's why `ccc`'s boot shim is small — fewer lines = fewer places to be wrong.

**Scenario 3: clone()**

To share an address space between threads:

- `Process` struct needs to be split: address-space state (page table, mm) goes into a shared `Mm` struct; per-thread state (regs, kstack, trap frame, sched ctx) stays in `Process`.
- `proc.fork` becomes "alloc new Process, copy parent's Mm pointer (refcount++), give it its own kstack/trap frame."
- Many syscalls become per-thread (e.g., `sys_brk` modifies the *Mm*, but that affects all threads sharing it — needs care).
- The scheduler doesn't change much — it still picks Processes.
- Per-thread fd table vs shared fd table is a design decision (Linux's clone has flags for both).

This is a major refactor. Real OSes (Linux, xv6 with later patches) take it on; `ccc` declined for Phase 3.

---

## Section 4: Reflection Questions

1. **Why does the trap frame include `sepc` and `sstatus`?** They're CSRs, not regs. What goes wrong if you forget to save/restore them?

2. **The trampoline pattern.** Could you avoid having a trampoline (have `stvec` point directly into kernel code)? Sketch what would break.

3. **Is the kernel "another process"?** The scheduler's `sched_ctx` looks like a Process's Context. Is the scheduler "PID 0" in any meaningful sense?

4. **The cost of switching satp.** Each trap entry swaps `satp` twice (once at entry, once at exit). What's the cost on real hardware (TLB!)? How does `ccc` avoid paying it?

5. **Why aren't syscalls just functions?** From the user's perspective, `write` looks like a function call. What's the actual mechanism for? Why not just have the kernel link into every user program?
