# Phase 2 Plan B — Emulator: delegation + async interrupts (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Plan 2.A emulator with **trap delegation** (`medeleg` / `mideleg`) and **asynchronous interrupt delivery**. Synchronous exceptions raised at privilege `< M` whose cause bit is set in `medeleg` now route to S-mode via the S-CSR file instead of terminating in M. The CPU gains an interrupt-boundary check that samples `mip & mie` before each instruction fetch, resolves interrupt priority per RISC-V, applies per-privilege enable gating, and enters a trap at M or S as `mideleg` dictates. CLINT grows an `isMtipPending()` query; the emulator wires CLINT's MTIP output live into `mip.MTIP`. The headline acceptance test is an end-to-end `CLINT → mip.MTIP → M-mode ISR → csrs mip, SSIP → S-mode SSIP handler` forwarding round-trip in a single unit test — the pattern Plan 2.C's kernel boot shim depends on. The `rv32si-p-sbreak` and `rv32si-p-ma_fetch` upstream tests, blocked in 2.A pending delegation, start passing. Kernel code (`tests/programs/kernel/`) is out of scope; that arrives in Plan 2.C.

**Architecture:** Delegation is implemented as a single routing decision inside `trap.zig`: `trap.enter` (synchronous) and the new `trap.enter_interrupt` (asynchronous) each consult the delegation register appropriate to their class (`medeleg` / `mideleg`) and either run the existing M-mode entry machinery or a mirrored S-mode path writing `sepc` / `scause` / `stval` / `sstatus.SPP` / `sstatus.SPIE` / `sstatus.SIE` and jumping to `stvec.BASE`. The routing rule is symmetric for both classes: delegation only applies when `cpu.privilege != .M`, and only when the cause's bit is set in the relevant register; otherwise traps go to M. The async interrupt pump lives in `cpu.zig` as a new `cpu.check_interrupt` helper called at the top of `cpu.step` before the instruction fetch: it computes the effective `mip` (raw storage OR CLINT's live MTIP bit), masks against `mie`, applies the per-privilege global-enable gate (`mstatus.MIE` / `mstatus.SIE`) according to the would-be target privilege, picks the highest-priority pending-enabled-deliverable interrupt in the spec order `MEI > MSI > MTI > SEI > SSI > STI`, and hands it to `trap.enter_interrupt`. CLINT gains a pure query method `isMtipPending()` which returns `mtime >= mtimecmp && mtimecmp != 0`; `mip.MTIP` is NEVER stored in `cpu.csr.mip` — it is always derived from CLINT at every `mip`/`sip` read (csr access and interrupt check alike), and the csr write-mask on `mip` zeroes bit 7 to enforce the hardware-read-only semantics. Trace gets a one-line interrupt-marker emitter (`--- interrupt N (<name>) taken in <old>, now <new> ---`) that `trap.enter_interrupt` calls on a configured `trace_writer`. Two upstream rv32si tests (`sbreak`, `ma_fetch`) unlock automatically once delegation works.

**Tech Stack:** Zig 0.16.x (pinned in `build.zig.zon`), no new external dependencies. The `riscv-tests` submodule already contains `sbreak.S` and `ma_fetch.S`.

**Spec reference:** `docs/superpowers/specs/2026-04-24-phase2-bare-metal-kernel-design.md` — Plan 2.B covers spec §Privilege & trap model (Delegation, Synchronous trap entry via medeleg, Async interrupt flow), §Architecture (emulator growth rows for `cpu`, `csr`, `trap`, `devices/clint`), §CLI (trace-format interrupt markers), §Testing strategy item 1 (delegation / interrupt priority / SSIP-forwarding unit tests) and item 2 (rv32si-p-\* integration growth). The RISC-V Privileged Spec sections on interrupt handling (§3.1.6, §3.1.9) and exception delegation (§3.1.8) are authoritative; the phase spec takes precedence if they disagree.

**Plan 2.B scope (subset of Phase 2 spec):**

- **`medeleg` (0x302) and `mideleg` (0x303) CSRs with real storage.** Both are M-only (address bits 9:8 == 0b11 → read/write illegal below M). The 2.A stub (read-as-zero, writes dropped) is replaced.
  - `medeleg` WARL mask: bits 0 (inst misaligned), 2 (illegal instruction), 3 (breakpoint), 4 (load misaligned), 6 (store misaligned), 8 (ECALL from U), 12 (inst page fault), 13 (load page fault), 15 (store page fault). Bit 11 (ECALL from M) is hardwired zero: M traps cannot be delegated. Bits 9 (ECALL from S) and 10, 14, 16+ (reserved) are also hardwired zero in this implementation — we accept-and-drop writes but they read back zero, matching the Phase 2 spec's "ECALL_FROM_S not delegated" directive.
  - `mideleg` WARL mask: bits 1 (SSIP), 5 (STIP), 9 (SEIP). M-level interrupt bits (MSIP=3, MTIP=7, MEIP=11) are hardwired zero — M interrupts cannot be delegated (spec §3.1.9).
- **Delegation-aware synchronous trap entry.** `trap.enter(cause, tval, cpu)` gains a routing decision at the top. If `cpu.privilege != .M` AND `medeleg & (1 << cause)` is set, the trap targets S-mode: writes `sepc`, `scause`, `stval`, `sstatus.SPP`/`SPIE`/`SIE`, switches `privilege` to `.S`, and jumps to `stvec.BASE`. Otherwise the existing M-mode path runs unchanged. `cpu.reservation` is cleared on both paths. `cpu.trap_taken = true` is set on both paths. `mepc` / `sepc` are 4-byte aligned via `MEPC_ALIGN_MASK` on both paths.
- **Asynchronous interrupt entry.** New `trap.enter_interrupt(cause_code: u32, cpu: *Cpu)` routes per `mideleg` using the same `cpu.privilege != .M AND delegated` rule. `mcause` / `scause` get bit 31 set (interrupt flag); `mtval` / `stval` get 0 (interrupts have no fault value); otherwise mirrors `enter`. Does NOT check `mstatus.MIE` / `mstatus.SIE` — the caller (`cpu.check_interrupt`) has already applied the global-enable gate.
- **Interrupt boundary check.** New `cpu.check_interrupt(cpu: *Cpu) bool` called at the top of `cpu.step` before instruction fetch:
  1. Compute effective `mip` = `cpu.csr.mip` with bit 7 (MTIP) forced to `cpu.memory.clint.isMtipPending()`.
  2. `pending = effective_mip & cpu.csr.mie`.
  3. If `pending == 0`, return false (no trap taken).
  4. For each interrupt bit in priority order `[11, 3, 7, 9, 1, 5]` (MEI, MSI, MTI, SEI, SSI, STI): if `pending & (1 << bit)` is set, determine target privilege (S if `mideleg & (1 << bit)`, else M, with the `cpu.privilege != .M` guard); determine if deliverable at `cpu.privilege` using the spec rule (lower current privilege → always take; equal → consult `mstatus.MIE` or `mstatus.SIE`; higher → never). The first bit that passes all three gates wins.
  5. If a winner is found, call `trap.enter_interrupt(cause_code, cpu)` and return true. If none deliverable this cycle, return false.
- **CLINT `isMtipPending`.** `Clint.isMtipPending(self: *const Clint) bool` returns `self.mtimecmp != 0 and self.mtime() >= self.mtimecmp`. Per Phase 2 spec §Devices: the `mtimecmp != 0` guard avoids spurious MTIP before any software programs the timer.
- **Live `mip.MTIP` wiring in csr.** `csrReadUnchecked(CSR_MIP)` and `csrReadUnchecked(CSR_SIP)` both OR-in `(1 << 7)` when CLINT says MTIP is pending, so software observes the live hardware signal. `csrWriteUnchecked(CSR_MIP, v)` uses a new `MIP_WRITE_MASK` that excludes bit 7 — writes to MTIP are silently dropped (hardware-only signal). `sip` already excludes bit 7 on reads via `SIP_READ_MASK`, so no behavior change there. The 2.A tests that touch `mip`/`sip` with `dummy_mem: Memory = undefined` are migrated to a minimal real-Memory rig because the CSR read path now dereferences `cpu.memory.clint`.
- **`mie` and `mip` WARL masks.** `mie` gains a writable mask `MIE_MASK = SSIE|MSIE|STIE|MTIE|SEIE|MEIE = (1<<1)|(1<<3)|(1<<5)|(1<<7)|(1<<9)|(1<<11)`; writes outside this mask are dropped. `mip` gains `MIP_WRITE_MASK = SSIP|MSIP|STIP|SEIP|MEIP = (1<<1)|(1<<3)|(1<<5)|(1<<9)|(1<<11)` (MTIP bit 7 explicitly excluded — read-only from software).
- **Trace interrupt marker.** New `trace.formatInterruptMarker(writer, cause_code, from_priv, to_priv)` emits one line:
  ```
  --- interrupt N (<name>) taken in <old>, now <new> ---
  ```
  Names: 1→"supervisor software", 3→"machine software", 5→"supervisor timer", 7→"machine timer", 9→"supervisor external", 11→"machine external". `trap.enter_interrupt` calls it when `cpu.trace_writer` is set — BEFORE the privilege switch, so the marker's "old" reflects pre-interrupt privilege.
- **rv32si-p-\* coverage expansion.** `build.zig` adds `sbreak` and `ma_fetch` to the `rv32si_tests` list. Both upstream tests define `stvec_handler`; the env's `RVTEST_CODE_BEGIN` macro programs `medeleg` with `BREAKPOINT | MISALIGNED_FETCH | ...` when `stvec_handler` is defined; once `medeleg` takes effect (Task 2), these tests' S-mode trap handlers receive the delegated trap and the tests pass. `dirty` remains excluded — it exercises a 4 MiB superpage leaf, and Phase 2 permanently rejects superpages per §Sv32 translation.

**Not in Plan 2.B (explicitly):**

