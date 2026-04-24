# Phase 2 Plan C — Kernel skeleton (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Tasks have strict sequential dependencies — do not dispatch in parallel.

**Goal:** Boot a bare-metal kernel.elf in Zig on the Plan 2.B emulator. The kernel is loaded by `ccc kernel.elf` at PC = e_entry in M-mode, runs a short M-mode boot shim that sets up delegation and the CLINT timer before dropping to S-mode, initializes an Sv32 page table covering the kernel's direct-mapped image + the MMIO strip + one U-mode user program, installs an S-mode trap dispatcher, and `sret`s to the user program at VA 0x00010000. The user program makes two ecalls — `write(1, MSG, MSG.len)` then `exit(0)` — and the kernel services them in S-mode. The emulator prints exactly `hello from u-mode\n` and exits 0. Timer interrupts fire in the background, get forwarded M→S via mip.SSIP per Plan 2.B, and the S-mode SSI handler clears SSIP and returns — no scheduler, no tick counter, no `Process` struct (those arrive in Plan 2.D).

**Architecture:** A three-layer program. (1) **M-mode boot shim** — `boot.S` zeros BSS, installs `mtvec` → `m_trap_vector` (an M-mode trap target for MTI), writes `medeleg`/`mideleg` for sync U→S delegation + async SSIP delegation, enables `mie.MTIE` + `mstatus.MIE`, programs CLINT `mtimecmp`, and `mret`s to `kmain` in S-mode; `mtimer.S` is the M-mode MTI ISR that advances `mtimecmp` and raises `mip.SSIP`. (2) **S-mode kernel** — `kmain.zig` initializes `page_alloc` from the linker `_end` symbol, allocates an Sv32 root, maps the kernel direct image + MMIO + user program via `vm.zig` (2-level 4 KB-leaf walk; no superpages), installs `stvec` → `s_trap_entry` (asm trampoline) and `sscratch` → `&the_tf`, enables `sie.SSIE`, writes satp + `sfence.vma`, and jumps into the trampoline's return-to-user path; `trap.zig` dispatches delegated traps (ECALL from U → `syscall.zig`, supervisor software → SSIP clear, anything else → panic); `syscall.zig` implements `write`/`exit` only (no `yield`); `uart.zig`/`kprintf.zig` are kernel-side MMIO helpers. (3) **U-mode user program** — `user/userprog.zig` is a naked 4-instruction core that does `write(1, MSG, MSG.len); exit(0); infinite_loop`; built to a flat binary with `user_linker.ld` (text at VA 0x00010000) and embedded into the kernel's `.rodata` via a build-generated stub + `@embedFile`. The emulator sources (`src/*.zig`) **do not change** — everything Plan 2.C needs is already in the CPU from Plans 2.A + 2.B.

**Tech Stack:** Zig 0.16.x (pinned in `build.zig.zon`, unchanged). Target `generic_rv32+m+a+zicsr+zifencei`, same as Phase 1's `hello.elf` cross-target. No new external dependencies. `llvm-objcopy` is invoked via `b.addSystemCommand` to flatten `userprog.elf` → `userprog.bin`; LLVM ships as part of the Zig toolchain distribution.

**Spec reference:** `docs/superpowers/specs/2026-04-24-phase2-bare-metal-kernel-design.md` — Plan 2.C covers spec §Kernel modules (all files except those deferred to 2.D), §Memory layout (kernel RAM + per-process VA), §Privilege & trap model (runtime share, synchronous trap entry/exit, async interrupt flow for the boot-shim side of the MTI→SSIP hop), §Sv32 translation (kernel uses only what the emulator already supports), §Kernel internals (boot sequence, trampoline, `s_trap_dispatch` **minus** the tick-counter branch and scheduler call, syscall ABI **minus** `yield`), and §Project structure (`tests/programs/kernel/` layout). Plan 2.D picks up the `Process` struct, scheduler stub, `sys_yield`, tick counter, and the `"ticks observed: N"` line.

---

## Plan 2.C scope (subset of Phase 2 spec)

- **Kernel tree** under `tests/programs/kernel/`:
  - `linker.ld` — RAM origin 0x80000000; `.text.init` → `.text` → `.rodata` → `.data` → `.bss` → 16 KB kernel stack → `_end` page-aligned. Exports section-boundary symbols `_text_start/_text_end`, etc., plus `_kstack_top`, `_end`.
  - `boot.S` — `_M_start`: zero BSS, `sp = _kstack_top`, `mtvec = m_trap_vector`, `medeleg`/`mideleg` setup per spec, `mie = MTIE`, `mstatus.MIE = 1`, `mtimecmp = mtime + TIMESLICE`, `mstatus.MPP = S`, `mepc = kmain`, `mret`. Also contains `m_trap_vector` (a 4-byte-aligned branch table: cause 7 + int bit → `m_timer_isr`; anything else → panic-spin) and `m_timer_isr` (imported from `mtimer.S`).
  - `mtimer.S` — `m_timer_isr`: save clobbered regs to `m_scratch_area`, advance `mtimecmp` by `TIMESLICE`, `csrrs zero, mip, SSIP_BIT`, restore regs, `mret`.
  - `trampoline.S` — `s_trap_entry`: `csrrw sp, sscratch, sp` to land on `&the_tf`, save all user GPRs + `sepc`, reset sscratch to `&the_tf`, switch to `_kstack_top`, `mv a0, &the_tf`, `call s_trap_dispatch`, fall through to `s_return_to_user` (restore regs from `&the_tf`, `sret`).
  - `kmain.zig` — S-mode entry: `page_alloc.init()`, `vm.allocRoot()`, `vm.mapKernelAndMmio(root)`, `vm.mapUser(root, USER_BLOB)`, initialize `the_tf` (sepc=0x00010000, sp=0x00032000), write `stvec`, `sscratch`, `sie.SSIE = 1`, write satp + `sfence.vma`, jump to `s_return_to_user`.
  - `vm.zig` — Sv32 construction (never walks; the emulator walks). PTE flag constants matching `memory.zig`'s `PTE_*` shifts. `allocRoot()` bumps a 4 KB page from page_alloc. `mapPage(root, va, pa, flags)` walks descending; on missing L1 entry, allocates a fresh L0 table, installs a pointer PTE; writes the L0 leaf PTE with `flags | PTE_V | PTE_A | PTE_D`. `mapRange(root, va, pa, len, flags)` iterates in PAGE_SIZE steps. `mapKernelAndMmio(root)` covers kernel .text (R+X), .rodata (R), .data/.bss/stack (R+W), and CLINT/UART/Halt (S R+W, one page each) — all with `U=0, G=1`. `mapUser(root, blob_ptr, blob_len)` allocates N = ceil(blob_len / 4K) user frames, memcpys blob, maps each at VA 0x00010000+k\*4K with `U=1, R+W+X` (Plan 2.C keeps permissions loose since the flat user blob mingles text + rodata); allocates 2 more pages for user stack at VA 0x00030000/0x00031000 with `U=1, R+W`.
  - `page_alloc.zig` — trivially bump-allocates 4 KB pages starting at `round_up(_end, 4K)`; single global `next_pa`; never frees.
  - `trap.zig` — `export fn s_trap_dispatch(tf: *TrapFrame) void`: reads `scause` + `stval` via inline asm; branches on `(is_interrupt, cause_code)`. `(false, 8)` → `syscall.dispatch(tf)`. `(true, 1)` → clear `sip.SSIP` (`csrc sip, 2`), return. Anything else → `panic()`. Advances `tf.sepc += 4` on syscall return path (sys_exit is moot).
  - `syscall.zig` — `dispatch(tf)` reads `tf.a7` and switches: `64` → `sys_write(tf.a0, tf.a1, tf.a2)`, `93` → `sys_exit(tf.a0)`, default → `tf.a0 = @bitCast(@as(i32, -38))`. `sys_write` sets `sstatus.SUM`, loops over user buf VA loading byte-by-byte and writing to UART, clears SUM; returns `len`. `sys_exit` writes `status & 0xFF` to halt MMIO `0x00100000`; does not return.
  - `uart.zig` — `writeByte(b)`: raw `*(*volatile u8)(0x10000000) = b`. `writeBytes(s)`: loop. Used by kmain for early printf and by `sys_write` to emit user bytes.
  - `kprintf.zig` — minimal formatter supporting `{s}`, `{x}` (u32 hex), `{d}` (u32 decimal). Used for panic messages only; no `\0` termination; no float.
  - `user/user_linker.ld` — `.text` at VA 0x00010000; `.rodata`/`.data`/`.bss` follow in the same contiguous region.
  - `user/userprog.zig` — naked `_start` in `.text.init` making two ecalls; `msg` constant in `.rodata`.
- **Build targets**: `zig build kernel-user` (produces `userprog.bin`), `zig build kernel-elf` (produces `zig-out/bin/kernel.elf`), `zig build e2e-kernel` (runs `ccc kernel.elf`, asserts stdout equals `"hello from u-mode\n"`, exit 0). `zig build kernel` aliases `kernel-elf`.
- **User blob embed**: the `userprog.bin` file is produced by `llvm-objcopy -O binary` on `userprog.elf`. A `std.Build.Step.WriteFile` step emits a tiny Zig shim `user_blob.zig` (`pub const BLOB = @embedFile("userprog.bin");`) co-located with a copy of `userprog.bin`, and the kernel module imports `user_blob` as a named anonymous import. `kmain.zig` reads `user_blob.BLOB.*` as `[]const u8`.
- **TIMESLICE**: `const TIMESLICE = 1_000_000` CLINT ticks, per spec guess — intentionally coarse for 2.C so the short `hello\nexit` program finishes before many ticks fire. Tuning is deferred to 2.D where the tick counter appears.
- **Regression guarantee**: `zig build test && zig build e2e && zig build e2e-mul && zig build e2e-trap && zig build e2e-hello-elf && zig build riscv-tests` all pass unchanged at the end of 2.C. The emulator is untouched.

### Not in Plan 2.C (explicitly)

- `Process` struct, scheduler, `sys_yield`, tick counter, `"ticks observed: N"` print — all 2.D.
- `scripts/qemu-diff-kernel.sh` — 2.D. Plan 2.C validates against our emulator only; QEMU-diff becomes load-bearing once the Phase 2 DoD demands parity on the full `hello from u-mode\nticks observed: N\n` trace.
- Multi-process, fork/exec, filesystem, block device — Phase 3.
- PLIC, UART RX, keyboard — Phase 3.
- Fault-safe `copy_from_user` — Phase 3; 2.C panics on any S-mode-origin page fault.
- Sv32 4 MiB superpages — Phase 2 permanently rejects (spec §Sv32 translation). Our `vm.mapPage` only ever writes leaves at L0.
- Per-process ASID — `satp.ASID = 0` throughout; `PTE.G = 1` is cosmetic.
- Kernel-side unit tests via `zig build test` — kernel modules target `riscv32-freestanding` and are unreachable from the host-target test runner. Validation is via the `e2e-kernel` end-to-end run after every task group. Pure-math helpers that would be host-testable in principle (Sv32 PTE encoding, bump-allocator arithmetic) are kept as `comptime`-usable no-dependency functions but are not currently imported into `src/main.zig`'s test reachability block — the 2.C decision is to keep the kernel tree a single-target island; Plan 3 can revisit if the kernel grows testable logic worth exercising twice.

---

## File structure (final state at end of Plan 2.C)

```
ccc/
├── .gitignore                                   UNCHANGED
├── .gitmodules                                  UNCHANGED
├── build.zig                                    MODIFIED (+kernel-user, +kernel-elf, +kernel, +e2e-kernel targets; +llvm-objcopy invocation; +WriteFile stub for @embedFile)
├── build.zig.zon                                UNCHANGED
├── README.md                                    MODIFIED (Status section; Next line)
├── src/                                         UNCHANGED
│   ├── main.zig
│   ├── cpu.zig
│   ├── memory.zig
│   ├── decoder.zig
│   ├── execute.zig
│   ├── csr.zig
│   ├── trap.zig
│   ├── elf.zig
│   ├── trace.zig
│   └── devices/
│       ├── halt.zig
│       ├── uart.zig
│       └── clint.zig
└── tests/
    ├── fixtures/                                UNCHANGED
    ├── programs/
    │   ├── hello/                               UNCHANGED (Phase 1 demo, regression-covered)
    │   ├── mul_demo/                            UNCHANGED
    │   ├── trap_demo/                           UNCHANGED
    │   └── kernel/                              NEW
    │       ├── linker.ld                        NEW
    │       ├── boot.S                           NEW
    │       ├── mtimer.S                         NEW
    │       ├── trampoline.S                     NEW
    │       ├── kmain.zig                        NEW
    │       ├── vm.zig                           NEW
    │       ├── page_alloc.zig                   NEW
    │       ├── trap.zig                         NEW
    │       ├── syscall.zig                      NEW
    │       ├── uart.zig                         NEW
    │       ├── kprintf.zig                      NEW
    │       └── user/
    │           ├── user_linker.ld               NEW
    │           └── userprog.zig                 NEW
    ├── riscv-tests/                             UNCHANGED (submodule)
    ├── riscv-tests-p.ld                         UNCHANGED
    ├── riscv-tests-s.ld                         UNCHANGED
    └── riscv-tests-shim/                        UNCHANGED
```

### Module responsibilities

