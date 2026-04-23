# Phase 1 Plan D — Monitor + Zig hello.elf + QEMU-diff + rv32mi-p-* (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close out Phase 1 by delivering the three remaining spec deliverables: (1) the cross-compiled Zig **`hello.elf`** that, together with a small M-mode monitor, prints `hello world` via U-mode `ecall` → M-mode trap → UART; (2) the `rv32mi-p-*` `riscv-tests` family brought to green via a shimmed `riscv_test.h` that works around Zig's LLVM assembler rejecting the upstream `.weak` → `.global` binding change; (3) the **QEMU-diff** debug harness (`scripts/qemu-diff.sh`). After Plan 1.D merges, every item in the Phase 1 spec §Definition of done is satisfied.

**Architecture:** The Plan 1.C emulator runs unchanged — Plan 1.D adds artifacts (test programs, scripts, a header shim) and one set of build-graph nodes (hello.elf build + e2e-hello step + rv32mi runner). The hello test program is a two-object link: `tests/programs/hello/monitor.S` contributes M-mode `_start` + `trap_vector` (ecall dispatch by `a7`: `write(64)` → UART loop + return count, `exit(93)` → halt MMIO write, everything else → `-ENOSYS`); `tests/programs/hello/hello.zig` contributes a U-mode entry function and the message buffer. A hand-written `tests/programs/hello/linker.ld` places `.text.init` (monitor) at `0x80000000` and `.text.umode` + `.rodata.umode` at known offsets. The `hello.elf` build produces an ELF32 RISC-V executable runnable via the existing default `ccc <file>` code path — no changes to `src/` required for hello.elf to work.

For rv32mi conformance: `tests/riscv-tests-shim/riscv_test.h` mirrors upstream's `env/p/riscv_test.h` with the two `.weak` handler declarations removed. The shim directory is added to the object's include path *before* `env/p`, so the C preprocessor resolves `#include "riscv_test.h"` against the shim. This is a pure source-level workaround — upstream's symbol table semantics (resolved by the linker) are preserved; we only change what the assembler sees.

The QEMU-diff harness is a bash script that runs the same ELF under both QEMU and our emulator with per-instruction tracing, canonicalizes the two output formats, and diffs them. First divergence (PC / instruction / register state) is almost always the bug.

**Tech Stack:** Zig 0.16.x (pinned), no new external dependencies. Host platform macOS (Linux works for the QEMU-diff path too). QEMU is an optional dependency used by the debug harness only; not required for `zig build test` or `zig build riscv-tests`.

**Spec reference:** `docs/superpowers/specs/2026-04-23-phase1-cpu-emulator-design.md` — Plan 1.D covers spec §3 "End-to-end hello world", the rv32mi subset of §Testing strategy item 2, and §Testing strategy item 4 "QEMU-diff harness".

**Plan 1.D scope:**

- **M-mode monitor** (`tests/programs/hello/monitor.S`): ~70 lines of RV32IMA assembly. Provides `_start` (set `sp`, install `mtvec`, clear `mstatus.MPP`, load `mepc ← u_entry`, `mret`) and `trap_vector` (read `mcause`; if `ecall_from_u`, dispatch by `a7`; advance `mepc += 4`; `mret`). Syscall numbers match the Linux RISC-V ABI subset: `a7 == 64` is `write`, `a7 == 93` is `exit`. Unknown syscall → `a0 = -ENOSYS (-38)`.
- **U-mode payload** (`tests/programs/hello/hello.zig`): a freestanding Zig object. One exported function, `u_entry`, implemented as `callconv(.Naked)` inline assembly: two back-to-back ecalls (`write(1, msg, 12)`, then `exit(0)`), then a safety `j .` loop. The message lives as an exported `msg: [12]u8` global in `.rodata.umode`.
- **Linker script** (`tests/programs/hello/linker.ld`): positions `.text.init` at `0x80000000`, reserves an 8 KB region ending at `_stack_top` inside the linker's view of RAM (the monitor loads `sp ← _stack_top`), then places `.text.umode` and `.rodata.umode`. No `.bss` populated (the Zig U-mode payload has none — inline asm only, no globals with storage beyond `msg`).
- **Build integration** (`build.zig`):
  - `zig build hello-elf` → produces `zig-out/bin/hello.elf` from the monitor object + hello.zig object, linked with `hello/linker.ld`.
  - `zig build e2e-hello-elf` → runs `ccc zig-out/bin/hello.elf` and asserts stdout equals `"hello world\n"`. This is the Phase 1 §Definition of done demo.
- **rv32mi-p-* tests** (`tests/riscv-tests-shim/riscv_test.h` + `build.zig`): the shim header + inclusion-path reorder lets Zig's LLVM assembler accept rv32mi sources that upstream gcc accepts. Adds 9 rv32mi tests to `zig build riscv-tests`: `csr`, `illegal`, `ma_addr`, `ma_fetch`, `mcsr`, `sbreak`, `scall`, `shamt`, `breakpoint`. (Not added: `lh-misaligned`, `lw-misaligned`, `sh-misaligned`, `sw-misaligned`, `instret_overflow`, `zicntr`, `pmpaddr` — these depend on CSRs / behaviors (`mcycle`/`minstret` counters, PMP) that Phase 1 doesn't model.)
- **QEMU-diff harness** (`scripts/qemu-diff.sh`): bash script taking an ELF path, runs it under `qemu-system-riscv32 -nographic -singlestep -d in_asm,cpu -machine virt -bios none -kernel <elf>` and under `./zig-out/bin/ccc --trace <elf>`, canonicalizes both traces to `PC  insn  regdelta` per line, and runs `diff -u`. Documentation in the same directory's `README.md`.
- **README status update**: bump the "Status" section to "Phase 1 complete"; add `hello-elf` and `e2e-hello-elf` to the build-targets table; note the QEMU-diff script and its dependencies.

**Not in Plan 1.D (explicitly):**

- S-mode, Sv32 paging, PLIC — Phase 2.
- Timer interrupt delivery (CLINT mtime/mtimecmp edges) — Phase 2.
- `rv32ui-v-*`, `rv32um-v-*`, `rv32ua-v-*`, `rv32si-p-*` virtual-memory / S-mode test families — Phase 2.
- `rv32mi-p-lh-misaligned`, `lw-misaligned`, `sh-misaligned`, `sw-misaligned`, `instret_overflow`, `zicntr`, `pmpaddr` — these rely on behaviors Phase 1 doesn't model (misaligned-load emulation vs. trapping, hardware performance counters, PMP). Documented in the same `build.zig` comment that explains the shim.
- Boot ROM bootstrap at `0x00001000` — Phase 2.
- GDB remote stub — deferred (spec says "later phase if needed").

**Deviation from Plan 1.C's closing note:** none. Plan 1.C deferred "The M-mode monitor (`tests/programs/hello/monitor.S`) and the cross-compiled Zig `hello.elf` that together form the Phase 1 definition-of-done demo → Plan 1.D" and "QEMU-diff debug harness (`scripts/qemu-diff.sh`) → Plan 1.D". Plan 1.D delivers both, plus picks up the rv32mi-p-* family that Plan 1.C's `build.zig` comment said required "shimming the upstream header or patching the test sources; both are out of Plan 1.C scope". The shim approach is exactly what Plan 1.C flagged; Plan 1.D implements it.

