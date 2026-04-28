# csrs-traps-and-privilege: A Beginner's Guide

## Why Does a CPU Need "Modes"?

Imagine a corporate office. There are interns (low trust), employees (medium trust), and the CEO (full trust). The CEO can do anything. Employees can use most company resources but not, say, fire other employees or look at salary data. Interns can only do what employees explicitly authorized.

Now: every action gets one of three labels.
- **Stuff anyone can do.** "Read your own files."
- **Stuff requiring employee status.** "Reorder office furniture."
- **Stuff requiring CEO status.** "Sign a billion-dollar contract."

When an intern wants something employee-level, they file a request. The employee reads it, decides, acts on the intern's behalf, and returns the result. Same pattern for employee-to-CEO requests.

This is exactly how a CPU works. The three modes are:

- **U-mode (User)** — interns. Run programs, read your own memory, ask the kernel for help.
- **S-mode (Supervisor)** — employees. The kernel. Manage processes, page tables, files.
- **M-mode (Machine)** — the CEO. The boot shim, the firmware. Full hardware access.

The "request" mechanism is called a **trap**. Specifically, when a U-mode program executes the `ecall` instruction, the CPU traps to S-mode (or M-mode, depending on configuration), runs a handler, and returns. That's how a `printf` becomes a `write` syscall becomes a UART byte.

---

## What's a CSR?

CSR = "Control/Status Register." Think of them as the CPU's settings panel. They live separately from the regular `x0..x31` registers and you access them with special instructions:

```
csrr a0, mstatus   ; read mstatus into a0
csrw mstatus, a0   ; write a0 into mstatus
```

Examples:
- **`mtvec`** — "where to jump on a trap." The kernel sets this once at boot to point at its trap handler.
- **`mepc`** — "saved PC at the last trap." The kernel reads this to know what was running.
- **`mcause`** — "why did the last trap happen?" Kernel reads this to dispatch.
- **`mstatus`** — a bag of bits including "interrupts enabled?" and "previous privilege level."
- **`satp`** — "current page table address" (for the paging chapter).

There are dozens of CSRs in the spec. `ccc` implements maybe ~20 — the ones the kernel and emulator actually need. See `src/emulator/csr.zig` for the full list.

---

## What's a Trap?

A trap is "something happened that needs attention from a higher-privilege handler." Two kinds:

1. **Synchronous (exception).** The current instruction caused it. Examples:
   - User did `ecall` (deliberate request).
   - Bad pointer dereference → page fault.
   - Decoded an illegal instruction.
   - Did a misaligned load.
2. **Asynchronous (interrupt).** Something *external* caused it. Examples:
   - The timer fired.
   - A device sent data over the UART.
   - A disk operation finished.

Either way, the same machinery runs:
1. CPU saves the current PC into `mepc` (or `sepc`).
2. CPU saves the current privilege into `MPP` (or `SPP`).
3. CPU writes the cause into `mcause` (or `scause`).
4. CPU disables interrupts (`MIE = 0`).
5. CPU switches privilege (to M or S, depending on delegation).
6. CPU jumps to `mtvec` (or `stvec`).

The kernel's handler reads `mcause`, decides what to do, does it, and then executes `mret` (or `sret`) to undo all the above and resume where the trapped instruction was.

---

## Why Are There SO MANY CSRs Just for Status?

`mstatus` looks scary. It's got bits for:
- `MIE` — M Interrupts Enabled?
- `MPIE` — M Previous IE (saved across traps)?
- `MPP` — M Previous Privilege (saved across traps)?
- `SIE`, `SPIE`, `SPP` — S-mode versions of the above.
- `MPRV` — "Modify Privilege" (let M loads/stores act as user)?
- `SUM` — "Supervisor User Memory" (let S access user pages)?
- `MXR` — "Make eXecutable Readable" (let X-bit imply R for loads)?
- ...

Why so many? Because every one of these is a tiny bit of policy that affects the *next* memory access or interrupt delivery, and the kernel needs to flip them precisely.

`ccc` stores these as separate fields in the `CsrFile` struct (`mstatus_mie: bool`, `mstatus_mpp: u2`, etc.) instead of bit-packing them. That's faster to read and harder to break. When code reads or writes the *whole* `mstatus` value via `csrrw`, the access functions in `csr.zig` reassemble or decompose the fields.

---

## Delegation: Why Bother?

Without delegation, every trap (every page fault, every syscall, every timer tick) goes to M-mode. M-mode handles it, decides "this is really a kernel job, let me forward to S," sets up the S-trap state, and `mret`s into S. That's two trap entries for one logical event — inefficient.

