# Phase 2 — Bare-Metal Kernel (Design)

**Project:** From-Scratch Computer (directory `ccc/`).
**Phase:** 2 of 6 — see `2026-04-23-from-scratch-computer-roadmap.md`.
**Status:** Approved design, ready for implementation planning.

## Goal

Boot a bare-metal kernel in Zig on our Phase 1 emulator (extended with
S-mode, Sv32 paging, trap delegation, and async interrupts). One
embedded user program runs in U-mode under its own Sv32 page table,
calls `write`, `yield`, and `exit` via `ecall`, and the kernel services
those syscalls in S-mode. A `Process` struct and a scheduler stub are
invoked from both the timer ISR and `sys_yield`, laying the groundwork
Phase 3 will fill in with fork/exec and a real picker.

## Definition of done

- `zig build kernel` produces `kernel.elf`.
- `ccc kernel.elf` prints exactly
  ```
  hello from u-mode
  ticks observed: N
  ```
  where `N` is a positive integer dependent on run time, then exits 0.
- Our emulator and `qemu-system-riscv32 -machine virt -bios none -kernel
  kernel.elf -nographic` produce identical UART output (QEMU-diff
  harness passes).
- Emulator passes `rv32si-p-*` riscv-tests in addition to Phase 1's
  `rv32ui`/`um`/`ua`/`mi` suites.
- `--trace` works across M/S/U; privilege transitions are visible in
  trace lines (privilege-column `[M]`/`[S]`/`[U]`).
- Phase 1's demos (`e2e`, `e2e-mul`, `e2e-trap`, `e2e-hello-elf`) and
  `riscv-tests` run unchanged — Phase 2 never regresses Phase 1.

## Scope

### In scope

- **ISA additions:** `sret`, `sfence.vma`, S-mode CSR access. No new
  arithmetic or memory ops.
- **Privilege:** M (boot shim + timer ISR + undelegated traps), S
  (kernel — vast majority of runtime), U (the user program).
- **Delegation:** `medeleg` + `mideleg`. U-mode synchronous traps
  (ECALL, page faults, misaligned, illegal) delegated to S. `MTIP`
  **not** delegated — M-mode forwards each tick to S by raising
  `mip.SSIP` (supervisor software interrupt). We use SSIP rather than
  STIP because without SSTC, STIP is read-only in `sip` and cannot be
  cleared from S-mode; SSIP is S-writable and is the standard
  non-SSTC pattern (xv6-riscv).
- **Async interrupts:** CPU checks `mip & mie` at instruction
  boundaries; highest-priority enabled pending interrupt wins;
  per-privilege interrupt enable gating (`mstatus.MIE`,
  `sstatus.SIE`).
- **Sv32 paging:** 2-level, 4 KB pages only (no 4 MB superpages —
  a superpage leaf in a walked table is treated as a fault).
  No TLB modeling; every access re-walks.
- **Per-process page table:** one root per process, containing kernel
  direct-mapped at `0x80000000+` (supervisor-only) and user pages at
  `0x00010000+` (U-accessible). MMIO identity-mapped (supervisor-only).
- **Kernel reads user memory** via `sstatus.SUM = 1` for the duration
  of the copy; no fault-safe access (any kernel-origin page fault
  panics in Phase 2).
- **Process struct:** trapframe, satp value, state, kernel stack top,
  tick counter, exit code. One instance, statically allocated.
- **Scheduler stub:** invoked from timer ISR and `sys_yield`; always
  re-picks the same process. Context-switch code (satp write +
  `sfence.vma` + trapframe restore) runs unconditionally.
- **Syscalls:** `write(fd, buf, len)`, `exit(status)`, `yield()`,
  numbered 64 / 93 / 124 to match the Linux RISC-V ABI subset.
- **Kernel build:** freestanding Zig + M-mode boot-shim asm +
  trampoline asm + `@embedFile`'d flat user blob; custom linker script
  places kernel at `0x80000000`.
- **Testing:** unit tests for all new emulator pieces, `rv32si-p-*`
  integration, kernel e2e test, QEMU-diff harness extended for the
  kernel ELF.

### Out of scope (deferred)

- Multiple processes, fork/exec, process table — Phase 3.
- Filesystem, block device — Phase 3.
- PLIC (external interrupt controller) — Phase 3 if needed.
- UART receive / keyboard input — Phase 3.
- Sv32 4 MB superpages — never in Phase 2; revisit if ever justified.
- Hardware TLB modeling — re-walk is fine.
- SSTC extension (native S-mode timer CSRs) — we use the SSIP
  M-forwarding pattern instead.