---

## File structure (final state at end of Plan 1.D)

```
ccc/
├── .gitignore
├── .gitmodules
├── build.zig                           ← MODIFIED (hello-elf, e2e-hello-elf, rv32mi runner, shim include)
├── build.zig.zon
├── README.md                           ← MODIFIED (status: Phase 1 complete; new targets table rows)
├── src/                                ← UNCHANGED from Plan 1.C
├── scripts/
│   └── qemu-diff.sh                    ← NEW (debug harness)
├── docs/
│   └── superpowers/
│       ├── specs/                      ← UNCHANGED
│       └── plans/
│           └── 2026-04-24-phase1-plan-d-monitor-hello-elf-qemu-diff.md  ← THIS FILE
└── tests/
    ├── programs/
    │   ├── hello/                      ← MODIFIED (add monitor.S, hello.zig, linker.ld, update README.md)
    │   │   ├── README.md               ← MODIFIED (document both raw hello.bin and hello.elf flows)
    │   │   ├── encode_hello.zig        ← UNCHANGED (Plan 1.A raw demo)
    │   │   ├── monitor.S               ← NEW
    │   │   ├── hello.zig               ← NEW
    │   │   └── linker.ld               ← NEW
    │   ├── mul_demo/                   ← UNCHANGED
    │   └── trap_demo/                  ← UNCHANGED
    ├── riscv-tests/                    ← UNCHANGED (submodule)
    ├── riscv-tests-p.ld                ← UNCHANGED
    └── riscv-tests-shim/               ← NEW (header shim for rv32mi)
        └── riscv_test.h                ← NEW (upstream env/p/riscv_test.h minus .weak handler declarations)
```

**Module responsibilities (deltas vs Plan 1.C):**

- **`src/`** — unchanged. The emulator already supports everything hello.elf exercises (Zicsr, M/U privilege, trap entry/exit, ECALL_FROM_U, UART write, halt MMIO, ELF32 loader with tohost resolution). Plan 1.D produces NEW test programs and NEW build-graph nodes; no code in `src/` needs to change.
- **`tests/programs/hello/monitor.S` (new)** — the M-mode trap monitor. `_start` sets `sp` to the symbol `_stack_top` (provided by the linker script), installs `trap_vector` in `mtvec` via `csrw`, clears `mstatus.MPP` (MPP = 00 = U-mode for the post-mret target privilege), sets `mepc` to the symbol `u_entry`, and `mret`s. The `trap_vector` reads `mcause`; if it's `ecall_from_u` (8), it dispatches on `a7`: 64 → `sys_write` (copy `a2` bytes from `*a1` to UART THR at `0x10000000`, return original `a2` in `a0`), 93 → `sys_exit` (store byte `a0` to halt MMIO at `0x00100000`), anything else → `a0 ← -38` (-ENOSYS). After dispatch, `mepc += 4` (step past the ecall) and `mret`. Any non-ECALL mcause loops forever (no recovery path in Phase 1).
- **`tests/programs/hello/hello.zig` (new)** — a freestanding Zig file compiled to an object (no `main`, no `_start`). Exports one symbol: `u_entry`, declared `callconv(.Naked) noreturn`. Body: inline asm that sets `a7=64 a0=1 a1=msg a2=12`, `ecall` (write), then `a7=93 a0=0`, `ecall` (exit), then an unreachable `1: j 1b` loop. Also exports `msg: [12]u8` (the literal `"hello world\n"`) in `.rodata.umode` so the assembler's `la a1, msg` resolves at link time.
- **`tests/programs/hello/linker.ld` (new)** — puts the monitor at `0x80000000` and reserves an 8 KB stack region just below an alignment boundary, then places U-mode text and rodata. Emits `_stack_top` as a symbol the monitor can `la sp, _stack_top`.
- **`tests/riscv-tests-shim/riscv_test.h` (new)** — byte-identical to `tests/riscv-tests/env/p/riscv_test.h` except the two lines `.weak stvec_handler;` and `.weak mtvec_handler;` inside `RVTEST_CODE_BEGIN` are removed. Removing `.weak` means later `.global mtvec_handler` declarations in rv32mi test bodies are accepted by LLVM's integrated assembler (no binding change), while the upstream linker semantics (which care about the final STB bit, not intermediate `.weak` hints) are unchanged.
- **`build.zig`** — gains: (1) `hello-elf` target: build monitor.S as an object, build hello.zig as an object, link both into an executable with our linker script, set entry = `_start`; (2) `e2e-hello-elf` target: run the emulator against the built hello.elf, assert stdout equals `"hello world\n"`; (3) rv32mi rows in the per-family run loop + `-I tests/riscv-tests-shim` inserted *before* the other includes in the `riscvTestStep` helper; (4) keeps all Plan 1.A/B/C targets intact.
- **`scripts/qemu-diff.sh` (new)** — bash, ~80 lines. Takes `<elf>` and optional `<max-steps>` (default 1000). Runs QEMU with `-singlestep -d in_asm,cpu` to a temp file, runs our emulator with `--trace` to another temp file, canonicalizes each line to `PC  insn-mnemonic  rd→value` form (the two tracers have different formats — this is the main work), and runs `diff -u`. Exits 0 if identical up to `max-steps`, 1 otherwise with the diff printed. Documentation for dependencies and usage at the top of the script.

---

## Conventions used in this plan

- All Zig code targets Zig 0.16.x (`std.Io.Writer`, `std.process.Init`, `std.heap.ArenaAllocator`). Same API surface as Plan 1.C.
- Tests live as inline `test "name" { ... }` blocks alongside the code under test; `zig build test` runs every test reachable from `src/main.zig`. Plan 1.D adds no new inline tests to `src/`; its primary "test" is the `e2e-hello-elf` end-to-end demo. No new `_ = @import(...)` lines in `main.zig` because no new `src/` modules are introduced.
- The hello monitor is written in assembly so the trap handler can be straightforwardly verified by reading the RISC-V reference (spec §Privilege & trap model, `docs/references/riscv-traps.md`). Writing it in Zig would require `callconv(.Naked)` plus labels plus inline asm labels plus careful register clobbering — the assembly version is clearer at this size.
- The U-mode payload is intentionally a naked Zig function (no stack use): ecall doesn't need a stack, and not needing one lets the monitor's sp setup be "whatever it is after the sp load in `_start`" — the U-mode code never touches sp.
- Register aliases in the monitor use RISC-V ABI numeric register names / ABI names as they appear in the RISC-V assembler (e.g., `sp`, `a0`, `a7`, `t0`) — same convention as the upstream riscv-tests.
- Each task ends with a TDD-style cycle: write/build the artifact, run the verification command, commit. Commit messages follow Conventional Commits: `feat:` for new artifacts, `test:` for new test paths, `chore:` for infra, `docs:` for README/plan updates, `refactor:` for restructuring.
- When extending a grouped build-graph section (e.g., the riscv-tests families loop), we show the full block so diffs are unambiguous.

