# rv32-cpu-and-decode: Code Cases

> Real artifacts from the `ccc` codebase that illustrate the CPU+decoder+executor topic. Each case names the actual files and tests so you can reproduce the run yourself.

---

### Case 1: `hello.elf` — the smallest end-to-end demo (Plan 1.D, 2026-04)

**Background**

`programs/hello/hello.zig` is the first ever Zig payload `ccc` runs. It's a tiny U-mode program that calls `write(1, "hello world\n", 12)` via an `ecall`. The build target `zig build hello-elf` produces `zig-out/bin/hello.elf` — about 10 KB. The Phase 1 §Definition of Done demo is one shell command:

```
$ zig build run -- zig-out/bin/hello.elf
hello world
```

**What happened**

When `ccc` loads `hello.elf`:

1. `src/emulator/elf.zig` parses the ELF header, finds the entry point (`0x80000000`), walks `PT_LOAD` segments, and copies them into RAM.
2. `Cpu.init(&memory, entry)` initializes regs to zero, PC to `0x80000000`, privilege to M.
3. `cpu.run()` starts the loop: fetch from `0x80000000`, decode, execute, repeat.
4. The first ~50 instructions are an M-mode monitor that sets up `mtvec`, drops to U via `mret`, and jumps to the Zig payload's `_start`.
5. `_start` calls `write` which is a `usys.S` stub: `li a7, 64; ecall; ret`.
6. The `ecall` decoded as `op=.ecall`, dispatched to the `ecall` arm, which calls `trap.enter(.env_call_from_u, pc, cpu)` — the trap handler in the M-mode monitor catches this, executes the syscall (write 12 bytes to the UART MMIO at `0x10000000`), then `mret`s back to `_start`.
7. `_start` calls `exit` (syscall #93). The monitor handles it by writing to the halt MMIO at `0x00100000`, which makes `cpu.run` return `Halt`.

**Relevance to rv32-cpu-and-decode**

This is the simplest possible exercise of every component: every kind of integer instruction, every encoding format, the privilege transition, the trap path, the memory-mapped I/O. If `decoder.zig` ever decodes anything wrong, `hello.elf` is the first test that breaks. The verifier `zig build e2e-hello-elf` asserts stdout equals `hello world\n` byte-for-byte.

**References**

- `programs/hello/hello.zig` (the user payload)
- `src/emulator/elf.zig` (the ELF loader)
- `tests/e2e/hello_elf.zig` (the verifier)
- `build.zig` build target `e2e-hello-elf`

---

### Case 2: The `mul_demo` walk — proving the M extension (Plan 1.B, 2026-04)

**Background**

`programs/mul_demo/encoder.zig` is a hand-crafted RV32IMA program that prints `42\n` using `mul`, `div`, `amoadd.w`, and `fence.i`. No ELF wrapper — it's raw bytes loaded with `--raw 0x80000000`.

**What happened**

The encoder builds a tiny program in memory:

```asm
addi a0, zero, 6           ; a0 = 6
addi a1, zero, 7           ; a1 = 7
mul  a0, a0, a1            ; a0 = 42
; ... write to UART, halt
```

`zig build e2e-mul` runs it and asserts stdout is `42\n`. This is `ccc`'s proof that `funct7 = 0x01` on opcode `0x33` correctly dispatches to the M-extension family in `decoder.zig`:

```zig
case 0x33: {
    if (f7 === 0x01) {
        const m = ['mul','mulh','mulhsu','mulhu','div','divu','rem','remu'][f3];
        ...
```

Without that arm, `mul` would decode as `add` (because `funct3 = 0` matches both, and only `funct7` distinguishes them). The test catches that the moment the build runs.

**Relevance to rv32-cpu-and-decode**

`mul_demo` is the regression-test floor for the M extension. It's also the first place `funct7`-based dispatch matters — a single bit in the instruction word changes which arm executes.

**References**

- `programs/mul_demo/encoder.zig`
- `tests/e2e/mul.zig`
- `build.zig` target `e2e-mul`

---

### Case 3: The LR/SC reservation-clear race (Plan 1.B / 1.C, 2026-04)

**Background**

The A-extension's `lr.w`/`sc.w` pair is the foundation for atomics. The spec says the reservation MUST be cleared on:
- successful or failing `sc.w`
- any trap (sync or async)
- (multi-hart cases that don't apply here)

If you forget the trap-clearing rule, a thread that's pre-empted between `lr.w` and `sc.w` could come back and find its reservation still set — a phantom-success bug. xv6 mailing-list lore from the early 2010s has examples.

**What happened**

`ccc/src/emulator/trap.zig` includes `cpu.reservation = null;` inside `trap.enter`. Without it, `riscv-tests rv32ua-p-amoswap_w` fails — the test deliberately traps in the middle of LR/SC sequences and expects no reservation to survive. There's a corresponding direct test in `cpu.zig`:

```zig
test "Cpu.init sets reservation to null" {
    var dummy_mem: Memory = undefined;
    const cpu = Cpu.init(&dummy_mem, 0);
    try std.testing.expect(cpu.reservation == null);
}
```

The test is small but the rule it pins is critical for any future kernel-side spinlock implementation.

**Relevance to rv32-cpu-and-decode**

The CPU's `reservation: ?u32` field looks innocuous, but its lifecycle (set on `lr.w`, cleared on `sc.w`/trap) is a tiny piece of state with disproportionate spec impact.

**References**

- `src/emulator/cpu.zig` (lines around `reservation`, plus the `trap` clearing)
- `tests/riscv-tests/rv32ua-p-amoswap_w.S` (upstream conformance)
- `build.zig` target `riscv-tests`

---

### Case 4: The rv32mi conformance suite — 67 tests at once (Plan 1.D, 2026-04)

**Background**

`riscv-software-src/riscv-tests` is the official RISC-V conformance suite. `ccc` includes it as a git submodule at `tests/riscv-tests/`. The build target `zig build riscv-tests` assembles, links, and runs **67 tests** across the `rv32ui`, `rv32um`, `rv32ua`, `rv32mi`, `rv32si` families.

**What happened**

Each test is a tiny assembly program that exercises one ISA feature:
- `rv32ui-p-add` — 38 add-ops including signed/unsigned overflow.
- `rv32mi-p-csr` — every CSR reachable from M with every legal op (`csrrw`/`csrrs`/`csrrc`/`csrrwi`/`csrrsi`/`csrrci`).
- `rv32mi-p-illegal` — illegal instructions trap with `mcause = 2`.
- `rv32ua-p-lrsc` — LR/SC pairs with intermixed traps.

Pass/fail is binary — the test writes to a "tohost" MMIO address. Pass writes 1, fail writes a non-zero error code. `ccc`'s `elf.zig` resolves the `tohost` symbol from the ELF symbol table; `memory.zig` watches stores to that address and reports the result.

When Plan 1.D started, ~5 of the 67 tests failed. Most failures were `mscratch` (the spec doesn't *require* it but the suite assumes it; we added storage). One was a `csrrsi`/`csrrci` immediate-encoding mistake — `rs1` for these ops is an unsigned immediate, not a register, and the early decoder treated it as a register read. After the fix, all 67 pass on every CI run.

**Relevance to rv32-cpu-and-decode**

The conformance suite is the *real* check that the decoder + executor matches the spec. Reading our own tests is necessary but not sufficient — the upstream suite covers corners we'd never have thought of.

**References**

- `tests/riscv-tests/` (upstream submodule)
- `tests/riscv-tests-shim/` (weak handlers + `riscv_test.h` overrides for `tohost`/`fromhost`)
- `build.zig` target `riscv-tests`
- The 67 test names: `find tests/riscv-tests/isa -name 'rv32*-p-*' | wc -l`

---

### Case 5: `--trace` output reading like assembly with a state delta (Plan 1.C, 2026-04)

**Background**

`--trace` makes `ccc` emit one line per executed instruction to stderr. It's the single most useful debugging aid in the codebase.

**What happened**

A line looks like:

```
[M] 0x80000000 02a00513 addi a0, zero, 42 → a0=0x0000002a
```

Field by field:
- `[M]` — current privilege when the instruction was fetched.
- `0x80000000` — the PC where it was fetched.
- `02a00513` — the raw 32-bit word.
- `addi a0, zero, 42` — the disassembly produced from the `Instruction` record.
- `→ a0=0x0000002a` — what changed in the destination register (only if `rd != 0`).

`src/emulator/trace.zig` formats the line in `formatInstr`. It reads `pre_priv`, `pre_pc`, `instr`, `pre_rd`, `post_rd`, and `post_pc` — the values *before* the dispatch and *after*. The trace doesn't include async events inline; those get separate marker lines:

```
--- interrupt 7 (machine timer) taken in U, now M ---
--- block: read sector 17 at PA 0x80100000 ---
```

The PR that landed `--trace` ([commit `9ab4f15` or so](https://github.com/cyyeh/ccc), Plan 1.C) reduced the time-to-diagnose for any new ISA bug from "stare at memory dumps for hours" to "grep stderr for the wrong instruction."

**Relevance to rv32-cpu-and-decode**

`--trace` is an instrumentation hook into `step()`. It runs *after* dispatch, so it can compare pre/post state. The `pre_rd` capture in `cpu.step` is the only pre-state read for tracing — everything else (PC change, trap takes) is recoverable from `post`.

**References**

- `src/emulator/trace.zig`
- `src/emulator/cpu.zig` (the `if (self.trace_writer) |tw| ...` block)
- The `--trace` flag handling in `src/emulator/main.zig`

---

### Case 6: The wasm `step_mode` escape hatch (Plan 1.D / Phase 3 web demo)

**Background**

When `ccc` cross-compiles to `wasm32-freestanding` for the browser demo (`zig build wasm`), the same `Cpu.step()` loop must run inside a Web Worker. But `wfi` would block the worker thread for up to 10 seconds — making the page unresponsive every time the guest goes idle.

**What happened**

`Cpu.step_mode: bool` was added. When `Cpu.stepOne()` is called (the chunked-runner path), it sets `step_mode = true` for the duration of one step:

```zig
pub fn stepOne(self: *Cpu) StepError!void {
    self.step_mode = true;
    defer self.step_mode = false;
    ...
}
```

`idleSpin` checks the flag at its top:

```zig
pub fn idleSpin(self: *Cpu) void {
    if (self.step_mode) return;  // wasm escape
    ...
}
```

So `wfi` becomes a no-op in chunked mode. The chunked runner schedules the next batch via `setTimeout(0)`, yielding to the JS event loop between batches.

This is a tiny code change (5 lines total) but it turns a hangs-the-tab bug into a working browser demo.

**Relevance to rv32-cpu-and-decode**

`step()` and `idleSpin` are the only places this path branches; the dispatch arms don't know they're running in a browser. Clean abstraction lets one Zig core ship to two very different environments.

**References**

- `src/emulator/cpu.zig` `stepOne` + `idleSpin`
- `demo/web_main.zig` (the wasm entry point that calls `stepOne`)
- `web/runner.js` (the JS that orchestrates the chunked loop)