- GDB remote stub.
- ASID support — `satp.ASID = 0` throughout; `PTE.G = 1` on kernel
  pages as cosmetic documentation only.

## Architecture

### Emulator modules (Phase 1 modules, growing)

| Module | Phase 1 role | Phase 2 additions |
|---|---|---|
| `cpu.zig` | M/U privilege, M-CSRs, step/run | S-mode privilege; async interrupt check at each instruction boundary; interrupt-priority resolution |
| `csr.zig` | M-CSRs | `sstatus`, `stvec`, `sepc`, `scause`, `stval`, `satp`, `sie`, `sip`, `medeleg`, `mideleg`, plus S-CSR aliasing (`sstatus` is a masked window on `mstatus`, `sie`/`sip` on `mie`/`mip`) |
| `decoder.zig` | RV32IMA + Zicsr + Zifencei + `mret`/`wfi` | `sret`, `sfence.vma` |
| `execute.zig` | RV32IMA execution | `sret` (mirror of `mret`); `sfence.vma` (no-op in our no-TLB model, still privilege-checked) |
| `trap.zig` | M-mode synchronous trap entry + `mret` | Delegation-aware target-privilege selection; async interrupt entry; `sret` exit |
| `memory.zig` | RAM + MMIO routing by physical address | Sv32 translation layer in front of RAM access (walk table when privilege ∈ {S, U} and `satp.MODE = Sv32`); translation faults become page-fault traps; MMIO bypasses translation (kernel identity-maps MMIO) |
| `devices/clint.zig` | `mtime`, `mtimecmp`, `msip` registers | Raises `mip.MTIP` edge when `mtime ≥ mtimecmp` and `mtimecmp ≠ 0` |

### Kernel modules (new, under `tests/programs/kernel/`)

```
tests/programs/kernel/
├── build.zig                 builds kernel.elf
├── linker.ld                 kernel at 0x80000000
├── boot.S                    M-mode boot shim: delegation + timer + drop to S
├── mtimer.S                  M-mode timer ISR: forwards MTIP → mip.SSIP
├── trampoline.S              S-mode trap entry/exit asm (save/restore, sret)
├── kmain.zig                 S-mode entry: init VM, init proc, start user
├── vm.zig                    Sv32 page-table construction + walk + satp switch
├── page_alloc.zig            bump-style physical page allocator
├── proc.zig                  Process struct + the single instance
├── sched.zig                 scheduler stub (always re-picks same process)
├── trap.zig                  S-mode trap dispatcher (syscall vs timer vs fault)
├── syscall.zig               write / exit / yield
├── uart.zig                  kernel-side MMIO UART writer
├── kprintf.zig               minimal kernel printf
└── user/
    ├── build.zig             builds userprog.bin (flat binary)
    ├── user_linker.ld        user .text at VA 0x00010000
    └── userprog.zig          hello-from-u-mode payload
```

The kernel is a sibling artifact to `hello.elf`. `ccc` itself doesn't
change — it still loads an ELF and sets `PC ← e_entry` in M-mode.

## Memory layout

### Physical address space (unchanged from Phase 1)

| Address      | Size   | Purpose                                  |
|--------------|--------|------------------------------------------|
| `0x00001000` | 4 KB   | Boot ROM (still reserved, still unused)  |
| `0x00100000` | 8 B    | Halt MMIO                                |
| `0x02000000` | 64 KB  | CLINT                                    |
| `0x10000000` | 256 B  | NS16550A UART                            |
| `0x80000000` | 128 MB | RAM                                      |

We continue to cheat the reset: `ccc` loads `kernel.elf` and sets
`PC ← e_entry` directly in M-mode. Phase 3 may populate the boot ROM.

### Kernel RAM usage (physical)

```
0x80000000  ┌─────────────────┐  ← e_entry (boot.S first insn)
            │ kernel .text    │
            │ kernel .rodata  │  (contains embedded userprog blob)
            │ kernel .data    │
            │ kernel .bss     │
            │ kernel stack    │  (16 KB)
0x8NNNNNNN  ├─────────────────┤  ← _end (linker symbol)
            │                 │
            │  free physical  │  ← page_alloc bumps upward from here
            │     pages       │  (used for page tables + user frames)
            │                 │
0x88000000  └─────────────────┘
```