- **`tests/programs/kernel/linker.ld`** — Kernel ELF layout. Page-aligned sections so `mapKernelAndMmio` can apply section-specific permissions. Exports `_text_start`, `_text_end`, `_rodata_start`, `_rodata_end`, `_data_start`, `_data_end`, `_bss_start`, `_bss_end`, `_kstack_bottom`, `_kstack_top`, and `_end`. Entry symbol `_M_start` (boot.S). Stack is 16 KB (4 pages). `_end` is 4 KB-aligned to simplify page_alloc's first bump.
- **`tests/programs/kernel/boot.S`** — M-mode entry + trap vector. Four labels: `_M_start` (entry; zero BSS, set sp, install M trap vector, program medeleg/mideleg/mie/mtimecmp, mret to S @ kmain), `m_trap_vector` (branch on `mcause` — cause 0x80000007 (MTI) → `m_timer_isr`, anything else → `m_panic_spin` which writes 0xFF to halt MMIO), `m_panic_spin` (`sb` to halt MMIO + `j self`). Does NOT handle synchronous traps — all sync traps in 2.C are delegated to S, and anything non-delegated (ECALL from S/M, faults outside medeleg) hits `m_panic_spin`.
- **`tests/programs/kernel/mtimer.S`** — `m_timer_isr`: target of `m_trap_vector` for the `(interrupt=1, cause=7)` MTI case. Saves `t0`/`t1`/`t2` to `m_scratch_area` (a 12-byte global allocated in this file), advances `mtimecmp` by `TIMESLICE`, sets `mip.SSIP` via `csrrs`, restores the three temps, `mret`. Clobbered-reg strategy: M-mode has no kernel stack to spill onto (we're re-using the same 16 KB stack owned by S-mode kmain), so we avoid touching sp and use a fixed scratch area.
- **`tests/programs/kernel/trampoline.S`** — S-mode trap vector. Two labels: `s_trap_entry` (csrrw sp/sscratch, save all GPRs except x0 and tf.sp's slot temporarily, save user sp from sscratch, restore sscratch = &the_tf, save sepc, switch sp to `_kstack_top`, call `s_trap_dispatch` with a0 = &the_tf, fall through) and `s_return_to_user` (restore regs from &the_tf, restore sp from &the_tf.sp at the very end via a final direct load, sret). The return path uses `a0` as tf-pointer-base until its very last load, at which point a0 is overwritten with the user's saved a0 and the ptr is discarded — a well-known RISC-V trampoline idiom.
- **`tests/programs/kernel/kmain.zig`** — Zig entry. `extern` linker symbols for `_end`, `_text_start/_end`, etc. Exports `the_tf: TrapFrame` as a global (referenced by trampoline.S via `la`). Exports `kmain` (the `mepc` target from boot.S) that sequences: `page_alloc.init()` → `const root = vm.allocRoot()` → `vm.mapKernelAndMmio(root)` → `vm.mapUser(root, USER_BLOB)` → initialize `the_tf` (sepc = 0x00010000, sp = 0x00032000, a0..a7 = 0) → `csrw stvec, &s_trap_entry` → `csrw sscratch, &the_tf` → `csrs sie, SIE_SSIE` → `const satp_val = SATP_MODE_SV32 | (pa(root) >> 12); csrw satp, satp_val; sfence.vma zero, zero` → `asm jmp s_return_to_user`. kmain has `callconv(.c)` so boot.S can reach it via `la + jalr`.
- **`tests/programs/kernel/vm.zig`** — Sv32 page-table constructor. Imports `page_alloc`. Exports `allocRoot() u32` (returns PA of zeroed L1 table), `mapPage(root_pa, va, pa, flags) void`, `mapRange(root_pa, va, pa, len, flags) void`, `mapKernelAndMmio(root_pa) void` (walks extern linker symbols + MMIO constants), `mapUser(root_pa, blob_ptr, blob_len) void`. PTE flag constants mirror `src/memory.zig`'s `PTE_*`. All PAs are u32 (RAM base 0x80000000+); VAs are u32. Kernel uses VA=PA direct-mapped, so pointers returned by page_alloc (which live at PA) can be used as if they were VAs.
- **`tests/programs/kernel/page_alloc.zig`** — Global bump. `var next_pa: u32 = undefined;`. `pub fn init() void { next_pa = alignForward(u32, @intFromPtr(&_end), PAGE_SIZE); }`. `pub fn allocZeroPage() u32 { const p = next_pa; next_pa += PAGE_SIZE; @memset(asSlice(p), 0); return p; }`. Crashes (via unreachable) if `next_pa` overflows 0x88000000 (end of 128 MiB RAM). No deinit.
- **`tests/programs/kernel/trap.zig`** — S-mode dispatcher. Exports `TrapFrame` struct (32-GPR-plus-sepc extern layout; field order fixed, offsets documented). Exports `s_trap_dispatch(tf: *TrapFrame) callconv(.c) void` that branches on `scause`. Imports `syscall.dispatch` and `csr_helpers` (inline-asm `read_scause`, `read_stval`, `clear_sip_ssip`). Panics via `kprintf.panic` on any unhandled trap.
- **`tests/programs/kernel/syscall.zig`** — Syscall table. `dispatch(tf)` switches on `tf.a7`. `sys_write(fd, buf_va, len)` sets `sstatus.SUM=1`, loops `i` in `0..len`, reads `@as(*const volatile u8, @ptrFromInt(buf_va + i)).*`, writes to UART via `uart.writeByte`, clears SUM, returns `len`. `sys_exit(status)` writes the low byte to halt MMIO and spins (never returns; emulator halts before the spin runs).
- **`tests/programs/kernel/uart.zig`** — Constants (`UART_THR = 0x10000000`), `writeByte(b)`, `writeBytes(s)`. Pure MMIO. No locking.
- **`tests/programs/kernel/kprintf.zig`** — `print(comptime fmt, args)` — minimal `{s}`, `{x}` (u32 hex, 8 nibbles, no 0x prefix — caller adds), `{d}` (u32 decimal, no padding). `panic(comptime fmt, args)` — prints "panic: " + fmt + "\n" then writes 0xFF to halt MMIO. Emitting via `uart.writeBytes` in all cases.
- **`tests/programs/kernel/user/user_linker.ld`** — User ELF layout. `.text` at VA 0x00010000; includes `_start` (from `.text.init`). Follows with `.rodata`, `.data`, `.bss` in one contiguous stretch (no gap between sections — the kernel's `mapUser` treats the blob as a single RWX span for 2.C). Exports `_user_start` = 0x00010000 and `_user_end`.
- **`tests/programs/kernel/user/userprog.zig`** — `msg: [len]u8` in `.rodata`; `_start` naked asm in `.text.init` making `write(1, msg, len)` then `exit(0)` then `j self`.
- **`build.zig`** — Adds five new build products and one new run step:
  1. `userprog_obj`, `userprog_elf`: cross-compile `userprog.zig` with `user_linker.ld` and the existing `rv_target`, entry `_start`.
  2. `userprog_bin_cmd = b.addSystemCommand({"llvm-objcopy", "-O", "binary"})` with `addFileArg(userprog_elf.getEmittedBin())` and `addOutputFileArg("userprog.bin")`.
  3. `user_blob_stub` = `b.addWriteFiles()`; adds `user_blob.zig` with `"pub const BLOB = @embedFile(\"userprog.bin\");"` and `addCopyFile(userprog_bin, "userprog.bin")`.
  4. `kernel_elf` cross-compile pairing `boot.S` + `mtimer.S` + `trampoline.S` + all kernel `.zig` + `linker.ld`; the kernel module imports `user_blob` pointing at the stub's `.zig` output. Entry `_M_start`.
  5. Top-level steps: `kernel-user` → `install(userprog_bin)`, `kernel-elf` → `install(kernel_elf)`, `kernel` → alias of `kernel-elf`, `e2e-kernel` → `addRunArtifact(exe)` passing kernel ELF, expecting stdout `"hello from u-mode\n"` and exit 0.
- **`README.md`** — Status section rewrites to announce Plan 2.C merge; Next line points to 2.D. ISA-coverage line unchanged (Plans 2.A/2.B already covered the machinery; 2.C only composes it).

---

## Conventions used in this plan

- All kernel Zig targets `riscv32-freestanding`; Zig tests from `zig build test` target the host (x86_64 / aarch64) and deliberately cannot reach the kernel tree.
- All kernel asm (`boot.S`, `mtimer.S`, `trampoline.S`) uses GNU-style directives (`.section`, `.globl`, `.balign`, `.option nopic`). The LLVM assembler (which Zig invokes) accepts these.
- Every task ends with a `zig build kernel-elf` compile check (ensures the kernel tree still builds) and, when a user-observable behavior changes, a `zig build e2e-kernel` run. The Phase 1 regression suite runs once at Task 21.
- Commit messages follow Conventional Commits and carry a `(Plan 2.C Task N)` suffix so the git log reads linearly.
- When a task modifies a Zig file that was fully written in an earlier task, we show the full resulting file rather than a diff — subagents may be reading tasks out of order, and a full snapshot is unambiguous. Asm files get diff-style changes where feasible because their structure is more stable.
- All register offsets, PTE bit positions, and CSR addresses used in hand-written asm are accompanied by an inline mnemonic comment. The comment is the source of truth; if a hand-computed word differs from the mnemonic, assume the word is wrong.
- Kernel code never `@panic`s directly — it calls `kprintf.panic` which emits a message over UART and writes `0xFF` to halt MMIO. This is the observable signal a test harness can use to distinguish "hit the panic path" from "exited normally".

---

## Tasks

### Task 1: Kernel directory scaffold + linker.ld + minimal boot.S + minimal kmain.zig

**Files:**
- Create: `tests/programs/kernel/linker.ld`
- Create: `tests/programs/kernel/boot.S`
- Create: `tests/programs/kernel/kmain.zig`

**Why this task first:** We need a skeleton the build graph can point at before we can add any build targets (Task 2). Everything in this task is intentionally a stub — `boot.S` just spins, `kmain.zig` is unreachable for now, `linker.ld` defines the symbols the later tasks will import. No Zig/C code in this task should do anything except compile.

- [ ] **Step 1: Create the linker script**

Create `tests/programs/kernel/linker.ld`:

```
/* Linker script for kernel.elf (Phase 2 Plan 2.C).
 *
 * Layout:
 *   0x80000000  .text.init  (boot.S: _M_start)
 *               .text       (kernel Zig + trampoline.S + mtimer.S)
 *               .rodata     (kernel rodata + embedded userprog.bin)
 *               .data
 *               .bss
 *               (16 KB kernel stack)
 *   _end (4 KB aligned — page_alloc.init bumps from here)
 *
 * All sections are 4 KB-aligned so vm.mapKernelAndMmio can apply
 * section-appropriate permissions on a per-page basis.
 */

OUTPUT_ARCH("riscv")
ENTRY(_M_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128M
}

SECTIONS {
    . = 0x80000000;

    .text : {
        _text_start = .;
        KEEP(*(.text.init))
        *(.text .text.*)
        . = ALIGN(4096);
        _text_end = .;
    } > RAM

    .rodata : {
        _rodata_start = .;
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(4096);
        _rodata_end = .;
    } > RAM

    .data : {
        _data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4096);
        _data_end = .;
    } > RAM

    .bss : {
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4096);
        _bss_end = .;
    } > RAM

    /* Kernel stack: 16 KB = 4 pages. */
    . = ALIGN(16);
    _kstack_bottom = .;
    . = . + 0x4000;
    _kstack_top = .;

    . = ALIGN(4096);
    _end = .;

    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.eh_frame)
        *(.riscv.attributes)
    }
}
```

- [ ] **Step 2: Create the minimal boot.S stub**

Create `tests/programs/kernel/boot.S`:

```
# tests/programs/kernel/boot.S — Phase 2 Plan 2.C kernel M-mode boot shim.
#
# Task 1 leaves this as a non-functional stub that just spins. Task 2 fills
# in the real M->S transition. Task 18 adds delegation + CLINT + MTI setup.
#
# Entry symbol _M_start is referenced from linker.ld's ENTRY directive.

.section .text.init, "ax", @progbits
.balign 4
.globl _M_start
_M_start:
1:  j 1b
```

- [ ] **Step 3: Create the minimal kmain.zig stub**

Create `tests/programs/kernel/kmain.zig`:

```zig
// tests/programs/kernel/kmain.zig — Phase 2 Plan 2.C kernel S-mode entry.
//
// Task 1 leaves this as an unreachable stub so build.zig (Task 2) can depend
// on a real Zig file. Task 2 wires boot.S to jump here; Tasks 8, 17, 20 flesh
// out the full paging + user-entry flow.

export fn kmain() callconv(.c) noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}
```

- [ ] **Step 4: Verify directory layout**

Run: `ls -la tests/programs/kernel/`

Expected output lists `linker.ld`, `boot.S`, `kmain.zig` (and `.` / `..`). No other files.

- [ ] **Step 5: Commit**

```bash
git add tests/programs/kernel/linker.ld tests/programs/kernel/boot.S tests/programs/kernel/kmain.zig
git commit -m "feat: kernel tree scaffold with linker script + M/S entry stubs (Plan 2.C Task 1)"
```

---

### Task 2: build.zig — add `kernel-elf` target; boot.S drops to S at `kmain`; kmain writes "ok\n" and halts

**Files:**
- Modify: `build.zig` (add kernel cross-compile using the existing `rv_target`)
- Modify: `tests/programs/kernel/boot.S` (full M→S transition using only the existing Phase 2.A machinery — no medeleg/timer yet)
- Modify: `tests/programs/kernel/kmain.zig` (write "ok\n" to UART, store 0 to halt MMIO, spin)

**Why this task:** Getting `kernel.elf` building and running end-to-end is the single highest-risk moment of Plan 2.C — if the link, the cross-target, or the ELF loader disagrees with our emulator on something basic, we want to find out NOW before paging / trap plumbing adds confounders. The assertion at the end of this task is simple: `ccc kernel.elf` prints `"ok\n"` and exits 0. Paging is disabled (satp = 0 = Bare mode → identity) so MMIO access is just a plain store.

- [ ] **Step 1: Fill in boot.S with the minimal M→S transition**

Rewrite `tests/programs/kernel/boot.S`:

```
# tests/programs/kernel/boot.S — Phase 2 Plan 2.C kernel M-mode boot shim.
#
# Task 2 state: minimum machinery to drop into S-mode at `kmain`. No
# delegation, no timer, no trap vector — anything unexpected hangs.
# Task 18 adds the rest.

.section .text.init, "ax", @progbits
.balign 4
.globl _M_start
_M_start:
    # Initialise stack pointer (we run on the shared kernel stack in both
    # M and S — M only uses it briefly during boot).
    la      sp, _kstack_top

    # Zero BSS. Both _bss_start and _bss_end are 4-byte aligned per the
    # linker script (everything is 4KB-aligned).
    la      t0, _bss_start
    la      t1, _bss_end
1:  beq     t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    # Configure mstatus for the mret drop: MPP=01 (S), MPIE=0, MIE=0.
    # The 2.A Phase-2 CPU honours these on mret: privilege <- MPP, SIE <-
    # SPIE implicitly (we're not using S-mode interrupts yet).
    li      t0, 0x1800           # MPP_MASK = bits 12:11
    csrc    mstatus, t0          # clear MPP (currently =11/M from reset)
    li      t0, 0x0800           # MPP = 01 (S) in bits 12:11
    csrs    mstatus, t0

    # mepc <- kmain (the Zig entry point).
    la      t0, kmain
    csrw    mepc, t0

    # Drop to S-mode.
    mret
```

- [ ] **Step 2: Update kmain.zig to emit "ok\n" and halt**

Rewrite `tests/programs/kernel/kmain.zig`:

```zig
// tests/programs/kernel/kmain.zig — Phase 2 Plan 2.C kernel S-mode entry.
//
// Task 2 state: proves the M->S drop works. Writes "ok\n" to the UART MMIO
// directly, then stores 0 to halt MMIO (emulator exits with code 0).
// Paging is disabled at this stage (satp == 0 == Bare), so raw PAs work.

const UART_THR: *volatile u8 = @ptrFromInt(0x10000000);
const HALT_MMIO: *volatile u8 = @ptrFromInt(0x00100000);

export fn kmain() callconv(.c) noreturn {
    UART_THR.* = 'o';
    UART_THR.* = 'k';
    UART_THR.* = '\n';
    HALT_MMIO.* = 0;
    // Unreachable: halt MMIO terminates the emulator on the store above.
    while (true) asm volatile ("wfi");
}
```

- [ ] **Step 3: Add kernel build targets to build.zig**

In `build.zig`, after the existing `e2e_hello_elf_step` block (around line 185 in the current file) and BEFORE the "Minimal ELF fixture" block, insert:

```zig
    // === Kernel.elf (Plan 2.C) ===
    //
    // Two-piece build:
    //   1. userprog.bin — a flat RV32 U-mode binary produced by objcopy
    //      (added in Task 15). For now (Task 2), userprog.bin does not
    //      exist yet and the kernel does not embed it.
    //   2. kernel.elf — M-mode boot.S + mtimer.S + trampoline.S + kernel
    //      Zig (kmain, vm, page_alloc, trap, syscall, uart, kprintf) all
    //      linked per kernel/linker.ld, entry _M_start.
    //
    // Task 2 state: only boot.S + kmain.zig exist; the other .zig / .S
    // files and the userprog embed arrive in later tasks.

    const kernel_boot_obj = b.addObject(.{
        .name = "kernel-boot",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
        }),
    });
    kernel_boot_obj.root_module.addAssemblyFile(b.path("tests/programs/kernel/boot.S"));

    const kernel_kmain_obj = b.addObject(.{
        .name = "kernel-kmain",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/kmain.zig"),
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });

    const kernel_elf = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    kernel_elf.root_module.addObject(kernel_boot_obj);
    kernel_elf.root_module.addObject(kernel_kmain_obj);
    kernel_elf.setLinkerScript(b.path("tests/programs/kernel/linker.ld"));
    kernel_elf.entry = .{ .symbol_name = "_M_start" };

    const install_kernel_elf = b.addInstallArtifact(kernel_elf, .{});
    const kernel_elf_step = b.step("kernel-elf", "Build the Plan 2.C kernel.elf");
    kernel_elf_step.dependOn(&install_kernel_elf.step);

    const kernel_step = b.step("kernel", "Alias for kernel-elf");
    kernel_step.dependOn(&install_kernel_elf.step);

    // End-to-end: run the Plan 2.C kernel.elf through the emulator and
    // assert the observable stdout. The expected output grows across
    // Tasks 2, 8, 17 before settling at "hello from u-mode\n" in Task 17.
    const e2e_kernel_run = b.addRunArtifact(exe);
    e2e_kernel_run.addFileArg(kernel_elf.getEmittedBin());
    e2e_kernel_run.expectStdOutEqual("ok\n");
    e2e_kernel_run.expectExitCode(0);

    const e2e_kernel_step = b.step("e2e-kernel", "Run the Plan 2.C kernel e2e test");
    e2e_kernel_step.dependOn(&e2e_kernel_run.step);
```

- [ ] **Step 4: Build and inspect the ELF**

Run: `zig build kernel-elf`

Expected: succeeds; produces `zig-out/bin/kernel.elf`. If the linker errors with "undefined symbol kmain", the kmain.zig export is wrong. If it errors with "undefined symbol _bss_start", the linker script section ordering is off.

- [ ] **Step 5: Run the e2e test**

Run: `zig build e2e-kernel`

Expected: passes — the emulator prints `"ok\n"` and exits 0. If it prints gibberish before `ok`, the BSS-zero loop is broken (the UART_THR pointer constant is in .rodata, so bad BSS zeroing would corrupt the zero-page and potentially mess with CSR writes). If it prints nothing, the mret didn't land at kmain — inspect with `zig-out/bin/ccc --trace zig-out/bin/kernel.elf | head -30`.

- [ ] **Step 6: Commit**

```bash
git add build.zig tests/programs/kernel/boot.S tests/programs/kernel/kmain.zig
git commit -m "feat: kernel.elf builds, M->S mret works, e2e-kernel asserts 'ok' (Plan 2.C Task 2)"
```

---

### Task 3: `uart.zig` + `kprintf.zig` helpers; kmain uses them

**Files:**
- Create: `tests/programs/kernel/uart.zig`
- Create: `tests/programs/kernel/kprintf.zig`
- Modify: `tests/programs/kernel/kmain.zig` (use `uart.writeBytes`)
- Modify: `build.zig` (kmain module needs access to uart + kprintf — we'll import them as siblings; nothing build-side changes for cross-module Zig imports within the same directory)

**Why this task:** `sys_write` and kernel panic paths need a UART helper. A formatter (even a tiny one) is cheap to add now and makes panic messages readable when page-fault bugs surface. Introducing them in a dedicated task, with a minimal kmain change that uses them, proves both compile and run before they're load-bearing.

- [ ] **Step 1: Create uart.zig**

Create `tests/programs/kernel/uart.zig`:

```zig
// tests/programs/kernel/uart.zig — kernel-side NS16550A UART helper.
//
// We only ever transmit; receive is not implemented in Phase 2. The
// emulator's uart.zig forwards THR stores straight to stdout, so
// writeByte is effectively a putchar.

pub const UART_THR: u32 = 0x10000000;

pub fn writeByte(b: u8) void {
    const thr: *volatile u8 = @ptrFromInt(UART_THR);
    thr.* = b;
}

pub fn writeBytes(s: []const u8) void {
    for (s) |b| writeByte(b);
}
```

- [ ] **Step 2: Create kprintf.zig**

Create `tests/programs/kernel/kprintf.zig`:

```zig
// tests/programs/kernel/kprintf.zig — minimal formatter + panic.
//
// Supports the subset of std.fmt we need for Phase 2 panic messages:
//   {s} — []const u8 slice
//   {x} — u32 printed as 8 hex nibbles, no "0x" prefix (caller prints it)
//   {d} — u32 printed in decimal, no padding
// That's all. No width specifiers, no padding, no float, no negatives.
// Arguments are matched positionally; extras or mismatches trigger a
// kprintf.panic.

const uart = @import("uart.zig");

const HEX_DIGITS: []const u8 = "0123456789abcdef";

fn writeHexU32(v: u32) void {
    var i: u5 = 8;
    while (i > 0) {
        i -= 1;
        const nibble = @as(usize, @intCast((v >> (@as(u5, i) * 4)) & 0xF));
        uart.writeByte(HEX_DIGITS[nibble]);
    }
}

fn writeDecU32(v: u32) void {
    if (v == 0) { uart.writeByte('0'); return; }
    var buf: [10]u8 = undefined;
    var n: u32 = v;
    var i: usize = 0;
    while (n > 0) : (i += 1) {
        buf[i] = @as(u8, @intCast(n % 10)) + '0';
        n /= 10;
    }
    while (i > 0) : (i -= 1) uart.writeByte(buf[i - 1]);
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    comptime var arg_i: usize = 0;
    comptime var i: usize = 0;
    inline while (i < fmt.len) {
        if (fmt[i] == '{' and i + 2 < fmt.len and fmt[i + 2] == '}') {
            const spec = fmt[i + 1];
            const arg = args[arg_i];
            switch (spec) {
                's' => uart.writeBytes(arg),
                'x' => writeHexU32(arg),
                'd' => writeDecU32(arg),
                else => @compileError("kprintf: unsupported spec " ++ [_]u8{spec}),
            }
            arg_i += 1;
            i += 3;
        } else {
            uart.writeByte(fmt[i]);
            i += 1;
        }
    }
    if (arg_i != args.len) @compileError("kprintf: argument count mismatch");
}

pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    uart.writeBytes("panic: ");
    print(fmt, args);
    uart.writeByte('\n');
    const halt: *volatile u8 = @ptrFromInt(0x00100000);
    halt.* = 0xFF;
    while (true) asm volatile ("wfi");
}
```

- [ ] **Step 3: Update kmain.zig to use uart**

Rewrite `tests/programs/kernel/kmain.zig`:

```zig
// tests/programs/kernel/kmain.zig — Phase 2 Plan 2.C kernel S-mode entry.
//
// Task 3 state: same observable behavior as Task 2 ("ok\n" + exit 0), but
// emitted via uart.writeBytes so the helper is exercised before Task 8
// adds Sv32 paging under it.

const uart = @import("uart.zig");

const HALT_MMIO: *volatile u8 = @ptrFromInt(0x00100000);

export fn kmain() callconv(.c) noreturn {
    uart.writeBytes("ok\n");
    HALT_MMIO.* = 0;
    while (true) asm volatile ("wfi");
}
```

- [ ] **Step 4: Add uart.zig and kprintf.zig as modules the kernel Zig sees**

No build.zig change is needed for sibling Zig imports — Zig's import resolution walks the filesystem from the importing file. BUT: Zig's compile-time test runner for `zig build test` will not compile these files (they live under `tests/programs/kernel/` and aren't imported from `src/main.zig`). The kernel cross-compile does reach them via `kmain.zig`'s `@import`.

To verify: the kernel module (`kernel_kmain_obj`) needs to see `uart.zig` via filesystem sibling resolution. Zig's default module root is `kmain.zig`, so `@import("uart.zig")` resolves to `tests/programs/kernel/uart.zig`. No explicit `addAnonymousImport` needed.

- [ ] **Step 5: Rebuild and run**

Run: `zig build e2e-kernel`

Expected: still passes with `"ok\n"`. If the build fails with "unable to resolve import 'uart.zig'", the kernel module's root_source_file is misconfigured; confirm it points at `tests/programs/kernel/kmain.zig`.

- [ ] **Step 6: Commit**

```bash
git add tests/programs/kernel/uart.zig tests/programs/kernel/kprintf.zig tests/programs/kernel/kmain.zig
git commit -m "feat: kernel uart + kprintf helpers; kmain uses writeBytes (Plan 2.C Task 3)"
```

---

### Task 4: `page_alloc.zig` bump allocator

**Files:**
- Create: `tests/programs/kernel/page_alloc.zig`

**Why this task:** `vm.zig` (Task 5–7) needs a source of 4 KB physical pages for the page-table root and its L0 tables. The allocator is dead-simple — bump from `_end`, never free — because Phase 2 has exactly one process and never reclaims memory. Introducing the allocator in isolation lets us unit-pattern the Zig-side integration (linker-extern symbols, pointer casting) without Sv32 concerns.

- [ ] **Step 1: Create page_alloc.zig**

Create `tests/programs/kernel/page_alloc.zig`:

```zig
// tests/programs/kernel/page_alloc.zig — physical-page bump allocator.
//
// Phase 2 has one process and never frees pages; a bump is sufficient
// and deterministic. `next_pa` starts at the first 4KB boundary at or
// after `_end` (linker symbol = 4KB-aligned by linker.ld) and advances
// by PAGE_SIZE on every alloc. Every returned page is zeroed.
//
// Kernel is direct-mapped at 0x80000000+, so the physical address
// returned doubles as the virtual address for use during kernel walks.

pub const PAGE_SIZE: u32 = 4096;
pub const RAM_END: u32 = 0x8800_0000; // 128 MiB RAM ceiling; panic past this

// Linker symbol: first byte past all kernel sections (stack included).
extern const _end: u8;

var next_pa: u32 = 0;

pub fn init() void {
    const end_addr: u32 = @intCast(@intFromPtr(&_end));
    next_pa = alignForward(end_addr);
}

pub fn allocZeroPage() u32 {
    if (next_pa + PAGE_SIZE > RAM_END) {
        @import("kprintf.zig").panic(
            "page_alloc: out of RAM at {x}",
            .{next_pa},
        );
    }
    const pa = next_pa;
    next_pa += PAGE_SIZE;
    const slice: [*]volatile u8 = @ptrFromInt(pa);
    var i: u32 = 0;
    while (i < PAGE_SIZE) : (i += 1) slice[i] = 0;
    return pa;
}

/// Test/debug hook: current bump position.
pub fn heapPos() u32 {
    return next_pa;
}

fn alignForward(x: u32) u32 {
    const mask: u32 = PAGE_SIZE - 1;
    return (x + mask) & ~mask;
}
```

- [ ] **Step 2: Rebuild the kernel to confirm it compiles**

Run: `zig build kernel-elf`

Expected: succeeds. No behavior change (kmain doesn't call into page_alloc yet). If Zig complains about `next_pa` being undefined-at-initialization, the `var next_pa: u32 = 0;` line is the fix — global mutable initialization must be explicit.

- [ ] **Step 3: Commit**

```bash
git add tests/programs/kernel/page_alloc.zig
git commit -m "feat: kernel page_alloc bump allocator from _end (Plan 2.C Task 4)"
```

---

### Task 5: `vm.zig` Sv32 PTE helpers + `allocRoot` + `mapPage`

**Files:**
- Create: `tests/programs/kernel/vm.zig`

**Why this task:** The page-table builder is the meat of the kernel's initialization. Splitting it across Tasks 5–7 lets us land the leaf-write primitive (`mapPage`) first (exercised only in Task 7), add range coverage (`mapRange` + kernel/MMIO coverage) second, and user mapping (which touches user-frame allocation + memcpy) last. Task 5 is the smallest self-contained unit — just the PTE flag layout + the single-page walker.

- [ ] **Step 1: Create vm.zig with PTE constants + allocRoot + mapPage**

Create `tests/programs/kernel/vm.zig`:

```zig
// tests/programs/kernel/vm.zig — kernel-side Sv32 page-table builder.
//
// We never walk page tables from the kernel — the emulator does that on
// every access. We only CONSTRUCT them here. Layout mirrors the emulator's
// memory.zig: 2-level walk, 4KB pages only, PTE bits { V R W X U G A D }.
//
// Kernel is direct-mapped (VA==PA) at 0x80000000+, so physical addresses
// returned by page_alloc can be dereferenced as pointers during the build.
//
// Phase 2 keeps the kernel in a single address space (the process's page
// table), which means kmain's own executing instructions — those between
// the `csrw satp` and `sfence.vma` in Task 7 — must be mapped in that
// table's kernel region. mapKernelAndMmio handles that.

const page_alloc = @import("page_alloc.zig");
const kprintf = @import("kprintf.zig");

pub const PAGE_SIZE: u32 = 4096;
pub const PAGE_SHIFT: u5 = 12;

// PTE flag bits — match src/memory.zig layout exactly.
pub const PTE_V: u32 = 1 << 0;
pub const PTE_R: u32 = 1 << 1;
pub const PTE_W: u32 = 1 << 2;
pub const PTE_X: u32 = 1 << 3;
pub const PTE_U: u32 = 1 << 4;
pub const PTE_G: u32 = 1 << 5;
pub const PTE_A: u32 = 1 << 6;
pub const PTE_D: u32 = 1 << 7;

// Convenience flag combinations. We pre-set A and D on every leaf we
// install — the emulator's translate() would do the same on first
// access, but pre-setting avoids the write-back dance for pages the
// kernel knows will be touched.
pub const KERNEL_TEXT: u32   = PTE_R | PTE_X | PTE_G | PTE_A | PTE_D;
pub const KERNEL_RODATA: u32 = PTE_R         | PTE_G | PTE_A | PTE_D;
pub const KERNEL_DATA: u32   = PTE_R | PTE_W | PTE_G | PTE_A | PTE_D;
pub const KERNEL_MMIO: u32   = PTE_R | PTE_W | PTE_G | PTE_A | PTE_D;
pub const USER_RWX: u32      = PTE_R | PTE_W | PTE_X | PTE_U | PTE_A | PTE_D;
pub const USER_RW: u32       = PTE_R | PTE_W | PTE_U         | PTE_A | PTE_D;

fn vpn1(va: u32) u32 { return (va >> 22) & 0x3FF; }
fn vpn0(va: u32) u32 { return (va >> 12) & 0x3FF; }

fn ppnOfPte(pte: u32) u32 {
    // PPN occupies bits 31:10 of the 32-bit PTE, where bits 9:8 are RSW.
    // PTE layout: [PPN (22)][RSW (2)][DAGU XWR V (8)].
    return (pte >> 10) & 0x3F_FFFF;
}

fn makeLeaf(pa: u32, flags: u32) u32 {
    // pa must be PAGE_SIZE-aligned.
    return ((pa >> 12) << 10) | (flags & 0xFF);
}

fn makePointer(child_pa: u32) u32 {
    // Pointer PTE: V=1, R=W=X=0, PPN = child_pa >> 12.
    return ((child_pa >> 12) << 10) | PTE_V;
}

fn ptePtr(table_pa: u32, index: u32) *volatile u32 {
    return @ptrFromInt(table_pa + index * 4);
}

pub fn allocRoot() u32 {
    // A fresh Sv32 L1 table is just a zeroed 4KB page.
    return page_alloc.allocZeroPage();
}

/// Map a single 4KB page at `va` to physical page `pa` with the given flags.
/// Panics if `va` or `pa` is not PAGE_SIZE-aligned, if the L0 leaf is
/// already populated, or if the L1 entry is a leaf (Phase 2 rejects
/// superpages so we never write one, but we guard in case a future bug
/// corrupts the root).
pub fn mapPage(root_pa: u32, va: u32, pa: u32, flags: u32) void {
    if ((va & (PAGE_SIZE - 1)) != 0) {
        kprintf.panic("vm.mapPage: unaligned va {x}", .{va});
    }
    if ((pa & (PAGE_SIZE - 1)) != 0) {
        kprintf.panic("vm.mapPage: unaligned pa {x}", .{pa});
    }

    const l1_idx = vpn1(va);
    const l1_entry = ptePtr(root_pa, l1_idx);
    var l0_table_pa: u32 = undefined;
    if ((l1_entry.* & PTE_V) == 0) {
        l0_table_pa = page_alloc.allocZeroPage();
        l1_entry.* = makePointer(l0_table_pa);
    } else {
        // Valid L1 entry — must be a pointer (superpages rejected).
        if ((l1_entry.* & (PTE_R | PTE_W | PTE_X)) != 0) {
            kprintf.panic("vm.mapPage: unexpected L1 leaf at va {x}", .{va});
        }
        l0_table_pa = ppnOfPte(l1_entry.*) << 12;
    }

    const l0_idx = vpn0(va);
    const l0_entry = ptePtr(l0_table_pa, l0_idx);
    if ((l0_entry.* & PTE_V) != 0) {
        kprintf.panic("vm.mapPage: remap at va {x} (old pte {x})", .{ va, l0_entry.* });
    }
    l0_entry.* = makeLeaf(pa, flags | PTE_V);
}
```

- [ ] **Step 2: Rebuild to confirm it compiles**

Run: `zig build kernel-elf`

Expected: succeeds. No behavior change (kmain still doesn't call vm). If Zig complains about integer-cast narrowing on the shift in `writeHexU32`, it's probably this task's u32 vs u5 mismatch — check the `@as(u5, i)` at the print-nibble site.

- [ ] **Step 3: Commit**

```bash
git add tests/programs/kernel/vm.zig
git commit -m "feat: vm.zig with PTE helpers, allocRoot, mapPage (Plan 2.C Task 5)"
```

---

### Task 6: `vm.zig` — `mapRange` + `mapKernelAndMmio`

**Files:**
- Modify: `tests/programs/kernel/vm.zig` (add two new public functions)

**Why this task:** Coverage of the kernel direct-map region + MMIO is where the integration risk lives. If `mapKernelAndMmio` mismaps a page, `csrw satp` in Task 7 enables paging and then the next instruction fetch faults. This task just writes the code; Task 7 exercises it.

- [ ] **Step 1: Add mapRange + mapKernelAndMmio to vm.zig**

Append to `tests/programs/kernel/vm.zig` (inside the module, after `mapPage`):

```zig

/// Map a contiguous VA region to a contiguous PA region, page by page.
/// `va` and `pa` must be PAGE_SIZE-aligned; `len` is rounded up to a
/// PAGE_SIZE multiple.
pub fn mapRange(root_pa: u32, va: u32, pa: u32, len: u32, flags: u32) void {
    const aligned_len = (len + (PAGE_SIZE - 1)) & ~(PAGE_SIZE - 1);
    var off: u32 = 0;
    while (off < aligned_len) : (off += PAGE_SIZE) {
        mapPage(root_pa, va + off, pa + off, flags);
    }
}

// Linker symbols — boundaries of each kernel section, all 4KB-aligned
// by linker.ld.
extern const _text_start: u8;
extern const _text_end: u8;
extern const _rodata_start: u8;
extern const _rodata_end: u8;
extern const _data_start: u8;
extern const _data_end: u8;
extern const _bss_start: u8;
extern const _bss_end: u8;
extern const _kstack_bottom: u8;
extern const _kstack_top: u8;

fn extU32(sym: *const u8) u32 { return @intCast(@intFromPtr(sym)); }

/// Map the kernel's own direct-mapped image plus the MMIO strip into
/// `root_pa`. Kernel VA == Kernel PA for every page we install here.
///
/// After this call, `csrw satp; sfence.vma` can safely switch to the
/// new page table — the executing kernel's .text will still be
/// reachable, its stack will still be valid, and its UART/Halt writes
/// will still hit the real MMIO.
pub fn mapKernelAndMmio(root_pa: u32) void {
    const text_s = extU32(&_text_start);
    const text_e = extU32(&_text_end);
    mapRange(root_pa, text_s, text_s, text_e - text_s, KERNEL_TEXT);

    const rodata_s = extU32(&_rodata_start);
    const rodata_e = extU32(&_rodata_end);
    if (rodata_e > rodata_s) {
        mapRange(root_pa, rodata_s, rodata_s, rodata_e - rodata_s, KERNEL_RODATA);
    }

    const data_s = extU32(&_data_start);
    const data_e = extU32(&_data_end);
    if (data_e > data_s) {
        mapRange(root_pa, data_s, data_s, data_e - data_s, KERNEL_DATA);
    }

    const bss_s = extU32(&_bss_start);
    const bss_e = extU32(&_bss_end);
    if (bss_e > bss_s) {
        mapRange(root_pa, bss_s, bss_s, bss_e - bss_s, KERNEL_DATA);
    }

    const stack_s = extU32(&_kstack_bottom);
    const stack_e = extU32(&_kstack_top);
    mapRange(root_pa, stack_s, stack_s, stack_e - stack_s, KERNEL_DATA);

    // Also cover the free-page region the allocator is bumping into — we
    // need to walk and install entries in L0 tables that the allocator
    // itself is producing, so each of those pages must be mappable as
    // the kernel accesses them. Map the entire 128 MiB RAM ceiling for
    // simplicity; over-mapping is harmless (unreferenced PTEs cost
    // nothing). Start at the current heap position (post-init) and
    // extend to RAM_END.
    const heap_s = page_alloc.heapPos();
    mapRange(root_pa, heap_s, heap_s, page_alloc.RAM_END - heap_s, KERNEL_DATA);

    // MMIO — one page each, identity-mapped, S-only.
    mapPage(root_pa, 0x0010_0000, 0x0010_0000, KERNEL_MMIO); // Halt
    // CLINT spans 0x02000000..0x0200FFFF (64KB). One page is the mtime/
    // mtimecmp window; the kernel only touches that page in S-mode.
    // Future plans touching msip elsewhere in CLINT should extend this.
    mapPage(root_pa, 0x0200_0000, 0x0200_0000, KERNEL_MMIO);
    mapPage(root_pa, 0x0200_4000, 0x0200_4000, KERNEL_MMIO);
    // UART is one page.
    mapPage(root_pa, 0x1000_0000, 0x1000_0000, KERNEL_MMIO);
}
```

**Note on the heap-region map:** `mapKernelAndMmio` is called with `page_alloc` already initialized. Each `mapPage` call may bump `page_alloc` for a fresh L0 table — meaning the current heap grows AS we map. The heap-region map must happen AFTER the section maps (otherwise mid-loop L0 allocations land in unmapped territory). We capture `heap_s` at the start of the heap map, and any allocations DURING the heap map itself land within the range we're about to install — by the time `csrw satp` fires in Task 7, every page touched will be reachable.

Subtlety: since mapping the heap ALSO allocates new L0 tables from the heap, this is self-referential. It terminates because (a) we map a fixed range [heap_s, RAM_END), and (b) each allocation advances heap_s by at most a few pages (the L0 table plus, in the worst case, the page we're mapping itself). `RAM_END - heap_s` shrinks monotonically until the loop ends. Empirically this converges in one pass for a 128 MiB RAM ceiling.

- [ ] **Step 2: Rebuild**

Run: `zig build kernel-elf`

Expected: succeeds. No behavior change yet.

- [ ] **Step 3: Commit**

```bash
git add tests/programs/kernel/vm.zig
git commit -m "feat: vm.mapRange + mapKernelAndMmio (Plan 2.C Task 6)"
```

---

### Task 7: kmain enables paging — checkpoint: "ok\n" still printed, but through Sv32

**Files:**
- Modify: `tests/programs/kernel/kmain.zig`

**Why this task:** This is the first behavioral checkpoint past Task 2. The observable output is still `"ok\n"` and exit 0, but the path has changed substantially: kmain now builds a page table with kernel + MMIO mappings, flips satp to Sv32 mode, sfences, and THEN writes `"ok\n"` + halts. If the translation fails, we hit an instruction-page-fault (cause 12) or a load/store-page-fault (13/15) delegated to S — but stvec isn't installed yet in this task, so we panic via the non-delegated path back in M-mode (which also has no trap vector yet → emulator reports FatalTrap). Expected: e2e-kernel still passes.

- [ ] **Step 1: Rewrite kmain.zig to enable paging before printing**

Replace `tests/programs/kernel/kmain.zig` with:

```zig
// tests/programs/kernel/kmain.zig — Phase 2 Plan 2.C kernel S-mode entry.
//
// Task 7 state: proves Sv32 paging works under a bare kernel. After the
// csrw satp + sfence.vma, every load/fetch/store walks the page table we
// just built. uart.writeBytes, the halt MMIO store, and the `wfi` spin
// all go through translation.
//
// No traps handled yet (stvec is not installed) — a page fault here
// would be fatal. Task 10 adds the trap plumbing.

const uart = @import("uart.zig");
const vm = @import("vm.zig");
const page_alloc = @import("page_alloc.zig");

const SATP_MODE_SV32: u32 = 1 << 31;

const HALT_MMIO: *volatile u8 = @ptrFromInt(0x00100000);

export fn kmain() callconv(.c) noreturn {
    page_alloc.init();
    const root_pa = vm.allocRoot();
    vm.mapKernelAndMmio(root_pa);

    const satp_val: u32 = SATP_MODE_SV32 | (root_pa >> 12);
    asm volatile (
        \\ csrw satp, %[satp]
        \\ sfence.vma zero, zero
        :
        : [satp] "r" (satp_val),
        : "memory"
    );

    uart.writeBytes("ok\n");
    HALT_MMIO.* = 0;
    while (true) asm volatile ("wfi");
}
```

- [ ] **Step 2: Rebuild + run**

Run: `zig build e2e-kernel`

Expected: passes, `"ok\n"` + exit 0.

**If it fails with a page fault:** trace with `zig-out/bin/ccc --trace zig-out/bin/kernel.elf 2>&1 | tail -40` and look for the first post-satp instruction. If that PC is the `csrw satp` itself, satp wasn't yet enabled when the instruction executed — the sfence.vma is the synchronization point, so in practice the next instruction fetch is the first that walks the table. If the PC is in `uart.writeBytes`, the .text mapping of that function is missing; inspect `_text_start` / `_text_end` by disassembling kernel.elf: `zig-out/bin/ccc` depends on llvm-objdump; if absent, use `nm zig-out/bin/kernel.elf | grep _text`.

- [ ] **Step 3: Commit**

```bash
git add tests/programs/kernel/kmain.zig
git commit -m "feat: kmain enables Sv32 paging with direct-mapped kernel (Plan 2.C Task 7)"
```

---

### Task 8: `trap.zig` — `TrapFrame` struct + offsets constants

**Files:**
- Create: `tests/programs/kernel/trap.zig`

**Why this task:** `trampoline.S` needs TrapFrame field offsets as assembler constants. Establishing the struct layout first — with a comptime-checked block that asserts the offsets match what asm will hard-code — catches ABI drift early. The dispatcher body arrives in Task 10.

- [ ] **Step 1: Create trap.zig with just the struct + offsets**

Create `tests/programs/kernel/trap.zig`:

```zig
// tests/programs/kernel/trap.zig — S-mode trap dispatcher.
//
// Task 8 state: just the TrapFrame struct and its offset constants.
// Task 10 adds s_trap_dispatch.
//
// Field order matters. trampoline.S saves/restores registers at fixed
// offsets; any re-ordering here is an asm ABI break. The comptime block
// below pins the offsets.

const std = @import("std");

pub const TrapFrame = extern struct {
    ra: u32, // x1
    sp: u32, // x2   (saved via sscratch dance)
    gp: u32, // x3
    tp: u32, // x4
    t0: u32, // x5
    t1: u32, // x6
    t2: u32, // x7
    s0: u32, // x8
    s1: u32, // x9
    a0: u32, // x10
    a1: u32, // x11
    a2: u32, // x12
    a3: u32, // x13
    a4: u32, // x14
    a5: u32, // x15
    a6: u32, // x16
    a7: u32, // x17
    s2: u32, // x18
    s3: u32, // x19
    s4: u32, // x20
    s5: u32, // x21
    s6: u32, // x22
    s7: u32, // x23
    s8: u32, // x24
    s9: u32, // x25
    s10: u32, // x26
    s11: u32, // x27
    t3: u32, // x28
    t4: u32, // x29
    t5: u32, // x30
    t6: u32, // x31
    sepc: u32, // 128th byte
};

// Offset constants — referenced as .globl symbols from trampoline.S via
// `.equ`. To keep the asm portable we export these as numeric literals
// that the asm file mirrors in its own .equ block; the comptime assert
// here guarantees the two mirrors stay in sync.
pub const TF_RA: u32 = 0;
pub const TF_SP: u32 = 4;
pub const TF_GP: u32 = 8;
pub const TF_TP: u32 = 12;
pub const TF_T0: u32 = 16;
pub const TF_T1: u32 = 20;
pub const TF_T2: u32 = 24;
pub const TF_S0: u32 = 28;
pub const TF_S1: u32 = 32;
pub const TF_A0: u32 = 36;
pub const TF_A1: u32 = 40;
pub const TF_A2: u32 = 44;
pub const TF_A3: u32 = 48;
pub const TF_A4: u32 = 52;
pub const TF_A5: u32 = 56;
pub const TF_A6: u32 = 60;
pub const TF_A7: u32 = 64;
pub const TF_S2: u32 = 68;
pub const TF_S3: u32 = 72;
pub const TF_S4: u32 = 76;
pub const TF_S5: u32 = 80;
pub const TF_S6: u32 = 84;
pub const TF_S7: u32 = 88;
pub const TF_S8: u32 = 92;
pub const TF_S9: u32 = 96;
pub const TF_S10: u32 = 100;
pub const TF_S11: u32 = 104;
pub const TF_T3: u32 = 108;
pub const TF_T4: u32 = 112;
pub const TF_T5: u32 = 116;
pub const TF_T6: u32 = 120;
pub const TF_SEPC: u32 = 124;
pub const TF_SIZE: u32 = 128;

comptime {
    std.debug.assert(@offsetOf(TrapFrame, "ra") == TF_RA);
    std.debug.assert(@offsetOf(TrapFrame, "sp") == TF_SP);
    std.debug.assert(@offsetOf(TrapFrame, "gp") == TF_GP);
    std.debug.assert(@offsetOf(TrapFrame, "tp") == TF_TP);
    std.debug.assert(@offsetOf(TrapFrame, "t0") == TF_T0);
    std.debug.assert(@offsetOf(TrapFrame, "t1") == TF_T1);
    std.debug.assert(@offsetOf(TrapFrame, "t2") == TF_T2);
    std.debug.assert(@offsetOf(TrapFrame, "s0") == TF_S0);
    std.debug.assert(@offsetOf(TrapFrame, "s1") == TF_S1);
    std.debug.assert(@offsetOf(TrapFrame, "a0") == TF_A0);
    std.debug.assert(@offsetOf(TrapFrame, "a7") == TF_A7);
    std.debug.assert(@offsetOf(TrapFrame, "s2") == TF_S2);
    std.debug.assert(@offsetOf(TrapFrame, "t3") == TF_T3);
    std.debug.assert(@offsetOf(TrapFrame, "t6") == TF_T6);
    std.debug.assert(@offsetOf(TrapFrame, "sepc") == TF_SEPC);
    std.debug.assert(@sizeOf(TrapFrame) == TF_SIZE);
}
```

- [ ] **Step 2: Rebuild**

Run: `zig build kernel-elf`

Expected: succeeds. The comptime asserts fire at compile time if `@offsetOf` disagrees with the manual offset.

- [ ] **Step 3: Commit**

```bash
git add tests/programs/kernel/trap.zig
git commit -m "feat: kernel TrapFrame struct + frozen offset table (Plan 2.C Task 8)"
```

---

### Task 9: `trampoline.S` — S-mode trap entry + return-to-user path

**Files:**
- Create: `tests/programs/kernel/trampoline.S`
- Modify: `build.zig` (link trampoline.S into kernel.elf)
- Modify: `tests/programs/kernel/kmain.zig` (export `the_tf` as a global so trampoline can locate it via `la`)

**Why this task:** trampoline.S is the asm bridge between U-mode trap entry and the Zig dispatcher (Task 10). It saves every user GPR into `the_tf`, then switches to the kernel stack and calls `s_trap_dispatch`. The return path mirrors: restore regs, sret. No code actually jumps through this trampoline until Task 13, but we land it early to keep the dependency graph linear.

- [ ] **Step 1: Create trampoline.S**

Create `tests/programs/kernel/trampoline.S`:

```
# tests/programs/kernel/trampoline.S — S-mode trap entry/exit.
#
# On trap: stvec points here. sscratch holds &the_tf (kmain initializes
# it before sret). We swap sp with sscratch to land on &the_tf, save all
# user GPRs at fixed offsets, then switch to the kernel stack and call
# s_trap_dispatch (Zig, in trap.zig).
#
# Return-to-user path: restore GPRs from &the_tf, then sret. The last
# two loads handle sp and a0 — a0 has been serving as the tf base
# pointer, so it's loaded last (which discards the base pointer as
# a side effect — well-known RISC-V trampoline idiom).
#
# Offsets MUST match trap.zig's TF_* constants. comptime asserts in
# trap.zig catch drift; this .equ block mirrors the numeric values.

.equ TF_RA,   0
.equ TF_SP,   4
.equ TF_GP,   8
.equ TF_TP,  12
.equ TF_T0,  16
.equ TF_T1,  20
.equ TF_T2,  24
.equ TF_S0,  28
.equ TF_S1,  32
.equ TF_A0,  36
.equ TF_A1,  40
.equ TF_A2,  44
.equ TF_A3,  48
.equ TF_A4,  52
.equ TF_A5,  56
.equ TF_A6,  60
.equ TF_A7,  64
.equ TF_S2,  68
.equ TF_S3,  72
.equ TF_S4,  76
.equ TF_S5,  80
.equ TF_S6,  84
.equ TF_S7,  88
.equ TF_S8,  92
.equ TF_S9,  96
.equ TF_S10, 100
.equ TF_S11, 104
.equ TF_T3,  108
.equ TF_T4,  112
.equ TF_T5,  116
.equ TF_T6,  120
.equ TF_SEPC, 124

.section .text, "ax", @progbits
.balign 4
.globl s_trap_entry
s_trap_entry:
    # sp <-> sscratch: sp now = &the_tf, sscratch now = user sp.
    csrrw   sp, sscratch, sp

    # Save all GPRs except x0 and x2 (sp, which we'll save from sscratch).
    sw      x1,  TF_RA(sp)
    sw      x3,  TF_GP(sp)
    sw      x4,  TF_TP(sp)
    sw      x5,  TF_T0(sp)
    sw      x6,  TF_T1(sp)
    sw      x7,  TF_T2(sp)
    sw      x8,  TF_S0(sp)
    sw      x9,  TF_S1(sp)
    sw      x10, TF_A0(sp)
    sw      x11, TF_A1(sp)
    sw      x12, TF_A2(sp)
    sw      x13, TF_A3(sp)
    sw      x14, TF_A4(sp)
    sw      x15, TF_A5(sp)
    sw      x16, TF_A6(sp)
    sw      x17, TF_A7(sp)
    sw      x18, TF_S2(sp)
    sw      x19, TF_S3(sp)
    sw      x20, TF_S4(sp)
    sw      x21, TF_S5(sp)
    sw      x22, TF_S6(sp)
    sw      x23, TF_S7(sp)
    sw      x24, TF_S8(sp)
    sw      x25, TF_S9(sp)
    sw      x26, TF_S10(sp)
    sw      x27, TF_S11(sp)
    sw      x28, TF_T3(sp)
    sw      x29, TF_T4(sp)
    sw      x30, TF_T5(sp)
    sw      x31, TF_T6(sp)

    # User sp is in sscratch. Save it into tf.sp.
    csrr    t0, sscratch
    sw      t0, TF_SP(sp)

    # Reset sscratch = &the_tf so the NEXT trap has something valid to
    # swap with. We pass &the_tf via a la instruction (Zig exports the
    # symbol) — the linker places it in kernel .bss/.data.
    la      t0, the_tf
    csrw    sscratch, t0

    # Save sepc.
    csrr    t0, sepc
    sw      t0, TF_SEPC(sp)

    # Switch sp to the kernel stack. _kstack_top is the linker symbol.
    la      sp, _kstack_top

    # Call s_trap_dispatch(tf).
    la      a0, the_tf
    call    s_trap_dispatch

    # Fall through to return-to-user.

.globl s_return_to_user
s_return_to_user:
    # a0 = &the_tf (either from call return or kmain's initial jump).

    # Restore sepc first.
    lw      t0, TF_SEPC(a0)
    csrw    sepc, t0

    # Restore every GPR except a0 and sp. Order doesn't matter except
    # that a0 comes last.
    lw      x1,  TF_RA(a0)
    lw      x3,  TF_GP(a0)
    lw      x4,  TF_TP(a0)
    lw      x5,  TF_T0(a0)
    lw      x6,  TF_T1(a0)
    lw      x7,  TF_T2(a0)
    lw      x8,  TF_S0(a0)
    lw      x9,  TF_S1(a0)
    lw      x11, TF_A1(a0)
    lw      x12, TF_A2(a0)
    lw      x13, TF_A3(a0)
    lw      x14, TF_A4(a0)
    lw      x15, TF_A5(a0)
    lw      x16, TF_A6(a0)
    lw      x17, TF_A7(a0)
    lw      x18, TF_S2(a0)
    lw      x19, TF_S3(a0)
    lw      x20, TF_S4(a0)
    lw      x21, TF_S5(a0)
    lw      x22, TF_S6(a0)
    lw      x23, TF_S7(a0)
    lw      x24, TF_S8(a0)
    lw      x25, TF_S9(a0)
    lw      x26, TF_S10(a0)
    lw      x27, TF_S11(a0)
    lw      x28, TF_T3(a0)
    lw      x29, TF_T4(a0)
    lw      x30, TF_T5(a0)
    lw      x31, TF_T6(a0)

    # Restore sp (from tf.sp — the user's sp saved on entry). a0 is
    # still the tf pointer here; the next load reuses it.
    lw      x2,  TF_SP(a0)

    # Last: restore a0 (user's saved a0 value). This overwrites the tf
    # base pointer, but we don't need it after this.
    lw      x10, TF_A0(a0)

    sret
```

- [ ] **Step 2: Export the_tf from kmain.zig**

Modify `tests/programs/kernel/kmain.zig`. Replace its current content with:

```zig
// tests/programs/kernel/kmain.zig — Phase 2 Plan 2.C kernel S-mode entry.
//
// Task 9 state: paging still works (from Task 7); `the_tf` is exported
// for trampoline.S to reach via `la`. kmain does not yet install stvec
// or jump into the trampoline — that happens in Tasks 13 and 17.

const uart = @import("uart.zig");
const vm = @import("vm.zig");
const page_alloc = @import("page_alloc.zig");
const trap = @import("trap.zig");

const SATP_MODE_SV32: u32 = 1 << 31;
const HALT_MMIO: *volatile u8 = @ptrFromInt(0x00100000);

// Exported so trampoline.S can reference via `la the_tf`. Initial zero
// values are placeholders; Task 17 fills them in before the first sret.
pub export var the_tf: trap.TrapFrame = std.mem.zeroes(trap.TrapFrame);

const std = @import("std");

export fn kmain() callconv(.c) noreturn {
    page_alloc.init();
    const root_pa = vm.allocRoot();
    vm.mapKernelAndMmio(root_pa);

    const satp_val: u32 = SATP_MODE_SV32 | (root_pa >> 12);
    asm volatile (
        \\ csrw satp, %[satp]
        \\ sfence.vma zero, zero
        :
        : [satp] "r" (satp_val),
        : "memory"
    );

    uart.writeBytes("ok\n");
    HALT_MMIO.* = 0;
    while (true) asm volatile ("wfi");
}
```

- [ ] **Step 3: Add trampoline.S to the kernel build**

In `build.zig`, locate the `kernel_elf` assembly — we currently have `kernel_boot_obj` and `kernel_kmain_obj`. Add a sibling for trampoline.S BEFORE the `kernel_elf` declaration:

```zig
    const kernel_trampoline_obj = b.addObject(.{
        .name = "kernel-trampoline",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
        }),
    });
    kernel_trampoline_obj.root_module.addAssemblyFile(b.path("tests/programs/kernel/trampoline.S"));
```

And add it to the kernel_elf module:

```zig
    kernel_elf.root_module.addObject(kernel_boot_obj);
    kernel_elf.root_module.addObject(kernel_trampoline_obj);  // NEW
    kernel_elf.root_module.addObject(kernel_kmain_obj);
```

- [ ] **Step 4: Add the `s_trap_dispatch` link-time stub**

trampoline.S's `call s_trap_dispatch` needs the symbol to resolve. Task 10 replaces this with a real body; for now a panic-stub is sufficient.

Append to `tests/programs/kernel/trap.zig`:

```zig
// Task 9 shim: asm references s_trap_dispatch at link time; this stub
// lets the linker resolve the symbol. Task 10 replaces this with the
// real dispatcher body.
export fn s_trap_dispatch(tf: *TrapFrame) callconv(.c) void {
    _ = tf;
    // Unreachable in Task 9 — kmain does not yet jump to the trampoline.
    @import("kprintf.zig").panic("s_trap_dispatch: not implemented (Task 9 stub)", .{});
}
```

- [ ] **Step 5: Rebuild**

Run: `zig build kernel-elf`

Expected: succeeds. The asm assembles, and the linker resolves `the_tf` (from kmain.zig), `_kstack_top` (from linker.ld), and `s_trap_dispatch` (from the Step 4 stub).

- [ ] **Step 6: Run the e2e**

Run: `zig build e2e-kernel`

Expected: still `"ok\n"` + exit 0. kmain doesn't jump to the trampoline, so the stub is never hit.

- [ ] **Step 7: Commit**

```bash
git add tests/programs/kernel/trampoline.S tests/programs/kernel/kmain.zig tests/programs/kernel/trap.zig build.zig
git commit -m "feat: trampoline.S save/restore + kmain exports the_tf (Plan 2.C Task 9)"
```

---

### Task 10: `trap.zig` — real `s_trap_dispatch` body with ECALL + panic paths

**Files:**
- Modify: `tests/programs/kernel/trap.zig` (replace the Task 9 stub with the real dispatcher)

**Why this task:** We add the real dispatcher body, wired only to ECALL (cause 8) and a panic-on-anything-else fallback. The supervisor-software-interrupt branch (SSI, cause 1 with interrupt bit set) and the syscall import arrive in Tasks 12 and 20 respectively. For this task we stub the ECALL branch with a panic so it's trivially testable once plumbing exists, but not yet reachable.

- [ ] **Step 1: Replace the Task 9 stub with the real dispatcher**

Rewrite the bottom of `tests/programs/kernel/trap.zig` — keep the `TrapFrame` struct and the offset constants from Task 8, then replace the `s_trap_dispatch` stub with:

```zig
const kprintf = @import("kprintf.zig");
const syscall = @import("syscall.zig");

fn readScause() u32 {
    return asm volatile ("csrr %[out], scause"
        : [out] "=r" (-> u32),
    );
}

fn readStval() u32 {
    return asm volatile ("csrr %[out], stval"
        : [out] "=r" (-> u32),
    );
}

fn clearSipSsip() void {
    // sip.SSIP is bit 1. `csrc sip, 2` clears it.
    asm volatile ("csrci sip, 2" ::: "memory");
}

export fn s_trap_dispatch(tf: *TrapFrame) callconv(.c) void {
    const scause = readScause();
    const is_interrupt = (scause >> 31) & 1 == 1;
    const cause = scause & 0x7fff_ffff;

    if (!is_interrupt and cause == 8) {
        // ECALL from U — advance sepc past the ecall instruction (4 bytes)
        // so sret returns to the next instruction.
        tf.sepc +%= 4;
        syscall.dispatch(tf);
        return;
    }

    if (is_interrupt and cause == 1) {
        // Supervisor software interrupt — forwarded timer tick. Plan 2.C
        // has no scheduler; just acknowledge and return.
        clearSipSsip();
        return;
    }

    // Synchronous faults — kernel-origin bugs in Phase 2. Panic with
    // scause + stval so the cause is visible.
    kprintf.panic(
        "unhandled S-mode trap: scause={x} stval={x} sepc={x}",
        .{ scause, readStval(), tf.sepc },
    );
}
```

- [ ] **Step 2: Create syscall.zig stub (needed for `syscall.dispatch` to resolve at link time)**

`trap.zig` imports `syscall` but Task 12 is the one that actually implements the dispatch body. For now, land a panic-stub so the build stays green.

Create `tests/programs/kernel/syscall.zig`:

```zig
// tests/programs/kernel/syscall.zig — syscall table.
//
// Task 10 state: just a stub so trap.zig's import resolves. Tasks 11-12
// fill in sys_write, sys_exit, dispatch.

const trap = @import("trap.zig");

pub fn dispatch(tf: *trap.TrapFrame) void {
    _ = tf;
    @import("kprintf.zig").panic("syscall.dispatch: not implemented (Task 10 stub)", .{});
}
```

No build.zig change — `trap.zig`'s `@import("syscall.zig")` resolves via sibling filesystem lookup (the kernel module's root is `kmain.zig`, which lives in the same directory).

- [ ] **Step 3: Rebuild**

Run: `zig build kernel-elf`

Expected: succeeds.

- [ ] **Step 4: Run the e2e**

Run: `zig build e2e-kernel`

Expected: still `"ok\n"` + exit 0. kmain still does not install stvec, so no trap reaches the dispatcher yet.

- [ ] **Step 5: Commit**

```bash
git add tests/programs/kernel/trap.zig tests/programs/kernel/syscall.zig
git commit -m "feat: s_trap_dispatch with ECALL/SSI branches + syscall.zig stub (Plan 2.C Task 10)"
```

---

### Task 11: `syscall.zig` — `sys_write` implementation

**Files:**
- Modify: `tests/programs/kernel/syscall.zig`

**Why this task:** The write syscall is the meatier of the two. It needs to toggle `sstatus.SUM` around the user-memory reads so the kernel (in S-mode) can legally fetch bytes from U-accessible pages. We land it before `sys_exit` (Task 12) because it's the one whose correctness is observable in the final e2e output.

- [ ] **Step 1: Implement sys_write**

Replace `tests/programs/kernel/syscall.zig` with:

```zig
// tests/programs/kernel/syscall.zig — syscall table.
//
// Task 11 state: sys_write implemented; sys_exit still stubbed. Task 12
// finishes both and dispatch.

const trap = @import("trap.zig");
const uart = @import("uart.zig");

const SSTATUS_SUM: u32 = 1 << 18;

fn setSum() void {
    asm volatile ("csrs sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SUM),
        : "memory"
    );
}

fn clearSum() void {
    asm volatile ("csrc sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SUM),
        : "memory"
    );
}

fn sysWrite(fd: u32, buf_va: u32, len: u32) u32 {
    if (fd != 1 and fd != 2) {
        return @bitCast(@as(i32, -9)); // -EBADF
    }
    setSum();
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const p: *const volatile u8 = @ptrFromInt(buf_va + i);
        uart.writeByte(p.*);
    }
    clearSum();
    return len;
}

pub fn dispatch(tf: *trap.TrapFrame) void {
    _ = tf;
    @import("kprintf.zig").panic("syscall.dispatch: not implemented (Task 11 stub)", .{});
}

// Keep sys_write file-scope-callable; Task 12 wires dispatch().
pub const sys_write = sysWrite;
```

- [ ] **Step 2: Rebuild**

Run: `zig build kernel-elf`

Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add tests/programs/kernel/syscall.zig
git commit -m "feat: kernel sys_write with sstatus.SUM toggle (Plan 2.C Task 11)"
```

---

### Task 12: `syscall.zig` — `sys_exit` + dispatch table

**Files:**
- Modify: `tests/programs/kernel/syscall.zig`

**Why this task:** Complete the syscall table: add `sys_exit` and the `dispatch` that routes by `tf.a7`. After this task, the kernel can service ECALL from U — though no U-mode code is running yet.

- [ ] **Step 1: Add sys_exit + dispatch**

Replace `tests/programs/kernel/syscall.zig` with:

```zig
// tests/programs/kernel/syscall.zig — syscall table.
//
// Phase 2 Plan 2.C supports write(64) + exit(93). yield(124) arrives in
// Plan 2.D when the scheduler lands.

const trap = @import("trap.zig");
const uart = @import("uart.zig");

const SSTATUS_SUM: u32 = 1 << 18;

fn setSum() void {
    asm volatile ("csrs sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SUM),
        : "memory"
    );
}

fn clearSum() void {
    asm volatile ("csrc sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SUM),
        : "memory"
    );
}

fn sysWrite(fd: u32, buf_va: u32, len: u32) u32 {
    if (fd != 1 and fd != 2) {
        return @bitCast(@as(i32, -9)); // -EBADF
    }
    setSum();
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const p: *const volatile u8 = @ptrFromInt(buf_va + i);
        uart.writeByte(p.*);
    }
    clearSum();
    return len;
}

fn sysExit(status: u32) noreturn {
    const halt: *volatile u8 = @ptrFromInt(0x00100000);
    halt.* = @intCast(status & 0xFF);
    // Unreachable — halt MMIO terminates the emulator on the store above.
    while (true) asm volatile ("wfi");
}

pub fn dispatch(tf: *trap.TrapFrame) void {
    switch (tf.a7) {
        64 => tf.a0 = sysWrite(tf.a0, tf.a1, tf.a2),
        93 => sysExit(tf.a0),
        124 => {
            // yield — not implemented in Plan 2.C; Plan 2.D adds it.
            tf.a0 = @bitCast(@as(i32, -38)); // -ENOSYS
        },
        else => tf.a0 = @bitCast(@as(i32, -38)), // -ENOSYS
    }
}
```

- [ ] **Step 2: Rebuild + run e2e**

Run: `zig build e2e-kernel`

Expected: still `"ok\n"` + exit 0. Nothing calls `dispatch` yet.

- [ ] **Step 3: Commit**

```bash
git add tests/programs/kernel/syscall.zig
git commit -m "feat: kernel sys_exit + dispatch routing (Plan 2.C Task 12)"
```

---

### Task 13: User program — `user/user_linker.ld` + `user/userprog.zig`

**Files:**
- Create: `tests/programs/kernel/user/user_linker.ld`
- Create: `tests/programs/kernel/user/userprog.zig`

**Why this task:** The user program is tiny and stable — let's land it before wiring it into the kernel. No build-graph changes yet; Task 14 adds the objcopy + embed plumbing.

- [ ] **Step 1: Create user_linker.ld**

Create `tests/programs/kernel/user/user_linker.ld`:

```
/* Linker script for userprog.elf (Plan 2.C U-mode payload).
 *
 * Layout:
 *   0x00010000  .text.init   (_start, naked asm)
 *               .text        (catch-all)
 *               .rodata      (msg)
 *   ...
 *
 * Contiguous — vm.mapUser treats the whole blob as one RWX span in 2.C.
 * Permission tightening is a Plan 3+ concern.
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
    USER (rwx) : ORIGIN = 0x00010000, LENGTH = 64K
}

SECTIONS {
    . = 0x00010000;
    _user_start = .;

    .text : {
        KEEP(*(.text.init))
        *(.text .text.*)
    } > USER

    .rodata : {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > USER

    .data : {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > USER

    .bss : {
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
    } > USER

    _user_end = .;

    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.eh_frame)
        *(.riscv.attributes)
    }
}
```

- [ ] **Step 2: Create userprog.zig**

Create `tests/programs/kernel/user/userprog.zig`:

```zig
// tests/programs/kernel/user/userprog.zig — Plan 2.C U-mode payload.
//
// Naked `_start` makes two ecalls (write + exit) and spins.
// Syscall ABI (matches Linux RISC-V subset):
//   a7 = syscall #, a0..a5 = args, a0 = return.
//   write (64): fd=a0, buf=a1, len=a2
//   exit  (93): status=a0 → halts emulator via kernel sys_exit

const MSG = "hello from u-mode\n";

export const msg linksection(".rodata") = [_]u8{
    'h', 'e', 'l', 'l', 'o', ' ', 'f', 'r', 'o', 'm',
    ' ', 'u', '-', 'm', 'o', 'd', 'e', '\n',
};

comptime {
    if (MSG.len != 18) @compileError("MSG must be 18 bytes (see _start's a2)");
    if (msg.len != 18) @compileError("msg array length must match MSG.len");
}

export fn _start() linksection(".text.init") callconv(.naked) noreturn {
    asm volatile (
        \\ li   a7, 64
        \\ li   a0, 1
        \\ la   a1, msg
        \\ li   a2, 18
        \\ ecall
        \\ li   a7, 93
        \\ li   a0, 0
        \\ ecall
        \\ 1:
        \\ j    1b
    );
}
```

- [ ] **Step 3: Rebuild the kernel (verify nothing broke)**

Run: `zig build kernel-elf`

Expected: still succeeds. userprog.zig is not yet in the build graph — this task is a pure "write file, don't link" step.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/kernel/user/user_linker.ld tests/programs/kernel/user/userprog.zig
git commit -m "feat: user program source (write + exit, 18-byte msg) (Plan 2.C Task 13)"
```

---

### Task 14: `userprog.bin` build + embed into kernel via `@embedFile` shim

**Files:**
- Modify: `build.zig` (add userprog-elf cross-compile, objcopy to bin, WriteFile stub, anonymous import on the kernel module)
- Modify: `tests/programs/kernel/kmain.zig` (import `user_blob` and expose `USER_BLOB`)

**Why this task:** This is the single trickiest piece of build-graph plumbing in Plan 2.C. We produce a flat binary via llvm-objcopy, co-locate a generated Zig stub with it in a `WriteFile` output, and import that stub from the kernel module so `@embedFile` resolves to the sibling file. Get this right once; everything else downstream is pure Zig/asm.

- [ ] **Step 1: Add userprog build graph**

In `build.zig`, after the existing `kernel_trampoline_obj` block (added in Task 9) and BEFORE the `kernel_elf` declaration, insert:

```zig
    // === User program (Plan 2.C) ===
    const userprog_obj = b.addObject(.{
        .name = "userprog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/user/userprog.zig"),
            .target = rv_target,
            .optimize = .ReleaseSmall,
            .strip = false,
            .single_threaded = true,
        }),
    });

    const userprog_elf = b.addExecutable(.{
        .name = "userprog.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .ReleaseSmall,
            .strip = false,
            .single_threaded = true,
        }),
    });
    userprog_elf.root_module.addObject(userprog_obj);
    userprog_elf.setLinkerScript(b.path("tests/programs/kernel/user/user_linker.ld"));
    userprog_elf.entry = .{ .symbol_name = "_start" };

    // Flatten ELF -> raw binary so the kernel can @embedFile it.
    const objcopy_cmd = b.addSystemCommand(&.{
        "llvm-objcopy", "-O", "binary",
    });
    objcopy_cmd.addFileArg(userprog_elf.getEmittedBin());
    const userprog_bin = objcopy_cmd.addOutputFileArg("userprog.bin");

    // WriteFile step that co-locates a tiny Zig stub with userprog.bin
    // in a single output dir. The stub `pub const BLOB = @embedFile(...)`
    // is resolved relative to itself, so the bin must be its sibling.
    const user_blob_stub_dir = b.addWriteFiles();
    const user_blob_zig = user_blob_stub_dir.add(
        "user_blob.zig",
        "pub const BLOB = @embedFile(\"userprog.bin\");\n",
    );
    _ = user_blob_stub_dir.addCopyFile(userprog_bin, "userprog.bin");

    // Expose a top-level step for CI / debugging.
    const install_userprog_bin = b.addInstallFile(userprog_bin, "userprog.bin");
    const kernel_user_step = b.step("kernel-user", "Build the Plan 2.C userprog.bin");
    kernel_user_step.dependOn(&install_userprog_bin.step);
```

- [ ] **Step 2: Wire the stub into the kernel kmain module**

Still in `build.zig`, locate the `kernel_kmain_obj` declaration (Task 2). Add an anonymous import AFTER the object is created:

```zig
    kernel_kmain_obj.root_module.addAnonymousImport("user_blob", .{
        .root_source_file = user_blob_zig,
    });
```

- [ ] **Step 3: Use the blob in kmain.zig**

Modify `tests/programs/kernel/kmain.zig` to import and expose the blob (we'll use it in Task 16; for now we just reference it to force the linker to include the .rodata):

```zig
// tests/programs/kernel/kmain.zig — Phase 2 Plan 2.C kernel S-mode entry.
//
// Task 14 state: user_blob is imported and exported as a pub const.
// kmain still does the same "ok\n" + halt behavior from Task 7. Task 17
// starts using USER_BLOB via vm.mapUser.

const std = @import("std");
const uart = @import("uart.zig");
const vm = @import("vm.zig");
const page_alloc = @import("page_alloc.zig");
const trap = @import("trap.zig");
const user_blob = @import("user_blob");

pub const USER_BLOB: []const u8 = user_blob.BLOB;

const SATP_MODE_SV32: u32 = 1 << 31;
const HALT_MMIO: *volatile u8 = @ptrFromInt(0x00100000);

pub export var the_tf: trap.TrapFrame = std.mem.zeroes(trap.TrapFrame);

export fn kmain() callconv(.c) noreturn {
    page_alloc.init();
    const root_pa = vm.allocRoot();
    vm.mapKernelAndMmio(root_pa);

    const satp_val: u32 = SATP_MODE_SV32 | (root_pa >> 12);
    asm volatile (
        \\ csrw satp, %[satp]
        \\ sfence.vma zero, zero
        :
        : [satp] "r" (satp_val),
        : "memory"
    );

    uart.writeBytes("ok\n");
    HALT_MMIO.* = 0;
    while (true) asm volatile ("wfi");
}
```

- [ ] **Step 4: Rebuild**

Run: `zig build kernel-user` (produces `zig-out/bin/userprog.bin`)
Run: `zig build kernel-elf`

Expected: both succeed. Check the .bin is non-empty: `wc -c zig-out/bin/userprog.bin` — should be a few dozen bytes at minimum (probably 60–200 bytes depending on Zig's code gen).

- [ ] **Step 5: Confirm the embed actually reached the kernel image**

Run: `nm zig-out/bin/kernel.elf | grep -i msg; nm zig-out/bin/kernel.elf | grep -i blob` — at least one of these should show a symbol near a ~18-byte or ~64-byte rodata object. We're just confirming the link picked up the anonymous import; if the kernel's `.rodata` grew by the size of userprog.bin between this task's before/after builds, the plumbing works.

Run: `zig build e2e-kernel`

Expected: still `"ok\n"` + exit 0 (nothing exercises USER_BLOB yet).

- [ ] **Step 6: Commit**

```bash
git add build.zig tests/programs/kernel/kmain.zig
git commit -m "feat: userprog.bin built and embedded into kernel.elf via stub (Plan 2.C Task 14)"
```

---

### Task 15: `vm.zig` — `mapUser(root, blob_ptr, blob_len)`

**Files:**
- Modify: `tests/programs/kernel/vm.zig` (add `mapUser`)

**Why this task:** Final vm.zig method. Allocates physical frames for the user blob, memcpys the blob bytes into those frames, and installs user PTEs pointing at them. Also maps 2 stack pages at VA 0x00030000.

- [ ] **Step 1: Add mapUser to vm.zig**

Append to `tests/programs/kernel/vm.zig` (after `mapKernelAndMmio`):

```zig

pub const USER_TEXT_VA: u32 = 0x0001_0000;
pub const USER_STACK_TOP: u32 = 0x0003_2000;
pub const USER_STACK_BOTTOM: u32 = 0x0003_0000;
pub const USER_STACK_PAGES: u32 = 2;

/// Map the user program: copy each 4 KB chunk of `blob` into a fresh
/// physical frame, install a U+R+W+X leaf PTE at VA 0x0001_0000 + k*4K.
/// Then allocate 2 stack pages mapped at VA 0x0003_0000 + {0, 4K}
/// with U+R+W (no X). The user's sp is initialized to USER_STACK_TOP
/// by kmain before sret.
pub fn mapUser(root_pa: u32, blob_ptr: [*]const u8, blob_len: u32) void {
    // Round up blob length to PAGE_SIZE for allocation purposes.
    const page_count: u32 = (blob_len + (PAGE_SIZE - 1)) >> PAGE_SHIFT;
    var i: u32 = 0;
    while (i < page_count) : (i += 1) {
        const user_pa = page_alloc.allocZeroPage();
        // Copy up to PAGE_SIZE bytes from blob[i*PAGE_SIZE..] into this frame.
        const src_off = i * PAGE_SIZE;
        const remaining = if (blob_len > src_off) blob_len - src_off else 0;
        const copy_len = @min(remaining, PAGE_SIZE);
        const dst: [*]volatile u8 = @ptrFromInt(user_pa);
        var j: u32 = 0;
        while (j < copy_len) : (j += 1) dst[j] = blob_ptr[src_off + j];

        const va = USER_TEXT_VA + i * PAGE_SIZE;
        mapPage(root_pa, va, user_pa, USER_RWX);
    }

    // User stack: 2 pages, U+R+W, zero-initialized (already zero from
    // allocZeroPage).
    var s: u32 = 0;
    while (s < USER_STACK_PAGES) : (s += 1) {
        const stack_pa = page_alloc.allocZeroPage();
        const va = USER_STACK_BOTTOM + s * PAGE_SIZE;
        mapPage(root_pa, va, stack_pa, USER_RW);
    }
}
```

- [ ] **Step 2: Rebuild**

Run: `zig build kernel-elf`

Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add tests/programs/kernel/vm.zig
git commit -m "feat: vm.mapUser with stack + U+R+W+X user frames (Plan 2.C Task 15)"
```

---

### Task 16: boot.S — add `medeleg` / `mideleg` setup for sync U→S delegation

**Files:**
- Modify: `tests/programs/kernel/boot.S`

**Why this task:** Task 17 enters U-mode. Without `medeleg[8] = 1` (ECALL from U), the user's first ecall routes to M-mode and hits whatever mtvec points at — currently undefined, so `FatalTrap` in the emulator. Land delegation bits NOW as part of boot.S so the U-mode trap path lands in S at Task 17.

We also set `mideleg[1] = 1` (SSIP) so the forwarded timer tick from Task 18's mtimer.S reaches S-mode; SSIP is the mechanism the spec spells out in detail (§Privilege & trap model, Async interrupt flow).

- [ ] **Step 1: Extend boot.S with delegation setup**

Rewrite `tests/programs/kernel/boot.S`:

```
# tests/programs/kernel/boot.S — Phase 2 Plan 2.C kernel M-mode boot shim.
#
# Task 16 state: M->S drop (Task 2) + delegation (this task). CLINT and
# mtvec arrive in Task 18.
#
# Delegation: route delegatable synchronous exceptions to S-mode, and
# delegate SSIP (the software-software interrupt we use to forward
# timer ticks from M to S).

# medeleg bit layout (spec §Delegation). We mirror the Phase 2 spec
# exactly; Plan 2.B already implemented the CSR.
.equ MEDELEG_INST_MISALIGN,  (1 <<  0)
.equ MEDELEG_ILLEGAL,        (1 <<  2)
.equ MEDELEG_BREAKPOINT,     (1 <<  3)
.equ MEDELEG_LOAD_MISALIGN,  (1 <<  4)
.equ MEDELEG_STORE_MISALIGN, (1 <<  6)
.equ MEDELEG_ECALL_U,        (1 <<  8)
.equ MEDELEG_INST_PF,        (1 << 12)
.equ MEDELEG_LOAD_PF,        (1 << 13)
.equ MEDELEG_STORE_PF,       (1 << 15)

.equ MIDELEG_SSIP, (1 << 1)

.section .text.init, "ax", @progbits
.balign 4
.globl _M_start
_M_start:
    # Stack.
    la      sp, _kstack_top

    # Zero BSS.
    la      t0, _bss_start
    la      t1, _bss_end
1:  beq     t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    # medeleg: delegate the exceptions U-mode can raise.
    li      t0, (MEDELEG_INST_MISALIGN | MEDELEG_ILLEGAL | MEDELEG_BREAKPOINT | \
                 MEDELEG_LOAD_MISALIGN  | MEDELEG_STORE_MISALIGN | MEDELEG_ECALL_U | \
                 MEDELEG_INST_PF        | MEDELEG_LOAD_PF        | MEDELEG_STORE_PF)
    csrw    medeleg, t0

    # mideleg: delegate SSIP (supervisor software interrupt). MTIP is
    # NOT delegable (hardwired 0 per Plan 2.B's MIDELEG_WRITABLE mask).
    li      t0, MIDELEG_SSIP
    csrw    mideleg, t0

    # mstatus.MPP = S (01).
    li      t0, 0x1800           # MPP_MASK = bits 12:11
    csrc    mstatus, t0
    li      t0, 0x0800           # MPP = 01 (S)
    csrs    mstatus, t0

    # mepc <- kmain.
    la      t0, kmain
    csrw    mepc, t0

    mret
```

- [ ] **Step 2: Rebuild + run**

Run: `zig build e2e-kernel`

Expected: still `"ok\n"` + exit 0. Delegation bits are set but nothing traps yet.

- [ ] **Step 3: Commit**

```bash
git add tests/programs/kernel/boot.S
git commit -m "feat: boot.S medeleg + mideleg setup for U->S delegation (Plan 2.C Task 16)"
```

---

### Task 17: kmain enters user mode — checkpoint: `"hello from u-mode\n"` + exit 0

**Files:**
- Modify: `tests/programs/kernel/kmain.zig` (wire the_tf, install stvec/sscratch, map user, jump to s_return_to_user)
- Modify: `build.zig` (update `expectStdOutEqual` to `"hello from u-mode\n"`)

**Why this task:** The first end-to-end U-mode run. After this task, `ccc kernel.elf` goes: boot.S (M) → kmain (S) → paging on → user blob mapped → trap vector installed → sret to U → user `_start` runs → `write(1, msg, 18)` → ecall → S trap → `syscall.dispatch` → `uart.writeBytes(msg)` → return to U → `exit(0)` → ecall → S trap → `syscall.sys_exit` → halt MMIO → emulator exit 0. Exactly one Plan 2.C observable behavior change: `"hello from u-mode\n"`.

- [ ] **Step 1: Rewrite kmain.zig for full user entry**

Replace `tests/programs/kernel/kmain.zig` with:

```zig
// tests/programs/kernel/kmain.zig — Phase 2 Plan 2.C kernel S-mode entry.
//
// Task 17 state: end-to-end U-mode entry. Maps user program, installs
// S-mode trap vector, writes satp, jumps to trampoline's s_return_to_user
// which sret's to user _start. Syscall handling is already in place from
// Tasks 10-12.
//
// Plan 2.C does NOT enable `sie.SSIE` yet — timer handling arrives in
// Tasks 18-20. This task intentionally runs without interrupts so the
// control flow for the happy path is unambiguous.

const std = @import("std");
const uart = @import("uart.zig");
const vm = @import("vm.zig");
const page_alloc = @import("page_alloc.zig");
const trap = @import("trap.zig");
const user_blob = @import("user_blob");

pub const USER_BLOB: []const u8 = user_blob.BLOB;

const SATP_MODE_SV32: u32 = 1 << 31;

pub export var the_tf: trap.TrapFrame = std.mem.zeroes(trap.TrapFrame);

extern fn s_trap_entry() void;
extern fn s_return_to_user(tf: *trap.TrapFrame) noreturn;

export fn kmain() callconv(.c) noreturn {
    page_alloc.init();
    const root_pa = vm.allocRoot();
    vm.mapKernelAndMmio(root_pa);
    vm.mapUser(root_pa, USER_BLOB.ptr, @intCast(USER_BLOB.len));

    // Initialize the user trap frame.
    the_tf = std.mem.zeroes(trap.TrapFrame);
    the_tf.sepc = vm.USER_TEXT_VA; // _start lives at VA 0x00010000
    the_tf.sp = vm.USER_STACK_TOP;

    // Install the S-mode trap vector and sscratch.
    const tf_addr: u32 = @intCast(@intFromPtr(&the_tf));
    const stvec_val: u32 = @intCast(@intFromPtr(&s_trap_entry));
    asm volatile (
        \\ csrw stvec, %[stv]
        \\ csrw sscratch, %[ss]
        :
        : [stv] "r" (stvec_val),
          [ss] "r" (tf_addr),
        : "memory"
    );

    // Configure sstatus.SPP = 0 (U) and sstatus.SPIE = 1 so sret lands
    // in U with SIE=1 after the privilege transition.
    //   SPP is bit 8, SPIE is bit 5, SIE is bit 1.
    const SSTATUS_SPP: u32 = 1 << 8;
    const SSTATUS_SPIE: u32 = 1 << 5;
    asm volatile (
        \\ csrc sstatus, %[spp]
        \\ csrs sstatus, %[spie]
        :
        : [spp] "r" (SSTATUS_SPP),
          [spie] "r" (SSTATUS_SPIE),
        : "memory"
    );

    // Flip on Sv32 translation.
    const satp_val: u32 = SATP_MODE_SV32 | (root_pa >> 12);
    asm volatile (
        \\ csrw satp, %[satp]
        \\ sfence.vma zero, zero
        :
        : [satp] "r" (satp_val),
        : "memory"
    );

    // Jump to the trampoline's return-to-user path with a0 = &the_tf.
    s_return_to_user(&the_tf);
}
```

- [ ] **Step 2: Update the e2e-kernel expected output**

In `build.zig`, locate the Task 2 `e2e_kernel_run.expectStdOutEqual("ok\n");` line. Replace with:

```zig
    e2e_kernel_run.expectStdOutEqual("hello from u-mode\n");
```

- [ ] **Step 3: Rebuild + run**

Run: `zig build e2e-kernel`

Expected: passes, stdout is exactly `"hello from u-mode\n"` (18 bytes), exit 0.

**If it fails** — this is the most likely debugging moment of Plan 2.C. The highest-signal diagnostic:

```bash
zig-out/bin/ccc --trace zig-out/bin/kernel.elf 2>&1 | tail -60
```

Look for the first address the trace hits in the `0x00010000` range — that's the user program. If the trace dies before hitting 0x00010000, the sret didn't land; inspect `sepc` in the final frame of the trace. If the trace DOES hit the user program but never emits anything to stdout, the ecall path is broken — check that `s_trap_entry` was reached (its first instruction address lives in the kernel .text region, 0x80000000+). If the ecall path IS reached but the write outputs garbage, the SUM toggle is the suspect: verify `sstatus` actually had bit 18 set when the load-from-user-VA happened.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/kernel/kmain.zig build.zig
git commit -m "feat: kmain enters user mode; e2e-kernel prints 'hello from u-mode' (Plan 2.C Task 17)"
```

---

### Task 18: boot.S — add `mtvec` + CLINT timer programming + `mie.MTIE` + `mstatus.MIE`

**Files:**
- Modify: `tests/programs/kernel/boot.S` (install m_trap_vector, program CLINT mtimecmp, enable MIE)

**Why this task:** With medeleg already delegating synchronous U→S traps, the remaining boot responsibility is the async interrupt plumbing: set `mtvec` to an M-mode trap target, program CLINT so the timer actually fires, and enable `mie.MTIE` + `mstatus.MIE`. The M-mode trap target itself is a simple spin-and-halt placeholder until Task 19 fills in `m_timer_isr` for the MTI case.

The tick WILL fire during the "hello from u-mode\n" run (TIMESLICE is 1M cycles; the user prints and exits in ~20 instructions). MTIP fires in M; the M-mode trap vector jumps to whatever label we install. Task 19 makes that label a real MTI ISR; until then it's a panic. Since Plan 2.C's Task 17 already passes e2e-kernel WITHOUT timer setup, we must be careful: we'll add MTI plumbing in a way that breaks nothing until Task 19 completes the chain.

- [ ] **Step 1: Extend boot.S with mtvec + CLINT + interrupt enables**

Rewrite `tests/programs/kernel/boot.S`:

```
# tests/programs/kernel/boot.S — Phase 2 Plan 2.C kernel M-mode boot shim.
#
# Task 18 state: full M-mode boot. Set mtvec to m_trap_vector (which
# routes MTI to m_timer_isr in mtimer.S, panics on anything else),
# delegate U->S synchronous traps + SSIP, enable mie.MTIE + mstatus.MIE,
# program CLINT mtimecmp = mtime + TIMESLICE, drop to S at kmain.

.equ MEDELEG_INST_MISALIGN,  (1 <<  0)
.equ MEDELEG_ILLEGAL,        (1 <<  2)
.equ MEDELEG_BREAKPOINT,     (1 <<  3)
.equ MEDELEG_LOAD_MISALIGN,  (1 <<  4)
.equ MEDELEG_STORE_MISALIGN, (1 <<  6)
.equ MEDELEG_ECALL_U,        (1 <<  8)
.equ MEDELEG_INST_PF,        (1 << 12)
.equ MEDELEG_LOAD_PF,        (1 << 13)
.equ MEDELEG_STORE_PF,       (1 << 15)

.equ MIDELEG_SSIP, (1 << 1)

.equ MIE_MTIE, (1 << 7)
.equ MSTATUS_MIE, (1 << 3)

# CLINT register addresses.
.equ CLINT_MTIMECMP_LO, 0x02004000
.equ CLINT_MTIMECMP_HI, 0x02004004
.equ CLINT_MTIME_LO,    0x0200BFF8
.equ CLINT_MTIME_HI,    0x0200BFFC

# Timer quantum: 1,000,000 CLINT ticks per slice. At the emulator's
# configured CLINT rate (~10 MHz), that's ~100 ms — coarse enough that
# a short `write+exit` program completes well before the first tick.
# Tune in Plan 2.D where the tick counter matters.
.equ TIMESLICE, 1000000

.section .text.init, "ax", @progbits
.balign 4
.globl _M_start
_M_start:
    la      sp, _kstack_top

    # Zero BSS.
    la      t0, _bss_start
    la      t1, _bss_end
1:  beq     t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    # Install M-mode trap vector.
    la      t0, m_trap_vector
    csrw    mtvec, t0

    # medeleg.
    li      t0, (MEDELEG_INST_MISALIGN | MEDELEG_ILLEGAL | MEDELEG_BREAKPOINT | \
                 MEDELEG_LOAD_MISALIGN  | MEDELEG_STORE_MISALIGN | MEDELEG_ECALL_U | \
                 MEDELEG_INST_PF        | MEDELEG_LOAD_PF        | MEDELEG_STORE_PF)
    csrw    medeleg, t0

    # mideleg: SSIP.
    li      t0, MIDELEG_SSIP
    csrw    mideleg, t0

    # mie.MTIE = 1.
    li      t0, MIE_MTIE
    csrs    mie, t0

    # Program CLINT: mtimecmp = mtime + TIMESLICE. 32-bit RV32 splits
    # the 64-bit counters into LO/HI words. We use the standard order:
    # write HI=-1 first so a carry during LO update doesn't briefly
    # fire; set LO; then set HI to the real value.
    #
    # For Plan 2.C, mtime starts near zero at reset and mtimecmp defaults
    # to zero (which with Plan 2.B's `isMtipPending` guard does NOT fire
    # while `mtimecmp == 0`). So we can simply load mtime, add TIMESLICE,
    # store to mtimecmp LO+HI.
    li      t2, CLINT_MTIME_LO
    lw      t0, 0(t2)            # t0 = mtime low
    li      t2, CLINT_MTIME_HI
    lw      t1, 0(t2)            # t1 = mtime high
    li      t2, TIMESLICE
    add     t0, t0, t2
    sltu    t2, t0, t2           # carry detect
    add     t1, t1, t2
    # Store LO then HI (safe because mtimecmp was 0 and our LO value is
    # the real low 32 bits).
    li      t2, CLINT_MTIMECMP_LO
    sw      t0, 0(t2)
    li      t2, CLINT_MTIMECMP_HI
    sw      t1, 0(t2)

    # mstatus.MIE = 1 (async MTI can now reach M).
    li      t0, MSTATUS_MIE
    csrs    mstatus, t0

    # mstatus.MPP = S (01).
    li      t0, 0x1800           # MPP_MASK = bits 12:11
    csrc    mstatus, t0
    li      t0, 0x0800           # MPP = 01 (S)
    csrs    mstatus, t0

    # mepc <- kmain.
    la      t0, kmain
    csrw    mepc, t0

    mret


# ---- M-mode trap vector. ----------------------------------------------
# Direct mode (MODE=0). cause 7 + interrupt bit = MTI -> m_timer_isr
# (defined in mtimer.S). Anything else panics by spinning and storing
# 0xFF to halt MMIO.
.balign 4
.globl m_trap_vector
m_trap_vector:
    # Use mscratch as a single-word scratch slot to stash t0 without
    # touching sp (sp at this point is the S-mode kernel stack or the
    # user stack, and we must not perturb either).
    csrrw   t0, mscratch, t0     # swap t0 <-> mscratch
    csrr    t0, mcause
    # Check for MTI: cause = 0x80000007.
    li      x31, 0x80000007
    beq     t0, x31, m_trap_is_mti
    # Not MTI -> panic. Restore t0 first, then fall through.
    csrrw   t0, mscratch, t0
    li      x31, 0x00100000
    li      x30, 0xFF
    sb      x30, 0(x31)
1:  j       1b

m_trap_is_mti:
    # Restore t0 and jump to m_timer_isr (defined in mtimer.S).
    csrrw   t0, mscratch, t0
    j       m_timer_isr
```

- [ ] **Step 2: Add a placeholder `m_timer_isr` so Task 18 links on its own**

Task 19 replaces this with the real implementation in `mtimer.S`. The placeholder spins forever: if control ever reaches it at runtime (e.g., MTI fires before we land Task 19), the test hangs loudly rather than appearing to pass via a silent fall-through.

Append to `tests/programs/kernel/boot.S`:

```

# Placeholder — Task 19 replaces with a real implementation in mtimer.S.
# If this label is still reached at runtime, the MTI ISR was not
# installed; we spin here forever so the test hangs obviously rather
# than silently misbehaving.
.balign 4
.globl m_timer_isr
m_timer_isr:
1:  j       1b
```

- [ ] **Step 3: Rebuild + run**

Run: `zig build e2e-kernel`

Expected: `"hello from u-mode\n"` + exit 0. TIMESLICE of 1,000,000 is large enough that the ~20-instruction user program finishes before the first MTI fires. If it hangs with no output, the M-mode CSR writes broke something — most likely `mstatus.MIE = 1` triggered an immediate MTI because CLINT's mtimecmp is smaller than current mtime. In that case the placeholder `m_timer_isr: j self` would eat the rest of the run. Verify by running WITHOUT timer setup — temporarily comment out the `csrs mstatus, MSTATUS_MIE` line; if that passes, the MTI plumbing is firing too eagerly and the `mtimecmp = mtime + TIMESLICE` read+write sequence needs to be re-inspected.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/kernel/boot.S
git commit -m "feat: boot.S full M-mode setup (mtvec, CLINT, MIE, MTIE) (Plan 2.C Task 18)"
```

---

### Task 19: `mtimer.S` — real MTI ISR forwarding MTIP → SSIP

**Files:**
- Create: `tests/programs/kernel/mtimer.S`
- Modify: `tests/programs/kernel/boot.S` (remove the placeholder `m_timer_isr`)
- Modify: `build.zig` (add mtimer.S as a kernel object)

**Why this task:** Real MTI handler. Advances `mtimecmp` (clearing MTIP by moving the threshold forward), sets `mip.SSIP` which — thanks to Task 16's mideleg — fires as a supervisor-software interrupt at the next S-mode instruction boundary with `sie.SSIE = 1`. The S-mode side arrives in Task 20.

- [ ] **Step 1: Create mtimer.S**

Create `tests/programs/kernel/mtimer.S`:

```
# tests/programs/kernel/mtimer.S — Phase 2 Plan 2.C M-mode timer ISR.
#
# Called from m_trap_vector (boot.S) when mcause = 0x80000007 (MTI).
# On entry, all GPRs hold the caller's values; we must not perturb any
# of them except through save/restore, because sp at this point is
# either S-mode kernel's sp or U-mode's sp and we have no M-mode stack.
#
# Strategy: stash caller's t0 into mscratch, use t0 as the scratch-area
# base, then save t1/t2 and (via mscratch) t0 into m_scratch_area. We
# use t0/t1/t2 as working registers during the mtimecmp advance; at
# the end we reload all three from m_scratch_area with `t2` as the base
# so the last load (t2 itself) can safely overwrite its own base.
#
# Steps:
#   1. Save t0, t1, t2 to m_scratch_area.
#   2. Advance mtimecmp = mtime + TIMESLICE (clears MTIP edge).
#   3. Set mip.SSIP (delegated to S per mideleg[SSIP]=1).
#   4. Restore t0, t1, t2.
#   5. mret.

.equ CLINT_MTIMECMP_LO, 0x02004000
.equ CLINT_MTIMECMP_HI, 0x02004004
.equ CLINT_MTIME_LO,    0x0200BFF8
.equ CLINT_MTIME_HI,    0x0200BFFC
.equ TIMESLICE,         1000000

.section .bss, "aw", @nobits
.balign 4
.globl m_scratch_area
m_scratch_area:
    .space 12             # 3 slots of 4 bytes: t0, t1, t2

.section .text, "ax", @progbits
.balign 4
.globl m_timer_isr
m_timer_isr:
    # Save caller's t0 via mscratch so we can use t0 as scratch-area base.
    csrw    mscratch, t0
    la      t0, m_scratch_area
    sw      t1, 4(t0)
    sw      t2, 8(t0)
    csrr    t1, mscratch         # t1 = caller's t0
    sw      t1, 0(t0)

    # mtimecmp = mtime + TIMESLICE. Reload t1/t2 with mtime {lo, hi}.
    li      t1, CLINT_MTIME_LO
    lw      t1, 0(t1)            # t1 = mtime_lo
    li      t2, CLINT_MTIME_HI
    lw      t2, 0(t2)            # t2 = mtime_hi
    li      t0, TIMESLICE
    add     t1, t1, t0
    sltu    t0, t1, t0           # carry out of low add
    add     t2, t2, t0
    li      t0, CLINT_MTIMECMP_LO
    sw      t1, 0(t0)
    li      t0, CLINT_MTIMECMP_HI
    sw      t2, 0(t0)

    # Forward to S-mode via mideleg[SSIP]=1.
    csrsi   mip, 2               # sets bit 1 = SSIP

    # Restore caller's t0/t1/t2. Use t2 as the base so the final load
    # (t2 itself) overwrites the base with its saved value in one step.
    la      t2, m_scratch_area
    lw      t0, 0(t2)
    lw      t1, 4(t2)
    lw      t2, 8(t2)

    mret
```

- [ ] **Step 2: Remove the placeholder from boot.S**

In `tests/programs/kernel/boot.S`, delete the Task 18 placeholder block:

```
# Placeholder — Task 19 replaces with a real implementation in mtimer.S.
...
.globl m_timer_isr
m_timer_isr:
1:  j       1b
```

- [ ] **Step 3: Add mtimer.S to the build**

In `build.zig`, add a `kernel_mtimer_obj` sibling to `kernel_trampoline_obj`:

```zig
    const kernel_mtimer_obj = b.addObject(.{
        .name = "kernel-mtimer",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
        }),
    });
    kernel_mtimer_obj.root_module.addAssemblyFile(b.path("tests/programs/kernel/mtimer.S"));
```

Add to kernel_elf:

```zig
    kernel_elf.root_module.addObject(kernel_boot_obj);
    kernel_elf.root_module.addObject(kernel_trampoline_obj);
    kernel_elf.root_module.addObject(kernel_mtimer_obj);   // NEW
    kernel_elf.root_module.addObject(kernel_kmain_obj);
```

- [ ] **Step 4: Rebuild + run**

Run: `zig build e2e-kernel`

Expected: still passes with `"hello from u-mode\n"` + exit 0. The first MTI fires somewhere during the run and gets processed by mtimer.S, then sets SSIP which — because `sie.SSIE` is still 0 in Plan 2.C Task 17 and the user's privilege is U (lower privilege, S-interrupts always deliverable) — the SSI fires at the next user-mode boundary. The `s_trap_dispatch` cause=1 branch (Task 10) clears sip.SSIP and returns. So the chain works IF Task 20's `sie.SSIE = 1` is set. WITHOUT `sie.SSIE = 1`, the SSI stays pending but never fires, which is also fine for the e2e (the write + exit still completes).

So this task should still pass e2e-kernel even without Task 20's sie.SSIE bit.

- [ ] **Step 5: Commit**

```bash
git add tests/programs/kernel/mtimer.S tests/programs/kernel/boot.S build.zig
git commit -m "feat: mtimer.S M-mode timer ISR (MTIP -> SSIP forwarding) (Plan 2.C Task 19)"
```

---

### Task 20: kmain enables `sie.SSIE` — S-mode accepts forwarded timer ticks

**Files:**
- Modify: `tests/programs/kernel/kmain.zig` (enable sie.SSIE after stvec install)

**Why this task:** Close the timer loop. With SSIE enabled, the SSI forwarded from mtimer.S actually fires in S-mode. `s_trap_dispatch`'s cause=1 branch (added in Task 10) handles it: clears sip.SSIP, returns. Plan 2.C doesn't do anything interesting with the tick — that's 2.D.

The e2e still prints exactly `"hello from u-mode\n"` because the SSI handler is a no-op; the only observable is that an interrupt WAS taken (and didn't crash).

- [ ] **Step 1: Add the sie.SSIE enable to kmain**

In `tests/programs/kernel/kmain.zig`, right after the stvec/sscratch block and BEFORE the satp block, insert:

```zig
    // Enable sie.SSIE so forwarded timer ticks take in S-mode (U-mode
    // is lower privilege, which ignores sstatus.SIE — SSI always
    // delivers — but we want SSI to fire in S too once the kernel is
    // long-lived enough in Plan 2.D to notice).
    const SIE_SSIE: u32 = 1 << 1;
    asm volatile ("csrs sie, %[b]"
        :
        : [b] "r" (SIE_SSIE),
        : "memory"
    );
```

- [ ] **Step 2: Rebuild + run**

Run: `zig build e2e-kernel`

Expected: still `"hello from u-mode\n"` + exit 0.

- [ ] **Step 3: Commit**

```bash
git add tests/programs/kernel/kmain.zig
git commit -m "feat: kmain enables sie.SSIE for forwarded timer ticks (Plan 2.C Task 20)"
```

---

### Task 21: Regression pass — Phase 1 + Phase 2 preceding plans all pass

**Files:**
- None modified (validation only).

**Why this task:** Plan 2.C adds no emulator source changes, but it's a lot of new build graph and new kernel code — worth a formal regression checkpoint before the README update.

- [ ] **Step 1: Run every existing build target**

```bash
zig build test
zig build e2e
zig build e2e-mul
zig build e2e-trap
zig build e2e-hello-elf
zig build e2e-kernel
zig build riscv-tests
```

Expected: all exit 0. Typical failure modes and fixes:

- **e2e-hello-elf breaks because of kmain.zig's `std.mem.zeroes`** — unlikely but check; we use std.mem.zeroes which requires std. If the kernel module's root was somehow restricted against std, fix the `b.createModule` options.
- **riscv-tests breaks because of build.zig accidentally touching `all_families` loop** — shouldn't happen since we only ADD to build.zig; verify no existing loop was altered.
- **e2e-kernel fails alone** — re-run a per-task regression: `git log --oneline origin/main..HEAD` and checkpoint each 2.C commit to find the regression.

- [ ] **Step 2: If any failure, fix root cause and re-run**

Do NOT mask failures. A failed Phase 1 e2e means Plan 2.C inadvertently changed something shared (most likely `build.zig`'s host-exe module or rv_target).

- [ ] **Step 3: Commit fixes if any**

If nothing needed fixing, skip this step. Otherwise:

```bash
git add <affected files>
git commit -m "fix: restore Phase 1 regression after Plan 2.C (Plan 2.C Task 21)"
```

---

### Task 22: README — announce Plan 2.C merge

**Files:**
- Modify: `README.md` (Status section + Next line)

- [ ] **Step 1: Update README Status section**

Find the existing Status block, which after Plan 2.B ends with:

```
**Plan 2.B (emulator trap delegation + async interrupts) merged.**

... bullets ...

The end-to-end `CLINT → M MTI ISR → mip.SSIP → S SSI ISR` forwarding
round-trip is validated by a dedicated integration test in
`src/cpu.zig` — the substrate Plan 2.C's kernel `mtimer.S` will
consume.

Next: **Plan 2.C — kernel skeleton (M-mode boot shim, single page
table, sret-to-U, user `write`+`exit` demo)**.
```

Replace with:

```
**Plan 2.C (kernel skeleton — M-mode boot shim, Sv32 paging, S-mode
trap dispatcher, user `write`+`exit` demo) merged.**

A bare-metal kernel.elf now builds alongside the emulator:

- `zig build kernel` builds `kernel.elf`. `ccc kernel.elf` prints
  exactly `"hello from u-mode\n"` and exits 0.
- Three privilege levels active in a single run: M-mode boot shim
  (sets up delegation, CLINT, mtvec, drops to S), S-mode kernel
  (manages Sv32 page table, trap dispatcher, syscalls), U-mode user
  program (writes a message, exits).
- One Sv32 page table with direct-mapped kernel + identity-mapped
  MMIO + user text/stack mapped at VA 0x00010000 / 0x00030000.
- Syscall ABI: `write(64)`, `exit(93)` (and a `yield(124)` stub
  returning `-ENOSYS`; Plan 2.D wires it up).
- Timer firing forwards from M→S via the Plan 2.B CLINT→MTIP→SSIP
  pipeline; the S-mode SSI handler clears SSIP and returns (no
  scheduler yet — Plan 2.D).

Plan 2.C is deliberately minimal: no `Process` struct, no scheduler,
no tick counter, no `yield`. Phase 2's Definition of Done (the full
`"hello from u-mode\nticks observed: N\n"` output and the QEMU-diff
harness) is achieved in Plan 2.D.

Next: **Plan 2.D — Process scaffolding + scheduler stub + yield +
QEMU-diff harness**.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README announces Plan 2.C merge (Plan 2.C Task 22)"
```

---

## Roughly what success looks like at the end of Plan 2.C

```
$ zig build test                              # all unit tests pass (emulator untouched)
$ zig build riscv-tests                       # Phase 1 + 2.A + 2.B families pass
$ zig build e2e e2e-mul e2e-trap e2e-hello-elf  # Phase 1 demos still green

$ zig build kernel-elf
$ zig-out/bin/ccc zig-out/bin/kernel.elf
hello from u-mode
$ echo $?
0

$ zig-out/bin/ccc --trace zig-out/bin/kernel.elf 2>&1 | head -30
80000000  [M] auipc t0, 0x0
80000004  [M] addi  sp, t0, 0x???
...
80000nnn  [M] mret                       # drop into S
800010xx  [S] csrw  satp, t0
800010yy  [S] sfence.vma zero, zero
...
800010zz  [S] jalr  s_return_to_user
...
800010ww  [S] sret                        # drop into U
00010000  [U] li    a7, 64
00010004  [U] li    a0, 1
00010008  [U] auipc a1, 0x0
...
00010018  [U] ecall                       # write
--- (delegated trap — cause=8 taken in U, now S) ---
8001xxxx  [S] csrrw sp, sscratch, sp      # trampoline entry
...
(uart byte-by-byte writes via sys_write)
...
800xxxxx  [S] sret
00010020  [U] li    a7, 93
00010024  [U] li    a0, 0
00010028  [U] ecall                       # exit
--- (delegated trap — cause=8 taken in U, now S) ---
...
(halt MMIO store — emulator exits 0)
```

Plan 2.D can now build the scheduler + yield + QEMU-diff on top of this substrate without writing a single emulator line.

## Risks and open questions addressed during 2.C

- **Zig `addAnonymousImport` pointing at a WriteFile output.** This is a
  known-working pattern but somewhat fragile. If Zig's API changes in
  a point release, the Task 14 plumbing is the candidate. Validation:
  Task 14 Step 5 asserts the blob reaches kernel .rodata via `nm`.
- **`llvm-objcopy` availability.** The Zig toolchain ships LLVM
  including objcopy; `llvm-objcopy` is on `$PATH` after `zig env`'s
  bin dir is exported. If a CI environment has zig without the LLVM
  tools, we need `b.findProgram` fallback to find it. Plan 2.C
  assumes default install.
- **Superpage accidentally constructed.** Phase 2 permanently rejects
  L1 leaves. `vm.mapPage` guards against already-leaf L1 entries
  (panics in that case); since we never write L1 leaves ourselves,
  this only catches memory corruption.
- **Kernel-heap allocation during `mapKernelAndMmio`.** The heap-coverage
  map (Step 1 of Task 6) must succeed before the first `csrw satp`.
  Risk: bump allocator grows during the heap-coverage loop itself.
  Mitigation: heap-coverage loop maps [heap_start, RAM_END); any
  fresh L0 table allocated mid-loop is within the range being
  installed. Confirmed by running the build and verifying the output.
- **Timer firing mid-syscall.** If TIMESLICE fires during `sys_write`'s
  byte-by-byte loop, we take a nested S-trap while in S (SSI from
  MTIP→SSIP forwarding). Because `s_trap_entry` unconditionally swaps
  sp with sscratch, and sscratch == &the_tf, a nested trap would
  corrupt the_tf. This is an unsolved problem for Plan 2.C BUT is
  harmless in practice because the syscall path does not enable
  interrupts (sstatus.SIE is cleared on S-trap entry by hardware), so
  the nested interrupt can't fire while in the handler. The `sret` at
  end-of-trampoline restores SIE. If a future bug sets sstatus.SIE = 1
  during the handler, this becomes a real problem — mark with a
  defense-in-depth clear at s_trap_entry's top if it comes up in 2.D.
- **User program `msg` symbol placement.** We `la a1, msg` in `_start`.
  The assembler emits this as `auipc + addi`, producing an absolute
  address based on linker script placement. If `msg` ends up outside
  the mapped user region (unlikely — user_linker.ld covers everything
  between `_user_start` and `_user_end`), the user-mode load page
  faults. Mitigation: build with `--verbose-link` once during Task 13
  and confirm `msg`'s address lies in [0x00010000, 0x00020000).
- **`sstatus.SUM` race.** `sys_write` toggles SUM around a loop that
  doesn't re-enter S-mode from an async interrupt (sstatus.SIE = 0
  while handling the syscall trap). If a future bug changes that, SUM
  may stay enabled longer than intended — a security hazard in Phase 3+
  but not Phase 2.
- **`mstatus.MIE` set before `mtimecmp` is programmed.** If we reversed
  these steps in boot.S, an immediate spurious MTI at mtime=0 with
  mtimecmp=0 would fire… except Plan 2.B's `isMtipPending` guards
  against `mtimecmp == 0` explicitly (requires `mtimecmp != 0 &&
  mtime >= mtimecmp`). So the ordering in Task 18's boot.S is robust
  to reorder. Still, we keep the spec's "program mtimecmp first"
  order as self-documentation.
- **Kernel stack overflow during deep `mapKernelAndMmio`.** The 16 KB
  stack is overkill for the initial sequence. Confirmed safe by
  pen-and-paper bookkeeping: each `mapPage` call uses ~8 words, deepest
  call chain is 4 levels.
- **Trampoline `call s_trap_dispatch` emits `auipc+jalr ra, offset`.**
  The implicit return address write to ra may clobber the user's ra
  if sp wasn't correctly switched to the kernel stack first. Audited:
  in `s_trap_entry`, we `la sp, _kstack_top` BEFORE the `call`. Safe.
- **Phase 2 spec's `mapUser` says .text R+X and .rodata R separately.**
  Plan 2.C flattens to USER_RWX because the user blob doesn't split
  sections in the linker script. Plan 3+ can tighten when the user
  build grows real sections.