- Any kernel-side code (`tests/programs/kernel/`) → Plans 2.C / 2.D.
- PLIC (external interrupt controller) — Phase 3.
- SSTC extension — Phase 2 spec rejects it; no `stimecmp`/`stime`.
- Sv32 superpages — Phase 2 spec rejects them; `dirty` stays excluded.
- WFI semantics beyond "advance PC" — a real wait-for-interrupt loop could bound step cycles to the next MTIP edge, but Plan 2.B has no caller that needs it (Plan 2.D's kernel loop idles in U-mode rather than `wfi`-in-S). Revisit if a kernel test actually needs it.
- Multi-hart / `msip` inter-hart doorbells — Phase 3.
- Vectored mode `mtvec.MODE=1` / `stvec.MODE=1` — Phase 2 spec uses direct mode only.
- `ASID` tracking — `satp.ASID` stays WARL 0.
- Interrupt delivery to U-mode via `mideleg` → U (non-standard N extension) — out of scope; N extension isn't implemented.

**Deviation from Plan 2.A's closing note:** none. Plan 2.A deferred medeleg/mideleg and async interrupts to 2.B. Plan 2.B implements exactly that split; the kernel (`boot.S`, `trap.zig`, `kmain.zig`, etc.) remains deferred to 2.C.

---

## File structure (final state at end of Plan 2.B)

```
ccc/
├── .gitignore                             ← UNCHANGED
├── .gitmodules                            ← UNCHANGED
├── build.zig                              ← MODIFIED (+rv32si tests: sbreak, ma_fetch)
├── build.zig.zon                          ← UNCHANGED
├── README.md                              ← MODIFIED (status line; trace interrupt-marker note)
├── src/
│   ├── main.zig                           ← UNCHANGED
│   ├── cpu.zig                            ← MODIFIED (+medeleg, +mideleg storage; +check_interrupt; +pendingInterrupts helper; step() calls check_interrupt pre-fetch)
│   ├── memory.zig                         ← UNCHANGED
│   ├── decoder.zig                        ← UNCHANGED
│   ├── execute.zig                        ← UNCHANGED (trap.enter already handles routing)
│   ├── csr.zig                            ← MODIFIED (real medeleg/mideleg storage + masks; live MTIP on mip/sip reads; MIP_WRITE_MASK bit 7 excluded; MIE_MASK; migrate dummy_mem tests)
│   ├── trap.zig                           ← MODIFIED (delegation-aware enter; +enter_interrupt; +INTERRUPT_PRIORITY_ORDER constant)
│   ├── elf.zig                            ← UNCHANGED
│   ├── trace.zig                          ← MODIFIED (+formatInterruptMarker)
│   └── devices/
│       ├── halt.zig                       ← UNCHANGED
│       ├── uart.zig                       ← UNCHANGED
│       └── clint.zig                      ← MODIFIED (+isMtipPending)
└── tests/
    ├── programs/                          ← UNCHANGED (Phase 1 demos keep running)
    ├── riscv-tests/                       ← UNCHANGED (submodule)
    ├── riscv-tests-p.ld                   ← UNCHANGED
    ├── riscv-tests-s.ld                   ← UNCHANGED
    └── riscv-tests-shim/
        ├── riscv_test.h                   ← UNCHANGED
        └── weak_handlers.S                ← UNCHANGED
```

**Module responsibilities (deltas vs Plan 2.A):**

- **`cpu.zig`** — `CsrFile` gains two `u32` fields: `medeleg`, `mideleg`. `Cpu.step()` calls a new top-of-function helper `check_interrupt(cpu)` before the instruction fetch; if it returns true (a trap was taken), `step` skips the fetch/execute cycle and returns (a subsequent `step` call will run from the trap vector). New file-scope helpers `pendingInterrupts(cpu)` (computes effective `mip`) and `check_interrupt(cpu)` (runs the priority/delegation/gating algorithm and enters a trap if a winner exists).
- **`csr.zig`** — the 2.A `CSR_MEDELEG, CSR_MIDELEG => 0` read arm and `=> {}` write arm are replaced with masked read/write against the new `cpu.csr.medeleg` and `cpu.csr.mideleg` storage. New `MEDELEG_WRITABLE` / `MIDELEG_WRITABLE` constants define which bits are persisted. The `CSR_MIP` read arm ORs in live MTIP via `cpu.memory.clint.isMtipPending()`; the `CSR_SIP` read arm does the same (the existing `SIP_READ_MASK` already includes bit 7 in the *read* set but that doesn't matter — SSIP/STIP/SEIP view). A new `MIP_WRITE_MASK` excludes bit 7; the `CSR_MIP` write arm uses it. A new `MIE_MASK` is applied to `CSR_MIE` writes. Tests that currently use `dummy_mem: Memory = undefined` together with `CSR_MIP`/`CSR_SIP` are updated to use a shared `csrTestRig` helper holding real Halt/UART/CLINT/Memory — required because the MIP read path now dereferences `cpu.memory.clint`.
- **`trap.zig`** — `enter(cause, tval, cpu)` gains a delegation decision: compute `cause_code: u32 = @intFromEnum(cause)`, decide `target = if (cpu.privilege != .M and (cpu.csr.medeleg & (1 << cause_code)) != 0) .S else .M`; run one of two entry paths (M path identical to Plan 2.A; S path writes S-CSRs and mirrors `exit_sret`'s `SPP`/`SPIE`/`SIE` side effects in reverse). New `enter_interrupt(cause_code, cpu)` mirrors `enter` but for async: routes per `mideleg`, sets bit 31 of `mcause`/`scause`, passes `tval=0`, and emits a trace marker via `trace.formatInterruptMarker` if `cpu.trace_writer` is set. A new file-scope constant `INTERRUPT_PRIORITY_ORDER = [_]u32{ 11, 3, 7, 9, 1, 5 }` exposes the RISC-V priority order for use by `cpu.check_interrupt`.
- **`trace.zig`** — new `formatInterruptMarker(writer, cause_code, from_priv, to_priv)` emits the synthetic marker line. Names live in a local `interruptName(code)` helper returning a `[]const u8`.
- **`devices/clint.zig`** — new `isMtipPending(self: *const Clint) bool`: returns `self.mtimecmp != 0 and self.mtime() >= self.mtimecmp`.
- **`build.zig`** — the `rv32si_tests` array gains `"sbreak"` and `"ma_fetch"`. Exclusion comments for these two entries in Plan 2.A are removed; `"dirty"` retains its exclusion rationale updated to cite the Phase 2 spec's permanent no-superpage policy.
- **`README.md`** — Status section updates: "Plan 2.B merged" paragraph replaces the "next" line; trace format description gains the interrupt-marker line.

---

## Conventions used in this plan

- All Zig code targets Zig 0.16.x. Same API surface as Plan 2.A.
- Tests live as inline `test "name" { ... }` blocks alongside the code under test. `zig build test` runs every test reachable from `src/main.zig`. No new source files are introduced in 2.B, so `main.zig`'s `comptime { _ = @import(...) }` block does not change.
- Each task ends with a TDD cycle: write failing test, see it fail, implement minimally, verify pass, commit. Commit messages follow Conventional Commits.
- When extending a grouped switch (the CSR address dispatch, the priority-order array), we show the full block so diffs are unambiguous.
- RISC-V spec bit positions and cause codes are quoted inline in tests when they appear as magic numbers, so a reviewer doesn't have to cross-reference.
- All new tests exercise a single behavioral contract. Delegation tests enumerate `(privilege, cause, medeleg_bit)` triples one per test. Interrupt-priority tests enumerate one `(pending, enabled, mideleg)` configuration per test rather than table-driven — keeps failure messages pinpoint.
- Whenever a test needs a real `Memory` (for the MTIP live-read path), it uses a local `setupRig()` helper. A single copy lives in each test file that needs it; we do not extract a shared module for this (Plan 2.A's pattern).
- Task order respects strict dependencies: CSR storage lands before delegation routing that consumes it; CLINT's query lands before csr.zig reads it; trap.enter_interrupt lands before cpu.check_interrupt that calls it. This means subagents can be dispatched in strict Task N-then-N+1 order without rework.

---

## Tasks

### Task 1: Add `medeleg` and `mideleg` fields to `CsrFile`

**Files:**
- Modify: `src/cpu.zig` (the `CsrFile` struct)
- Modify: `src/cpu.zig` (new test)

**Why this task first:** We can't route traps to S-mode without somewhere to read the delegation register from. Adding the fields before touching the read/write paths ensures the fields compile and default to zero, which preserves the Plan 2.A "no delegation" behavior until Task 2 turns delegation on.

- [ ] **Step 1: Write a failing test that asserts medeleg/mideleg storage exists on a default `Cpu`**

Append to `src/cpu.zig` tests section (after the last existing test):

```zig
test "CsrFile default has zero medeleg and mideleg" {
    var dummy_mem: Memory = undefined;
    const cpu = Cpu.init(&dummy_mem, 0);
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.medeleg);
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.mideleg);
}
```

- [ ] **Step 2: Run the test to verify it fails (compile error)**

Run: `zig build test`

Expected: compile error — `no field named 'medeleg' in struct 'CsrFile'`.

- [ ] **Step 3: Add `medeleg` and `mideleg` to `CsrFile`**

Modify `src/cpu.zig`. Locate `CsrFile` (around line 39 of Plan 2.A's final state) and add two fields. The placement is immediately after `mip` since they're in the same M-mode trap/interrupt CSR family:

```zig
pub const CsrFile = struct {
    // mstatus — split into per-field storage (Plan 2.A Task 2)
    mstatus_sie: bool = false,
    mstatus_mie: bool = false,
    mstatus_spie: bool = false,
    mstatus_mpie: bool = false,
    mstatus_spp: u1 = 0,
    mstatus_mpp: u2 = 0,
    mstatus_mprv: bool = false,
    mstatus_sum: bool = false,
    mstatus_mxr: bool = false,
    mstatus_tvm: bool = false,
    mstatus_tsr: bool = false,
    // M-mode trap/interrupt CSRs
    mtvec: u32 = 0,
    mepc: u32 = 0,
    mcause: u32 = 0,
    mtval: u32 = 0,
    mie: u32 = 0,
    mip: u32 = 0,
    // Plan 2.B: trap delegation registers. Controlled by M; read by trap
    // routing logic in trap.zig and the interrupt boundary check in
    // cpu.check_interrupt. WARL-masked by csr.zig per the Phase 2 spec.
    medeleg: u32 = 0,
    mideleg: u32 = 0,
    // ... rest of struct unchanged (mscratch, mcounteren, scounteren,
    //     stvec, sscratch, sepc, scause, stval, satp)
    mscratch: u32 = 0,
    mcounteren: u32 = 0,
    scounteren: u32 = 0,
    stvec: u32 = 0,
    sscratch: u32 = 0,
    sepc: u32 = 0,
    scause: u32 = 0,
    stval: u32 = 0,
    satp: u32 = 0,
};
```

Only the two new lines and their comment are added. All other fields keep their position and default values.

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/cpu.zig
git commit -m "feat: add medeleg/mideleg storage to CsrFile (Plan 2.B Task 1)"
```

---

### Task 2: Replace the `medeleg` / `mideleg` CSR stub with masked read/write

**Files:**
- Modify: `src/csr.zig` (WARL mask constants near the top; new behavior in `csrReadUnchecked` / `csrWriteUnchecked`; existing 2.A stub test removed/rewritten)

**Why this task:** The 2.A comment on medeleg/mideleg said "Phase 1 has no S-mode, so delegation is meaningless. We implement them as read-as-zero / write-ignored so code that touches them (rv32mi tests, future kernel init) doesn't trap." That comment is now stale — Phase 2.A introduced S-mode, and Plan 2.B needs real delegation semantics. This task replaces the stub with WARL-masked storage, keeping reads/writes legal from M and illegal below M (the existing `checkAccess` privilege gate still applies).

- [ ] **Step 1: Write four failing tests covering the new WARL masks**

Append to `src/csr.zig` tests section (after the existing `"medeleg / mideleg read as zero and swallow writes (no trap)"` test — we'll delete that in Step 3):

```zig
test "medeleg round-trips Phase 2 delegatable bits" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    // Bits we allow: 0 (inst misaligned), 2 (illegal), 3 (breakpoint),
    // 4 (load misaligned), 6 (store misaligned), 8 (ECALL from U),
    // 12/13/15 (page faults).
    const delegatable: u32 =
        (1 << 0) | (1 << 2) | (1 << 3) | (1 << 4) |
        (1 << 6) | (1 << 8) | (1 << 12) | (1 << 13) | (1 << 15);
    try csrWrite(&cpu, CSR_MEDELEG, delegatable);
    try std.testing.expectEqual(delegatable, try csrRead(&cpu, CSR_MEDELEG));
}

test "medeleg masks out ECALL_FROM_M (bit 11) and reserved bits" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MEDELEG, 0xFFFF_FFFF);
    const v = try csrRead(&cpu, CSR_MEDELEG);
    // bit 11 (ECALL_FROM_M) must be zero — M traps cannot be delegated.
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 11));
    // bit 9 (ECALL_FROM_S) — Phase 2 spec: not delegated; hardwired 0 here.
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 9));
    // Bits we allow round-trip to 1.
    try std.testing.expect((v & (1 << 0)) != 0);
    try std.testing.expect((v & (1 << 8)) != 0);
    try std.testing.expect((v & (1 << 12)) != 0);
}

test "mideleg round-trips SSIP/STIP/SEIP" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    const delegatable_ints: u32 = (1 << 1) | (1 << 5) | (1 << 9);
    try csrWrite(&cpu, CSR_MIDELEG, delegatable_ints);
    try std.testing.expectEqual(delegatable_ints, try csrRead(&cpu, CSR_MIDELEG));
}

