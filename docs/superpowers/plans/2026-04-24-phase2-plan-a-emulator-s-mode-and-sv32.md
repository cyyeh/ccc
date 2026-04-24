# Phase 2 Plan A — Emulator: S-mode + Sv32 paging (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Phase 1 emulator with **S-mode privilege**, the full S-mode **CSR file** (`sstatus`, `stvec`, `sepc`, `scause`, `stval`, `sscratch`, `satp`, `sie`, `sip`), the two S-mode **instructions** (`sret`, `sfence.vma`), and **Sv32 two-level paging** (4 KB pages only; no superpages; no TLB modeling). All Phase 1 tests still pass, and the emulator passes the subset of the official `rv32si-p-*` `riscv-tests` conformance suite that our Sv32 + S-mode feature set can support. Trap delegation and async interrupt delivery are explicitly out of scope (they arrive in Plan 2.B).

**Architecture:** S-mode is added alongside M/U as a third `PrivilegeMode` variant. The S-mode CSRs are wired into `csr.zig` with the field-masking semantics the RISC-V privileged spec mandates: `sstatus`, `sie`, and `sip` are **masked views** over the same underlying storage as `mstatus`/`mie`/`mip` (no duplicated state); `stvec`, `sepc`, `scause`, `stval`, `sscratch`, and `satp` are standalone S-mode CSRs. `sret` and `sfence.vma` decode as new SYSTEM-opcode variants in `decoder.zig` and execute in `execute.zig`; `sret` mirrors `mret`'s 3-step exit but over S-mode fields, and `sfence.vma` is a no-op in our no-TLB model after a privilege check. Sv32 lives inside `memory.zig` as a new `translate(va, access, effective_priv)` layer that every load/store/fetch goes through: when current privilege is S or U and `satp.MODE = Sv32`, the walker returns a physical address or a page-fault cause; MMIO and M-mode accesses bypass translation entirely. A/D bits are updated in-place on each access rather than raising a page fault. The `rv32si-p-*` suite requires a new `tests/riscv-tests-s.ld` linker script and a small S-mode entry shim (modeled on `tests/riscv-tests-p.ld` + the `p` environment) so the tests land in S-mode and set up their own trap handler correctly.

**Tech Stack:** Zig 0.16.x (pinned in `build.zig.zon`), no new external dependencies. The `riscv-tests` submodule added in Plan 1.C already contains the `rv32si-p-*` sources.

**Spec reference:** `docs/superpowers/specs/2026-04-24-phase2-bare-metal-kernel-design.md` — Plan 2.A covers spec §Architecture (emulator growth rows for `cpu`, `csr`, `decoder`, `execute`, `memory`), §Privilege & trap model (S-mode runtime, S-CSRs, Sv32 translation), §Testing strategy item 1 (S-CSR / Sv32 unit tests) and item 2 (rv32si-p-\* integration). The RISC-V Privileged Spec sections on Sv32 (§4.3) and CSR aliasing (§3.1.6.x) are authoritative; the phase spec takes precedence if they disagree.

**Plan 2.A scope (subset of Phase 2 spec):**

- **`PrivilegeMode.S` variant.** `Cpu.privilege` is now one of `.M`, `.S`, `.U`. Initial state = `.M` (unchanged).
- **S-CSRs, all writable except where noted**:
  - `sstatus` (0x100) — masked view of `mstatus`. S-visible fields: `SIE` (bit 1), `SPIE` (bit 5), `UBE` (bit 6, WPRI in RV32 → WARL 0), `SPP` (bit 8), `VS` (bits 10:9, 0), `FS` (bits 14:13, 0), `XS` (bits 16:15, 0), `SUM` (bit 18), `MXR` (bit 19), `SD` (bit 31, read-only aggregate of FS/VS/XS = 0). Writes through `sstatus` clear non-visible bits before merging with `mstatus`.
  - `sie` (0x104) / `sip` (0x144) — masked views of `mie`/`mip` restricted to bits {SSIE=1, STIE=5, SEIE=9}. Writes through `sie` only touch those bits in `mie`; reads mask out everything else. Same for `sip`.
  - `stvec` (0x105) — standalone; direct mode only (same convention as `mtvec`).
  - `sscratch` (0x140) — standalone; a u32 scratch register.
  - `sepc` (0x141) — standalone.
  - `scause` (0x142) — standalone.
  - `stval` (0x143) — standalone.
  - `satp` (0x180) — standalone. Encoded as `MODE` (bit 31), `ASID` (bits 30:22 — WARL 0 in our implementation), `PPN` (bits 21:0). `MODE ∈ {0: Bare, 1: Sv32}` accepted; other values clamp to `Bare`.
- **CSR-access privilege checks**:
  - M-mode may access any CSR.
  - S-mode may access the M-mode CSR addresses 0x100–0x1BF and its own S-addresses, but **not** M-only CSRs (those whose address bits 9:8 == 0b11) unless via sstatus/sie/sip. Concretely: S-mode can read/write `sstatus`, `sie`, `stvec`, `sscratch`, `sepc`, `scause`, `stval`, `sip`, `satp`, plus any user-level or supervisor-level custom CSR, but attempting `mstatus` / `mie` / `mepc` / `medeleg` / `mideleg` / `mhartid` / `misa` / `mtvec` / `mscratch` / `mcause` / `mtval` / `mip` → illegal instruction trap.
  - U-mode cannot access any CSR (unchanged from Phase 1).
  - When `satp` is the target and the current privilege is S-mode, `mstatus.TVM` is checked: if `TVM = 1`, access traps as illegal. In Plan 2.A we leave `TVM = 0` unconditionally, but the check is wired so Plan 2.B can exercise it.
- **`sret` instruction** (SYSTEM opcode, funct3=000, imm12=0x102): privilege check (M or S only; U traps illegal). Mirrors `mret`'s 3-step exit over S-fields: `PC ← sepc`; `privilege ← sstatus.SPP`; `sstatus.SIE ← sstatus.SPIE`; `sstatus.SPIE ← 1`; `sstatus.SPP ← U`. In S-mode with `mstatus.TSR = 1`, `sret` traps illegal; we leave `TSR = 0` but wire the check.
- **`sfence.vma` instruction** (SYSTEM opcode, funct3=000, imm12 top bits 0001001 — rs2 = ASID, rs1 = VA). Privilege check (M or S only; U → illegal). In S-mode with `mstatus.TVM = 1`, traps illegal; TVM left 0 here. Behavior: no memory side effects in our no-TLB model; we ignore rs1/rs2 operands. The instruction is still fully decoded and the rs1/rs2 fields captured for completeness so Plan 2.B (or a future TLB model) doesn't need to re-decode.
- **Sv32 translation**: `memory.zig` gains a `translate(va, access, effective_priv) !TranslationResult` function.
  - `access: enum { fetch, load, store }`.
  - `effective_priv`: instruction fetch always uses `cpu.privilege`; loads/stores use `cpu.privilege` normally, but if `cpu.privilege == .M` and `mstatus.MPRV == 1`, use `mstatus.MPP` as the effective privilege.
  - When effective privilege is `.M` or `satp.MODE == Bare`: identity translation; any RAM/MMIO dispatch works as in Plan 1.C.
  - Otherwise: 2-level page walk. Each walk reads 4 bytes at `(root_ppn << 12) + VPN[i] * 4`; stops at a leaf (R|W|X ≥ 1). A leaf at level 1 (superpage) → page fault. Permission check uses `PTE.U`, `sstatus.SUM`, `sstatus.MXR`, and the access type. A/D bits: on success, if `PTE.A = 0` (any access) or (`access == .store` and `PTE.D = 0`), update-in-place via a RAM write and continue.
  - Faults return a `TranslationFault { cause, va }` where `cause ∈ {12, 13, 15}` (instruction page fault, load page fault, store/AMO page fault).
- **`Cause` enum additions**: `inst_page_fault = 12`, `load_page_fault = 13`, `store_page_fault = 15`. Trap entry path in `trap.zig` accepts these exactly like the existing access-fault causes (same CSR-update machinery). Since delegation is not yet implemented, all these traps still terminate in M-mode (`mtvec` handler). This is fine for Plan 2.A because the rv32si tests set up `mtvec` themselves before dropping to S.
- **`mstatus` field additions**: fields that previously read-as-zero now have real backing:
  - `SIE` (bit 1), `SPIE` (bit 5), `SPP` (bit 8) — saved/restored on trap entry/exit alongside the MIE/MPIE/MPP machinery.
  - `SUM` (bit 18), `MXR` (bit 19) — consulted by the Sv32 permission check.
  - `MPRV` (bit 17) — consulted by the load/store effective-privilege selector.
  - `TVM` (bit 20) — consulted on `satp` access from S-mode and on `sfence.vma`.
  - `TSR` (bit 22) — consulted on `sret` from S-mode.
  - `TW` (bit 21) — WARL 0 for now; relevant only if we implement `wfi` privilege gating, which we don't.
- **`misa` bump**: bit 18 (`'S'`) is set to advertise S-mode presence. Value becomes `0x40141101` (MXL=01, I+M+A+S+U).
- **Trap entry path**: gains awareness of S-mode as the current privilege (preserves it in `mstatus.MPP`). Gains page-fault causes. Still routes every trap to M-mode — delegation is Plan 2.B.
- **Trace format**: `trace.formatInstr` gains a privilege column rendered as `[M]`, `[S]`, or `[U]` between the PC and the opcode. Backward-compatible: Phase 1 `e2e`/`e2e-mul`/`e2e-trap` expected-output fixtures are regenerated to include the column.
- **`rv32si-p-*` integration**: new `tests/riscv-tests-s.ld` linker script (mirrors upstream `env/p/link.ld` but gives the test an S-mode entry shim); new `buildRv32siTest` helper in `build.zig` drives assembly + link + run. Initial coverage: whatever upstream tests our Sv32 + S-mode feature set passes — explicit list decided during the integration task. Expected at minimum: `csr`, `dirty`, `illegal`, `ma_fetch`, `sbreak`, `scall`, `wfi`. Tests that need delegation, external interrupts, or features we don't model are excluded with an in-file comment.

**Not in Plan 2.A (explicitly):**

- `medeleg`, `mideleg`, and delegation-aware trap entry routing → Plan 2.B.
- Async interrupt delivery (CPU-side `mip & mie` check at instruction boundaries; CLINT MTIP edge generation; M→SSIP forwarding path) → Plan 2.B.
- Any kernel-side code (`tests/programs/kernel/`) → Plans 2.C / 2.D.
- Superpage (L1 leaf) support — Phase 2 spec rejects it; Plan 2.A enforces the rejection.
- TLB modeling — we re-walk every access; `sfence.vma` is a no-op.
- SSTC extension — the spec rejects it; no `stimecmp` / `stime`.
- ASID tracking — `satp.ASID` stored as WARL 0 only.
- Interrupt cause handling (`scause.Interrupt` bit = 1) at trap entry — synchronous-only in 2.A.
- `PLIC` — Phase 3.

**Deviation from Plan 1.D's closing note:** none. Plan 1.D marked Phase 1 complete and named Phase 2 as "S-mode, Sv32 page tables, M↔S↔U privilege transitions, timer interrupt delivery". Plan 2.A implements the first three items' *emulator-side substrate* (S-mode privilege, Sv32, S-CSRs, sret/sfence); Plan 2.B adds delegation + timer-interrupt delivery; Plans 2.C/2.D are the kernel itself.

---

## File structure (final state at end of Plan 2.A)

```
ccc/
├── .gitignore
├── .gitmodules
├── build.zig                           ← MODIFIED (+rv32si family in riscv-tests; updated e2e expected outputs for new trace format)
├── build.zig.zon
├── README.md                           ← MODIFIED (status line; new ISA surface rows; trace format note)
├── src/
│   ├── main.zig                        ← UNCHANGED
│   ├── cpu.zig                         ← MODIFIED (+PrivilegeMode.S; +backing fields for SIE/SPIE/SPP/SUM/MXR/MPRV/TVM/TSR; +sscratch/satp/stvec/sepc/scause/stval storage)
│   ├── memory.zig                      ← MODIFIED (+translate() layer; callers wrap each load/store/fetch)
│   ├── decoder.zig                     ← MODIFIED (+Op.sret, +Op.sfence_vma; SYSTEM arm extended)
│   ├── execute.zig                     ← MODIFIED (+sret arm; +sfence_vma arm; +trap cause for load/store/fetch page faults)
│   ├── csr.zig                         ← MODIFIED (+S-CSR addresses and masks; +aliasing; +privilege checks; +TVM/TSR hooks)
│   ├── trap.zig                        ← MODIFIED (+page-fault causes; S-mode aware `mstatus.MPP` capture)
│   ├── elf.zig                         ← UNCHANGED
│   ├── trace.zig                       ← MODIFIED (+privilege column)
│   └── devices/
│       ├── halt.zig                    ← UNCHANGED
│       ├── uart.zig                    ← UNCHANGED
│       └── clint.zig                   ← UNCHANGED
└── tests/
    ├── programs/                       ← UNCHANGED (Phase 1 demos keep running; their trace-format expected outputs update)
    ├── riscv-tests/                    ← UNCHANGED (submodule)
    ├── riscv-tests-p.ld                ← UNCHANGED
    ├── riscv-tests-s.ld                ← NEW (link script for the rv32si-p family; places the S-mode shim at 0x80000000)
    └── riscv-tests-shim/
        └── riscv_test.h                ← UNCHANGED (still covers the rv32mi families)
```

