# Phase 1 Plan C — Zicsr, Privilege, Traps, CLINT, ELF, riscv-tests (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Plan 1.B emulator with the **Zicsr** extension, a **CSR file**, **M-mode + U-mode privilege**, a **synchronous trap model** (`ecall`, `ebreak`, `mret`, `wfi`, illegal-instruction, load/store misaligned, load/store access fault), a **CLINT timer** device, an **ELF32 loader**, `--trace` / `--halt-on-trap` / `--memory` CLI flags, and — as the external conformance signal — **first passes of the official `riscv-tests` suite** (`rv32ui-p-*`, `rv32um-p-*`, `rv32ua-p-*`, `rv32mi-p-*`) built via Zig's own assembler with no `riscv-gnu-toolchain` dependency.

**Architecture:** CSRs live as explicit fields on `Cpu` (same style as Plans 1.A/1.B regs/pc/reservation); a small `src/csr.zig` module provides `csrRead`/`csrWrite` with field-mask enforcement and privilege checks. A new `src/trap.zig` owns the 6-step trap entry and 3-step `mret` exit prescribed in the spec; `execute.zig` catches `MemoryError` at each load/store site and delegates to `trap.enter` rather than propagating. A new `src/elf.zig` parses ELF32 by hand (no `std.elf` dependency) and returns `{ entry, tohost_addr }`, where the resolved `tohost` symbol becomes an additional halt-write address alongside the existing `0x00100000` MMIO. The CLINT device (`src/devices/clint.zig`) follows the `halt.zig`/`uart.zig` pattern and gets wired into `memory.zig`'s address-range dispatch. `--trace` captures pre/post register state around each `step()` and emits a one-line disassembly via `src/trace.zig`. The `riscv-tests` integration submodules the upstream repo, provides one Zig-assembly linker script (`tests/riscv-tests-p.ld`) matching `env/p/link.ld`, and drives assembly + link + run via `build.zig` helpers.

**Tech Stack:** Zig 0.16.x (pinned in `build.zig.zon`), no external dependencies beyond the `riscv-tests` submodule. Host platform macOS or Linux, little-endian.

**Spec reference:** `docs/superpowers/specs/2026-04-23-phase1-cpu-emulator-design.md` — Plan 1.C implements the Zicsr + privilege + trap + CLINT + ELF + `--trace` + `riscv-tests` slice. The RISC-V trap reference notes in `docs/references/riscv-traps.md` are authoritative for cause codes, CSR fields, and the `mret` sequence; the spec takes precedence if they disagree.

**Plan 1.C scope (subset of Phase 1 spec):**

- **Zicsr** (6 instructions): `csrrw`, `csrrs`, `csrrc`, `csrrwi`, `csrrsi`, `csrrci`. Immediate variants take a 5-bit zero-extended `uimm` stashed in the `rs1` slot of the encoding. Spec-mandated side-effect rules honored: `csrrs`/`csrrc` with `rs1 == x0` suppress the CSR write; `csrrw` with `rd == x0` suppresses the CSR read.
- **CSR file** (12 CSRs on `Cpu` + one read-only constant): `mstatus` (fields `MIE`=bit 3, `MPIE`=bit 7, `MPP`=bits 12:11; other bits read-as-zero), `mtvec` (`BASE`=bits 31:2, `MODE`=bits 1:0 stored-as-written but only direct mode honored), `mepc`, `mcause`, `mtval`, `mie`, `mip` full read-write; `mhartid=0`, `mvendorid=0`, `marchid=0`, `mimpid=0` hardwired; `misa = 0x40101101` (MXL=RV32, 'I'+'M'+'A'+'U' bits).
- **Privilege modes M + U.** `Cpu.privilege: PrivilegeMode` enum; initial = M. U-mode CSR access (any address) returns `CsrError.IllegalInstruction`, which `execute.zig` translates into an illegal-instruction trap.
- **Synchronous traps** (spec §Privilege & trap model, `docs/references/riscv-traps.md` §Common `mcause` values): `illegal_instruction` (2), `breakpoint` (3), `load_addr_misaligned` (4), `load_access_fault` (5), `store_addr_misaligned` (6), `store_access_fault` (7), `ecall_from_u` (8), `ecall_from_m` (11). `Cause` enum codes these. Instruction-address-misaligned (0) and instruction-access-fault (1) aren't raised in 1.C (the ELF loader and `--raw` fallback always land us at well-formed addresses; misaligned jumps would need a branch-taken-to-misaligned-target check that the spec defers).
- **Trap entry/exit**: `src/trap.zig` implements the 6-step entry (mepc←PC, mcause, mtval, mstatus.MPP←priv, mstatus.MPIE←MIE, MIE←0, priv←M, PC←mtvec.BASE) and 3-step `mret` exit (PC←mepc, priv←MPP, MIE←MPIE, MPIE←1, MPP←U). Entry also clears `cpu.reservation` (the Plan 1.B LR/SC reservation) since a trapped-into handler may execute arbitrary memory operations.
- **`ecall`/`ebreak`** real semantics: `trap.enter(.ecall_from_u|.ecall_from_m, 0, cpu)` / `trap.enter(.breakpoint, 0, cpu)`. No longer `UnsupportedInstruction`.
- **`mret`/`wfi`**: decoded as SYSTEM funct3=000 imm12=0x302 / 0x105. `mret` calls `trap.exit_mret`. `wfi` advances PC by 4 (no-op; Phase 1 has no interrupt sources). Both require M-mode; U-mode execution traps as illegal.
- **CLINT** at `0x02000000`: `msip` (offset 0, 4 bytes, RW), `mtimecmp` (offset 0x4000, 8 bytes, RW), `mtime` (offset 0xBFF8, 8 bytes; reads return `std.time.nanoTimestamp() / 100` giving a 10 MHz nominal tick; writes ignored). No IRQ edges delivered in 1.C. Wired into `memory.zig`'s MMIO dispatch.
- **ELF32 loader** (`src/elf.zig`): default boot path. Parses ELF32 little-endian RISC-V EXEC files; copies `PT_LOAD` segments into RAM honoring `p_filesz` vs `p_memsz` (BSS zeroing); scans the symbol table for `tohost`; returns `{ entry: u32, tohost_addr: ?u32 }`.
- **Halt-write addresses**: the existing `0x00100000` MMIO stays (hand-crafted binaries). ELF binaries additionally treat writes to the resolved `tohost` address as halt: value `1` → exit 0 (pass); non-zero value `v` → exit `v >> 1` (fail with test number). `Memory.init` gains an optional `tohost_addr: ?u32` parameter.
- **CLI**: ELF becomes the default boot mode; `--raw <hex-addr>` becomes the opt-in fallback. New flags: `--trace` (one line per executed instruction to stderr), `--halt-on-trap` (dump diagnostic and exit on unhandled trap), `--memory <MB>` (override RAM size, default 128). Help text matches spec §CLI verbatim.
- **`src/trace.zig`**: `formatInstr(writer, pc, instr, pre_regs, post_regs, post_pc)` emits one line per step. `cpu.zig` gains an optional `trace_writer: ?*std.Io.Writer`; when non-null, `step()` captures pre-state, executes, captures post-state, calls `trace.formatInstr`.
- **`riscv-tests` integration**: submodule `tests/riscv-tests` pointing at upstream `riscv-software-src/riscv-tests`. Build rule assembles each listed `.S` via `addObject` with `addAssemblyFile` + `-target riscv32-freestanding -mcpu generic_rv32+m+a+zicsr+zifencei`, preprocessor includes for `env/p` and `isa/macros/scalar`, links against our minimal `tests/riscv-tests-p.ld` (matches upstream `env/p/link.ld`), runs each resulting ELF through `ccc`, asserts exit code 0. Step: `zig build riscv-tests`.
- **End-to-end privilege demo** (`tests/programs/trap_demo/`): hand-crafted `--raw` binary. M-mode sets up `mtvec`, writes `mstatus.MPP=U`, `mret`s to U-mode. U-mode executes `ecall`. M-mode handler reads `mcause`, confirms it's `ecall_from_u`, prints `"trap ok\n"` via UART, writes 0 to halt MMIO. Wired as `zig build e2e-trap` asserting stdout equals `"trap ok\n"`.

**Not in Plan 1.C (deferred to Plan 1.D):**

- The M-mode monitor (`tests/programs/hello/monitor.S`) and the cross-compiled Zig `hello.elf` that together form the Phase 1 definition-of-done demo → Plan 1.D.
- QEMU-diff debug harness (`scripts/qemu-diff.sh`) → Plan 1.D.
- S-mode, Sv32 page tables, process scheduling, PLIC → Phase 2.
- Instruction-address-misaligned (cause 0) and instruction-access-fault (cause 1) traps → Plan 2 (when branch/jump targets go through tighter validation).
- CLINT interrupt delivery (`msip` → software IRQ; `mtime >= mtimecmp` → timer IRQ) → Phase 2.
- `mstatus` fields beyond `MIE`/`MPIE`/`MPP` (`SIE`/`SPIE`/`SPP`/`MPRV`/`SUM`/`MXR`/etc.) → Phase 2.
- The `rv32ui-v-*` / `rv32um-v-*` / `rv32ua-v-*` / `rv32si-p-*` `riscv-tests` families (virtual-memory + S-mode) → Phase 2.
- Boot-ROM bootstrap at `0x00001000` (the spec reserves the region; we still set `PC ← e_entry` at load time in 1.C) → Phase 2.

**Deviation from Plan 1.B's closing note:** none. Plan 1.B's closing promised "M/U-mode, the CSR file, the trap entry/exit sequence, ecall/ebreak/mret/wfi with real semantics, the CLINT device, ELF loading, the --trace flag, and the first riscv-tests passes (rv32ui-p-*, rv32um-p-*, rv32ua-p-*, rv32mi-p-*)"; Plan 1.C delivers exactly that, plus the `--halt-on-trap` and `--memory` CLI flags the Phase 1 spec calls for, plus the `e2e-trap` demo (the Plan 1.C equivalent of Plan 1.A's hello demo and Plan 1.B's mul demo). The Plan 1.B "self-review" table listed ELF loader under 1.D; the closing paragraph overrode that and placed it in 1.C — we honor the closing. The monitor + Zig `hello.elf` split between 1.C and 1.D stays as the closing described: monitor + Zig hello → 1.D.

---

## File structure (final state at end of Plan 1.C)

```
ccc/
├── .gitignore
├── .gitmodules                         ← NEW (riscv-tests submodule)
├── build.zig                           ← MODIFIED (e2e-trap, riscv-tests, --trace wiring)
├── build.zig.zon
├── README.md                           ← MODIFIED (status line, new flags, riscv-tests table)
├── src/
│   ├── main.zig                        ← MODIFIED (ELF default, --raw fallback, --trace, --halt-on-trap, --memory)
│   ├── cpu.zig                         ← MODIFIED (+privilege, +12 CSR fields, +trace_writer, clear reservation on trap)
│   ├── memory.zig                      ← MODIFIED (+CLINT dispatch, +optional tohost_addr halt)
│   ├── decoder.zig                     ← MODIFIED (+Zicsr variants, +mret/wfi, +Instruction.csr field)
│   ├── execute.zig                     ← MODIFIED (+Zicsr, +trap-based ecall/ebreak/mret/wfi, +mem-err-to-trap)
│   ├── csr.zig                         ← NEW (CSR address constants, field masks, csrRead/csrWrite)
│   ├── trap.zig                        ← NEW (Cause enum, enter, exit_mret)
│   ├── elf.zig                         ← NEW (parseAndLoad → {entry, tohost_addr?})
│   ├── trace.zig                       ← NEW (formatInstr)
│   └── devices/
│       ├── halt.zig                    ← UNCHANGED
│       ├── uart.zig                    ← UNCHANGED
│       └── clint.zig                   ← NEW (msip, mtimecmp, mtime)
└── tests/
    ├── programs/
    │   ├── hello/                      ← UNCHANGED (Plan 1.A)
    │   ├── mul_demo/                   ← UNCHANGED (Plan 1.B)
    │   └── trap_demo/                  ← NEW (encode_trap_demo.zig + README.md)
    ├── riscv-tests/                    ← NEW (git submodule, upstream riscv-software-src/riscv-tests)
    └── riscv-tests-p.ld                ← NEW (linker script mirroring env/p/link.ld for the p environment)
```

**Module responsibilities (deltas vs Plan 1.B):**