test "mideleg masks out MSIP/MTIP/MEIP" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MIDELEG, 0xFFFF_FFFF);
    const v = try csrRead(&cpu, CSR_MIDELEG);
    // M-level interrupt bits must be zero — M interrupts cannot be delegated.
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 3));  // MSIP
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 7));  // MTIP
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 11)); // MEIP
    // S-level interrupt bits round-trip.
    try std.testing.expect((v & (1 << 1)) != 0); // SSIP
    try std.testing.expect((v & (1 << 5)) != 0); // STIP
    try std.testing.expect((v & (1 << 9)) != 0); // SEIP
}
```

- [ ] **Step 2: Run the tests — two fail (the new read returns 0, not the masked value)**

Run: `zig build test`

Expected: the two "round-trips" tests fail with "expected 0x... got 0"; the two "masks out" tests happen to pass (because the stub returns 0 and 0 matches the masked expectations — coincidence, not correctness).

- [ ] **Step 3: Add WARL mask constants and replace the stub**

Modify `src/csr.zig`. Add after the existing `MTVEC_*` constants (around the same block where CSR addresses live):

```zig
// medeleg WARL mask — bits that correspond to delegatable synchronous
// exception causes in our Phase 2 subset. ECALL_FROM_S (bit 9) and
// ECALL_FROM_M (bit 11) are deliberately excluded: the Phase 2 spec
// routes these to M-mode with no delegation. Reserved bits (10, 14, 16+)
// are also excluded to keep the register deterministic.
pub const MEDELEG_WRITABLE: u32 =
    (1 << 0)  | // inst addr misaligned
    (1 << 2)  | // illegal instruction
    (1 << 3)  | // breakpoint
    (1 << 4)  | // load addr misaligned
    (1 << 6)  | // store addr misaligned
    (1 << 8)  | // ECALL from U
    (1 << 12) | // inst page fault
    (1 << 13) | // load page fault
    (1 << 15);  // store/AMO page fault

// mideleg WARL mask — only S-level interrupt bits. M-level interrupts
// (MSIP=3, MTIP=7, MEIP=11) cannot be delegated (spec §3.1.9).
pub const MIDELEG_WRITABLE: u32 =
    (1 << 1) | // SSIP
    (1 << 5) | // STIP
    (1 << 9);  // SEIP
```

Now locate the 2.A stub in `csrReadUnchecked`:

```zig
        CSR_MEDELEG, CSR_MIDELEG => 0,
```

Replace with two separate arms:

```zig
        CSR_MEDELEG => cpu.csr.medeleg,
        CSR_MIDELEG => cpu.csr.mideleg,
```

Locate the 2.A stub in `csrWriteUnchecked`:

```zig
        // medeleg / mideleg: writes ignored (we report no S-mode, so
        // delegation has no effect). Reads return 0.
        CSR_MEDELEG, CSR_MIDELEG => {},
```

Replace with masked writes:

```zig
        // medeleg / mideleg: WARL — store only the bits Plan 2.B permits.
        // See MEDELEG_WRITABLE / MIDELEG_WRITABLE comments above for the
        // rationale behind each included/excluded bit.
        CSR_MEDELEG => cpu.csr.medeleg = value & MEDELEG_WRITABLE,
        CSR_MIDELEG => cpu.csr.mideleg = value & MIDELEG_WRITABLE,
```

Delete the 2.A test that is now contradicted:

```zig
test "medeleg / mideleg read as zero and swallow writes (no trap)" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MEDELEG, 0xFFFF_FFFF);
    try csrWrite(&cpu, CSR_MIDELEG, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), try csrRead(&cpu, CSR_MEDELEG));
    try std.testing.expectEqual(@as(u32, 0), try csrRead(&cpu, CSR_MIDELEG));
}
```

Also update the explanatory comment block above `CSR_MEDELEG` in the CSR-address constants section. The old comment was:

```zig
// medeleg / mideleg: M-mode exception/interrupt delegation to S-mode.
// Phase 1 has no S-mode, so delegation is meaningless. We implement them
// as read-as-zero / write-ignored so code that touches them (rv32mi tests,
// future kernel init) doesn't trap.
```

Replace with:

```zig
// medeleg / mideleg: M-mode exception/interrupt delegation to S-mode.
// Plan 2.B turns these into first-class WARL registers — see
// MEDELEG_WRITABLE / MIDELEG_WRITABLE for the set of persisted bits.
// Storage lives in cpu.csr.medeleg / cpu.csr.mideleg (cpu.zig).
```

- [ ] **Step 4: Run all csr tests**

Run: `zig build test`

Expected: all tests pass, including the four new ones. The old "read as zero and swallow writes" test is gone — its expectations are now wrong.

- [ ] **Step 5: Commit**

```bash
git add src/csr.zig
git commit -m "feat: wire medeleg/mideleg to real WARL-masked storage (Plan 2.B Task 2)"
```

---

### Task 3: Make `trap.enter` delegation-aware for synchronous exceptions

**Files:**
- Modify: `src/trap.zig` (the `enter` function)
- Modify: `src/trap.zig` (new tests: delegation to S; no-delegation stays at M; M-mode never delegates; etc.)

**Why this task:** This is the core routing change for 2.B's synchronous side. Every synchronous trap path — ECALL, illegal instruction, page fault, misaligned, etc. — already funnels through `trap.enter`. Adding the delegation decision here fixes all of them at once.

- [ ] **Step 1: Write five failing tests covering the new delegation behavior**

Append to `src/trap.zig` tests section:

```zig
test "enter from U with delegated cause routes to S (sepc, scause, stval, stvec)" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0100);
    cpu.privilege = .U;
    cpu.csr.mtvec = 0x8000_0400;
    cpu.csr.stvec = 0x8000_0500;
    cpu.csr.mstatus_sie = true;
    cpu.csr.medeleg = 1 << @intFromEnum(Cause.ecall_from_u); // bit 8

    enter(.ecall_from_u, 0, &cpu);

    // S-mode entry CSRs got written.
    try std.testing.expectEqual(@as(u32, 0x8000_0100), cpu.csr.sepc);
    try std.testing.expectEqual(@intFromEnum(Cause.ecall_from_u), cpu.csr.scause);
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.stval);
    // Privilege ← S, PC ← stvec.BASE (direct mode only).
    try std.testing.expectEqual(PrivilegeMode.S, cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0500), cpu.pc);
    // sstatus transition: SPP ← U (0), SPIE ← old SIE (true), SIE ← 0.
    try std.testing.expectEqual(@as(u1, 0), cpu.csr.mstatus_spp);
    try std.testing.expect(cpu.csr.mstatus_spie);
    try std.testing.expect(!cpu.csr.mstatus_sie);
    // M-mode CSRs untouched.
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.mepc);
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.mcause);
}

test "enter from S with delegated cause routes to S, SPP=S" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0200);
    cpu.privilege = .S;
    cpu.csr.stvec = 0x8000_0600;
    cpu.csr.medeleg = 1 << @intFromEnum(Cause.breakpoint); // bit 3
    cpu.csr.mstatus_sie = true;

    enter(.breakpoint, 0, &cpu);

    try std.testing.expectEqual(PrivilegeMode.S, cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0600), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x8000_0200), cpu.csr.sepc);
    // SPP ← S (coming from S).
    try std.testing.expectEqual(@as(u1, 1), cpu.csr.mstatus_spp);
}

test "enter from U without delegation routes to M (baseline)" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0100);
    cpu.privilege = .U;
    cpu.csr.mtvec = 0x8000_0400;
    cpu.csr.medeleg = 0; // nothing delegated

    enter(.ecall_from_u, 0, &cpu);

    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0400), cpu.pc);
    try std.testing.expectEqual(@intFromEnum(Cause.ecall_from_u), cpu.csr.mcause);
    // S-mode CSRs untouched.
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.scause);
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.sepc);
}

test "enter from M never delegates even if medeleg bit is set" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0300);
    cpu.privilege = .M;
    cpu.csr.mtvec = 0x8000_0700;
    cpu.csr.stvec = 0x8000_0800;
    cpu.csr.medeleg = 0xFFFF_FFFF;

    enter(.illegal_instruction, 0xDEAD_BEEF, &cpu);

    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0700), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), cpu.csr.mtval);
}

test "enter with delegation clears reservation and sets trap_taken" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0100);
    cpu.privilege = .U;
    cpu.reservation = 0x8000_0500;
    cpu.csr.medeleg = 1 << 8;

    enter(.ecall_from_u, 0, &cpu);

    try std.testing.expect(cpu.reservation == null);
    try std.testing.expect(cpu.trap_taken);
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `zig build test`

Expected: the first two tests fail (trap still goes to M); the third passes (baseline already works); the fourth passes (M never delegated anyway); the fifth passes (reservation clearing is already there). So: 2 new tests fail, 3 pass.

- [ ] **Step 3: Rewrite `enter` to route per `medeleg`**

Replace the existing body of `enter` in `src/trap.zig` with the delegation-aware version. Show the full function for reviewability:

```zig
/// Take a synchronous trap. Implements spec §Trap entry and §Exception
/// delegation (§3.1.9).
///
/// Routing:
///   if cpu.privilege != .M AND (medeleg >> cause_code) & 1 == 1
///     → target = S; write S-CSRs; privilege ← S; pc ← stvec.BASE
///   else
///     → target = M; write M-CSRs; privilege ← M; pc ← mtvec.BASE
///
/// Both paths:
///   - capture the trapping PC (mepc/sepc ← cpu.pc, 4-byte aligned)
///   - store cause and tval
///   - save previous interrupt-enable and previous privilege into the
///     target privilege's mstatus fields (MPP/MPIE/MIE for M,
///     SPP/SPIE/SIE for S)
///   - clear the target privilege's IE bit
///   - clear cpu.reservation (LR/SC invariant; trap handlers may run
///     arbitrary code)
///   - set cpu.trap_taken = true for the halt-on-trap check
pub fn enter(cause: Cause, tval: u32, cpu: *Cpu) void {
    const cause_code: u32 = @intFromEnum(cause);
    const delegated = (cpu.csr.medeleg >> @intCast(cause_code)) & 1 == 1;
    const target: PrivilegeMode = if (cpu.privilege != .M and delegated) .S else .M;

    switch (target) {
        .M => {
            cpu.csr.mepc = cpu.pc & csr.MEPC_ALIGN_MASK;
            cpu.csr.mcause = cause_code;
            cpu.csr.mtval = tval;
            cpu.csr.mstatus_mpp = @intFromEnum(cpu.privilege);
            cpu.csr.mstatus_mpie = cpu.csr.mstatus_mie;
            cpu.csr.mstatus_mie = false;
            cpu.privilege = .M;
            cpu.pc = cpu.csr.mtvec & csr.MTVEC_BASE_MASK;
        },
        .S => {
            cpu.csr.sepc = cpu.pc & csr.MEPC_ALIGN_MASK;
            cpu.csr.scause = cause_code;
            cpu.csr.stval = tval;
            // SPP is a 1-bit field: 1 = S, 0 = U. M cannot reach here
            // (target == .S requires cpu.privilege != .M).
            cpu.csr.mstatus_spp = if (cpu.privilege == .S) 1 else 0;
            cpu.csr.mstatus_spie = cpu.csr.mstatus_sie;
            cpu.csr.mstatus_sie = false;
            cpu.privilege = .S;
            cpu.pc = cpu.csr.stvec & csr.MTVEC_BASE_MASK;
        },
        else => unreachable, // U cannot be a trap target; reserved_h is CSR-clamped out
    }
    cpu.reservation = null;
    cpu.trap_taken = true;
}
```

Note: the `else => unreachable` arm is defensive — U/reserved_h would be a logic bug (the if/else above only produces .M or .S).

- [ ] **Step 4: Run all tests including existing ones**

Run: `zig build test`