**Module responsibilities (deltas vs Plan 1.D):**

- **`cpu.zig`** — `PrivilegeMode` enum grows by one variant `.S`. `CsrFile` grows with the six standalone S-CSR fields (`stvec`, `sscratch`, `sepc`, `scause`, `stval`, `satp`), plus the previously-zeroed `mstatus` fields now backed by real storage (`SIE`, `SPIE`, `SPP`, `SUM`, `MXR`, `MPRV`, `TVM`, `TSR`). `misa` becomes `0x40141101`. No API changes.
- **`csr.zig`** — `csrRead`/`csrWrite` gains S-CSR addresses. `sstatus` read/write implements the mask-in/mask-out pattern against `mstatus`. Same for `sie`/`sip` against `mie`/`mip`. Privilege check hoisted into a single `checkAccess(addr, priv, write_intent, *Cpu) !void` helper (Plan 1.C had a simpler check in the switch arms).
- **`decoder.zig`** — `Op` enum gets `sret` and `sfence_vma`. `decode`'s SYSTEM opcode arm, previously ecall/ebreak/mret/wfi only, grows: imm12=0x102 → `sret`; top7 == 0b0001001 → `sfence.vma` (stores rs1 and rs2). The 5-bit `csr` field representation of `sfence.vma` is not relevant (it's not a CSR op); the instruction uses the R-type layout even though its opcode is SYSTEM.
- **`execute.zig`** — `executeSret` function: check M/S privilege + `mstatus.TSR`; call `trap.exit_sret`. `executeSfenceVma` function: check M/S privilege + `mstatus.TVM`; no-op. Every existing load/store site is retargeted through `memory.loadWordChecked` / `memory.storeWordChecked` etc. wrappers that translate first and convert `TranslationFault` into a `trap.enter` call with the page-fault cause.
- **`memory.zig`** — `translate` function + `TranslationResult` tagged union. `loadWord`/`storeWord`/etc. gain a thin wrapper (or direct caller adaptation — decided in the plan task) that runs `translate` first. Instruction fetch (currently `loadWordPhysical` or similar) also goes through `translate(va, .fetch, cpu.privilege)`. MMIO dispatch stays keyed off *physical* addresses — after translation succeeds, we dispatch normally.
- **`trap.zig`** — `Cause` enum gains `inst_page_fault = 12`, `load_page_fault = 13`, `store_page_fault = 15`. `enter` is aware that `cpu.privilege` may be `.S` when captured into `mstatus.MPP`.
- **`trace.zig`** — `formatInstr` takes an additional `privilege` argument (computed from the pre-step CPU state) and emits it as `[M]`/`[S]`/`[U]` between PC and mnemonic.

---

## Conventions used in this plan

- All Zig code targets Zig 0.16.x. Same API surface as Plan 1.D.
- Tests live as inline `test "name" { ... }` blocks alongside the code under test. `zig build test` runs every test reachable from `src/main.zig`. No new source files are introduced in 2.A, so `main.zig`'s `comptime { _ = @import(...) }` block does not change.
- Each task ends with a TDD cycle: write failing test, see it fail, implement minimally, verify pass, commit. Commit messages follow Conventional Commits.
- When extending a grouped switch (the CSR address dispatch, the SYSTEM-opcode dispatch, the load/store execute arms), we show the full block so diffs are unambiguous.
- RISC-V spec bit positions and field encodings are quoted inline in tests when they appear in magic numbers, so a reviewer doesn't have to cross-reference.
- All new tests exercise a single behavioral contract. Where one logical contract has many cases (e.g., Sv32 permission checks under each `(effective_priv, PTE.U, SUM, MXR, access)` combination) we use `test "..."` blocks per case rather than table-driven, to keep failure messages pinpoint.
- Page-table setups inside tests use a small helper `buildPtLeaf(pa, flags)` + `buildPtRoot(leaf_pte_paddr)` constructed in the test rig; we avoid a shared test fixture that could mask bugs.

---

## Tasks

### Task 1: Add `PrivilegeMode.S` variant

**Files:**
- Modify: `src/cpu.zig` (the `PrivilegeMode` enum)
- Modify: `src/cpu.zig` tests (one new test)

**Why this task first:** Adding the enum variant is a single-line change that ripples through the codebase in a predictable way — the compiler surfaces every switch that doesn't cover `.S`. This task seeds the rest of the plan without introducing any new behavior yet.

- [ ] **Step 1: Write a failing test that asserts the enum has three variants**

Append to `src/cpu.zig` tests section:

```zig
test "PrivilegeMode has M, S, and U" {
    const m = PrivilegeMode.M;
    const s = PrivilegeMode.S;
    const u = PrivilegeMode.U;
    try std.testing.expect(m != s);
    try std.testing.expect(s != u);
    try std.testing.expect(u != m);
}
```

- [ ] **Step 2: Run the test to verify it fails (compile error)**

Run: `zig build test`
Expected: compile error about `PrivilegeMode.S` being unknown.

- [ ] **Step 3: Add the `.S` variant**

Find the `PrivilegeMode` enum declaration in `src/cpu.zig` and add `S`:

```zig
pub const PrivilegeMode = enum(u2) {
    U = 0b00,
    S = 0b01,
    M = 0b11,
};
```

Note the numeric values match the spec's 2-bit privilege-level encoding for `mstatus.MPP` / `sstatus.SPP`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test`
Expected: test "PrivilegeMode has M, S, and U" passes; all Phase 1 tests still pass. If any Phase 1 switch is now non-exhaustive, fix by adding an `else => unreachable` arm or by handling `.S` explicitly as "no-op same as `.U` for now" — the later tasks will fill in real behavior.

- [ ] **Step 5: Commit**

```bash
git add src/cpu.zig
git commit -m "feat(cpu): add PrivilegeMode.S variant"
```

---

### Task 2: Back `mstatus` S-mode fields (`SIE`, `SPIE`, `SPP`, `SUM`, `MXR`, `MPRV`, `TVM`, `TSR`) with real storage

**Files:**
- Modify: `src/cpu.zig` (the `CsrFile` struct + `mstatus` accessors)
- Modify: `src/csr.zig` (the `mstatus` read/write mask if one exists)
- Modify: `src/cpu.zig` tests

**Why now:** Plan 1.C backed only `MIE`, `MPIE`, `MPP` and read-as-zero everything else. Plan 2.A needs real storage for the S-related fields before any other change can use them. Doing it in isolation — one field-group, round-tripping reads — catches bit-layout bugs before they compound.

`mstatus` bit layout (RV32 M-view):
```
bit 0   — UIE (unused, WARL 0)
bit 1   — SIE
bit 3   — MIE    (Plan 1.C)
bit 5   — SPIE
bit 7   — MPIE   (Plan 1.C)
bit 8   — SPP
bit 11  — MPP[0]
bit 12  — MPP[1] (Plan 1.C)
bit 17  — MPRV
bit 18  — SUM
bit 19  — MXR
bit 20  — TVM
bit 21  — TW    (WARL 0)
bit 22  — TSR
bit 31  — SD    (read-only aggregate; 0 here since FS/VS/XS = 0)
```

- [ ] **Step 1: Write failing tests for each field's round-trip write/read behavior**

Append to `src/cpu.zig` tests:

```zig
test "mstatus SIE bit is writable and readable" {
    var cpu = Cpu.init(.{});
    try csr.csrWrite(&cpu, csr.CSR_MSTATUS, 1 << 1);
    try std.testing.expectEqual(@as(u32, 1 << 1), try csr.csrRead(&cpu, csr.CSR_MSTATUS) & (1 << 1));
}

test "mstatus SPIE bit is writable and readable" {
    var cpu = Cpu.init(.{});
    try csr.csrWrite(&cpu, csr.CSR_MSTATUS, 1 << 5);
    try std.testing.expectEqual(@as(u32, 1 << 5), try csr.csrRead(&cpu, csr.CSR_MSTATUS) & (1 << 5));
}

test "mstatus SPP bit is writable and readable" {
    var cpu = Cpu.init(.{});
    try csr.csrWrite(&cpu, csr.CSR_MSTATUS, 1 << 8);
    try std.testing.expectEqual(@as(u32, 1 << 8), try csr.csrRead(&cpu, csr.CSR_MSTATUS) & (1 << 8));
}

test "mstatus MPRV bit is writable and readable" {
    var cpu = Cpu.init(.{});
    try csr.csrWrite(&cpu, csr.CSR_MSTATUS, 1 << 17);
    try std.testing.expectEqual(@as(u32, 1 << 17), try csr.csrRead(&cpu, csr.CSR_MSTATUS) & (1 << 17));
}

test "mstatus SUM bit is writable and readable" {
    var cpu = Cpu.init(.{});
    try csr.csrWrite(&cpu, csr.CSR_MSTATUS, 1 << 18);
    try std.testing.expectEqual(@as(u32, 1 << 18), try csr.csrRead(&cpu, csr.CSR_MSTATUS) & (1 << 18));
}

test "mstatus MXR bit is writable and readable" {
    var cpu = Cpu.init(.{});
    try csr.csrWrite(&cpu, csr.CSR_MSTATUS, 1 << 19);
    try std.testing.expectEqual(@as(u32, 1 << 19), try csr.csrRead(&cpu, csr.CSR_MSTATUS) & (1 << 19));
}

test "mstatus TVM bit is writable and readable" {
    var cpu = Cpu.init(.{});
    try csr.csrWrite(&cpu, csr.CSR_MSTATUS, 1 << 20);
    try std.testing.expectEqual(@as(u32, 1 << 20), try csr.csrRead(&cpu, csr.CSR_MSTATUS) & (1 << 20));
}

test "mstatus TSR bit is writable and readable" {
    var cpu = Cpu.init(.{});
    try csr.csrWrite(&cpu, csr.CSR_MSTATUS, 1 << 22);
    try std.testing.expectEqual(@as(u32, 1 << 22), try csr.csrRead(&cpu, csr.CSR_MSTATUS) & (1 << 22));
}

test "mstatus UIE and TW remain zero (WARL)" {
    var cpu = Cpu.init(.{});
    try csr.csrWrite(&cpu, csr.CSR_MSTATUS, 0xFFFFFFFF);
    const v = try csr.csrRead(&cpu, csr.CSR_MSTATUS);
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 0)); // UIE
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 21)); // TW
}
```

- [ ] **Step 2: Run tests to verify they fail (reads return 0)**

Run: `zig build test`
Expected: the 8 new tests fail because the fields currently read as zero; the `UIE`/`TW` zero test may already pass.

- [ ] **Step 3: Add storage for the new fields in `CsrFile`**

Modify `src/cpu.zig`'s `CsrFile` struct. Current Plan 1.C layout:

```zig
pub const CsrFile = struct {
    mstatus_mie:  bool = false,
    mstatus_mpie: bool = false,
    mstatus_mpp:  u2   = 0,
    mtvec:        u32  = 0,
    mepc:         u32  = 0,
    mcause:       u32  = 0,
    mtval:        u32  = 0,
    mie:          u32  = 0,
    mip:          u32  = 0,
};
```

Replace with (retaining the existing fields):

```zig
pub const CsrFile = struct {
    // mstatus — split into per-field storage because the fields are scattered
    mstatus_sie:  bool = false,
    mstatus_mie:  bool = false,
    mstatus_spie: bool = false,
    mstatus_mpie: bool = false,
    mstatus_spp:  u1   = 0,
    mstatus_mpp:  u2   = 0,
    mstatus_mprv: bool = false,
    mstatus_sum:  bool = false,
    mstatus_mxr:  bool = false,
    mstatus_tvm:  bool = false,
    mstatus_tsr:  bool = false,
    // the rest unchanged
    mtvec:        u32  = 0,
    mepc:         u32  = 0,
    mcause:       u32  = 0,
    mtval:        u32  = 0,
    mie:          u32  = 0,
    mip:          u32  = 0,
    // placeholders for later tasks:
    stvec:        u32  = 0,
    sscratch:     u32  = 0,
    sepc:         u32  = 0,
    scause:       u32  = 0,
    stval:        u32  = 0,
    satp:         u32  = 0,
};
```

- [ ] **Step 4: Update `mstatus` read/write in `csr.zig`**

Find the `csrRead` arm for `CSR_MSTATUS` and rewrite:

```zig
CSR_MSTATUS => blk: {
    var v: u32 = 0;
    if (cpu.csr.mstatus_sie)  v |= 1 << 1;
    if (cpu.csr.mstatus_mie)  v |= 1 << 3;
    if (cpu.csr.mstatus_spie) v |= 1 << 5;
    if (cpu.csr.mstatus_mpie) v |= 1 << 7;
    v |= @as(u32, cpu.csr.mstatus_spp) << 8;
    v |= @as(u32, cpu.csr.mstatus_mpp) << 11;
    if (cpu.csr.mstatus_mprv) v |= 1 << 17;
    if (cpu.csr.mstatus_sum)  v |= 1 << 18;
    if (cpu.csr.mstatus_mxr)  v |= 1 << 19;
    if (cpu.csr.mstatus_tvm)  v |= 1 << 20;
    if (cpu.csr.mstatus_tsr)  v |= 1 << 22;
    break :blk v;
},
```

Find the `csrWrite` arm and rewrite:

```zig
CSR_MSTATUS => {
    cpu.csr.mstatus_sie  = (value & (1 << 1))  != 0;
    cpu.csr.mstatus_mie  = (value & (1 << 3))  != 0;
    cpu.csr.mstatus_spie = (value & (1 << 5))  != 0;
    cpu.csr.mstatus_mpie = (value & (1 << 7))  != 0;
    cpu.csr.mstatus_spp  = @intCast((value >> 8) & 0x1);
    // MPP: writes of 0b10 are WARL-clamped to 0b00 (we only support M/S/U)
    const mpp_raw: u2 = @intCast((value >> 11) & 0x3);
    cpu.csr.mstatus_mpp = if (mpp_raw == 0b10) 0 else mpp_raw;
    cpu.csr.mstatus_mprv = (value & (1 << 17)) != 0;
    cpu.csr.mstatus_sum  = (value & (1 << 18)) != 0;
    cpu.csr.mstatus_mxr  = (value & (1 << 19)) != 0;
    cpu.csr.mstatus_tvm  = (value & (1 << 20)) != 0;
    cpu.csr.mstatus_tsr  = (value & (1 << 22)) != 0;
},
```

- [ ] **Step 5: Update trap entry/exit in `trap.zig` for the new field names**

Find `trap.enter` and `trap.exit_mret`. Rewrite to use the new field names verbatim (`mstatus_mie` → `mstatus_mie`, etc.). If you had `cpu.csr.mstatus.mie` syntax before, switch to the flat `cpu.csr.mstatus_mie` form:

```zig
pub fn enter(cause: Cause, tval: u32, cpu: *Cpu) void {
    cpu.reservation = null;
    cpu.csr.mepc   = cpu.pc;
    cpu.csr.mcause = @intFromEnum(cause);
    cpu.csr.mtval  = tval;
    cpu.csr.mstatus_mpp  = @intFromEnum(cpu.privilege);
    cpu.csr.mstatus_mpie = cpu.csr.mstatus_mie;
    cpu.csr.mstatus_mie  = false;
    cpu.privilege = .M;
    cpu.pc = cpu.csr.mtvec & ~@as(u32, 0x3);
}

pub fn exit_mret(cpu: *Cpu) void {
    cpu.pc = cpu.csr.mepc;
    cpu.privilege = @enumFromInt(cpu.csr.mstatus_mpp);
    cpu.csr.mstatus_mie  = cpu.csr.mstatus_mpie;
    cpu.csr.mstatus_mpie = true;
    cpu.csr.mstatus_mpp  = @intFromEnum(PrivilegeMode.U);
}
```

Note `mstatus_mpp` now holds a raw u2 rather than an enum; do the enum conversion in the trap exit path. The enum values were chosen to match the spec encoding (Task 1), so this conversion is bit-for-bit stable.

- [ ] **Step 6: Run tests to verify they pass**

Run: `zig build test`
Expected: all 8 new tests pass, all Plan 1.D tests still pass.

- [ ] **Step 7: Commit**

```bash
git add src/cpu.zig src/csr.zig src/trap.zig
git commit -m "feat(csr): back mstatus S-mode and control fields with real storage"
```

---

### Task 3: Bump `misa` to advertise S-mode (`'S'` bit)

**Files:**
- Modify: `src/csr.zig` (the `misa` read value)
- Modify: `src/csr.zig` tests

**Why now:** Small, isolated. Needs to land before any external code (like the rv32si tests) reads `misa`.

- [ ] **Step 1: Write a failing test**

Append to `src/csr.zig` tests:

```zig
test "misa encodes RV32 I+M+A+S+U" {
    var cpu = Cpu.init(.{});
    const v = try csr.csrRead(&cpu, csr.CSR_MISA);
    // MXL = 01 (RV32) in bits 31:30
    try std.testing.expectEqual(@as(u32, 0b01), (v >> 30) & 0x3);
    // extensions: I (bit 8), M (bit 12), A (bit 0), S (bit 18), U (bit 20)
    try std.testing.expect((v & (1 << 8))  != 0);   // I
    try std.testing.expect((v & (1 << 12)) != 0);   // M
    try std.testing.expect((v & (1 << 0))  != 0);   // A
    try std.testing.expect((v & (1 << 18)) != 0);   // S
    try std.testing.expect((v & (1 << 20)) != 0);   // U
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test`
Expected: the `'S'` bit assertion fails.

- [ ] **Step 3: Update the `misa` constant**

In `src/csr.zig`, find the `misa` return value (Plan 1.C set it to `0x40101101` = MXL=01 | I | M | A | U). Update to include S:

```zig
// MXL=01 (RV32) at bits 31:30, plus extension bits A(0), I(8), M(12), S(18), U(20)
const MISA_VALUE: u32 = (0b01 << 30) | (1 << 20) | (1 << 18) | (1 << 12) | (1 << 8) | (1 << 0);
```

Replace `0x40101101` wherever it appears with `MISA_VALUE`. For reference, `MISA_VALUE == 0x40141101`.

- [ ] **Step 4: Run to verify**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/csr.zig
git commit -m "feat(csr): advertise S-mode in misa"
```

---

### Task 4: Standalone S-CSRs — `stvec`, `sscratch`, `sepc`, `scause`, `stval`

**Files:**
- Modify: `src/csr.zig` (address constants + read/write arms)
- Modify: `src/csr.zig` tests

**Why now:** These five CSRs don't alias anything — they're independent u32 fields that Task 2 already added to `CsrFile`. Wiring them into `csrRead`/`csrWrite` is mechanical and can be done before the more subtle `sstatus` / `sie` / `sip` / `satp` aliasing CSRs.

- [ ] **Step 1: Add address constants**

At the top of `src/csr.zig` (where `CSR_MSTATUS` etc. live), add:

```zig
pub const CSR_STVEC    : u12 = 0x105;
pub const CSR_SSCRATCH : u12 = 0x140;
pub const CSR_SEPC     : u12 = 0x141;
pub const CSR_SCAUSE   : u12 = 0x142;
pub const CSR_STVAL    : u12 = 0x143;
```

- [ ] **Step 2: Write failing tests**

Append to `src/csr.zig` tests:

```zig
test "stvec round-trip" {
    var cpu = Cpu.init(.{});
    try csr.csrWrite(&cpu, csr.CSR_STVEC, 0x8000_1000);
    try std.testing.expectEqual(@as(u32, 0x8000_1000), try csr.csrRead(&cpu, csr.CSR_STVEC));
}

test "sscratch round-trip" {
    var cpu = Cpu.init(.{});
    try csr.csrWrite(&cpu, csr.CSR_SSCRATCH, 0xdead_beef);
    try std.testing.expectEqual(@as(u32, 0xdead_beef), try csr.csrRead(&cpu, csr.CSR_SSCRATCH));
}

test "sepc round-trip" {
    var cpu = Cpu.init(.{});
    try csr.csrWrite(&cpu, csr.CSR_SEPC, 0x1234_5678);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), try csr.csrRead(&cpu, csr.CSR_SEPC));
}

test "scause round-trip" {
    var cpu = Cpu.init(.{});
    try csr.csrWrite(&cpu, csr.CSR_SCAUSE, 0x8000_0005);
    try std.testing.expectEqual(@as(u32, 0x8000_0005), try csr.csrRead(&cpu, csr.CSR_SCAUSE));
}

test "stval round-trip" {
    var cpu = Cpu.init(.{});
    try csr.csrWrite(&cpu, csr.CSR_STVAL, 0x0001_0000);
    try std.testing.expectEqual(@as(u32, 0x0001_0000), try csr.csrRead(&cpu, csr.CSR_STVAL));
}
```

- [ ] **Step 3: Run to verify failures**

Run: `zig build test`
Expected: the 5 new tests fail because the CSR addresses aren't dispatched.

- [ ] **Step 4: Add read/write arms**

In `csrRead`, add:

```zig
CSR_STVEC    => cpu.csr.stvec,
CSR_SSCRATCH => cpu.csr.sscratch,
CSR_SEPC     => cpu.csr.sepc,
CSR_SCAUSE   => cpu.csr.scause,
CSR_STVAL    => cpu.csr.stval,
```

In `csrWrite`, add:

```zig
CSR_STVEC    => cpu.csr.stvec    = value,
CSR_SSCRATCH => cpu.csr.sscratch = value,
CSR_SEPC     => cpu.csr.sepc     = value,
CSR_SCAUSE   => cpu.csr.scause   = value,
CSR_STVAL    => cpu.csr.stval    = value,
```

- [ ] **Step 5: Run to verify**

Run: `zig build test`
Expected: all 5 new tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/csr.zig
git commit -m "feat(csr): add stvec, sscratch, sepc, scause, stval"
```

---

### Task 5: `sstatus` as a masked view of `mstatus`

**Files:**
- Modify: `src/csr.zig` (address constant + read/write arms)
- Modify: `src/csr.zig` tests

**Why now:** `sstatus` is the first aliased CSR. Getting the mask right is the whole task; it needs its own TDD cycle.

**Mask (S-visible bits of `mstatus` in RV32):** `SIE` (1), `SPIE` (5), `UBE` (6, WARL 0), `SPP` (8), `VS/FS/XS` (9–16, WARL 0 here), `SUM` (18), `MXR` (19), `SD` (31, read-only). Writable bits from S: `SIE`, `SPIE`, `SPP`, `SUM`, `MXR`. Readable (possibly via write-back of 0): everything in the mask.

- [ ] **Step 1: Add address constant**

```zig
pub const CSR_SSTATUS : u12 = 0x100;
```

And define the sstatus mask:

```zig
// sstatus visible/writable field mask (RV32)
const SSTATUS_WRITABLE_MASK: u32 =
    (1 << 1)  |  // SIE
    (1 << 5)  |  // SPIE
    (1 << 8)  |  // SPP
    (1 << 18) |  // SUM
    (1 << 19);   // MXR
const SSTATUS_READ_MASK: u32 = SSTATUS_WRITABLE_MASK;  // no read-only bits in our subset
```

- [ ] **Step 2: Write failing tests**

```zig
test "sstatus reads the S-visible subset of mstatus" {
    var cpu = Cpu.init(.{});
    // set a full bag of mstatus bits via the M-mode write path
    try csr.csrWrite(&cpu, csr.CSR_MSTATUS,
        (1 << 1)  | (1 << 3)  | (1 << 5)  | (1 << 7) |
        (1 << 8)  | (3 << 11) | (1 << 17) | (1 << 18) |
        (1 << 19) | (1 << 20) | (1 << 22));
    // read sstatus — should expose only the S-visible bits
    const s = try csr.csrRead(&cpu, csr.CSR_SSTATUS);
    const expected: u32 = (1 << 1) | (1 << 5) | (1 << 8) | (1 << 18) | (1 << 19);
    try std.testing.expectEqual(expected, s);
}

test "sstatus write affects only the writable bits of mstatus" {
    var cpu = Cpu.init(.{});
    // pre-populate mstatus with some M-only bits we expect to survive
    try csr.csrWrite(&cpu, csr.CSR_MSTATUS, (1 << 3) | (1 << 7) | (1 << 17) | (1 << 20) | (1 << 22));
    // write all-ones through sstatus
    try csr.csrWrite(&cpu, csr.CSR_SSTATUS, 0xFFFF_FFFF);
    const m = try csr.csrRead(&cpu, csr.CSR_MSTATUS);
    // M-only bits preserved
    try std.testing.expect((m & (1 << 3))  != 0); // MIE
    try std.testing.expect((m & (1 << 7))  != 0); // MPIE
    try std.testing.expect((m & (1 << 17)) != 0); // MPRV
    try std.testing.expect((m & (1 << 20)) != 0); // TVM
    try std.testing.expect((m & (1 << 22)) != 0); // TSR
    // S-writable bits set to 1
    try std.testing.expect((m & (1 << 1))  != 0); // SIE
    try std.testing.expect((m & (1 << 5))  != 0); // SPIE
    try std.testing.expect((m & (1 << 8))  != 0); // SPP
    try std.testing.expect((m & (1 << 18)) != 0); // SUM
    try std.testing.expect((m & (1 << 19)) != 0); // MXR
}
```

- [ ] **Step 3: Run to verify failures**

Run: `zig build test`
Expected: both new tests fail (unknown CSR address).

- [ ] **Step 4: Add `sstatus` read/write arms**

In `csrRead`:

```zig
CSR_SSTATUS => (try csrRead(cpu, CSR_MSTATUS)) & SSTATUS_READ_MASK,
```