---

## Tasks

### Task 1: Add the `riscv-tests-shim` header + wire into `riscvTestStep`

**Files:**
- Create: `tests/riscv-tests-shim/riscv_test.h`
- Modify: `build.zig` (one line inside `riscvTestStep`)

**Why this task first:** It's the smallest independent piece — one file + one line — and validates the rv32mi path end-to-end before we touch the larger hello.elf build graph. Catching a shim bug here is cheap; catching it after we've added hello.elf scaffolding means chasing two sources of test failures.

- [ ] **Step 1: Copy upstream `riscv_test.h` into the shim directory and remove `.weak`**

```bash
mkdir -p tests/riscv-tests-shim
cp tests/riscv-tests/env/p/riscv_test.h tests/riscv-tests-shim/riscv_test.h
# Remove the two .weak declarations inside RVTEST_CODE_BEGIN:
sed -i '' '/\.weak stvec_handler/d; /\.weak mtvec_handler/d' tests/riscv-tests-shim/riscv_test.h
```

(On Linux, drop the empty-string argument from `-i`: `sed -i '/\.weak .../d' ...`.)

Verify the shim has zero occurrences of `.weak` and still has `RVTEST_CODE_BEGIN`:

```bash
grep -c '\.weak' tests/riscv-tests-shim/riscv_test.h   # 0
grep -c 'RVTEST_CODE_BEGIN' tests/riscv-tests-shim/riscv_test.h   # 1
```

**Why this works:** GNU `as` silently upgrades `.weak foo` + later `.global foo` to a strong binding. LLVM's integrated assembler (the one Zig ships) rejects the binding change with `error: foo changed binding to STB_GLOBAL`. The upstream `RVTEST_CODE_BEGIN` macro provides the `.weak` hint only so the linker can leave `mtvec_handler` unresolved (jumping to 0) when no test-specific handler exists. The rv32mi tests we care about *do* define a handler (they `.global mtvec_handler; mtvec_handler:`), so dropping the `.weak` hint has no effect on the final linked output — the symbol binding is still `STB_GLOBAL`, just without the earlier `.weak` intermediate step.

- [ ] **Step 2: Add the shim as the earliest include path in `riscvTestStep`**

Inside `build.zig`, in the `riscvTestStep` helper's `obj.root_module.addIncludePath(...)` block, add the shim **before** the existing env/p include:

```zig
            obj.root_module.addAssemblyFile(bb.path(src_path));
            obj.root_module.addIncludePath(bb.path("tests/riscv-tests-shim"));  // NEW — must come first
            obj.root_module.addIncludePath(bb.path("tests/riscv-tests/env/p"));
            obj.root_module.addIncludePath(bb.path("tests/riscv-tests/env"));
            obj.root_module.addIncludePath(bb.path("tests/riscv-tests/isa/macros/scalar"));
```

The preprocessor walks include paths in order; with the shim first, `#include "riscv_test.h"` resolves to our shim.

- [ ] **Step 3: Verify rv32ui/um/ua still pass (the shim must not break existing tests)**

```bash
zig build riscv-tests
```

Expected: exit 0 (same as before — rv32ui/um/ua never used `.weak` interactions, but we need to confirm nothing regresses).

- [ ] **Step 4: Commit**

```bash
git add tests/riscv-tests-shim/ build.zig
git commit -m "feat: riscv-tests-shim to drop upstream .weak handler decls"
```

---

### Task 2: Wire rv32mi-p-* into the `riscv-tests` runner

**Files:**
- Modify: `build.zig` (add rv32mi family row + list; delete the deferred comment)

**Why this task:** With the shim in place, rv32mi sources assemble cleanly. Now we plug the runnable subset (the 9 tests whose behavior Phase 1 models) into the loop. The other 7 tests (`lh-misaligned`, `lw-misaligned`, `sh-misaligned`, `sw-misaligned`, `instret_overflow`, `zicntr`, `pmpaddr`) stay out, with a comment explaining why.

- [ ] **Step 1: Add the rv32mi test list**

In `build.zig`, after the existing `rv32ua_tests` line, replace the `_rv32mi_tests_deferred` block with a live list:

```zig
    const rv32ua_tests = [_][]const u8{ "amoadd_w", "amoand_w", "amomax_w", "amomaxu_w", "amomin_w", "amominu_w", "amoor_w", "amoswap_w", "amoxor_w", "lrsc" };
    // rv32mi-p: machine-mode CSRs, traps, illegal-instruction, misaligned-addr.
    // Requires the riscv-tests-shim (Plan 1.D Task 1) to work around LLVM's
    // assembler rejecting upstream's .weak → .global handler rebinding.
    //
    // Excluded from Phase 1 (behaviors not modeled):
    //   - lh-misaligned/lw-misaligned/sh-misaligned/sw-misaligned: Phase 1
    //     traps on all misaligned accesses; upstream tests assert hardware
    //     handles them transparently. Revisit in Phase 2 if a workload needs it.
    //   - instret_overflow/zicntr: require mcycle/minstret hardware performance
    //     counters (Zicntr). Phase 1 doesn't implement Zicntr.
    //   - pmpaddr: requires Physical Memory Protection. Phase 1 has flat
    //     physical addressing.
    const rv32mi_tests = [_][]const u8{ "csr", "illegal", "ma_addr", "ma_fetch", "mcsr", "sbreak", "scall", "shamt", "breakpoint" };
```

- [ ] **Step 2: Add the rv32mi row to the `all_families` array**

```zig
    const all_families = [_]struct { family: []const u8, list: []const []const u8 }{
        .{ .family = "rv32ui", .list = &rv32ui_tests },
        .{ .family = "rv32um", .list = &rv32um_tests },
        .{ .family = "rv32ua", .list = &rv32ua_tests },
        .{ .family = "rv32mi", .list = &rv32mi_tests },
    };
```

- [ ] **Step 3: Update the `rv-step` description and run**

Change the step description string from `"Run the riscv-tests suite (rv32ui/um/ua)"` to `"Run the riscv-tests suite (rv32ui/um/ua/mi)"`:

```zig
    const rv_step = b.step("riscv-tests", "Run the riscv-tests suite (rv32ui/um/ua/mi)");
```

Then:

```bash
zig build riscv-tests
```

Expected: exit 0. All 66 tests (38 ui + 8 um + 10 ua + 9 mi = 65 distinct + 1 `simple`) pass.

- [ ] **Step 4: If any rv32mi test fails, diagnose**

Most likely failure modes and what they mean:

| Failure | Likely cause | Fix location |
|---|---|---|
| `breakpoint` fails | `ebreak` raises `mcause=3 (breakpoint)` but the test expects a specific handler path | `src/execute.zig`'s ebreak arm + `src/trap.zig`'s `Cause.breakpoint` — should already work from Plan 1.C; if not, add a failing inline test mirroring the test's expected sequence |
| `ma_addr` fails | Misaligned load/store *addresses* should trap. Verify `src/memory.zig` raises `MisalignedAccess` and execute.zig routes it to `load_addr_misaligned` / `store_addr_misaligned` (already true from Plan 1.C) |
| `ma_fetch` fails | Jump to a misaligned instruction address should trap with `instr_addr_misaligned`. Plan 1.C's `src/cpu.zig::step` handles this — look at whether the test's `mtval` expectation matches what we write |
| `csr`/`mcsr`/`illegal` fail | CSR field masks or illegal-instruction encoding mismatch vs. spec. Inspect `src/csr.zig` + `src/execute.zig` |

