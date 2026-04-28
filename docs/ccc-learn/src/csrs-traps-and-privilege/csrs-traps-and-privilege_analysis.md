# csrs-traps-and-privilege: In-Depth Analysis

## Introduction

A CPU that ran nothing but user code would be useless — there'd be no way to schedule, no way to handle interrupts, no way to enforce isolation between programs. RISC-V solves this with three things:

1. **Privilege levels** — M (machine), S (supervisor), U (user). The CPU is always in *one* of these.
2. **CSRs** (Control/Status Registers) — special registers, accessed via `csrr*` instructions, that hold the configuration of the privilege machinery.
3. **Traps** — the mechanism by which control transfers between privilege levels: synchronous (caused by the running instruction) or asynchronous (caused by a device).

This topic covers all three. The relevant `ccc` source is `src/emulator/csr.zig` (CSR storage rules), `src/emulator/trap.zig` (trap entry/exit), and the privilege fields in `src/emulator/cpu.zig`'s `Cpu` struct.

---

## Part 1: Privilege levels — what M / S / U actually means

`PrivilegeMode` is a 2-bit value:

```zig
pub const PrivilegeMode = enum(u2) {
    U = 0b00,    // user
    S = 0b01,    // supervisor
    reserved_h = 0b10,  // never legally seen
    M = 0b11,    // machine
};
```

The encoding matches the bits in `mstatus.MPP` / `sstatus.SPP` so the CPU never converts between formats. The `reserved_h` variant is a Zig type-safety belt — `@enumFromInt(u2)` must be total — but `csrWrite` clamps any 0b10 input to U before storage.

**Privilege isn't a hardware bit on real silicon either.** It's a state in the CPU's control unit, consulted by every load/store/fetch and every `csrr*` instruction. In `ccc` it's just `cpu.privilege`.

What changes when privilege changes?

- **CSR access** — Some CSRs are M-only (`mstatus`, `mtvec`, `mcause`, ...). A U-mode `csrr*` to an M-CSR raises `illegal_instruction`.
- **MMIO access** — All MMIO (UART, CLINT, PLIC, block) is at low addresses (`0x10000000` etc.) below RAM. With paging on, U-mode page tables don't map those regions, so attempts to access them page-fault. M-mode is identity, so M can always reach them.
- **Page-table flag enforcement** — `pte.U = 1` means "user-accessible." S can't access (without `mstatus.SUM`); U requires it. M ignores translation entirely.
- **Privileged instructions** — `mret`, `sret`, `wfi`, `sfence.vma` are gated by privilege. Calling `mret` from U mode raises `illegal_instruction`.

The hierarchy is strict: M > S > U. Higher modes can do everything lower modes can. Lower modes can ask higher modes for permission via `ecall`.

---

## Part 2: CSRs — the configuration registers

`ccc` implements the M-mode and S-mode CSRs needed for the kernel. The full list (from `src/emulator/csr.zig`):

| CSR | Address | Purpose |
|-----|---------|---------|
| `mstatus` | 0x300 | M-mode status: MIE/MPIE/MPP/MPRV/SUM/MXR/SIE/SPIE/SPP/TVM/TSR. |
| `misa` | 0x301 | Read-only. ISA string. |
| `medeleg` | 0x302 | Which sync exception causes are delegated to S. |
| `mideleg` | 0x303 | Which async interrupt causes are delegated to S. |
| `mie` | 0x304 | Per-cause interrupt enable. |
| `mtvec` | 0x305 | M-mode trap vector base address. |
| `mscratch` | 0x340 | Software scratch. |
| `mepc` | 0x341 | Saved PC at last M-trap entry. |
| `mcause` | 0x342 | Cause of last M-trap. |
| `mtval` | 0x343 | "Trap value" — faulting address, illegal-instr word, etc. |
| `mip` | 0x344 | Interrupt-pending bits (MTIP/SEIP overlaid live). |
| `sstatus` | 0x100 | S-mode view of mstatus (subset). |
| `sie` | 0x104 | S-mode view of `mie` (subset). |
| `stvec` | 0x105 | S-mode trap vector base. |
| `sscratch` | 0x140 | S-mode scratch. |
| `sepc` | 0x141 | Saved PC at last S-trap entry. |
| `scause` | 0x142 | Cause of last S-trap. |
| `stval` | 0x143 | S-trap "value" register. |
| `sip` | 0x144 | S-mode view of `mip`. |
| `satp` | 0x180 | Supervisor address translation: MODE + ASID + PPN. |