In `csrWrite`:

```zig
CSR_SSTATUS => {
    const current = try csrRead(cpu, CSR_MSTATUS);
    const merged  = (current & ~SSTATUS_WRITABLE_MASK) | (value & SSTATUS_WRITABLE_MASK);
    try csrWrite(cpu, CSR_MSTATUS, merged);
},
```

Note: `csrWrite` to `CSR_MSTATUS` ignores bits outside its own mask (WARL bits UIE/TW are dropped on that path), so the merged write is safe.

- [ ] **Step 5: Run to verify**

Run: `zig build test`
Expected: both new tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/csr.zig
git commit -m "feat(csr): add sstatus as masked view of mstatus"
```

---

### Task 6: `sie` and `sip` as masked views of `mie` and `mip`

**Files:**
- Modify: `src/csr.zig`
- Modify: `src/csr.zig` tests

**Why now:** Structurally identical to `sstatus` aliasing — same test pattern, same read-mask/write-mask design. Keep it separate so any bug lands in one test, not a compound one.

**Mask (S-writable bits of mie/mip):** `SSIE/SSIP` (bit 1), `STIE/STIP` (bit 5), `SEIE/SEIP` (bit 9). The S-mode view can read these through sie/sip; writes to sie propagate to mie's bits {1, 5, 9} only; writes to sip propagate to mip's bit {1} only (bits 5 and 9 of sip are read-only from S-mode — STIP is hardware/M-software-maintained; SEIP is external-interrupt-controller-maintained in the general case).

For Plan 2.A, we take a small simplification: sip writes propagate **only to bit 1 (SSIP)** because that's the one S-mode legitimately writes. Bits 5 and 9 of mip are M-only.

- [ ] **Step 1: Add constants and masks**

```zig
pub const CSR_SIE : u12 = 0x104;
pub const CSR_SIP : u12 = 0x144;

const SIE_MASK : u32 = (1 << 1) | (1 << 5) | (1 << 9);  // SSIE | STIE | SEIE — reads and writes
const SIP_READ_MASK  : u32 = (1 << 1) | (1 << 5) | (1 << 9);  // SSIP | STIP | SEIP reads
const SIP_WRITE_MASK : u32 = (1 << 1);                         // only SSIP writable from S
```

- [ ] **Step 2: Write failing tests**

```zig
test "sie reads the S-visible bits of mie" {
    var cpu = Cpu.init(.{});
    try csr.csrWrite(&cpu, csr.CSR_MIE,
        (1 << 1) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 9) | (1 << 11));
    const s = try csr.csrRead(&cpu, csr.CSR_SIE);
    try std.testing.expectEqual(@as(u32, (1 << 1) | (1 << 5) | (1 << 9)), s);
}

test "sie write merges into mie preserving M-only bits" {
    var cpu = Cpu.init(.{});
    try csr.csrWrite(&cpu, csr.CSR_MIE, (1 << 3) | (1 << 7) | (1 << 11));  // M-only
    try csr.csrWrite(&cpu, csr.CSR_SIE, 0xFFFF_FFFF);
    const m = try csr.csrRead(&cpu, csr.CSR_MIE);
    try std.testing.expect((m & (1 << 3))  != 0); // MSIE
    try std.testing.expect((m & (1 << 7))  != 0); // MTIE
    try std.testing.expect((m & (1 << 11)) != 0); // MEIE
    try std.testing.expect((m & (1 << 1))  != 0); // SSIE
    try std.testing.expect((m & (1 << 5))  != 0); // STIE
    try std.testing.expect((m & (1 << 9))  != 0); // SEIE
}

test "sip reads SSIP/STIP/SEIP from mip" {
    var cpu = Cpu.init(.{});
    try csr.csrWrite(&cpu, csr.CSR_MIP, (1 << 1) | (1 << 5) | (1 << 9));
    const s = try csr.csrRead(&cpu, csr.CSR_SIP);
    try std.testing.expectEqual(@as(u32, (1 << 1) | (1 << 5) | (1 << 9)), s);
}

test "sip writes only SSIP into mip" {
    var cpu = Cpu.init(.{});
    try csr.csrWrite(&cpu, csr.CSR_MIP, (1 << 7) | (1 << 5));  // M-only + STIP
    try csr.csrWrite(&cpu, csr.CSR_SIP, 0xFFFF_FFFF);
    const m = try csr.csrRead(&cpu, csr.CSR_MIP);
    try std.testing.expect((m & (1 << 7)) != 0);  // MTIP preserved
    try std.testing.expect((m & (1 << 5)) != 0);  // STIP preserved (not S-writable via sip)
    try std.testing.expect((m & (1 << 1)) != 0);  // SSIP set by sip write
    try std.testing.expect((m & (1 << 9)) == 0);  // SEIP NOT set (not in sip write-mask)
}
```

- [ ] **Step 3: Run to verify failures**

Run: `zig build test`
Expected: 4 tests fail (unknown CSR addresses).

- [ ] **Step 4: Add read/write arms**

```zig
CSR_SIE => cpu.csr.mie & SIE_MASK,
CSR_SIP => cpu.csr.mip & SIP_READ_MASK,
```

And in writes:

```zig
CSR_SIE => cpu.csr.mie = (cpu.csr.mie & ~SIE_MASK) | (value & SIE_MASK),
CSR_SIP => cpu.csr.mip = (cpu.csr.mip & ~SIP_WRITE_MASK) | (value & SIP_WRITE_MASK),
```

- [ ] **Step 5: Run to verify**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/csr.zig
git commit -m "feat(csr): add sie/sip as masked views of mie/mip"
```

---

### Task 7: `satp` CSR with MODE validation

**Files:**
- Modify: `src/csr.zig`
- Modify: `src/csr.zig` tests

**Why now:** `satp` is standalone (already has storage from Task 2). This task wires read/write with MODE-bit WARL validation — writes of unsupported MODE clamp to Bare (MODE=0).

- [ ] **Step 1: Add constant**

```zig
pub const CSR_SATP : u12 = 0x180;

pub const SATP_MODE_BARE : u32 = 0;
pub const SATP_MODE_SV32 : u32 = 1;
pub const SATP_MODE_MASK : u32 = 1 << 31;
pub const SATP_PPN_MASK  : u32 = (1 << 22) - 1;
// ASID bits 30:22 — WARL 0 in our implementation.
```

- [ ] **Step 2: Write failing tests**

```zig
test "satp accepts MODE=Bare" {
    var cpu = Cpu.init(.{});
    try csr.csrWrite(&cpu, csr.CSR_SATP, 0x0000_0000);
    try std.testing.expectEqual(@as(u32, 0), try csr.csrRead(&cpu, csr.CSR_SATP));
}

test "satp accepts MODE=Sv32 with PPN" {
    var cpu = Cpu.init(.{});
    const written: u32 = (1 << 31) | 0x1234;  // MODE=Sv32, PPN=0x1234
    try csr.csrWrite(&cpu, csr.CSR_SATP, written);
    try std.testing.expectEqual(written, try csr.csrRead(&cpu, csr.CSR_SATP));
}

test "satp ASID bits are WARL 0" {
    var cpu = Cpu.init(.{});
    const attempt: u32 = (1 << 31) | (0x1FF << 22) | 0x5678;  // try setting ASID=0x1FF
    try csr.csrWrite(&cpu, csr.CSR_SATP, attempt);
    const v = try csr.csrRead(&cpu, csr.CSR_SATP);
    try std.testing.expectEqual(@as(u32, 0), (v >> 22) & 0x1FF);
    // MODE and PPN preserved
    try std.testing.expect((v & (1 << 31)) != 0);
    try std.testing.expectEqual(@as(u32, 0x5678), v & SATP_PPN_MASK);
}
```

- [ ] **Step 3: Run to verify failures**

Run: `zig build test`
Expected: the 3 new tests fail.

- [ ] **Step 4: Add read/write arms**

```zig
CSR_SATP => cpu.csr.satp,
```

And:

```zig
CSR_SATP => {
    // MODE: accept 0 or 1; anything else clamps to Bare
    const mode_bit = value & SATP_MODE_MASK;
    const ppn      = value & SATP_PPN_MASK;
    // ASID: WARL 0
    cpu.csr.satp = mode_bit | ppn;
},
```

- [ ] **Step 5: Run to verify**

Run: `zig build test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/csr.zig
git commit -m "feat(csr): add satp with MODE+PPN fields (ASID WARL 0)"
```

---

### Task 8: CSR access privilege check for S-mode CSRs

**Files:**
- Modify: `src/csr.zig` (add `checkAccess` helper)
- Modify: `src/csr.zig` tests

**Why now:** S-mode and U-mode must not be able to read/write CSRs above their privilege. Plan 1.C had a simpler check (U-mode → illegal everything); Plan 2.A needs a three-way check.

Rule: RISC-V CSR address bits 9:8 encode the lowest privilege that can access that CSR (0b00=user, 0b01=supervisor, 0b10=hypervisor, 0b11=machine). Bits 11:10 encode accessibility (0b00–0b10 read-write, 0b11 read-only). We translate: `cpu.privilege < required` → illegal.

- [ ] **Step 1: Write failing tests**

```zig
test "U-mode cannot read mstatus" {
    var cpu = Cpu.init(.{});
    cpu.privilege = .U;
    try std.testing.expectError(error.IllegalInstruction, csr.csrRead(&cpu, csr.CSR_MSTATUS));
}

test "U-mode cannot read sstatus" {
    var cpu = Cpu.init(.{});
    cpu.privilege = .U;
    try std.testing.expectError(error.IllegalInstruction, csr.csrRead(&cpu, csr.CSR_SSTATUS));
}

test "S-mode cannot read mstatus" {
    var cpu = Cpu.init(.{});
    cpu.privilege = .S;
    try std.testing.expectError(error.IllegalInstruction, csr.csrRead(&cpu, csr.CSR_MSTATUS));
}

test "S-mode can read sstatus" {
    var cpu = Cpu.init(.{});
    cpu.privilege = .S;
    _ = try csr.csrRead(&cpu, csr.CSR_SSTATUS);  // should not error
}

test "M-mode can read mstatus and sstatus" {
    var cpu = Cpu.init(.{});
    cpu.privilege = .M;
    _ = try csr.csrRead(&cpu, csr.CSR_MSTATUS);
    _ = try csr.csrRead(&cpu, csr.CSR_SSTATUS);
}
```

- [ ] **Step 2: Run to verify failures**