- **`cpu.zig`** — gains `privilege: PrivilegeMode` (init `.M`), a `csr: CsrFile` sub-struct holding the 7 writable CSR fields, and an optional `trace_writer: ?*std.Io.Writer`. `StepError` gains no new variants (`UnsupportedInstruction` is *removed* — everything that used to return it now traps); the error surface narrows to `error.Halt` (bubbled from a halt-MMIO write) plus fatal errors from a misconfigured emulator state (`error.UnreachableTrap` when a trap fires while `mtvec == 0` and `--halt-on-trap` is set). `step()` picks up the trace capture logic.
- **`csr.zig` (new)** — pure functions over `*Cpu`: `csrRead(cpu, addr) !u32`, `csrWrite(cpu, addr, value) !void`. CSR address constants (`CSR_MSTATUS = 0x300`, etc.) and field-mask constants (`MSTATUS_MIE = 1 << 3`, etc.) live here. U-mode CSR access → `error.IllegalInstruction`. Unknown CSR address → same error. Read-only CSRs (`misa`, `mhartid`, etc.) ignore writes (WARL: writes complete without side effect). `mstatus` writes mask to the supported fields (`MIE | MPIE | MPP`). `mtvec` stores as-written but reads back the same value (MODE bits stored but ignored by `trap.enter`).
- **`trap.zig` (new)** — `Cause` enum encodes mcause values. `enter(cause, tval, *Cpu)` implements the spec's 6-step entry; `exit_mret(*Cpu)` implements the 3-step exit. Both operate only on `Cpu` state — no I/O, no allocation. `enter` always clears `cpu.reservation` (LR/SC invariant).
- **`decoder.zig`** — `Op` enum grows with 8 new variants: `csrrw`, `csrrs`, `csrrc`, `csrrwi`, `csrrsi`, `csrrci`, `mret`, `wfi`. `Instruction` gains a `csr: u12` field (for Zicsr). The SYSTEM opcode arm (`0b1110011`) is rewritten to dispatch on funct3: funct3=000 handles `ecall`/`ebreak`/`mret`/`wfi` by imm12; funct3 ∈ {001, 010, 011} handles reg-source Zicsr; funct3 ∈ {101, 110, 111} handles imm-source Zicsr (with the 5-bit uimm stashed in the `rs1` slot, a documented reuse).
- **`execute.zig`** — `ExecuteError` drops `UnsupportedInstruction`, `IllegalInstruction`, `MisalignedAccess`, `OutOfBounds`, `UnexpectedRegister`, `WriteFailed` (all absorbed into traps) and keeps only `error.Halt` + `error.FatalTrap` (the "trap while `--halt-on-trap` set" signal for the CLI). Each load/store site is rewritten: it catches `MemoryError` and calls `trap.enter(.load_access_fault, addr, cpu)` etc. The `.ecall`/`.ebreak` arms switch from returning `UnsupportedInstruction` to `trap.enter`. The `.illegal` arm calls `trap.enter(.illegal_instruction, instr.raw, cpu)`. New arms for Zicsr, `mret`, `wfi`. The `mapMemErr` helper is gone.
- **`memory.zig`** — gains a CLINT range in the MMIO dispatch. Gains an optional `tohost_addr: ?u32` field; when set, writes to that address are treated identically to the existing `0x00100000` halt MMIO (value → exit code). `Memory.init` gains a `tohost_addr: ?u32` parameter; callers that don't need it (tests, hand-crafted demos) pass `null`.
- **`elf.zig` (new)** — pure ELF32 parser using `std.mem.readInt(.little)` against a slice. No dependency on `std.elf`. Returns `{ entry: u32, tohost_addr: ?u32 }` or a tagged error. Handles `PT_LOAD` program headers; scans `.symtab`/`.strtab` for `tohost`; tolerates the absence of a symbol table (returns `tohost_addr = null`).
- **`trace.zig` (new)** — one exported function: `formatInstr(writer, pc, instr, pre_regs, post_regs, post_pc) !void`. Prints a line to `writer`: `PC  RAW  op  reg-deltas`. No global state, no side effects beyond the writer.
- **`devices/clint.zig` (new)** — follows the `halt.zig`/`uart.zig` pattern. `Clint` struct with `msip: u32`, `mtimecmp: u64`, fields and a captured `clock_source: ClockSource` (an interface-ish: a function pointer to `fn () i128` returning nanoseconds). Production uses `std.time.nanoTimestamp`; tests pass a fixture clock. `read`/`write` for 4/8-byte accesses at the right offsets; unknown offsets return 0 / accept-no-op (matches the lenient MMIO approach of Plan 1.A's UART).
- **`main.zig`** — argument parsing grows. Default boot is ELF; `--raw <hex-addr>` is the opt-in raw-binary mode. Help text matches spec §CLI verbatim. Constructs `Clint`, passes into `Memory.init`, wires `--trace` (captured stderr writer), wires `--halt-on-trap` (sets `cpu.halt_on_trap = true`), wires `--memory <MB>` (passes into `Memory.init`). Exit code = `halt.exit_code orelse 0`.

---

## Conventions used in this plan

- All Zig code targets Zig 0.16.x. Same API surface as Plan 1.B (`std.Io.Writer`, `std.process.Init`, `std.heap.ArenaAllocator`, `std.time.nanoTimestamp`).
- Tests live as inline `test "name" { ... }` blocks alongside the code under test. `zig build test` runs every test reachable from `src/main.zig`. `main.zig`'s `comptime { _ = @import(...) }` block gets one new line per new source file (`csr.zig`, `trap.zig`, `elf.zig`, `trace.zig`, `devices/clint.zig`).
- Each task ends with a TDD cycle: write a failing test, see it fail, implement minimally, verify pass, commit. Commit messages follow Conventional Commits (`feat:`, `test:`, `chore:`, `docs:`, `refactor:`).
- When extending a grouped switch (e.g., the SYSTEM opcode dispatch), we show the whole block in full so the reader doesn't have to reconstruct from diffs.
- Register aliases in the `trap_demo` encoder use the RISC-V ABI numbers (`T0 = 5`, `T1 = 6`, `A0 = 10`, `A7 = 17`, ...), matching `encode_hello.zig` and `encode_mul_demo.zig`.
- The `TestRig` / `Rig` test-fixture pattern from Plan 1.A (fill-in-place with stable addresses because the `Uart` holds `*std.Io.Writer` pointing into the rig's `aw` field) continues — we add a `clint` field and `tohost_addr: ?u32` parameter to the existing rigs.
- Raw-binary task demos keep the `encode_*.zig` host-encoder pattern: a Zig program run at build time that writes a little-endian 32-bit stream to a named output file. `trap_demo` follows this pattern.

---

## Tasks

### Task 1: Add `PrivilegeMode` enum + `privilege` field to `Cpu`

**Files:**
- Modify: `src/cpu.zig`

**Why this task:** Every CSR access, trap entry, and trap exit needs to consult or update the current privilege level. We stand up the state first so downstream tasks (CSR file, trap module) can reference it. Initial privilege is M (matches the spec: "The Phase 1 monitor lives here").

- [ ] **Step 1: Add the `PrivilegeMode` enum + field**

At the top of `src/cpu.zig`, add the enum declaration alongside `StepError`:

```zig
/// Two-level RISC-V privilege, spec §Privilege & trap model.
/// Encoding matches the `mstatus.MPP` field: 0b00 = U, 0b11 = M.
/// The two reserved middle values (0b01 = S, 0b10 = H) never appear in
/// Phase 1 but we keep them in the enum so bit-level round-trips through
/// mstatus are total; `trap.exit_mret` normalizes them to U (spec: WARL
/// unsupported modes read back as the least-privileged supported mode).
pub const PrivilegeMode = enum(u2) {
    U = 0b00,
    reserved_s = 0b01,
    reserved_h = 0b10,
    M = 0b11,
};
```

Then update the `Cpu` struct to carry the new field, initialised to `.M`:

```zig
pub const Cpu = struct {
    regs: [32]u32,
    pc: u32,
    memory: *Memory,
    reservation: ?u32,
    // Current privilege level. Starts in M; a monitor drops to U via mret,
    // and synchronous traps return control to M. Phase 1 never uses the
    // reserved_s/reserved_h variants; they exist only to round-trip the
    // mstatus.MPP bit field losslessly (see trap.zig).
    privilege: PrivilegeMode,

    pub fn init(memory: *Memory, entry: u32) Cpu {
        return .{
            .regs = [_]u32{0} ** 32,
            .pc = entry,
            .memory = memory,
            .reservation = null,
            .privilege = .M,
        };
    }
```

(Leave the rest of `Cpu` — `readReg`/`writeReg`/`step`/`run`/`mapMemErr` — unchanged for now. Task 6 will remove `mapMemErr`; Task 2 adds the CSR field; Task 13 adds the trace hook.)

- [ ] **Step 2: Write a failing test that `init` sets privilege to M**

Append to the existing test block in `src/cpu.zig`:

```zig
test "Cpu.init starts in M-mode" {
    var dummy_mem: Memory = undefined;
    const cpu = Cpu.init(&dummy_mem, 0);
    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
}
```

- [ ] **Step 3: Run the tests**

Run: `zig build test`
Expected: all existing tests still pass; the new `Cpu.init starts in M-mode` test passes.

- [ ] **Step 4: Commit**

```bash
git add src/cpu.zig
git commit -m "feat: add PrivilegeMode enum and privilege field to Cpu"
```

---

### Task 2: Add the CSR file — 7 writable CSR fields on `Cpu` + `src/csr.zig`

**Files:**
- Modify: `src/cpu.zig`
- Create: `src/csr.zig`
- Modify: `src/main.zig` (add `_ = @import("csr.zig");` to the `comptime` block)

**Why this task:** The CSR file is the shared backplane for Zicsr execution (Task 4), trap entry/exit (Task 5), and `mret`/`wfi` decode (Task 9). We lay the storage on `Cpu` plus a thin `csr.zig` module for reads/writes with field masking and privilege checks, so each of the later tasks can call `csr.csrRead(cpu, addr)` / `csr.csrWrite(cpu, addr, val)` without re-inventing the address dispatch.

- [ ] **Step 1: Add the `CsrFile` sub-struct to `Cpu`**

In `src/cpu.zig`, add a nested struct declaration just above `Cpu` (below `PrivilegeMode`):

```zig
/// Writable CSR storage. Read-only CSRs (misa, mhartid, mvendorid,
/// marchid, mimpid) live as constants in csr.zig — they have no storage.
/// Field semantics live in csr.zig's mask constants and its csrRead /
/// csrWrite functions; this struct is just the bytes.
pub const CsrFile = struct {
    mstatus: u32 = 0,
    mtvec: u32 = 0,
    mepc: u32 = 0,
    mcause: u32 = 0,
    mtval: u32 = 0,
    mie: u32 = 0,
    mip: u32 = 0,
};
```

Update `Cpu` to embed one:

```zig
pub const Cpu = struct {
    regs: [32]u32,
    pc: u32,
    memory: *Memory,
    reservation: ?u32,
    privilege: PrivilegeMode,
    csr: CsrFile,

    pub fn init(memory: *Memory, entry: u32) Cpu {
        return .{
            .regs = [_]u32{0} ** 32,
            .pc = entry,
            .memory = memory,
            .reservation = null,
            .privilege = .M,
            .csr = .{},
        };
    }
```

- [ ] **Step 2: Create `src/csr.zig` with address constants, field masks, and `csrRead`/`csrWrite`**

Create `src/csr.zig`:

```zig
const std = @import("std");
const cpu_mod = @import("cpu.zig");
const Cpu = cpu_mod.Cpu;
const PrivilegeMode = cpu_mod.PrivilegeMode;

// Writable (software-visible) CSR addresses we implement in Phase 1.
pub const CSR_MSTATUS: u12 = 0x300;
pub const CSR_MISA: u12 = 0x301;
pub const CSR_MIE: u12 = 0x304;
pub const CSR_MTVEC: u12 = 0x305;
pub const CSR_MEPC: u12 = 0x341;
pub const CSR_MCAUSE: u12 = 0x342;
pub const CSR_MTVAL: u12 = 0x343;
pub const CSR_MIP: u12 = 0x344;

// Read-only (hardwired) CSR addresses.
pub const CSR_MVENDORID: u12 = 0xF11;
pub const CSR_MARCHID: u12 = 0xF12;
pub const CSR_MIMPID: u12 = 0xF13;
pub const CSR_MHARTID: u12 = 0xF14;

// mstatus field bits we honor in Phase 1. Other bits read-as-zero.
pub const MSTATUS_MIE: u32 = 1 << 3; // Machine Interrupt Enable
pub const MSTATUS_MPIE: u32 = 1 << 7; // Previous MIE (saved on trap entry)
pub const MSTATUS_MPP_SHIFT: u5 = 11; // Previous privilege (2 bits, 12:11)
pub const MSTATUS_MPP_MASK: u32 = 0b11 << MSTATUS_MPP_SHIFT;
pub const MSTATUS_WRITABLE: u32 = MSTATUS_MIE | MSTATUS_MPIE | MSTATUS_MPP_MASK;

// mtvec field bits. BASE is bits 31:2 (word-aligned); MODE is bits 1:0.
// Phase 1 only honors MODE=0 (direct); MODE=1 (vectored) is stored
// (writes aren't rejected) but trap.enter always jumps to BASE.
pub const MTVEC_MODE_MASK: u32 = 0b11;
pub const MTVEC_BASE_MASK: u32 = ~MTVEC_MODE_MASK;

// mepc is 4-byte aligned in Phase 1 (no compressed extension).
// The low two bits read-as-zero per spec.
pub const MEPC_ALIGN_MASK: u32 = ~@as(u32, 0b11);

// misa value: MXL=01 (RV32), extensions I+M+A+U.
// Bit positions (from RISC-V spec misa chapter):
//   'A' = bit 0, 'I' = bit 8, 'M' = bit 12, 'U' = bit 20
//   MXL lives in the top 2 bits: 31:30.
pub const MISA_VALUE: u32 =
    (@as(u32, 0b01) << 30) | // MXL = RV32
    (@as(u32, 1) << 20) | // U
    (@as(u32, 1) << 12) | // M
    (@as(u32, 1) << 8) | // I
    (@as(u32, 1) << 0); // A

pub const CsrError = error{IllegalInstruction};

/// Read a CSR. In U-mode, any CSR access is illegal (Phase 1 has no
/// user-accessible CSRs; time/cycle/instret live in CSR 0xC00+ which
/// we don't implement yet). Unknown addresses also trap.
pub fn csrRead(cpu: *const Cpu, addr: u12) CsrError!u32 {
    if (cpu.privilege != .M) return CsrError.IllegalInstruction;
    return switch (addr) {
        CSR_MSTATUS => cpu.csr.mstatus,
        CSR_MISA => MISA_VALUE,
        CSR_MIE => cpu.csr.mie,
        CSR_MTVEC => cpu.csr.mtvec,
        CSR_MEPC => cpu.csr.mepc & MEPC_ALIGN_MASK,
        CSR_MCAUSE => cpu.csr.mcause,
        CSR_MTVAL => cpu.csr.mtval,
        CSR_MIP => cpu.csr.mip,
        CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID => 0,
        else => CsrError.IllegalInstruction,
    };
}

/// Write a CSR. Read-only CSRs silently drop writes (WARL). mstatus and
/// mtvec honor field masks; mepc zeros the low two bits.
pub fn csrWrite(cpu: *Cpu, addr: u12, value: u32) CsrError!void {
    if (cpu.privilege != .M) return CsrError.IllegalInstruction;
    switch (addr) {
        CSR_MSTATUS => cpu.csr.mstatus = value & MSTATUS_WRITABLE,
        CSR_MIE => cpu.csr.mie = value,
        CSR_MTVEC => cpu.csr.mtvec = value,
        CSR_MEPC => cpu.csr.mepc = value & MEPC_ALIGN_MASK,
        CSR_MCAUSE => cpu.csr.mcause = value,
        CSR_MTVAL => cpu.csr.mtval = value,
        CSR_MIP => cpu.csr.mip = value,
        // Read-only / hardwired — accept writes silently (WARL behavior).
        CSR_MISA, CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID => {},
        else => return CsrError.IllegalInstruction,
    }
}

test "mstatus round-trips through writable mask" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MSTATUS, 0xFFFF_FFFF);
    try std.testing.expectEqual(MSTATUS_WRITABLE, try csrRead(&cpu, CSR_MSTATUS));
}

test "misa reads back constant RV32IMAU value" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try std.testing.expectEqual(MISA_VALUE, try csrRead(&cpu, CSR_MISA));
    // Writes to misa are silently dropped.
    try csrWrite(&cpu, CSR_MISA, 0);
    try std.testing.expectEqual(MISA_VALUE, try csrRead(&cpu, CSR_MISA));
}

test "mhartid/mvendorid/marchid/mimpid all read zero" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try std.testing.expectEqual(@as(u32, 0), try csrRead(&cpu, CSR_MHARTID));
    try std.testing.expectEqual(@as(u32, 0), try csrRead(&cpu, CSR_MVENDORID));
    try std.testing.expectEqual(@as(u32, 0), try csrRead(&cpu, CSR_MARCHID));
    try std.testing.expectEqual(@as(u32, 0), try csrRead(&cpu, CSR_MIMPID));
}

test "U-mode CSR read/write traps as illegal" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    cpu.privilege = .U;
    try std.testing.expectError(CsrError.IllegalInstruction, csrRead(&cpu, CSR_MSTATUS));
    try std.testing.expectError(CsrError.IllegalInstruction, csrWrite(&cpu, CSR_MSTATUS, 1));
}

test "unknown CSR address traps as illegal" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try std.testing.expectError(CsrError.IllegalInstruction, csrRead(&cpu, 0xABC));
    try std.testing.expectError(CsrError.IllegalInstruction, csrWrite(&cpu, 0xABC, 0));
}

test "mepc forces 4-byte alignment on read and write" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MEPC, 0x8000_1003); // unaligned low bits
    try std.testing.expectEqual(@as(u32, 0x8000_1000), try csrRead(&cpu, CSR_MEPC));
}

test "mcause round-trips full 32 bits (interrupt high bit + cause)" {
    var dummy_mem: @import("memory.zig").Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    try csrWrite(&cpu, CSR_MCAUSE, 0x8000_0007);
    try std.testing.expectEqual(@as(u32, 0x8000_0007), try csrRead(&cpu, CSR_MCAUSE));
}
```

- [ ] **Step 3: Wire `csr.zig` into the test root**

In `src/main.zig`, add `csr.zig` to the `comptime` import block so its tests get picked up:

```zig
comptime {
    _ = @import("cpu.zig");
    _ = @import("memory.zig");
    _ = @import("devices/halt.zig");
    _ = @import("devices/uart.zig");
    _ = @import("decoder.zig");
    _ = @import("execute.zig");
    _ = @import("csr.zig");
}
```

- [ ] **Step 4: Run the tests**

Run: `zig build test`
Expected: all existing tests still pass; the 7 new CSR tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/cpu.zig src/csr.zig src/main.zig
git commit -m "feat: add CSR file and csr.zig with read/write, field masks, privilege checks"
```

---

### Task 3: Decode Zicsr (6 instructions) + extend `Instruction` with a `csr: u12` field

**Files:**
- Modify: `src/decoder.zig`

**Why this task:** All six Zicsr instructions share opcode `0b1110011` (SYSTEM) with `ecall`/`ebreak`, distinguished by funct3. The register-source forms (`csrrw`/`csrrs`/`csrrc`, funct3 ∈ {001, 010, 011}) take a register index in `rs1`; the immediate-source forms (`csrrwi`/`csrrsi`/`csrrci`, funct3 ∈ {101, 110, 111}) take a 5-bit zero-extended `uimm` in the same encoding slot. We reuse `Instruction.rs1` for the uimm value to avoid bloating the struct with a separate `uimm` field — execute.zig knows from the `Op` tag how to interpret it. The 12-bit CSR address (bits 31:20) needs its own `Instruction.csr` field since it's wider than `rs2`.

- [ ] **Step 1: Write failing decoder tests**

Append to `src/decoder.zig`, after the existing `ebreak` test:

```zig
test "decode CSRRW a0, mstatus, t0 → 0x300292F3" {
    // csrrw x5 (t0) into mstatus (0x300), read into x5 (t0)? Let's pick clear operands.
    // csrrw rd=x5, rs1=x5, csr=0x300 → bits: csr[31:20]=0x300, rs1[19:15]=00101,
    // funct3[14:12]=001, rd[11:7]=00101, opcode[6:0]=1110011
    //   = 0b001100000000_00101_001_00101_1110011
    //   = 0x300292F3
    const i = decode(0x300292F3);
    try std.testing.expectEqual(Op.csrrw, i.op);
    try std.testing.expectEqual(@as(u5, 5), i.rd);
    try std.testing.expectEqual(@as(u5, 5), i.rs1);
    try std.testing.expectEqual(@as(u12, 0x300), i.csr);
}

test "decode CSRRS rd=x1, rs1=x0, csr=mhartid → 0xF14022F3 has rd=5, not 1; re-encode" {
    // csrrs rd=x5 (t0), rs1=x0, csr=0xF14 (mhartid)
    // bits: 0xF14 << 20 | 0 << 15 | 010 << 12 | 5 << 7 | 0b1110011
    //   = 0xF140_0000 | 0 | 0x2000 | 0x0280 | 0x73
    //   = 0xF14022F3
    const i = decode(0xF14022F3);
    try std.testing.expectEqual(Op.csrrs, i.op);
    try std.testing.expectEqual(@as(u5, 5), i.rd);
    try std.testing.expectEqual(@as(u5, 0), i.rs1);
    try std.testing.expectEqual(@as(u12, 0xF14), i.csr);
}

test "decode CSRRC rd=x3, rs1=x4, csr=mtvec" {
    // csrrc rd=x3, rs1=x4, csr=0x305 (mtvec)
    // 0x305 << 20 | 4 << 15 | 011 << 12 | 3 << 7 | 0x73
    //   = 0x3050_0000 | 0x0002_0000 | 0x3000 | 0x0180 | 0x73
    //   = 0x305231F3
    const i = decode(0x305231F3);
    try std.testing.expectEqual(Op.csrrc, i.op);
    try std.testing.expectEqual(@as(u5, 3), i.rd);
    try std.testing.expectEqual(@as(u5, 4), i.rs1);
    try std.testing.expectEqual(@as(u12, 0x305), i.csr);
}

test "decode CSRRWI rd=x1, uimm=0x1F, csr=mepc — uimm lives in the rs1 slot" {
    // csrrwi rd=x1, zimm=0x1F (= 31), csr=0x341 (mepc)
    // 0x341 << 20 | 0x1F << 15 | 101 << 12 | 1 << 7 | 0x73
    //   = 0x3410_0000 | 0x000F_8000 | 0x5000 | 0x0080 | 0x73
    //   = 0x341FD0F3
    const i = decode(0x341FD0F3);
    try std.testing.expectEqual(Op.csrrwi, i.op);
    try std.testing.expectEqual(@as(u5, 1), i.rd);
    try std.testing.expectEqual(@as(u5, 0x1F), i.rs1); // uimm stashed in rs1 slot
    try std.testing.expectEqual(@as(u12, 0x341), i.csr);
}

test "decode CSRRSI rd=x0, uimm=0, csr=0xC00 (cycle — unsupported in Phase 1 but decode succeeds)" {
    // csrrsi rd=x0, zimm=0, csr=0xC00
    // 0xC00 << 20 | 0 << 15 | 110 << 12 | 0 << 7 | 0x73
    //   = 0xC000_0000 | 0 | 0x6000 | 0 | 0x73
    //   = 0xC0006073
    const i = decode(0xC0006073);
    try std.testing.expectEqual(Op.csrrsi, i.op);
    try std.testing.expectEqual(@as(u5, 0), i.rd);
    try std.testing.expectEqual(@as(u5, 0), i.rs1);
    try std.testing.expectEqual(@as(u12, 0xC00), i.csr);
}

test "decode CSRRCI rd=x7, uimm=0b10101, csr=mie" {
    // csrrci rd=x7, zimm=0x15, csr=0x304 (mie)
    // 0x304 << 20 | 0x15 << 15 | 111 << 12 | 7 << 7 | 0x73
    //   = 0x3040_0000 | 0x000A_8000 | 0x7000 | 0x0380 | 0x73
    //   = 0x304AF3F3
    const i = decode(0x304AF3F3);
    try std.testing.expectEqual(Op.csrrci, i.op);
    try std.testing.expectEqual(@as(u5, 7), i.rd);
    try std.testing.expectEqual(@as(u5, 0x15), i.rs1);
    try std.testing.expectEqual(@as(u12, 0x304), i.csr);
}

test "SYSTEM with funct3=100 decodes to illegal (reserved in Zicsr)" {
    // csr=0x300, rs1=0, funct3=100 (reserved), rd=5, opcode=0x73
    // 0x300 << 20 | 0 << 15 | 100 << 12 | 5 << 7 | 0x73
    //   = 0x30004_2F3
    const i = decode(0x300042F3);
    try std.testing.expectEqual(Op.illegal, i.op);
}
```

- [ ] **Step 2: Add the six new `Op` variants + the `csr: u12` field on `Instruction`**

At the top of `src/decoder.zig`, extend the `Op` enum (insert just before `illegal`):

```zig
pub const Op = enum {
    // RV32I — base integer (Plan 1.A)
    lui,
    auipc,
    jal,
    jalr,
    beq,
    bne,
    blt,
    bge,
    bltu,
    bgeu,
    lb,
    lh,
    lw,
    lbu,
    lhu,
    sb,
    sh,
    sw,
    addi,
    slti,
    sltiu,
    xori,
    ori,
    andi,
    slli,
    srli,
    srai,
    add,
    sub,
    sll,
    slt,
    sltu,
    xor_,
    srl,
    sra,
    or_,
    and_,
    fence,
    ecall,
    ebreak,
    // RV32M — multiply/divide (Plan 1.B, Task 2)
    mul,
    mulh,
    mulhsu,
    mulhu,
    div,
    divu,
    rem,
    remu,
    // Zifencei (Plan 1.B, Task 5)
    fence_i,
    // RV32A — atomics (Plan 1.B, Task 6)
    lr_w,
    sc_w,
    amoswap_w,
    amoadd_w,
    amoxor_w,
    amoand_w,
    amoor_w,
    amomin_w,
    amomax_w,
    amominu_w,
    amomaxu_w,
    // Zicsr (Plan 1.C, Task 3)
    csrrw,
    csrrs,
    csrrc,
    csrrwi,
    csrrsi,
    csrrci,
    // Machine-mode privileged (Plan 1.C, Task 9)
    mret,
    wfi,
    // (more added in later plans)
    illegal,
};
```

Extend the `Instruction` struct to carry the 12-bit CSR address:

```zig
pub const Instruction = struct {
    op: Op,
    rd: u5 = 0,
    rs1: u5 = 0, // on csrr*i, this slot holds the 5-bit uimm (not a register)
    rs2: u5 = 0,
    imm: i32 = 0,
    csr: u12 = 0,
    raw: u32 = 0,
};
```

- [ ] **Step 3: Rewrite the SYSTEM opcode arm in `decode()` to dispatch by funct3**

In `src/decoder.zig`, replace the existing `0b1110011 => {...}` block with:

```zig
        0b1110011 => blk: {
            const f3 = funct3(word);
            const imm12: u32 = (word >> 20) & 0xFFF;
            if (f3 == 0b000) {
                // ecall / ebreak / mret / wfi — distinguished by the full 12-bit imm field.
                // rd and rs1 are required to be zero for these; if they're not, the
                // instruction is still a valid encoding per spec, so we don't check.
                const op: Op = switch (imm12) {
                    0x000 => .ecall,
                    0x001 => .ebreak,
                    0x302 => .mret,
                    0x105 => .wfi,
                    else => .illegal,
                };
                break :blk .{ .op = op, .raw = word };
            }
            // Zicsr — 12-bit csr address lives in bits 31:20.
            const csr_addr: u12 = @truncate(imm12);
            const op: Op = switch (f3) {
                0b001 => .csrrw,
                0b010 => .csrrs,
                0b011 => .csrrc,
                0b100 => .illegal, // reserved funct3
                0b101 => .csrrwi,
                0b110 => .csrrsi,
                0b111 => .csrrci,
                else => .illegal, // f3 == 0 handled above
            };
            break :blk .{
                .op = op,
                .rd = rd(word),
                .rs1 = rs1(word),
                .csr = csr_addr,
                .raw = word,
            };
        },
```

- [ ] **Step 4: Run the tests**

Run: `zig build test`
Expected: all existing tests pass; the 7 new decode tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/decoder.zig
git commit -m "feat: decode Zicsr (csrrw/rs/rc/wi/si/ci), mret, wfi; add Instruction.csr field"
```

---

### Task 4: Execute Zicsr — 6 arms in `execute.zig`

**Files:**
- Modify: `src/execute.zig`

**Why this task:** Now that the decoder produces Zicsr variants and `csr.zig` owns the read/write logic, execution is a thin adapter: read old value, compute new value per the instruction's rule (swap / set / clear / imm-variants), write back old value to `rd`, commit new value to the CSR, advance PC. The RISC-V spec mandates an ordering nuance — if `rd == x0` for `csrrw`, the CSR read is suppressed; if `rs1 == x0` (or `uimm == 0`) for `csrrs`/`csrrc`/`csrrsi`/`csrrci`, the CSR write is suppressed. This prevents accidental side effects when the programmer uses these as "read-only" or "write-only" ops.

Note: `mret`/`wfi` execute arms are **not** in this task — they land in Task 9 once the trap module exists. For now, new SYSTEM variants that aren't Zicsr (`ecall`, `ebreak`, `mret`, `wfi`) continue to hit the existing `.ecall, .ebreak => return ExecuteError.UnsupportedInstruction` arm, with `mret`/`wfi` added to it transiently; Tasks 5 and 8 rewire.

- [ ] **Step 1: Write failing execute tests**

Append to `src/execute.zig`, after the existing RV32A tests:

```zig
test "CSRRW swaps: rd gets old CSR, CSR gets rs1" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    // Preload mtvec with something observable.
    rig.cpu.csr.mtvec = 0xDEAD_BEE0;
    // Write x1 = 0xCAFE_BABC (word-aligned, since mtvec is stored as-written but we'll
    // end up with the low-2-bits still present — mtvec is not masked on write).
    rig.cpu.writeReg(1, 0xCAFE_BABC);
    try dispatch(.{ .op = .csrrw, .rd = 2, .rs1 = 1, .csr = 0x305, .raw = 0 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEE0), rig.cpu.readReg(2));
    try std.testing.expectEqual(@as(u32, 0xCAFE_BABC), rig.cpu.csr.mtvec);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.pc);
}

test "CSRRW with rd=x0 suppresses CSR read (no trap on write-only CSRs)" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mtvec = 0x1111_1110;
    rig.cpu.writeReg(1, 0x2222_2220);
    try dispatch(.{ .op = .csrrw, .rd = 0, .rs1 = 1, .csr = 0x305, .raw = 0 }, &rig.cpu);
    // rd=x0 means we don't observe the old value; the CSR still got written.
    try std.testing.expectEqual(@as(u32, 0x2222_2220), rig.cpu.csr.mtvec);
}

test "CSRRS sets bits: new = old | rs1, rd = old" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mcause = 0xAAAA_AAAA;
    rig.cpu.writeReg(1, 0x5555_5555);
    try dispatch(.{ .op = .csrrs, .rd = 2, .rs1 = 1, .csr = 0x342, .raw = 0 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xAAAA_AAAA), rig.cpu.readReg(2));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), rig.cpu.csr.mcause);
}

test "CSRRS with rs1=x0 suppresses CSR write (read-only effect)" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mcause = 0xAAAA_AAAA;
    // Pre-seed x5 with a sentinel to confirm we overwrite it with the CSR read.
    rig.cpu.writeReg(5, 0x1234_5678);
    try dispatch(.{ .op = .csrrs, .rd = 5, .rs1 = 0, .csr = 0x342, .raw = 0 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xAAAA_AAAA), rig.cpu.readReg(5));
    try std.testing.expectEqual(@as(u32, 0xAAAA_AAAA), rig.cpu.csr.mcause);
}

test "CSRRC clears bits: new = old & ~rs1, rd = old" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mtval = 0xFF00_FF00;
    rig.cpu.writeReg(1, 0x0F0F_0F0F);
    try dispatch(.{ .op = .csrrc, .rd = 2, .rs1 = 1, .csr = 0x343, .raw = 0 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFF00_FF00), rig.cpu.readReg(2));
    try std.testing.expectEqual(@as(u32, 0xF000_F000), rig.cpu.csr.mtval);
}

test "CSRRWI writes zero-extended uimm to CSR, rd gets old value" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mepc = 0x8000_1000;
    // rs1 slot holds the 5-bit uimm = 0x1F = 31.
    try dispatch(.{ .op = .csrrwi, .rd = 2, .rs1 = 0x1F, .csr = 0x341, .raw = 0 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x8000_1000), rig.cpu.readReg(2));
    // mepc forces 4-byte alignment on write → 31 & ~3 = 28 = 0x1C.
    try std.testing.expectEqual(@as(u32, 0x0000_001C), rig.cpu.csr.mepc);
}

test "CSRRSI with uimm=0 suppresses CSR write" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mstatus = 0x0000_1880;
    try dispatch(.{ .op = .csrrsi, .rd = 2, .rs1 = 0, .csr = 0x300, .raw = 0 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x0000_1880), rig.cpu.readReg(2));
    try std.testing.expectEqual(@as(u32, 0x0000_1880), rig.cpu.csr.mstatus);
}

test "CSRRCI with nonzero uimm clears bits" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mie = 0x0000_0FFF;
    // Clear low 5 bits using uimm=0x0F.
    try dispatch(.{ .op = .csrrci, .rd = 2, .rs1 = 0x0F, .csr = 0x304, .raw = 0 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x0000_0FFF), rig.cpu.readReg(2));
    try std.testing.expectEqual(@as(u32, 0x0000_0FF0), rig.cpu.csr.mie);
}

test "CSR access in U-mode returns error.IllegalInstruction (pre-trap-wiring)" {
    // NOTE: In Task 7 this test's expectation flips from "error propagation"
    // to "traps and continues". For now we assert the pre-trap contract.
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.privilege = .U;
    try std.testing.expectError(
        ExecuteError.IllegalInstruction,
        dispatch(.{ .op = .csrrw, .rd = 1, .rs1 = 2, .csr = 0x300, .raw = 0 }, &rig.cpu),
    );
}
```

- [ ] **Step 2: Import `csr.zig` into `execute.zig` and add the arms**

At the top of `src/execute.zig`, add the import line alongside the existing imports:

```zig
const std = @import("std");
const cpu_mod = @import("cpu.zig");
const decoder = @import("decoder.zig");
const csr_mod = @import("csr.zig");
```

Extend the `ExecuteError` set (temporarily — Task 6 narrows it) to surface CSR errors:

```zig
pub const ExecuteError = error{
    UnsupportedInstruction,
    IllegalInstruction,
    Halt,
    OutOfBounds,
    MisalignedAccess,
    UnexpectedRegister,
    WriteFailed,
};
```

(No changes yet — the `IllegalInstruction` variant already exists. `csr_mod.CsrError.IllegalInstruction` maps to it.)

Add two new switch arms to `dispatch` in `src/execute.zig`. Insert them just before the `.illegal =>` arm. The register-source form:

```zig
        .csrrw, .csrrs, .csrrc => {
            const rs1_val = cpu.readReg(instr.rs1);
            const do_read = (instr.op != .csrrw) or (instr.rd != 0);
            const do_write = (instr.op == .csrrw) or (instr.rs1 != 0);
            const old: u32 = if (do_read)
                csr_mod.csrRead(cpu, instr.csr) catch |e| switch (e) {
                    error.IllegalInstruction => return ExecuteError.IllegalInstruction,
                }
            else
                0;
            if (do_write) {
                const new: u32 = switch (instr.op) {
                    .csrrw => rs1_val,
                    .csrrs => old | rs1_val,
                    .csrrc => old & ~rs1_val,
                    else => unreachable,
                };
                csr_mod.csrWrite(cpu, instr.csr, new) catch |e| switch (e) {
                    error.IllegalInstruction => return ExecuteError.IllegalInstruction,
                };
            }
            if (instr.rd != 0) cpu.writeReg(instr.rd, old);
            cpu.pc +%= 4;
        },
        .csrrwi, .csrrsi, .csrrci => {
            // rs1 slot holds the 5-bit zero-extended uimm; not a register index.
            const uimm: u32 = instr.rs1;
            const do_read = (instr.op != .csrrwi) or (instr.rd != 0);
            const do_write = (instr.op == .csrrwi) or (uimm != 0);
            const old: u32 = if (do_read)
                csr_mod.csrRead(cpu, instr.csr) catch |e| switch (e) {
                    error.IllegalInstruction => return ExecuteError.IllegalInstruction,
                }
            else
                0;
            if (do_write) {
                const new: u32 = switch (instr.op) {
                    .csrrwi => uimm,
                    .csrrsi => old | uimm,
                    .csrrci => old & ~uimm,
                    else => unreachable,
                };
                csr_mod.csrWrite(cpu, instr.csr, new) catch |e| switch (e) {
                    error.IllegalInstruction => return ExecuteError.IllegalInstruction,
                };
            }
            if (instr.rd != 0) cpu.writeReg(instr.rd, old);
            cpu.pc +%= 4;
        },
```

Also extend the stubbed-systems arm so `mret`/`wfi` don't crash before Task 9 wires them — leave them returning `UnsupportedInstruction` temporarily (they already decode to those variants so a missing switch arm would be a compile error):

```zig
        .ecall, .ebreak, .mret, .wfi => return ExecuteError.UnsupportedInstruction,
```

- [ ] **Step 3: Run the tests**

Run: `zig build test`
Expected: all existing tests pass; the 9 new CSR-execution tests pass. The `Cpu.run propagates UnsupportedInstruction` test from Plan 1.A still passes (ecall still returns UnsupportedInstruction).

- [ ] **Step 4: Commit**

```bash
git add src/execute.zig
git commit -m "feat: execute Zicsr (csrrw/rs/rc and immediate variants) with spec side-effect rules"
```

---

### Task 5: `src/trap.zig` — `Cause` enum, `enter`, `exit_mret`

**Files:**
- Create: `src/trap.zig`
- Modify: `src/main.zig` (add `_ = @import("trap.zig");`)

**Why this task:** The spec's trap entry and exit sequences are precise bit-level CSR manipulations. Keeping them inside `execute.zig` would force every trapping instruction to inline the 6-step dance. `trap.zig` factors it out as two functions over `*Cpu`. From this task onward, any instruction that wants to trap calls `trap.enter(cause, tval, &cpu)` and the trap module handles the CSR and PC updates.

- [ ] **Step 1: Create `src/trap.zig`**

```zig
const std = @import("std");
const cpu_mod = @import("cpu.zig");
const csr = @import("csr.zig");
const Cpu = cpu_mod.Cpu;
const PrivilegeMode = cpu_mod.PrivilegeMode;

/// Synchronous exception cause codes — spec §Privilege & trap model
/// and docs/references/riscv-traps.md §Common mcause values.
/// Interrupt causes (high bit set) aren't raised in Phase 1.
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
    ecall_from_m = 11,
};

/// Take a synchronous trap. Implements spec §Trap entry:
///   1. mepc  ← cpu.pc (the trapping instruction's address)
///   2. mcause ← cause
///   3. mtval  ← tval (faulting address for memory traps; 0 otherwise;
///               the raw 32-bit instruction word for illegal-instruction)
///   4. mstatus.MPP  ← current privilege mode
///   5. mstatus.MPIE ← mstatus.MIE; mstatus.MIE ← 0
///   6. privilege ← M; pc ← mtvec.BASE (direct mode only in Phase 1)
/// Always clears cpu.reservation (trap handlers may run arbitrary code
/// that makes the LR/SC reservation meaningless).
pub fn enter(cause: Cause, tval: u32, cpu: *Cpu) void {
    cpu.csr.mepc = cpu.pc & csr.MEPC_ALIGN_MASK;
    cpu.csr.mcause = @intFromEnum(cause);
    cpu.csr.mtval = tval;

    // mstatus updates in one pass.
    var ms = cpu.csr.mstatus;
    // MPP ← current priv (clear first, then OR in the new value).
    ms &= ~csr.MSTATUS_MPP_MASK;
    ms |= (@as(u32, @intFromEnum(cpu.privilege)) << csr.MSTATUS_MPP_SHIFT) & csr.MSTATUS_MPP_MASK;
    // MPIE ← MIE, then MIE ← 0.
    if ((ms & csr.MSTATUS_MIE) != 0) {
        ms |= csr.MSTATUS_MPIE;
    } else {
        ms &= ~csr.MSTATUS_MPIE;
    }
    ms &= ~csr.MSTATUS_MIE;
    cpu.csr.mstatus = ms;

    cpu.privilege = .M;
    cpu.pc = cpu.csr.mtvec & csr.MTVEC_BASE_MASK;
    cpu.reservation = null;
}

/// Return from trap via mret. Implements spec §Trap exit:
///   1. pc ← mepc
///   2. privilege ← mstatus.MPP
///   3. mstatus.MIE ← mstatus.MPIE
///      mstatus.MPIE ← 1
///      mstatus.MPP ← U (least-privileged supported mode)
/// MPP values not supported by the implementation (0b01 = S, 0b10 = H)
/// are normalized to U, matching RISC-V WARL semantics.
pub fn exit_mret(cpu: *Cpu) void {
    cpu.pc = cpu.csr.mepc & csr.MEPC_ALIGN_MASK;

    const mpp_bits: u2 = @truncate((cpu.csr.mstatus & csr.MSTATUS_MPP_MASK) >> csr.MSTATUS_MPP_SHIFT);
    cpu.privilege = switch (mpp_bits) {
        0b00 => .U,
        0b11 => .M,
        else => .U, // unsupported modes read back as U
    };

    var ms = cpu.csr.mstatus;
    if ((ms & csr.MSTATUS_MPIE) != 0) {
        ms |= csr.MSTATUS_MIE;
    } else {
        ms &= ~csr.MSTATUS_MIE;
    }
    ms |= csr.MSTATUS_MPIE; // MPIE ← 1
    ms &= ~csr.MSTATUS_MPP_MASK; // MPP ← 0b00 (U)
    cpu.csr.mstatus = ms;
}

// --- tests ---

const Memory = @import("memory.zig").Memory;

test "enter sets mepc, mcause, mtval; jumps to mtvec; switches to M" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0100);
    cpu.privilege = .U;
    cpu.csr.mtvec = 0x8000_0400; // direct mode (MODE=00)
    cpu.csr.mstatus = csr.MSTATUS_MIE; // MIE=1, MPIE=0, MPP=00

    enter(.ecall_from_u, 0, &cpu);

    try std.testing.expectEqual(@as(u32, 0x8000_0100), cpu.csr.mepc);
    try std.testing.expectEqual(@intFromEnum(Cause.ecall_from_u), cpu.csr.mcause);
    try std.testing.expectEqual(@as(u32, 0), cpu.csr.mtval);
    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0400), cpu.pc);
    // MPP = U (0b00), MPIE = 1 (from MIE), MIE = 0
    try std.testing.expectEqual(@as(u32, csr.MSTATUS_MPIE), cpu.csr.mstatus & (csr.MSTATUS_MPP_MASK | csr.MSTATUS_MPIE | csr.MSTATUS_MIE));
}

test "enter masks mtvec MODE bits (direct mode only in Phase 1)" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0200);
    cpu.csr.mtvec = 0x8000_0403; // BASE=0x80000400, MODE=01 (vectored bits set)
    enter(.illegal_instruction, 0, &cpu);
    // Direct mode regardless of MODE bits.
    try std.testing.expectEqual(@as(u32, 0x8000_0400), cpu.pc);
}

test "enter from M-mode sets MPP=M" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0100);
    cpu.privilege = .M;
    enter(.illegal_instruction, 0xDEADBEEF, &cpu);
    const mpp_bits: u2 = @truncate((cpu.csr.mstatus & csr.MSTATUS_MPP_MASK) >> csr.MSTATUS_MPP_SHIFT);
    try std.testing.expectEqual(@as(u2, 0b11), mpp_bits);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), cpu.csr.mtval);
}

test "enter clears reservation (LR/SC invariant)" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0100);
    cpu.reservation = 0x8000_0500;
    enter(.illegal_instruction, 0, &cpu);
    try std.testing.expect(cpu.reservation == null);
}

test "exit_mret restores PC from mepc, privilege from MPP" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0400);
    cpu.privilege = .M;
    cpu.csr.mepc = 0x8000_0108;
    // MPP = U (0b00), MPIE = 1, MIE = 0
    cpu.csr.mstatus = csr.MSTATUS_MPIE;

    exit_mret(&cpu);

    try std.testing.expectEqual(@as(u32, 0x8000_0108), cpu.pc);
    try std.testing.expectEqual(PrivilegeMode.U, cpu.privilege);
    // MIE ← MPIE = 1. MPIE ← 1. MPP ← U (0).
    try std.testing.expectEqual(
        csr.MSTATUS_MIE | csr.MSTATUS_MPIE,
        cpu.csr.mstatus & (csr.MSTATUS_MPP_MASK | csr.MSTATUS_MPIE | csr.MSTATUS_MIE),
    );
}

test "exit_mret with MPP=M restores M-mode" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0400);
    cpu.privilege = .M;
    cpu.csr.mepc = 0x8000_0500;
    cpu.csr.mstatus = csr.MSTATUS_MPP_MASK | csr.MSTATUS_MPIE; // MPP=M, MPIE=1
    exit_mret(&cpu);
    try std.testing.expectEqual(PrivilegeMode.M, cpu.privilege);
}

test "exit_mret unsupported MPP (reserved_s) normalizes to U" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0x8000_0400);
    cpu.privilege = .M;
    cpu.csr.mepc = 0x8000_0200;
    // Write MPP = 01 (unsupported in 2-mode build)
    cpu.csr.mstatus = (@as(u32, 0b01) << csr.MSTATUS_MPP_SHIFT) | csr.MSTATUS_MPIE;
    exit_mret(&cpu);
    try std.testing.expectEqual(PrivilegeMode.U, cpu.privilege);
}
```

- [ ] **Step 2: Wire `trap.zig` into the test root**

Extend the `comptime` block in `src/main.zig`:

```zig
comptime {
    _ = @import("cpu.zig");
    _ = @import("memory.zig");
    _ = @import("devices/halt.zig");
    _ = @import("devices/uart.zig");
    _ = @import("decoder.zig");
    _ = @import("execute.zig");
    _ = @import("csr.zig");
    _ = @import("trap.zig");
}
```

- [ ] **Step 3: Run the tests**

Run: `zig build test`
Expected: all existing tests pass; the 6 new trap tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/trap.zig src/main.zig
git commit -m "feat: add src/trap.zig with Cause enum, enter, and exit_mret"
```

---

### Task 6: Map memory errors to traps inside `execute.zig` load/store sites

**Files:**
- Modify: `src/execute.zig`
- Modify: `src/cpu.zig` (narrow `StepError`, delete the now-unused `mapMemErr` helper)

**Why this task:** Today any memory error from `loadWord`/`storeWord`/etc. propagates out of `dispatch` as an `ExecuteError` variant, which `cpu.step` turns into a `StepError`, which bubbles out of `cpu.run`. Plan 1.C replaces the top half of that pipeline: memory errors at instruction level become **synchronous traps**, which means `dispatch` updates CPU state (via `trap.enter`) and returns normally (the next `step` resumes at `mtvec`). Only `error.Halt` and the new `error.FatalTrap` (used later by Task 18's `--halt-on-trap`) still propagate.

- [ ] **Step 1: Add `mapMemCause` helper + narrow `ExecuteError`**

In `src/execute.zig`, add these declarations near the top (after the imports, before `ExecuteError`):

```zig
const trap = @import("trap.zig");
const MemoryError = @import("memory.zig").MemoryError;

/// Map a memory error at a load site to the appropriate trap cause.
/// A Halt error is not a trap — it's the halt-MMIO signal and we
/// re-raise it so it propagates out of cpu.step to terminate the run.
fn loadTrapCause(e: MemoryError) !trap.Cause {
    return switch (e) {
        error.MisalignedAccess => trap.Cause.load_addr_misaligned,
        error.OutOfBounds, error.UnexpectedRegister, error.WriteFailed => trap.Cause.load_access_fault,
        error.Halt => error.Halt,
    };
}

fn storeTrapCause(e: MemoryError) !trap.Cause {
    return switch (e) {
        error.MisalignedAccess => trap.Cause.store_addr_misaligned,
        error.OutOfBounds, error.UnexpectedRegister, error.WriteFailed => trap.Cause.store_access_fault,
        error.Halt => error.Halt,
    };
}
```

Replace the `ExecuteError` declaration at the top of `src/execute.zig` with:

```zig
pub const ExecuteError = error{
    Halt,
    FatalTrap,
};
```

(All the variants that mapped to CPU-level errors — `UnsupportedInstruction`, `IllegalInstruction`, `MisalignedAccess`, `OutOfBounds`, `UnexpectedRegister`, `WriteFailed` — disappear. They're absorbed into traps now, or into the two remaining variants for fatal cases.)

Delete the `mapMemErr` helper at the bottom of `src/execute.zig` — it's gone.

- [ ] **Step 2: Rewrite each load arm to trap on memory error**

In `src/execute.zig`, replace the existing loads arm:

```zig
        .lb, .lh, .lw, .lbu, .lhu => {
            const addr = cpu.readReg(instr.rs1) +% @as(u32, @bitCast(instr.imm));
            const value: u32 = switch (instr.op) {
                .lb => blk: {
                    const byte = cpu.memory.loadByte(addr) catch |e| {
                        const cause = loadTrapCause(e) catch return ExecuteError.Halt;
                        trap.enter(cause, addr, cpu);
                        return;
                    };
                    break :blk @bitCast(@as(i32, @as(i8, @bitCast(byte))));
                },
                .lbu => blk: {
                    const byte = cpu.memory.loadByte(addr) catch |e| {
                        const cause = loadTrapCause(e) catch return ExecuteError.Halt;
                        trap.enter(cause, addr, cpu);
                        return;
                    };
                    break :blk @as(u32, byte);
                },
                .lh => blk: {
                    const half = cpu.memory.loadHalfword(addr) catch |e| {
                        const cause = loadTrapCause(e) catch return ExecuteError.Halt;
                        trap.enter(cause, addr, cpu);
                        return;
                    };
                    break :blk @bitCast(@as(i32, @as(i16, @bitCast(half))));
                },
                .lhu => blk: {
                    const half = cpu.memory.loadHalfword(addr) catch |e| {
                        const cause = loadTrapCause(e) catch return ExecuteError.Halt;
                        trap.enter(cause, addr, cpu);
                        return;
                    };
                    break :blk @as(u32, half);
                },
                .lw => cpu.memory.loadWord(addr) catch |e| {
                    const cause = loadTrapCause(e) catch return ExecuteError.Halt;
                    trap.enter(cause, addr, cpu);
                    return;
                },
                else => unreachable,
            };
            cpu.writeReg(instr.rd, value);
            cpu.pc +%= 4;
        },
```

Replace each store arm similarly. `.sb`:

```zig
        .sb => {
            const addr = cpu.readReg(instr.rs1) +% @as(u32, @bitCast(instr.imm));
            const value: u8 = @truncate(cpu.readReg(instr.rs2));
            cpu.memory.storeByte(addr, value) catch |e| {
                const cause = storeTrapCause(e) catch return ExecuteError.Halt;
                trap.enter(cause, addr, cpu);
                return;
            };
            cpu.pc +%= 4;
        },
        .sh => {
            const addr = cpu.readReg(instr.rs1) +% @as(u32, @bitCast(instr.imm));
            const value: u16 = @truncate(cpu.readReg(instr.rs2));
            cpu.memory.storeHalfword(addr, value) catch |e| {
                const cause = storeTrapCause(e) catch return ExecuteError.Halt;
                trap.enter(cause, addr, cpu);
                return;
            };
            cpu.pc +%= 4;
        },
        .sw => {
            const addr = cpu.readReg(instr.rs1) +% @as(u32, @bitCast(instr.imm));
            cpu.memory.storeWord(addr, cpu.readReg(instr.rs2)) catch |e| {
                const cause = storeTrapCause(e) catch return ExecuteError.Halt;
                trap.enter(cause, addr, cpu);
                return;
            };
            cpu.pc +%= 4;
        },
```

- [ ] **Step 3: Rewrite LR/SC and AMO arms**

Replace the existing `.lr_w` arm:

```zig
        .lr_w => {
            const addr = cpu.readReg(instr.rs1);
            if (addr & 3 != 0) {
                trap.enter(.load_addr_misaligned, addr, cpu);
                return;
            }
            const val = cpu.memory.loadWord(addr) catch |e| {
                const cause = loadTrapCause(e) catch return ExecuteError.Halt;
                trap.enter(cause, addr, cpu);
                return;
            };
            cpu.reservation = addr;
            cpu.writeReg(instr.rd, val);
            cpu.pc +%= 4;
        },
        .sc_w => {
            const addr = cpu.readReg(instr.rs1);
            if (addr & 3 != 0) {
                trap.enter(.store_addr_misaligned, addr, cpu);
                return;
            }
            const holds = (cpu.reservation != null and cpu.reservation.? == addr);
            if (holds) {
                cpu.memory.storeWord(addr, cpu.readReg(instr.rs2)) catch |e| {
                    cpu.reservation = null;
                    const cause = storeTrapCause(e) catch return ExecuteError.Halt;
                    trap.enter(cause, addr, cpu);
                    return;
                };
            }
            cpu.reservation = null;
            cpu.writeReg(instr.rd, if (holds) @as(u32, 0) else @as(u32, 1));
            cpu.pc +%= 4;
        },
        .amoswap_w, .amoadd_w, .amoxor_w, .amoand_w, .amoor_w,
        .amomin_w, .amomax_w, .amominu_w, .amomaxu_w => {
            const addr = cpu.readReg(instr.rs1);
            if (addr & 3 != 0) {
                trap.enter(.store_addr_misaligned, addr, cpu);
                return;
            }
            const old = cpu.memory.loadWord(addr) catch |e| {
                const cause = loadTrapCause(e) catch return ExecuteError.Halt;
                trap.enter(cause, addr, cpu);
                return;
            };
            const rs2_val = cpu.readReg(instr.rs2);
            const new: u32 = switch (instr.op) {
                .amoswap_w => rs2_val,
                .amoadd_w => old +% rs2_val,
                .amoxor_w => old ^ rs2_val,
                .amoand_w => old & rs2_val,
                .amoor_w => old | rs2_val,
                .amomin_w => if (@as(i32, @bitCast(old)) < @as(i32, @bitCast(rs2_val))) old else rs2_val,
                .amomax_w => if (@as(i32, @bitCast(old)) > @as(i32, @bitCast(rs2_val))) old else rs2_val,
                .amominu_w => if (old < rs2_val) old else rs2_val,
                .amomaxu_w => if (old > rs2_val) old else rs2_val,
                else => unreachable,
            };
            cpu.memory.storeWord(addr, new) catch |e| {
                const cause = storeTrapCause(e) catch return ExecuteError.Halt;
                trap.enter(cause, addr, cpu);
                return;
            };
            cpu.writeReg(instr.rd, old);
            cpu.pc +%= 4;
        },
```

- [ ] **Step 4: Narrow `StepError` in `src/cpu.zig`**

Replace the `StepError` definition in `src/cpu.zig`:

```zig
pub const StepError = error{
    Halt,
    FatalTrap,
};
```

Remove the `mapMemErr` function from `Cpu` (it's gone), and update `step` to not call it:

```zig
    pub fn step(self: *Cpu) StepError!void {
        const word = self.memory.loadWord(self.pc) catch |e| switch (e) {
            error.Halt => return StepError.Halt,
            // Other memory errors at instruction fetch become an instruction-access-fault
            // trap. Phase 1 rarely hits this (entry points are always well-formed), but
            // a broken program that jumps to an unmapped address will land here.
            error.MisalignedAccess => {
                trap.enter(.instr_addr_misaligned, self.pc, self);
                return;
            },
            else => {
                trap.enter(.instr_access_fault, self.pc, self);
                return;
            },
        };
        const instr = decoder.decode(word);
        return execute.dispatch(instr, self) catch |e| switch (e) {
            error.Halt => StepError.Halt,
            error.FatalTrap => StepError.FatalTrap,
        };
    }
```

Add an import of `trap.zig` at the top of `src/cpu.zig`:

```zig
const trap = @import("trap.zig");
```

- [ ] **Step 5: Update the cpu.zig test that relied on `UnsupportedInstruction`**

Delete the now-obsolete test at the bottom of `src/cpu.zig`:

```zig
// REMOVE THIS TEST:
test "Cpu.run propagates UnsupportedInstruction" { ... }
```

Replace it with a test exercising the new trap-based behavior — ECALL triggers a trap and jumps to mtvec, it doesn't return an error:

```zig
test "Cpu.step: ECALL in M-mode traps to mtvec with mcause=11" {
    // Deferred from Task 8 (ecall rewiring) — this test lands in Task 8.
    // For now, deleting the UnsupportedInstruction test is enough; Task 7
    // will land an illegal-instruction equivalent, Task 8 wires ecall.
}
```

Actually — leave that placeholder out. Just delete the obsolete test and move on. Tasks 7–8 add real trap-path tests.

Also delete the `Cpu.run halts cleanly when program writes to halt MMIO` test's final assertion if it referenced `StepError.UnsupportedInstruction` anywhere; it doesn't, but double-check. That test should still pass unchanged (halt is still `error.Halt`).

- [ ] **Step 6: Update execute.zig tests that expected the dropped error variants**

Search `src/execute.zig` for every test that uses `ExecuteError.MisalignedAccess`, `ExecuteError.OutOfBounds`, `ExecuteError.UnexpectedRegister`, or `ExecuteError.WriteFailed` in an `expectError`. Each of those has to flip to asserting that (a) `dispatch` returns normally, and (b) cpu state now reflects a trap (PC == mtvec.BASE, mcause set, mepc set to the trapping instruction's PC).

The existing tests that need rewiring:

Find this test:

```zig
test "misaligned LW returns error.MisalignedAccess" {
```

Replace with:

```zig
test "misaligned LW traps with cause=load_addr_misaligned" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 1); // misaligned
    try dispatch(.{ .op = .lw, .rd = 2, .rs1 = 1, .imm = 0 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x200, rig.cpu.pc);
    try std.testing.expectEqual(
        @intFromEnum(@import("trap.zig").Cause.load_addr_misaligned),
        rig.cpu.csr.mcause,
    );
    try std.testing.expectEqual(mem_mod.RAM_BASE + 1, rig.cpu.csr.mtval);
}
```

Apply the same rewiring pattern to every "load/store error" test in `execute.zig`. If a test expected `OutOfBounds`, change cause to `.load_access_fault` / `.store_access_fault`. If it expected `MisalignedAccess`, change cause to `.load_addr_misaligned` / `.store_addr_misaligned`. Plan 1.A/1.B wrote around 6 such tests — count them all and update one by one.

- [ ] **Step 7: Run the tests**

Run: `zig build test`
Expected: all tests pass, including the rewritten trap-path tests. If a test fails, the most likely culprit is a forgotten site in `execute.zig` that still returns a narrowed-out error variant — Zig's exhaustive switch will catch it at compile time and point you to the offending line.

- [ ] **Step 8: Commit**

```bash
git add src/execute.zig src/cpu.zig
git commit -m "refactor: route memory errors to trap.enter; narrow ExecuteError/StepError to Halt+FatalTrap"
```

---

### Task 7: Illegal-instruction trap — replace `.illegal =>` and CSR-illegal-access propagation

**Files:**
- Modify: `src/execute.zig`

**Why this task:** Two sources of illegal-instruction events remain un-trapped after Task 6: (a) the `.illegal` decoder variant, which today returns `ExecuteError.IllegalInstruction`; (b) U-mode CSR access, which `csr.zig` raises as `CsrError.IllegalInstruction`. Both should fire an illegal-instruction trap with `mtval = instr.raw`. After this task the only `dispatch` error variants are `Halt` and `FatalTrap` (the latter still unused until Task 18).

- [ ] **Step 1: Write failing test for the illegal-decoder path**

Append to `src/execute.zig`, in the test block:

```zig
test "illegal opcode traps with cause=illegal_instruction, mtval=raw word" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    // Zero word is decoded to .illegal with raw=0 (the decoder's all-opcodes-unknown arm).
    try dispatch(.{ .op = .illegal, .raw = 0xFFFFFFFF }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x200, rig.cpu.pc);
    try std.testing.expectEqual(
        @intFromEnum(@import("trap.zig").Cause.illegal_instruction),
        rig.cpu.csr.mcause,
    );
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), rig.cpu.csr.mtval);
}