### Virtual address space per process (Sv32)

One page-table root per process. Phase 2 has one process, so one
root, containing:

| VA range | Purpose | Perm |
|---|---|---|
| `0x00010000 – 0x0002FFFF` | User `.text` / `.rodata` / `.data` / `.bss` | U, R/W/X per segment |
| `0x00030000 – 0x00031FFF` | User stack (2 × 4 KB), `sp` initial = `0x00032000` | U, R/W |
| `0x00100000 – 0x00100FFF` | Halt MMIO (identity-mapped) | S, R/W |
| `0x02000000 – 0x0200FFFF` | CLINT (identity-mapped) | S, R/W |
| `0x10000000 – 0x10000FFF` | UART (identity-mapped) | S, R/W |
| `0x80000000 – 0x87FFFFFF` | Kernel RAM (direct-mapped, VA = PA) | S, R/W/X per page, `G=1` |

Kernel VA = kernel PA (direct map). Kernel reads user memory via
`sstatus.SUM = 1` for the duration of the copy.

## Devices

- **UART (`0x10000000`)** — unchanged from Phase 1. Still output-only.
- **CLINT (`0x02000000`)** — same register set; the timer now actually
  fires. When `mtime ≥ mtimecmp` and `mtimecmp ≠ 0`, the emulator
  raises `mip.MTIP`. Writing `mtimecmp` to a value greater than `mtime`
  clears `mip.MTIP`. `msip` remains present but never raised (Phase 3
  uses it for IPIs in a multi-hart world).
- **Halt MMIO (`0x00100000`)** — unchanged. Used by `sys_exit` and by
  riscv-tests termination.
- **Boot ROM** — still reserved, still unused.

## Privilege & trap model

### Runtime share

- **M-mode:** boot shim (once) + timer ISR (each tick). Nothing else.
- **S-mode:** the kernel. Trap dispatcher, syscall handlers, scheduler
  stub, page-table management, `kprintf`.
- **U-mode:** the user program.

### CSRs

| Group | CSRs | Notes |
|---|---|---|
| M-mode machine info | `mhartid`, `mvendorid`, `marchid`, `mimpid`, `misa` | `misa` now encodes the **S bit** in addition to I+M+A+U |
| M-mode trap state | `mstatus`, `mtvec`, `mepc`, `mcause`, `mtval`, `mie`, `mip` | `mstatus` gains `SPP`, `SPIE`, `SIE`, `SUM`, `MXR`, `MPRV` |
| M-mode delegation | `medeleg`, `mideleg` | new; `mideleg[MTIP]=0` hardwired; `mideleg[SSIP]=1` set by boot shim; `mideleg[STIP]` writable but unused in Phase 2 |
| S-mode | `sstatus`, `stvec`, `sepc`, `scause`, `stval`, `satp`, `sie`, `sip` | new; `sstatus` is a masked window on `mstatus`; `sie`/`sip` on `mie`/`mip` |

### Delegation

Boot shim sets:

```
medeleg = (1<<0)   // inst addr misaligned  → S
        | (1<<2)   // illegal instruction    → S
        | (1<<4)   // load addr misaligned   → S
        | (1<<6)   // store addr misaligned  → S
        | (1<<8)   // ECALL from U           → S
        | (1<<12)  // inst page fault        → S
        | (1<<13)  // load page fault        → S
        | (1<<15)  // store page fault       → S

mideleg = (1<<1)   // SSIP (software-forwarded timer tick) → S
// MTIP (bit 7) is NOT delegated — M-mode handles CLINT and
// forwards to S by raising mip.SSIP.
// STIP is not used (read-only in sip; unusable without SSTC).
```

`ECALL_FROM_S` (cause 9) and `ECALL_FROM_M` (cause 11) are not
delegated — they terminate in M with a panic if they ever fire in
Phase 2.

### Synchronous trap entry (delegated U→S path)

When a U-mode instruction raises an exception with `medeleg[cause]=1`:

1. `sepc ← PC` of trapping instruction.
2. `scause ← cause`.
3. `stval ← faulting VA` (page faults, misaligned) or `0`.
4. `sstatus.SPP ← U`; `sstatus.SPIE ← sstatus.SIE`; `sstatus.SIE ← 0`.
5. Privilege ← S.
6. `PC ← stvec.BASE`. (Direct mode only; vectored mode ignored.)