Expected: all trap tests pass; all Phase 1 ecall/mret/trap tests still pass (medeleg defaults to 0, so delegation is silent); all execute.zig ECALL tests still pass (their `ECALL from S-mode traps with mcause=9` assertion remains valid because that test doesn't set medeleg).

- [ ] **Step 5: Commit**

```bash
git add src/trap.zig
git commit -m "feat: trap.enter routes delegated exceptions to S-mode (Plan 2.B Task 3)"
```

---

### Task 4: Add `trap.enter_interrupt` for asynchronous delivery

**Files:**
- Modify: `src/trap.zig` (new `enter_interrupt` function; new `INTERRUPT_PRIORITY_ORDER` constant)
- Modify: `src/trap.zig` (new tests)

**Why this task:** Async interrupts have almost-identical entry semantics to sync exceptions, but with two differences: bit 31 of `scause`/`mcause` is set, and the `mideleg` register is consulted instead of `medeleg`. Keeping the async path in a separate function (instead of threading an `is_interrupt` flag through `enter`) keeps the sync path trivial and lets the async path emit its trace marker in isolation.

- [ ] **Step 1: Write four failing tests for `enter_interrupt`**

Append to `src/trap.zig` tests section:

```zig
test "enter_interrupt from U, SSIP delegated, routes to S with interrupt flag" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0100);
    cpu.privilege = .U;
    cpu.csr.stvec = 0x8000_0500;
    cpu.csr.mideleg = 1 << 1; // delegate SSIP

    enter_interrupt(1, &cpu); // cause code 1 = supervisor software

    try std.testing.expectEqual(PrivilegeMode.S, cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0500), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x8000_0100), cpu.csr.sepc);
    try std.testing.expectEqual(@as(u32, 0x8000_0001), cpu.csr.scause); // bit 31 | 1
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.stval);
}

test "enter_interrupt from S, MTIP not delegated, routes to M" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0300);
    cpu.privilege = .S;
    cpu.csr.mtvec = 0x8000_0700;
    cpu.csr.mideleg = 0; // MTIP cannot be delegated anyway, but set to zero explicitly

    enter_interrupt(7, &cpu); // cause code 7 = machine timer

    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0700), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x8000_0007), cpu.csr.mcause); // bit 31 | 7
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.mtval);
    try std.testing.expectEqual(@as(u2, @intFromEnum(PrivilegeMode.S)), cpu.csr.mstatus_mpp);
}

test "enter_interrupt from M stays in M regardless of mideleg" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0400);
    cpu.privilege = .M;
    cpu.csr.mtvec = 0x8000_0800;
    cpu.csr.mideleg = (1 << 1) | (1 << 5) | (1 << 9); // all S-int delegated

    enter_interrupt(1, &cpu); // even though mideleg[1]=1, M never delegates

    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0800), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x8000_0001), cpu.csr.mcause);
}

test "INTERRUPT_PRIORITY_ORDER spans MEI MSI MTI SEI SSI STI in spec order" {
    try std.testing.expectEqual(@as(usize, 6), INTERRUPT_PRIORITY_ORDER.len);
    try std.testing.expectEqual(@as(u32, 11), INTERRUPT_PRIORITY_ORDER[0]); // MEI
    try std.testing.expectEqual(@as(u32, 3),  INTERRUPT_PRIORITY_ORDER[1]); // MSI
    try std.testing.expectEqual(@as(u32, 7),  INTERRUPT_PRIORITY_ORDER[2]); // MTI
    try std.testing.expectEqual(@as(u32, 9),  INTERRUPT_PRIORITY_ORDER[3]); // SEI
    try std.testing.expectEqual(@as(u32, 1),  INTERRUPT_PRIORITY_ORDER[4]); // SSI
    try std.testing.expectEqual(@as(u32, 5),  INTERRUPT_PRIORITY_ORDER[5]); // STI
}
```

- [ ] **Step 2: Run the tests to confirm compile error then failure**

Run: `zig build test`

Expected: compile error — `no declaration 'enter_interrupt'` and `no declaration 'INTERRUPT_PRIORITY_ORDER'`.

- [ ] **Step 3: Implement `enter_interrupt` and the priority constant**

Add to `src/trap.zig` at the top of the file, after the existing `pub const Cause = enum` block and before `pub fn enter`:

```zig
/// Spec-mandated interrupt priority order (RISC-V privileged spec §3.1.9).
/// Higher indices earlier in the array lose to lower indices. Used by
/// cpu.check_interrupt to pick which pending+enabled+deliverable bit wins.
/// Cause codes: MEI=11, MSI=3, MTI=7, SEI=9, SSI=1, STI=5.
pub const INTERRUPT_PRIORITY_ORDER = [_]u32{ 11, 3, 7, 9, 1, 5 };

/// Interrupt-cause bit 31 marker per RISC-V spec: scause/mcause have the
/// high bit set to 1 for async interrupts, 0 for synchronous exceptions.
pub const INTERRUPT_CAUSE_FLAG: u32 = 1 << 31;
```

Add after `pub fn enter`:

```zig
/// Take an asynchronous interrupt. Mirrors `enter` but:
///   - `cause_code` is the bare interrupt cause (0..15); bit 31 is set
///     in the scause/mcause write.
///   - consults `mideleg` instead of `medeleg`.
///   - `mtval` / `stval` are always written 0 (interrupts have no fault
///     value in the RV32 privileged spec).
///   - emits a trace marker if `cpu.trace_writer` is set, BEFORE the
///     privilege switch so the marker reflects the pre-interrupt state.
///
/// The caller (cpu.check_interrupt) is expected to have already gated
/// on mstatus.MIE / mstatus.SIE per the current privilege mode; this
/// function does not re-check those bits.
pub fn enter_interrupt(cause_code: u32, cpu: *Cpu) void {
    const delegated = (cpu.csr.mideleg >> @intCast(cause_code)) & 1 == 1;
    const target: PrivilegeMode = if (cpu.privilege != .M and delegated) .S else .M;
    const cause_reg = INTERRUPT_CAUSE_FLAG | cause_code;
    const from_priv = cpu.privilege;

    if (cpu.trace_writer) |tw| {
        @import("trace.zig").formatInterruptMarker(tw, cause_code, from_priv, target) catch {};
    }

    switch (target) {
        .M => {
            cpu.csr.mepc = cpu.pc & csr.MEPC_ALIGN_MASK;
            cpu.csr.mcause = cause_reg;
            cpu.csr.mtval = 0;
            cpu.csr.mstatus_mpp = @intFromEnum(cpu.privilege);
            cpu.csr.mstatus_mpie = cpu.csr.mstatus_mie;
            cpu.csr.mstatus_mie = false;
            cpu.privilege = .M;
            cpu.pc = cpu.csr.mtvec & csr.MTVEC_BASE_MASK;
        },
        .S => {
            cpu.csr.sepc = cpu.pc & csr.MEPC_ALIGN_MASK;
            cpu.csr.scause = cause_reg;
            cpu.csr.stval = 0;
            cpu.csr.mstatus_spp = if (cpu.privilege == .S) 1 else 0;
            cpu.csr.mstatus_spie = cpu.csr.mstatus_sie;
            cpu.csr.mstatus_sie = false;
            cpu.privilege = .S;
            cpu.pc = cpu.csr.stvec & csr.MTVEC_BASE_MASK;
        },
        else => unreachable,
    }
    cpu.reservation = null;
    cpu.trap_taken = true;
}
```

Note on `trace.formatInterruptMarker`: Task 10 adds this function. Until then, this call will fail to compile. We'll add a forward-declared stub in Task 5's preamble if Task 10 can't land first — but the natural order is to lock in `enter_interrupt` before the marker. To sequence cleanly, the trace-marker call lives behind `if (cpu.trace_writer)` — we can temporarily add a `no-op stub` in trace.zig as part of this task that Task 10 replaces with the real formatter. Concrete sequencing: in Step 3 of THIS task, add the stub.

Add this stub to `src/trace.zig` (place it after the existing `formatInstr`):

```zig
/// Plan 2.B Task 10 replaces this with the real formatter.
pub fn formatInterruptMarker(
    _: *std.Io.Writer,
    _: u32,
    _: PrivilegeMode,
    _: PrivilegeMode,
) !void {}
```

Task 10 will replace the body and add tests.

- [ ] **Step 4: Run the tests**

Run: `zig build test`

Expected: all four new tests pass; all existing tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/trap.zig src/trace.zig
git commit -m "feat: add trap.enter_interrupt and priority constants (Plan 2.B Task 4)"
```

---

### Task 5: Add `Clint.isMtipPending`

**Files:**
- Modify: `src/devices/clint.zig` (new `isMtipPending` method)
- Modify: `src/devices/clint.zig` (new tests)

**Why this task:** The whole async timer path hinges on this query. It's also trivially testable in isolation using the existing `fixtureClock` infrastructure — we lock in the behavior before layering the CSR read path and the CPU check on top.

- [ ] **Step 1: Write three failing tests for `isMtipPending`**

Append to `src/devices/clint.zig` tests section (after the existing `"writing mtime is silently dropped (Phase 1)"` test):

```zig
test "isMtipPending: returns false when mtimecmp is zero (Phase 2 guard)" {
    fixture_clock_ns = 1_000_000; // mtime = 10_000 ticks
    var c = Clint.init(&fixtureClock);
    // Default mtimecmp = 0 → spec says MTIP stays clear.
    try std.testing.expect(!c.isMtipPending());
}

test "isMtipPending: false when mtime < mtimecmp, true when mtime >= mtimecmp" {
    fixture_clock_ns = 0;
    var c = Clint.init(&fixtureClock);
    // Set mtimecmp = 100 ticks.
    try c.writeByte(0x4000, 100);
    try c.writeByte(0x4001, 0);
    try c.writeByte(0x4002, 0);
    try c.writeByte(0x4003, 0);
    try c.writeByte(0x4004, 0);
    try c.writeByte(0x4005, 0);
    try c.writeByte(0x4006, 0);
    try c.writeByte(0x4007, 0);
    // mtime = 0 → not pending.
    try std.testing.expect(!c.isMtipPending());
    // Advance clock: 100 ticks × 100 ns/tick = 10_000 ns → mtime = 100.
    fixture_clock_ns = 10_000;
    try std.testing.expect(c.isMtipPending());
    // Advance further: strictly > mtimecmp also pending.
    fixture_clock_ns = 20_000;
    try std.testing.expect(c.isMtipPending());
}

test "isMtipPending: becomes false again after mtimecmp is moved past mtime" {
    fixture_clock_ns = 0;
    var c = Clint.init(&fixtureClock);
    try c.writeByte(0x4000, 50);
    fixture_clock_ns = 10_000;   // mtime = 100 ticks > mtimecmp = 50
    try std.testing.expect(c.isMtipPending());
    // Reprogram mtimecmp to 200 — the standard "ack timer" move.
    try c.writeByte(0x4000, 200);
    try std.testing.expect(!c.isMtipPending());
}
```

- [ ] **Step 2: Run the tests — they fail (method doesn't exist)**

Run: `zig build test`

Expected: compile error — `no field or member function named 'isMtipPending' in type 'Clint'`.

- [ ] **Step 3: Implement `isMtipPending`**

Add to `src/devices/clint.zig` inside the `Clint` struct, placed right after the `mtime` private method (around line 54 of the current file):

```zig
/// Returns true when the CLINT's MTIP output line is asserted. Per Phase 2
/// spec §Devices: `mip.MTIP` is raised when `mtime >= mtimecmp` AND
/// `mtimecmp != 0`. The `mtimecmp != 0` guard avoids spurious MTIP before
/// any software programs the timer (both registers start at 0, so without
/// the guard `0 >= 0` would fire forever).
pub fn isMtipPending(self: *const Clint) bool {
    if (self.mtimecmp == 0) return false;
    return self.mtime() >= self.mtimecmp;
}
```

- [ ] **Step 4: Run the tests**

Run: `zig build test`

Expected: all three new tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/devices/clint.zig
git commit -m "feat: add Clint.isMtipPending query (Plan 2.B Task 5)"
```

---

### Task 6: Wire live `mip.MTIP` into `csrRead` for `CSR_MIP` and `CSR_SIP`; mask bit 7 on `csrWrite(MIP)`

**Files:**
- Modify: `src/csr.zig` (`csrReadUnchecked` arms for `CSR_MIP` and `CSR_SIP`; `csrWriteUnchecked` arm for `CSR_MIP`; new `MIP_WRITE_MASK` constant)
- Modify: `src/csr.zig` (migrate the two existing `dummy_mem`-based sip/mip tests to a real-Memory rig; add new tests)

**Why this task:** Software observing `mip.MTIP` must see the live hardware signal; software writes to MTIP must be silently dropped (MTIP is a hardware-driven pending bit). Once this task lands, task 7 (interrupt boundary check) can consume `pendingInterrupts(cpu)` knowing it returns the authoritative `mip` value.

- [ ] **Step 1: Add `MIP_WRITE_MASK` constant**

Add to `src/csr.zig` near the existing mask constants (after `SIP_WRITE_MASK`):

```zig
// mip write mask: MTIP (bit 7) is a hardware-driven read-only bit; writes
// to it from software are silently dropped. MEIP (bit 11) and SEIP (bit 9)
// are platform-driven (PLIC writes through dedicated APIs, not plain CSR
// writes); we permit software writes to them since Phase 2 has no PLIC and
// tests sometimes inject SEIP by hand. MSIP (bit 3), SSIP (bit 1), and
// STIP (bit 5) are software-writable per spec.
pub const MIP_WRITE_MASK: u32 =
    (1 << 1)  | // SSIP
    (1 << 3)  | // MSIP
    (1 << 5)  | // STIP
    (1 << 9)  | // SEIP
    (1 << 11);  // MEIP
```

- [ ] **Step 2: Write three failing tests**

Append to `src/csr.zig` tests section:

```zig
test "CSR_MIP read reflects live MTIP from CLINT when pending" {
    var rig = try csrRigWithMtimecmp(50);
    defer rig.deinit();
    // CLINT's mtimecmp = 50, mtime advances under fixture clock.
    clint_dev.fixture_clock_ns = 10_000; // mtime = 100 > mtimecmp
    const v = try csrRead(&rig.cpu, CSR_MIP);
    try std.testing.expect((v & (1 << 7)) != 0); // MTIP set
}

test "CSR_MIP read: MTIP stays clear when CLINT says not pending" {
    var rig = try csrRigWithMtimecmp(50);
    defer rig.deinit();
    clint_dev.fixture_clock_ns = 0; // mtime = 0 < mtimecmp
    const v = try csrRead(&rig.cpu, CSR_MIP);
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 7));
}

test "CSR_MIP write masks out MTIP (bit 7 is read-only)" {
    var rig = try csrRigWithMtimecmp(0);
    defer rig.deinit();
    // Try to write MTIP — must be silently dropped.
    try csrWrite(&rig.cpu, CSR_MIP, (1 << 7) | (1 << 1));
    // Storage should reflect only SSIP (bit 1), not MTIP (bit 7).
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.csr.mip & (1 << 7));
    try std.testing.expectEqual(@as(u32, 1 << 1), rig.cpu.csr.mip & (1 << 1));
}
```

Append the helper to `src/csr.zig` tests section (place this before the three new tests):

```zig
const mem_mod_test = @import("memory.zig");
const halt_dev = @import("devices/halt.zig");
const uart_dev = @import("devices/uart.zig");
const clint_dev = @import("devices/clint.zig");

/// Test rig that stands up a fully-wired Cpu + Memory + CLINT, needed by
/// any CSR test that hits the MIP / SIP live-MTIP read path. The Phase 2.A
/// `var dummy_mem: Memory = undefined` shorthand is insufficient once csr.zig
/// dereferences `cpu.memory.clint` inside csrReadUnchecked.
const CsrRig = struct {
    halt: halt_dev.Halt,
    aw: std.Io.Writer.Allocating,
    uart: uart_dev.Uart,
    clint: clint_dev.Clint,
    mem: mem_mod_test.Memory,
    cpu: Cpu,

    fn deinit(self: *CsrRig) void {
        self.mem.deinit();
        self.aw.deinit();
    }
};

fn csrRigWithMtimecmp(mtimecmp: u64) !CsrRig {
    clint_dev.fixture_clock_ns = 0;
    var rig: CsrRig = undefined;
    rig.halt = halt_dev.Halt.init();
    rig.aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    rig.uart = uart_dev.Uart.init(&rig.aw.writer);
    rig.clint = clint_dev.Clint.init(&clint_dev.fixtureClock);
    rig.clint.mtimecmp = mtimecmp;
    rig.mem = try mem_mod_test.Memory.init(
        std.testing.allocator, &rig.halt, &rig.uart, &rig.clint, null,
        mem_mod_test.RAM_SIZE_DEFAULT,
    );
    rig.cpu = Cpu.init(&rig.mem, 0);
    return rig;
}
```

- [ ] **Step 3: Run the tests — they fail**

Run: `zig build test`

Expected: the two MTIP-live tests fail (bit 7 always zero because csr.zig doesn't consult CLINT). The write-mask test also fails (MTIP bit 7 gets stored).

- [ ] **Step 4: Update `csrReadUnchecked` MIP/SIP arms**

Locate `CSR_MIP` and `CSR_SIP` arms in `csrReadUnchecked` (around line 149/184 in the current file). Replace with:

```zig
        CSR_SIP => blk: {
            var v = cpu.csr.mip;
            if (cpu.memory.clint.isMtipPending()) v |= 1 << 7;
            break :blk v & SIP_READ_MASK;
        },
        // ... other arms unchanged ...
        CSR_MIP => blk: {
            var v = cpu.csr.mip;
            if (cpu.memory.clint.isMtipPending()) v |= 1 << 7;
            break :blk v;
        },
```

(The two arms stay at their current positions in the switch; only the expression on the right side changes.)

- [ ] **Step 5: Update `csrWriteUnchecked` MIP arm to apply `MIP_WRITE_MASK`**

Locate `CSR_MIP => cpu.csr.mip = value,` around line 245 in the current file. Replace with:

```zig
        // MTIP (bit 7) is hardware-read-only in the Phase 2 model; other
        // bits follow the standard spec's software-writability rules via
        // MIP_WRITE_MASK.
        CSR_MIP => cpu.csr.mip =
            (cpu.csr.mip & ~MIP_WRITE_MASK) | (value & MIP_WRITE_MASK),
```

- [ ] **Step 6: Migrate the two existing Phase 2.A mip/sip tests that used `dummy_mem`**

The Plan 2.A tests `"sip reads SSIP/STIP/SEIP from mip"` and `"sip writes only SSIP into mip"` dereference `cpu.memory.clint` indirectly now via the MIP read path. Convert both to use the rig.

Find and delete:

```zig
test "sip reads SSIP/STIP/SEIP from mip" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MIP, (1 << 1) | (1 << 5) | (1 << 9));
    const s = try csrRead(&cpu, CSR_SIP);
    try std.testing.expectEqual(@as(u32, (1 << 1) | (1 << 5) | (1 << 9)), s);
}

test "sip writes only SSIP into mip" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MIP, (1 << 7) | (1 << 5)); // M-only + STIP
    try csrWrite(&cpu, CSR_SIP, 0xFFFF_FFFF);
    const m = try csrRead(&cpu, CSR_MIP);
    try std.testing.expect((m & (1 << 7)) != 0); // MTIP preserved
    try std.testing.expect((m & (1 << 5)) != 0); // STIP preserved (not S-writable via sip)
    try std.testing.expect((m & (1 << 1)) != 0); // SSIP set by sip write
    try std.testing.expect((m & (1 << 9)) == 0); // SEIP NOT set (not in sip write-mask)
}
```

Replace with:

```zig
test "sip reads SSIP/STIP/SEIP from mip (rig)" {
    var rig = try csrRigWithMtimecmp(0);
    defer rig.deinit();
    try csrWrite(&rig.cpu, CSR_MIP, (1 << 1) | (1 << 5) | (1 << 9));
    const s = try csrRead(&rig.cpu, CSR_SIP);
    try std.testing.expectEqual(@as(u32, (1 << 1) | (1 << 5) | (1 << 9)), s);
}

test "sip writes only SSIP into mip (rig)" {
    var rig = try csrRigWithMtimecmp(0);
    defer rig.deinit();
    // Pre-populate STIP via the M-mode path (MTIP=bit7 is now read-only,
    // so the Phase 2.A test's "MTIP preserved" assertion is dropped —
    // Plan 2.B's semantics are: MTIP is NEVER in cpu.csr.mip).
    try csrWrite(&rig.cpu, CSR_MIP, 1 << 5);
    try csrWrite(&rig.cpu, CSR_SIP, 0xFFFF_FFFF);
    const m = try csrRead(&rig.cpu, CSR_MIP);
    try std.testing.expect((m & (1 << 7)) == 0); // MTIP always clear when CLINT not pending
    try std.testing.expect((m & (1 << 5)) != 0); // STIP preserved (not S-writable via sip)
    try std.testing.expect((m & (1 << 1)) != 0); // SSIP set by sip write
    try std.testing.expect((m & (1 << 9)) == 0); // SEIP NOT set (not in sip write-mask)
}
```

Rationale for dropping the "MTIP preserved" assertion: Phase 2.B semantics say MTIP is never stored in `cpu.csr.mip` — it is always derived live from CLINT. The Phase 2.A test's assertion that writing `(1 << 7) | (1 << 5)` "preserves" MTIP reflected a model that no longer matches hardware. The new assertion `MTIP always clear when CLINT not pending` is the correct 2.B replacement.

- [ ] **Step 7: Run all tests**

Run: `zig build test`

Expected: all csr tests pass; all other tests still pass (no new regressions).

- [ ] **Step 8: Commit**

```bash
git add src/csr.zig
git commit -m "feat: csr MIP/SIP reads reflect live CLINT MTIP; mask MTIP on writes (Plan 2.B Task 6)"
```

---

### Task 7: Add `MIE` WARL mask

**Files:**
- Modify: `src/csr.zig` (new `MIE_MASK` constant; `csrWriteUnchecked` CSR_MIE arm)
- Modify: `src/csr.zig` (new test)

**Why this task:** Small, standalone hygiene. Currently `CSR_MIE => cpu.csr.mie = value` accepts any u32. Spec §3.1.9 lists six writable interrupt-enable bits (SSIE, MSIE, STIE, MTIE, SEIE, MEIE). Masking prevents garbage bits from influencing the interrupt check in Task 8. Could have been folded into Task 6, but keeping it separate keeps each commit reviewable.

- [ ] **Step 1: Write two failing tests**

Append to `src/csr.zig` tests section:

```zig
test "mie write keeps only SSIE/MSIE/STIE/MTIE/SEIE/MEIE" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MIE, 0xFFFF_FFFF);
    const expected: u32 =
        (1 << 1) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 9) | (1 << 11);
    try std.testing.expectEqual(expected, try csrRead(&cpu, CSR_MIE));
}

test "mie reserved bits (0, 2, 4, 6, 8, 10, 12+) stay zero" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MIE, 0xFFFF_FFFF);
    const v = try csrRead(&cpu, CSR_MIE);
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 0));
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 2));
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 12));
    try std.testing.expectEqual(@as(u32, 0), v & 0xFFFF_0000);
}
```

- [ ] **Step 2: Run the tests — they fail**

Run: `zig build test`

Expected: the first test fails (v = 0xFFFFFFFF != expected); the second fails (bits 0/2/12/high-word all set).

- [ ] **Step 3: Add `MIE_MASK` constant and masked-write**

Add after `MIP_WRITE_MASK` in `src/csr.zig`:

```zig
// mie WARL mask: the six interrupt-enable bits defined by the RISC-V
// privileged spec §3.1.9. Writes outside these bits are dropped.
pub const MIE_MASK: u32 =
    (1 << 1)  | // SSIE
    (1 << 3)  | // MSIE
    (1 << 5)  | // STIE
    (1 << 7)  | // MTIE
    (1 << 9)  | // SEIE
    (1 << 11);  // MEIE
```

Change the `csrWriteUnchecked` `CSR_MIE` arm from:

```zig
        CSR_MIE => cpu.csr.mie = value,
```

to:

```zig
        CSR_MIE => cpu.csr.mie = value & MIE_MASK,
```

- [ ] **Step 4: Run all tests**

Run: `zig build test`

Expected: both new tests pass; the existing `"sie write merges into mie preserving M-only bits"` test still passes (that test writes legal bits only through `sie`, which already masks).

- [ ] **Step 5: Commit**

```bash
git add src/csr.zig
git commit -m "feat: apply MIE_MASK to CSR_MIE writes (Plan 2.B Task 7)"
```

---

### Task 8: Add `pendingInterrupts` and `check_interrupt` helpers in `cpu.zig`

**Files:**
- Modify: `src/cpu.zig` (new file-scope `pendingInterrupts` and `check_interrupt` functions)
- Modify: `src/cpu.zig` (new tests)

**Why this task:** This is the priority / gating engine. Pure function of CPU state plus CLINT's MTIP query — easy to unit-test without running an instruction stream. Task 9 wires the call site into `step`; Task 11 builds an end-to-end integration test that drives the whole pipeline.

- [ ] **Step 1: Write six failing tests covering the core behaviors**

Append to `src/cpu.zig` tests section:

```zig
const trap_mod = @import("trap.zig");
const halt_dev_t = @import("devices/halt.zig");
const uart_dev_t = @import("devices/uart.zig");

const CpuRig = struct {
    halt: halt_dev_t.Halt,
    aw: std.Io.Writer.Allocating,
    uart: uart_dev_t.Uart,
    clint: clint_dev.Clint,
    mem: Memory,
    cpu: Cpu,
    fn deinit(self: *CpuRig) void {
        self.mem.deinit();
        self.aw.deinit();
    }
};

fn cpuRig() !CpuRig {
    clint_dev.fixture_clock_ns = 0;
    var rig: CpuRig = undefined;
    rig.halt = halt_dev_t.Halt.init();
    rig.aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    rig.uart = uart_dev_t.Uart.init(&rig.aw.writer);
    rig.clint = clint_dev.Clint.init(&clint_dev.fixtureClock);
    rig.mem = try Memory.init(
        std.testing.allocator, &rig.halt, &rig.uart, &rig.clint, null,
        mem_mod.RAM_SIZE_DEFAULT,
    );
    rig.cpu = Cpu.init(&rig.mem, mem_mod.RAM_BASE);
    return rig;
}

test "check_interrupt: no pending → returns false, cpu state unchanged" {
    var rig = try cpuRig();
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.mie = 0xFFFF_FFFF & @import("csr.zig").MIE_MASK;
    // Nothing pending (mip=0, CLINT mtimecmp=0).
    const taken = check_interrupt(&rig.cpu);
    try std.testing.expect(!taken);
    try std.testing.expectEqual(PrivilegeMode.U, rig.cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.csr.mcause);
}

test "check_interrupt: MTIP pending, MIE+MTIE set in M-mode → M-trap taken" {
    var rig = try cpuRig();
    defer rig.deinit();
    rig.cpu.privilege = .M;
    rig.cpu.csr.mtvec = 0x8000_0400;
    rig.cpu.csr.mstatus_mie = true;
    rig.cpu.csr.mie = 1 << 7; // MTIE
    rig.clint.mtimecmp = 50;
    clint_dev.fixture_clock_ns = 10_000; // mtime = 100 > mtimecmp

    const taken = check_interrupt(&rig.cpu);
    try std.testing.expect(taken);
    try std.testing.expectEqual(PrivilegeMode.M, rig.cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0007), rig.cpu.csr.mcause);
    try std.testing.expectEqual(@as(u32, 0x8000_0400), rig.cpu.pc);
}

test "check_interrupt: M-mode with MIE=0 → MTIP pending but not taken" {
    var rig = try cpuRig();
    defer rig.deinit();
    rig.cpu.privilege = .M;
    rig.cpu.csr.mtvec = 0x8000_0400;
    rig.cpu.csr.mstatus_mie = false; // global disable
    rig.cpu.csr.mie = 1 << 7;
    rig.clint.mtimecmp = 50;
    clint_dev.fixture_clock_ns = 10_000;

    try std.testing.expect(!check_interrupt(&rig.cpu));
    try std.testing.expectEqual(PrivilegeMode.M, rig.cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.csr.mcause);
}

test "check_interrupt: U-mode always allows M-interrupt regardless of MIE" {
    var rig = try cpuRig();
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.mtvec = 0x8000_0400;
    rig.cpu.csr.mstatus_mie = false; // ignored because current priv < M
    rig.cpu.csr.mie = 1 << 7;
    rig.clint.mtimecmp = 50;
    clint_dev.fixture_clock_ns = 10_000;

    try std.testing.expect(check_interrupt(&rig.cpu));
    try std.testing.expectEqual(PrivilegeMode.M, rig.cpu.privilege);
}

test "check_interrupt: SSIP delegated, in U → trap taken at S" {
    var rig = try cpuRig();
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.stvec = 0x8000_0600;
    rig.cpu.csr.mideleg = 1 << 1;
    rig.cpu.csr.mstatus_sie = false; // ignored: U < S → always take
    rig.cpu.csr.mie = 1 << 1; // SSIE
    rig.cpu.csr.mip = 1 << 1; // SSIP pending (set by M-mode in the real path)

    try std.testing.expect(check_interrupt(&rig.cpu));
    try std.testing.expectEqual(PrivilegeMode.S, rig.cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0001), rig.cpu.csr.scause);
    try std.testing.expectEqual(@as(u32, 0x8000_0600), rig.cpu.pc);
}

test "check_interrupt: priority order — MTI beats SSI when both pending at U" {
    var rig = try cpuRig();
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.mtvec = 0x8000_0400; // M vector
    rig.cpu.csr.stvec = 0x8000_0600; // S vector
    rig.cpu.csr.mideleg = 1 << 1;    // SSIP delegated
    rig.cpu.csr.mie = (1 << 7) | (1 << 1);
    rig.cpu.csr.mip = 1 << 1;        // SSIP pending
    rig.clint.mtimecmp = 50;
    clint_dev.fixture_clock_ns = 10_000; // MTIP live-pending

    try std.testing.expect(check_interrupt(&rig.cpu));
    // MTI (priority 3rd after MEI/MSI) beats SSI (5th). Neither MEI nor MSI
    // is wired in Phase 2, so MTI wins.
    try std.testing.expectEqual(PrivilegeMode.M, rig.cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0007), rig.cpu.csr.mcause);
}
```

- [ ] **Step 2: Run the tests — they fail to compile**

Run: `zig build test`

Expected: compile error — `no declaration 'check_interrupt' in file 'cpu.zig'`.

- [ ] **Step 3: Implement `pendingInterrupts` and `check_interrupt`**

Add to `src/cpu.zig` at file scope (after the `Cpu` struct definition, before the `test` blocks):

```zig
/// Compute the effective `mip` for the interrupt-boundary check. This is
/// cpu.csr.mip OR'd with CLINT's live MTIP bit. We never store MTIP in
/// cpu.csr.mip — the bit is always derived here and inside csrRead.
fn pendingInterrupts(cpu: *const Cpu) u32 {
    var mip = cpu.csr.mip;
    if (cpu.memory.clint.isMtipPending()) mip |= 1 << 7;
    return mip;
}

/// Returns true if an interrupt would be deliverable at `target` given the
/// current privilege level and the relevant global-enable bit.
/// Spec §3.1.6.1 / §3.1.9 rule:
///   current < target → always taken (lower privilege can't mask higher)
///   current == target → consult global enable (MIE for M, SIE for S)
///   current > target → never taken this cycle (pend until we drop down)
fn interruptDeliverableAt(target: PrivilegeMode, cpu: *const Cpu) bool {
    const target_rank = @intFromEnum(target);
    const current_rank = @intFromEnum(cpu.privilege);
    if (current_rank < target_rank) return true;
    if (current_rank > target_rank) return false;
    return switch (target) {
        .M => cpu.csr.mstatus_mie,
        .S => cpu.csr.mstatus_sie,
        else => false, // U as an interrupt target requires the N extension (not implemented)
    };
}

/// Check for a deliverable async interrupt at the current instruction
/// boundary. If one exists, enter the trap and return true; otherwise
/// return false (caller proceeds with the fetch).
///
/// Priority uses the RISC-V spec order exposed in trap.INTERRUPT_PRIORITY_ORDER.
/// For each cause code in that order, we consult the effective mip AND mie
/// to see if it's pending+enabled, then route via mideleg to determine the
/// target privilege (but never delegate when cpu.privilege == .M), then
/// apply the deliverability rule above. The first cause passing all three
/// gates wins.
pub fn check_interrupt(cpu: *Cpu) bool {
    const effective_mip = pendingInterrupts(cpu);
    const pending_enabled = effective_mip & cpu.csr.mie;
    if (pending_enabled == 0) return false;

    for (trap.INTERRUPT_PRIORITY_ORDER) |cause_code| {
        const bit = @as(u32, 1) << @intCast(cause_code);
        if ((pending_enabled & bit) == 0) continue;

        const delegated = (cpu.csr.mideleg & bit) != 0;
        const target: PrivilegeMode =
            if (cpu.privilege != .M and delegated) .S else .M;

        if (!interruptDeliverableAt(target, cpu)) continue;

        trap.enter_interrupt(cause_code, cpu);
        return true;
    }

    return false;
}
```

- [ ] **Step 4: Run the tests**

Run: `zig build test`

Expected: all six new tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/cpu.zig
git commit -m "feat: add check_interrupt with priority + gating (Plan 2.B Task 8)"
```

---

### Task 9: Call `check_interrupt` at the top of `cpu.step`

**Files:**
- Modify: `src/cpu.zig` (the `step` method — add the pre-fetch interrupt check)
- Modify: `src/cpu.zig` (new test exercising `step` with MTIP pending)

**Why this task:** Task 8 defined the engine. This task integrates it into the instruction loop. Keeping them separate means Task 8's behaviors are unit-testable in isolation, and Task 9's change is a one-line addition we can review independently.

- [ ] **Step 1: Write a failing test that exercises step() with pending MTIP**

Append to `src/cpu.zig` tests section:

```zig
test "Cpu.step() takes pending MTI before fetching the next instruction" {
    var rig = try cpuRig();
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.mtvec = 0x8000_0400;
    rig.cpu.csr.mie = 1 << 7; // MTIE
    rig.cpu.csr.mstatus_mie = false; // U-mode: MIE ignored, lower privilege always takes
    rig.clint.mtimecmp = 50;
    clint_dev.fixture_clock_ns = 10_000; // MTIP live

    const saved_pc = rig.cpu.pc;
    try rig.cpu.step();

    // step() should have taken the MTI trap, NOT fetched at saved_pc.
    try std.testing.expectEqual(PrivilegeMode.M, rig.cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0400), rig.cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x8000_0007), rig.cpu.csr.mcause);
    try std.testing.expectEqual(saved_pc, rig.cpu.csr.mepc);
}