### CSR access semantics

The Zicsr extension provides 6 instructions:

| Op | Effect |
|----|--------|
| `csrrw rd, csr, rs1` | Atomic read-modify-write: rd ← csr; csr ← rs1 |
| `csrrs rd, csr, rs1` | rd ← csr; csr ← csr \| rs1 (set bits) |
| `csrrc rd, csr, rs1` | rd ← csr; csr ← csr & ~rs1 (clear bits) |
| `csrrwi`, `csrrsi`, `csrrci` | Same but rs1 is a 5-bit immediate |

Pseudo-instructions in software:
- `csrr rd, csr` ≡ `csrrs rd, csr, x0` (read-only).
- `csrw csr, rs1` ≡ `csrrw x0, csr, rs1` (write, no read).

Each access goes through `csr.zig`'s `csrRead`/`csrWrite`. These functions:

1. Check privilege (M-only CSRs raise illegal-instr in S/U).
2. Apply WARL masks — "Write Any, Read Legal." `mtvec`'s low 2 bits are MODE, restricted to 0 (Direct) or 1 (Vectored, not used in `ccc`); writes of other values are clamped to 0. `mstatus`'s reserved/unsupported bits ignore writes (read as 0).
3. For status CSRs, decompose into the per-field storage in `CsrFile`.

The flat-storage approach (`mstatus_mie: bool`, `mstatus_mpp: u2`, etc.) is faster for the hot reads (e.g., `cpu.csr.mstatus_mie` in `interruptDeliverableAt`) and removes a class of "did I forget to mask?" bugs.

---

## Part 3: Synchronous traps — `trap.enter`

Sync traps are caused by the *currently executing* instruction. In `ccc/src/emulator/trap.zig`:

```zig
pub const Cause = enum(u32) {
    instr_addr_misaligned = 0,
    instr_access_fault = 1,
    illegal_instruction = 2,
    breakpoint = 3,
    load_addr_misaligned = 4,
    load_access_fault = 5,
    store_addr_misaligned = 6,
    store_access_fault = 7,
    ecall_from_u = 8,
    ecall_from_s = 9,
    ecall_from_m = 11,
    instr_page_fault = 12,
    load_page_fault = 13,
    store_page_fault = 15,
};
```

When the executor calls `trap.enter(.ecall_from_u, pc, cpu)`:

```zig
pub fn enter(cause: Cause, tval: u32, cpu: *Cpu) void {
    const cause_code: u32 = @intFromEnum(cause);
    const delegated = (cpu.csr.medeleg >> @intCast(cause_code)) & 1 == 1;
    const target: PrivilegeMode = if (cpu.privilege != .M and delegated) .S else .M;

    switch (target) {
        .M => {
            cpu.csr.mepc = cpu.pc & MEPC_ALIGN_MASK;
            cpu.csr.mcause = cause_code;
            cpu.csr.mtval = tval;
            cpu.csr.mstatus_mpp = @intFromEnum(cpu.privilege);
            cpu.csr.mstatus_mpie = cpu.csr.mstatus_mie;
            cpu.csr.mstatus_mie = false;
            cpu.privilege = .M;
            cpu.pc = cpu.csr.mtvec & MTVEC_BASE_MASK;
        },
        .S => { /* analogous, with sepc/scause/stval/SPP/SPIE/SIE/stvec */ },
    }
    cpu.reservation = null;
    cpu.trap_taken = true;
}
```

Six things happen, in order:

