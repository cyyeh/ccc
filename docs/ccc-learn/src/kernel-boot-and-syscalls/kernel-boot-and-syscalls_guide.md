# kernel-boot-and-syscalls: A Beginner's Guide

## "What Even Is the Kernel?"

The kernel is the program the CPU runs first, and that's always running underneath everything else. When you click on a Mac, somewhere a kernel routine handles "mouse moved." When you `cd` in a terminal, the kernel translates that into a syscall. When you `Cmd-Q` an app, the kernel cleans up its memory.

In `ccc`, the kernel is `src/kernel/*.zig` plus a few `.S` files. About 4000 lines total. It does:

- **Bootstrap.** Set up the world before any user program runs.
- **Trap handling.** Catch every exception and interrupt; dispatch to the right place.
- **Syscalls.** Be the gatekeeper for "user wants kernel to do something."
- **Scheduling.** Pick which process runs next.
- **Memory management.** Allocate physical pages; install page-table entries.
- **Filesystem.** (Phase 3) Read/write a disk image.
- **Drivers.** UART, PLIC, block. (Thin layers — most logic is in the device emulation.)

This topic covers the first three: bootstrap, trap handling, and syscalls.

---

## The Boot Story in Plain Terms

Imagine you're hired to set up a brand-new computer for a small office. There's nobody else there. You need to:

1. **Plug it in.** (Power on. CPU starts at PC = reset vector.)
2. **Configure the OS settings.** Time zone, network, etc. (Set CSRs, install page tables.)
3. **Hire and onboard the first employee.** (Allocate PID 1, set up its environment.)
4. **Hand the keys over.** (Drop privilege from M to S to U; give PID 1 the CPU.)
5. **Step into the supervisor's office and watch what happens.** (Scheduler runs forever, intervenes only on traps.)

Steps 1–4 happen exactly once, at boot. Step 5 is "everything else, forever."

In `ccc`:
- Step 1: hardware-defined; CPU starts at `0x80000000`.
- Step 2: `boot.S` (M-mode) + `kmain.zig` (S-mode).
- Step 3: `kmain` calls `proc.allocate()` and `proc.exec()` to set up PID 1.
- Step 4: `sched.schedule()` does the first `swtch` into PID 1, which `sret`s into U-mode.
- Step 5: trap handlers (`s_trap_entry` → `dispatch`) and the scheduler take over.

---

## What's a Syscall, *Really*?

A syscall is "I am a user program. I would like the kernel to do something for me."

The mechanism:

1. User puts a number in `a7` (which syscall to run).
2. User puts arguments in `a0..a5`.
3. User executes `ecall`.
4. The CPU traps. It saves user state, switches to S-mode, and lands at the kernel's trap vector.
5. Kernel reads `scause`, sees "ecall from U." Reads `a7` to find which syscall.
6. Kernel does the work. Stores result in the user's `a0`.
7. Kernel does `sret`. CPU is back in U-mode at the instruction after `ecall`.
8. User reads `a0`, sees the result.

In code, that's:

```c
// User-side stub for write():
int write(int fd, char *buf, int len) {
    register int a0 = fd, a1 = (int)buf, a2 = len, a7 = 64;
    asm volatile ("ecall" : "+r"(a0) : "r"(a1), "r"(a2), "r"(a7));
    return a0;  // syscall return value
}
```

In `ccc`'s `usys.S`, every syscall is exactly two instructions:

```
.global write
write:
    li a7, 64
    ecall
    ret
```

The `li` puts 64 in a7. The `ecall` traps. After return, `a0` holds whatever the kernel put there.

---

## The Trap Frame: Where User Regs Live During the Trap

When the trap fires, all the user's registers are *still in the CPU's register file*. The kernel can't just start using them — it'd clobber the user's state. So the very first thing `s_trap_entry` does is **save** every user register into a per-process *trap frame*.

The trap frame is a struct:

```zig
pub const Trapframe = struct {
    ra: u32, sp: u32, gp: u32, tp: u32,
    t0: u32, t1: u32, t2: u32,
    s0: u32, s1: u32, ..., s11: u32,
    a0: u32, a1: u32, a2: u32, a3: u32, a4: u32, a5: u32, a6: u32, a7: u32,
    t3: u32, t4: u32, t5: u32, t6: u32,
    sepc: u32, sstatus: u32,
};
```

Allocated once per process, at a fixed VA. `s_trap_entry` writes into it, the dispatch reads from / writes to it (e.g., to put the syscall return in `a0`), and the tail of `s_trap_entry` reloads the regs from it.

The trap frame is *the* user/kernel handshake. Anything the kernel wants the user to see ends up in the trap frame; anything the user wants to send the kernel comes through the trap frame.

---