test "Cpu.step() with no pending interrupts runs the fetched instruction" {
    var rig = try cpuRig();
    defer rig.deinit();
    // Place a nop (addi x0, x0, 0 = 0x00000013) at the entry PC.
    try rig.mem.storeWordPhysical(mem_mod.RAM_BASE, 0x00000013);
    const saved_pc = rig.cpu.pc;

    try rig.cpu.step();

    try std.testing.expectEqual(saved_pc + 4, rig.cpu.pc);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.csr.mcause);
}
```

- [ ] **Step 2: Run the tests — the first fails, second passes**

Run: `zig build test`

Expected: the first test fails — step() fetched and executed something at `saved_pc` because the interrupt check isn't wired into step yet. The second passes — no pending interrupt, so execution proceeds normally.

- [ ] **Step 3: Call `check_interrupt` at the top of `step`**

Locate `pub fn step(self: *Cpu) StepError!void` in `src/cpu.zig` (around line 128). Insert the interrupt check at the top:

```zig
    pub fn step(self: *Cpu) StepError!void {
        // Plan 2.B: check for deliverable async interrupts BEFORE fetching.
        // If one is taken, the PC has been redirected to the trap vector
        // and the instruction that would have been fetched this cycle is
        // not executed — per RISC-V spec, interrupts are taken at the
        // boundary between instructions.
        if (check_interrupt(self)) return;

        const pre_pc = self.pc;
        const pre_priv = self.privilege;
        // ... rest unchanged ...
```

The rest of `step` (fetch, decode, execute, trace) remains exactly as in Plan 2.A.

- [ ] **Step 4: Run the tests**

Run: `zig build test`

Expected: both new tests pass; all Phase 1 tests still pass (nothing in Phase 1 programs MTIP while MIE/MTIE are zero).

- [ ] **Step 5: Commit**

```bash
git add src/cpu.zig
git commit -m "feat: cpu.step checks for pending interrupts pre-fetch (Plan 2.B Task 9)"
```

---

### Task 10: Implement the real `trace.formatInterruptMarker`

**Files:**
- Modify: `src/trace.zig` (replace the Task 4 stub with the real formatter and an `interruptName` helper)
- Modify: `src/trace.zig` (new tests)

**Why this task:** Debugging the Plan 2.D kernel WILL require seeing exactly when interrupts fire. The marker format is frozen by the Phase 2 spec §CLI; this task locks it in with tests.

- [ ] **Step 1: Write three failing tests**

Append to `src/trace.zig` tests section:

```zig
test "formatInterruptMarker: machine timer (cause 7), taken in U, now M" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try formatInterruptMarker(&aw.writer, 7, .U, .M);
    try std.testing.expectEqualStrings(
        "--- interrupt 7 (machine timer) taken in U, now M ---\n",
        aw.written(),
    );
}