test "U-mode CSR access traps with cause=illegal_instruction" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    // csrrw should raise illegal-instruction, not propagate as error.
    try dispatch(
        .{ .op = .csrrw, .rd = 1, .rs1 = 2, .csr = 0x300, .raw = 0xDEADBEEF },
        &rig.cpu,
    );
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x200, rig.cpu.pc);
    try std.testing.expectEqual(
        @intFromEnum(@import("trap.zig").Cause.illegal_instruction),
        rig.cpu.csr.mcause,
    );
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), rig.cpu.csr.mtval);
}
```

(Also, delete or update the "CSR access in U-mode returns error.IllegalInstruction" test from Task 4 — it's flipping now to the trap-based behavior above.)

- [ ] **Step 2: Rewrite the `.illegal =>` arm**

In `src/execute.zig`, replace the existing `.illegal =>` arm with:

```zig
        .illegal => {
            trap.enter(.illegal_instruction, instr.raw, cpu);
        },
```

(No PC bump — `trap.enter` sets PC to `mtvec.BASE`.)

- [ ] **Step 3: Rewrite the CSR arms to trap on `CsrError.IllegalInstruction`**

In `src/execute.zig`, update the `.csrrw, .csrrs, .csrrc =>` and `.csrrwi, .csrrsi, .csrrci =>` arms' error-mapping blocks. Each `catch |e| switch (e) { error.IllegalInstruction => return ExecuteError.IllegalInstruction, }` becomes:

```zig
                csr_mod.csrRead(cpu, instr.csr) catch |e| switch (e) {
                    error.IllegalInstruction => {
                        trap.enter(.illegal_instruction, instr.raw, cpu);
                        return;
                    },
                }
