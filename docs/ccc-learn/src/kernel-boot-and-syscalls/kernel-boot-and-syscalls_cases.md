# kernel-boot-and-syscalls: Code Cases

> Real artifacts from the codebase that illustrate boot, traps, and syscalls.

---

### Case 1: The first U-mode `write` (Plan 2.C, 2026-04)

**Background**

The Phase 2 §Definition of Done asserts that `kernel.elf` boots, runs a user program that calls `write(1, "hello from u-mode\n", 18)`, and the bytes appear on stdout. This was the first time *any* user-privilege code in `ccc` did anything observable.

**What happened**

`src/kernel/user/userprog.zig`:

```zig
fn _start() noreturn {
    const msg = "hello from u-mode\n";
    _ = write(1, msg, msg.len);
    _ = yield();
    _ = yield();
    _ = yield();
    _ = exit(0);
    while (true) {}
}
```

The `write`/`yield`/`exit` symbols are externs, defined in `usys.S` as:

```
.global write
write:
    li a7, 64
    ecall
    ret
```

Compile + link → user ELF embedded into kernel.elf at build time. At boot, kernel reads the embedded blob, copies it into PID 1's address space, sets `sepc = entry`, runs.

The verifier `tests/e2e/kernel.zig` asserts stdout matches `^hello from u-mode\nticks observed: \d+\n$`. The "ticks observed" bit is printed by PID 1's exit path (in `proc.exit` for PID 1).

**Relevance**

This single test is the proof point for the entire kernel-boot-and-syscalls topic. If `boot.S` doesn't `mret` correctly, the test fails. If `kmain` builds the wrong page table, fails. If `s_trap_entry` clobbers `a0`, fails. If `sys_write` doesn't honor SUM, fails. Every part of the boot chain is exercised.

**References**

- `src/kernel/user/userprog.zig`
- `src/kernel/user/lib/usys.S`
- `src/kernel/syscall.zig` (`sys_write`)
- `src/kernel/proc.zig` (`exit` printing "ticks observed")
- `tests/e2e/kernel.zig`

---

### Case 2: The trampoline page mapping trick (Plan 2.A → 2.C, 2026-04)

**Background**

When a U-mode trap fires, the CPU is in U-mode with the user's `satp`. It jumps to `stvec` = trampoline VA. For that jump to *not* page-fault, the trampoline must be mapped as `X` in the user's page table.

But the kernel doesn't want user code to be able to *call into* the trampoline at will (security boundary). So the trampoline mapping has `U=0` (not user-accessible). The CPU is in U-mode, so by normal rules a `U=0` page is unreachable.

**The trick**: when fetching the *target* of a trap, the CPU uses the *target* privilege (S), not the current (U). So fetch translation succeeds. After `s_trap_entry` swaps `satp` to the kernel's table, the trampoline is mapped there too (also `U=0` — the kernel doesn't need user-mode reach).

This pattern (per-address-space trampoline at fixed VA, kernel-only) is universal in RISC-V/ARM kernels. xv6, Linux, and `ccc` all do it the same way.

**Implementation**

In `vm.zig`, when building any user page table, the kernel installs:
- Trampoline page (1 PTE, X-only, kernel-only, fixed VA `TRAMPOLINE`).
- Trap-frame page (1 PTE, R+W, kernel-only, fixed VA below `TRAMPOLINE`).

These two pages are at the top of every user address space; the user can't see them but the trap path uses them.

**References**

- `src/kernel/vm.zig` (`mapTrampoline`, `mapTrapframe`)
- `src/kernel/trampoline.S`
- xv6's `kernel/vm.c` for comparison

---

### Case 3: `e2e-kernel` proving the round-trip (Plan 2.D, 2026-04)

**Background**

Plan 2.D's deliverable was a kernel demo where a U-mode program could `write`, `yield`, observe timer ticks, and `exit` — the full Phase 2 vertical slice. The verifier `tests/e2e/kernel.zig` is the regression for the entire kernel.

**What happened**

The verifier:
1. `zig build kernel-elf` → produces `zig-out/bin/kernel.elf`.
2. Spawns `ccc kernel.elf` as a child process.
3. Captures stdout.
4. Asserts: stdout starts with `"hello from u-mode\n"`, then a `"ticks observed: N\n"` with `N > 0`.
5. Asserts the exit code is 0.

If `N == 0`, it means the timer interrupt never fired (or never delivered). If the prefix is wrong, `sys_write` is broken. If the exit code is non-zero, the kernel panicked or trapped fatally.

**Why N > 0 specifically**

The user program calls `yield()` three times. Between `yield`s, the kernel's idle path runs `wfi`. The timer fires while idle → MTI handler → `mip.SSIP = 1` → S trap → tick counter++. By the time `exit(0)` runs, the counter should be ≥ 1.

If the SIE-window is broken (see Plan 3.E case), `wfi` blocks 10 seconds and the test times out. The fact that this passes proves the timer-driven scheduler is alive.

**References**

- `tests/e2e/kernel.zig`
- `build.zig` target `e2e-kernel`