Non-delegated exceptions follow the Phase 1 M-mode entry path
unchanged.

### Trap exit via `sret`

1. `PC ← sepc`.
2. Privilege ← `sstatus.SPP`.
3. `sstatus.SIE ← sstatus.SPIE`; `sstatus.SPIE ← 1`;
   `sstatus.SPP ← U`.

(`mret` path is unchanged from Phase 1.)

### Async interrupt flow (the timer story)

MTIP is not delegable, and STIP is unusable in S-mode (read-only in
`sip` without SSTC). We piggyback on **SSIP** — supervisor software
interrupt — which IS S-writable. Timer delivery to S takes two hops:

1. CLINT raises `mip.MTIP = 1` when `mtime ≥ mtimecmp`.
2. At the next instruction boundary (regardless of current privilege),
   the CPU checks for an enabled pending interrupt. For M-mode with
   `mstatus.MIE = 1` and `mie.MTIE = 1`: async trap to M-mode. (For
   lower privileges, M interrupts are globally enabled by virtue of
   not being the current privilege.)
3. M-mode timer ISR (`mtimer.S`):
   - Advance `mtimecmp ← mtime + TIMESLICE` (clears MTIP by moving
     the threshold forward).
   - Set `mip.SSIP = 1` (`csrs mip, 2`) — supervisor software
     interrupt pending; delegated to S via `mideleg[SSIP]=1`.
   - `mret`.
4. `mret` returns to wherever we were (S or U). At the next
   instruction boundary, if we're in S with `sstatus.SIE = 1` and
   `sie.SSIE = 1`, or in U (lower privilege), async trap to S-mode
   at `stvec`.
5. S-mode supervisor-software ISR (in `trap.zig`):
   - Clear `mip.SSIP = 0` via `csrc sip, 2` (SSIP is S-writable
     through the `sip` view).
   - `the_process.ticks_observed += 1`.
   - Call `sched.schedule()` (returns the same process in Phase 2).
   - Return-to-user path runs `satp` write + `sfence.vma` + trapframe
     restore + `sret`.

Interrupt priority at instruction boundary (per RISC-V spec):
`MEI > MSI > MTI > SEI > SSI > STI`. Phase 2 ever only produces MTI
(taken in M) or SSI (taken in S); priority resolution still exists
and is unit-tested.

### Sv32 translation

- **`satp` layout:** `MODE` (1 bit), `ASID` (9 bits — ignored),
  `PPN` (22 bits).
  - `MODE = 0` (Bare): identity; no walk.
  - `MODE = 1` (Sv32): 2-level walk.

- **Walk.** VA = `VPN[1]` (10) ‖ `VPN[0]` (10) ‖ `offset` (12).
  PTE = `PPN` (22) ‖ `RSW` (2) ‖ `D A G U X W R V` (8).

  ```
  l1_pte = mem[(satp.PPN << 12) + VPN[1]*4]
    if not valid → page fault
    if R|W|X set at L1 → superpage leaf → page fault (Phase 2 rejects)
    else descend
  l0_pte = mem[(l1_pte.PPN << 12) + VPN[0]*4]
    must be valid with (R|W|X) set → leaf
  PA = (l0_pte.PPN << 12) | offset
  ```

- **Permission check** (using effective privilege; `mstatus.MPRV` is
  honored for loads/stores from M-mode but instruction fetch always
  uses the current privilege mode):
  - U-mode: `PTE.U` must be 1.
  - S-mode without `sstatus.SUM`: `PTE.U` must be 0.
  - S-mode with `sstatus.SUM = 1`: `PTE.U` may be either, but
    instruction fetch on a page with `PTE.U = 1` always faults.
  - `R`/`W` checked per access type; `sstatus.MXR = 1` allows reads
    on pages with only `X` set.

- **Fault causes.** Instruction page fault = 12, load page fault =
  13, store/AMO page fault = 15. `stval ← faulting VA`.

- **A/D bits.** On access, if `PTE.A = 0` on read or `PTE.D = 0` on
  write, update the PTE in memory (write-back) and continue.
  Alternative approach (raise page fault for OS to update) is
  rejected for Phase 2 — simpler with no extra fault handling.