```

(Same replacement for the `csrWrite` catches.)

Full updated `.csrrw, .csrrs, .csrrc` arm:

```zig
        .csrrw, .csrrs, .csrrc => {
            const rs1_val = cpu.readReg(instr.rs1);
            const do_read = (instr.op != .csrrw) or (instr.rd != 0);
            const do_write = (instr.op == .csrrw) or (instr.rs1 != 0);
            const old: u32 = if (do_read) blk: {
                break :blk csr_mod.csrRead(cpu, instr.csr) catch {
                    trap.enter(.illegal_instruction, instr.raw, cpu);
                    return;
                };
            } else 0;
            if (do_write) {
                const new: u32 = switch (instr.op) {
                    .csrrw => rs1_val,
                    .csrrs => old | rs1_val,
                    .csrrc => old & ~rs1_val,
                    else => unreachable,
                };
                csr_mod.csrWrite(cpu, instr.csr, new) catch {
                    trap.enter(.illegal_instruction, instr.raw, cpu);
                    return;
                };
            }
            if (instr.rd != 0) cpu.writeReg(instr.rd, old);
            cpu.pc +%= 4;
        },
        .csrrwi, .csrrsi, .csrrci => {
            const uimm: u32 = instr.rs1;
            const do_read = (instr.op != .csrrwi) or (instr.rd != 0);
            const do_write = (instr.op == .csrrwi) or (uimm != 0);
            const old: u32 = if (do_read) blk: {
                break :blk csr_mod.csrRead(cpu, instr.csr) catch {
                    trap.enter(.illegal_instruction, instr.raw, cpu);
                    return;
                };
            } else 0;
            if (do_write) {
                const new: u32 = switch (instr.op) {
                    .csrrwi => uimm,
                    .csrrsi => old | uimm,
                    .csrrci => old & ~uimm,
                    else => unreachable,
                };
                csr_mod.csrWrite(cpu, instr.csr, new) catch {
                    trap.enter(.illegal_instruction, instr.raw, cpu);
                    return;
                };
            }
            if (instr.rd != 0) cpu.writeReg(instr.rd, old);
            cpu.pc +%= 4;
        },
```

- [ ] **Step 4: Run the tests**

Run: `zig build test`
Expected: the two new trap tests pass; the old "returns error.IllegalInstruction" tests have been flipped to the trap contract. The compiler won't allow any dangling `ExecuteError.IllegalInstruction` references now — if one exists it'll be a compile error.

- [ ] **Step 5: Commit**

```bash
git add src/execute.zig
git commit -m "feat: illegal-instruction trap (decoder .illegal + U-mode CSR access)"
```

---

### Task 8: `ecall` + `ebreak` real semantics

**Files:**
- Modify: `src/execute.zig`

**Why this task:** `ecall` and `ebreak` currently return `ExecuteError.UnsupportedInstruction`, which Task 6 narrowed out of existence — so right now this compiles only because the temporary `mret`/`wfi` placeholder keeps the same error variant. Now we wire each to a real trap: `ecall` with cause depending on the current privilege (`ecall_from_u` = 8, `ecall_from_m` = 11), `ebreak` with cause `breakpoint` (3), both with `mtval = 0`.

- [ ] **Step 1: Write failing tests**

Append to `src/execute.zig`:

```zig
test "ECALL from U-mode traps with mcause=8, mepc=PC" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE + 0x100);
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    try dispatch(.{ .op = .ecall, .raw = 0x73 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 8), rig.cpu.csr.mcause);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x100, rig.cpu.csr.mepc);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x200, rig.cpu.pc);
    try std.testing.expectEqual(@import("cpu.zig").PrivilegeMode.M, rig.cpu.privilege);
}

test "ECALL from M-mode traps with mcause=11" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.privilege = .M;
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    try dispatch(.{ .op = .ecall, .raw = 0x73 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 11), rig.cpu.csr.mcause);
}

test "EBREAK traps with mcause=3 (breakpoint)" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    try dispatch(.{ .op = .ebreak, .raw = 0x100073 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 3), rig.cpu.csr.mcause);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x200, rig.cpu.pc);
}
```

- [ ] **Step 2: Rewrite the SYSTEM arm in `dispatch`**

Replace the temporary `.ecall, .ebreak, .mret, .wfi => return ExecuteError.UnsupportedInstruction,` with real arms for `.ecall`/`.ebreak` (leaving `.mret`/`.wfi` still stubbed until Task 9):

```zig
        .ecall => {
            const cause: trap.Cause = switch (cpu.privilege) {
                .M => .ecall_from_m,
                .U => .ecall_from_u,
                else => .ecall_from_u, // reserved modes treated as U (shouldn't happen)
            };
            trap.enter(cause, 0, cpu);
        },
        .ebreak => {
            trap.enter(.breakpoint, 0, cpu);
        },
        .mret, .wfi => return ExecuteError.FatalTrap, // placeholder — Task 9
```

(`FatalTrap` is chosen here just so the placeholder produces a distinct signal before Task 9 lands — it's cleared by Task 9 before the plan finishes.)

- [ ] **Step 3: Update the obsolete test in `cpu.zig`**

The "Cpu.run propagates UnsupportedInstruction" test was deleted in Task 6 — confirm no references remain. If not deleted then, do it now; otherwise skip.

- [ ] **Step 4: Run the tests**

Run: `zig build test`
Expected: the three new ecall/ebreak tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/execute.zig
git commit -m "feat: ecall/ebreak real trap semantics (cause 8/11 by priv; cause 3 for ebreak)"
```

---

### Task 9: `mret` + `wfi` execute arms (close the SYSTEM-opcode trap plumbing)

**Files:**
- Modify: `src/execute.zig`

**Why this task:** `mret` returns from a trap; `wfi` waits for an interrupt (a no-op in Phase 1 since no IRQ sources are wired). Both are M-mode-only; U-mode execution traps as illegal. After this task the SYSTEM opcode is fully wired, `ExecuteError` no longer needs `FatalTrap` for a placeholder (it stays for Task 18), and nothing in `dispatch` returns `UnsupportedInstruction`.

- [ ] **Step 1: Write failing tests**

Append to `src/execute.zig`:

```zig
test "MRET in M-mode: PC←mepc, privilege←MPP, MIE←MPIE, MPIE←1, MPP←U" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE + 0x400);
    defer rig.deinit();
    rig.cpu.privilege = .M;
    rig.cpu.csr.mepc = mem_mod.RAM_BASE + 0x108;
    // MPP=U(0), MPIE=1, MIE=0.
    rig.cpu.csr.mstatus = @import("csr.zig").MSTATUS_MPIE;
    try dispatch(.{ .op = .mret, .raw = 0x30200073 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x108, rig.cpu.pc);
    try std.testing.expectEqual(@import("cpu.zig").PrivilegeMode.U, rig.cpu.privilege);
    const ms = rig.cpu.csr.mstatus;
    const csr_mod = @import("csr.zig");
    try std.testing.expect((ms & csr_mod.MSTATUS_MIE) != 0);
    try std.testing.expect((ms & csr_mod.MSTATUS_MPIE) != 0);
    try std.testing.expectEqual(@as(u32, 0), ms & csr_mod.MSTATUS_MPP_MASK);
}

test "MRET in U-mode traps as illegal-instruction" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    try dispatch(.{ .op = .mret, .raw = 0x30200073 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x200, rig.cpu.pc);
    try std.testing.expectEqual(
        @intFromEnum(@import("trap.zig").Cause.illegal_instruction),
        rig.cpu.csr.mcause,
    );
}

test "WFI in M-mode is a no-op (advances PC by 4)" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.privilege = .M;
    try dispatch(.{ .op = .wfi, .raw = 0x10500073 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.pc);
}

test "WFI in U-mode traps as illegal-instruction" {
    // The spec says TW (timeout-wait) bit in mstatus can cause wfi to trap
    // from U-mode; we take the strict stance and always trap from U.
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    try dispatch(.{ .op = .wfi, .raw = 0x10500073 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x200, rig.cpu.pc);
    try std.testing.expectEqual(
        @intFromEnum(@import("trap.zig").Cause.illegal_instruction),
        rig.cpu.csr.mcause,
    );
}
```

- [ ] **Step 2: Replace the `.mret, .wfi` placeholder with real arms**

In `src/execute.zig`, delete `.mret, .wfi => return ExecuteError.FatalTrap,` and add:

```zig
        .mret => {
            if (cpu.privilege != .M) {
                trap.enter(.illegal_instruction, instr.raw, cpu);
                return;
            }
            trap.exit_mret(cpu);
        },
        .wfi => {
            if (cpu.privilege != .M) {
                trap.enter(.illegal_instruction, instr.raw, cpu);
                return;
            }
            // Phase 1 has no interrupt sources; wfi is a no-op (advance PC).
            cpu.pc +%= 4;
        },
```

- [ ] **Step 3: Run the tests**

Run: `zig build test`
Expected: all new tests pass. `FatalTrap` is now unused in `execute.zig` — but keep the error variant in `ExecuteError` since Task 18 re-uses it.

- [ ] **Step 4: Commit**

```bash
git add src/execute.zig
git commit -m "feat: mret (trap exit) and wfi (no-op in Phase 1); U-mode traps as illegal"
```

---

### Task 10: CLINT device (`src/devices/clint.zig`) + `memory.zig` dispatch

**Files:**
- Create: `src/devices/clint.zig`
- Modify: `src/memory.zig`
- Modify: `src/main.zig` (import into the `comptime` block; wire `Clint` into `Memory.init`)

