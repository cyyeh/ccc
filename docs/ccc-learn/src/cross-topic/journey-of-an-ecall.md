# Walkthrough: The Journey of a Single `ecall`

> A single syscall — `write(1, "hi\n", 3)` — traced from the user-side `_start` through the kernel and back. Every register, every CSR write, every page-table touch, in order.

This walkthrough assumes you've read [rv32-cpu-and-decode](#rv32-cpu-and-decode), [csrs-traps-and-privilege](#csrs-traps-and-privilege), [kernel-boot-and-syscalls](#kernel-boot-and-syscalls), and [processes-fork-exec-wait](#processes-fork-exec-wait). It's the integrative single-page reference for "what *actually* happens when user code does a syscall."

We use the simplest possible scenario: a U-mode program that calls `write(1, "hi\n", 3)` and exits. Setup: `kernel.elf` is running. PID 1 has just been built with the user program loaded. The scheduler has `swtch`'d into PID 1's context, which `sret`'d into U-mode at `_start`. The trap frame has zero regs except as set up by exec. The user page table is installed (`satp` points at it). `mstatus.SPP = 0` (U), `SPIE = 1`.

Sit tight. We're about to make ~30 layered things happen.

---

## Stage 0: The user program calls `write`

```zig
// In user code:
_ = write(1, "hi\n", 3);
```

`write` is defined in `usys.S`:

```
.global write
write:
    li a7, 64
    ecall
    ret
```

So at user-code level, the compiled sequence is:

```
# load args (caller's responsibility):
addi a0, zero, 1            # fd
auipc a1, %hi("hi\n"); addi a1, a1, %lo("hi\n")  # buffer
addi a2, zero, 3            # length
# call write:
jal ra, write
# (instruction at ra continues after the call returns)
```

When PC reaches `write` (which is now in user memory at some address — say, `0x10000280`):

- `li a7, 64`  ← `a7 = 64` (write syscall number).
- `ecall`      ← the trap.

---

## Stage 1: `ecall` decodes & dispatches

The CPU's `cpu.step()` runs:

1. **Service deferred IRQs.** None.
2. **Check async interrupts.** None pending; skip.
3. **Fetch.** `pc = 0x10000284` (the ecall). Translate via current privilege (U) + Sv32. Walk the user page table; lands at some PA in user RAM. `loadWordPhysical` returns the encoding `0x00000073` (the canonical `ecall`).
4. **Decode.** `decoder.decode(0x00000073)` returns `Instruction{op = .ecall, rd = 0, rs1 = 0, ...}`.
5. **Dispatch.** `execute.dispatch` enters the `.ecall` arm.

The `.ecall` arm:

```zig
.ecall => {
    const cause: trap.Cause = switch (cpu.privilege) {
        .U => .ecall_from_u,
        .S => .ecall_from_s,
        .M => .ecall_from_m,
        else => unreachable,
    };
    trap.enter(cause, 0, cpu);
    return;
},
```

So `trap.enter(.ecall_from_u, tval=0, cpu)` is called.

---

## Stage 2: `trap.enter` — the trap-routing dance

`trap.enter` decides where the trap goes:

```zig
const cause_code = 8;  // @intFromEnum(Cause.ecall_from_u)
const delegated = (cpu.csr.medeleg >> 8) & 1 == 1;  // is bit 8 set?
const target = if (cpu.privilege != .M and delegated) .S else .M;
```

Since `medeleg.bit_8` was set by the boot shim, `target = .S`. The S-trap arm runs:

```zig
.S => {
    cpu.csr.sepc = cpu.pc & MEPC_ALIGN_MASK;     // sepc = 0x10000284
    cpu.csr.scause = 8;                            // ecall_from_u
    cpu.csr.stval = 0;
    cpu.csr.mstatus_spp = 0;                       // SPP = 0 (was U)
    cpu.csr.mstatus_spie = cpu.csr.mstatus_sie;    // SPIE = current SIE
    cpu.csr.mstatus_sie = false;                   // SIE = 0 (disable)
    cpu.privilege = .S;                            // now in S
    cpu.pc = cpu.csr.stvec & MTVEC_BASE_MASK;      // pc = stvec.BASE
},
cpu.reservation = null;                            // clear LR/SC reservation
cpu.trap_taken = true;
```