- **TLB.** Not modeled. Every access re-walks. `sfence.vma`
  validates operand privilege (illegal in U; illegal in S when
  `mstatus.TVM = 1`, which we leave 0) but has no memory side
  effects.

### Page-table ownership

One root per process (Phase 2 has one process → one root):

- **Kernel pages** (`0x80000000 – 0x87FFFFFF`, direct-mapped): per-page
  flags (`.text` R+X, `.rodata` R, `.data`/`.bss`/stack R+W), all
  `U=0, G=1`.
- **MMIO pages** (CLINT, UART, Halt, one 4 KB page each,
  identity-mapped): `S, R+W, U=0, G=1`.
- **User text/rodata/data/bss** (at `0x00010000+`): `U=1`, per-segment
  `R`/`W`/`X`.
- **User stack** (at `0x00030000+`, 2 pages, `sp` top = `0x00032000`):
  `U=1, R+W`.

The root is allocated at boot; second-level tables lazily allocated
as user regions are mapped. Page-table memory comes from the bump
allocator.

## Kernel internals

### Boot sequence (from `PC = e_entry` to user code)

1. **`boot.S` (M-mode):**
   - Zero kernel BSS. Load `sp ← _kstack_top`.
   - `mtvec ← m_trap_vector` (M-mode trap target — only MTI in
     Phase 2).
   - Set `medeleg` and `mideleg` per §Delegation.
   - `mie.MTIE = 1`, `mstatus.MIE = 1`.
   - Program CLINT: `mtimecmp ← mtime + TIMESLICE` (start with
     `TIMESLICE = 1_000_000` CLINT ticks ≈ 100 ms at 10 MHz; tune
     empirically).
   - `mstatus.MPP = S`, `mepc ← kmain`. `mret` → S-mode at `kmain`.
2. **`kmain.zig` (S-mode):**
   - `page_alloc.init(&_end)`.
   - `root = vm.alloc_root()`; `vm.map_kernel_and_mmio(root)`.
   - `vm.map_user(root, userprog_blob)` — allocate user frames,
     memcpy user `.text`/`.rodata`/`.data` from the `@embedFile`'d
     blob, map at VA `0x00010000+` and stack at `0x00030000+`.
   - Initialize `the_process`: `satp`, `kstack_top`,
     `tf.sp = 0x00032000` (top of user stack),
     `tf.sepc = 0x00010000` (user entry), `state = .Running`.
   - `sie.SSIE = 1` (enable supervisor software interrupts — the
     forwarded timer path). `sstatus.SIE` is irrelevant while we're
     in U-mode (lower privilege always allows S interrupts).
   - `stvec ← s_trap_vector` (trampoline).
   - `sscratch ← &the_process.tf`.
   - `csrw satp, the_process.satp; sfence.vma`.
   - Jump to the trampoline's return-to-user path: restore
     `the_process.tf` registers into hardware regs and `sret`.
3. **U-mode** runs the user program: writes the message via
   `sys_write`, yields once via `sys_yield`, exits via `sys_exit`,
   which writes to halt MMIO → emulator terminates with exit code
   0.

### `Process` struct

```zig
pub const State = enum { Runnable, Running, Exited };

pub const TrapFrame = extern struct {
    // Order chosen so trampoline.S can save/restore at fixed offsets.
    ra: u32, sp: u32, gp: u32, tp: u32,
    t0: u32, t1: u32, t2: u32,
    s0: u32, s1: u32,
    a0: u32, a1: u32, a2: u32, a3: u32, a4: u32, a5: u32, a6: u32, a7: u32,
    s2: u32, s3: u32, s4: u32, s5: u32, s6: u32, s7: u32,
    s8: u32, s9: u32, s10: u32, s11: u32,
    t3: u32, t4: u32, t5: u32, t6: u32,
    sepc: u32,
};

pub const Process = struct {
    satp: u32,
    kstack_top: usize,
    tf: TrapFrame,
    state: State,
    ticks_observed: u32,
    exit_code: u32,
};

pub var the_process: Process = undefined;
```

One instance, statically allocated in kernel `.bss`.

### S-mode trap entry/exit (`trampoline.S`)

On trap from U (or async in S), `stvec` lands at the trampoline:

1. `csrrw sp, sscratch, sp` — swap `sp` with `sscratch`. Now
   `sp = &the_process.tf`; `sscratch` holds user's `sp`.