**Why this task:** The CLINT (Core-Local Interruptor) is the simplest timer device in the RISC-V virt memory map, and `riscv-tests` `rv32mi-p-*` touches it indirectly (reading `mtime`). In Phase 1 we model the registers (so reads/writes don't fault) but do not deliver interrupts; Phase 2 adds the IRQ edges.

- [ ] **Step 1: Create `src/devices/clint.zig`**

```zig
const std = @import("std");

pub const CLINT_BASE: u32 = 0x0200_0000;
pub const CLINT_SIZE: u32 = 0x1_0000; // 64 KB, matches spec memory map

const OFF_MSIP: u32 = 0x0000;
const OFF_MTIMECMP: u32 = 0x4000;
const OFF_MTIME: u32 = 0xBFF8;

pub const ClintError = error{UnexpectedRegister};

/// A clock source returns nanoseconds since an arbitrary epoch.
/// Production uses std.time.nanoTimestamp; tests pass a fixture.
pub const ClockSourceFn = *const fn () i128;

fn defaultClockSource() i128 {
    return std.time.nanoTimestamp();
}

pub const Clint = struct {
    msip: u32 = 0,
    mtimecmp: u64 = 0,
    clock_source: ClockSourceFn,
    /// Anchor for mtime: nanosecond timestamp taken at init. mtime advances
    /// relative to this anchor so the first read is ~0 rather than some
    /// enormous wall-clock value.
    epoch_ns: i128,

    pub fn init(clock_source: ClockSourceFn) Clint {
        return .{
            .clock_source = clock_source,
            .epoch_ns = clock_source(),
        };
    }

    pub fn initDefault() Clint {
        return init(&defaultClockSource);
    }

    /// Convert (now - epoch) nanoseconds to ticks at 10 MHz nominal
    /// (100 ns per tick → divide by 100).
    fn mtime(self: *const Clint) u64 {
        const now = self.clock_source();
        const delta = now - self.epoch_ns;
        if (delta < 0) return 0;
        const ticks: u128 = @intCast(@divTrunc(delta, 100));
        return @truncate(ticks);
    }

    pub fn readByte(self: *const Clint, offset: u32) ClintError!u8 {
        return switch (offset) {
            0x0000...0x0003 => blk: {
                const idx: u2 = @truncate(offset - OFF_MSIP);
                break :blk @truncate(self.msip >> (@as(u5, idx) * 8));
            },
            0x4000...0x4007 => blk: {
                const idx: u3 = @truncate(offset - OFF_MTIMECMP);
                break :blk @truncate(self.mtimecmp >> (@as(u6, idx) * 8));
            },
            0xBFF8...0xBFFF => blk: {
                const idx: u3 = @truncate(offset - OFF_MTIME);
                break :blk @truncate(self.mtime() >> (@as(u6, idx) * 8));
            },
            else => 0, // lenient: unmapped CLINT offsets read as zero
        };
    }

    pub fn writeByte(self: *Clint, offset: u32, value: u8) ClintError!void {
        switch (offset) {
            0x0000...0x0003 => {
                const idx: u2 = @truncate(offset - OFF_MSIP);
                const shift: u5 = @as(u5, idx) * 8;
                const mask: u32 = ~(@as(u32, 0xFF) << shift);
                self.msip = (self.msip & mask) | (@as(u32, value) << shift);
            },
            0x4000...0x4007 => {
                const idx: u3 = @truncate(offset - OFF_MTIMECMP);
                const shift: u6 = @as(u6, idx) * 8;
                const mask: u64 = ~(@as(u64, 0xFF) << shift);
                self.mtimecmp = (self.mtimecmp & mask) | (@as(u64, value) << shift);
            },
            // mtime is read-only from the point of view of software in Phase 1.
            // Writes silently drop (WARL-ish).
            0xBFF8...0xBFFF => {},
            else => {}, // lenient: accept-no-op
        }
    }
};

test "msip round-trips byte-wise" {
    var c = Clint.init(&zeroClock);
    try c.writeByte(0x0000, 0x12);
    try c.writeByte(0x0001, 0x34);
    try c.writeByte(0x0002, 0x56);
    try c.writeByte(0x0003, 0x78);
    try std.testing.expectEqual(@as(u8, 0x12), try c.readByte(0x0000));
    try std.testing.expectEqual(@as(u8, 0x34), try c.readByte(0x0001));
    try std.testing.expectEqual(@as(u8, 0x56), try c.readByte(0x0002));
    try std.testing.expectEqual(@as(u8, 0x78), try c.readByte(0x0003));
    try std.testing.expectEqual(@as(u32, 0x78563412), c.msip);
}

test "mtimecmp round-trips byte-wise (all 8 bytes)" {
    var c = Clint.init(&zeroClock);
    try c.writeByte(0x4000, 0x01);
    try c.writeByte(0x4001, 0x23);
    try c.writeByte(0x4002, 0x45);
    try c.writeByte(0x4003, 0x67);
    try c.writeByte(0x4004, 0x89);
    try c.writeByte(0x4005, 0xAB);
    try c.writeByte(0x4006, 0xCD);
    try c.writeByte(0x4007, 0xEF);
    try std.testing.expectEqual(@as(u64, 0xEFCDAB8967452301), c.mtimecmp);
}

test "mtime returns monotonic, anchored ticks (via fixture clock)" {
    fixture_clock_ns = 0;
    var c = Clint.init(&fixtureClock);
    try std.testing.expectEqual(@as(u8, 0), try c.readByte(0xBFF8));
    // Advance fixture by 1000 ns → 10 ticks at 10 MHz nominal.
    fixture_clock_ns = 1000;
    try std.testing.expectEqual(@as(u8, 10), try c.readByte(0xBFF8));
}

test "writing mtime is silently dropped (Phase 1)" {
    fixture_clock_ns = 0;
    var c = Clint.init(&fixtureClock);
    try c.writeByte(0xBFF8, 0xFF); // should be a no-op
    fixture_clock_ns = 100; // advance by 1 tick
    try std.testing.expectEqual(@as(u8, 1), try c.readByte(0xBFF8));
}

// --- test fixtures ---

var fixture_clock_ns: i128 = 0;

fn zeroClock() i128 {
    return 0;
}

fn fixtureClock() i128 {
    return fixture_clock_ns;
}
```

- [ ] **Step 2: Wire CLINT into `memory.zig` address dispatch**

In `src/memory.zig`, add the CLINT import and a `*clint_dev.Clint` field on `Memory`:

```zig
const std = @import("std");
const halt_dev = @import("devices/halt.zig");
const uart_dev = @import("devices/uart.zig");
const clint_dev = @import("devices/clint.zig");

pub const RAM_BASE: u32 = 0x8000_0000;
pub const RAM_SIZE_DEFAULT: usize = 128 * 1024 * 1024;

pub const MemoryError = error{
    OutOfBounds,
    MisalignedAccess,
    UnexpectedRegister,
    WriteFailed,
    Halt,
};

pub const Memory = struct {
    ram: []u8,
    halt: *halt_dev.Halt,
    uart: *uart_dev.Uart,
    clint: *clint_dev.Clint,
    // Optional secondary halt address resolved from ELF's `tohost` symbol;
    // Task 11 populates this when loading ELF files. Hand-crafted/raw
    // demos pass null and use the 0x00100000 MMIO halt only.
    tohost_addr: ?u32,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        halt: *halt_dev.Halt,
        uart: *uart_dev.Uart,
        clint: *clint_dev.Clint,
        tohost_addr: ?u32,
        ram_size: usize,
    ) !Memory {
        const ram = try allocator.alloc(u8, ram_size);
        @memset(ram, 0);
        return .{
            .ram = ram,
            .halt = halt,
            .uart = uart,
            .clint = clint,
            .tohost_addr = tohost_addr,
            .allocator = allocator,
        };
    }

    // ... (deinit unchanged)
```

Update the `loadByte`/`storeByte` bodies to route CLINT accesses and tohost-halt writes. Full new `loadByte`:

```zig
    pub fn loadByte(self: *Memory, addr: u32) MemoryError!u8 {
        if (inRange(addr, uart_dev.UART_BASE, uart_dev.UART_SIZE)) {
            return self.uart.readByte(addr - uart_dev.UART_BASE) catch |e| switch (e) {
                error.UnexpectedRegister => MemoryError.UnexpectedRegister,
                error.WriteFailed => MemoryError.WriteFailed,
            };
        }
        if (inRange(addr, clint_dev.CLINT_BASE, clint_dev.CLINT_SIZE)) {
            return self.clint.readByte(addr - clint_dev.CLINT_BASE) catch |e| switch (e) {
                error.UnexpectedRegister => MemoryError.UnexpectedRegister,
            };
        }
        if (inRange(addr, halt_dev.HALT_BASE, halt_dev.HALT_SIZE)) {
            return 0;
        }
        const off = try ramOffset(addr);
        return self.ram[off];
    }
```

Full new `storeByte`:

```zig
    pub fn storeByte(self: *Memory, addr: u32, value: u8) MemoryError!void {
        if (inRange(addr, uart_dev.UART_BASE, uart_dev.UART_SIZE)) {
            self.uart.writeByte(addr - uart_dev.UART_BASE, value) catch |e| switch (e) {
                error.UnexpectedRegister => return MemoryError.UnexpectedRegister,
                error.WriteFailed => return MemoryError.WriteFailed,
            };
            return;
        }
        if (inRange(addr, clint_dev.CLINT_BASE, clint_dev.CLINT_SIZE)) {
            self.clint.writeByte(addr - clint_dev.CLINT_BASE, value) catch |e| switch (e) {
                error.UnexpectedRegister => return MemoryError.UnexpectedRegister,
            };
            return;
        }
        if (inRange(addr, halt_dev.HALT_BASE, halt_dev.HALT_SIZE)) {
            self.halt.writeByte(addr - halt_dev.HALT_BASE, value) catch |e| switch (e) {
                error.Halt => return MemoryError.Halt,
            };
            return;
        }
        // ELF-loaded tohost halt: all bytes within the 8-byte tohost quadword
        // write the byte into halt.exit_code and signal halt.
        if (self.tohost_addr) |ta| {
            if (addr >= ta and addr < ta +% 8) {
                self.halt.exit_code = value;
                return MemoryError.Halt;
            }
        }
        const off = try ramOffset(addr);
        self.ram[off] = value;
    }
```

(Rename `RAM_SIZE` to `RAM_SIZE_DEFAULT` globally in the module; `--memory <MB>` will pass a custom size in Task 12.)

Update the `TestRig` at the bottom of `memory.zig` to construct and pass a `Clint` plus the new parameters:

```zig
const TestRig = struct {
    halt: halt_dev.Halt,
    uart: uart_dev.Uart,
    clint: clint_dev.Clint,
    aw: std.Io.Writer.Allocating,
    mem: Memory,

    fn init(self: *TestRig, allocator: std.mem.Allocator) !void {
        self.halt = halt_dev.Halt.init();
        self.aw = .init(allocator);
        self.uart = uart_dev.Uart.init(&self.aw.writer);
        self.clint = clint_dev.Clint.init(&@import("devices/clint.zig").fixtureClock);
        self.mem = try Memory.init(allocator, &self.halt, &self.uart, &self.clint, null, RAM_SIZE_DEFAULT);
    }

    fn deinit(self: *TestRig) void {
        self.mem.deinit();
        self.aw.deinit();
    }
};
```

(But `fixtureClock` is a private test helper in `devices/clint.zig`. Export it: in `src/devices/clint.zig`, change `fn fixtureClock() i128 { ... }` to `pub fn fixtureClock() i128 { ... }` and `var fixture_clock_ns: i128 = 0;` to `pub var fixture_clock_ns: i128 = 0;`. Same for `zeroClock` if needed by tests. In production, `main.zig` uses `Clint.initDefault()`.)

Add a CLINT-routing test to `memory.zig`:

```zig
test "word load from CLINT mtime returns nonzero after clock advances" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    @import("devices/clint.zig").fixture_clock_ns = 0;
    rig.clint.epoch_ns = 0;
    @import("devices/clint.zig").fixture_clock_ns = 10_000; // 100 ticks
    const v = try rig.mem.loadWord(clint_dev.CLINT_BASE + 0xBFF8);
    try std.testing.expectEqual(@as(u32, 100), v);
}
```

- [ ] **Step 3: Update `Rig` in `execute.zig` and `cpu.zig` tests**

The fixtures in `execute.zig` (`Rig` struct) and `cpu.zig` (ad-hoc setup in the `Cpu.run halts cleanly when program writes to halt MMIO` test) both construct `Memory.init` directly. Update both to pass a `Clint` and the new signature:

```zig
// In execute.zig's Rig.init:
    fn init(self: *Rig, allocator: std.mem.Allocator, entry: u32) !void {
        self.halt = halt_dev.Halt.init();
        self.aw = .init(allocator);
        self.uart = uart_dev.Uart.init(&self.aw.writer);
        self.clint = clint_dev.Clint.init(&clint_dev.zeroClock);
        self.mem = try mem_mod.Memory.init(allocator, &self.halt, &self.uart, &self.clint, null, mem_mod.RAM_SIZE_DEFAULT);
        self.cpu = cpu_mod.Cpu.init(&self.mem, entry);
    }
```

Add `const clint_dev = @import("devices/clint.zig");` to execute.zig's imports, and add `clint: clint_dev.Clint,` to the `Rig` struct.

Same shape update for the `Cpu.run halts cleanly` test in cpu.zig — add a local `var clint = clint_dev.Clint.init(&clint_dev.zeroClock);` and the extra args in the `Memory.init` call.

- [ ] **Step 4: Wire `clint.zig` into the test root**

In `src/main.zig`'s `comptime` block:

```zig
    _ = @import("devices/clint.zig");
```

- [ ] **Step 5: Run the tests**

Run: `zig build test`
Expected: all tests pass, including the new CLINT tests and the memory-dispatch CLINT test.

- [ ] **Step 6: Commit**

```bash
git add src/devices/clint.zig src/memory.zig src/execute.zig src/cpu.zig src/main.zig
git commit -m "feat: CLINT device (msip, mtimecmp, mtime) + tohost halt routing in Memory"
```

---

### Task 11: ELF32 loader (`src/elf.zig`) — `parseAndLoad → {entry, tohost_addr?}`

**Files:**
- Create: `src/elf.zig`
- Create: `tests/fixtures/minimal.elf` (committed binary; ~200 bytes; a hand-crafted tiny ELF used only in tests)
- Create: `tests/fixtures/README.md` (explains the fixture)
- Modify: `src/main.zig` (add `_ = @import("elf.zig");` to the `comptime` block)

**Why this task:** The ELF loader is the default boot path for Plan 1.C. The `riscv-tests` ELFs land here; the trap-demo (Task 17) stays on `--raw`. The loader also resolves the `tohost` symbol so Task 15's test runner can halt on pass/fail writes.

- [ ] **Step 1: Create `src/elf.zig`**

```zig
const std = @import("std");
const Memory = @import("memory.zig").Memory;

pub const ElfError = error{
    FileTooSmall,
    BadMagic,
    NotElf32,
    NotLittleEndian,
    NotRiscV,
    NotExecutable,
    SegmentOutOfRange,
    InvalidSectionTable,
};

pub const LoadResult = struct {
    entry: u32,
    tohost_addr: ?u32,
};

const EI_CLASS = 4;
const EI_DATA = 5;
const ELFCLASS32: u8 = 1;
const ELFDATA2LSB: u8 = 1;
const EM_RISCV: u16 = 0xF3;
const ET_EXEC: u16 = 2;
const PT_LOAD: u32 = 1;
const SHT_SYMTAB: u32 = 2;
const SHT_STRTAB: u32 = 3;

/// Parse the given ELF32 RISC-V EXEC image and copy its PT_LOAD segments
/// into `memory`. Returns the entry point and the resolved `tohost`
/// address (null if the file has no symbol table or no `tohost` symbol).
///
/// The caller owns `data`; this function only reads from it.
pub fn parseAndLoad(data: []const u8, memory: *Memory) ElfError!LoadResult {
    if (data.len < 52) return ElfError.FileTooSmall;

    // ELF magic: 0x7F 'E' 'L' 'F'
    if (!std.mem.eql(u8, data[0..4], "\x7FELF")) return ElfError.BadMagic;
    if (data[EI_CLASS] != ELFCLASS32) return ElfError.NotElf32;
    if (data[EI_DATA] != ELFDATA2LSB) return ElfError.NotLittleEndian;

    const e_type = std.mem.readInt(u16, data[16..18], .little);
    if (e_type != ET_EXEC) return ElfError.NotExecutable;
    const e_machine = std.mem.readInt(u16, data[18..20], .little);
    if (e_machine != EM_RISCV) return ElfError.NotRiscV;

    const e_entry = std.mem.readInt(u32, data[24..28], .little);
    const e_phoff = std.mem.readInt(u32, data[28..32], .little);
    const e_shoff = std.mem.readInt(u32, data[32..36], .little);
    const e_phentsize = std.mem.readInt(u16, data[42..44], .little);
    const e_phnum = std.mem.readInt(u16, data[44..46], .little);
    const e_shentsize = std.mem.readInt(u16, data[46..48], .little);
    const e_shnum = std.mem.readInt(u16, data[48..50], .little);
    const e_shstrndx = std.mem.readInt(u16, data[50..52], .little);
    _ = e_shstrndx;

    // --- Copy PT_LOAD segments ---
    var ph_i: usize = 0;
    while (ph_i < e_phnum) : (ph_i += 1) {
        const off = e_phoff + ph_i * e_phentsize;
        if (off + 32 > data.len) return ElfError.SegmentOutOfRange;
        const p_type = std.mem.readInt(u32, data[off..][0..4], .little);
        if (p_type != PT_LOAD) continue;

        const p_offset = std.mem.readInt(u32, data[off + 4 ..][0..4], .little);
        const p_paddr = std.mem.readInt(u32, data[off + 12 ..][0..4], .little);
        const p_filesz = std.mem.readInt(u32, data[off + 16 ..][0..4], .little);
        const p_memsz = std.mem.readInt(u32, data[off + 20 ..][0..4], .little);

        if (p_offset + p_filesz > data.len) return ElfError.SegmentOutOfRange;

        // Copy [p_offset, p_offset + p_filesz) → memory at p_paddr.
        var j: u32 = 0;
        while (j < p_filesz) : (j += 1) {
            memory.storeByte(p_paddr + j, data[p_offset + j]) catch |e| switch (e) {
                error.Halt => return ElfError.SegmentOutOfRange, // shouldn't happen during load
                else => return ElfError.SegmentOutOfRange,
            };
        }
        // Zero [p_paddr + p_filesz, p_paddr + p_memsz) — BSS.
        while (j < p_memsz) : (j += 1) {
            memory.storeByte(p_paddr + j, 0) catch return ElfError.SegmentOutOfRange;
        }
    }

    // --- Find tohost via symbol table ---
    var tohost_addr: ?u32 = null;
    if (e_shnum > 0 and e_shoff != 0) {
        // Find .symtab and its linked .strtab.
        var symtab_off: u32 = 0;
        var symtab_size: u32 = 0;
        var symtab_link: u32 = 0;
        var sh_i: usize = 0;
        while (sh_i < e_shnum) : (sh_i += 1) {
            const shoff = e_shoff + sh_i * e_shentsize;
            if (shoff + 40 > data.len) return ElfError.InvalidSectionTable;
            const sh_type = std.mem.readInt(u32, data[shoff + 4 ..][0..4], .little);
            if (sh_type != SHT_SYMTAB) continue;
            symtab_off = std.mem.readInt(u32, data[shoff + 16 ..][0..4], .little);
            symtab_size = std.mem.readInt(u32, data[shoff + 20 ..][0..4], .little);
            symtab_link = std.mem.readInt(u32, data[shoff + 24 ..][0..4], .little);
            break;
        }
        if (symtab_size > 0) {
            // Get the linked .strtab.
            const strtab_shoff = e_shoff + symtab_link * e_shentsize;
            if (strtab_shoff + 40 > data.len) return ElfError.InvalidSectionTable;
            const strtab_off = std.mem.readInt(u32, data[strtab_shoff + 16 ..][0..4], .little);
            const strtab_size = std.mem.readInt(u32, data[strtab_shoff + 20 ..][0..4], .little);
            if (strtab_off + strtab_size > data.len) return ElfError.InvalidSectionTable;

            // Iterate Elf32_Sym entries (16 bytes each).
            const SYMSIZE: u32 = 16;
            var sym_i: u32 = 0;
            while (sym_i < symtab_size) : (sym_i += SYMSIZE) {
                const e_off = symtab_off + sym_i;
                if (e_off + SYMSIZE > data.len) break;
                const st_name = std.mem.readInt(u32, data[e_off..][0..4], .little);
                const st_value = std.mem.readInt(u32, data[e_off + 4 ..][0..4], .little);
                // Look up name in strtab.
                const name_start = strtab_off + st_name;
                if (name_start >= data.len) continue;
                var end = name_start;
                while (end < data.len and data[end] != 0) : (end += 1) {}
                const name = data[name_start..end];
                if (std.mem.eql(u8, name, "tohost")) {
                    tohost_addr = st_value;
                    break;
                }
            }
        }
    }

    return .{ .entry = e_entry, .tohost_addr = tohost_addr };
}

test "reject files smaller than an ELF header" {
    var halt = @import("devices/halt.zig").Halt.init();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var uart = @import("devices/uart.zig").Uart.init(&aw.writer);
    var clint = @import("devices/clint.zig").Clint.init(&@import("devices/clint.zig").zeroClock);
    var mem = try Memory.init(std.testing.allocator, &halt, &uart, &clint, null, 1024);
    defer mem.deinit();
    try std.testing.expectError(ElfError.FileTooSmall, parseAndLoad(&[_]u8{0}, &mem));
}

test "reject wrong magic" {
    var halt = @import("devices/halt.zig").Halt.init();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var uart = @import("devices/uart.zig").Uart.init(&aw.writer);
    var clint = @import("devices/clint.zig").Clint.init(&@import("devices/clint.zig").zeroClock);
    var mem = try Memory.init(std.testing.allocator, &halt, &uart, &clint, null, 1024);
    defer mem.deinit();
    var bogus = [_]u8{0} ** 64;
    bogus[0] = 'Z'; bogus[1] = 'O'; bogus[2] = 'M'; bogus[3] = 'G';
    try std.testing.expectError(ElfError.BadMagic, parseAndLoad(&bogus, &mem));
}

test "load minimal.elf fixture, extract entry and tohost" {
    const fixture = @embedFile("../tests/fixtures/minimal.elf");
    var halt = @import("devices/halt.zig").Halt.init();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var uart = @import("devices/uart.zig").Uart.init(&aw.writer);
    var clint = @import("devices/clint.zig").Clint.init(&@import("devices/clint.zig").zeroClock);
    const mem_mod = @import("memory.zig");
    var mem = try Memory.init(std.testing.allocator, &halt, &uart, &clint, null, mem_mod.RAM_SIZE_DEFAULT);
    defer mem.deinit();
    const result = try parseAndLoad(fixture, &mem);
    try std.testing.expectEqual(mem_mod.RAM_BASE, result.entry);
    try std.testing.expect(result.tohost_addr != null);
    try std.testing.expectEqual(@as(u32, 0x8000_1000), result.tohost_addr.?);
    // First four bytes of RAM should match what we encoded in the fixture.
    try std.testing.expectEqual(@as(u8, 0x73), try mem.loadByte(mem_mod.RAM_BASE)); // ECALL low byte
}
```

- [ ] **Step 2: Generate the fixture ELF**

The fixture is a ~200-byte ELF32 RISC-V EXEC file with:

- `e_entry = 0x80000000`
- One `PT_LOAD` segment: `.text` with a single `ECALL` instruction (`0x00000073`)
- A `tohost` symbol pointing at `0x80001000`
- A `.symtab` and `.strtab` sufficient for Task 11's loader to find `tohost`

We generate it via a one-off Zig program rather than checking in a pre-built binary (matches the `encode_*.zig` pattern used by Plans 1.A/1.B demos). Create `tests/fixtures/encode_minimal_elf.zig`:

```zig
const std = @import("std");

// Layout:
//   [0:52]    ELF header
//   [52:84]   Program header (one PT_LOAD)
//   [84:88]   Text segment (ECALL)
//   [88:128]  .symtab (2 entries × 16 bytes + null)   -> actually 3 entries
//   [128:140] .strtab ("", "tohost")
//   [140:180] Section headers (null, .text, .symtab, .strtab)
//
// This is hand-assembled byte-by-byte and only aims to satisfy parseAndLoad's
// happy path + symbol lookup. Any production ELF is obviously far richer.
pub fn main() !void {
    var args_iter = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args_iter.deinit();
    _ = args_iter.next();
    const out_path = args_iter.next() orelse return error.MissingArg;

    var buf: [512]u8 = undefined;
    @memset(&buf, 0);

    // ELF header
    buf[0..4].* = "\x7FELF".*;
    buf[4] = 1; // ELFCLASS32
    buf[5] = 1; // ELFDATA2LSB
    buf[6] = 1; // EI_VERSION
    // e_type = ET_EXEC (2)
    std.mem.writeInt(u16, buf[16..18], 2, .little);
    // e_machine = EM_RISCV (0xF3)
    std.mem.writeInt(u16, buf[18..20], 0xF3, .little);
    // e_version
    std.mem.writeInt(u32, buf[20..24], 1, .little);
    // e_entry
    std.mem.writeInt(u32, buf[24..28], 0x8000_0000, .little);
    // e_phoff = 52
    std.mem.writeInt(u32, buf[28..32], 52, .little);
    // e_shoff = 140
    std.mem.writeInt(u32, buf[32..36], 140, .little);
    // e_ehsize = 52
    std.mem.writeInt(u16, buf[40..42], 52, .little);
    // e_phentsize = 32
    std.mem.writeInt(u16, buf[42..44], 32, .little);
    // e_phnum = 1
    std.mem.writeInt(u16, buf[44..46], 1, .little);
    // e_shentsize = 40
    std.mem.writeInt(u16, buf[46..48], 40, .little);
    // e_shnum = 4
    std.mem.writeInt(u16, buf[48..50], 4, .little);
    // e_shstrndx = 0 (we don't populate section name strings for this fixture)
    std.mem.writeInt(u16, buf[50..52], 0, .little);

    // Program header at offset 52
    const ph = buf[52..84];
    std.mem.writeInt(u32, ph[0..4], 1, .little); // p_type = PT_LOAD
    std.mem.writeInt(u32, ph[4..8], 84, .little); // p_offset = 84
    std.mem.writeInt(u32, ph[8..12], 0x8000_0000, .little); // p_vaddr
    std.mem.writeInt(u32, ph[12..16], 0x8000_0000, .little); // p_paddr
    std.mem.writeInt(u32, ph[16..20], 4, .little); // p_filesz
    std.mem.writeInt(u32, ph[20..24], 4, .little); // p_memsz
    std.mem.writeInt(u32, ph[24..28], 5, .little); // p_flags = R|X
    std.mem.writeInt(u32, ph[28..32], 4, .little); // p_align

    // Text at offset 84: ECALL = 0x00000073
    std.mem.writeInt(u32, buf[84..88], 0x00000073, .little);

    // .symtab at offset 88: 2 entries (null + tohost), 16 bytes each = 32 bytes
    // Sym layout: st_name (u32), st_value (u32), st_size (u32), st_info (u8), st_other (u8), st_shndx (u16)
    // Entry 0: null
    // Entry 1: tohost
    const sym1 = buf[88 + 16 .. 88 + 32];
    std.mem.writeInt(u32, sym1[0..4], 1, .little); // st_name offset into .strtab
    std.mem.writeInt(u32, sym1[4..8], 0x8000_1000, .little); // st_value
    std.mem.writeInt(u32, sym1[8..12], 8, .little); // st_size (8 bytes, MMIO doorbell)
    sym1[12] = 0x11; // st_info = GLOBAL OBJECT
    sym1[13] = 0;
    std.mem.writeInt(u16, sym1[14..16], 1, .little); // st_shndx (link to .text, cosmetic)

    // .strtab at offset 120: "\0tohost\0"
    buf[120] = 0;
    buf[121] = 't'; buf[122] = 'o'; buf[123] = 'h';
    buf[124] = 'o'; buf[125] = 's'; buf[126] = 't'; buf[127] = 0;

    // Section headers at offset 140. 4 entries × 40 bytes = 160 bytes. Total file = 300 bytes.
    // Entry 0: null (all zero — already done via @memset)
    // Entry 1: .text
    const sh1 = buf[140 + 40 .. 140 + 80];
    std.mem.writeInt(u32, sh1[4..8], 1, .little); // sh_type = SHT_PROGBITS
    std.mem.writeInt(u32, sh1[12..16], 0x8000_0000, .little); // sh_addr
    std.mem.writeInt(u32, sh1[16..20], 84, .little); // sh_offset
    std.mem.writeInt(u32, sh1[20..24], 4, .little); // sh_size

    // Entry 2: .symtab (sh_type=SHT_SYMTAB=2, sh_link → entry 3)
    const sh2 = buf[140 + 80 .. 140 + 120];
    std.mem.writeInt(u32, sh2[4..8], 2, .little); // SHT_SYMTAB
    std.mem.writeInt(u32, sh2[16..20], 88, .little); // sh_offset
    std.mem.writeInt(u32, sh2[20..24], 32, .little); // sh_size
    std.mem.writeInt(u32, sh2[24..28], 3, .little); // sh_link → .strtab
    std.mem.writeInt(u32, sh2[36..40], 16, .little); // sh_entsize

    // Entry 3: .strtab (sh_type=SHT_STRTAB=3)
    const sh3 = buf[140 + 120 .. 140 + 160];
    std.mem.writeInt(u32, sh3[4..8], 3, .little); // SHT_STRTAB
    std.mem.writeInt(u32, sh3[16..20], 120, .little); // sh_offset
    std.mem.writeInt(u32, sh3[20..24], 8, .little); // sh_size

    const total: usize = 300;
    const file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();
    try file.writeAll(buf[0..total]);
}
```

Then add a wiring line to `build.zig` (near the encode_* blocks) so `zig build fixture` builds and installs it:

```zig
    // === Fixture ELF for elf.zig tests ===
    const min_elf_encoder = b.addExecutable(.{
        .name = "encode_minimal_elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures/encode_minimal_elf.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const min_elf_run = b.addRunArtifact(min_elf_encoder);
    const min_elf_bin = min_elf_run.addOutputFileArg("minimal.elf");
    const install_min_elf = b.addInstallFile(min_elf_bin, "../tests/fixtures/minimal.elf");
    const fixture_step = b.step("fixtures", "Build test-only fixture ELF");
    fixture_step.dependOn(&install_min_elf.step);
```

Run `zig build fixtures` to produce `tests/fixtures/minimal.elf` (committed). Subsequent edits to the fixture encoder require a re-run.

Create `tests/fixtures/README.md`:

```markdown
# Test fixtures

`minimal.elf` — a ~300-byte ELF32 RISC-V EXEC file used exclusively by
`src/elf.zig`'s inline tests. Generated by `tests/fixtures/encode_minimal_elf.zig`
(run via `zig build fixtures`). Checked in as a binary so tests don't
depend on the host Zig having a working ELF toolchain.

Update procedure:
1. Edit `encode_minimal_elf.zig`.
2. Run `zig build fixtures`.
3. Verify `zig build test` still passes.
4. Commit both the encoder change and the new `minimal.elf`.
```

- [ ] **Step 3: Wire `elf.zig` into the test root**

Add to `src/main.zig`'s `comptime` block:

```zig
    _ = @import("elf.zig");
```

- [ ] **Step 4: Run the tests**

First, build the fixture: `zig build fixtures`.
Then: `zig build test`
Expected: all tests pass, including the three `elf.zig` tests.

- [ ] **Step 5: Commit**

```bash
git add src/elf.zig tests/fixtures/encode_minimal_elf.zig tests/fixtures/minimal.elf tests/fixtures/README.md build.zig src/main.zig
git commit -m "feat: ELF32 loader with PT_LOAD copying and tohost symbol resolution"
```

---

### Task 12: `main.zig` CLI wiring — ELF default, `--raw` fallback, `--trace`, `--halt-on-trap`, `--memory`

**Files:**
- Modify: `src/main.zig`

**Why this task:** Plan 1.A's CLI took `--raw <hex-addr> <file>` and required the `--raw` flag. Plan 1.C flips that: ELF is the default, `--raw <hex-addr>` is opt-in for hand-crafted binaries. New flags `--trace`, `--halt-on-trap`, `--memory <MB>` join the set. Help text matches spec §CLI verbatim.

- [ ] **Step 1: Rewrite `Args` + `parseArgs` + `printUsage`**

Full updated section of `src/main.zig` (the top half, up through `printUsage`):

```zig
const std = @import("std");
const Io = std.Io;
const cpu_mod = @import("cpu.zig");
const mem_mod = @import("memory.zig");
const halt_dev = @import("devices/halt.zig");
const uart_dev = @import("devices/uart.zig");
const clint_dev = @import("devices/clint.zig");
const elf_mod = @import("elf.zig");

comptime {
    _ = @import("cpu.zig");
    _ = @import("memory.zig");
    _ = @import("devices/halt.zig");
    _ = @import("devices/uart.zig");
    _ = @import("devices/clint.zig");
    _ = @import("decoder.zig");
    _ = @import("execute.zig");
    _ = @import("csr.zig");
    _ = @import("trap.zig");
    _ = @import("elf.zig");
    _ = @import("trace.zig"); // landed in Task 13
}

const Args = struct {
    raw_addr: ?u32 = null,
    file: ?[]const u8 = null,
    trace: bool = false,
    halt_on_trap: bool = false,
    memory_mb: u32 = 128,
};

const ArgsError = error{
    MissingArg,
    UnknownOption,
    TooManyPositional,
    MissingFile,
    InvalidAddress,
    InvalidMemory,
};

fn parseArgs(argv: []const [:0]const u8, stderr: *Io.Writer) ArgsError!Args {
    var args: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--raw")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            args.raw_addr = std.fmt.parseInt(u32, argv[i], 0) catch return error.InvalidAddress;
        } else if (std.mem.eql(u8, a, "--trace")) {
            args.trace = true;
        } else if (std.mem.eql(u8, a, "--halt-on-trap")) {
            args.halt_on_trap = true;
        } else if (std.mem.eql(u8, a, "--memory")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            const mb = std.fmt.parseInt(u32, argv[i], 0) catch return error.InvalidMemory;
            if (mb == 0 or mb > 4096) return error.InvalidMemory;
            args.memory_mb = mb;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            printUsage(stderr) catch {};
            std.process.exit(0);
        } else if (a.len > 0 and a[0] == '-') {
            stderr.print("unknown option: {s}\n", .{a}) catch {};
            stderr.flush() catch {};
            return error.UnknownOption;
        } else {
            if (args.file != null) return error.TooManyPositional;
            args.file = a;
        }
    }
    if (args.file == null) return error.MissingFile;
    return args;
}

fn printUsage(stderr: *Io.Writer) !void {
    try stderr.print(
        \\usage: ccc [options] <program>
        \\
        \\Run a RISC-V program in the emulator.
        \\
        \\Arguments:
        \\  <program>           Path to ELF file (default) or raw binary (with --raw).
        \\
        \\Options:
        \\  --raw <addr>        Treat <program> as a raw binary loaded at <addr> (hex).
        \\  --trace             Print one line per executed instruction to stderr.
        \\  --memory <MB>       Override RAM size (default: 128).
        \\  --halt-on-trap      Stop on first unhandled trap (default: enter trap handler).
        \\  -h, --help          Show this help.
        \\
    , .{});
    try stderr.flush();
}
```

- [ ] **Step 2: Rewrite `main` body around the new boot split**

Full updated body:

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var stderr_buffer: [256]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const argv = init.minimal.args.toSlice(a) catch |err| {
        stderr.print("failed to read argv: {s}\n", .{@errorName(err)}) catch {};
        stderr.flush() catch {};
        std.process.exit(2);
    };

    const args = parseArgs(argv, stderr) catch {
        printUsage(stderr) catch {};
        std.process.exit(2);
    };

    // Load program bytes (16 MiB cap).
    const file_data = Io.Dir.cwd().readFileAlloc(io, args.file.?, a, .limited(16 * 1024 * 1024)) catch |err| {
        stderr.print("failed to read {s}: {s}\n", .{ args.file.?, @errorName(err) }) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };

    // stdout writer for UART output.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var halt = halt_dev.Halt.init();
    var uart = uart_dev.Uart.init(stdout);
    var clint = clint_dev.Clint.initDefault();

    const ram_size: usize = @as(usize, args.memory_mb) * 1024 * 1024;

    // Default boot: ELF. Fallback: --raw <addr>.
    var entry: u32 = 0;
    var tohost_addr: ?u32 = null;
    if (args.raw_addr) |_| {
        // --raw path: tohost_addr stays null; halt only via 0x00100000.
    } else {
        // We need to probe the ELF file *before* constructing Memory, because
        // Memory.init takes tohost_addr. So we parse ELF header just enough
        // to find tohost here, then re-parse in parseAndLoad to copy segments.
        // Simpler approach: construct Memory with tohost_addr=null, call
        // parseAndLoad, then post-hoc set mem.tohost_addr.
    }

    var mem = try mem_mod.Memory.init(a, &halt, &uart, &clint, tohost_addr, ram_size);
    defer mem.deinit();

    if (args.raw_addr) |addr| {
        for (file_data, 0..) |b, idx| {
            mem.storeByte(addr + @as(u32, @intCast(idx)), b) catch |err| {
                stdout.flush() catch {};
                stderr.print("failed to load byte {d} at 0x{X:0>8}: {s}\n", .{ idx, addr + @as(u32, @intCast(idx)), @errorName(err) }) catch {};
                stderr.flush() catch {};
                std.process.exit(1);
            };
        }
        entry = addr;
    } else {
        const result = elf_mod.parseAndLoad(file_data, &mem) catch |err| {
            stderr.print("ELF load failed: {s}\n", .{@errorName(err)}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        };
        entry = result.entry;
        mem.tohost_addr = result.tohost_addr;
    }

    var cpu = cpu_mod.Cpu.init(&mem, entry);
    cpu.halt_on_trap = args.halt_on_trap;

    // --trace setup is wired in Task 13.
    _ = args.trace;

    cpu.run() catch |err| {
        stdout.flush() catch {};
        stderr.print("\nemulator stopped: {s} (PC=0x{X:0>8})\n", .{ @errorName(err), cpu.pc }) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };
    stdout.flush() catch {};
    std.process.exit(halt.exit_code orelse 0);
}
```

Note: `cpu.halt_on_trap` is a new field landing in this task on `Cpu`. Add it:

In `src/cpu.zig`, extend `Cpu`:

```zig
pub const Cpu = struct {
    regs: [32]u32,
    pc: u32,
    memory: *Memory,
    reservation: ?u32,
    privilege: PrivilegeMode,
    csr: CsrFile,
    halt_on_trap: bool = false,
    // trace_writer lands in Task 13
    ...
    pub fn init(memory: *Memory, entry: u32) Cpu {
        return .{
            .regs = [_]u32{0} ** 32,
            .pc = entry,
            .memory = memory,
            .reservation = null,
            .privilege = .M,
            .csr = .{},
            .halt_on_trap = false,
        };
    }
```

- [ ] **Step 3: Update the existing `e2e` and `e2e-mul` build rules to pass `--raw`**

In `build.zig`, the existing `e2e_run.addArgs(&.{ "--raw", "0x80000000" })` call still works since `--raw` is still the flag name. No change needed.

- [ ] **Step 4: Run the tests and the two existing e2e demos**

Run: `zig build test` — all tests pass.
Run: `zig build e2e` — still prints "hello world\n".
Run: `zig build e2e-mul` — still prints "42\n".

- [ ] **Step 5: Commit**

```bash
git add src/main.zig src/cpu.zig
git commit -m "feat: ELF default boot; --raw fallback; --trace/--halt-on-trap/--memory flags"
```

---

### Task 13: `--trace` + `src/trace.zig`

**Files:**
- Create: `src/trace.zig`
- Modify: `src/cpu.zig` (add `trace_writer: ?*std.Io.Writer` field + call formatInstr in `step`)
- Modify: `src/main.zig` (wire `--trace` to stderr)

**Why this task:** A per-instruction trace is the single most useful tool for debugging `riscv-tests` failures. We keep the format simple — PC, raw instruction, op name, and the register indices that changed — rather than fully disassembling. Full disassembly can come later; for Phase 1 this is enough to tell an ecall apart from an illegal, or to see `mret` resuming at the right address.

- [ ] **Step 1: Create `src/trace.zig`**

```zig
const std = @import("std");
const decoder = @import("decoder.zig");

/// Format one line of instruction trace to `writer`. The format is
/// intentionally terse:
///
///   PC=0x80000004 RAW=0x00000013  addi x0, x0, 0  [rd=x0 <- 0]
///
/// The square-bracket suffix lists (a) the write to rd if any, and
/// (b) the PC change if it's not just +4 (i.e., a branch/jump).
pub fn formatInstr(
    writer: *std.Io.Writer,
    pre_pc: u32,
    instr: decoder.Instruction,
    pre_rd: u32,
    post_rd: u32,
    post_pc: u32,
) !void {
    try writer.print("PC=0x{X:0>8} RAW=0x{X:0>8}  {s}", .{ pre_pc, instr.raw, @tagName(instr.op) });
    if (instr.rd != 0 and pre_rd != post_rd) {
        try writer.print("  [x{d} := 0x{X:0>8}]", .{ instr.rd, post_rd });
    }
    const expected_next = pre_pc +% 4;
    if (post_pc != expected_next) {
        try writer.print("  [pc -> 0x{X:0>8}]", .{post_pc});
    }
    try writer.print("\n", .{});
    try writer.flush();
}

test "format an addi with rd write" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const i: decoder.Instruction = .{ .op = .addi, .rd = 5, .rs1 = 0, .imm = 7, .raw = 0x00700293 };
    try formatInstr(&aw.writer, 0x80000000, i, 0, 7, 0x80000004);
    try std.testing.expectEqualStrings(
        "PC=0x80000000 RAW=0x00700293  addi  [x5 := 0x00000007]\n",
        aw.written(),
    );
}

test "format a jal shows pc redirect" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const i: decoder.Instruction = .{ .op = .jal, .rd = 1, .imm = 16, .raw = 0x010000EF };
    try formatInstr(&aw.writer, 0x80000000, i, 0, 0x80000004, 0x80000010);
    try std.testing.expectEqualStrings(
        "PC=0x80000000 RAW=0x010000EF  jal  [x1 := 0x80000004]  [pc -> 0x80000010]\n",
        aw.written(),
    );
}