Run: `zig build test`
Expected: `S-mode cannot read mstatus` fails (current Plan 1.C code doesn't restrict S).

- [ ] **Step 3: Add the privilege helper**

In `src/csr.zig`, above `csrRead`/`csrWrite`:

```zig
fn requiredPriv(addr: u12) PrivilegeMode {
    // CSR address bits 9:8 encode the lowest privilege.
    const priv_bits: u2 = @intCast((addr >> 8) & 0x3);
    return switch (priv_bits) {
        0b00 => .U,
        0b01 => .S,
        0b10 => .S,  // hypervisor — we don't model it; treat as S-accessible
        0b11 => .M,
    };
}

fn checkAccess(addr: u12, priv: PrivilegeMode) !void {
    const need = requiredPriv(addr);
    const priv_rank = @intFromEnum(priv);
    const need_rank = @intFromEnum(need);
    if (priv_rank < need_rank) return error.IllegalInstruction;
}
```

Note: `PrivilegeMode`'s numeric values (U=0, S=1, M=3) are monotonic in privilege level, so `<` comparison works.

- [ ] **Step 4: Call `checkAccess` at the top of `csrRead` and `csrWrite`**

```zig
pub fn csrRead(cpu: *Cpu, addr: u12) !u32 {
    try checkAccess(addr, cpu.privilege);
    // ... existing switch ...
}

pub fn csrWrite(cpu: *Cpu, addr: u12, value: u32) !void {
    try checkAccess(addr, cpu.privilege);
    // ... existing switch ...
}
```

- [ ] **Step 5: Run to verify**

Run: `zig build test`
Expected: all tests pass, including Plan 1.C's "U-mode cannot access CSRs" test.

- [ ] **Step 6: Commit**

```bash
git add src/csr.zig
git commit -m "feat(csr): enforce per-CSR minimum privilege via address-field check"
```

---

### Task 9: Decode `sret`

**Files:**
- Modify: `src/decoder.zig`
- Modify: `src/decoder.zig` tests

**Why now:** Decoding is pure and can be landed/tested ahead of execution.

`sret` encoding: opcode = 0b1110011 (SYSTEM), funct3 = 000, imm12 = 0x102, rs1 = 0, rd = 0. Full 32-bit word: `0x10200073`.

- [ ] **Step 1: Write a failing test**

Append to `src/decoder.zig` tests:

```zig
test "decode: sret" {
    const ins = try decoder.decode(0x10200073);
    try std.testing.expectEqual(decoder.Op.sret, ins.op);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test`
Expected: compile error (unknown variant).

- [ ] **Step 3: Add the variant + decode arm**

In `src/decoder.zig`, add to `Op`:

```zig
pub const Op = enum {
    // ... existing variants ...
    sret,
};
```

Find the SYSTEM opcode dispatch (funct3 == 000 branch) and add:

```zig
0x102 => .{ .op = .sret, ... zeroed fields ... },  // sret
```

(The surrounding dispatch checks `imm12`; mirror the shape of the existing `mret` = 0x302 arm.)

- [ ] **Step 4: Run to verify**

Run: `zig build test`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add src/decoder.zig
git commit -m "feat(decoder): decode sret"
```

---

### Task 10: Decode `sfence.vma`

**Files:**
- Modify: `src/decoder.zig`
- Modify: `src/decoder.zig` tests

**Why now:** Same category as Task 9; pure decode.

`sfence.vma` encoding: opcode = 0b1110011 (SYSTEM), funct3 = 000, top7 = 0b0001001, rs1 = VA reg, rs2 = ASID reg, rd = 0. Examples:
- `sfence.vma zero, zero` (flush all) = `0x12000073`.
- `sfence.vma t0, zero` = `0x12028073`.

- [ ] **Step 1: Write failing tests**

```zig
test "decode: sfence.vma zero, zero" {
    const ins = try decoder.decode(0x12000073);
    try std.testing.expectEqual(decoder.Op.sfence_vma, ins.op);
    try std.testing.expectEqual(@as(u5, 0), ins.rs1);
    try std.testing.expectEqual(@as(u5, 0), ins.rs2);
}

test "decode: sfence.vma t0, t1 captures rs1 and rs2" {
    // rs1=5 (t0), rs2=6 (t1), top7=0b0001001
    const word: u32 = (0b0001001 << 25) | (6 << 20) | (5 << 15) | (0 << 12) | (0 << 7) | 0b1110011;
    const ins = try decoder.decode(word);
    try std.testing.expectEqual(decoder.Op.sfence_vma, ins.op);
    try std.testing.expectEqual(@as(u5, 5), ins.rs1);
    try std.testing.expectEqual(@as(u5, 6), ins.rs2);
}
```

- [ ] **Step 2: Run to verify failures**

Run: `zig build test`
Expected: compile error.

- [ ] **Step 3: Add variant + decode arm**

```zig
pub const Op = enum {
    // ...
    sret,
    sfence_vma,
};
```

In the SYSTEM funct3=000 dispatch, distinguish by top7:

```zig
// Within the funct3=000 arm of the SYSTEM opcode handler:
const top7: u7 = @intCast((raw >> 25) & 0x7F);
if (top7 == 0b0001001) {
    // sfence.vma — capture rs1 and rs2
    const rs1: u5 = @intCast((raw >> 15) & 0x1F);
    const rs2: u5 = @intCast((raw >> 20) & 0x1F);
    return .{ .op = .sfence_vma, .rs1 = rs1, .rs2 = rs2, /* rd=0, imm=0 */ };
}
// fall through to existing imm12-based dispatch for mret/sret/ecall/ebreak/wfi
```

- [ ] **Step 4: Run to verify**

Run: `zig build test`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add src/decoder.zig
git commit -m "feat(decoder): decode sfence.vma"
```

---

### Task 11: Execute `sret`

**Files:**
- Modify: `src/trap.zig` (+ `exit_sret`)
- Modify: `src/execute.zig` (+ sret arm)
- Modify: `src/execute.zig` tests

**Why now:** Small isolated feature. Depends on Task 2 (SPIE/SPP storage) + Task 9 (decoder).

- [ ] **Step 1: Write failing tests**

Append to `src/execute.zig` tests:

```zig
test "sret returns from S-mode to U-mode per sstatus.SPP" {
    var cpu = Cpu.init(.{});
    // set up pre-sret state: we're in S-mode, SPP=U, sepc = some target
    cpu.privilege = .S;
    cpu.csr.mstatus_spp = 0;      // SPP = U
    cpu.csr.mstatus_spie = true;  // SPIE = 1 — will become SIE after sret
    cpu.csr.sepc = 0x8001_0000;

    const ins = try decoder.decode(0x10200073); // sret
    try execute.dispatch(ins, &cpu, &mem);      // `mem` is a test-rig Memory

    try std.testing.expectEqual(PrivilegeMode.U, cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8001_0000), cpu.pc);
    try std.testing.expectEqual(true, cpu.csr.mstatus_sie);
    try std.testing.expectEqual(true, cpu.csr.mstatus_spie); // now 1 per spec
    try std.testing.expectEqual(@as(u1, 0), cpu.csr.mstatus_spp);  // reset to U
}

test "sret from U-mode is illegal" {
    var cpu = Cpu.init(.{});
    cpu.privilege = .U;
    cpu.csr.mtvec = 0x8000_1000;  // so the illegal trap lands somewhere deterministic

    const ins = try decoder.decode(0x10200073);
    try execute.dispatch(ins, &cpu, &mem);

    // We expect a trap to M with cause = illegal
    try std.testing.expectEqual(@as(u32, @intFromEnum(trap.Cause.illegal_instruction)), cpu.csr.mcause);
    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
}

test "sret from S with mstatus.TSR=1 is illegal" {
    var cpu = Cpu.init(.{});
    cpu.privilege = .S;
    cpu.csr.mstatus_tsr = true;
    cpu.csr.mtvec = 0x8000_1000;

    const ins = try decoder.decode(0x10200073);
    try execute.dispatch(ins, &cpu, &mem);

    try std.testing.expectEqual(@as(u32, @intFromEnum(trap.Cause.illegal_instruction)), cpu.csr.mcause);
    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
}
```

The test file already uses a `TestRig` pattern; if the existing rig doesn't expose `&mem` as a mutable `*Memory`, follow the Plan 1.C pattern (use `rig.memory()` or similar).

- [ ] **Step 2: Run to verify failures**

Run: `zig build test`
Expected: the 3 new tests fail (no `sret` execute arm).

- [ ] **Step 3: Add `trap.exit_sret`**

In `src/trap.zig`, add:

```zig
pub fn exit_sret(cpu: *Cpu) void {
    cpu.pc = cpu.csr.sepc;
    cpu.privilege = if (cpu.csr.mstatus_spp == 1) .S else .U;
    cpu.csr.mstatus_sie  = cpu.csr.mstatus_spie;
    cpu.csr.mstatus_spie = true;
    cpu.csr.mstatus_spp  = 0;  // reset to U
}
```

- [ ] **Step 4: Add `sret` execute arm**

In `src/execute.zig`'s dispatch switch:

```zig
.sret => {
    // Privilege check: M or S only
    if (cpu.privilege == .U) {
        trap.enter(.illegal_instruction, 0, cpu);
        return;
    }
    // S-mode with TSR trap-sret check
    if (cpu.privilege == .S and cpu.csr.mstatus_tsr) {
        trap.enter(.illegal_instruction, 0, cpu);
        return;
    }
    trap.exit_sret(cpu);
},
```

- [ ] **Step 5: Run to verify**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/execute.zig src/trap.zig
git commit -m "feat(execute): sret returns from S-mode honoring TSR"
```

---

### Task 12: Execute `sfence.vma` as a privileged no-op

**Files:**
- Modify: `src/execute.zig`
- Modify: `src/execute.zig` tests

- [ ] **Step 1: Write failing tests**

```zig
test "sfence.vma from U-mode is illegal" {
    var cpu = Cpu.init(.{});
    cpu.privilege = .U;
    cpu.csr.mtvec = 0x8000_1000;
    const ins = try decoder.decode(0x12000073);
    try execute.dispatch(ins, &cpu, &mem);
    try std.testing.expectEqual(@as(u32, @intFromEnum(trap.Cause.illegal_instruction)), cpu.csr.mcause);
}

test "sfence.vma from S with TVM=1 is illegal" {
    var cpu = Cpu.init(.{});
    cpu.privilege = .S;
    cpu.csr.mstatus_tvm = true;
    cpu.csr.mtvec = 0x8000_1000;
    const ins = try decoder.decode(0x12000073);
    try execute.dispatch(ins, &cpu, &mem);
    try std.testing.expectEqual(@as(u32, @intFromEnum(trap.Cause.illegal_instruction)), cpu.csr.mcause);
}

test "sfence.vma from M-mode is a PC-advancing no-op" {
    var cpu = Cpu.init(.{});
    cpu.privilege = .M;
    cpu.pc = 0x8000_0000;
    const ins = try decoder.decode(0x12000073);
    try execute.dispatch(ins, &cpu, &mem);
    try std.testing.expectEqual(@as(u32, 0x8000_0004), cpu.pc);
}

test "sfence.vma from S with TVM=0 is a PC-advancing no-op" {
    var cpu = Cpu.init(.{});
    cpu.privilege = .S;
    cpu.csr.mstatus_tvm = false;
    cpu.pc = 0x8000_0000;
    const ins = try decoder.decode(0x12000073);
    try execute.dispatch(ins, &cpu, &mem);
    try std.testing.expectEqual(@as(u32, 0x8000_0004), cpu.pc);
}
```

- [ ] **Step 2: Run to verify failures**

Run: `zig build test`
Expected: 4 tests fail (no sfence_vma arm).

- [ ] **Step 3: Add the dispatch arm**

```zig
.sfence_vma => {
    if (cpu.privilege == .U) {
        trap.enter(.illegal_instruction, 0, cpu);
        return;
    }
    if (cpu.privilege == .S and cpu.csr.mstatus_tvm) {
        trap.enter(.illegal_instruction, 0, cpu);
        return;
    }
    // No TLB modeled — nothing to invalidate. PC advances as for any other insn.
    cpu.pc +%= 4;
},
```

Note: the normal `pc += 4` step typically happens at the top or bottom of `step()`. Follow the Plan 1.C convention — if `step()` advances PC around `dispatch`, make this arm a no-op body; if not, do the increment here. Look for the pattern used by other SYSTEM instructions (`ecall`, `mret`) and mirror it.

- [ ] **Step 4: Run to verify**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/execute.zig
git commit -m "feat(execute): sfence.vma as privileged no-op (no TLB modeled)"
```

---

### Task 13: Add page-fault cause codes and unit-test trap entry from them

**Files:**
- Modify: `src/trap.zig` (+ 3 `Cause` variants)
- Modify: `src/trap.zig` tests

**Why now:** Translation code in later tasks will call `trap.enter(.inst_page_fault, va, cpu)` etc. Land the causes first.

- [ ] **Step 1: Write failing test**

```zig
test "page-fault Cause enum values match spec" {
    try std.testing.expectEqual(@as(u32, 12), @intFromEnum(trap.Cause.inst_page_fault));
    try std.testing.expectEqual(@as(u32, 13), @intFromEnum(trap.Cause.load_page_fault));
    try std.testing.expectEqual(@as(u32, 15), @intFromEnum(trap.Cause.store_page_fault));
}

test "trap.enter sets mcause and mtval for a load page fault" {
    var cpu = Cpu.init(.{});
    cpu.pc = 0x8001_0000;
    cpu.privilege = .U;
    cpu.csr.mtvec = 0x8000_1000;
    cpu.csr.mstatus_mie = true;

    trap.enter(.load_page_fault, 0xDEAD_BEEF, &cpu);

    try std.testing.expectEqual(@as(u32, 13), cpu.csr.mcause);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), cpu.csr.mtval);
    try std.testing.expectEqual(@as(u32, 0x8001_0000), cpu.csr.mepc);
    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
    try std.testing.expectEqual(@as(u2, @intFromEnum(PrivilegeMode.U)), cpu.csr.mstatus_mpp);
    try std.testing.expectEqual(true, cpu.csr.mstatus_mpie);
    try std.testing.expectEqual(false, cpu.csr.mstatus_mie);
    try std.testing.expectEqual(@as(u32, 0x8000_1000), cpu.pc);
}
```

- [ ] **Step 2: Run to verify**

Run: `zig build test`
Expected: compile error (unknown variants).

- [ ] **Step 3: Add variants**

In `src/trap.zig`:

```zig
pub const Cause = enum(u32) {
    // existing Plan 1.C variants ...
    inst_page_fault  = 12,
    load_page_fault  = 13,
    store_page_fault = 15,
};
```

- [ ] **Step 4: Run to verify**

Run: `zig build test`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add src/trap.zig
git commit -m "feat(trap): add inst/load/store page-fault causes"
```

---

### Task 14: Sv32 translation — bare identity mode

**Files:**
- Modify: `src/memory.zig`
- Modify: `src/memory.zig` tests

**Why now:** Smallest Sv32 step. Before introducing page walks, make sure the translation hook exists and is pass-through when `satp.MODE == Bare`.

- [ ] **Step 1: Write failing test**

Append to `src/memory.zig` tests:

```zig
const memory = @import("memory.zig");
const Access = memory.Access;

test "translate: Bare mode returns identity from U-mode" {
    var rig = TestRig.init();
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = 0;  // MODE = Bare

    const pa = try rig.mem.translate(0x8000_0000, .load, .U, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), pa);
}

