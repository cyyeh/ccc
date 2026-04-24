# Phase 2 Plan D — Process scaffolding + scheduler stub + yield + ticks observed (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Tasks have strict sequential dependencies — do not dispatch in parallel.

**Goal:** Finish Phase 2 by landing the `Process` struct, a single-process scheduler stub, `sys_yield`, a timer-driven tick counter, and the final `"hello from u-mode\nticks observed: N\n"` output. At the end of Plan 2.D, `ccc kernel.elf` hits the Phase 2 §Definition of Done verbatim (N is a positive integer dependent on run time), the emulator passes `rv32si-p-*` (already green from 2.A/2.B), `--trace` shows privilege-column `[M]`/`[S]`/`[U]` transitions with interrupt markers (also already green), and a `scripts/qemu-diff-kernel.sh` debug aid is available for future instruction-level divergence hunts.

**Architecture:** The `the_tf` global from 2.C is subsumed into a new `Process` struct whose first field is the 128-byte `TrapFrame` (so `&the_process == &the_process.tf` and `trampoline.S` only needs a symbol rename — no offset arithmetic). A new `proc.zig` owns the struct + `the_process` singleton. A new `sched.zig` owns two 1-line stubs: `schedule()` returns `&the_process`; `context_switch_to(p)` writes `satp`, issues `sfence.vma zero, zero`, then returns (the trampoline does the register restore). The S-mode trap dispatcher in `trap.zig` grows two branches: on the forwarded timer tick (SSI, `scause=0x80000001`) we clear `sip.SSIP`, increment `the_process.ticks_observed`, and call `sched.schedule()`; on ECALL with `a7=124` we call `sched.schedule()` and return 0 (advancing `sepc` by 4 is already done pre-dispatch). `sys_exit` prints `"ticks observed: N\n"` via `kprintf` before writing halt MMIO. The user program gains a `yield()` between `write` and `exit` and a short busy-loop after `yield` to guarantee that at least one timer tick fires during U-mode execution. TIMESLICE is dropped from 1_000_000 to 10_000 CLINT ticks (≈ 1 ms at 10 MHz nominal) so ticks accumulate during the brief user lifetime. The e2e verifier switches from `expectStdOutEqual` (which can't express a variable N) to a purpose-built host-side Zig tool that spawns `ccc kernel.elf`, captures stdout, and asserts the regex-equivalent of `"hello from u-mode\nticks observed: (\d+)\n"` with N > 0 and exit code 0. `scripts/qemu-diff-kernel.sh` is a thin wrapper over the existing `qemu-diff.sh` — it builds `kernel.elf` first, then invokes the Phase 1 trace diff harness; the existing canonicalization (first-occurrence-per-PC) handles kernel instruction loops fine. The emulator itself is not touched in 2.D.

**Tech Stack:** Zig 0.16.x (pinned in `build.zig.zon`, unchanged). `riscv32-freestanding` for kernel + user (same `rv_target` as 2.C). Host target (`b.graph.host`) for the new e2e verifier tool. No new external dependencies. No new system commands.

**Spec reference:** `docs/superpowers/specs/2026-04-24-phase2-bare-metal-kernel-design.md` — Plan 2.D covers spec §Definition of done (final output + N > 0 + emulator exit 0), §Kernel modules (`proc.zig`, `sched.zig` — the two files deferred from 2.C), §Kernel internals (`Process` struct verbatim, scheduler stub verbatim, `s_trap_dispatch` tick-counter branch + scheduler call, syscall ABI entry for `yield`), §Privilege & trap model (Async interrupt flow — the S-mode SSIP handler side of the MTI→SSIP hop now does real work), §Testing strategy (QEMU-diff harness extended for kernel ELF, kernel e2e regex match), and §Risks and open questions (TIMESLICE tuning). Plan 2.C built every other piece.

---

## Plan 2.D scope (final slice of Phase 2)

- **New kernel modules** under `tests/programs/kernel/`:
  - `proc.zig` — `State` enum (`Runnable`/`Running`/`Exited`), `Process` extern struct (first field `tf: TrapFrame`, followed by `satp`, `kstack_top`, `state`, `ticks_observed`, `exit_code`), and `pub export var the_process: Process = undefined` (single statically-allocated instance). Exports a `comptime` assertion that `@offsetOf(Process, "tf") == 0` so the trampoline's bare `la t0, the_process` stays valid if a refactor ever reorders fields.
  - `sched.zig` — `pub fn schedule() *proc.Process { return &proc.the_process; }` and `pub fn context_switch_to(p: *proc.Process) void { csrw satp, p.satp; sfence.vma zero, zero; }`. Called from the timer branch and the yield branch of `trap.zig` and from `kmain.zig`'s boot-to-user tail. The scheduler's "always re-picks the same process" semantics are by construction since `the_process` is the only instance.
- **Modified kernel modules**:
  - `kmain.zig` — `the_tf` is replaced by `proc.the_process`, whose first field is the trapframe. Boot sequence writes `the_process.satp`, `the_process.kstack_top`, `the_process.state = .Runnable`, zeroes counters, populates `tf.sepc`/`tf.sp`. The boot-to-user jump goes through `sched.context_switch_to(&proc.the_process)` + tail call to `s_return_to_user(&proc.the_process)`. All three CSR writes (`stvec`, `sscratch`, `sie.SSIE`, `sstatus.SPP`/`SPIE`) remain in the same order.
  - `trap.zig` — S-mode dispatcher gains two new behaviors. On supervisor-software interrupt (`is_interrupt=true, cause=1`), it clears `sip.SSIP`, does `proc.the_process.ticks_observed +%= 1`, then calls `sched.schedule()` (result ignored — there's only one process). On ECALL-from-U with `a7=124`, the syscall layer routes to a new `sys_yield` that calls `sched.schedule()` and returns 0. The Plan 2.C panic-on-anything-else branch is unchanged.
  - `syscall.zig` — `sys_yield(tf)` returns 0 after `_ = sched.schedule()`. `sys_exit(status)` prints `"ticks observed: {d}\n"` via `kprintf.print` before halting. The Plan 2.C `-ENOSYS` fallback for `a7=124` is replaced by the real handler.
  - `user/userprog.zig` — adds a second ecall `yield (124)` between the existing `write` and `exit` (matching the spec's canonical user program in §User program), plus a 100_000-iteration busy-loop between the yield and the exit. The busy-loop burns wall-clock time so at least one timer tick fires during U-mode execution regardless of host speed; it's 3 instructions (`addi`/`bnez`) inside a two-label pair, trivial to audit.
  - `boot.S` + `mtimer.S` — `TIMESLICE` dropped from `1000000` to `10000` (≈ 1 ms at 10 MHz nominal). The two files keep their independent `.equ` declaration per 2.C's "asm doesn't import headers" rule; a Task-level inspection step confirms they agree.
  - `trampoline.S` — three occurrences of the symbol `the_tf` renamed to `the_process`. The TF_* offsets don't move (they're offsets inside `TrapFrame`, not inside `Process`), so the save/restore instruction block is unchanged byte-for-byte.
- **New host tooling** under `tests/programs/kernel/`:
  - `verify_e2e.zig` — host-compiled Zig tool. Argv: `<ccc-binary> <kernel.elf>`. Spawns `ccc kernel.elf` with stdout captured, waits for termination, asserts: (a) exit code is 0, (b) stdout is exactly `"hello from u-mode\n"` followed by a single `"ticks observed: N\n"` line where `N` is a decimal integer > 0, (c) nothing after the final `\n`. Exits 0 on match, 1 with diagnostic on mismatch.
- **Modified scripts**:
  - `scripts/qemu-diff-kernel.sh` — new wrapper. Two-line body: `zig build kernel` then `exec scripts/qemu-diff.sh zig-out/bin/kernel.elf "$@"`. All heavy lifting lives in `qemu-diff.sh`; this exists for doc-discoverability and so `zig build qemu-diff-kernel` has something to invoke.
- **Build targets**:
  - `e2e-kernel` — REPLACED. Old: `addRunArtifact(exe).expectStdOutEqual("hello from u-mode\n")`. New: `addRunArtifact(verify_e2e)` with `addFileArg(exe.getEmittedBin())` and `addFileArg(kernel_elf.getEmittedBin())`.
  - `qemu-diff-kernel` — NEW. Wraps `scripts/qemu-diff-kernel.sh` via `b.addSystemCommand`. Not a CI gate (requires `qemu-system-riscv32`); devs invoke explicitly for trace divergences.
- **README.md** — Status section advances to announce Plan 2.D; Next line points to Phase 3.
- **Regression guarantee**: `zig build test && zig build e2e && zig build e2e-mul && zig build e2e-trap && zig build e2e-hello-elf && zig build riscv-tests && zig build e2e-kernel` all pass at the end of 2.D. The emulator is not modified.

### Not in Plan 2.D (deferred to Phase 3+)

- Multiple processes, process table, fork/exec, real scheduler selection — Phase 3.
- Filesystem, block device, PLIC, UART receive — Phase 3.
- Fault-safe `copy_from_user` — Phase 3. 2.D inherits 2.C's "panic on kernel-origin page fault" — harmless for the hardcoded user program where `msg` lives in the always-mapped user `.rodata` span.
- Proper ASID handling — `satp.ASID = 0` throughout; `PTE.G = 1` is still cosmetic.
- Kernel-side unit tests — kernel modules target `riscv32-freestanding` and are unreachable from the host-target test runner. Validation is via the `e2e-kernel` end-to-end run after every task group.
- Instruction-retire-based `mtime` — `mtime` is still wall-clock (see `src/devices/clint.zig`). The TIMESLICE tuning discussion below is what makes the test deterministic-enough despite this.

---

## File structure (final state at end of Plan 2.D)

```
ccc/
├── .gitignore                                   UNCHANGED
├── .gitmodules                                  UNCHANGED
├── build.zig                                    MODIFIED (verify_e2e host exe; e2e-kernel swaps to verifier; +qemu-diff-kernel step)
├── build.zig.zon                                UNCHANGED
├── README.md                                    MODIFIED (Status announces 2.D; Next points to Phase 3)
├── src/                                         UNCHANGED
├── scripts/
│   ├── qemu-diff.sh                             UNCHANGED
│   └── qemu-diff-kernel.sh                      NEW
└── tests/
    ├── fixtures/                                UNCHANGED
    ├── programs/
    │   ├── hello/                               UNCHANGED
    │   ├── mul_demo/                            UNCHANGED
    │   ├── trap_demo/                           UNCHANGED
    │   └── kernel/
    │       ├── linker.ld                        UNCHANGED
    │       ├── boot.S                           MODIFIED (TIMESLICE → 10000)
    │       ├── mtimer.S                         MODIFIED (TIMESLICE → 10000)
    │       ├── trampoline.S                     MODIFIED (the_tf → the_process, 3 sites)
    │       ├── kmain.zig                        MODIFIED (use proc.the_process; call sched.context_switch_to)
    │       ├── vm.zig                           UNCHANGED
    │       ├── page_alloc.zig                   UNCHANGED
    │       ├── trap.zig                         MODIFIED (timer tick counter + schedule call; remove "no scheduler" comment)
    │       ├── syscall.zig                      MODIFIED (sys_yield; sys_exit prints ticks)
    │       ├── uart.zig                         UNCHANGED
    │       ├── kprintf.zig                      UNCHANGED
    │       ├── proc.zig                         NEW
    │       ├── sched.zig                        NEW
    │       ├── verify_e2e.zig                   NEW
    │       └── user/
    │           ├── user_linker.ld               UNCHANGED
    │           └── userprog.zig                 MODIFIED (+yield ecall, +busy-loop, MSG constant unchanged)
    ├── riscv-tests/                             UNCHANGED (submodule)
    ├── riscv-tests-p.ld                         UNCHANGED
    ├── riscv-tests-s.ld                         UNCHANGED
    └── riscv-tests-shim/                        UNCHANGED
```

### Module responsibilities (new + modified in 2.D)

- **`tests/programs/kernel/proc.zig`** — Owns the `Process` struct and the `the_process` global. `Process` is an `extern struct` with `tf: trap.TrapFrame` as its FIRST field (the trampoline relies on this), followed by `satp: u32`, `kstack_top: u32`, `state: State`, `ticks_observed: u32`, `exit_code: u32`. `State` is `enum(u32) { Runnable, Running, Exited }` — `u32`-tagged for `extern struct` compatibility. `pub export var the_process: Process = undefined` so the symbol is visible to `trampoline.S`. One `comptime` assert: `@offsetOf(Process, "tf") == 0`.
- **`tests/programs/kernel/sched.zig`** — Two public functions. `schedule() *proc.Process` unconditionally returns `&proc.the_process` (Phase 2 has one process). `context_switch_to(p: *proc.Process) void` does `csrw satp, p.satp; sfence.vma zero, zero` via inline asm, then returns. The subsequent trampoline return-to-user path will do the register restore. Called from `kmain.zig`'s boot-to-user sequence and (eventually) from any point that needs to flip page tables — in Plan 2.D that's only the boot path. Note: the timer ISR and `sys_yield` call `schedule()` (to exercise the "pick" path) but NOT `context_switch_to` — since there's only one process and `satp` is already set to its value, the switch is a no-op; the trampoline's final `sret` still needs that `satp` intact, which it already is. Plan 3 will add `context_switch_to` to those paths when processes differ.
- **`tests/programs/kernel/kmain.zig`** — MODIFIED. Removes `pub export var the_tf`. Imports `proc` and `sched`. Boot sequence now:
  1. `page_alloc.init()`; `vm.allocRoot()`; `vm.mapKernelAndMmio(root)`; `vm.mapUser(root, USER_BLOB.ptr, len)`.
  2. Populate `proc.the_process`: zero it, then set `tf.sepc = USER_TEXT_VA`, `tf.sp = USER_STACK_TOP`, `satp = SATP_MODE_SV32 | (root_pa >> 12)`, `kstack_top = @intFromPtr(&_kstack_top)`, `state = .Runnable`. `ticks_observed` and `exit_code` start at 0 from the zero-init.
  3. `csrw stvec, &s_trap_entry`; `csrw sscratch, &proc.the_process`; `csrs sie, SIE_SSIE`; `csrc sstatus, SPP`; `csrs sstatus, SPIE`.
  4. `sched.context_switch_to(&proc.the_process)` — installs satp + sfence.vma.
  5. Tail call `s_return_to_user(&proc.the_process)`.
- **`tests/programs/kernel/trap.zig`** — MODIFIED. Imports `proc` and `sched`. The SSI branch (`is_interrupt and cause == 1`) now does: `clearSipSsip()`; `proc.the_process.ticks_observed +%= 1`; `_ = sched.schedule()`. The ECALL branch unchanged up to `syscall.dispatch(tf)`. Panic path unchanged.
- **`tests/programs/kernel/syscall.zig`** — MODIFIED. Imports `proc`, `sched`, `kprintf`. `sys_yield(tf)` calls `_ = sched.schedule()` and returns 0. `sys_exit(status)` prints `"ticks observed: {d}\n"` using `kprintf.print` with `proc.the_process.ticks_observed` as the sole argument, then writes `status & 0xFF` to halt MMIO and spins. `dispatch`'s switch: `64 → sys_write`, `93 → sys_exit`, `124 → sys_yield`, else → `-ENOSYS`.
- **`tests/programs/kernel/user/userprog.zig`** — MODIFIED. After the `ecall` at syscall 64, emit `li a7, 124; ecall` (yield). Then a busy-loop `li t0, 100000; 1: addi t0, t0, -1; bnez t0, 1b` (3 insns, ~300k cycles on a typical emulator, plenty of wall-clock time for 1 ms TIMESLICE to tick). Then `li a7, 93; li a0, 0; ecall` (exit) and `j 1b`. The `msg` array and `MSG` comptime constant are unchanged.
- **`tests/programs/kernel/verify_e2e.zig`** — NEW host tool. Spawns `argv[1]` with `argv[2]` as its single arg, pipes stdout, waits. Returns 0 iff: (a) child exited with status 0, (b) captured stdout starts with the exact prefix `"hello from u-mode\nticks observed: "`, (c) everything after the prefix up to the next `\n` parses as a u32 > 0, (d) the `\n` after the number is the final byte of stdout. Any mismatch writes a diagnostic to stderr and returns 1. Uses only `std.process`, `std.fmt`, and `std.heap.GeneralPurposeAllocator` — no external deps.
- **`scripts/qemu-diff-kernel.sh`** — NEW. Three-line executable: shebang, `zig build kernel`, `exec "$(dirname "$0")/qemu-diff.sh" zig-out/bin/kernel.elf "$@"`. All divergence analysis logic inherits from `qemu-diff.sh`. Comments note that the Phase 1 boot-ROM divergence applies here too (QEMU runs virt-machine bootstrap; we PC-jump to e_entry), so the first ~6 lines of trace are expected to differ.
- **`build.zig`** — MODIFIED. (1) Add `verify_e2e` as a host-target executable from `tests/programs/kernel/verify_e2e.zig`. (2) Rewrite `e2e_kernel_run` to be `b.addRunArtifact(verify_e2e)` with two `addFileArg` calls (ccc exe, kernel.elf). Expect exit code 0, drop `expectStdOutEqual`. (3) Add top-level step `qemu-diff-kernel` that `b.addSystemCommand`s `scripts/qemu-diff-kernel.sh`, depends on `install_kernel_elf`.

---

## Conventions used in this plan

- Kernel Zig targets `riscv32-freestanding`; `verify_e2e` targets `b.graph.host`.
- Kernel asm still uses GNU directives (`.section`, `.globl`, `.balign`, `.option nopic`) — same as 2.C.
- Every task ends with a `zig build kernel-elf` compile check. Tasks that change observable behavior end with `zig build e2e-kernel`. Phase 1 regression (`zig build test e2e e2e-mul e2e-trap e2e-hello-elf riscv-tests`) is deferred to the final Task 12 — changes in 2.D are kernel-tree-local and can't affect the emulator.
- Commit messages: Conventional Commits with a `(Plan 2.D Task N)` suffix.
- When a task modifies a Zig file that was fully written in 2.C, we show the FULL resulting file. Subagents may read tasks out of order; full snapshots avoid "where's the rest of this file" ambiguity. Asm changes are shown as diff-style context because their structure is stable across edits.
- All CSR addresses / PTE bit positions / register offsets in hand-written asm carry inline mnemonic comments — the comment is source-of-truth, the numeric word is the thing to double-check.
- Kernel code never `@panic`s directly; it calls `kprintf.panic` so halt MMIO + 0xFF gives a distinguishable "hit the panic path" signal to the test harness vs "exited normally with 0".

---

## Tasks

### Task 1: Introduce `proc.zig` with `Process` struct and `the_process` global

**Files:**
- Create: `tests/programs/kernel/proc.zig`

**Why this task first:** Every other file in the plan will import `proc`. Standing up the struct + singleton before any callers prevents the "fix-it-twice" pattern where Task 2 imports a struct Task 3 still has to rename. The `tf` field MUST be first so the trampoline's `la t0, the_process` is equivalent to `la t0, &the_process.tf`.

- [ ] **Step 1: Create `tests/programs/kernel/proc.zig`**

```zig
// tests/programs/kernel/proc.zig — Phase 2 Plan 2.D Process struct + singleton.
//
// Phase 2 has exactly one process; Phase 3 will add a process table. The
// struct layout is fixed here and referenced from:
//   - trampoline.S via `la t0, the_process` (relies on @offsetOf(Process,"tf")==0)
//   - kmain.zig during boot to populate fields
//   - trap.zig (the SSI handler increments ticks_observed)
//   - sched.zig (schedule returns &the_process)
//   - syscall.zig (sys_exit reads ticks_observed)
//
// `extern struct` is required for predictable field layout — Zig's default
// struct layout reorders fields for packing. `State` is tagged `u32` so
// the enum has a well-defined ABI size inside an extern struct.

const std = @import("std");
const trap = @import("trap.zig");

pub const State = enum(u32) {
    Runnable = 0,
    Running = 1,
    Exited = 2,
};

pub const Process = extern struct {
    tf: trap.TrapFrame,     // MUST be first — trampoline.S depends on offset 0.
    satp: u32,
    kstack_top: u32,
    state: State,
    ticks_observed: u32,
    exit_code: u32,
};

pub export var the_process: Process = undefined;

comptime {
    std.debug.assert(@offsetOf(Process, "tf") == 0);
    // TrapFrame is 128 bytes (29 GPRs * 4 + sepc * 4 = 32*4), so satp follows at offset 128.
    std.debug.assert(@offsetOf(Process, "satp") == trap.TF_SIZE);
}
```

- [ ] **Step 2: Compile-only check**

Run: `zig build kernel-elf`
Expected: succeeds. `the_process` is defined but not yet referenced by any other kernel file, so the linker keeps it in `.bss` as an unreferenced global export.

- [ ] **Step 3: Symbol-table sanity check**

Run: `llvm-nm zig-out/bin/kernel.elf | grep the_process`
Expected: one line showing `the_process` as a `.bss` symbol (e.g., `80XXXXXX B the_process`). Confirms the export made it to the final binary.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/kernel/proc.zig
git commit -m "feat(kernel): add Process struct and the_process singleton (Plan 2.D Task 1)"
```

---

### Task 2: Introduce `sched.zig` with `schedule` and `context_switch_to`

**Files:**
- Create: `tests/programs/kernel/sched.zig`

**Why:** Two tiny stub functions both callers (kmain boot, trap SSI handler, syscall yield) need. Landing them before their callers means Task 3+ can reference them without forward declarations.

- [ ] **Step 1: Create `tests/programs/kernel/sched.zig`**

```zig
// tests/programs/kernel/sched.zig — Phase 2 Plan 2.D scheduler stub.
//
// Phase 2 has one process, so schedule() is a constant function. The real
// purpose of this file is to exercise the "pick + switch" code path — the
// satp write and sfence.vma in context_switch_to — so Phase 3 can slot in
// a real picker by only changing schedule() and how context_switch_to is
// reached (e.g., only call it when the pick actually differs).
//
// Plan 2.D callers:
//   - kmain.zig: boot tail calls context_switch_to(&the_process) right
//     before jumping to s_return_to_user.
//   - trap.zig (SSI branch): calls schedule() after incrementing ticks.
//   - syscall.zig (sys_yield): calls schedule().
//
// Neither the SSI branch nor sys_yield call context_switch_to — with one
// process, satp is already correct. Adding a redundant switch there would
// make the hot path ~20 cycles slower for no benefit; Plan 3 will reinstate
// when the picker can return a new process.

const proc = @import("proc.zig");

pub fn schedule() *proc.Process {
    return &proc.the_process;
}

pub fn context_switch_to(p: *proc.Process) void {
    asm volatile (
        \\ csrw satp, %[satp]
        \\ sfence.vma zero, zero
        :
        : [satp] "r" (p.satp),
        : .{ .memory = true }
    );
}
```

- [ ] **Step 2: Compile-only check**

Run: `zig build kernel-elf`
Expected: succeeds. Neither function is called yet; both live in `.text` as potentially-dead symbols (the linker keeps them because the module is reachable from the kernel entry point, but LTO may inline them once called in Task 4).

- [ ] **Step 3: Commit**

```bash
git add tests/programs/kernel/sched.zig
git commit -m "feat(kernel): add scheduler stub (schedule + context_switch_to) (Plan 2.D Task 2)"
```

---

### Task 3: Rename `the_tf` to `the_process` in `trampoline.S`

**Files:**
- Modify: `tests/programs/kernel/trampoline.S` (3 sites — lines 94, 105, 110)

**Why:** `the_tf` will be removed in Task 4 when `kmain.zig` switches to referencing `the_process`. The trampoline's save/restore block stays byte-for-byte identical because TF_* offsets are offsets within `TrapFrame`, not within `Process`, and `@offsetOf(Process, "tf") == 0` means `&the_process == &the_process.tf`.

- [ ] **Step 1: Edit `trampoline.S` — three `la` sites**

In `tests/programs/kernel/trampoline.S`:
- Line around 94: change `la      t0, the_tf` to `la      t0, the_process`.
- Line around 105: change `la      a0, the_tf` to `la      a0, the_process`.
- Line around 110: change `la      a0, the_tf` to `la      a0, the_process`.

The surrounding comments mentioning "the_tf" should also be updated to "the_process" for consistency.

- [ ] **Step 2: Intermediate compile check (expected to FAIL with a linker error)**

Run: `zig build kernel-elf 2>&1 | head -20`
Expected: link fails with `undefined symbol: the_process` (or equivalent). `kmain.zig` still exports `the_tf` but trampoline now refers to `the_process`. This is the transient mid-refactor state; Task 4 fixes it.

Do NOT commit this state. Task 4's edits go on top.

- [ ] **Step 3: Stage the trampoline changes but do NOT commit**

```bash
git add tests/programs/kernel/trampoline.S
```

No commit yet — Task 4 will bundle the trampoline + kmain changes into a single commit that leaves the tree buildable.

---

### Task 4: Update `kmain.zig` to use `proc.the_process` and call `sched.context_switch_to`

**Files:**
- Modify: `tests/programs/kernel/kmain.zig` (full rewrite — file is 95 lines)

**Why:** This is the bridge between Tasks 1-3 and the rest of the plan. Once kmain sets up `proc.the_process` instead of the standalone `the_tf`, the kernel is once again linkable and `e2e-kernel` continues to pass (same observable output — no new syscalls yet).

- [ ] **Step 1: Rewrite `tests/programs/kernel/kmain.zig`**

Full file (replace contents):

```zig
// tests/programs/kernel/kmain.zig — Phase 2 Plan 2.D kernel S-mode entry.
//
// Difference from 2.C: the standalone `the_tf` is gone. The trapframe is
// now the first field of `proc.the_process`, so sscratch / trampoline
// references point at the same memory via the new symbol `the_process`.
// Boot also routes through `sched.context_switch_to` for the initial
// satp write so Plan 3 has one code path to edit when the switch becomes
// non-trivial.

const std = @import("std");
const uart = @import("uart.zig");
const vm = @import("vm.zig");
const page_alloc = @import("page_alloc.zig");
const trap = @import("trap.zig");
const proc = @import("proc.zig");
const sched = @import("sched.zig");
const user_blob = @import("user_blob");

pub const USER_BLOB: []const u8 = user_blob.BLOB;

const SATP_MODE_SV32: u32 = 1 << 31;

extern fn s_trap_entry() void;
extern fn s_return_to_user(tf: *trap.TrapFrame) noreturn;

// Linker symbol: top of the 16 KB kernel stack. Used to populate
// the_process.kstack_top so the trampoline can switch to it on trap entry.
// (Plan 2.C's trampoline hard-codes `la sp, _kstack_top`; Plan 3 will
// want this per-process. 2.D stores it but trampoline still uses the
// linker symbol directly — wiring it through is Phase 3 scope.)
extern const _kstack_top: u8;

export fn kmain() callconv(.c) noreturn {
    page_alloc.init();
    const root_pa = vm.allocRoot();
    vm.mapKernelAndMmio(root_pa);
    vm.mapUser(root_pa, USER_BLOB.ptr, @intCast(USER_BLOB.len));

    // Initialize the single process.
    proc.the_process = std.mem.zeroes(proc.Process);
    proc.the_process.tf.sepc = vm.USER_TEXT_VA; // _start lives at VA 0x00010000
    proc.the_process.tf.sp = vm.USER_STACK_TOP;
    proc.the_process.satp = SATP_MODE_SV32 | (root_pa >> 12);
    proc.the_process.kstack_top = @intCast(@intFromPtr(&_kstack_top));
    proc.the_process.state = .Runnable;
    // ticks_observed, exit_code already zero from zeroes().

    // Install the S-mode trap vector and sscratch.
    const tf_addr: u32 = @intCast(@intFromPtr(&proc.the_process));
    const stvec_val: u32 = @intCast(@intFromPtr(&s_trap_entry));
    asm volatile (
        \\ csrw stvec, %[stv]
        \\ csrw sscratch, %[ss]
        :
        : [stv] "r" (stvec_val),
          [ss] "r" (tf_addr),
        : .{ .memory = true }
    );

    // Enable sie.SSIE so forwarded timer ticks deliver in S-mode.
    // (U-mode delivery is always on as a consequence of lower-privilege
    // semantics; this bit matters for any S-mode-originated SSI once the
    // kernel grows nested structures — defense-in-depth for Plan 3+.)
    const SIE_SSIE: u32 = 1 << 1;
    asm volatile ("csrs sie, %[b]"
        :
        : [b] "r" (SIE_SSIE),
        : .{ .memory = true }
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
        : .{ .memory = true }
    );

    // Flip on Sv32 translation via the scheduler's context-switch helper.
    // Plan 3 will reroute SSI + yield here too; 2.D only uses it from boot.
    sched.context_switch_to(&proc.the_process);

    // Jump to the trampoline's return-to-user path with a0 = &the_process.tf.
    // Since @offsetOf(Process, "tf") == 0, &the_process is the TrapFrame ptr.
    s_return_to_user(@ptrCast(&proc.the_process));
}

// Keep `uart` in the reachable set for potential early-boot panic printing.
comptime {
    _ = uart;
}
```

- [ ] **Step 2: Full-tree compile check**

Run: `zig build kernel-elf`
Expected: succeeds. Trampoline.S + kmain.zig now agree on the `the_process` symbol.

- [ ] **Step 3: E2E regression check**

Run: `zig build e2e-kernel`
Expected: `zig build e2e-kernel` passes (stdout still equals `"hello from u-mode\n"`, exit 0). Observable behavior is unchanged from 2.C — we only moved memory around.

- [ ] **Step 4: Commit both files in one commit**

```bash
git add tests/programs/kernel/kmain.zig tests/programs/kernel/trampoline.S
git commit -m "refactor(kernel): route kmain + trampoline through proc.the_process (Plan 2.D Task 4)"
```

---

### Task 5: Wire the S-mode timer-tick handler to increment `ticks_observed` and call `schedule`

**Files:**
- Modify: `tests/programs/kernel/trap.zig` (rewrite the SSI branch in `s_trap_dispatch`; add imports)

**Why:** The kernel already acknowledges SSI (clears SSIP) — Plan 2.C validated the full MTI→SSIP forwarding path. Plan 2.D lands the actual tick work: counter bump + scheduler pick. We don't call `context_switch_to` here (see `sched.zig` comment) — with one process, `satp` is already correct.

- [ ] **Step 1: Rewrite `tests/programs/kernel/trap.zig`**

Full file:

```zig
// tests/programs/kernel/trap.zig — S-mode trap dispatcher.
//
// Plan 2.D changes: the SSI branch now increments the_process.ticks_observed
// and calls sched.schedule(). The ECALL branch is unchanged from 2.C; the
// panic branch is unchanged from 2.C.
//
// Field order in TrapFrame matters. trampoline.S saves/restores registers
// at fixed offsets; any re-ordering here is an asm ABI break. The comptime
// block below pins the offsets.

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

const kprintf = @import("kprintf.zig");
const syscall = @import("syscall.zig");
const proc = @import("proc.zig");
const sched = @import("sched.zig");

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
    // sip.SSIP is bit 1. `csrci sip, 2` clears it.
    asm volatile ("csrci sip, 2"
        :
        :
        : .{ .memory = true }
    );
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
        // Supervisor software interrupt — forwarded timer tick.
        // 1. Clear sip.SSIP so the same edge doesn't re-fire immediately.
        // 2. Bump the per-process tick counter (wrapping add — 2^32 ticks
        //    at 10 kHz nominal is ≈ 4.9 days, overflow is not a 2.D worry).
        // 3. Pick next process. In Phase 2 this is always the same one,
        //    but we exercise the code path so Plan 3's picker drops in
        //    without a signature change.
        clearSipSsip();
        proc.the_process.ticks_observed +%= 1;
        _ = sched.schedule();
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

- [ ] **Step 2: Compile check**

Run: `zig build kernel-elf`
Expected: succeeds.

- [ ] **Step 3: Behavior check (still same expected output)**

Run: `zig build e2e-kernel`
Expected: passes. The counter bumps during the quiet period before user `exit`, but nothing reads it yet, so observable output is unchanged.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/kernel/trap.zig
git commit -m "feat(kernel): timer ISR bumps ticks_observed and invokes scheduler (Plan 2.D Task 5)"
```

---

### Task 6: Implement `sys_yield`; make `sys_exit` print `"ticks observed: N\n"`

**Files:**
- Modify: `tests/programs/kernel/syscall.zig` (full rewrite — file is 58 lines)

**Why:** Two user-observable additions. `sys_yield` finally does real work — calls `schedule()` (whose no-op nature is fine for Phase 2). `sys_exit` prints the ticks count before halting, so the final byte sequence hits the Phase 2 §Definition of done string.

- [ ] **Step 1: Rewrite `tests/programs/kernel/syscall.zig`**

Full file:

```zig
// tests/programs/kernel/syscall.zig — Phase 2 Plan 2.D syscall table.
//
// Plan 2.D changes vs 2.C:
//   - `124` (yield) now real — calls sched.schedule().
//   - `93` (exit) now prints "ticks observed: {d}\n" via kprintf before
//     halting, so the final observable stdout matches the Phase 2 DoD:
//       "hello from u-mode\nticks observed: N\n"
//
// ABI unchanged: a7 = syscall number, a0..a5 = args, a0 = return.

const trap = @import("trap.zig");
const uart = @import("uart.zig");
const kprintf = @import("kprintf.zig");
const proc = @import("proc.zig");
const sched = @import("sched.zig");

const SSTATUS_SUM: u32 = 1 << 18;

fn setSum() void {
    asm volatile ("csrs sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SUM),
        : .{ .memory = true }
    );
}

fn clearSum() void {
    asm volatile ("csrc sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SUM),
        : .{ .memory = true }
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
    // Emit the Phase 2 §Definition of done trailer: "ticks observed: N\n".
    // We read the counter AFTER the scheduler has had a chance to bump it
    // one last time (the ticks live in proc.the_process, touched by the
    // SSI handler in trap.zig).
    kprintf.print("ticks observed: {d}\n", .{proc.the_process.ticks_observed});
    const halt: *volatile u8 = @ptrFromInt(0x00100000);
    halt.* = @intCast(status & 0xFF);
    // Unreachable — halt MMIO terminates the emulator on the store above.
    while (true) asm volatile ("wfi");
}

fn sysYield() u32 {
    // Plan 2.D: scheduler has one process, so this is a no-op pick. We
    // still exercise the path so Plan 3's real picker drops in without
    // changing the syscall layer.
    _ = sched.schedule();
    return 0;
}

pub fn dispatch(tf: *trap.TrapFrame) void {
    switch (tf.a7) {
        64 => tf.a0 = sysWrite(tf.a0, tf.a1, tf.a2),
        93 => sysExit(tf.a0),
        124 => tf.a0 = sysYield(),
        else => tf.a0 = @bitCast(@as(i32, -38)), // -ENOSYS
    }
}
```

- [ ] **Step 2: Compile check**

Run: `zig build kernel-elf`
Expected: succeeds.

- [ ] **Step 3: E2E check — this will FAIL temporarily**

Run: `zig build e2e-kernel 2>&1 | tail -10`
Expected: FAILS because expected output is still `"hello from u-mode\n"` but actual is now `"hello from u-mode\nticks observed: 0\n"` (N is 0 — user never waits for a tick yet; the busy-loop and `yield` ecall arrive in Tasks 7 and 8, and the TIMESLICE tweak in Task 9).

This failure is expected. Do NOT commit yet — the expected output needs to change in Task 10 first, and the N=0 result needs the Task 7+8+9 changes.

- [ ] **Step 4: Stage but do NOT commit**

```bash
git add tests/programs/kernel/syscall.zig
```

Continue to Task 7.

---

### Task 7: Add `yield` + busy-loop to the user program

**Files:**
- Modify: `tests/programs/kernel/user/userprog.zig`

**Why:** The user program now needs to (a) call yield so the `sys_yield` handler is actually exercised, and (b) stay in U-mode long enough for at least one timer tick to fire (so `ticks_observed > 0` when `sys_exit` reads it). The busy-loop is 3 asm instructions — a decrement-and-branch on `t0`.

- [ ] **Step 1: Rewrite `tests/programs/kernel/user/userprog.zig`**

Full file:

```zig
// tests/programs/kernel/user/userprog.zig — Plan 2.D U-mode payload.
//
// Naked `_start` does: write(1, msg, 18); yield(); busy-loop 100k; exit(0).
// The busy-loop is there so wall-clock time advances enough that at least
// one timer tick fires while we're in U-mode — guaranteeing
// `ticks_observed > 0` when the kernel's sys_exit prints it.
//
// Syscall ABI (matches Linux RISC-V subset):
//   a7 = syscall #, a0..a5 = args, a0 = return.
//   write (64): fd=a0, buf=a1, len=a2
//   yield (124): (no args)
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
        \\ li   a7, 124
        \\ ecall
        \\ li   t0, 100000
        \\ 1:
        \\ addi t0, t0, -1
        \\ bnez t0, 1b
        \\ li   a7, 93
        \\ li   a0, 0
        \\ ecall
        \\ 2:
        \\ j    2b
    );
}
```

- [ ] **Step 2: Compile check**

Run: `zig build kernel-elf`
Expected: succeeds.

- [ ] **Step 3: Spot-check the user binary**

Run: `llvm-objdump -d zig-out/bin/userprog.elf | head -40`
Expected: the disassembly shows three `ecall` sites and a short decrement-branch loop between the second and third ecall. Scrubbing for pseudo-ops, the loop should be two instructions (`addi t0,t0,-1` and `bnez t0, ...`) plus the `li t0, 100000` initializer.

- [ ] **Step 4: E2E check — will STILL fail, but output should now end with a positive N**

Run: `zig build e2e-kernel 2>&1 | tail -10`
Expected: FAILS, but the failure diagnostic now shows actual output `"hello from u-mode\nticks observed: N\n"` with N probably still 0 (because TIMESLICE = 1_000_000 is way too big — 10+ seconds at 10 MHz nominal before first tick, and the user program finishes in milliseconds). Task 9 drops TIMESLICE. Task 8 lands the e2e verifier that replaces `expectStdOutEqual`. Don't commit yet.

- [ ] **Step 5: Stage but do NOT commit**

```bash
git add tests/programs/kernel/user/userprog.zig
```

Continue to Task 8.

---

### Task 8: Write the host-side e2e verifier tool

**Files:**
- Create: `tests/programs/kernel/verify_e2e.zig`

**Why:** `expectStdOutEqual` can't express "the stdout matches this regex with N > 0". The verifier is a tiny host executable that spawns `ccc kernel.elf`, captures stdout, and asserts the structural shape by hand. No external regex library needed — the format is fixed enough that `startsWith` + `parseInt` is sufficient.

- [ ] **Step 1: Create `tests/programs/kernel/verify_e2e.zig`**

```zig
// tests/programs/kernel/verify_e2e.zig — Phase 2 Plan 2.D e2e verifier.
//
// Host-compiled helper for `zig build e2e-kernel`. Spawns the emulator
// with the kernel ELF and asserts the Phase 2 §Definition of done:
//   - exit code 0
//   - stdout exactly:  "hello from u-mode\n"
//                      "ticks observed: N\n"
//     where N is a decimal integer > 0
//
// Usage: verify_e2e <ccc-binary> <kernel.elf>
//
// Uses Zig 0.16's std.process.spawn / Io.File.reader / Io.Reader.allocRemaining
// APIs (the stdlib was restructured in 0.16 — older patterns like
// std.process.Child.init().spawn() no longer compile).

const std = @import("std");
const Io = std.Io;

const FAIL_EXIT: u8 = 1;
const USAGE_EXIT: u8 = 2;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    // stderr writer for our diagnostics; inherits in the child separately.
    var stderr_buf: [512]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_fw.interface;

    const argv = try init.minimal.args.toSlice(gpa);
    defer gpa.free(argv);

    if (argv.len != 3) {
        stderr.print("usage: {s} <ccc-binary> <kernel.elf>\n", .{argv[0]}) catch {};
        stderr.flush() catch {};
        return USAGE_EXIT;
    }

    // Spawn ccc with the kernel ELF as its sole argument; pipe stdout, let
    // stderr inherit so emulator diagnostics (if any) are visible to the
    // operator.
    const child_argv = &[_][]const u8{ argv[1], argv[2] };
    var child = try std.process.spawn(io, .{
        .argv = child_argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    // Read all of stdout. Cap at 64 KiB — Phase 2's kernel output is
    // ~35 bytes; anything larger is a runaway bug we want to fail on.
    const MAX_BYTES: usize = 65536;
    var read_buf: [4096]u8 = undefined;
    var reader = child.stdout.?.reader(io, &read_buf);
    const out = reader.interface.allocRemaining(gpa, .limited(MAX_BYTES)) catch |err| switch (err) {
        error.StreamTooLong => {
            stderr.print(
                "verify_e2e: kernel output exceeded {d} bytes\n",
                .{MAX_BYTES},
            ) catch {};
            stderr.flush() catch {};
            child.kill(io);
            return FAIL_EXIT;
        },
        else => return err,
    };
    defer gpa.free(out);

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            stderr.print(
                "verify_e2e: expected exit 0, got {d}\nstdout was:\n{s}\n",
                .{ code, out },
            ) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
        else => {
            stderr.print(
                "verify_e2e: child terminated abnormally: {any}\nstdout was:\n{s}\n",
                .{ term, out },
            ) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
    }

    // Assert structure: "hello from u-mode\nticks observed: <N>\n".
    const expected_prefix = "hello from u-mode\nticks observed: ";
    if (!std.mem.startsWith(u8, out, expected_prefix)) {
        stderr.print(
            "verify_e2e: stdout prefix mismatch\n  expected prefix: {s}\n  got: {s}\n",
            .{ expected_prefix, out },
        ) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    const rest = out[expected_prefix.len..];
    // Find the terminating '\n' that ends the ticks-observed line.
    var end: usize = 0;
    while (end < rest.len and rest[end] != '\n') : (end += 1) {}
    if (end == 0) {
        stderr.print(
            "verify_e2e: empty number after 'ticks observed: '\n  stdout: {s}\n",
            .{out},
        ) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }
    if (end == rest.len) {
        stderr.print(
            "verify_e2e: no newline after 'ticks observed: N'\n  stdout: {s}\n",
            .{out},
        ) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    const n_str = rest[0..end];
    const n = std.fmt.parseInt(u32, n_str, 10) catch {
        stderr.print(
            "verify_e2e: could not parse ticks: {s}\n  stdout: {s}\n",
            .{ n_str, out },
        ) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    };

    if (n == 0) {
        stderr.print(
            "verify_e2e: expected ticks > 0, got 0 (TIMESLICE too large or user program too short?)\n  stdout: {s}\n",
            .{out},
        ) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    // The '\n' at `end` must be the last byte. Anything after it is garbage.
    if (end + 1 != rest.len) {
        stderr.print(
            "verify_e2e: trailing bytes after final newline\n  stdout: {s}\n",
            .{out},
        ) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    return 0;
}
```

- [ ] **Step 2: Add verify_e2e to build.zig and rewrite e2e-kernel step**

Open `build.zig`. Find the existing `e2e-kernel` block (roughly lines 317-326). Replace:

```zig
    const e2e_kernel_run = b.addRunArtifact(exe);
    e2e_kernel_run.addFileArg(kernel_elf.getEmittedBin());
    e2e_kernel_run.expectStdOutEqual("hello from u-mode\n");
    e2e_kernel_run.expectExitCode(0);

    const e2e_kernel_step = b.step("e2e-kernel", "Run the Plan 2.C kernel e2e test");
    e2e_kernel_step.dependOn(&e2e_kernel_run.step);
```

with:

```zig
    // Host-compiled verifier: spawns ccc on kernel.elf, captures stdout,
    // asserts the Phase 2 §Definition of done shape (variable N > 0).
    const verify_e2e = b.addExecutable(.{
        .name = "verify_e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/verify_e2e.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const e2e_kernel_run = b.addRunArtifact(verify_e2e);
    e2e_kernel_run.addFileArg(exe.getEmittedBin());
    e2e_kernel_run.addFileArg(kernel_elf.getEmittedBin());
    e2e_kernel_run.expectExitCode(0);

    const e2e_kernel_step = b.step("e2e-kernel", "Run the Phase 2 kernel e2e test (hello + ticks)");
    e2e_kernel_step.dependOn(&e2e_kernel_run.step);
```

- [ ] **Step 3: Compile + run check — may still FAIL (N is still 0 until Task 9)**

Run: `zig build e2e-kernel 2>&1 | tail -20`
Expected: FAILS with the verifier's own diagnostic "expected ticks > 0, got 0 (TIMESLICE too large…)". This confirms the verifier is wired correctly. Do not commit yet — Task 9 will fix N.

- [ ] **Step 4: Stage but do NOT commit**

```bash
git add build.zig tests/programs/kernel/verify_e2e.zig
```

Continue to Task 9.

---

### Task 9: Drop TIMESLICE to 10_000 (1 ms at 10 MHz nominal)

**Files:**
- Modify: `tests/programs/kernel/boot.S`
- Modify: `tests/programs/kernel/mtimer.S`

**Why:** With the emulator's wall-clock mtime at ~10 MHz nominal (100 ns/tick, per `src/devices/clint.zig`), 1_000_000 ticks = 100 ms, and the short user program finishes well within that window. Dropping to 10_000 (1 ms) means at least one tick fires during the busy-loop. 1 ms is chosen over smaller values because the tick-handling overhead (~30 S-mode instructions per tick) should stay <10% of total work; at 10_000 we get 10-100 ticks in a ~10-100 ms run, fine.

The two values MUST agree — `boot.S` uses TIMESLICE for the initial `mtimecmp` program, and `mtimer.S` uses it for every subsequent advance. A mismatch would desync the two.

- [ ] **Step 1: Edit `tests/programs/kernel/boot.S` — change TIMESLICE**

Find the line:
```
.equ TIMESLICE, 1000000
```
Replace with:
```
.equ TIMESLICE, 10000
```

Also update the comment above it if it mentions 1_000_000 or 100 ms — set it to something like:
```
# Timer quantum: 10,000 CLINT ticks per slice. At the emulator's
# 10 MHz nominal CLINT rate, that's ~1 ms — short enough that even a
# sub-10-ms user program guarantees at least one tick fires.
```

- [ ] **Step 2: Edit `tests/programs/kernel/mtimer.S` — change TIMESLICE**

Find:
```
.equ TIMESLICE,         1000000
```
Replace with:
```
.equ TIMESLICE,         10000
```

- [ ] **Step 3: Verify the two asm files agree**

Run: `grep "TIMESLICE" tests/programs/kernel/boot.S tests/programs/kernel/mtimer.S`
Expected: both show `.equ TIMESLICE, 10000` (with possibly different whitespace). Values must match.

- [ ] **Step 4: Compile + run**

Run: `zig build e2e-kernel`
Expected: passes. The sequence Tasks 1-9 has just completed Phase 2's Definition of Done end-to-end. Stdout is now `"hello from u-mode\nticks observed: N\n"` for some N > 0 (typical: 1-20 on a modest laptop; lower on very fast hosts, higher on slower ones — all valid).

- [ ] **Step 5: Inspect actual output**

Run: `zig build kernel && zig-out/bin/ccc zig-out/bin/kernel.elf`
Expected stdout (N will vary run-to-run):
```
hello from u-mode
ticks observed: 3
```
Exit code 0 (`echo $?` → `0`).

- [ ] **Step 6: Commit all the Task 6+7+8+9 changes together**

These four tasks form the single atomic user-visible behavior change (the output gains a second line). Squashing them makes the git history readable.

```bash
git add tests/programs/kernel/syscall.zig tests/programs/kernel/user/userprog.zig \
        tests/programs/kernel/verify_e2e.zig build.zig \
        tests/programs/kernel/boot.S tests/programs/kernel/mtimer.S
git commit -m "feat(kernel): sys_yield + ticks_observed output + e2e verifier + TIMESLICE tune (Plan 2.D Tasks 6-9)"
```

---

### Task 10: Add `qemu-diff-kernel.sh` and the `zig build qemu-diff-kernel` step

**Files:**
- Create: `scripts/qemu-diff-kernel.sh`
- Modify: `build.zig`

**Why:** Spec §Testing strategy calls for a QEMU-diff harness against kernel.elf. Since the existing `scripts/qemu-diff.sh` already does the heavy lifting (canonicalize both traces to PC+RAW, dedupe by PC, diff), the kernel version is a thin wrapper that ensures kernel.elf is built first. The `zig build qemu-diff-kernel` step lets developers invoke it without remembering the script path.

This is a debug aid, not a CI gate — it requires `qemu-system-riscv32` installed (noted in the script's error message). The default Phase 1 divergence notes (boot ROM, PMP) carry over; one new expected divergence is the async timer interrupt, which fires at different wall-clock moments in the two emulators and causes traces to diverge the first time MTIP is taken.

- [ ] **Step 1: Create `scripts/qemu-diff-kernel.sh`**

```bash
#!/usr/bin/env bash
# qemu-diff-kernel.sh — diff per-instruction traces of kernel.elf between
# our emulator and qemu-system-riscv32. Thin wrapper over qemu-diff.sh:
# builds the kernel first, then delegates to the Phase 1 harness.
#
# Usage:
#   scripts/qemu-diff-kernel.sh [max-instructions]
#
# Known structural (non-bug) divergences, in addition to the ones noted
# in qemu-diff.sh:
#
#   * Async timer interrupts — our emulator and QEMU have independent
#     wall clocks; MTIP will fire at different moments, causing the
#     post-first-tick traces to diverge. For debug of the synchronous
#     M→S drop and the user entry, pass a low max-instructions (e.g.,
#     200) to halt before the first TIMESLICE expires.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "building kernel.elf..." >&2
zig build kernel

exec "$SCRIPT_DIR/qemu-diff.sh" zig-out/bin/kernel.elf "$@"
```

- [ ] **Step 2: Make the script executable**

Run: `chmod +x scripts/qemu-diff-kernel.sh`

- [ ] **Step 3: Add the `qemu-diff-kernel` build step to `build.zig`**

Open `build.zig`. Immediately after the `e2e_kernel_step.dependOn(&e2e_kernel_run.step);` line added in Task 8, append:

```zig
    // qemu-diff-kernel: debug-only trace diff against QEMU. Requires
    // qemu-system-riscv32 on PATH; not run by CI.
    const qemu_diff_kernel_cmd = b.addSystemCommand(&.{
        "bash",
        "scripts/qemu-diff-kernel.sh",
    });
    qemu_diff_kernel_cmd.step.dependOn(&install_kernel_elf.step);
    const qemu_diff_kernel_step = b.step(
        "qemu-diff-kernel",
        "Diff kernel.elf instruction trace against qemu-system-riscv32 (debug aid)",
    );
    qemu_diff_kernel_step.dependOn(&qemu_diff_kernel_cmd.step);
```

- [ ] **Step 4: Verify the build graph**

Run: `zig build --help 2>&1 | grep qemu-diff-kernel`
Expected: a line like `  qemu-diff-kernel             Diff kernel.elf instruction trace against qemu-system-riscv32 (debug aid)`.

- [ ] **Step 5: Smoke-test the script (only if qemu-system-riscv32 is on PATH)**

If you have QEMU installed:
```bash
scripts/qemu-diff-kernel.sh 200 2>&1 | tail -30
```
Expected: either "OK: traces match over N instructions" (unlikely given boot-ROM divergence) or a short diff output. Exit code doesn't matter — the goal is that the script ran without a syntax error.

If QEMU isn't installed: skip this step; the script will correctly print the installation hint and exit 2.

- [ ] **Step 6: Commit**

```bash
git add scripts/qemu-diff-kernel.sh build.zig
git commit -m "feat(kernel): qemu-diff-kernel.sh + build step for trace divergence debug (Plan 2.D Task 10)"
```

---

### Task 11: Update README.md Status + Next

**Files:**
- Modify: `README.md` (Status section and the build-targets table)

**Why:** Phase 2 is now complete. The README should reflect that `e2e-kernel` asserts the full DoD output (not just "hello from u-mode\n"), `qemu-diff-kernel` exists, and the project is entering Phase 3.

- [ ] **Step 1: Update the build-targets table**

In `README.md`, find the line:

```
| `zig build e2e-kernel` | Run `ccc kernel.elf` and assert stdout equals `hello from u-mode\n` (Plan 2.C integration test) |
```

Replace with:

```
| `zig build e2e-kernel` | Run `ccc kernel.elf` and assert stdout matches `hello from u-mode\nticks observed: N\n` with N > 0 (Phase 2 §Definition of done) |
| `zig build qemu-diff-kernel` | Diff the kernel.elf trace against `qemu-system-riscv32` (debug aid; needs QEMU installed) |
```

- [ ] **Step 2: Rewrite the Status section**

Find the Status section (starts with `## Status` around line 87). Replace the "Plan 2.C" block and the "Next" line with:

```
**Phase 2 — Bare-metal kernel — complete.**

Plans 2.A (emulator S-mode + Sv32 paging), 2.B (trap delegation + async
interrupts), 2.C (kernel skeleton: boot shim, page table, S-mode trap
dispatcher, `write`/`exit` demo), and 2.D (Process struct + scheduler
stub + `yield` + tick counter) are merged.

The Phase 2 §Definition of done demo:

    $ zig build e2e-kernel
    # passes: stdout matches "hello from u-mode\nticks observed: N\n" with N > 0

    $ zig build kernel && zig build run -- zig-out/bin/kernel.elf
    hello from u-mode
    ticks observed: 7

Three privilege levels active in a single run: M-mode boot shim (sets up
delegation + CLINT, forwards MTI to SSIP on each tick), S-mode kernel
(manages Sv32 page table, trap dispatcher, syscalls, increments tick
counter), U-mode user program (writes, yields, busy-loops, exits). The
scheduler stub always re-picks the single process; Phase 3 will swap in
a real picker behind the same `sched.schedule()` interface.

Debug aids: `zig build qemu-diff-kernel` runs `scripts/qemu-diff-kernel.sh`,
which compares per-instruction traces between our emulator and QEMU.
Requires `qemu-system-riscv32`; not a CI gate.

Next: **Phase 3 — multi-process OS + filesystem + shell.**
```

- [ ] **Step 3: Sanity-check the README rendering**

Read `README.md` top-to-bottom. Verify:
- Build-targets table has both the updated `e2e-kernel` row and the new `qemu-diff-kernel` row.
- Status section announces Phase 2 complete.
- Next line points to Phase 3.
- No dangling references to `hello from u-mode\n` as the full expected stdout.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: Phase 2 complete — update README status + build targets (Plan 2.D Task 11)"
```

---

### Task 12: Full regression suite + Phase 2 §Definition of done verification

**Files:** none modified; this is a verification task.

**Why:** Plan 2.D's changes are all under `tests/programs/kernel/` plus `build.zig` additions and one README update — no emulator source touched. But the plan's own regression guarantee requires running the full Phase 1 + Phase 2 test matrix to confirm nothing broke.

- [ ] **Step 1: Run the full Phase 1 suite**

Run the five Phase 1 test targets in one command:

```bash
zig build test e2e e2e-mul e2e-trap e2e-hello-elf
```

Expected: all succeed. No output unless a test fails.

- [ ] **Step 2: Run riscv-tests**

Run:

```bash
zig build riscv-tests
```

Expected: all 67 tests pass (rv32ui: 39, rv32um: 8, rv32ua: 10, rv32mi: 8, rv32si: 5 — minus any the build.zig excludes). No output on success.

- [ ] **Step 3: Run the Phase 2 kernel e2e**

Run:

```bash
zig build e2e-kernel
```

Expected: succeeds (verifier returns 0).

- [ ] **Step 4: Manually verify the §Definition of done output**

Run:

```bash
zig build kernel && zig-out/bin/ccc zig-out/bin/kernel.elf ; echo "exit=$?"
```

Expected (N will vary):

```
hello from u-mode
ticks observed: 5
exit=0
```

Structure checklist:
- [ ] First line is exactly `hello from u-mode` (no prefix, no trailing whitespace).
- [ ] Second line starts with `ticks observed: ` and ends with a positive integer.
- [ ] Both lines terminated by `\n` (the CLI shows them on separate lines).
- [ ] Exit code is `0`.

- [ ] **Step 5: Manually verify `--trace` still shows all three privilege levels**

Run:

```bash
zig-out/bin/ccc --trace zig-out/bin/kernel.elf 2>&1 >/dev/null | head -40
```

Expected: the first lines show `[M]` for M-mode boot; some later line shows `mret` with a PC redirect into S-mode and subsequent lines show `[S]`; then eventually `sret` and `[U]` lines at PC ≈ `0x00010000`. An interrupt marker `--- interrupt 1 (supervisor software) taken in U, now S ---` appears somewhere in the tail (if the user busy-loop got interrupted before exit).

- [ ] **Step 6: Symbol-table sanity check on kernel.elf**

Run:

```bash
llvm-nm zig-out/bin/kernel.elf | grep -E '(the_process|schedule|sys_yield|sys_exit)' | sort
```

Expected: all four symbols present. Specifically:
- `the_process` (in `.bss`, type `B`)
- `sched.schedule` (in `.text`, type `T` or `t`)
- `syscall.sysYield` (in `.text`)
- `syscall.sysExit` (in `.text`)

The exact mangled names may vary slightly by Zig version; the key is that none is absent.

- [ ] **Step 7: No commit — this is a verification-only task**

If everything above passed, Plan 2.D (and therefore Phase 2) is complete. The final commit graph should read:

```
<task11> docs: Phase 2 complete — update README status + build targets (Plan 2.D Task 11)
<task10> feat(kernel): qemu-diff-kernel.sh + build step for trace divergence debug (Plan 2.D Task 10)
<6-9>    feat(kernel): sys_yield + ticks_observed output + e2e verifier + TIMESLICE tune (Plan 2.D Tasks 6-9)
<task5>  feat(kernel): timer ISR bumps ticks_observed and invokes scheduler (Plan 2.D Task 5)
<task4>  refactor(kernel): route kmain + trampoline through proc.the_process (Plan 2.D Task 4)
<task2>  feat(kernel): add scheduler stub (schedule + context_switch_to) (Plan 2.D Task 2)
<task1>  feat(kernel): add Process struct and the_process singleton (Plan 2.D Task 1)
```

Seven commits; each compiles; most pass e2e individually; tasks 3 and 6-8 stage without committing and get bundled with neighbors per their instructions.

---

## Risks and open questions addressed during 2.D

- **TIMESLICE tuning is timing-sensitive.** On a very fast host, 10,000 CLINT ticks (1 ms wall-clock) may be shorter than the time between `sret`-to-U-mode and the first busy-loop instruction — unlikely but theoretically possible. Mitigation: the 100,000-iteration busy-loop in the user program has ~300k emulator cycles, which at even 100 MIPS-equivalent emulation speed is ~3 ms wall-clock. Several ticks fire. If this ever becomes a flake vector, lower TIMESLICE to 1,000 (kernel overhead at 1k is still <30%).
- **N is non-deterministic.** The verifier accepts any N > 0. This means two runs produce different captured stdout. `expectStdOutEqual` cannot express this; that's why Task 8 introduces the host-side verifier. Phase 3+ tests that need determinism should either (a) advance `mtime` in instruction-retire units rather than wall-clock, or (b) drop TIMESLICE so low that N is saturated to a predictable magnitude.
- **QEMU-diff divergence on timer ticks.** QEMU and our emulator have independent wall clocks, so after the first MTIP, the traces diverge. Plan 2.D's qemu-diff-kernel is most useful for the *pre-first-tick* section (M-mode boot, S-mode setup, first sret-to-U, maybe the first ecall). Pass `max-instructions = 200` to stay in that window.
- **Nested S-mode traps.** If a timer tick arrives while we're already handling a U-mode ecall in S-mode, the hardware-cleared `sstatus.SIE = 0` blocks delivery, and MTIP stays pending in M-mode until the next U-mode instruction boundary after `sret`. Plan 2.C noted this; Plan 2.D changes nothing in this area.
- **the_process must be `extern struct`.** Zig's default struct layout reorders fields. If Plan 2.D accidentally used a default struct, `@offsetOf(Process, "tf") == 0` would still hold (Zig can't reorder a single field to a non-zero offset… well, it could pad), but `trap.TrapFrame` field order inside the embedded `tf` would not be guaranteed. The comptime asserts in `trap.zig` would still catch TrapFrame reordering; but this isn't a concern since `TrapFrame` itself is already `extern struct` from 2.C.
- **`context_switch_to` on the hot path is skipped.** The SSI branch and `sys_yield` deliberately skip `context_switch_to` since they'd be re-writing the same `satp`. When Phase 3 introduces a real picker, `schedule()` returns the new process and the caller must pass that return value to `context_switch_to`. The current interface already carries the process pointer, so the Phase 3 change is additive.
- **Kernel stack depth during `kprintf.print` from `sys_exit`.** `kprintf.print` uses `uart.writeByte` per character; the deepest call is `print → writeDecU32 → writeByte → MMIO store`. ~4 frames of ~8 words each = 128 bytes. 16 KB kernel stack is wildly sufficient.
- **`proc.the_process.ticks_observed` as a read-modify-write from S-mode.** The SSI handler does `ticks_observed +%= 1`. Between the load and the store, a nested trap could (in principle) interleave. Phase 2 blocks this because `sstatus.SIE = 0` during trap handling; the next MTIP sits pending in `mip` until the handler returns. If Phase 3 ever enables nested S traps, this counter needs atomic semantics (or the kernel needs to set `SIE = 0` explicitly).
- **Symbol lookup in `llvm-nm` checks.** The Task 1 Step 3 and Task 12 Step 6 checks use `llvm-nm` which ships with the Zig distribution. If a CI environment has a `zig` without the LLVM tools on PATH, those steps can be skipped (they're sanity checks, not build gates).

---

## What success looks like at the end of Plan 2.D

```
$ zig build test                              # all unit tests pass (Phase 1 + 2)
$ zig build riscv-tests                       # rv32ui/um/ua/mi/si p-* all pass
$ zig build e2e-kernel                        # Phase 2 §Definition of done
# passes

$ zig build kernel && zig build run -- zig-out/bin/kernel.elf
hello from u-mode
ticks observed: 4

$ zig build run -- --trace zig-out/bin/kernel.elf 2>&1 | head -12
PC=0x80000000 RAW=0x00001117  [M]  auipc  [x2 := 0x80001000]
PC=0x80000004 RAW=0x04010113  [M]  addi   [x2 := 0x80001040]
PC=0x80000008 RAW=0x00000297  [M]  auipc  [x5 := 0x80000008]
... (M-mode boot shim)
PC=0x800000A0 RAW=0x30200073  [M]  mret   [pc -> 0x80001040]
PC=0x80001040 RAW=0x...       [S]  ... (kmain starts)
... (S-mode init, satp write, sret)
PC=0x00010000 RAW=0x06400893  [U]  li     [x17 := 0x00000040]
PC=0x00010004 RAW=0x00100513  [U]  li     [x10 := 0x00000001]
PC=0x00010008 RAW=0x...       [U]  auipc  [x11 := ...]
PC=0x0001000C RAW=0x01258593  [U]  addi   [x11 := ...]   # la msg
PC=0x00010010 RAW=0x01200613  [U]  li     [x12 := 0x00000012]
PC=0x00010014 RAW=0x00000073  [U]  ecall  [pc -> 0x80001xxx]
--- interrupt 1 (supervisor software) taken in U, now S ---
(later in trace — during the busy-loop)
```

…and Phase 2 is done. The kernel speaks, ticks count, traps delegate, interrupts forward, and we understand every byte of it because we wrote it all.