test "format an illegal has no rd write and no pc change (pre-trap)" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const i: decoder.Instruction = .{ .op = .illegal, .raw = 0xDEADBEEF };
    try formatInstr(&aw.writer, 0x80000100, i, 0, 0, 0x80000104);
    try std.testing.expectEqualStrings(
        "PC=0x80000100 RAW=0xDEADBEEF  illegal\n",
        aw.written(),
    );
}
```

- [ ] **Step 2: Add `trace_writer` field to `Cpu` and hook into `step`**

In `src/cpu.zig`, extend `Cpu`:

```zig
pub const Cpu = struct {
    regs: [32]u32,
    pc: u32,
    memory: *Memory,
    reservation: ?u32,
    privilege: PrivilegeMode,
    csr: CsrFile,
    halt_on_trap: bool = false,
    trace_writer: ?*std.Io.Writer = null,
    ...
```

Update `Cpu.init` to default `trace_writer = null`.

Replace `step` to capture pre/post state around `dispatch`:

```zig
    pub fn step(self: *Cpu) StepError!void {
        const pre_pc = self.pc;
        const word = self.memory.loadWord(pre_pc) catch |e| switch (e) {
            error.Halt => return StepError.Halt,
            error.MisalignedAccess => {
                trap.enter(.instr_addr_misaligned, pre_pc, self);
                return;
            },
            else => {
                trap.enter(.instr_access_fault, pre_pc, self);
                return;
            },
        };
        const instr = decoder.decode(word);
        const pre_rd = self.regs[instr.rd];
        try execute.dispatch(instr, self) catch |e| switch (e) {
            error.Halt => return StepError.Halt,
            error.FatalTrap => return StepError.FatalTrap,
        };
        if (self.trace_writer) |tw| {
            const post_rd = self.regs[instr.rd];
            @import("trace.zig").formatInstr(tw, pre_pc, instr, pre_rd, post_rd, self.pc) catch {};
        }
    }
```

- [ ] **Step 3: Wire `--trace` in `main.zig`**

Replace the placeholder `_ = args.trace;` in `main.zig` with:

```zig
    if (args.trace) {
        cpu.trace_writer = stderr;
    }
```

(`stderr` is already the `Io.File.Writer.interface` established at the top of `main`.)

- [ ] **Step 4: Verify trace works on the hello demo**

Run: `zig build run -- --raw 0x80000000 --trace zig-out/hello.bin 2>&1 >/dev/null | head -5`
Expected: five lines on stderr, format matches the examples above. (`2>&1 >/dev/null` swaps stdout and stderr so we only see the trace output, not the UART hello-world text.)

- [ ] **Step 5: Run all tests**

Run: `zig build test`
Expected: all tests pass, including three trace tests.

- [ ] **Step 6: Commit**

```bash
git add src/trace.zig src/cpu.zig src/main.zig
git commit -m "feat: --trace flag + src/trace.zig one-line-per-instruction output"
```

---

### Task 14: `riscv-tests` submodule + linker script + build glue

**Files:**
- Create: `.gitmodules`
- Create: `tests/riscv-tests/` (submodule checkout of `riscv-software-src/riscv-tests`)
- Create: `tests/riscv-tests-p.ld`
- Modify: `build.zig`

**Why this task:** We submodule the upstream `riscv-tests` repo to vendor the `.S` sources. Then we write a minimal linker script that mirrors upstream's `env/p/link.ld` (the "physical, M-mode-only" environment), and a `build.zig` helper that: (1) creates an `addObject` step per test `.S` with RISC-V freestanding target + include paths pointing at the submodule's `env/p` and `isa/macros/scalar` headers, (2) links the resulting object against our linker script into an ELF. Running the ELF is Task 15.

- [ ] **Step 1: Add the submodule**

```bash
git submodule add https://github.com/riscv-software-src/riscv-tests.git tests/riscv-tests
git submodule update --init --recursive
```

Confirm `.gitmodules` exists with the expected content:

```ini
[submodule "tests/riscv-tests"]
	path = tests/riscv-tests
	url = https://github.com/riscv-software-src/riscv-tests.git
```

Verify the path `tests/riscv-tests/isa/rv32ui/add.S` exists and is a real file (not an empty directory).

- [ ] **Step 2: Create `tests/riscv-tests-p.ld`**

```ld
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  .tohost ALIGN(0x1000) : { *(.tohost) }
  .text : { *(.text) }
  .data ALIGN(0x1000) : { *(.data) }
  .bss ALIGN(0x1000) : { *(.bss) }
  _end = .;
}
```

This mirrors the upstream `env/p/link.ld` closely. The key invariants:
- Entry symbol is `_start` (defined in `env/p/riscv_test.h`-included prologue).
- Load address is `0x80000000` (matches our RAM base).
- `.tohost` is page-aligned and contains a `tohost` symbol at its start. The upstream `env/encoding.h` + `env/p/riscv_test.h` export `tohost:` as the first item in `.tohost`; our `elf.zig` picks it up by symbol-name lookup.

- [ ] **Step 3: Add `riscvTest` helper to `build.zig`**

At the bottom of `build.zig` (below the existing `e2e-mul` wiring), add:

```zig
    // === riscv-tests helpers (Plan 1.C Task 14-16) ===
    // Target: RV32IMA freestanding (no Zicsr bit here — the isa string
    // is M + A; Zicsr instructions are always present in RV32 and don't
    // get their own flag in llvm tooling). Zifencei (Zifencei_i) likewise.
    const rv_target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv32,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = blk: {
            const features = std.Target.riscv.Feature;
            var set = std.Target.Cpu.Feature.Set.empty;
            set.addFeature(@intFromEnum(features.m));
            set.addFeature(@intFromEnum(features.a));
            break :blk set;
        },
    });

    const RiscvTest = struct {
        family: []const u8, // "rv32ui", "rv32um", "rv32ua", "rv32mi"
        name: []const u8, // e.g. "add", "csr", "ma_fetch"
    };

    const rv_link_script = b.path("tests/riscv-tests-p.ld");

    const riscvTestStep = struct {
        fn call(
            bb: *std.Build,
            rtarget: std.Build.ResolvedTarget,
            link_script: std.Build.LazyPath,
            test_def: RiscvTest,
        ) std.Build.LazyPath {
            const src_path = bb.fmt("tests/riscv-tests/isa/{s}/{s}.S", .{ test_def.family, test_def.name });
            const obj = bb.addObject(.{
                .name = bb.fmt("{s}-{s}", .{ test_def.family, test_def.name }),
                .root_module = bb.createModule(.{
                    .root_source_file = null,
                    .target = rtarget,
                    .optimize = .ReleaseSmall,
                }),
            });
            obj.root_module.addAssemblyFile(bb.path(src_path));
            obj.root_module.addIncludePath(bb.path("tests/riscv-tests/env/p"));
            obj.root_module.addIncludePath(bb.path("tests/riscv-tests/env"));
            obj.root_module.addIncludePath(bb.path("tests/riscv-tests/isa/macros/scalar"));

            const exe_tst = bb.addExecutable(.{
                .name = bb.fmt("{s}-{s}-elf", .{ test_def.family, test_def.name }),
                .root_module = bb.createModule(.{
                    .root_source_file = null,
                    .target = rtarget,
                    .optimize = .ReleaseSmall,
                }),
            });
            exe_tst.root_module.addObject(obj);
            exe_tst.setLinkerScript(link_script);
            // Avoid any libc linking; no standard startup either.
            exe_tst.root_module.single_threaded = true;

            const installed = bb.addInstallArtifact(exe_tst, .{
                .dest_dir = .{ .override = .{ .custom = bb.fmt("riscv-tests/{s}", .{test_def.family}) } },
            });
            _ = installed;
            return exe_tst.getEmittedBin();
        }
    }.call;
    _ = riscvTestStep; // referenced in Task 15