1. **`mepc/sepc` ← current PC.** This is *not* PC + 4 — it's the PC of the *trapping instruction itself*. After `mret`, execution resumes at this address. For `ecall`, the kernel must `mepc += 4` before `mret` to return *past* the ecall.
2. **`mcause/scause` ← cause code.** The kernel reads this to know what kind of trap.
3. **`mtval/stval` ← `tval`.** For page faults, this is the faulting VA. For illegal-instr, the bad instruction word. For ecall, zero.
4. **Save the *previous* mode and IE bit:**
   - `mstatus.MPP ← old privilege` (or `SPP` for S-trap).
   - `mstatus.MPIE ← old MIE` (or `SPIE` for S-trap).
5. **Disable interrupts at the new privilege.** `MIE ← 0` (or `SIE ← 0`). The trap handler runs with interrupts off until it explicitly re-enables them.
6. **Switch privilege; jump to the trap vector.** `cpu.privilege = .M`; `cpu.pc = mtvec.BASE` (or `stvec.BASE`).

Plus two housekeeping details: clear the LR/SC reservation (so a trap kills any in-flight LR), set `trap_taken = true` (so `--halt-on-trap` can detect).

### Delegation

`medeleg` is a 32-bit mask. Bit `n` set means "trap with cause `n` is delegated from M to S." The delegation rule:

```
if cpu.privilege != .M AND (medeleg >> cause_code) & 1 == 1
    → trap goes to S
else
    → trap goes to M
```

The "M cannot self-delegate" rule means that even if `medeleg.ECALL_M` were set, an ecall from M still goes to M. Delegation is one-directional (toward less privilege).

`ccc`'s kernel sets `medeleg` to delegate everything S can handle: page faults, ecalls from U, illegal-instr, etc. `mideleg` does the same for async interrupts (delegate SSI, SEI, STI to S; keep MTI and MEI at M because `ccc`'s boot shim wants them).

---

## Part 4: Async interrupts — `enter_interrupt`

Async interrupts are raised by devices (timer, IRQ controller). `cpu.check_interrupt` runs at every instruction boundary; if a deliverable interrupt is pending, it calls `trap.enter_interrupt(cause_code, cpu)`.

The async path mirrors `enter` but:

- The cause register gets bit 31 set: `scause/mcause = (1 << 31) | cause_code`. This is the signal "this was an interrupt, not an exception."
- `mtval/stval` is always 0 (interrupts have no fault value).
- `mideleg` (not `medeleg`) controls delegation.
- The trace stream gets an interrupt marker line *before* the privilege switch, so the marker shows the pre-trap state.

Cause codes for async interrupts:
- 1 = SSI (S software interrupt)
- 3 = MSI (M software interrupt)
- 5 = STI (S timer interrupt)
- 7 = MTI (M timer interrupt)
- 9 = SEI (S external interrupt — from PLIC)
- 11 = MEI (M external interrupt)

The spec's priority order (when multiple are pending) is hard-coded:

```zig
pub const INTERRUPT_PRIORITY_ORDER = [_]u32{ 11, 3, 7, 9, 1, 5 };
// MEI > MSI > MTI > SEI > SSI > STI
```

`check_interrupt` walks this order and picks the first pending+enabled+deliverable cause.

---

## Part 5: Trap exits — `mret`, `sret`

`mret` undoes the M-trap entry:

```zig
pub fn exit_mret(cpu: *Cpu) void {
    cpu.pc = cpu.csr.mepc & MEPC_ALIGN_MASK;
    cpu.privilege = @enumFromInt(cpu.csr.mstatus_mpp);
    cpu.csr.mstatus_mie = cpu.csr.mstatus_mpie;
    cpu.csr.mstatus_mpie = true;
    cpu.csr.mstatus_mpp = @intFromEnum(PrivilegeMode.U);
}
```

Five things:
1. `pc ← mepc`.
2. Restore privilege from `MPP`.
3. `MIE ← MPIE`.
4. `MPIE ← 1` (the "next-trap-default" optimization).
5. `MPP ← U`.