## Why Does the Kernel Have Its Own Page Table?

The user has a page table that maps their code, data, stack, and heap. The kernel can't share that — it has its own code (the kernel image), its own data, its own stack, its own MMIO mappings.

So the kernel has its own page table. When a trap fires, the trampoline switches `satp` from "user page table" to "kernel page table." Now kernel code can run normally — its addresses make sense again.

When the kernel needs to *read* a user pointer (e.g., the buffer arg in `write`), it needs help. Two options:

1. **Walk the user's page table manually.** Read PTEs at known addresses; chase pointers. Tedious.
2. **Set `mstatus.SUM = 1`.** This bit lets S-mode loads/stores access U-pages without faulting. The kernel sets SUM, does the access, clears SUM.

`ccc` uses option 2 for `sys_write` and similar. See `src/kernel/syscall.zig`'s `setSum()` / `clearSum()` helpers.

---

## What's a Context Switch?

A *context switch* is "stop running process A; start running process B." The scheduler does this by:

1. Saving A's *kernel-side* state into A's `Context` struct.
2. Loading B's `Context` into the CPU.
3. Returning into B's saved code path.

The "kernel-side state" here is just the callee-saved registers (`ra`, `sp`, `s0..s11`). The *user-side* state is in A's trap frame already (it was saved on the trap that brought us here). When B's saved code path eventually runs `sret`, *that's* what restores B's user state from B's trap frame.

So a context switch in `ccc` is a 14-instruction asm function (`swtch.S`) that saves a dozen regs and loads a dozen regs. The `ret` at the end pops the new `ra` into the PC and we're now executing B.

---

## A Concrete Walk: `printf("hi\n")` from a User Program

Let's say PID 1 is running and wants to print `hi\n`. The user code:

```zig
write(1, "hi\n", 3);  // fd 1, buffer "hi\n", length 3
```

Compiled to:

```
li a0, 1                    ; fd = 1
auipc a1, 0; addi a1, a1, ... ; a1 = address of "hi\n"
li a2, 3                    ; length = 3
li a7, 64                   ; syscall number = write
ecall
```

What happens:

1. `ecall` decodes. `dispatch` calls `trap.enter(.ecall_from_u, pc, cpu)`.
2. Trap entry: `sepc = pc`, `scause = 8`, switch to S, jump to `stvec` = trampoline `s_trap_entry`.
3. `s_trap_entry`:
   - Save `ra`, `sp`, `gp`, `tp`, all `t*`, all `s*`, `a0..a7`, `sepc`, `sstatus` into PID 1's trap frame.
   - Load kernel's `satp`.
   - Load kernel stack pointer.
   - Call `s_kernel_trap_dispatch`.
4. `dispatch`:
   - Read `scause` = 8. ECALL_U. Call `syscall.dispatch(p)`.
5. `syscall.dispatch`:
   - `a7` = 64 → `sys_write(p)`.
   - Read `a0` = 1, `a1` = user buffer address, `a2` = 3 from trap frame.
   - Set SUM = 1.
   - Loop: read 3 bytes from user buffer (via SUM-enabled load), write each to `console.write` which calls `uart.putByte` which writes to UART THR which prints.
   - Clear SUM.
   - Return 3 (bytes written).
   - Store 3 in trap frame's `a0`.
   - `sepc += 4` so we resume past ecall.
6. `dispatch` returns. `s_trap_entry`:
   - Reload all regs from trap frame (now `a0` = 3).
   - Switch `satp` back to PID 1's user page table.
   - `sret` — pops sstatus.SPP into privilege, sepc into PC.
7. Back in U-mode. PC = address of `ret` instruction. `a0` = 3.
8. User code returns from `write`. Sees 3.

That's the entire story of a syscall. About 30 instructions of asm + a hundred lines of Zig, end to end.

---

## Quick Reference

| Concept | One-liner |
|---------|-----------|
| Boot shim | `boot.S` — M-mode init, then `mret` into S-mode `kmain`. |
| `kmain` | Kernel's `main()`. Builds page tables, allocates PID 1, runs the scheduler. |
| Trampoline | A page mapped in every address space. Holds `s_trap_entry`. |
| Trap frame | Per-process struct holding saved user regs across a trap. |
| `s_trap_entry` | Asm. Save user regs → swap satp + sp → call dispatch → restore → sret. |
| Syscall ABI | `a7` = number, `a0..a5` = args, `a0` = return. |
| SUM | mstatus bit. Set to let S-mode load/store U-pages. |
| `swtch.S` | 14-instr context switch. Saves/loads `ra`, `sp`, `s0..s11`. |
| Scheduler | A loop over `ptable` looking for Runnable processes. |
| MTI → SSIP | M-mode timer ISR forwards to S as a software interrupt. |