```

- [ ] **Step 4: Smoke-test by building exactly one ELF**

As a proof-of-life for the toolchain, add a temporary single-test step before moving on:

```zig
    // Temporary: build one test to verify the toolchain works.
    const smoke_test = riscvTestStep(b, rv_target, rv_link_script, .{
        .family = "rv32ui",
        .name = "add",
    });
    _ = smoke_test;
```

Run: `zig build`
Expected: succeeds, produces `zig-out/riscv-tests/rv32ui/rv32ui-add-elf`. If Zig's assembler rejects upstream macros, the diagnostic will point to the first offending line — fix by adding include paths, or by filing the test in Task 16's "skip" list and moving on.

- [ ] **Step 5: Commit**

```bash
git add .gitmodules tests/riscv-tests tests/riscv-tests-p.ld build.zig
git commit -m "chore: submodule riscv-tests; add linker script + build.zig helper"
```

---

### Task 15: `zig build riscv-tests` runner step

**Files:**
- Modify: `build.zig`

**Why this task:** Each test ELF, when run through `ccc`, should exit with status 0 if the test passed (the upstream `riscv_test.h` writes `1` to `tohost` on pass, which — via the ELF loader resolving `tohost` and `Memory` routing writes to halt — exits the emulator with `exit_code = 0`). A non-zero exit from `ccc` means the test failed. We wire this into a single `zig build riscv-tests` step that runs each test and expects exit 0.

- [ ] **Step 1: Define the test list**

In `build.zig`, add a list constant near the `riscv-tests` helpers:

```zig
    const rv32ui_tests = [_][]const u8{
        "add",   "addi",  "and",    "andi",  "auipc", "beq",    "bge",   "bgeu",
        "blt",   "bltu",  "bne",    "fence_i","jal",  "jalr",   "lb",    "lbu",
        "lh",    "lhu",   "lui",    "lw",    "or_",   "ori",    "sb",    "sh",
        "simple", "sll",  "slli",   "slt",   "slti",  "sltiu",  "sltu",  "sra",
        "srai",  "srl",   "srli",   "sub",   "sw",    "xor_",   "xori",
    };

    const rv32um_tests = [_][]const u8{
        "mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu",
    };

    const rv32ua_tests = [_][]const u8{
        "amoadd_w",   "amoand_w", "amomax_w",  "amomaxu_w", "amomin_w", "amominu_w",
        "amoor_w",    "amoswap_w","amoxor_w",  "lrsc",
    };

    const rv32mi_tests = [_][]const u8{
        "csr",     "illegal", "ma_addr", "ma_fetch", "mcsr",  "sbreak", "scall",
        "shamt",
    };
```

(`or_`, `xor_`, and `and_` may not exactly match upstream file names — they're typically `or.S`, `xor.S`, `and.S` in the `riscv-tests/isa/rv32ui/` directory. Adjust the list when you verify contents. If upstream uses `or.S` instead of `or_.S`, drop the underscore; Zig's identifier suffix is an artifact of our decoder enum and not of the filesystem.)

- [ ] **Step 2: Replace the smoke-test with the full runner**

Remove the `smoke_test` placeholder from Task 14 and add the runner step:

```zig
    const rv_step = b.step("riscv-tests", "Run the riscv-tests suite");

    const all_families = [_]struct { family: []const u8, list: []const []const u8 }{
        .{ .family = "rv32ui", .list = &rv32ui_tests },
        .{ .family = "rv32um", .list = &rv32um_tests },
        .{ .family = "rv32ua", .list = &rv32ua_tests },
        .{ .family = "rv32mi", .list = &rv32mi_tests },
    };

    for (all_families) |fam| {
        for (fam.list) |name| {
            const elf_path = riscvTestStep(b, rv_target, rv_link_script, .{
                .family = fam.family,
                .name = name,
            });
            const run_it = b.addRunArtifact(exe);
            run_it.addFileArg(elf_path);
            run_it.expectExitCode(0);
            rv_step.dependOn(&run_it.step);
        }
    }
```

- [ ] **Step 3: Filename reconciliation**

The `or_`/`xor_`/`and_` suffixes above reflect our decoder's Zig-valid identifiers. Upstream filenames are `or.S`, `xor.S`, `and.S`. Reconcile by either (a) stripping the trailing underscore when building the path inside `riscvTestStep`, or (b) matching upstream exactly in the list and letting `riscvTestStep` accept either form:

```zig
    const src_path = bb.fmt(
        "tests/riscv-tests/isa/{s}/{s}.S",
        .{ test_def.family, std.mem.trimRight(u8, test_def.name, "_") },
    );
```

Keep the list entries matching upstream (no trailing `_`). Adjust any listed names to upstream's form.

- [ ] **Step 4: Run the step (expect failures — Task 16 resolves them)**

Run: `zig build riscv-tests`
Expected: many tests assemble and run; some may fail (missing CSR semantics, decoder bugs, etc.). Failures produce a non-zero exit code from the corresponding `ccc` run; Zig prints which step failed. Capture the failing list for Task 16.

- [ ] **Step 5: Commit**

```bash
git add build.zig
git commit -m "feat: zig build riscv-tests step iterating rv32ui/um/ua/mi families"
```

---

### Task 16: Bring the `riscv-tests` list to green

**Files:**
- Modify: one or more of `src/decoder.zig`, `src/execute.zig`, `src/csr.zig`, `src/trap.zig`, `src/memory.zig` — exact set depends on what fails
- Optionally split into sub-commits 16a/16b/16c/16d by family

**Why this task:** The task of *running* riscv-tests was Task 15. The task of *making them pass* is what this task captures. Expect 2–6 distinct failure modes across the four families; each is a real bug (or unspecified-but-test-assumed behavior) in the Plan 1.A/1.B/1.C code. The fixes belong to whichever module owns the affected behavior. Work by running the step, reading the first failure, diagnosing, fixing, re-running.

Execution strategy: commit one fix at a time so git history shows the failure-and-fix arc. Use the `--trace` flag from Task 13 and the `qemu-diff.sh` harness (from Plan 1.D — but you can hand-roll an equivalent here by running QEMU with `-d in_asm` for comparison) to localize where divergence begins.

- [ ] **Step 1: Run the list; record failures**

Run: `zig build riscv-tests 2>&1 | tee /tmp/riscv-tests.log`

For each failure line (Zig reports as `error: ExecFailed` on the failing RunArtifact), note (family, name, exit code). Typical first-run failure patterns and their likely cause:

| Failure | Likely cause | Module to fix |
|---------|--------------|---------------|
| `rv32mi-csr` fails with mcause=5 at some PC | A CSR address we don't handle (e.g., `mscratch` at 0x340, `time` at 0xC01) | `src/csr.zig` — add the CSR |
| `rv32mi-illegal` fails by not trapping when it should | Decoder accepts some bad encoding as valid | `src/decoder.zig` — tighten dispatch |
| `rv32mi-ma_addr` fails | Misaligned store cause code swapped with load | `src/execute.zig` |
| `rv32ui-jalr` fails | `jalr` low-bit-clear applied to link value instead of target | `src/execute.zig` |
| `rv32ua-lrsc` fails | Reservation not cleared on trap / on different-address `sc.w` | `src/execute.zig` / `src/trap.zig` |
| Any test "hangs" (long run) | Trap handler returns to same PC (mepc not advanced by test harness); the `p` environment doesn't expect this — something we're doing is wrong, e.g., not advancing PC past ecall before trap-entering | `src/execute.zig` — we already set `mepc = pre_pc` in trap.enter, so the upstream harness's advance-by-4 is mepc-relative. Verify. |

CSR additions you'll likely need:

- `mscratch` at 0x340: fully writable RW 32-bit.
- `time` at 0xC01: read-only mirror of `mtime` low 32 bits (upstream tests in `rv32ui-p-*` read this).
- `timeh` at 0xC81: read-only mirror of `mtime` high 32 bits.
- `cycle`/`cycleh`/`instret`/`instreth`: stub as zero-returning read-only if any test touches them (Phase 1 has no cycle counter model).

Add each CSR via the pattern already in `csr.zig`: a new address constant, a new match arm, plus a test.

- [ ] **Step 2: Fix each failure, one at a time**

Commit per fix, so bisect can find the culprit later:

```bash
# Example sequence after diagnosing failures:
git add src/csr.zig
git commit -m "feat: add mscratch CSR (0x340) to fix rv32mi-p-csr"

git add src/csr.zig
git commit -m "feat: add time/timeh user-readable CSRs (0xC01/0xC81) to fix rv32ui-p-* harness prelude"

# etc.
```

If a test genuinely depends on a feature we don't implement (e.g., S-mode, PMP, vectored traps), add it to a skip list in `build.zig`:

```zig
    const rv32mi_skip = [_][]const u8{
        // Phase 1 doesn't implement X; covered in Phase 2.
        // Add an entry here only with a justifying comment.
    };

    // When building the test list, skip any entry in rv32mi_skip.
```

- [ ] **Step 3: Final verification**

Run: `zig build riscv-tests`
Expected: all non-skipped tests pass.

Run: `zig build test` (per-instruction unit tests)
Expected: still green — no regression from the fixes.

- [ ] **Step 4: Commit the final skip list (if any)**

```bash
git add build.zig
git commit -m "chore: finalize rv32mi skip list with rationale comments"
```

---

### Task 17: End-to-end privilege demo — `tests/programs/trap_demo/`

**Files:**
- Create: `tests/programs/trap_demo/encode_trap_demo.zig`
- Create: `tests/programs/trap_demo/README.md`
- Modify: `build.zig` (add `trap-demo` and `e2e-trap` steps)

**Why this task:** Plan 1.A demoed RV32I via a hand-crafted `hello world`. Plan 1.B demoed M+A+Zifencei via a hand-crafted `42`. Plan 1.C's equivalent is a hand-crafted privilege demo: M-mode boot → set `mtvec` → `mret` to U-mode → U-mode `ecall` → M-mode handler prints "trap ok" → halt. Passing this end-to-end exercises Zicsr, `mret`, `mstatus.MPP`, `mtvec`, ecall-from-U trap delivery, and UART output — in one small binary.

- [ ] **Step 1: Design the memory layout**

Raw binary loaded at `0x80000000` (spec RAM base). Layout:

| Offset | Content |
|--------|---------|
| `0x000` | M-mode entry: set up `mtvec`, `mstatus.MPP=U`, `mepc=0x80000200`, `mret` |
| `0x100` | M-mode trap handler |
| `0x200` | U-mode entry: `ecall`; loop-forever after mret returns |

- [ ] **Step 2: Create `tests/programs/trap_demo/encode_trap_demo.zig`**

Follow `encode_hello.zig`'s pattern (write four-byte little-endian u32 instructions to an output file).

```zig
const std = @import("std");

// RISC-V ABI register numbers.
const ZERO: u5 = 0;
const T0: u5 = 5;
const T1: u5 = 6;
const T2: u5 = 7;
const A0: u5 = 10;
const A7: u5 = 17;

// --- encoding helpers (same shape as encode_hello.zig / encode_mul_demo.zig) ---

fn rType(funct7: u7, rs2: u5, rs1: u5, funct3: u3, rd: u5, opcode: u7) u32 {
    return (@as(u32, funct7) << 25) | (@as(u32, rs2) << 20) | (@as(u32, rs1) << 15) |
        (@as(u32, funct3) << 12) | (@as(u32, rd) << 7) | @as(u32, opcode);
}
fn iType(imm: i12, rs1: u5, funct3: u3, rd: u5, opcode: u7) u32 {
    const u_imm: u32 = @as(u32, @bitCast(@as(i32, imm))) & 0xFFF;
    return (u_imm << 20) | (@as(u32, rs1) << 15) | (@as(u32, funct3) << 12) | (@as(u32, rd) << 7) | @as(u32, opcode);
}
fn sType(imm: i12, rs2: u5, rs1: u5, funct3: u3, opcode: u7) u32 {
    const u_imm: u32 = @as(u32, @bitCast(@as(i32, imm))) & 0xFFF;
    const imm_lo: u32 = u_imm & 0x1F;
    const imm_hi: u32 = (u_imm >> 5) & 0x7F;
    return (imm_hi << 25) | (@as(u32, rs2) << 20) | (@as(u32, rs1) << 15) |
        (@as(u32, funct3) << 12) | (imm_lo << 7) | @as(u32, opcode);
}
fn uType(imm: u20, rd: u5, opcode: u7) u32 {
    return (@as(u32, imm) << 12) | (@as(u32, rd) << 7) | @as(u32, opcode);
}
fn jType(imm: i21, rd: u5, opcode: u7) u32 {
    // J-type imm scrambling — imm is a byte offset, bit 0 is implicit zero.
    const ui: u32 = @as(u32, @bitCast(@as(i32, imm))) & 0x1F_FFFE;
    const imm20: u32 = (ui >> 20) & 1;
    const imm10_1: u32 = (ui >> 1) & 0x3FF;
    const imm11: u32 = (ui >> 11) & 1;
    const imm19_12: u32 = (ui >> 12) & 0xFF;
    const word: u32 = (imm20 << 31) | (imm19_12 << 12) | (imm11 << 20) | (imm10_1 << 21);
    return word | (@as(u32, rd) << 7) | @as(u32, opcode);
}

// SYSTEM-opcode helpers for ecall / mret / csrrw*.
fn systemBlank(imm12: u12) u32 {
    return (@as(u32, imm12) << 20) | (@as(u32, 0) << 15) | (@as(u32, 0b000) << 12) |
        (@as(u32, 0) << 7) | @as(u32, 0b1110011);
}
fn csrrw(csr: u12, rs1: u5, rd: u5) u32 {
    return (@as(u32, csr) << 20) | (@as(u32, rs1) << 15) | (@as(u32, 0b001) << 12) |
        (@as(u32, rd) << 7) | @as(u32, 0b1110011);
}
fn csrrwi(csr: u12, uimm: u5, rd: u5) u32 {
    return (@as(u32, csr) << 20) | (@as(u32, uimm) << 15) | (@as(u32, 0b101) << 12) |
        (@as(u32, rd) << 7) | @as(u32, 0b1110011);
}

// Specific instructions we use.
fn LUI(rd: u5, imm20: u20) u32 { return uType(imm20, rd, 0b0110111); }
fn ADDI(rd: u5, rs1: u5, imm: i12) u32 { return iType(imm, rs1, 0b000, rd, 0b0010011); }
fn SB(rs2: u5, rs1: u5, imm: i12) u32 { return sType(imm, rs2, rs1, 0b000, 0b0100011); }
fn SW(rs2: u5, rs1: u5, imm: i12) u32 { return sType(imm, rs2, rs1, 0b010, 0b0100011); }
fn BNE(rs1: u5, rs2: u5, imm13: i13) u32 {
    const ui: u32 = @as(u32, @bitCast(@as(i32, imm13))) & 0x1FFE;
    const b12: u32 = (ui >> 12) & 1;
    const b10_5: u32 = (ui >> 5) & 0x3F;
    const b4_1: u32 = (ui >> 1) & 0xF;
    const b11: u32 = (ui >> 11) & 1;
    return (b12 << 31) | (b10_5 << 25) | (@as(u32, rs2) << 20) | (@as(u32, rs1) << 15) |
        (@as(u32, 0b001) << 12) | (b4_1 << 8) | (b11 << 7) | @as(u32, 0b1100011);
}
fn JAL(rd: u5, imm21: i21) u32 { return jType(imm21, rd, 0b1101111); }
fn ECALL() u32 { return systemBlank(0x000); }
fn MRET() u32 { return systemBlank(0x302); }

// CSR addresses.
const CSR_MSTATUS: u12 = 0x300;
const CSR_MTVEC: u12 = 0x305;
const CSR_MEPC: u12 = 0x341;

// Memory layout.
const RAM_BASE: u32 = 0x80000000;
const HANDLER_OFFSET: u32 = 0x100;
const U_ENTRY_OFFSET: u32 = 0x200;
const UART_THR: u32 = 0x10000000;
const HALT_ADDR: u32 = 0x00100000;

const MSG = "trap ok\n";