The `MPIE ← 1; MPP ← U` resets are the spec's way of "leaving the next trap a clean slate." If the next instruction takes a trap, MIE will be 1 (because MPIE was) and MPP will reflect *that* instruction's privilege.

`sret` is analogous, with `sepc`/`SPP`/`SPIE`/`SIE` and a 1-bit SPP field.

---

## Part 6: The interaction with paging

When a U-mode load page-faults:

1. Executor calls `mem.loadByte(va, cpu)`.
2. `translate` returns `error.LoadPageFault`.
3. Executor catches it, calls `trap.enter(.load_page_fault, va, cpu)`.
4. Trap-entry routing: U-mode + `medeleg.LOAD_PAGE_FAULT` set → target is S.
5. Set `sepc = pc`, `scause = 13`, `stval = va`. Switch to S, jump to `stvec`.
6. The kernel's S-mode trap dispatcher (see [kernel-boot-and-syscalls](#kernel-boot-and-syscalls)) reads `scause`, sees 13, dispatches to its page-fault handler.

This is the *only* path by which the S-mode kernel learns about a page fault. The CPU doesn't call back; it just lands the kernel at `stvec` with the right state in CSRs.

---

## Part 7: The SIE-window bug (Plan 3.E story)

When the scheduler has nothing to do (all processes blocked), it executes `wfi`. The CPU calls `idleSpin`. While idling, a device interrupt arrives. We *want* it to be delivered to S-mode so the trap handler runs.

But `wfi` runs with `sie = 1` only briefly — `cpu.privilege = .S` and `mstatus_sie = 1` is required for an SEI to be deliverable to S. If the scheduler has set `SIE = 0` to protect its own data structures, the IRQ pends indefinitely.

The fix: a **SIE window**. The scheduler explicitly sets `SIE = 1` for one instruction (the `wfi`) and back to 0 when `wfi` completes. If a trap fires during the window, it's delivered; if not, the next instruction runs with `SIE = 0` again.

`ccc`'s implementation uses a separate trap entry point (`s_kernel_trap_entry` in `trampoline.S`) that the scheduler points `stvec` at while in the window. Subtle — but without it, the FS demo (which depends on block-device IRQs) would hang.

---

## Summary & Key Takeaways

1. **Three privilege levels: M, S, U.** Each is a 2-bit value in `cpu.privilege` plus the CSR fields. M > S > U; higher modes can do everything lower can.

2. **CSRs are configuration registers** accessed via `csrr*` instructions. M-only CSRs raise illegal-instr in S/U.

3. **`mstatus` is split per-field in `CsrFile`** for fast reads — `mstatus_mie: bool`, `mstatus_mpp: u2`, etc.

4. **Synchronous traps fire at the trapping instruction.** `mepc/sepc` capture the PC of *that* instruction, not the next one. Software must advance past it before returning (e.g., `mepc += 4` after an `ecall`).

5. **Async interrupts fire between instructions.** `cpu.check_interrupt` runs at the top of every `step`.

6. **Trap entry saves prev-state and clears IE.** `MPP` ← old privilege, `MPIE` ← old MIE, `MIE` ← 0.

7. **`mret` / `sret` undo trap entry.** Restore PC + privilege + IE; reset MPP/MPIE for the next trap.

8. **Delegation routes traps from M to S.** `medeleg` for sync, `mideleg` for async. M cannot self-delegate.

9. **Cause encoding: bit 31 distinguishes async from sync.** `mcause = (1 << 31) | code` for interrupts; raw code for exceptions.

10. **Interrupt priority is hard-coded.** MEI > MSI > MTI > SEI > SSI > STI.

11. **The LR/SC reservation clears on every trap.** Spec rule. Implemented as one line in `enter`/`enter_interrupt`.

12. **The SIE window is a `ccc` workaround for `wfi`-during-idle.** A separate trap entry lets the scheduler enable interrupts for exactly one instruction.