test "formatInterruptMarker: supervisor software (cause 1), taken in S, now S" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try formatInterruptMarker(&aw.writer, 1, .S, .S);
    try std.testing.expectEqualStrings(
        "--- interrupt 1 (supervisor software) taken in S, now S ---\n",
        aw.written(),
    );
}

test "formatInterruptMarker: unknown cause → \"unknown\"" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try formatInterruptMarker(&aw.writer, 42, .M, .M);
    try std.testing.expectEqualStrings(
        "--- interrupt 42 (unknown) taken in M, now M ---\n",
        aw.written(),
    );
}
```

- [ ] **Step 2: Run the tests — they fail (stub body returns empty)**

Run: `zig build test`

Expected: all three tests fail — `aw.written()` is empty because the stub is a no-op.

- [ ] **Step 3: Implement the formatter**

Replace the Task 4 stub in `src/trace.zig` with:

```zig
/// Human-readable name for an async interrupt cause code. RISC-V priv spec
/// §3.1.9 Table "Machine and Supervisor Interrupts".
fn interruptName(cause_code: u32) []const u8 {
    return switch (cause_code) {
        1 => "supervisor software",
        3 => "machine software",
        5 => "supervisor timer",
        7 => "machine timer",
        9 => "supervisor external",
        11 => "machine external",
        else => "unknown",
    };
}