test "translate: M-mode always identity even with Sv32 MODE" {
    var rig = TestRig.init();
    defer rig.deinit();
    rig.cpu.privilege = .M;
    rig.cpu.csr.satp = (1 << 31) | 0x1234;  // Sv32 with bogus PPN

    const pa = try rig.mem.translate(0x8000_0000, .load, .M, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), pa);
}
```

- [ ] **Step 2: Run to verify**

Run: `zig build test`
Expected: compile error (no `Access` / `translate`).

- [ ] **Step 3: Add the stub**

In `src/memory.zig`, add:

```zig
pub const Access = enum { fetch, load, store };

pub const TranslationError = error{
    InstPageFault,
    LoadPageFault,
    StorePageFault,
};

pub fn translate(self: *Memory, va: u32, access: Access, effective_priv: PrivilegeMode, cpu: *Cpu) TranslationError!u32 {
    _ = self;
    _ = access;
    // M-mode or Bare satp: identity
    if (effective_priv == .M) return va;
    const mode = (cpu.csr.satp >> 31) & 1;
    if (mode == 0) return va;
    // Sv32 walk — stubbed; Task 15 implements.
    return va;
}
```

- [ ] **Step 4: Run to verify**

Run: `zig build test`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/memory.zig
git commit -m "feat(memory): translate() identity for Bare and M-mode"
```

---

### Task 15: Sv32 page walk for 4-KB leaves (valid path only)

**Files:**
- Modify: `src/memory.zig`
- Modify: `src/memory.zig` tests

**Why now:** The happy-path walk is the core Sv32 operation. Isolating it from faults/permissions makes the walk logic reviewable on its own.

Walk:
```
va = VPN[1] (10 bits) ‖ VPN[0] (10 bits) ‖ offset (12 bits)
root_pa = satp.PPN << 12
l1_pte_pa = root_pa + VPN[1] * 4
l1_pte    = mem[l1_pte_pa]
if l1_pte.V == 0 → page fault
if l1_pte.R|W|X == 1 → leaf at L1 → superpage → page fault (we reject)
l0_table_pa = l1_pte.PPN << 12
l0_pte_pa   = l0_table_pa + VPN[0] * 4
l0_pte      = mem[l0_pte_pa]
if l0_pte.V == 0 → page fault
if l0_pte.R|W|X == 0 → not a leaf → page fault (pointer at leaf level is invalid)
pa = (l0_pte.PPN << 12) | offset
```

Helper struct for building page tables in tests:

```zig
pub const PTE_V: u32 = 1 << 0;
pub const PTE_R: u32 = 1 << 1;
pub const PTE_W: u32 = 1 << 2;
pub const PTE_X: u32 = 1 << 3;
pub const PTE_U: u32 = 1 << 4;
pub const PTE_G: u32 = 1 << 5;
pub const PTE_A: u32 = 1 << 6;
pub const PTE_D: u32 = 1 << 7;

fn makeLeafPte(pa: u32, flags: u32) u32 {
    return ((pa >> 12) << 10) | flags;
}

fn makePointerPte(child_table_pa: u32) u32 {
    // V=1, R=W=X=0 → pointer
    return ((child_table_pa >> 12) << 10) | PTE_V;
}
```

- [ ] **Step 1: Write failing test**

```zig
test "translate: Sv32 4K leaf, U-mode, matches VA→PA" {
    var rig = TestRig.init();
    defer rig.deinit();

    // Build a trivial 2-level table at physical RAM.
    // Layout (all 4 KB aligned):
    //   root_pa     = 0x8010_0000 (1st free page above kernel image area)
    //   l0_table_pa = 0x8010_1000
    //   leaf_pa     = 0x8020_0000 (where VA 0x00010000 maps)
    const root_pa     : u32 = 0x8010_0000;
    const l0_table_pa : u32 = 0x8010_1000;
    const leaf_pa     : u32 = 0x8020_0000;

    // VA 0x00010000 → VPN[1]=0, VPN[0]=0x10, offset=0
    try rig.mem.storeWord(root_pa + 0, memory.makePointerPte(l0_table_pa));
    try rig.mem.storeWord(l0_table_pa + 0x10 * 4, memory.makeLeafPte(leaf_pa,
        memory.PTE_V | memory.PTE_R | memory.PTE_W | memory.PTE_U));

    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);

    const pa = try rig.mem.translate(0x0001_0000, .load, .U, &rig.cpu);
    try std.testing.expectEqual(leaf_pa, pa);
}

test "translate: Sv32 4K leaf preserves offset" {
    var rig = TestRig.init();
    defer rig.deinit();
    const root_pa     : u32 = 0x8010_0000;
    const l0_table_pa : u32 = 0x8010_1000;
    const leaf_pa     : u32 = 0x8020_0000;
    try rig.mem.storeWord(root_pa + 0, memory.makePointerPte(l0_table_pa));
    try rig.mem.storeWord(l0_table_pa + 0x10 * 4, memory.makeLeafPte(leaf_pa,
        memory.PTE_V | memory.PTE_R | memory.PTE_W | memory.PTE_U));

    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);

    const pa = try rig.mem.translate(0x0001_0ABC, .load, .U, &rig.cpu);
    try std.testing.expectEqual(leaf_pa + 0xABC, pa);
}
```

- [ ] **Step 2: Run to verify**

Run: `zig build test`
Expected: both tests fail (translate always returns `va`).

- [ ] **Step 3: Implement the walk**

Replace the stub body of `translate`:

```zig
pub fn translate(self: *Memory, va: u32, access: Access, effective_priv: PrivilegeMode, cpu: *Cpu) TranslationError!u32 {
    if (effective_priv == .M) return va;
    const mode = (cpu.csr.satp >> 31) & 1;
    if (mode == 0) return va;

    const vpn1:   u32 = (va >> 22) & 0x3FF;
    const vpn0:   u32 = (va >> 12) & 0x3FF;
    const off:    u32 = va & 0xFFF;
    const root_pa: u32 = (cpu.csr.satp & 0x003F_FFFF) << 12;

    const l1_pte_pa = root_pa + vpn1 * 4;
    const l1_pte    = self.loadWordPhysical(l1_pte_pa) catch return pageFaultFor(access);
    if ((l1_pte & PTE_V) == 0) return pageFaultFor(access);
    if ((l1_pte & (PTE_R | PTE_W | PTE_X)) != 0) {
        // Superpage leaf at L1 — Phase 2 rejects.
        return pageFaultFor(access);
    }
    const l0_table_pa = ((l1_pte >> 10) & 0x003F_FFFF) << 12;
    const l0_pte_pa   = l0_table_pa + vpn0 * 4;
    const l0_pte      = self.loadWordPhysical(l0_pte_pa) catch return pageFaultFor(access);
    if ((l0_pte & PTE_V) == 0) return pageFaultFor(access);
    if ((l0_pte & (PTE_R | PTE_W | PTE_X)) == 0) return pageFaultFor(access);

    const leaf_pa = ((l0_pte >> 10) & 0x003F_FFFF) << 12;
    return leaf_pa | off;
}

fn pageFaultFor(access: Access) TranslationError {
    return switch (access) {
        .fetch => error.InstPageFault,
        .load  => error.LoadPageFault,
        .store => error.StorePageFault,
    };
}
```

`loadWordPhysical` is the bypass-translation form of `loadWord`. If it doesn't exist yet, rename the existing physical-access `loadWord` to `loadWordPhysical` (translation-free) and in Task 17 wire `loadWord` to use translation.

- [ ] **Step 4: Run to verify**

Run: `zig build test`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add src/memory.zig
git commit -m "feat(memory): Sv32 4K-leaf page walk (happy path)"
```

---

### Task 16: Sv32 permission checks — U bit, SUM, MXR, R/W/X

**Files:**
- Modify: `src/memory.zig`
- Modify: `src/memory.zig` tests

**Why now:** The walker resolves an address; now the leaf's permission bits must be enforced against the effective privilege and access type.

- [ ] **Step 1: Write failing tests** (one per rule)

```zig
test "translate: U-mode cannot access a page with U=0" {
    var rig = TestRig.init();
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWord(root_pa, memory.makePointerPte(l0_pa));
    try rig.mem.storeWord(l0_pa + 0x10 * 4, memory.makeLeafPte(leaf_pa,
        memory.PTE_V | memory.PTE_R | memory.PTE_W));  // U=0
    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);
    try std.testing.expectError(error.LoadPageFault,
        rig.mem.translate(0x0001_0000, .load, .U, &rig.cpu));
}

test "translate: S-mode without SUM cannot access U=1 page" {
    var rig = TestRig.init();
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWord(root_pa, memory.makePointerPte(l0_pa));
    try rig.mem.storeWord(l0_pa + 0x10 * 4, memory.makeLeafPte(leaf_pa,
        memory.PTE_V | memory.PTE_R | memory.PTE_W | memory.PTE_U));
    rig.cpu.privilege = .S;
    rig.cpu.csr.mstatus_sum = false;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);
    try std.testing.expectError(error.LoadPageFault,
        rig.mem.translate(0x0001_0000, .load, .S, &rig.cpu));
}

test "translate: S-mode with SUM=1 may access U=1 page for load/store but never for fetch" {
    var rig = TestRig.init();
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWord(root_pa, memory.makePointerPte(l0_pa));
    try rig.mem.storeWord(l0_pa + 0x10 * 4, memory.makeLeafPte(leaf_pa,
        memory.PTE_V | memory.PTE_R | memory.PTE_W | memory.PTE_X | memory.PTE_U));
    rig.cpu.privilege = .S;
    rig.cpu.csr.mstatus_sum = true;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);

    // load ok
    _ = try rig.mem.translate(0x0001_0000, .load, .S, &rig.cpu);
    // store ok
    _ = try rig.mem.translate(0x0001_0000, .store, .S, &rig.cpu);
    // fetch from U=1 page is always a fault
    try std.testing.expectError(error.InstPageFault,
        rig.mem.translate(0x0001_0000, .fetch, .S, &rig.cpu));
}

test "translate: write to page without W bit is a store page fault" {
    var rig = TestRig.init();
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWord(root_pa, memory.makePointerPte(l0_pa));
    try rig.mem.storeWord(l0_pa + 0x10 * 4, memory.makeLeafPte(leaf_pa,
        memory.PTE_V | memory.PTE_R | memory.PTE_U));  // no W
    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);
    try std.testing.expectError(error.StorePageFault,
        rig.mem.translate(0x0001_0000, .store, .U, &rig.cpu));
}

test "translate: fetch from R-only page is a fault; fetch from X page succeeds" {
    var rig = TestRig.init();
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWord(root_pa, memory.makePointerPte(l0_pa));
    try rig.mem.storeWord(l0_pa + 0x10 * 4, memory.makeLeafPte(leaf_pa,
        memory.PTE_V | memory.PTE_R | memory.PTE_U));  // R only
    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);
    try std.testing.expectError(error.InstPageFault,
        rig.mem.translate(0x0001_0000, .fetch, .U, &rig.cpu));

    try rig.mem.storeWord(l0_pa + 0x10 * 4, memory.makeLeafPte(leaf_pa,
        memory.PTE_V | memory.PTE_X | memory.PTE_U));  // X only
    _ = try rig.mem.translate(0x0001_0000, .fetch, .U, &rig.cpu);
}

test "translate: MXR=1 allows load from X-only page" {
    var rig = TestRig.init();
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWord(root_pa, memory.makePointerPte(l0_pa));
    try rig.mem.storeWord(l0_pa + 0x10 * 4, memory.makeLeafPte(leaf_pa,
        memory.PTE_V | memory.PTE_X | memory.PTE_U));  // X only
    rig.cpu.privilege = .U;
    rig.cpu.csr.mstatus_mxr = false;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);
    try std.testing.expectError(error.LoadPageFault,
        rig.mem.translate(0x0001_0000, .load, .U, &rig.cpu));
    rig.cpu.csr.mstatus_mxr = true;
    _ = try rig.mem.translate(0x0001_0000, .load, .U, &rig.cpu);
}
```

- [ ] **Step 2: Run to verify**

Run: `zig build test`
Expected: 6 new tests fail (walker does no perm check yet).

- [ ] **Step 3: Add permission checks to `translate`**

Just before the `return leaf_pa | off;` line in `translate`, insert:

```zig
    // Permission check
    const pte_u = (l0_pte & PTE_U) != 0;
    const pte_r = (l0_pte & PTE_R) != 0;
    const pte_w = (l0_pte & PTE_W) != 0;
    const pte_x = (l0_pte & PTE_X) != 0;

    // U-bit vs privilege
    if (effective_priv == .U and !pte_u) return pageFaultFor(access);
    if (effective_priv == .S) {
        if (access == .fetch and pte_u) return pageFaultFor(access);  // S never executes U pages
        if (access != .fetch and pte_u and !cpu.csr.mstatus_sum) return pageFaultFor(access);
    }

    // Access-type vs PTE.R/W/X (with MXR extending readability)
    const effective_readable = pte_r or (pte_x and cpu.csr.mstatus_mxr);
    switch (access) {
        .fetch => if (!pte_x) return pageFaultFor(access),
        .load  => if (!effective_readable) return pageFaultFor(access),
        .store => if (!pte_w) return pageFaultFor(access),
    }