**Delegation says: "trap cause N goes straight to S, skip M."** It's a 32-bit mask: bit N set in `medeleg` (for sync) or `mideleg` (for async) means "delegate cause N to S."

`ccc`'s kernel delegates almost everything S can handle: ecalls from U, page faults, the SSI/SEI/STI interrupts. The boot shim keeps the timer interrupt (MTI) at M-mode because it wants to do the bookkeeping itself.

A subtle rule: **M cannot self-delegate.** Even if you set `medeleg.ECALL_M`, an ecall from M still traps to M. Delegation only works "downward" (M → S, never sideways).

---

## Walking Through `ecall`

You're in U-mode. You execute `ecall` (after putting a syscall number in `a7` and arguments in `a0..a5`). What happens?

1. **CPU decodes `ecall`.** Dispatch enters the `.ecall` arm.
2. **Dispatch calls `trap.enter(.ecall_from_u, pc, cpu)`.** ("Sync trap, cause = 8, no fault value.")
3. **`enter` consults `medeleg.ECALL_FROM_U`.** Suppose it's 1 (kernel delegated).
4. **Target = S.** Routing decided.
5. **Save state.** `sepc ← pc`, `scause ← 8`, `stval ← 0` (no fault VA), `SPP ← 0` (was U), `SPIE ← old SIE`, `SIE ← 0`.
6. **Switch privilege.** `cpu.privilege = .S`.
7. **Jump.** `pc ← stvec.BASE`.
8. **The kernel's S-mode trap handler runs.** Reads `scause`, sees 8 (ECALL_U), dispatches to `syscall.zig`.
9. **Handler runs the requested syscall.** Sets the return value in `a0`.
10. **Handler does `sepc += 4`.** So we resume *past* the `ecall`.
11. **Handler executes `sret`.** Undoes step 5/6/7: `pc ← sepc`, `cpu.privilege = .U`, `SIE ← SPIE`, `SPIE ← 1`, `SPP ← 0`.
12. **Back in U-mode.** The instruction after `ecall` runs. The user code reads `a0` for the return value.

That's a **system call**. It's a trap. The whole machinery exists to make this round-trip safe and isolated.

---

## What If a Trap Happens *During* a Trap Handler?

It can. If the kernel's handler dereferences a bad pointer, it page-faults. Now:
- The kernel was in S-mode.
- A page fault from S-mode goes to M-mode (delegation only works toward less privilege).
- M-mode catches it; in `ccc` the M-mode monitor either fixes it or panics.

To prevent this scenario, kernels write trap handlers carefully — every load/store inside is checked, page tables are pre-built, etc. We dive into this in [kernel-boot-and-syscalls](#kernel-boot-and-syscalls).

---

## What Does `MIE = 0` Inside a Trap Mean?

When the CPU enters a trap, **interrupts are disabled at the new privilege level.** So if the handler is in S-mode, `SIE` is now 0 — no async interrupts will fire while the handler runs.

This is a safety thing: the handler shouldn't be re-entered before its own data structures are consistent. The handler can re-enable interrupts after saving the trap frame, if it wants to allow nested trap handling.

`ccc`'s kernel keeps interrupts disabled for the whole syscall handler — short and predictable. `wfi` requires a brief reenable (the SIE window — see analysis Part 7).

---

## Quick Reference

| Concept | One-liner |
|---------|-----------|
| Privilege level | M (machine), S (supervisor), U (user). Stored in `cpu.privilege`. |
| CSR | A side-shelf register accessed via `csrr*` — holds CPU configuration. |
| Trap | Sync (exception) or async (interrupt) transfer of control to a higher privilege. |
| `mtvec`/`stvec` | Trap vector base — where the CPU jumps on M/S trap. |
| `mepc`/`sepc` | Saved PC at trap entry. The trapping instruction's address. |
| `mcause`/`scause` | Why the trap fired. Bit 31 = async; rest = cause code. |
| `mtval`/`stval` | "Trap value" — fault VA, illegal opcode, or 0. |
| `MIE`/`SIE` | Global interrupt-enable bits. |
| `MPP`/`SPP` | Previous privilege saved across traps. |
| `MPIE`/`SPIE` | Previous IE saved across traps. |
| Delegation | `medeleg`/`mideleg` mask routes M traps to S. |
| `mret`/`sret` | Trap return — undoes the trap entry. |
| `ecall` | "I am asking my supervisor for help." Sync trap to higher privilege. |
| `wfi` | "Wait for interrupt." CPU pauses fetching until an async event. |