State changes:
- `pc = 0x80000800` (let's say that's where stvec points — at the trampoline's `s_trap_entry`).
- `cpu.privilege = .S`.
- `mstatus.SIE = 0` (interrupts disabled).
- `sepc = 0x10000284` (the ecall's PC).
- `scause = 8`.
- The user's regs are *unchanged* — they're still in `cpu.regs[0..31]`. They'll be saved to the trap frame next.

---

## Stage 3: `s_trap_entry` (asm in `trampoline.S`)

The CPU is now executing the first instruction at `0x80000800`. That's the trampoline page, mapped in the user's page table as kernel-only-X. Even though we're in S-mode now, the same page is mapped (because the trampoline is in every address space at the same VA).

`s_trap_entry`'s job is to:

1. **Save user regs** to the trap frame.
2. **Switch satp** to the kernel page table.
3. **Switch sp** to the kernel stack.
4. **Call** the C/Zig dispatcher.

It uses `sscratch` as a temporary. Before the trap, the kernel had pre-stashed PID 1's trap-frame address in `sscratch`. The first instruction:

```
csrrw a0, sscratch, a0   ; swap a0 with sscratch — a0 now holds trap_frame_va
```

Then save user regs:

```
sw ra, 0(a0)
sw sp, 4(a0)
sw gp, 8(a0)
... (every reg, including a0 from sscratch — read it back)
```

`a0` was already saved using sscratch's swap; restore the original a0 from the swap. Save sepc and sstatus:

```
csrr t0, sepc
sw t0, OFF_SEPC(a0)
csrr t0, sstatus
sw t0, OFF_SSTATUS(a0)
```

Now load the kernel's bookkeeping:

```
lw t0, OFF_KSTACK(a0)        ; per-process kernel-stack VA
csrw satp, kernel_satp_value ; switch to kernel page table
sfence.vma                    ; (no-op in ccc)
mv sp, t0                    ; switch stack
```

After this, `sp` is the per-process kernel stack, `satp` is the kernel page table, and the user's regs are all in the trap frame.

Finally:

```
mv a0, p_argument            ; pass *Process to dispatcher
call s_kernel_trap_dispatch
```

---

## Stage 4: `s_kernel_trap_dispatch` (Zig in `trap.zig`)

```zig
pub fn dispatch(p: *Process) void {
    const scause = read_scause();
    if (scause & (1 << 31) != 0) {
        // async interrupt
        ...
    } else {
        switch (scause) {
            8 => syscall.dispatch(p),
            12, 13, 15 => handle_page_fault(p, scause),
            ...
        }
    }
}
```

`scause = 8` → `syscall.dispatch(p)`.

---

## Stage 5: `syscall.dispatch` (Zig in `syscall.zig`)

```zig
pub fn dispatch(p: *Process) void {
    const num = p.trapframe.a7;
    p.trapframe.a0 = switch (num) {
        64 => sys_write(p),
        93 => sys_exit(p),
        ...
    };
    p.trapframe.sepc += 4;       // resume past ecall
    if (p.killed) proc.exit(p, 1);
}
```

`a7 = 64` → `sys_write(p)`.

---

## Stage 6: `sys_write` (Zig in `syscall.zig`)

```zig
pub fn sys_write(p: *Process) i32 {
    const fd = @as(i32, @bitCast(p.trapframe.a0));        // 1
    const buf_va = p.trapframe.a1;                         // user pointer
    const len = p.trapframe.a2;                            // 3

    const f = p.ofile[@intCast(fd)] orelse return -1;
    if (!f.writable) return -1;

    // For a Console-type fd 1:
    if (f.type == .Console) {
        setSum();                                          // SUM = 1
        defer clearSum();
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            const byte = @as(*u8, @ptrFromInt(buf_va + i)).*;
            console.putByte(byte);                         // → uart.writeByte → THR → host stdout
        }
        return @intCast(len);
    }
    // Inode-type fd: writei via bufcache + balloc.
    ...
}
```

(Code simplified — actual implementation may copy the whole buffer to a kernel scratch then call `console.write`.)

The interesting parts:

1. **`setSum()`** — sets `mstatus.SUM = 1` so the kernel can read user pointers.
2. **Read `buf_va + i`** — translates through the kernel page table. The kernel's page table identity-maps user RAM, so the load just works (with SUM allowing U-pages).
3. **`console.putByte(byte)`** — writes the byte to the UART THR. The UART forwards to the host writer (stdout). 'h', 'i', '\n' appear on the console.

Returns 3 (bytes written).

---

## Stage 7: Back through dispatch

`sys_write` returned 3. `syscall.dispatch` writes 3 to `p.trapframe.a0`. `sepc += 4` so on return, the user resumes at `0x10000288` (the ret after ecall). Check `p.killed`: false. Return.

---

## Stage 8: `s_trap_entry` exit (the asm's tail)

After `s_kernel_trap_dispatch` returns, the asm does the inverse of the entry:

```
; restore user state from trap frame
lw t0, OFF_SEPC(a0)
csrw sepc, t0
lw t0, OFF_SSTATUS(a0)
csrw sstatus, t0

; switch satp back to user pt
lw t0, OFF_USER_SATP(a0)
csrw satp, t0

; restore user regs
lw ra, 0(a0)
lw sp, 4(a0)
... (all regs, finally a0 itself)

; sret
sret
```

`sret` does the trap exit:
- `pc = sepc = 0x10000288`.
- `cpu.privilege = .U` (from `sstatus.SPP = 0`).
- `mstatus.SIE = SPIE = 1`.
- `mstatus.SPIE = 1`, `mstatus.SPP = 0` (reset to next-trap defaults).

---

## Stage 9: Back in user mode

The CPU is now at `0x10000288`. That's the `ret` after the `ecall` in `usys.S`'s `write` function:

```
.global write
write:
    li a7, 64
    ecall
    ret           ← we're here
```

`ret` is `jalr x0, 0(ra)` — jump to `ra`, no link. So PC becomes `ra`, which the caller set before `jal write`. The caller continues. `a0` holds the return value (3) for the caller to read.

---

## What happened, register-by-register

| Reg / CSR | Pre-trap | Mid-trap (S) | Post-trap |
|-----------|----------|--------------|-----------|
| `pc` | `0x10000284` | `0x80000800 → ...` | `0x10000288` |
| `cpu.privilege` | U | S | U |
| `mstatus.SIE` | 1 | 0 | 1 (restored from SPIE) |
| `mstatus.SPP` | 0 | 0 | 0 (reset by sret) |
| `mstatus.SPIE` | 1 | 1 (saved) | 1 (reset by sret) |
| `sepc` | (whatever) | `0x10000284 → 0x10000288` | (whatever) |
| `scause` | (whatever) | 8 | (kept as 8, but unused) |
| `stval` | (whatever) | 0 | (whatever) |
| `satp` | user pt | user pt → kernel pt → user pt | user pt |
| `a7` | 64 | 64 (read by dispatch) | 64 (preserved through trap frame) |
| `a0` | 1 | 1 (read by sys_write), then 3 (written) | 3 |

Plus device side-effects:
- UART THR: 'h', 'i', '\n' all written. Host stdout printed `hi\n`.

That's the entire journey: **user → ecall → trap.enter → s_trap_entry → dispatch → sys_write → UART → exit dispatch → s_trap_entry tail → sret → user.** Eight or so distinct phases, each with its own state mutations.

If you can hold this picture in your head, the rest of `ccc`'s kernel is just *more of this*: page faults take the same path with different scause; timer interrupts take a parallel path through enter_interrupt; the only thing that varies is what happens between the trap-frame save and restore.