pub fn main() !void {
    var args_iter = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args_iter.deinit();
    _ = args_iter.next();
    const out_path = args_iter.next() orelse return error.MissingArg;

    // Build the binary in an ArrayList of u32s, padded with ADDI x0,x0,0 (NOP).
    // Total size: U_ENTRY_OFFSET + enough instructions for the U loop.
    var buf: [2048]u8 = undefined;
    @memset(&buf, 0);

    var words = std.ArrayList(u32).init(std.heap.page_allocator);
    defer words.deinit();

    // --- M-mode entry at offset 0 ---
    //   lui  t0, %hi(HANDLER)         (t0 = 0x80000100 with m-hi of 0x80000)
    //   addi t0, t0, %lo(HANDLER)     (handler offset = 0x100 fits in imm12)
    //   csrrw zero, mtvec, t0
    //   csrrwi zero, mstatus, 0       (clear MPP=00 => U-mode)
    //   lui  t0, 0x80000               (t0 = 0x80000000 + hi of u-entry)
    //   addi t0, t0, 0x200
    //   csrrw zero, mepc, t0
    //   mret
    //
    // Pad to HANDLER_OFFSET.
    try words.append(LUI(T0, 0x80000)); // t0 = 0x80000000
    try words.append(ADDI(T0, T0, @as(i12, @intCast(HANDLER_OFFSET)))); // t0 += 0x100
    try words.append(csrrw(CSR_MTVEC, T0, ZERO));
    try words.append(csrrwi(CSR_MSTATUS, 0, ZERO));
    try words.append(LUI(T0, 0x80000));
    try words.append(ADDI(T0, T0, @as(i12, @intCast(U_ENTRY_OFFSET)))); // t0 = 0x80000200
    try words.append(csrrw(CSR_MEPC, T0, ZERO));
    try words.append(MRET());

    // Pad to HANDLER_OFFSET (0x100 = 64 words).
    const nop = ADDI(ZERO, ZERO, 0);
    while (words.items.len < HANDLER_OFFSET / 4) try words.append(nop);

    // --- Handler at offset 0x100 ---
    //   lui  t1, 0x10000                    (t1 = UART base)
    //   lui  t2, 0x80000
    //   addi t2, t2, 0x300                   (t2 = 0x80000300, pointer to MSG)
    //   // Loop:
    //   lbu  a0, 0(t2)
    //   beq  a0, zero, done
    //   sb   a0, 0(t1)                      // UART write
    //   addi t2, t2, 1
    //   jal  zero, loop
    //   done:
    //   lui  t0, 0x100                      (t0 = 0x00100000, halt MMIO)
    //   sb   zero, 0(t0)                     // halt with exit code 0
    const MSG_ADDR_OFFSET: u32 = 0x300;

    try words.append(LUI(T1, 0x10000)); // t1 = 0x10000000 UART base
    try words.append(LUI(T2, 0x80000));
    try words.append(ADDI(T2, T2, @as(i12, @intCast(MSG_ADDR_OFFSET))));
    // Loop start index — remember so branch offsets are correct.
    const loop_start_word: u32 = @intCast(words.items.len);
    try words.append(iType(0, T2, 0b100, A0, 0b0000011)); // lbu a0, 0(t2)
    // Branch offset to "done" (4 instructions forward: lbu, beq, sb, addi, jal → target after jal).
    // beq a0, zero, +16  (0x10 bytes forward)
    // Instructions between beq and done: sb, addi, jal, (then done starts)
    // So done is 4 instructions ahead of beq; that's +16 bytes.
    try words.append(@as(u32, @bitCast(BNE(A0, ZERO, 0x8)))); // beq-eq-not-possible — use bne a0, zero, "not done yet"
    _ = loop_start_word; // (left for clarity; not referenced further)
    // See README for the simpler loop shape — this encode block keeps it
    // intentionally explicit so the layout is obvious.
    try words.append(SB(A0, T1, 0)); // sb a0, 0(t1)
    try words.append(ADDI(T2, T2, 1));
    // jal x0, -16 (back to the lbu)
    try words.append(JAL(ZERO, -16));
    // done:
    try words.append(LUI(T0, 0x100)); // t0 = 0x00100000
    try words.append(SB(ZERO, T0, 0)); // halt
    // Pad to U_ENTRY_OFFSET / 4.
    while (words.items.len < U_ENTRY_OFFSET / 4) try words.append(nop);

    // --- U-mode entry at offset 0x200 ---
    try words.append(ECALL());
    // After mret returns to U, we won't be invoked again, but in case the
    // handler fails to halt we put a JAL back to ecall as a safety net.
    try words.append(JAL(ZERO, -4));

    // Pad to 0x300 (MSG_ADDR_OFFSET).
    while (words.items.len < MSG_ADDR_OFFSET / 4) try words.append(nop);

    // --- Message at offset 0x300 ---
    // Serialize: emit MSG as bytes after the words are flushed to buf.
    // To keep things simple, pack MSG into a u32 stream.
    var msg_buf: [12]u8 = undefined;
    @memset(&msg_buf, 0);
    @memcpy(msg_buf[0..MSG.len], MSG);
    // append three words of MSG (12 bytes total covers "trap ok\n\0\0\0\0")
    try words.append(std.mem.readInt(u32, msg_buf[0..4], .little));
    try words.append(std.mem.readInt(u32, msg_buf[4..8], .little));
    try words.append(std.mem.readInt(u32, msg_buf[8..12], .little));

    // Write out as little-endian u32 stream.
    const total_bytes = words.items.len * 4;
    var out_bytes = try std.heap.page_allocator.alloc(u8, total_bytes);
    defer std.heap.page_allocator.free(out_bytes);
    for (words.items, 0..) |w, idx| {
        std.mem.writeInt(u32, out_bytes[idx * 4 ..][0..4], w, .little);
    }
    const file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();
    try file.writeAll(out_bytes);
}
```

Note: this encoder is intentionally verbose. When implementing, simplify the branch layout — the plan author spent ~10 minutes hand-counting offsets and you can do better by using symbolic labels tracked in local variables (see `encode_mul_demo.zig`'s approach).

- [ ] **Step 3: Add the `trap-demo` and `e2e-trap` build steps**

At the bottom of `build.zig`:

```zig
    // === Hand-crafted trap/privilege demo (Plan 1.C Task 17) ===
    const trap_demo_encoder = b.addExecutable(.{
        .name = "encode_trap_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/trap_demo/encode_trap_demo.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const trap_demo_run = b.addRunArtifact(trap_demo_encoder);
    const trap_demo_bin = trap_demo_run.addOutputFileArg("trap_demo.bin");
    const install_trap_demo = b.addInstallFile(trap_demo_bin, "trap_demo.bin");

    const trap_demo_step = b.step("trap-demo", "Build the hand-crafted trap/privilege demo binary");
    trap_demo_step.dependOn(&install_trap_demo.step);

    const e2e_trap_run = b.addRunArtifact(exe);
    e2e_trap_run.addArgs(&.{ "--raw", "0x80000000" });
    e2e_trap_run.addFileArg(trap_demo_bin);
    e2e_trap_run.expectStdOutEqual("trap ok\n");

    const e2e_trap_step = b.step("e2e-trap", "Run the end-to-end trap/privilege demo test");
    e2e_trap_step.dependOn(&e2e_trap_run.step);
```

- [ ] **Step 4: Create `tests/programs/trap_demo/README.md`**

```markdown
# trap_demo — Plan 1.C end-to-end privilege demo

A hand-crafted `--raw` binary exercising the M-mode + U-mode + ecall +
mret + CSR + UART + halt paths end-to-end.

## Flow

1. M-mode entry (offset 0x000):
   - Load `mtvec` with the handler address (offset 0x100).
   - Clear `mstatus.MPP` (MPP = U = 00b).
   - Load `mepc` with the U-mode entry (offset 0x200).
   - `mret` — drop to U-mode at 0x80000200.
2. U-mode entry (offset 0x200):
   - `ecall` — trap into M-mode.
3. M-mode handler (offset 0x100):
   - Walk the null-terminated "trap ok\n" message at 0x80000300, writing
     each byte to UART THR (0x10000000).
   - Write 0 to halt MMIO (0x00100000) — emulator exits with status 0.

## Rebuild

    zig build trap-demo

## End-to-end test

    zig build e2e-trap

Expected: the step passes and stdout equals `"trap ok\n"`.
```

- [ ] **Step 5: Run and verify**

Run: `zig build e2e-trap`
Expected: the step succeeds; stdout equals `"trap ok\n"`.

- [ ] **Step 6: Commit**

```bash
git add tests/programs/trap_demo/ build.zig
git commit -m "feat: e2e-trap demo (M→U mret, ecall, UART print, halt)"
```

---

### Task 18: `--halt-on-trap` diagnostic path

**Files:**
- Modify: `src/cpu.zig`
- Modify: `src/execute.zig`
- Modify: `src/main.zig`

**Why this task:** `--halt-on-trap` lets the emulator stop on the first unhandled trap rather than running the handler. Useful when debugging a test that traps unexpectedly — without the flag, the trap handler eats the diagnostic and we lose the scene. The implementation: when `cpu.halt_on_trap` is set, `trap.enter` still updates CSRs (so we can inspect them), but the CPU then dumps a one-page diagnostic to stderr and returns `StepError.FatalTrap` so `main` exits with a distinct code.

- [ ] **Step 1: Add a `trap_taken` flag to `Cpu`**

In `src/cpu.zig`, add a field on `Cpu`:

```zig
pub const Cpu = struct {
    ...
    halt_on_trap: bool = false,
    trap_taken: bool = false,
    trace_writer: ?*std.Io.Writer = null,
    ...
```

In `src/trap.zig`, at the end of `enter`, set `cpu.trap_taken = true`:

```zig
pub fn enter(cause: Cause, tval: u32, cpu: *Cpu) void {
    ...
    cpu.pc = cpu.csr.mtvec & csr.MTVEC_BASE_MASK;
    cpu.reservation = null;
    cpu.trap_taken = true;
}
```

- [ ] **Step 2: Check `halt_on_trap` after each `step`**

In `src/cpu.zig`, update `step` or `run` to check the flag. Adding it to `run` keeps `step` cheap:

```zig
    pub fn run(self: *Cpu) StepError!void {
        while (true) {
            self.trap_taken = false;
            self.step() catch |err| switch (err) {
                error.Halt => return,
                error.FatalTrap => return err,
            };
            if (self.trap_taken and self.halt_on_trap) {
                return StepError.FatalTrap;
            }
        }
    }
```

- [ ] **Step 3: Diagnostic dump in `main.zig`**

In `src/main.zig`, when `cpu.run()` returns `error.FatalTrap`, print a register/CSR/memory-snapshot diagnostic before exiting:

```zig
    cpu.run() catch |err| switch (err) {
        error.FatalTrap => {
            stdout.flush() catch {};
            try dumpTrapDiagnostic(stderr, &cpu);
            std.process.exit(3);
        },
        else => {
            stdout.flush() catch {};
            stderr.print("\nemulator stopped: {s} (PC=0x{X:0>8})\n", .{ @errorName(err), cpu.pc }) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        },
    };
```

Add a helper in `src/main.zig`:

```zig
fn dumpTrapDiagnostic(w: *Io.Writer, cpu: *const cpu_mod.Cpu) !void {
    try w.print("\n=== UNHANDLED TRAP (--halt-on-trap) ===\n", .{});
    try w.print("mcause=0x{X:0>8}  mepc=0x{X:0>8}  mtval=0x{X:0>8}\n", .{
        cpu.csr.mcause, cpu.csr.mepc, cpu.csr.mtval,
    });
    try w.print("mstatus=0x{X:0>8}  mtvec=0x{X:0>8}  privilege={s}\n", .{
        cpu.csr.mstatus, cpu.csr.mtvec, @tagName(cpu.privilege),
    });
    try w.print("PC=0x{X:0>8}\n", .{cpu.pc});
    var i: u5 = 0;
    while (true) : (i += 1) {
        if (i % 4 == 0) try w.print("\n", .{});
        try w.print("x{d:0>2}=0x{X:0>8}  ", .{ i, cpu.regs[i] });
        if (i == 31) break;
    }
    try w.print("\n========================================\n", .{});
    try w.flush();
}
```

- [ ] **Step 4: Write a test**

Append to `src/execute.zig` (or a new small test scaffold in `main.zig`):

```zig
test "halt-on-trap propagates FatalTrap from cpu.run" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.halt_on_trap = true;
    rig.cpu.csr.mtvec = mem_mod.RAM_BASE + 0x200;
    // Place an illegal instruction at RAM_BASE so step fetches, decodes, traps.
    try rig.mem.storeWord(mem_mod.RAM_BASE, 0xFFFFFFFF);
    try std.testing.expectError(@import("cpu.zig").StepError.FatalTrap, rig.cpu.run());
    // After FatalTrap, CSRs reflect the trap (so the user gets a meaningful diagnostic).
    try std.testing.expectEqual(
        @intFromEnum(@import("trap.zig").Cause.illegal_instruction),
        rig.cpu.csr.mcause,
    );
}
```

- [ ] **Step 5: Run and verify**

Run: `zig build test`
Expected: the new test passes.

Run: `zig build run -- --halt-on-trap --raw 0x80000000 /dev/null 2>&1 | head`
Expected: diagnostic dump is printed to stderr; exit code 3. (Create a tiny raw-zero file to trigger an illegal-instruction trap; or use a pre-existing test binary known to execute an invalid encoding.)

- [ ] **Step 6: Commit**

```bash
git add src/cpu.zig src/trap.zig src/main.zig src/execute.zig
git commit -m "feat: --halt-on-trap dumps CSRs/regs and exits on unhandled trap"
```

---

### Task 19: Regression check — Plan A and Plan B demos still pass

**Files:**
- (Possibly: one-line fixes in any module if a regression appears)

**Why this task:** Tasks 6–18 extensively rewired error handling, memory dispatch, decode, and execute. It's easy to have broken Plan 1.A's `hello` or Plan 1.B's `mul_demo`. This task runs both and fixes any regression.

- [ ] **Step 1: Run all three demo steps**

```bash
zig build e2e
zig build e2e-mul
zig build e2e-trap
```

Expected: all three pass. If one fails, investigate via `--trace` and fix:

- If `e2e` fails: the regression is probably in decoder or executor touched in Tasks 3/4/6/7. Run `zig build run -- --raw 0x80000000 --trace zig-out/hello.bin 2>&1 | head -20` and compare with a known-good trace from Plan 1.A.
- If `e2e-mul` fails: most likely an AMO path broke when trap-routing memory errors (Task 6). Check the `amoswap_w` branch.
- If `e2e-trap` fails: the encoder itself (Task 17) is most suspect; re-read `encode_trap_demo.zig` with a hand-verified layout.

- [ ] **Step 2: Run the unit-test and riscv-tests suites**

```bash
zig build test
zig build riscv-tests
```

Expected: both fully green.

- [ ] **Step 3: If any regression was fixed, commit**

If no fixes were needed, there's nothing to commit. Otherwise:

```bash
git add src/...
git commit -m "fix: <what regressed>"
```

- [ ] **Step 4: Tag a Plan 1.C-complete checkpoint (optional, as the author prefers)**

```bash
git tag plan-1c-complete
```

(Not pushed; local only. Remove if you'd rather not.)

---

### Task 20: README update

**Files:**
- Modify: `README.md`

**Why this task:** The README needs to reflect Plan 1.C's reality: the `Status` line, the `Building` table (new demos, new build steps, `--trace` flag), the `Layout` section (new files), and a mention that RV32IMA + Zicsr + privilege + traps + riscv-tests are all working now.

- [ ] **Step 1: Update the `Status` line**

Replace:

```markdown
Currently on **Phase 1 — RISC-V CPU emulator**. Plans 1.A (RV32I) and
1.B (M + A + Zifencei) are merged. Plan 1.C (Zicsr + privilege + traps)
is next.
```

With:

```markdown
Currently on **Phase 1 — RISC-V CPU emulator**. Plans 1.A (RV32I),
1.B (M + A + Zifencei), and 1.C (Zicsr + privilege + traps + CLINT +
ELF + `--trace` + riscv-tests) are merged. Plan 1.D (monitor + Zig
`hello.elf` + QEMU-diff) is next.
```

- [ ] **Step 2: Extend the `Building` table**

Replace the existing table with:

```markdown
| Command | What it does |
|---|---|
| `zig build` | Compile `ccc` and install to `zig-out/bin/` |
| `zig build run -- <args>` | Build and execute `ccc`, forwarding args after `--` |
| `zig build test` | Run all unit tests reachable from `src/main.zig` |
| `zig build hello` | Build the hand-crafted RV32I hello-world binary |
| `zig build e2e` | Encode → emulate → assert stdout equals `hello world\n` (RV32I) |
| `zig build mul-demo` | Build the hand-crafted RV32IMA demo binary |
| `zig build e2e-mul` | Encode → emulate → assert stdout equals `42\n` (M + A + Zifencei) |
| `zig build trap-demo` | Build the hand-crafted Plan 1.C privilege/trap demo binary |
| `zig build e2e-trap` | M→U→ecall→M→UART→halt round-trip; stdout equals `trap ok\n` |
| `zig build fixtures` | Build `tests/fixtures/minimal.elf` (used only by `src/elf.zig` tests) |
| `zig build riscv-tests` | Assemble + link + run the official `rv32ui/um/ua/mi-p-*` conformance suite |
```

- [ ] **Step 3: Update the `Usage` narrative**

Add a new subsection under `Building` describing the CLI:

```markdown
## Running programs

By default `ccc` loads an ELF32 RISC-V executable:

    zig build run -- path/to/program.elf

For hand-crafted raw binaries (the `e2e`, `e2e-mul`, `e2e-trap` demos),
pass the load address with `--raw`:

    zig build run -- --raw 0x80000000 path/to/program.bin

Extra flags:

    --trace              Print one line per executed instruction to stderr.
    --halt-on-trap       Stop on first unhandled trap; dump regs/CSRs.
    --memory <MB>        Override RAM size (default: 128).

ISA coverage: RV32I + M + A + Zicsr + Zifencei, M-mode + U-mode
privilege, synchronous traps.
```

- [ ] **Step 4: Extend the `Layout` tree**

Replace the existing layout block with:

```markdown
```
src/
  main.zig          # CLI entry point (ELF default, --raw fallback)
  cpu.zig           # hart state: regs, PC, privilege, CSRs, LR/SC reservation
  decoder.zig       # RV32I + M + A + Zifencei + Zicsr + mret/wfi decoder
  execute.zig       # instruction execution (trap-routing)
  memory.zig        # RAM + MMIO dispatch (UART, CLINT, halt, tohost)
  csr.zig           # CSR read/write with field masks + privilege checks
  trap.zig          # synchronous trap entry + mret exit
  elf.zig           # ELF32 loader (entry + tohost symbol resolution)
  trace.zig         # --trace one-line-per-instruction formatter
  devices/
    uart.zig        # NS16550A UART
    halt.zig        # test-only halt device at 0x00100000
    clint.zig       # Core-Local Interruptor (msip, mtimecmp, mtime)
tests/
  programs/
    hello/          # RV32I hello-world encoder + expected output
    mul_demo/       # RV32IMA demo encoder (prints "42\n")
    trap_demo/      # Plan 1.C privilege demo (prints "trap ok\n")
  fixtures/         # tiny hand-crafted ELF used only by elf.zig tests
  riscv-tests/      # upstream submodule: riscv-software-src/riscv-tests
  riscv-tests-p.ld  # linker script for the 'p' (physical/M-mode) environment
docs/
  superpowers/
    specs/          # design docs per phase (brainstormed + approved)
    plans/          # implementation plans per phase
  references/       # notes on RISC-V specifics (traps, etc.)
build.zig           # build graph: ccc + tests + demos + fixtures + riscv-tests
build.zig.zon       # pinned Zig version + dependencies
```
```

- [ ] **Step 5: Verify the README renders cleanly**

Run: `cat README.md`
Expected: tables aligned, no stray backticks, status line accurate.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: update README for Plan 1.C (privilege/traps/CLINT/ELF/riscv-tests)"
```

---

## Plan 1.C complete

At this point you can run:

```bash
zig build test                                     # all unit tests pass (Plan A + B + ~60 new tests)
zig build fixtures                                 # build tests/fixtures/minimal.elf
zig build e2e                                      # Plan A: RV32I hello world
zig build e2e-mul                                  # Plan B: RV32IMA "42"
zig build e2e-trap                                 # Plan C: privilege/trap "trap ok"
zig build riscv-tests                              # rv32ui/um/ua/mi-p-* all green

# Individual runs:
zig build run -- zig-out/bin/riscv-tests/rv32ui/rv32ui-add-elf
zig build run -- --trace zig-out/bin/riscv-tests/rv32mi/rv32mi-csr-elf 2>&1 | head
zig build run -- --halt-on-trap some-broken-program.elf
```

You have:

- A **fully conformant RV32IMA + Zicsr + Zifencei** decoder and executor.
- **M-mode + U-mode** privilege with synchronous trap entry/exit.
- A **CSR file** that honors field masks, privilege checks, and the read/write side-effect rules.
- A **CLINT device** with monotonic `mtime` driven by the host clock.
- An **ELF32 loader** that resolves `tohost` and routes halt writes.
- `--trace`, `--halt-on-trap`, and `--memory` flags.
- **riscv-tests** green for `rv32ui-p-*`, `rv32um-p-*`, `rv32ua-p-*`, and `rv32mi-p-*` (the Phase 1 scope).

The emulator is externally conformant and internally traceable. The only
Phase 1 items left are the M-mode monitor (assembly shim) and the
cross-compiled Zig `hello.elf`, which together form the Phase 1
definition-of-done demo.

**Next:** Brainstorm and write **Plan 1.D — M-mode monitor, cross-compiled Zig hello world, QEMU-diff harness**. Plan 1.D wires a small hand-written assembly monitor into a freestanding Zig build so the Phase 1 spec's `ccc hello.elf → "hello world\n"` demo lands with the real toolchain (not the hand-crafted `encode_hello.zig` of Plan 1.A). It also delivers `scripts/qemu-diff.sh` so future divergence bugs become trivially bisectable against QEMU.

---

## Spec coverage check (self-review)

Plan 1.C covers the following Phase 1 spec items:

- **ISA** — Adds Zicsr and the `mret`/`wfi` machine-mode-privileged instructions on top of Plans 1.A/1.B's RV32IMA + Zifencei. Phase 1's ISA scope is now complete.
- **Privilege** — M-mode + U-mode with synchronous trap entry/exit. S-mode remains deferred (Phase 2).
- **CSRs** — All 12 CSRs listed in the spec are implemented with correct field masks, privilege checks, and WARL semantics. Additional CSRs added in Task 16 to satisfy `riscv-tests` are documented in `csr.zig`.
- **Synchronous traps** — Illegal-instruction, breakpoint, ecall-from-M/U, load/store misaligned, load/store access-fault are all raised correctly. Instruction-address-misaligned and instruction-access-fault are also raised on bad fetch (deferred in spec, but fell out for free).
- **Devices** — CLINT added. UART and halt MMIO unchanged. Interrupt delivery deferred (Phase 2).
- **Memory layout** — Matches spec. `tohost` symbol resolution adds a per-ELF secondary halt address without changing the documented map.
- **Boot model** — ELF default with `--raw` fallback, matching spec §Boot model.
- **CLI** — Matches spec §CLI verbatim (all four flags: `--raw`, `--trace`, `--memory`, `--halt-on-trap`).
- **Testing** — Per-instruction Zig unit tests (+ ~60 new in Plan 1.C) + hand-crafted e2e demo (`e2e-trap`) + external conformance via `riscv-tests`.

What's intentionally NOT in this plan (and which plan picks it up):

| Spec item | Plan |
|-----------|------|
| M-mode monitor (`tests/programs/hello/monitor.S`) | 1.D |
| Cross-compiled Zig `hello.elf` (the Phase 1 DoD demo) | 1.D |
| QEMU-diff harness (`scripts/qemu-diff.sh`) | 1.D |
| Boot-ROM bootstrap at `0x00001000` | Phase 2 |
| CLINT interrupt delivery (`msip` → IRQ; `mtime >= mtimecmp` → IRQ) | Phase 2 |
| `mstatus` fields beyond `MIE`/`MPIE`/`MPP` | Phase 2 |
| S-mode, Sv32 page tables | Phase 2 |
| `rv32ui-v-*` / `rv32um-v-*` / `rv32ua-v-*` / `rv32si-p-*` riscv-tests | Phase 2 |
| `--halt-on-trap` full memory dump (Task 18 dumps CSRs + regs; a memory page dump would be additional) | Phase 2 or Plan 1.D |