For each failing test, first reproduce with:

```bash
./zig-out/bin/ccc --trace ./zig-out/riscv-tests/rv32mi/rv32mi-<name>-elf 2>&1 | tail -40
```

then compare the final register state against the test's expected sequence in `tests/riscv-tests/isa/rv32mi/<name>.S`.

If the failure is in Phase 1 scope, fix it in `src/` as a normal TDD cycle: add an inline Zig test reproducing the issue, see it fail, fix, confirm both the inline test and the rv32mi test pass.

If the failure exposes a deferred behavior (e.g., the test assumes the timer interrupt fires), exclude that specific test name from `rv32mi_tests` and document why in a comment.

- [ ] **Step 5: Commit**

```bash
git add build.zig
git commit -m "test: enable rv32mi-p-* in riscv-tests runner"
```

---

### Task 3: Add the Zig cross-compile target helper for the hello.elf build

**Files:**
- Modify: `build.zig` (factor the `rv_target` definition or reuse it — decision depends on current layout)

**Why this task:** The existing `build.zig` defines `rv_target` once inside the `=== riscv-tests helpers ===` section. The hello.elf build (Task 5) needs the same target. Rather than duplicate the resolve-query block or reach into a deep nested scope, hoist `rv_target` to be usable by both the rv-tests loop and the hello.elf build.

- [ ] **Step 1: Hoist `rv_target`**

Before the `=== riscv-tests helpers ===` section header comment, move the `rv_target` definition up to just below the existing `e2e_trap_step` section, guarded by its own section comment:

```zig
    // === Shared RV32 cross-compile target (used by hello.elf and riscv-tests) ===
    // Use generic_rv32 (explicit CPU model) so compressed (C) is OFF.
    // baseline_rv32 silently includes C, which breaks us: our decoder is
    // strictly 32-bit-wide. Plus M + A features.
    const rv_target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv32,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32 },
        .cpu_features_add = blk: {
            const features = std.Target.riscv.Feature;
            var set = std.Target.Cpu.Feature.Set.empty;
            set.addFeature(@intFromEnum(features.m));
            set.addFeature(@intFromEnum(features.a));
            break :blk set;
        },
    });
```

Delete the duplicate definition from inside the `=== riscv-tests helpers ===` section; leave the `RiscvTest` struct, `rv_link_script`, and `riscvTestStep` fn in place there.

- [ ] **Step 2: Verify the hoist didn't break anything**

```bash
zig build riscv-tests
```

Expected: exit 0. The target moved one level out; `riscvTestStep` still closes over the same `rv_target`.

- [ ] **Step 3: Commit**

```bash
git add build.zig
git commit -m "refactor: hoist rv_target out of riscv-tests section for reuse"
```

---

### Task 4: Write the M-mode monitor (`tests/programs/hello/monitor.S`)

**Files:**
- Create: `tests/programs/hello/monitor.S`

**Why this task:** The monitor is the ELF's entry point. Everything after depends on it (the Zig U-mode payload is called *from* the monitor's `mret`; the linker script places the monitor first; the e2e test asserts the output the monitor produces).

- [ ] **Step 1: Author `tests/programs/hello/monitor.S`**

```asm
# Phase 1 M-mode monitor for hello.elf.
# Entry point `_start`, trap handler `trap_vector`, syscall dispatch by a7:
#   a7 == 64  (write) : for fd in {1,2}, copy a2 bytes from *a1 to UART THR.
#   a7 == 93  (exit)  : store low byte of a0 to halt MMIO (exit code).
#   otherwise         : return a0 = -ENOSYS (-38).
#
# Register conventions (RISC-V ABI):
#   sp  = x2   a0..a7 = x10..x17   t0..t6 = x5..x7,x28..x31
#
# MMIO addresses (spec §Memory layout):
#   UART THR  = 0x10000000
#   Halt MMIO = 0x00100000
#
# Stack layout: `_stack_top` symbol comes from linker.ld; monitor loads it
# into sp before doing anything that might need a stack. The U-mode payload
# is naked asm and never touches sp.

.section .text.init, "ax", @progbits
.globl _start
_start:
    # Initialise stack pointer.
    la      sp, _stack_top

    # Install the trap vector (mtvec = &trap_vector).
    la      t0, trap_vector
    csrw    mtvec, t0

    # Clear mstatus.MPP (bits 12:11): MPP = 00 = U-mode.
    # Also clear MIE (bit 3) and MPIE (bit 7). Phase 1 has no interrupts
    # delivered, so leaving MIE=0 is the honest state.
    li      t0, 0x1888                   # MIE | MPIE | MPP_MASK
    csrc    mstatus, t0

    # mepc <- U-mode entry symbol (provided by hello.zig).
    la      t0, u_entry
    csrw    mepc, t0

    # Drop to U-mode and branch to mepc.
    mret

# ---- Trap vector (M-mode) -----------------------------------------------
# Must be 4-byte aligned (direct mode, Phase 1 ignores mtvec.MODE).
.balign 4
.globl trap_vector
trap_vector:
    # Only ecall_from_u is handled; anything else hangs. We do NOT save
    # callee-saved registers because the Phase 1 U-mode payload doesn't
    # care about them either — it's naked asm that makes ecalls and halts.
    csrr    t0, mcause
    li      t1, 8                        # cause = ecall_from_u
    bne     t0, t1, unexpected_trap

    # Dispatch by a7.
    li      t0, 64
    beq     a7, t0, sys_write
    li      t0, 93
    beq     a7, t0, sys_exit

    # Unknown syscall: a0 <- -ENOSYS (-38). Then fall through to mret_resume.
    li      a0, -38
    j       mret_resume

# ---- sys_write(fd=a0, buf=a1, len=a2) -> a0 = len ----------------------
sys_write:
    # Only fd in {1,2} is supported (stdout, stderr). Phase 1's UART is
    # the same device regardless.
    li      t0, 2
    bgtu    a0, t0, sys_write_bad_fd
    beqz    a0, sys_write_bad_fd
    # Save the original length so we can return it.
    mv      t2, a2
    # t0 <- UART THR (0x10000000).
    li      t0, 0x10000000
    beqz    a2, sys_write_done
1:  lbu     t1, 0(a1)
    sb      t1, 0(t0)
    addi    a1, a1, 1
    addi    a2, a2, -1
    bnez    a2, 1b
sys_write_done:
    mv      a0, t2
    j       mret_resume
sys_write_bad_fd:
    li      a0, -9                        # -EBADF
    j       mret_resume

# ---- sys_exit(status=a0) -----------------------------------------------
sys_exit:
    # Halt MMIO: store low byte of a0 → emulator exits with that byte.
    li      t0, 0x00100000
    sb      a0, 0(t0)
    # Should be unreachable; if halt didn't fire (shouldn't happen), spin.
1:  j       1b

# ---- Advance mepc past the 4-byte ecall and return. --------------------
mret_resume:
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0
    mret

# ---- Unexpected trap: hang. --------------------------------------------
unexpected_trap:
1:  j       1b
```