2. Save `ra, gp, tp, t0–t6, s0–s11, a0–a7` at fixed offsets in `*sp`.
3. `csrr tmp, sepc; sw tmp, SEPC_OFF(sp)`.
4. `csrr tmp, sscratch; sw tmp, SP_OFF(sp)`.
5. `la tmp, the_process.tf; csrw sscratch, tmp` (restore sscratch
   for next trap).
6. `lw sp, the_process.kstack_top`.
7. `mv a0, &the_process.tf; call s_trap_dispatch`.

Return path mirrors: reload registers from `*&the_process.tf`,
`csrw sepc, tf.sepc`, swap `sp ↔ sscratch`, `sret`.

### `s_trap_dispatch`

```zig
pub export fn s_trap_dispatch(tf: *TrapFrame) void {
    const scause = csr.read_scause();
    const is_int = (scause >> 31) & 1 == 1;
    const cause  = scause & 0x7fffffff;

    if (is_int and cause == 1) {              // supervisor software (forwarded timer tick)
        csr.clear_mip_ssip();
        the_process.ticks_observed +%= 1;
        _ = sched.schedule();
    } else if (!is_int and cause == 8) {      // ECALL from U
        syscall.dispatch(tf);
    } else if (!is_int and (cause == 12 or cause == 13 or cause == 15)) {
        panic("user page fault at {x} (cause {})",
              .{ csr.read_stval(), cause });
    } else {
        panic("unhandled S-mode trap: scause={x}", .{scause});
    }
    // Return-to-user path follows, running sched.context_switch_to.
}
```

Phase 2 panics on kernel-origin page faults (including `sys_write`
with an unmapped user buffer). The Phase 2 user program's `MSG` lives
in user `.rodata`, which is always mapped, so the simplification is
safe. Phase 3 must add fault-safe `copy_from_user` before accepting
user-allocated pointers.

### Scheduler stub

```zig
// sched.zig
pub fn schedule() *Process {
    return &proc.the_process;    // Phase 2: one process
}

pub fn context_switch_to(p: *Process) void {
    csr.write_satp(p.satp);
    asm volatile ("sfence.vma zero, zero" ::: "memory");
    // Trampoline return loads p.tf and sret's.
}
```

Called from the timer ISR path and from `sys_yield`. The `satp` write
and `sfence.vma` run unconditionally — exercising the switch path in
Phase 2 even though the "new" process equals the old one.

### Syscall ABI

Standard RISC-V syscall convention: args in `a0..a5`, number in `a7`,
return in `a0`.

| Num | Name | Args | Return | Behavior |
|---|---|---|---|---|
| 64 | `write` | `a0=fd`, `a1=buf`, `a2=len` | bytes written or `-EBADF` | Sets `sstatus.SUM=1`, reads `len` bytes from user VA `buf`, writes them to UART byte-by-byte, clears SUM. `fd` must be 1 or 2. |
| 93 | `exit` | `a0=status` | does not return | `state ← .Exited`, print `"ticks observed: N\n"`, write `status & 0xff` to halt MMIO → emulator terminates. |
| 124 | `yield` | (none) | 0 | Calls `sched.schedule()`; return-to-user path runs the switch code. |

Anything else: `a0 ← -ENOSYS (-38)`. `sepc` is advanced by 4 after
dispatch in all paths (success and `-ENOSYS`) so U-mode resumes at
the instruction after `ecall`. `sys_exit` is the exception — it
writes to halt MMIO and never returns, so `sepc` advancement is
moot.

### User program

```zig
// tests/programs/kernel/user/userprog.zig
const MSG = "hello from u-mode\n";

fn ecall3(a7: u32, a0: u32, a1: u32, a2: u32) u32 {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> u32),
        : [n] "{a7}" (a7), [a] "{a0}" (a0),
          [b] "{a1}" (a1), [c] "{a2}" (a2),
        : "memory");
}

export fn _start() noreturn {
    _ = ecall3(64, 1, @intFromPtr(&MSG[0]), MSG.len);  // write
    _ = ecall3(124, 0, 0, 0);                           // yield
    _ = ecall3(93, 0, 0, 0);                            // exit
    while (true) {}
}
```

Built with `-target riscv32-freestanding -mcpu
generic_rv32+m+a+zicsr+zifencei`, linked with `user_linker.ld`
placing `.text` at VA `0x00010000`. `objcopy -O binary` produces
`userprog.bin`, which the kernel embeds via `@embedFile`.