```

- [ ] **Step 4: Run to verify**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/memory.zig
git commit -m "feat(memory): Sv32 permission checks (U, SUM, MXR, R/W/X)"
```

---

### Task 17: Sv32 A/D bit update-in-place

**Files:**
- Modify: `src/memory.zig`
- Modify: `src/memory.zig` tests

- [ ] **Step 1: Write failing tests**

```zig
test "translate: PTE.A is set on successful load" {
    var rig = TestRig.init();
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWord(root_pa, memory.makePointerPte(l0_pa));
    const initial_pte = memory.makeLeafPte(leaf_pa, memory.PTE_V | memory.PTE_R | memory.PTE_U);  // A=0
    try rig.mem.storeWord(l0_pa + 0x10 * 4, initial_pte);
    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);

    _ = try rig.mem.translate(0x0001_0000, .load, .U, &rig.cpu);
    const pte_after = try rig.mem.loadWord(l0_pa + 0x10 * 4);
    try std.testing.expect((pte_after & memory.PTE_A) != 0);
}

test "translate: PTE.D is set on successful store; A also set" {
    var rig = TestRig.init();
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWord(root_pa, memory.makePointerPte(l0_pa));
    try rig.mem.storeWord(l0_pa + 0x10 * 4,
        memory.makeLeafPte(leaf_pa, memory.PTE_V | memory.PTE_R | memory.PTE_W | memory.PTE_U));

    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);

    _ = try rig.mem.translate(0x0001_0000, .store, .U, &rig.cpu);
    const pte_after = try rig.mem.loadWord(l0_pa + 0x10 * 4);
    try std.testing.expect((pte_after & memory.PTE_A) != 0);
    try std.testing.expect((pte_after & memory.PTE_D) != 0);
}

test "translate: PTE.D stays 0 after a load-only access" {
    var rig = TestRig.init();
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWord(root_pa, memory.makePointerPte(l0_pa));
    try rig.mem.storeWord(l0_pa + 0x10 * 4,
        memory.makeLeafPte(leaf_pa, memory.PTE_V | memory.PTE_R | memory.PTE_W | memory.PTE_U));
    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);

    _ = try rig.mem.translate(0x0001_0000, .load, .U, &rig.cpu);
    const pte_after = try rig.mem.loadWord(l0_pa + 0x10 * 4);
    try std.testing.expect((pte_after & memory.PTE_A) != 0);
    try std.testing.expect((pte_after & memory.PTE_D) == 0);
}
```

- [ ] **Step 2: Run to verify**

Run: `zig build test`
Expected: 3 tests fail.

- [ ] **Step 3: Add A/D write-back**

In `translate`, after permission checks but before `return leaf_pa | off;`:

```zig
    // A/D bit update-in-place
    var new_pte = l0_pte;
    var dirty = false;
    if ((l0_pte & PTE_A) == 0) {
        new_pte |= PTE_A;
        dirty = true;
    }
    if (access == .store and (l0_pte & PTE_D) == 0) {
        new_pte |= PTE_D;
        dirty = true;
    }
    if (dirty) {
        self.storeWordPhysical(l0_pte_pa, new_pte) catch return pageFaultFor(access);
    }
```

Like `loadWordPhysical`, `storeWordPhysical` bypasses translation. Same renaming pattern as in Task 15 if not already done.

- [ ] **Step 4: Run to verify**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/memory.zig
git commit -m "feat(memory): Sv32 A/D bit update-in-place"
```

---

### Task 18: Wire `translate` into load/store and fetch paths

**Files:**
- Modify: `src/memory.zig` (loadWord/loadHalf/loadByte + store counterparts route through translate)
- Modify: `src/cpu.zig` (instruction fetch routes through translate)
- Modify: existing `src/memory.zig` tests for translation-bypass paths to keep passing

**Why now:** The translate function exists but nothing uses it yet. This task flips the switch.

- [ ] **Step 1: Write a failing integration test**

```zig
test "loadWord from U-mode through Sv32 translates VA→PA" {
    var rig = TestRig.init();
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWord(root_pa, memory.makePointerPte(l0_pa));
    try rig.mem.storeWord(l0_pa + 0x10 * 4,
        memory.makeLeafPte(leaf_pa, memory.PTE_V | memory.PTE_R | memory.PTE_W | memory.PTE_U));
    // store something at the leaf PA
    try rig.mem.storeWord(leaf_pa, 0x1234_5678);

    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);

    // loadWord accepts a VA now and translates before reading
    const v = try rig.mem.loadWord(0x0001_0000, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), v);
}
```

(If the current `loadWord` signature is `loadWord(self, addr)`, this test will also force the signature to grow a `*Cpu` parameter. Plan 1.C has a similar pattern with the optional `Clint` / `tohost_addr` — the helpers thread through. Do what the codebase does.)

- [ ] **Step 2: Run to verify**

Run: `zig build test`
Expected: integration test fails because `loadWord` ignores translation.

- [ ] **Step 3: Rename bypass accessors, add translating accessors**

- Rename current `loadWord` (physical access) → `loadWordPhysical`. Same for halfword/byte, store variants.
- Add new `loadWord(self, va, cpu) !u32`:

```zig
pub fn loadWord(self: *Memory, va: u32, cpu: *Cpu) !u32 {
    const effective_priv = effectivePriv(cpu, .load);
    const pa = try self.translate(va, .load, effective_priv, cpu);
    return self.loadWordPhysical(pa);
}

fn effectivePriv(cpu: *Cpu, access: Access) PrivilegeMode {
    if (access != .fetch and cpu.privilege == .M and cpu.csr.mstatus_mprv) {
        return @enumFromInt(cpu.csr.mstatus_mpp);
    }
    return cpu.privilege;
}
```

Mirror for `loadHalf`, `loadByte`, `storeWord`, `storeHalf`, `storeByte`.

Translate errors become traps at the call site in `execute.zig` — keep `translate` returning errors; the `!u32` gives the caller the choice.

- [ ] **Step 4: Update `execute.zig` load/store arms**

Each existing load/store call site that uses `mem.loadWord(addr)` becomes `mem.loadWord(addr, cpu)`. On `error.LoadPageFault` / `error.StorePageFault`, call `trap.enter(.load_page_fault, va, cpu)` / `trap.enter(.store_page_fault, va, cpu)` respectively. The existing Plan 1.C pattern already handles `error.LoadAccessFault` → `trap.enter(.load_access_fault, ...)`; extend the catch block. Example (load):

```zig
const val = memory_ref.loadWord(va, cpu) catch |err| {
    switch (err) {
        error.LoadAccessFault  => trap.enter(.load_access_fault, va, cpu),
        error.LoadPageFault    => trap.enter(.load_page_fault,  va, cpu),
        error.StoreAccessFault => unreachable,  // load path can't produce store faults
        error.StorePageFault   => unreachable,
        error.InstPageFault    => unreachable,  // load path can't produce inst fault
        else => return err,
    }
    return;
};
```

- [ ] **Step 5: Update instruction fetch in `cpu.zig`**

Find where `step()` fetches the next instruction. Currently something like `const word = try mem.loadWordPhysical(pc);`. Change to:

```zig
const effective_priv = cpu.privilege; // fetch never applies MPRV
const pa = mem.translate(cpu.pc, .fetch, effective_priv, cpu) catch |err| {
    switch (err) {
        error.InstPageFault => trap.enter(.inst_page_fault, cpu.pc, cpu),
        else => return err,
    }
    return;  // trap entered; next step() sees new PC
};
const word = try mem.loadWordPhysical(pa);
```

- [ ] **Step 6: Run to verify**

Run: `zig build test`
Expected: all tests pass, including the new integration test. Phase 1 tests still pass because when `satp = 0` (initial state), `translate` short-circuits to identity.

- [ ] **Step 7: Commit**

```bash
git add src/memory.zig src/execute.zig src/cpu.zig
git commit -m "feat(memory): route all loads/stores/fetches through Sv32 translate"
```

---

### Task 19: MPRV — M-mode load/store uses MPP privilege for translation

**Files:**
- Modify: `src/memory.zig` (the `effectivePriv` helper — already stubbed in Task 18)
- Modify: `src/memory.zig` tests

**Why now:** MPRV is subtle (applies to loads/stores only, never fetch) and has a dedicated test story. Isolating it makes the behavior reviewable.

- [ ] **Step 1: Write failing test**

```zig
test "MPRV=1 in M-mode: loads use MPP privilege for translation" {
    var rig = TestRig.init();
    defer rig.deinit();
    // Set up a U-mode accessible page
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWord(root_pa, memory.makePointerPte(l0_pa));
    try rig.mem.storeWord(l0_pa + 0x10 * 4,
        memory.makeLeafPte(leaf_pa, memory.PTE_V | memory.PTE_R | memory.PTE_W | memory.PTE_U));
    try rig.mem.storeWord(leaf_pa, 0xCAFE_BABE);

    // Running in M, but with MPRV=1 and MPP=U and Sv32 enabled.
    rig.cpu.privilege = .M;
    rig.cpu.csr.mstatus_mprv = true;
    rig.cpu.csr.mstatus_mpp = @intFromEnum(PrivilegeMode.U);
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);

    const v = try rig.mem.loadWord(0x0001_0000, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xCAFE_BABE), v);
}

test "MPRV has no effect on instruction fetch" {
    var rig = TestRig.init();
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    try rig.mem.storeWord(root_pa, 0);  // empty root so any translation faults
    rig.cpu.privilege = .M;
    rig.cpu.csr.mstatus_mprv = true;
    rig.cpu.csr.mstatus_mpp = @intFromEnum(PrivilegeMode.U);
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);

    // M-mode fetch: should NOT translate even with MPRV. Expect identity:
    const pa = try rig.mem.translate(0x8000_0000, .fetch, .M, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), pa);
}
```

- [ ] **Step 2: Run to verify**

Run: `zig build test`
Expected: first test passes only if the `effectivePriv` helper was correctly wired in Task 18; if not, it fails.

- [ ] **Step 3: Verify/adjust `effectivePriv`**

Ensure `effectivePriv(cpu, .fetch)` returns `cpu.privilege` unconditionally, and `effectivePriv(cpu, .load)`/`(.store)` honor MPRV only when `cpu.privilege == .M`. Task 18's stub should already be correct; if not, fix it.

Also: fetch callers must pass their own `effective_priv` (already done in Task 18). No change to the fetch path.

- [ ] **Step 4: Run to verify**

Run: `zig build test`
Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/memory.zig
git commit -m "feat(memory): honor MPRV for M-mode loads/stores (not fetch)"
```

---

### Task 20: `satp` access from S-mode honors `mstatus.TVM`

**Files:**
- Modify: `src/csr.zig`
- Modify: `src/csr.zig` tests

**Why now:** TVM ties CSR access to privilege state in a way the simple `checkAccess` doesn't cover. Isolating keeps it reviewable.

- [ ] **Step 1: Write failing test**

```zig
test "satp access from S-mode with TVM=1 is illegal" {
    var cpu = Cpu.init(.{});
    cpu.privilege = .S;
    cpu.csr.mstatus_tvm = true;
    try std.testing.expectError(error.IllegalInstruction, csr.csrRead(&cpu, csr.CSR_SATP));
    try std.testing.expectError(error.IllegalInstruction, csr.csrWrite(&cpu, csr.CSR_SATP, 0));
}

test "satp access from S-mode with TVM=0 succeeds" {
    var cpu = Cpu.init(.{});
    cpu.privilege = .S;
    cpu.csr.mstatus_tvm = false;
    _ = try csr.csrRead(&cpu, csr.CSR_SATP);
    try csr.csrWrite(&cpu, csr.CSR_SATP, (1 << 31) | 0x42);
}

test "satp access from M-mode ignores TVM" {
    var cpu = Cpu.init(.{});
    cpu.privilege = .M;
    cpu.csr.mstatus_tvm = true;
    try csr.csrWrite(&cpu, csr.CSR_SATP, (1 << 31) | 0x42);
}
```

- [ ] **Step 2: Run to verify**

Run: `zig build test`
Expected: the first test fails.

- [ ] **Step 3: Add TVM check in `csrRead`/`csrWrite` arms for `CSR_SATP`**

Extract the TVM check into a helper and call it from both arms:

```zig
fn satpTvmCheck(cpu: *Cpu) !void {
    if (cpu.privilege == .S and cpu.csr.mstatus_tvm) return error.IllegalInstruction;
}
```

Then at the `CSR_SATP` arms of both `csrRead` and `csrWrite`, call `try satpTvmCheck(cpu);` before returning/assigning.