---

### Case 4: Why does `swtch.S` save *only* callee-saved? (Plan 2.D, 2026-04)

**Background**

The RISC-V calling convention partitions registers into *caller-saved* (`a0..a7`, `t0..t6`, `ra`) and *callee-saved* (`s0..s11`, `sp`). `swtch.S` saves only the callee-saved set.

**Why**

`swtch` is called from C/Zig code as a regular function. The Zig caller (e.g., `sched.schedule`) is responsible for saving any *caller-saved* regs it cares about across the call — that's what callers always do for any function call, by spec. So when `swtch` runs, the only state that survives a normal return is the callee-saved set, plus the PC (in `ra`).

Saving only the callee-saved set makes `swtch` shorter (14 instructions instead of ~30) and faster.

When the new context's `ret` runs, it returns to *its* `swtch`'s caller — which had similarly saved any caller-saved regs it cared about. So the context switch is invisible to the C/Zig code on either side, except for the ABI round-trip latency.

**The user-side trap frame is different**

The trap frame saves *every* register, because the trap interrupted user code at an arbitrary point. The user's regs are not partitioned into "saved" vs "not" at that moment — every reg might be in use.

So: trap entry saves all regs to the trap frame (asm). `swtch` saves only callee-saved (asm). Different machinery for different purposes.

**References**

- `src/kernel/swtch.S`
- `src/kernel/trampoline.S` (s_trap_entry's full register save)
- The RISC-V ABI document, §18.2

---

### Case 5: The s_kernel_trap_entry SIE-window arm (Plan 3.E, 2026-04)

**Background**

The scheduler can `wfi` while waiting for a runnable process. While in `wfi`, a device IRQ may arrive. We want it to land — but `s_trap_entry` assumes it's coming from U or from a process's kstack, not from the scheduler's own stack.

**What happened**

The scheduler's `wfi` path uses a separate trap entry: `s_kernel_trap_entry`. This entry is simpler:

- The scheduler is running on `sched_stack`. We're in S-mode already.
- We don't need to swap `satp` (kernel page table is already active).
- We don't need to save the trap frame (we're not coming from a process).
- We do need to save callee-saved regs to `sched_stack` (the trap may return after the scheduler has yielded back).

Pseudo-asm:

```
s_kernel_trap_entry:
    addi sp, sp, -64
    sw   ra, 0(sp); sw s0, 4(sp); ...   # save callee-saved
    call s_kernel_trap_dispatch
    lw   ra, 0(sp); lw s0, 4(sp); ...
    addi sp, sp, 64
    sret
```

The dispatcher inside is a stripped-down version: it handles only async interrupts (sync exceptions on the scheduler's stack are panics). It claims the PLIC source, runs the device ISR (which probably wakes a sleeping process), and returns.

The SIE-window pattern is: scheduler sets `stvec = s_kernel_trap_entry` and `sie.SEIE = 1` for one instruction. `wfi`. If trap fires, lands here. If not, `sie` clears, `stvec` restores, scheduler resumes.

**References**

- `src/kernel/sched.zig` (the SIE-window setup)
- `src/kernel/trampoline.S` (`s_kernel_trap_entry`)

---

### Case 6: Why does `sys_write` have a SUM dance? (Plan 2.C / 3.E, 2026-04)

**Background**

`sys_write` needs to copy bytes from the user's buffer (a U-mode VA) to UART. The kernel's `satp` points at the kernel page table, which doesn't map user pages.

**Two choices**

1. **Walk the user's page table manually.** The `Process` struct has `user_satp`; the kernel could compute the translation explicitly via `vm.walk(user_satp, va)` and read the byte from the resulting PA.
2. **Set `mstatus.SUM = 1`.** This bit lets S-mode loads/stores access *any* PTE with `U=1`. Combined with the kernel page table's identity mapping of user RAM (in `ccc`'s setup), the read works.

`ccc` uses option 2. The dance:

```zig
fn setSum() void { asm volatile ("csrs sstatus, %[b]" :: [b] "r" (SSTATUS_SUM) : "memory"); }
fn clearSum() void { asm volatile ("csrc sstatus, %[b]" :: [b] "r" (SSTATUS_SUM) : "memory"); }

pub fn sys_write(p: *Process) i32 {
    const fd = p.trapframe.a0;
    const buf_va = p.trapframe.a1;
    const len = p.trapframe.a2;
    setSum();
    defer clearSum();
    // ... loop reading bytes from buf_va ...
}
```

The `setSum`/`clearSum` are scoped tight: only the user-pointer loads happen with SUM=1.

**Caveat**

This works because `ccc`'s kernel page table happens to identity-map RAM. If the kernel decided to *not* map user RAM in its own pt, option 2 would fail (the load would page-fault — kernel pt has no PTE for the user VA at all). Linux uses both approaches depending on context.

**References**

- `src/kernel/syscall.zig` (`setSum`/`clearSum`/`sys_write`)
- `src/kernel/vm.zig` (kernel pt construction)
- xv6's `copyout`/`copyin` for the alternative (manual walk) approach