Notes on correctness, worth keeping in the source as comments:

- `la sp, _stack_top` assembles to `auipc` + `addi` under PIC and `lui` + `addi` under absolute — either works with our linker.ld; the PIC version is what `generic_rv32` defaults to and is what we test with.
- `csrc mstatus, t0` (CSR Clear bits) clears only the bits set in t0 and leaves the rest alone. MPP=00 after the clear because t0 had MPP_MASK set.
- We do *not* clear MPIE; after `mret`, MPIE is forced to 1 (spec §Trap exit), so its value before mret is irrelevant.
- Syscall numbers match the Linux RISC-V ABI subset (`__NR_write=64`, `__NR_exit=93`). This matches what a Zig program compiled with inline ecall would naturally use.
- The `bgtu`/`beqz` fd checks mean `fd == 0` (stdin) returns -EBADF rather than silently writing to UART. Not strictly required by the hello-world demo, but it's a cheap correctness detail.

- [ ] **Step 2: Sanity-check assembly syntax**

Run the full `zig build test` — it should still pass (we haven't wired the monitor into any build rule yet; this is just verifying no syntax fallout from editing build.zig in earlier tasks).

```bash
zig build test
```

Expected: all unit tests still pass (as before).

- [ ] **Step 3: Commit**

```bash
git add tests/programs/hello/monitor.S
git commit -m "feat: hello.elf M-mode monitor (ecall write/exit dispatch)"
```

---

### Task 5: Write the Zig U-mode payload (`tests/programs/hello/hello.zig`) and linker script

**Files:**
- Create: `tests/programs/hello/hello.zig`
- Create: `tests/programs/hello/linker.ld`

**Why this task:** The monitor will `mret` to `u_entry`, which is defined here. The linker script names `_stack_top` (referenced by the monitor) and places `.text.init`, `.text.umode`, and `.rodata.umode` in the right order.

- [ ] **Step 1: Author `tests/programs/hello/hello.zig`**

```zig
// Phase 1 U-mode payload for hello.elf.
// Compiled as a Zig object (no main, no _start — the monitor's _start runs first).
// `u_entry` is the post-mret target the monitor installs in mepc.

const MSG: []const u8 = "hello world\n";

// Place the message in .rodata.umode so the linker script can position it
// distinctly from the monitor's .rodata (if any).
export const msg linksection(".rodata.umode") = [_]u8{
    'h', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', '\n',
};

comptime {
    // Size invariant: the inline asm below passes a2=12 as the length, so
    // `msg` MUST be exactly MSG.len bytes. If someone edits MSG, this fires.
    if (MSG.len != 12) @compileError("MSG must be 12 bytes for the inline ecall");
}

// U-mode entry. Naked: no prologue/epilogue, no stack use.
// Syscall ABI (matches Linux RISC-V subset implemented by monitor.S):
//   a7 = syscall number; a0..a2 = args; ecall; a0 = return value.
//   write (64): a0=fd, a1=buf, a2=len → a0=len-written
//   exit  (93): a0=status → no return (monitor halts the emulator)
export fn u_entry() linksection(".text.umode") callconv(.Naked) noreturn {
    asm volatile (
        \\ # write(1, msg, 12)
        \\ li   a7, 64
        \\ li   a0, 1
        \\ la   a1, msg
        \\ li   a2, 12
        \\ ecall
        \\ # exit(0)
        \\ li   a7, 93
        \\ li   a0, 0
        \\ ecall
        \\ # exit should have halted the emulator; safety loop.
        \\1:
        \\ j    1b
        :
        :
        : "memory"
    );
}
```

Notes on why this compiles to something sensible:

- `export const msg` with `linksection(".rodata.umode")` forces the compiler to emit the bytes into the named section (the linker script picks them up). Declaring as `[_]u8{...}` rather than `[12]u8` lets the compiler infer the length.
- `callconv(.Naked)` skips the function prologue/epilogue so no stack adjustment happens — we don't have (and don't need) a valid sp for `u_entry` beyond what the monitor installed, but even that is untouched here because we never push/pop.
- `la a1, msg` assembles to `auipc a1, %pcrel_hi(msg)` + `addi a1, a1, %pcrel_lo(.-4)`, which works with any position of `u_entry` and `msg` as long as they're within ±2 GiB — trivially true in Phase 1's 128 MB RAM.
- `noreturn` plus the trailing `1: j 1b` keeps Zig from inserting an implicit `ret` after the asm.
- The `"memory"` clobber is a conservative hint; nothing else in hello.zig would care, but it's cheap and correct.

- [ ] **Step 2: Author `tests/programs/hello/linker.ld`**

```ld
/* Linker script for hello.elf.
 *
 * Layout (addresses are 32-bit physical):
 *   0x80000000  .text.init    (monitor: _start, trap_vector)
 *               .text.umode   (Zig U-mode code: u_entry)
 *               .rodata.umode (Zig U-mode data: msg)
 *               .bss           (nothing in Phase 1, kept for future)
 *   ...8 KB gap for stack...
 *   _stack_top = ALIGN(16) after .bss end + 0x2000
 *
 * The monitor loads `sp` from _stack_top before mret. Phase 1 has no
 * process scheduling, so one 8 KB stack is all we need.
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128M
}

SECTIONS {
    . = 0x80000000;

    .text.init : {
        KEEP(*(.text.init))
    } > RAM

    .text.umode : {
        *(.text.umode)
        *(.text.umode.*)
    } > RAM

    .rodata.umode : {
        *(.rodata.umode)
        *(.rodata.umode.*)
    } > RAM

    /* Catch-all for any Zig-emitted sections we forgot to place explicitly.
     * The Zig compiler may emit .rodata, .data, .bss for strings, globals,
     * etc.  For hello.zig the only non-u_entry symbol is `msg`, which we
     * placed explicitly with linksection; the catch-alls are defence in
     * depth against future edits. */
    .text    : { *(.text .text.*) } > RAM
    .rodata  : { *(.rodata .rodata.*) } > RAM
    .data    : { *(.data .data.*) } > RAM

    .bss : {
        _bss_start = .;
        *(.bss .bss.*)
        _bss_end = .;
    } > RAM

    /* 8 KB stack above all loaded sections, 16-byte aligned. */
    . = ALIGN(16);
    . = . + 0x2000;
    _stack_top = .;

    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.eh_frame)
        *(.riscv.attributes)
    }
}
```

Notes:

- `KEEP(*(.text.init))` stops the linker from garbage-collecting the monitor even if no call-graph edge reaches it from the entry (the entry literally IS `_start`, which lives in `.text.init`, so `KEEP` is belt-and-braces).
- `ENTRY(_start)` makes `_start` the ELF header's `e_entry`. When we run `ccc hello.elf`, the ELF loader sets PC=`e_entry`, which lands at the monitor's `_start` — exactly what we want.
- We put `.text.umode` and `.rodata.umode` *before* the catch-all `.text`/`.rodata` so Zig-emitted `u_entry` and `msg` end up in the named sections. (The compiler emits them into `.text.umode`/`.rodata.umode` because of `linksection`; the catch-alls sweep up anything else.)
- `/DISCARD/` drops RISC-V attribute sections that confuse some tools; not strictly needed for our emulator (which only reads `PT_LOAD` segments) but keeps the ELF clean for QEMU and `objdump -d`.
- `.bss` carries `_bss_start` / `_bss_end` symbols that future kernel code will zero in a tight loop. Phase 1 hello.elf has no .bss, so the loop is a no-op; we keep the symbols so the linker script is stable for Phase 2.

- [ ] **Step 3: Commit**

```bash
git add tests/programs/hello/hello.zig tests/programs/hello/linker.ld
git commit -m "feat: hello.zig U-mode payload + linker script"
```

---

### Task 6: Wire `zig build hello-elf` + `zig build e2e-hello-elf`

**Files:**
- Modify: `build.zig` (add the hello-elf build graph + e2e step)

**Why this task:** This is the build-graph node that binds the monitor, the Zig payload, and the linker script into an ELF and verifies the emulator prints "hello world".

- [ ] **Step 1: Add the hello.elf build section**

Insert after the `e2e_trap_step` section in `build.zig` (before the `=== Shared RV32 cross-compile target ===` comment added in Task 3):

```zig
    // === Zig-compiled hello.elf (Plan 1.D — Phase 1 §Definition of done) ===
    // Two-object link: monitor.S provides _start + trap_vector (M-mode);
    // hello.zig provides u_entry + msg (U-mode). linker.ld places .text.init
    // at 0x80000000 and defines _stack_top.
    const hello_monitor_obj = b.addObject(.{
        .name = "hello-monitor",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
        }),
    });
    hello_monitor_obj.root_module.addAssemblyFile(b.path("tests/programs/hello/monitor.S"));

    const hello_umode_obj = b.addObject(.{
        .name = "hello-umode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/hello/hello.zig"),
            .target = rv_target,
            .optimize = .ReleaseSmall,
            // Keep the Zig compiler from stripping u_entry / msg as "unused".
            .strip = false,
            .single_threaded = true,
        }),
    });

    const hello_elf = b.addExecutable(.{
        .name = "hello.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    hello_elf.root_module.addObject(hello_monitor_obj);
    hello_elf.root_module.addObject(hello_umode_obj);
    hello_elf.setLinkerScript(b.path("tests/programs/hello/linker.ld"));
    hello_elf.entry = .{ .symbol_name = "_start" };

    const install_hello_elf = b.addInstallArtifact(hello_elf, .{});
    const hello_elf_step = b.step("hello-elf", "Build the Zig-compiled hello.elf (Phase 1 §Definition of done)");
    hello_elf_step.dependOn(&install_hello_elf.step);

    // End-to-end: run our emulator against hello.elf and assert UART output.
    const e2e_hello_elf_run = b.addRunArtifact(exe);
    e2e_hello_elf_run.addFileArg(hello_elf.getEmittedBin());
    e2e_hello_elf_run.expectStdOutEqual("hello world\n");

    const e2e_hello_elf_step = b.step("e2e-hello-elf", "Run the Phase 1 §Definition of done demo (ccc hello.elf)");
    e2e_hello_elf_step.dependOn(&e2e_hello_elf_run.step);
```

- [ ] **Step 2: Build and verify**

```bash
zig build hello-elf
ls -la zig-out/bin/hello.elf
zig build e2e-hello-elf
```

Expected: `zig build hello-elf` produces `zig-out/bin/hello.elf`. `zig build e2e-hello-elf` passes (stdout equals `"hello world\n"`).

- [ ] **Step 3: If the e2e step fails, diagnose**

Common failure modes and recovery:

| Symptom | Likely cause | Fix |
|---|---|---|
| `ELF load failed: NotExecutable` | `e_type != ET_EXEC` — usually because linker produced ET_DYN | Add `-static` / check LDFLAGS; confirm ELF header with `xxd zig-out/bin/hello.elf | head -2` (byte 0x10: `02 00` = ET_EXEC) |
| `emulator stopped: UnreachableTrap` | Monitor's `_start` not reached, or `mtvec=0` when trap fires | Run with `--trace --halt-on-trap` and inspect first few PC values; check linker.ld places `.text.init` at `0x80000000` |
| Stdout empty or partial | `u_entry` reached but `la a1, msg` resolved to 0 (msg unplaced) | Check `llvm-readelf -s zig-out/bin/hello.elf | grep msg` — its st_value should be inside `.rodata.umode`, i.e., near the end of `.text.*` |
| Stdout prints garbage bytes | Length mismatch; a2 != 12 or msg contents wrong | `llvm-objdump -s -j .rodata.umode zig-out/bin/hello.elf` should show `68 65 6c 6c 6f 20 77 6f 72 6c 64 0a` |
| Emulator doesn't halt, loops forever | exit syscall not dispatched; check `a7=93` path in monitor | Compare trace to monitor.S line by line |

Reach for `./zig-out/bin/ccc --trace --halt-on-trap zig-out/bin/hello.elf 2>trace.log` and walk the first 30 lines of `trace.log`.

- [ ] **Step 4: Commit**

```bash
git add build.zig
git commit -m "feat: zig build hello-elf + e2e-hello-elf (Phase 1 DOD demo)"
```

---

### Task 7: Refresh `tests/programs/hello/README.md`

**Files:**
- Modify: `tests/programs/hello/README.md`

**Why this task:** The hello directory now contains two flows (the Plan 1.A raw demo and the Plan 1.D ELF demo). Readers need to understand both without spelunking through `build.zig`.

- [ ] **Step 1: Rewrite the README**

```markdown
# hello — the Phase 1 "hello world" demos

Two flavours of hello-world live in this directory:

## 1. `hello.bin` — hand-crafted raw binary (Plan 1.A)

`encode_hello.zig` is a host Zig program that emits a raw RV32I binary
implementing a minimal boot loop: UART-write each byte of `"hello world\n"`,
then write to the halt MMIO. No privilege switches, no ELF, no monitor.

```
zig build hello           # produces zig-out/bin/hello.bin
zig build e2e             # runs it through ccc and asserts output
```

This is the Plan 1.A end-to-end test. It exercises RV32I + UART + halt MMIO
and nothing else.

## 2. `hello.elf` — cross-compiled Zig + M-mode monitor (Plan 1.D)

The Phase 1 §Definition of done demo. Exercises the whole emulator:

- ELF32 loader (Plan 1.C): parses `hello.elf` and sets `PC ← e_entry`.
- `monitor.S`: M-mode entry (`_start`) sets `sp`, installs `mtvec`, clears
  `mstatus.MPP` (so post-mret privilege = U), sets `mepc = u_entry`, `mret`s.
- `hello.zig`: U-mode naked function does `write(1, msg, 12)` via ecall (a7=64),
  then `exit(0)` via ecall (a7=93).
- `monitor.S` trap handler: catches both ecalls. `sys_write` copies bytes from
  `*a1` to UART THR. `sys_exit` writes to the halt MMIO.
- Halt MMIO: emulator exits with code `a0`.

Build & run:

```
zig build hello-elf       # produces zig-out/bin/hello.elf
zig build e2e-hello-elf   # runs it through ccc and asserts "hello world\n"
```

Run manually with tracing:

```
./zig-out/bin/ccc --trace zig-out/bin/hello.elf 2>trace.log
head -20 trace.log
```

## Files

| File | Purpose |
|---|---|
| `encode_hello.zig` | Plan 1.A host encoder → hello.bin |
| `monitor.S` | Plan 1.D M-mode trap monitor |
| `hello.zig` | Plan 1.D U-mode payload (naked, inline-asm ecalls) |
| `linker.ld` | Plan 1.D linker script (places .text.init at 0x80000000) |
```