fn privStr(p: PrivilegeMode) []const u8 {
    return switch (p) {
        .M => "M",
        .S => "S",
        .U => "U",
        .reserved_h => "?",
    };
}

/// Emit one line denoting an async interrupt entry:
///   --- interrupt N (<name>) taken in <old>, now <new> ---
///
/// Called by trap.enter_interrupt BEFORE the privilege switch so `from`
/// captures the pre-interrupt state. Synchronous traps do NOT emit this
/// marker — they appear in trace as the target-vector instruction.
pub fn formatInterruptMarker(
    writer: *std.Io.Writer,
    cause_code: u32,
    from: PrivilegeMode,
    to: PrivilegeMode,
) !void {
    try writer.print(
        "--- interrupt {d} ({s}) taken in {s}, now {s} ---\n",
        .{ cause_code, interruptName(cause_code), privStr(from), privStr(to) },
    );
    try writer.flush();
}
```

- [ ] **Step 4: Run the tests**

Run: `zig build test`

Expected: all three tests pass; existing `formatInstr` tests still pass.

- [ ] **Step 5: Commit**

```bash
git add src/trace.zig
git commit -m "feat: trace interrupt marker with cause name + privilege transition (Plan 2.B Task 10)"
```

---

### Task 11: End-to-end CLINT → M-mode ISR → mip.SSIP → S-mode ISR forwarding integration test

**Files:**
- Modify: `src/cpu.zig` (new integration test)

**Why this task:** This is the single most important acceptance test for Plan 2.B: it exercises the entire async pipeline in one shot and is what Plan 2.C's kernel boot-shim `mtimer.S` relies on. If this test passes, the kernel's timer path has a proven substrate. It runs a hand-assembled two-handler program — no external dependency on riscv-tests.

The integration test assembles a tiny program by hand:

- **M-mode handler** at physical `0x8000_0400`: set `mtimecmp ← 0xFFFF_FFFF` (ack timer), set `mip.SSIP ← 1` via `csrrsi`, `mret`.
- **S-mode handler** at physical `0x8000_0600`: clear `mip.SSIP` via `csrrci`, write `1` to RAM at `0x8000_0800` (a test sentinel), loop forever.
- **Reset code** at physical `0x8000_0000`: delegate SSIP (`csrw mideleg, 2`), enable MTIE + SSIE, set `MIE = 1`, `SIE = 1`, `mtvec = 0x80000400`, `stvec = 0x80000600`, set `mstatus.MPP = U`, `mepc = 0x80001000`, program CLINT `mtimecmp ← 100`, advance wall clock, `mret` → U-mode loop (`j 0`) at `0x8000_1000`.

The test then steps the CPU a bounded number of times and asserts the sentinel at `0x80000800` holds `1`.

- [ ] **Step 1: Write the failing integration test**

Append to `src/cpu.zig` tests section:

```zig
test "integration: CLINT → M MTI ISR → mip.SSIP → S SSI ISR end-to-end" {
    clint_dev.fixture_clock_ns = 0;
    var halt = @import("devices/halt.zig").Halt.init();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var uart = @import("devices/uart.zig").Uart.init(&aw.writer);
    var clint = clint_dev.Clint.init(&clint_dev.fixtureClock);
    var mem = try Memory.init(
        std.testing.allocator, &halt, &uart, &clint, null, mem_mod.RAM_SIZE_DEFAULT,
    );
    defer mem.deinit();

    // --- Program layout ---
    // 0x80000000  reset: setup delegation, CSRs, drop to U at 0x80001000
    // 0x80000400  M-mode MTI ISR
    // 0x80000600  S-mode SSI ISR
    // 0x80000800  sentinel word (starts 0, S ISR writes 1)
    // 0x80001000  U-mode infinite loop

    const RAM_BASE = mem_mod.RAM_BASE;

    // --- Reset code @ 0x80000000 ---
    // csrrwi zero, mideleg, 2      # mideleg = (1<<1) = SSIP
    try mem.storeWordPhysical(RAM_BASE + 0x000, 0x30315073);
    // lui t0, 0x80000; addi t0, t0, 0x400  (pre-compute mtvec target)
    try mem.storeWordPhysical(RAM_BASE + 0x004, 0x800002B7); // lui t0, 0x80000
    try mem.storeWordPhysical(RAM_BASE + 0x008, 0x40028293); // addi t0, t0, 0x400
    // csrw mtvec, t0 (0x305)
    try mem.storeWordPhysical(RAM_BASE + 0x00C, 0x30529073);
    // lui t0, 0x80000; addi t0, t0, 0x600  → stvec
    try mem.storeWordPhysical(RAM_BASE + 0x010, 0x800002B7);
    try mem.storeWordPhysical(RAM_BASE + 0x014, 0x60028293);
    // csrw stvec, t0 (0x105)
    try mem.storeWordPhysical(RAM_BASE + 0x018, 0x10529073);
    // li t0, (1<<7) | (1<<1)        # MTIE | SSIE
    try mem.storeWordPhysical(RAM_BASE + 0x01C, 0x08200293); // addi t0, x0, 0x82
    // csrw mie, t0
    try mem.storeWordPhysical(RAM_BASE + 0x020, 0x30429073);
    // csrrsi zero, mstatus, 0x8     # MIE = 1
    try mem.storeWordPhysical(RAM_BASE + 0x024, 0x30046073);
    // csrrsi zero, sstatus, 0x2     # SIE = 1
    try mem.storeWordPhysical(RAM_BASE + 0x028, 0x10016073);
    // li t1, 100; write mtimecmp = 100
    //   CLINT_MTIMECMP = 0x02004000
    try mem.storeWordPhysical(RAM_BASE + 0x02C, 0x06400313); // addi t1, x0, 100
    try mem.storeWordPhysical(RAM_BASE + 0x030, 0x020043B7); // lui t2, 0x2004
    try mem.storeWordPhysical(RAM_BASE + 0x034, 0x0063A023); // sw t1, 0(t2)
    try mem.storeWordPhysical(RAM_BASE + 0x038, 0x0003A223); // sw zero, 4(t2)
    // lui t0, 0x80001; csrw mepc, t0
    try mem.storeWordPhysical(RAM_BASE + 0x03C, 0x800012B7);
    try mem.storeWordPhysical(RAM_BASE + 0x040, 0x34129073);
    // mret
    try mem.storeWordPhysical(RAM_BASE + 0x044, 0x30200073);

    // --- M-mode MTI ISR @ 0x80000400 ---
    //   Ack by moving mtimecmp far into the future; forward to SSIP; mret.
    //   li t0, -1; lui t2, 0x2004; sw t0, 0(t2); sw t0, 4(t2)
    //   csrrsi zero, mip, 0x2       # set SSIP
    //   mret
    try mem.storeWordPhysical(RAM_BASE + 0x400, 0xFFF00293); // addi t0, x0, -1
    try mem.storeWordPhysical(RAM_BASE + 0x404, 0x020043B7); // lui t2, 0x2004
    try mem.storeWordPhysical(RAM_BASE + 0x408, 0x0053A023); // sw t0, 0(t2)
    try mem.storeWordPhysical(RAM_BASE + 0x40C, 0x0053A223); // sw t0, 4(t2)
    try mem.storeWordPhysical(RAM_BASE + 0x410, 0x34416073); // csrrsi zero, mip, 0x2
    try mem.storeWordPhysical(RAM_BASE + 0x414, 0x30200073); // mret

    // --- S-mode SSI ISR @ 0x80000600 ---
    // Clear SSIP via sip; compute sentinel address via auipc+addi; write
    // 1 to sentinel; loop forever.
    //   csrrci zero, sip, 0x2     # clear SSIP
    //   auipc  t0, 0x0             # t0 = 0x80000604
    //   addi   t0, t0, 0x1FC       # t0 = 0x80000800 (sentinel VA)
    //   addi   t1, x0, 1
    //   sw     t1, 0(t0)
    //   loop: j loop
    try mem.storeWordPhysical(RAM_BASE + 0x600, 0x14417073); // csrrci zero, sip, 0x2
    try mem.storeWordPhysical(RAM_BASE + 0x604, 0x00000297); // auipc t0, 0x0
    try mem.storeWordPhysical(RAM_BASE + 0x608, 0x1FC28293); // addi t0, t0, 0x1FC
    try mem.storeWordPhysical(RAM_BASE + 0x60C, 0x00100313); // addi t1, x0, 1
    try mem.storeWordPhysical(RAM_BASE + 0x610, 0x0062A023); // sw t1, 0(t0)
    try mem.storeWordPhysical(RAM_BASE + 0x614, 0x0000006F); // loop: j self

    // --- U-mode loop @ 0x80001000 ---
    //   j 0   (loop forever; MTI will interrupt us)
    try mem.storeWordPhysical(RAM_BASE + 0x1000, 0x0000006F);

    // Sentinel starts at zero.
    try mem.storeWordPhysical(RAM_BASE + 0x800, 0);

    var cpu = Cpu.init(&mem, RAM_BASE);

    // Step through reset, then drop into U, then let CLINT fire.
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        cpu.step() catch |e| switch (e) { error.Halt, error.FatalTrap => break };
    }
    // Now advance the wall clock so MTIP fires at the next boundary.
    clint_dev.fixture_clock_ns = 20_000; // mtime = 200, mtimecmp = 100 → pending
    i = 0;
    while (i < 200) : (i += 1) {
        cpu.step() catch |e| switch (e) { error.Halt, error.FatalTrap => break };
        const sentinel = try mem.loadWordPhysical(RAM_BASE + 0x800);
        if (sentinel == 1) break;
    }
    const sentinel = try mem.loadWordPhysical(RAM_BASE + 0x800);
    try std.testing.expectEqual(@as(u32, 1), sentinel);
    // Final privilege should be S (SSI ISR loops there).
    try std.testing.expectEqual(PrivilegeMode.S, cpu.privilege);
}
```

Note on the hand-assembled instruction encodings: the values above are computed from the RV32 encoding of each mnemonic. If a subagent re-derives any of these and finds a discrepancy, they MUST match the comment mnemonic — the comment is the source of truth. Use `objdump -d` on a miniature `riscv-as` output to cross-check when in doubt.

- [ ] **Step 2: Run the test**

Run: `zig build test`

Expected: the test passes. If it fails:
  - Inspect `cpu.pc` and `cpu.privilege` at each expected checkpoint by interleaving `std.debug.print("...", .{})` calls.
  - Use the `--trace` flag (requires wiring a trace_writer — see Plan 1.D's e2e harness).
  - Most likely failure: a hand-assembled encoding is wrong. Decode the offending word with `@import("decoder.zig").decode(word)` and diff against the comment.

- [ ] **Step 3: Commit**

```bash
git add src/cpu.zig
git commit -m "test: integration CLINT → M → SSIP → S forwarding round-trip (Plan 2.B Task 11)"
```

---

### Task 12: Extend `rv32si_tests` with `sbreak` and `ma_fetch`

**Files:**
- Modify: `build.zig` (update the `rv32si_tests` array and the associated comment block)

**Why this task:** These two upstream riscv-tests define `stvec_handler`, which triggers the `p` env macro to write `medeleg` with `BREAKPOINT | MISALIGNED_FETCH | ...`. Once Plan 2.B delegation works end-to-end, the delegated trap reaches `stvec_handler`, the handler verifies `scause`/`sepc`, and the tests pass. They fail today only because medeleg is a stub.

- [ ] **Step 1: Locate and update the `rv32si_tests` list**

In `build.zig`, find:

```zig
    const rv32si_tests = [_][]const u8{ "csr", "scall", "wfi" };