### Kernel build targets (in `build.zig`)

- `kernel-user` — builds `userprog.bin`.
- `kernel-elf` — builds kernel Zig + asm + `@embedFile`'d
  `userprog.bin`, linked per `kernel/linker.ld`, entry `_M_start`.
  Emits `zig-out/bin/kernel.elf`.
- `zig build kernel` — alias for `kernel-elf`.
- `zig build e2e-kernel` — runs `ccc kernel.elf`, asserts stdout
  matches `hello from u-mode\nticks observed: <N>\n` with N > 0,
  exit code 0.
- `zig build qemu-diff-kernel` — wrapper over
  `scripts/qemu-diff-kernel.sh`.

The linker script places kernel at `0x80000000`, orders sections
`.text → .rodata → .data → .bss`, and allocates a 16 KB kernel stack
with `_kstack_top` exported.

## Testing strategy

### 1. Emulator unit tests (`src/*_test.zig`)

- S-CSR aliasing: writes through `sstatus`/`sie`/`sip` affect
  `mstatus`/`mie`/`mip` only in the S-visible fields.
- Sv32 translation: valid 4 KB leaf; superpage leaf → fault; `U=0`
  page from U-mode → fault; `U=1` from S-mode with `SUM=0` → fault;
  with `SUM=1` → ok; execute with `PTE.U=1` from S → always faults;
  X-only page read with `MXR=1` → ok; A/D write-back; misaligned VA
  → fault.
- Delegation: synthetic ECALL-from-U with `medeleg[8]=1` targets S;
  `=0` targets M.
- Async interrupts: CLINT raises `mip.MTIP` when `mtime ≥ mtimecmp`;
  M-mode takes MTI trap when `mie.MTIE & mstatus.MIE`;
  interrupt-priority ordering (MEI > MSI > MTI > SEI > SSI > STI) on
  multiple pending bits.
- SSIP forwarding end-to-end: tiny M+S shim sets `mip.SSIP = 1` in M
  (with `mideleg[SSIP]=1` and `sie.SSIE=1`) and verifies S takes a
  supervisor-software trap (`scause = 0x80000001`).
- `sret` register/CSR side effects mirror `mret`.
- `sfence.vma` illegal in U; legal in S with `TVM=0`.

### 2. `riscv-tests` integration

Add `rv32si-p-*` targets. This requires a new
`tests/riscv-tests-s.ld` and a small S-mode entry/trap shim so the
tests' S-mode environment is set up correctly. Phase 1's `rv32ui`,
`rv32um`, `rv32ua`, `rv32mi` targets continue to pass unchanged.

### 3. Kernel e2e (`zig build e2e-kernel`)

Runs `ccc zig-out/bin/kernel.elf`, captures stdout, asserts match
against regex `hello from u-mode\nticks observed: (\d+)\n` with
integer group > 0, exit code 0.

### 4. QEMU-diff harness

`scripts/qemu-diff-kernel.sh <kernel.elf>`:

1. Run in QEMU: `qemu-system-riscv32 -machine virt -bios none -kernel
   <kernel.elf> -nographic -singlestep -d in_asm,cpu,int` → trace A.
2. Run in our emulator: `ccc --trace <kernel.elf>` → trace B.
3. Diff on `(PC, instruction, privilege, key-regs)`, line by line;
   first divergence is almost always the bug.

Debug aid for the developer; not in CI.

### 5. Regression coverage

Phase 1's `e2e`, `e2e-mul`, `e2e-trap`, `e2e-hello-elf`, and
`riscv-tests` must still pass after every Phase 2 plan lands.

## Project structure

```
ccc/
├── build.zig                                  + kernel + kernel-user + e2e-kernel
├── src/                                       emulator modules (all grow per Architecture)
├── tests/
│   ├── programs/
│   │   ├── hello/                             Phase 1, unchanged
│   │   ├── mul_demo/                          Phase 1, unchanged
│   │   ├── trap_demo/                         Phase 1, unchanged
│   │   ├── hello_elf/                         Phase 1, unchanged
│   │   └── kernel/                            NEW (see Architecture)
│   ├── fixtures/                              unchanged
│   ├── riscv-tests/                           + rv32si targets
│   ├── riscv-tests-p.ld                       unchanged
│   └── riscv-tests-s.ld                       NEW
├── scripts/
│   ├── qemu-diff.sh                           unchanged
│   └── qemu-diff-kernel.sh                    NEW
└── docs/superpowers/specs/                    + this spec
```