- [ ] **Step 2: Commit**

```bash
git add tests/programs/hello/README.md
git commit -m "docs: hello README covers both raw (1.A) and ELF (1.D) flows"
```

---

### Task 8: QEMU-diff harness (`scripts/qemu-diff.sh`)

**Files:**
- Create: `scripts/qemu-diff.sh`
- Create: `scripts/README.md` (if scripts/ didn't already have one)

**Why this task:** The QEMU-diff harness is the debug tool we reach for when a riscv-test or a future kernel image does something weird inside our emulator. It's intentionally *not* part of CI — it depends on QEMU being installed, and trace canonicalization is fragile. Documenting it as a standalone bash script keeps it loosely coupled.

- [ ] **Step 1: Author `scripts/qemu-diff.sh`**

```bash
#!/usr/bin/env bash
# qemu-diff.sh — diff per-instruction traces from our emulator and QEMU.
#
# Usage: scripts/qemu-diff.sh <file.elf> [max-instructions]
#
# Dependencies:
#   - qemu-system-riscv32 (brew install qemu / apt install qemu-system-misc)
#   - zig (already required for the project)
#
# Output:
#   stdout = nothing if traces match up to max-instructions
#   stderr = diagnostic info; exit 1 on divergence (with diff output)

set -euo pipefail

ELF="${1:-}"
MAX="${2:-1000}"

if [[ -z "$ELF" ]]; then
    echo "usage: $0 <file.elf> [max-instructions]" >&2
    exit 2
fi

if [[ ! -f "$ELF" ]]; then
    echo "error: $ELF not found" >&2
    exit 2
fi

if ! command -v qemu-system-riscv32 >/dev/null 2>&1; then
    echo "error: qemu-system-riscv32 not found on PATH" >&2
    echo "       macOS: brew install qemu" >&2
    echo "       Linux: apt install qemu-system-misc (or equivalent)" >&2
    exit 2
fi

# Build the emulator if needed.
if [[ ! -x ./zig-out/bin/ccc ]]; then
    echo "building ccc..." >&2
    zig build
fi

TMPDIR_="$(mktemp -d -t ccc-qemu-diff.XXXXXX)"
trap 'rm -rf "$TMPDIR_"' EXIT

QEMU_RAW="$TMPDIR_/qemu.raw"
CCC_RAW="$TMPDIR_/ccc.raw"
QEMU_CANON="$TMPDIR_/qemu.canon"
CCC_CANON="$TMPDIR_/ccc.canon"

echo "running under qemu-system-riscv32..." >&2
# QEMU's -d in_asm logs the instruction as it's decoded; -d cpu logs register
# state after each instruction. -singlestep forces one TB per instruction so
# the logs line up. 2>&1 redirects the trace (QEMU writes it to stderr).
timeout 30 qemu-system-riscv32 \
    -machine virt \
    -bios none \
    -kernel "$ELF" \
    -nographic \
    -singlestep \
    -d in_asm,cpu \
    -D "$QEMU_RAW" \
    -no-reboot \
    > /dev/null 2>&1 || true    # ignore exit status — halt MMIO causes QEMU to error

echo "running under ccc --trace..." >&2
./zig-out/bin/ccc --trace "$ELF" 2>"$CCC_RAW" >/dev/null || true

# --- Canonicalize ---
# QEMU's `-d in_asm` lines look like:
#   ----------------
#   IN:
#   0x80000000:  00000297          auipc           t0,0
# and `-d cpu` prints a big multi-line block with pc=... x1/ra ... x31/t6.
# Our emulator prints one line per step:
#   80000000  auipc t0, 0x0          x5  := 0x80000000
# We reduce each trace to:
#   PC  op     (one line per instruction, op = mnemonic word)
# which is the cheapest comparison that still catches divergence.

canon_qemu() {
    grep -E '^0x[0-9a-fA-F]+: ' "$1" \
        | head -n "$MAX" \
        | awk '{
            pc = substr($1, 3, length($1)-3);        # strip "0x" and ":"
            printf "%08x %s\n", strtonum("0x"pc), $3;
          }'
}

canon_ccc() {
    head -n "$MAX" "$1" \
        | awk '{ printf "%s %s\n", $1, $2 }'
}

canon_qemu "$QEMU_RAW" > "$QEMU_CANON"
canon_ccc  "$CCC_RAW"  > "$CCC_CANON"

QEMU_LINES=$(wc -l < "$QEMU_CANON")
CCC_LINES=$(wc -l < "$CCC_CANON")
echo "qemu traced $QEMU_LINES instructions; ccc traced $CCC_LINES" >&2

if diff -u "$QEMU_CANON" "$CCC_CANON" > "$TMPDIR_/diff" ; then
    echo "OK: traces match over $QEMU_LINES instructions" >&2
    exit 0
fi

echo "DIVERGENCE:" >&2
cat "$TMPDIR_/diff"
exit 1
```

Permissions: `chmod +x scripts/qemu-diff.sh`.

Notes on the canonicalization:

- QEMU's `-d in_asm` output format is stable across versions since at least QEMU 6.x; the `0xPPPPPPPP: HHHHHHHH  MNEMONIC operands...` shape hasn't changed.
- Our emulator's trace format lives in `src/trace.zig` (`formatInstr`) and also uses `PC  op ...` as the leading columns, so the same `awk '{print $1, $2}'` canonicalizes both.
- Full register-state comparison (the deepest form of diff) is *not* performed here — it would require mapping QEMU's `x10/a0=...` → our `x10  := ...` format. First-divergence-by-PC is usually enough to locate the bug; if it isn't, extend the canonicalizer.
- `timeout 30` keeps a bug where QEMU hangs from wedging the harness. `|| true` ignores its exit code because QEMU doesn't understand our halt MMIO (write to `0x00100000`), which causes it to error after printing the trace.

- [ ] **Step 2: Author `scripts/README.md`**

```markdown
# scripts/

Debug and development scripts. None of these run in CI.

## `qemu-diff.sh`

Compare per-instruction execution of an ELF in QEMU vs. our emulator. First
divergence is almost always the bug.

Requirements: `qemu-system-riscv32` on PATH (`brew install qemu` or
`apt install qemu-system-misc`).

```
scripts/qemu-diff.sh zig-out/bin/hello.elf
scripts/qemu-diff.sh zig-out/bin/hello.elf 500      # compare 500 instructions
```

Exit code 0 = traces match over requested instruction count.
Exit code 1 = divergence; diff printed to stdout.
Exit code 2 = usage / environment error.
```

- [ ] **Step 3: Try the harness against a known-good ELF**

```bash
zig build hello-elf
scripts/qemu-diff.sh zig-out/bin/hello.elf 100
```

Expected: "OK: traces match over N instructions" for some N up to 100.

If the traces diverge, that's a legitimate emulator bug. Fix it as a TDD cycle (add a Zig unit test reproducing the divergence first, then fix, then re-run the harness).

If the traces match perfectly, great — commit. If the canonicalization is too aggressive (e.g., it treats different operand syntaxes as a match), that's fine for Phase 1 diagnostics; the harness is a tool, not a strict equivalence proof.

- [ ] **Step 4: Commit**

```bash
chmod +x scripts/qemu-diff.sh
git add scripts/
git commit -m "feat: qemu-diff.sh debug harness"
```

---

### Task 9: README status + build-target updates

**Files:**
- Modify: `README.md`

**Why this task:** The README is the single most visible source of project status. Once Plan 1.D is merged, the status line should say "Phase 1 complete", the build-targets table should list the new `hello-elf` / `e2e-hello-elf` steps, and the "Currently on" sentence in §Status should point to Phase 2.

- [ ] **Step 1: Update the build-targets table**

In `README.md`, find the `zig build fixtures` row and add two rows *above* the riscv-tests row:

```
| `zig build hello-elf` | Build the Zig-compiled `hello.elf` (monitor + U-mode hello) |
| `zig build e2e-hello-elf` | Run `ccc hello.elf` and assert stdout equals `hello world\n` (Phase 1 §Definition of done) |
| `zig build fixtures` | Build `tests/fixtures/minimal.elf` (used only by `src/elf.zig` tests) |
| `zig build riscv-tests` | Assemble + link + run the official `rv32ui/um/ua/mi-p-*` conformance suite (66 tests) |
```

(Update the existing `riscv-tests` row to read 66 tests — `rv32ui` 39 + `rv32um` 8 + `rv32ua` 10 + `rv32mi` 9 = 66 — and mention `mi` alongside `ui/um/ua`.)

- [ ] **Step 2: Update the §Status section**

Replace the current §Status paragraph with:

```markdown
## Status

**Phase 1 — RISC-V CPU emulator — complete.**

Phase 1 delivered: RV32I + M + A + Zicsr + Zifencei; M-mode + U-mode
privilege + synchronous trap handling; NS16550A UART; CLINT timer
registers; 128 MB RAM; ELF32 loader; `--trace`/`--halt-on-trap`/`--memory`
flags; `rv32ui/um/ua/mi-p-*` riscv-tests (66 tests, all green); Zig
cross-compiled `hello.elf` with an M-mode trap monitor; QEMU-diff
debug harness.

The Phase 1 §Definition of done demo:

    $ zig build e2e-hello-elf
    # passes: stdout equals "hello world\n"
    $ zig build run -- zig-out/bin/hello.elf
    hello world

Next: **Phase 2 — Bare-metal kernel** (S-mode, Sv32 page tables,
M↔S↔U privilege transitions, timer interrupt delivery).
```

- [ ] **Step 3: Update §Running programs to mention `hello.elf`**

Replace the first paragraph of §Running programs:

```markdown
## Running programs

By default `ccc` loads an ELF32 RISC-V executable:

    zig build hello-elf                          # build hello.elf first
    zig build run -- zig-out/bin/hello.elf       # prints "hello world"

For hand-crafted raw binaries (the `e2e`, `e2e-mul`, `e2e-trap` demos),
pass the load address with `--raw`:

    zig build run -- --raw 0x80000000 path/to/program.bin
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: README reflects Phase 1 complete (hello.elf + rv32mi green)"
```

---

### Task 10: Final Phase 1 §Definition of done verification

**Files:** none (this is a verification task)

**Why this task:** Before declaring Phase 1 complete, walk through the spec's §Definition of done bullets one-by-one and confirm each is demonstrable from a clean checkout.

- [ ] **Step 1: Clean build + run each DOD demo**

```bash
rm -rf .zig-cache zig-out
zig build test                   # all unit tests pass
zig build e2e                    # Plan 1.A raw hello
zig build e2e-mul                # Plan 1.B raw mul demo
zig build e2e-trap               # Plan 1.C raw trap demo
zig build riscv-tests            # Plan 1.C + 1.D riscv-tests (rv32ui/um/ua/mi)
zig build hello-elf              # Plan 1.D hello.elf
zig build e2e-hello-elf          # Plan 1.D end-to-end DOD demo
zig build run -- --trace zig-out/bin/hello.elf 2>trace.log
wc -l trace.log                  # should be dozens of lines
head -5 trace.log                # should start with _start at 0x80000000
```

Check each step exits 0 and the trace looks reasonable.

- [ ] **Step 2: Walk the spec §Definition of done checklist**

From `docs/superpowers/specs/2026-04-23-phase1-cpu-emulator-design.md`:

> - `ccc hello.elf` prints `hello world\n` to host stdout. ← ✅ `zig build e2e-hello-elf`
> - The emulator passes the relevant subset of the official `riscv-tests` suite (rv32ui, rv32um, rv32ua, rv32mi). ← ✅ `zig build riscv-tests` (66 tests)
> - The same `hello.elf` runs in both our emulator and QEMU `riscv32 virt` and produces identical UART output. ← ✅ via `scripts/qemu-diff.sh zig-out/bin/hello.elf` (sanity check; not in CI)
> - An instruction trace (`--trace`) prints one line per executed instruction. ← ✅ Plan 1.C §Task 13

All bullets satisfied.

- [ ] **Step 3: Commit the plan document itself (if not already)**

Plan 1.D has been authored as part of this work; make sure the plan file is committed alongside the implementation.

```bash
git add docs/superpowers/plans/2026-04-24-phase1-plan-d-monitor-hello-elf-qemu-diff.md
git commit -m "docs: Plan 1.D — monitor + hello.elf + QEMU-diff + rv32mi"
```

(If the plan was committed earlier in the task sequence, skip this step.)

- [ ] **Step 4: Final CI-like check from scratch**

```bash
git status                       # clean
rm -rf .zig-cache zig-out
zig build test
zig build e2e && zig build e2e-mul && zig build e2e-trap && zig build e2e-hello-elf
zig build riscv-tests
```

Expected: all steps exit 0. Phase 1 shipped.

---

## Closing note

Plan 1.D converts a working-but-incomplete Phase 1 emulator (Plan 1.A/B/C) into one that matches the spec's §Definition of done verbatim. The delta is small but load-bearing: the Zig `hello.elf` is the first artifact built with the cross-compiler toolchain this project will depend on for the rest of its life (Phase 2 kernel, Phase 3 user programs, Phase 5 browser), and the QEMU-diff harness is the debugging tool we'll reach for every time a workload misbehaves. Getting both right now pays dividends for the next 10+ months of work.

After Plan 1.D merges: **Phase 1 is done. Begin brainstorming Phase 2.**