```

Replace with:

```zig
    const rv32si_tests = [_][]const u8{ "csr", "scall", "wfi", "sbreak", "ma_fetch" };
```

And update the exclusion-rationale block immediately above it. The current block (starting with `// rv32si-p: ...`) lists `sbreak`, `ma_fetch`, and `dirty` as excluded. The new block should list only `dirty`:

```zig
    // rv32si-p: S-mode CSRs, Sv32 page walks, A/D bits, S-mode WFI, plus
    // S-mode synchronous trap delegation (Plan 2.B).
    // NOTE: no illegal.S exists in the upstream submodule for this family;
    // illegal-instruction coverage lives in rv32mi.
    //
    // Excluded (permanent in Phase 2):
    //   - dirty: exercises a root-level (L1) leaf PTE — a 4 MiB Sv32
    //     superpage. Phase 2 permanently rejects superpages (spec
    //     §Sv32 translation). Revisit only if a future phase adopts them.
    const rv32si_tests = [_][]const u8{ "csr", "scall", "wfi", "sbreak", "ma_fetch" };
```

- [ ] **Step 2: Run the riscv-tests suite**

Run: `zig build riscv-tests`

Expected: all 5 rv32si tests pass (3 from 2.A + the 2 newly added). All other families (rv32ui / rv32um / rv32ua / rv32mi) also pass unchanged.

If either new test fails:
  - Dump the failing test's binary with `objdump -d zig-out/riscv-tests/rv32si/sbreak.elf` to confirm the env macro wrote the medeleg setup.
  - Run our emulator on the test with `--trace --halt-on-trap` to see where the trap actually lands.
  - The most likely failure mode is a wrong assumption about which bit of medeleg / which priv-mode transition runs — not a bug in the emulator, but an incorrect test inclusion.

- [ ] **Step 3: Commit**

```bash
git add build.zig
git commit -m "test: enable rv32si-p-sbreak and -ma_fetch in riscv-tests (Plan 2.B Task 12)"
```

---

### Task 13: Regression pass — Phase 1 demos still work

**Files:**
- None modified (this task validates).

**Why this task:** Plan 2.B changes `cpu.step`, `trap.enter`, and CSR read semantics. Each Phase 1 demo (`e2e`, `e2e-mul`, `e2e-trap`, `e2e-hello-elf`) needs to keep passing. This is the "Phase 2 never regresses Phase 1" guarantee from the Phase 2 spec §Definition of done.

- [ ] **Step 1: Run every build target in one go**

Run the sequence:

```bash
zig build test
zig build e2e
zig build e2e-mul
zig build e2e-trap
zig build e2e-hello-elf
zig build riscv-tests
```

Expected: all commands exit 0. If `zig build test` fails on an existing Plan 2.A test, the cause is almost certainly:
- A `dummy_mem: Memory = undefined` test now touches MIP/SIP. Fix: migrate to `CsrRig` / `CpuRig` (pattern from Task 6).
- A test that relied on the stub `medeleg / mideleg read as zero`. Fix: delete the test (Task 2 already removed the primary stub test; any other drift is a forgotten copy).
- A test inadvertently setting `mstatus_mie=true` and `mie=MTIE` while CLINT is programmed → the new interrupt check fires. Fix: zero `mie` or `mstatus_mie` in the test setup unless the interrupt is intended.

- [ ] **Step 2: If any failure, fix root cause and re-run the suite**

Fixes fall into the three buckets above. Do not mask symptoms by carving exceptions — a failing test means the new plumbing touches something the test didn't expect, and the fix is either the test (migrate to a rig) or the plumbing (bug in our check_interrupt / delegation code).

- [ ] **Step 3: Commit fixes (if any) together with a focused message**

```bash
git add <the_files_you_fixed>
git commit -m "fix: migrate dummy_mem tests colliding with MIP live-read (Plan 2.B Task 13)"
```

If no fixes are needed, skip the commit.

---

### Task 14: README status line and trace format note

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the Status section**

Find:

```
**Plan 2.A (emulator S-mode + Sv32) merged.**

The emulator now supports:

- S-mode privilege + full S-CSR file (`sstatus`, `stvec`, `sepc`,
  `scause`, `stval`, `sscratch`, `sie`, `sip`, `satp`).
- `sret`, `sfence.vma`.
- Sv32 two-level paging (4 KB pages; no superpages; no TLB model).
- `misa` advertises `'S'`.
- `--trace` includes a privilege column: `[M]` / `[S]` / `[U]`.
- `rv32si-p-*` conformance tests for `csr`, `scall`, `wfi`. The `dirty`,
  `sbreak`, and `ma_fetch` upstream tests are excluded with rationale in
  `build.zig`: they depend on trap delegation or Sv32 superpages, both
  of which are explicit Plan 2.B / beyond-2.A features.

Trap delegation and async interrupt delivery arrive in Plan 2.B.

Next: **Plan 2.B — emulator trap delegation + async interrupts**.
```

Replace with:

```
**Plan 2.B (emulator trap delegation + async interrupts) merged.**

The emulator now supports, in addition to the Plan 2.A surface:

- `medeleg` / `mideleg` WARL storage; synchronous trap routing to S when
  the cause bit is delegated and the current privilege is < M.
- Asynchronous interrupt delivery: per-instruction-boundary check of
  `mip & mie` with delegation via `mideleg` and per-privilege enable
  gating (`mstatus.MIE` / `mstatus.SIE`).
- CLINT `mtime >= mtimecmp && mtimecmp != 0` drives live `mip.MTIP`;
  writes to `mip.MTIP` are silently dropped (hardware-only signal).
- `--trace` emits a synthetic marker on async interrupt entry:
  `--- interrupt N (<name>) taken in <old>, now <new> ---`.
- `rv32si-p-*` conformance now also includes `sbreak` and `ma_fetch`.
  Only `dirty` remains excluded — it depends on Sv32 superpages, which
  the Phase 2 spec permanently rejects.

The end-to-end `CLINT → M MTI ISR → mip.SSIP → S SSI ISR` forwarding
round-trip is validated by a dedicated integration test in
`src/cpu.zig` — the substrate Plan 2.C's kernel `mtimer.S` will
consume.

Next: **Plan 2.C — kernel skeleton (M-mode boot shim, single page
table, sret-to-U, user `write`+`exit` demo)**.
```

And find the ISA coverage line:

```
ISA coverage: RV32I + M + A + Zicsr + Zifencei, M/S/U privilege,
synchronous traps, Sv32 paging. `--trace` renders a `[M]`/`[S]`/`[U]`
privilege column.
```

Replace with:

```
ISA coverage: RV32I + M + A + Zicsr + Zifencei, M/S/U privilege,
synchronous traps with delegation, async interrupt delivery, Sv32
paging. `--trace` renders a `[M]`/`[S]`/`[U]` privilege column, plus
a synthetic `--- interrupt N (<name>) taken in <old>, now <new> ---`
marker on async trap entry.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README reflects Plan 2.B (delegation + async interrupts) merged (Plan 2.B Task 14)"
```

---

## Roughly what success looks like at the end of Plan 2.B

```
$ zig build test                              # all unit tests pass (Phase 1 + 2.A + 2.B)
$ zig build riscv-tests                       # rv32ui/um/ua/mi/si p-* pass; rv32si grows
$ zig build e2e e2e-mul e2e-trap e2e-hello-elf  # Phase 1 demos still green

# New capability: async interrupts work end-to-end in a unit test.
# Live preview of the integration trace (pseudo-listing):
$ zig build run -- --trace <minimal-int-program>.elf | sed -n '20,40p'
80000040  [M] csrw  mtimecmp, ...
80000044  [M] mret                     [pc -> 0x80001000]
80001000  [U] j 0                      [pc -> 0x80001000]
...
--- interrupt 7 (machine timer) taken in U, now M ---
80000400  [M] addi  t0, x0, -1         [x5 := 0xFFFFFFFF]
80000404  [M] lui   t2, 0x2004         [x7 := 0x02004000]
80000408  [M] sw    t0, 0(t2)
8000040C  [M] sw    t0, 4(t2)
80000410  [M] csrrsi zero, mip, 0x2
80000414  [M] mret                     [pc -> 0x80001000]
80001000  [U] j 0                      [pc -> 0x80001000]
--- interrupt 1 (supervisor software) taken in U, now S ---
80000600  [S] csrrci zero, sip, 0x2
80000604  [S] auipc t0, 0x0            [x5 := 0x80000604]
...
```

…and Plan 2.C can now build the kernel on top of this substrate without writing a single emulator line.

## Risks and open questions addressed during 2.B

- **Hand-assembled encodings in the Task 11 integration test.** The comment alongside each `storeWordPhysical` call gives the mnemonic; the numeric word must match. When Task 11 is implemented, the subagent SHOULD verify each word by running `riscv64-unknown-elf-gcc -march=rv32ima -c /tmp/check.S -o /tmp/check.o && riscv64-unknown-elf-objdump -d /tmp/check.o` on a `.S` file containing the same mnemonics. Any mismatch between comment and word is a planning bug, not a grader error.
- **MTIP live-read crashes tests that use `dummy_mem: Memory = undefined`.** Addressed by Task 6 (helper `CsrRig` migrates all affected tests). If Task 13's regression pass finds another such test in cpu.zig or elsewhere, migrate it using the same pattern.
- **Priority order tie-breaking.** Spec priority is total for the six bits we consider; if multiple bits are pending simultaneously, the first in `INTERRUPT_PRIORITY_ORDER` wins. Task 8's tests cover the MTI-vs-SSI case explicitly.
- **Interrupt taken at M while `mstatus.MIE = 0` from M-mode.** Correctly gated by `interruptDeliverableAt`. Task 8 test "M-mode with MIE=0 → MTIP pending but not taken" pins this.
- **Delegated interrupt taken while in M.** Phase 2 spec: delegation is silent if current privilege is M (M traps never go to S). `check_interrupt`'s `if (cpu.privilege != .M and delegated)` implements this. Task 4 test "enter_interrupt from M stays in M regardless of mideleg" pins this.
- **Synchronous trap routing to S while already in S (e.g., sbreak from S).** Allowed — delegation from S to S is still "delegation" in spec terms and the `if (cpu.privilege != .M)` check permits it; `SPP` becomes `S`. Task 3 test "enter from S with delegated cause routes to S, SPP=S" pins this.
- **Trap taken on the FIRST instruction of a handler.** If `stvec` points at an instruction that itself would raise a sync trap, and that cause is also delegated, we'd loop. Real RISC-V software avoids this by hand; our emulator follows the same rule. No handling needed in Plan 2.B.
- **`sfence.vma` with TVM=1 from S.** Plan 2.A wired this as illegal-instruction; delegation routing now sends the resulting illegal-instruction trap to S (cause 2 delegated). This is harmless since we never set TVM=1, but the composition is worth noting.