## CLI

Unchanged: `ccc [--trace] [--halt-on-trap] [--memory <MB>] <elf>`.

The `--trace` format gains a privilege column `[M]`/`[S]`/`[U]` and a
synthetic marker line `--- interrupt N (<name>) taken in <old>, now
<new> ---` between instructions when an async trap is entered.

## Implementation plan decomposition

Four plans, echoing Phase 1's rhythm:

- **2.A — Emulator: S-mode + Sv32.** S-mode privilege; S-CSRs; `sret`;
  `sfence.vma`; Sv32 translation in `memory.zig`. `rv32si-p-*` passes.
- **2.B — Emulator: delegation + async interrupts.** `medeleg`,
  `mideleg`; delegation-aware trap entry; interrupt priority check at
  instruction boundaries; CLINT MTIP edge generation; end-to-end
  CLINT → M → SSIP → S forwarding validated by a dedicated unit test.
- **2.C — Kernel skeleton.** M-mode boot shim (delegation setup +
  timer ISR + drop to S); kernel S-mode trap dispatcher; single page
  table (kernel + MMIO + user); `sret` to U; user `write` + `exit`
  demo (no `yield` yet, no `Process` struct).
- **2.D — Process scaffolding + scheduler stub + yield + final
  demo.** Introduce `Process` struct; wire timer IRQ → scheduler
  stub; `sys_yield`; tick counter; printed `"ticks observed: N"`
  at exit. Hit Definition of Done.

## Risks and open questions

- **QEMU vs us on Sv32 edge cases.** Superpage rejection, A/D update
  timing, and `MPRV` interactions are the usual sources of divergence.
  Mitigation: QEMU-diff as the first-line debug tool.
- **Trace format for async traps.** We emit a synthetic
  `--- interrupt N taken, M←S ---` marker between instructions so
  trap entry is visible. Format frozen before 2.B lands.
- **Timer rate.** `TIMESLICE = 1_000_000` CLINT ticks (100 ms at
  nominal 10 MHz) is a guess. Too small → kernel drowns in ticks;
  too big → short user program finishes with `ticks_observed = 0`.
  Tune during 2.D.
- **Kernel-originated page faults panic.** Acceptable for Phase 2's
  hardcoded user program (string literal in user `.rodata`, always
  mapped). Phase 3 must add fault-safe `copy_from_user` before
  accepting user-allocated pointers in syscalls.
- **rv32si test environment.** The `p` linker script used for mi/ui
  tests assumes M-mode. rv32si needs an S-mode entry shim — new
  `tests/riscv-tests-s.ld` handles this; spec it out fully during 2.A.
- **ASID handling.** We leave `satp.ASID = 0` and set `PTE.G = 1` on
  kernel pages as cosmetic documentation. Real ASIDs, if ever needed,
  are a future phase's problem.
- **Superpage emitters.** We only construct 4 KB leaves, but `vm.zig`
  should `assert` this when walking — catches a class of bugs early.
- **Zig version churn.** Same risk as Phase 1. Re-pin
  `build.zig.zon` at Phase 2 start.

## Roughly what success looks like at the end of Phase 2

```
$ zig build test                              # all unit tests pass (Phase 1 + 2)
$ zig build riscv-tests                       # rv32ui/um/ua/mi/si p-* all pass
$ zig build e2e-kernel
# passes: stdout matches "hello from u-mode\nticks observed: <N>\n"

$ zig build kernel && zig build run -- zig-out/bin/kernel.elf
hello from u-mode
ticks observed: 42

$ zig build run -- --trace zig-out/bin/kernel.elf | head -15
80000000  [M] auipc t0, 0x0            x5 := 0x80000000
80000004  [M] addi  t0, t0, 0x40       x5 := 0x80000040
...
80001040  [M] mret                     → S-mode, PC = kmain
80010200  [S] csrw  satp, t0
80010204  [S] sfence.vma zero, zero
80010208  [S] sret                     → U-mode, PC = 0x00010000
00010000  [U] auipc gp, 0x20           x3 := 0x00030000
...
--- interrupt 1 (supervisor software / forwarded timer) taken in U, now S ---
80010300  [S] auipc t0, 0x0            x5 := 0x80010300
...
```

…and you understand every byte in `kernel.elf` because you wrote it.