- [ ] **Step 4: Run to verify**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/csr.zig
git commit -m "feat(csr): satp access honors mstatus.TVM from S-mode"
```

---

### Task 21: Trace privilege column

**Files:**
- Modify: `src/trace.zig`
- Modify: `src/cpu.zig` (passes `privilege` to `formatInstr`)
- Modify: `tests/programs/*/expected_output.txt` and any test harness that compares trace output

**Why now:** Small, cross-cutting, touches a user-visible format. Done after all execute/memory changes so the trace is stable.

- [ ] **Step 1: Write failing tests**

Append to `src/trace.zig` tests (or create the tests file if it doesn't exist):

```zig
test "formatInstr emits [M] privilege column for M-mode" {
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();
    const pre  = [_]u32{0} ** 32;
    var post = pre;
    post[5] = 0x8000_0000;

    try trace.formatInstr(&w, .M, 0x8000_0000, .{ .op = .auipc, .rd = 5, .imm = 0 }, &pre, &post, 0x8000_0004);
    const line = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, line, "[M]") != null);
}

test "formatInstr emits [S] for S-mode and [U] for U-mode" {
    var buf1: [128]u8 = undefined;
    var s1 = std.io.fixedBufferStream(&buf1);
    try trace.formatInstr(&s1.writer(), .S, 0, .{ .op = .nop, .rd = 0, .imm = 0 }, &[_]u32{0}**32, &[_]u32{0}**32, 4);
    try std.testing.expect(std.mem.indexOf(u8, s1.getWritten(), "[S]") != null);

    var buf2: [128]u8 = undefined;
    var s2 = std.io.fixedBufferStream(&buf2);
    try trace.formatInstr(&s2.writer(), .U, 0, .{ .op = .nop, .rd = 0, .imm = 0 }, &[_]u32{0}**32, &[_]u32{0}**32, 4);
    try std.testing.expect(std.mem.indexOf(u8, s2.getWritten(), "[U]") != null);
}
```

- [ ] **Step 2: Run to verify failures**

Run: `zig build test`
Expected: signature mismatch or compile error.

- [ ] **Step 3: Update `formatInstr` signature to accept privilege**

In `src/trace.zig`:

```zig
pub fn formatInstr(
    w: anytype,
    priv: PrivilegeMode,
    pc: u32,
    instr: Instruction,
    pre_regs: *const [32]u32,
    post_regs: *const [32]u32,
    post_pc: u32,
) !void {
    const priv_str = switch (priv) { .M => "[M]", .S => "[S]", .U => "[U]" };
    try w.print("{x:0>8}  {s} ", .{ pc, priv_str });
    // ... existing formatting follows ...
}
```

- [ ] **Step 4: Update the call site in `cpu.zig`**

Where `step()` calls `trace.formatInstr`, pass the pre-step privilege (captured before the instruction executes, because a trap can change it mid-step):

```zig
const pre_priv = cpu.privilege;
// ... capture pre_regs, execute, capture post_regs ...
try trace.formatInstr(writer, pre_priv, pre_pc, instr, &pre_regs, &post_regs, cpu.pc);
```

- [ ] **Step 5: Update Phase 1 expected-output fixtures**

Run the three Phase 1 e2e demos with `--trace` and refresh the committed expected-output files:

```bash
zig build run -- --trace tests/programs/hello/hello.bin 2> /tmp/trace-hello.txt
zig build run -- --trace tests/programs/mul_demo/mul_demo.bin 2> /tmp/trace-mul.txt
zig build run -- --trace tests/programs/trap_demo/trap_demo.bin 2> /tmp/trace-trap.txt
```

Compare each to the committed expected and confirm the only diff is the added `[M]` / `[U]` column. Copy the new outputs to replace the expected files (if they exist; if the Phase 1 e2e demos don't use trace-comparison, nothing to do here).

- [ ] **Step 6: Run everything**

Run: `zig build test`
Run: `zig build e2e && zig build e2e-mul && zig build e2e-trap && zig build e2e-hello-elf`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add src/trace.zig src/cpu.zig tests/
git commit -m "feat(trace): emit privilege column [M]/[S]/[U]"
```

---

### Task 22: Add `tests/riscv-tests-s.ld` linker script

**Files:**
- Create: `tests/riscv-tests-s.ld`
- (reference only) `tests/riscv-tests-p.ld` — keep as Plan 1.C left it

**Why now:** Precondition for the rv32si build graph in Task 23.

Review `tests/riscv-tests-p.ld` first; the S-variant is structurally identical — same ORIGIN, same single `.text` + `.data` + `.bss` sections, same entry point — the difference is only in how the shim handler starts (M-mode preamble vs direct S-mode preamble). The linker script itself doesn't encode mode — that's the shim's job. So the `s.ld` file can be a near-copy of `p.ld`, with comments adjusted to note its intended use.

- [ ] **Step 1: Copy `p.ld` → `s.ld`**

```bash
cp tests/riscv-tests-p.ld tests/riscv-tests-s.ld
```

Edit the top comment to read:

```ld
/*
 * Linker script for rv32si-p-* riscv-tests (Phase 2).
 * Layout mirrors tests/riscv-tests-p.ld; the test preamble itself (from
 * env/p/riscv_test.h) sets up M-mode CSRs and drops into S-mode for the
 * test body.
 */
```

- [ ] **Step 2: Verify no build changes are needed yet**

Run: `zig build`
Expected: builds — the new file isn't referenced by `build.zig` yet.

- [ ] **Step 3: Commit**

```bash
git add tests/riscv-tests-s.ld
git commit -m "chore(tests): add riscv-tests-s.ld linker script for rv32si"
```

---

### Task 23: `zig build riscv-tests` runs `rv32si-p-*`

**Files:**
- Modify: `build.zig` (add the `rv32si` family to the per-family loop)

**Why now:** The last substantive task. Everything the tests need is in place.

- [ ] **Step 1: Survey which rv32si tests exist in the submodule**

```bash
ls tests/riscv-tests/isa/rv32si/
```

Expected list (as of the pinned submodule hash from Plan 1.C): `csr.S`, `dirty.S`, `illegal.S`, `ma_fetch.S`, `sbreak.S`, `scall.S`, `wfi.S`.

Decide which to include. Default inclusions: `csr`, `dirty`, `illegal`, `ma_fetch`, `sbreak`, `scall`, `wfi`. Exclude any test that needs delegation (`mideleg`/`medeleg` — Plan 2.B) or external interrupts.

- [ ] **Step 2: Extend the riscv-tests families loop in `build.zig`**

Find the existing code that builds families {`ui`, `um`, `ua`, `mi`}. Add an `si` entry. The family differs in three things: the ISA-source directory (`isa/rv32si`), the linker script (`tests/riscv-tests-s.ld`), and the list of test names.

Example (adapt to the existing data-structure style in `build.zig`):

```zig
const families = [_]Family{
    .{ .name = "ui", .dir = "isa/rv32ui", .ld = "tests/riscv-tests-p.ld", .names = &UI_TESTS },
    .{ .name = "um", .dir = "isa/rv32um", .ld = "tests/riscv-tests-p.ld", .names = &UM_TESTS },
    .{ .name = "ua", .dir = "isa/rv32ua", .ld = "tests/riscv-tests-p.ld", .names = &UA_TESTS },
    .{ .name = "mi", .dir = "isa/rv32mi", .ld = "tests/riscv-tests-p.ld", .names = &MI_TESTS },
    .{ .name = "si", .dir = "isa/rv32si", .ld = "tests/riscv-tests-s.ld", .names = &SI_TESTS },  // NEW
};

const SI_TESTS = [_][]const u8{
    "csr", "dirty", "illegal", "ma_fetch", "sbreak", "scall", "wfi",
};
```

- [ ] **Step 3: Run the suite**

Run: `zig build riscv-tests`
Expected: all `rv32ui/um/ua/mi` tests still green. `rv32si` tests run; some may fail on first run — triage.

Common failures to expect + remedies:

- **`wfi.S`** may rely on M-mode `wfi` being a no-op — Plan 1.C treats it as no-op, Phase 2 continues this; should pass.
- **`csr.S`** tests the full CSR-access privilege matrix. If a specific CSR combination fails, verify `requiredPriv`/`checkAccess` handles it (e.g., `sscratch` from M-mode, `mcause` from S-mode). Fix in `src/csr.zig`.
- **`ma_fetch.S`** tests that misaligned instruction fetches produce the right cause. Since our PC is always 4-aligned (no C extension), this test may need skipping — check whether it falls through to `mret`/`sret` correctly. Document any skip.
- **`dirty.S`** tests A/D bit behavior; Task 17's update-in-place path should make it pass.
- **`scall.S`** tests `ecall` from S-mode → cause 9. If the trap cause enum doesn't include `ecall_from_s = 9`, add it now (spec lists it but Plan 1.C didn't wire it).
- **`sbreak.S`** tests `ebreak` → cause 3; Plan 1.C already wires this.
- **`illegal.S`** tests illegal instruction → cause 2; Plan 1.C already wires this.

For each failure:
  1. Run the single test: `zig build -Drv-test=si/csr` (or whatever the helper command is).
  2. Add `--trace` or QEMU-diff it to find the divergence.
  3. Fix the emulator; re-run.

- [ ] **Step 4: If `ecall_from_s` was missing, add it**

In `src/trap.zig`'s `Cause` enum:

```zig
ecall_from_s = 9,
```

And in `src/execute.zig`'s `ecall` arm, when `cpu.privilege == .S`, call `trap.enter(.ecall_from_s, 0, cpu)`.

- [ ] **Step 5: Run the full riscv-tests to confirm green**

Run: `zig build riscv-tests`
Expected: all families green. Document any skipped tests with a comment in `build.zig` explaining why.

- [ ] **Step 6: Commit**

```bash
git add build.zig src/trap.zig src/execute.zig
git commit -m "feat(tests): add rv32si-p-* to riscv-tests suite"
```

---

### Task 24: Regression-run Phase 1 e2e demos

**Files:**
- (possibly) `tests/programs/*/` expected outputs if the trace-column change in Task 21 wasn't fully propagated.

**Why now:** Sanity check that no Plan 2.A change regressed Phase 1. Should be a formality.

- [ ] **Step 1: Run all e2e targets**

Run:

```bash
zig build e2e
zig build e2e-mul
zig build e2e-trap
zig build e2e-hello-elf
```

Expected: all four pass.

- [ ] **Step 2: If any regress, fix** (commit each fix separately)

Typical failure: a call site to `mem.loadWord(...)` that was missed in Task 18's wave. Add the missing `cpu` argument. The compiler flags these.

- [ ] **Step 3: Run the full build**

Run: `zig build && zig build test && zig build riscv-tests`
Expected: everything green.

- [ ] **Step 4: Commit any regression fixes**

```bash
git add src/
git commit -m "fix: regression-run Phase 1 e2e demos"
```

(Skip if no changes.)

---

### Task 25: Update `README.md` status line and ISA surface

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the status section**

Find the "Status" section and append a Plan 2.A entry below the Phase 1 summary:

```markdown
**Plan 2.A (emulator S-mode + Sv32) merged.**

The emulator now supports:

- S-mode privilege + full S-CSR file (`sstatus`, `stvec`, `sepc`,
  `scause`, `stval`, `sscratch`, `sie`, `sip`, `satp`).
- `sret`, `sfence.vma`.
- Sv32 two-level paging (4 KB pages; no superpages; no TLB model).
- `misa` advertises `'S'`.
- `--trace` includes a privilege column: `[M]` / `[S]` / `[U]`.

Trap delegation and async interrupt delivery arrive in Plan 2.B.
```

- [ ] **Step 2: Update the build-targets table**

Add a row for rv32si:

```markdown
| `zig build riscv-tests` | Assemble + link + run rv32ui/um/ua/mi/**si**-p-* |
```

(replacing the previous row that only listed ui/um/ua/mi.)

- [ ] **Step 3: Bump "Next" line**

```markdown
Next: **Plan 2.B — emulator trap delegation + async interrupts**.
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: README — Plan 2.A (S-mode + Sv32) complete"
```

---

## Self-review

After completing all tasks, run the following checklist before handing off to the user:

- [ ] Every spec §"In scope" item for 2.A is addressed: S-CSRs ✅ (Tasks 2, 4, 5, 6, 7), sret ✅ (Tasks 9, 11), sfence.vma ✅ (Tasks 10, 12), Sv32 translation ✅ (Tasks 14–17), MPRV ✅ (Task 19), TVM ✅ (Task 20), privilege check ✅ (Task 8), trace privilege column ✅ (Task 21), rv32si-p-* ✅ (Tasks 22, 23).
- [ ] Every out-of-scope item stays out of scope: no medeleg/mideleg changes, no async interrupt delivery, no kernel code.
- [ ] All Phase 1 demos pass (`zig build e2e*`).
- [ ] `zig build riscv-tests` green on ui + um + ua + mi + si families.
- [ ] `zig build test` green.
- [ ] `README.md` status line reflects Plan 2.A completion.

If any item is un-checkable, open a task and finish it before reporting 2.A complete.

---

## Closing note

Plan 2.A puts the emulator in the shape Plan 2.B needs: S-mode exists, S-CSRs work, Sv32 translates. Plan 2.B then adds `medeleg`/`mideleg`, delegation-aware trap entry, interrupt-boundary checks, CLINT MTIP edge generation, and the M→SSIP forwarding path — at which point a kernel (Plans 2.C and 2.D) can boot.
