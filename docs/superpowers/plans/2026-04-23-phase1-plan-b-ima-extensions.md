# Phase 1 Plan B — RV32IMA ISA Extensions (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Plan 1.A emulator with the **M** (multiply/divide), **A** (atomics), and **Zifencei** (`fence.i`) extensions, so the CPU decodes and executes the full RV32IMA instruction set and can run a hand-crafted RV32IMA binary that prints `42\n` to UART.

**Architecture:** Flat extension of Plan A's structure. We grow the existing `Op` enum with new variants, extend the `decoder.zig` opcode switch (adding an AMO arm and M-extension funct7 branches), and extend the `execute.zig` dispatcher with new switch cases. One new field on `Cpu` tracks the LR/SC reservation. No new source files; no CSRs, no trap model, no privilege changes — those land in Plan 1.C.

**Tech Stack:** Zig 0.16.x (pinned in `build.zig.zon`), no external dependencies. Same host platform assumptions as Plan A (macOS or Linux, little-endian).

**Spec reference:** `docs/superpowers/specs/2026-04-23-phase1-cpu-emulator-design.md` — Plan 1.B implements the M + A + Zifencei slice of that spec.

**Plan 1.B scope (subset of Phase 1 spec):**

- **M extension** (8 instructions): `mul`, `mulh`, `mulhsu`, `mulhu`, `div`, `divu`, `rem`, `remu`. Includes the spec's edge cases — div-by-zero returns all-ones quotient and dividend-as-remainder; signed overflow (`INT_MIN / -1`) returns `INT_MIN` quotient and `0` remainder. **No traps** are raised.
- **A extension** (11 instructions): `lr.w`, `sc.w`, `amoswap.w`, `amoadd.w`, `amoxor.w`, `amoand.w`, `amoor.w`, `amomin.w`, `amomax.w`, `amominu.w`, `amomaxu.w`. Single-hart semantics: `aq`/`rl` acquire/release bits are decoded but ignored (we don't reorder memory). The LR/SC reservation is tracked as one optional `u32` on `Cpu`.
- **Zifencei** (1 instruction): `fence.i` as a no-op (we have no instruction cache to invalidate).
- **Hand-crafted RV32IMA demo binary**: `tests/programs/mul_demo/encode_mul_demo.zig` emits a raw binary that computes `6 * 7` with `mul`, atomically swaps the result into a memory slot with `amoswap.w`, formats `42` into ASCII via `divu`/`remu`, prints `"42\n"` via UART, and halts. Wired as a new `zig build e2e-mul` step that asserts stdout equals `"42\n"`.

**Not in Plan 1.B (deferred to Plan 1.C / 1.D):**

- Zicsr (`csrrw`/`csrrs`/`csrrc`/`csrrwi`/`csrrsi`/`csrrci`), the CSR file, `misa`/`mvendorid`/etc. → Plan 1.C.
- M-mode/U-mode privilege, `mstatus`/`mtvec`/`mepc`/`mcause`/`mtval`, trap entry/exit, `mret`/`wfi`, real `ecall`/`ebreak` handling (still return `error.UnsupportedInstruction` from the executor) → Plan 1.C.
- ELF loading, the M-mode monitor, cross-compiled Zig hello world → Plan 1.D.
- `riscv-tests` integration, `--trace` flag, QEMU-diff harness, CLINT → Plan 1.C / 1.D.

**Deviation from Plan 1.A's closing note:** Plan 1.A's epilogue suggested Plan 1.B would also cover "full Zicsr machinery" and the `riscv-tests` suite. We deliberately narrowed Plan 1.B to M + A + Zifencei only — this keeps the plan small and self-contained (no new CPU state beyond one reservation field, no trap plumbing), and lets the big privilege/CSR lift happen coherently in its own plan. Plan 1.C picks up Zicsr + trap model + `riscv-tests`.

---

## File structure (final state at end of Plan 1.B)

```
ccc/
├── .gitignore
├── build.zig                              ← MODIFIED (adds e2e-mul wiring)
├── build.zig.zon
├── README.md                              ← MODIFIED (notes RV32IMA support + e2e-mul)
├── src/
│   ├── main.zig
│   ├── cpu.zig                            ← MODIFIED (adds reservation field)
│   ├── memory.zig
│   ├── decoder.zig                        ← MODIFIED (M, A, Zifencei decoding + Op variants)
│   ├── execute.zig                        ← MODIFIED (M, A, Zifencei cases)
│   └── devices/
│       ├── halt.zig
│       └── uart.zig
└── tests/
    └── programs/
        ├── hello/                         ← UNCHANGED
        │   ├── encode_hello.zig
        │   └── README.md
        └── mul_demo/                      ← NEW
            ├── encode_mul_demo.zig        ← NEW
            └── README.md                  ← NEW
```

**Module responsibilities (deltas vs Plan A):**

- `cpu.zig` — gains `reservation: ?u32` field. Stays otherwise unchanged; no new privilege state, no CSRs.
- `decoder.zig` — `Op` enum grows with 20 new variants. The OP (`0b0110011`) arm gains M-extension branches (funct7 `== 0b0000001`). The MISC-MEM (`0b0001111`) arm now discriminates on funct3 (0 → `fence`, 1 → `fence_i`). A new top-level arm for AMO opcode `0b0101111` dispatches by funct5 to the 11 A-extension variants. One new helper: `funct5(word) → u5`.
- `execute.zig` — gains three grouped switch arms (mul-family, div-family, AMO-family) plus standalone arms for `lr_w`, `sc_w`, `fence_i`. Reuses the existing `mapMemErr` helper unchanged.
- `memory.zig` — **no change**. AMOs reuse `loadWord`/`storeWord`. AMO on MMIO is undefined per the RISC-V spec; we do not special-case it, and the existing error plumbing surfaces anything unusual.
- `tests/programs/mul_demo/encode_mul_demo.zig` — a new host-side encoder, following the `encode_hello.zig` pattern, that emits a self-contained RV32IMA binary.

---

## Conventions used in this plan

- All Zig code targets Zig 0.16.x. Same API surface as Plan A (e.g., `std.Io.Writer`, `std.process.Init`, `std.heap.ArenaAllocator`).
- Tests live as inline `test "name" { ... }` blocks alongside the code under test. `zig build test` runs every test reachable from `src/main.zig`.
- Each task ends with a TDD cycle: write a failing test, see it fail, implement minimally, verify pass, commit. Commit messages follow Conventional Commits (`feat:`, `test:`, `chore:`).
- When extending a grouped switch (e.g., adding `.mul` to the existing `0b0110011` block), we touch the whole block and show it in full so the reader doesn't have to reconstruct it from diffs.
- Register aliases in demo encoders use the RISC-V ABI numbers (`T0 = 5`, `T1 = 6`, …), matching `encode_hello.zig`.

---

## Tasks

### Task 1: Add LR/SC reservation state to `Cpu`

**Files:**
- Modify: `src/cpu.zig`

**Why this task:** The A extension's `lr.w` (load-reserved) and `sc.w` (store-conditional) need one piece of per-hart state: the address that `lr.w` reserved, or none. This is the only new CPU state Plan 1.B introduces. We land it first so downstream execute tasks can reference it.

- [ ] **Step 1: Add the field and initialise it to null**

In `src/cpu.zig`, update the `Cpu` struct and its `init` function.

Replace:

```zig
pub const Cpu = struct {
    regs: [32]u32,
    pc: u32,
    memory: *Memory,

    pub fn init(memory: *Memory, entry: u32) Cpu {
        return .{
            .regs = [_]u32{0} ** 32,
            .pc = entry,
            .memory = memory,
        };
    }
```

With:

```zig
pub const Cpu = struct {
    regs: [32]u32,
    pc: u32,
    memory: *Memory,
    // LR/SC reservation: address last reserved by lr.w, or null.
    // Set by lr.w, cleared by sc.w (on success or failure). Plan 1.C
    // will additionally clear this on trap entry; Plan 1.B has no traps.
    reservation: ?u32,

    pub fn init(memory: *Memory, entry: u32) Cpu {
        return .{
            .regs = [_]u32{0} ** 32,
            .pc = entry,
            .memory = memory,
            .reservation = null,
        };
    }
```

- [ ] **Step 2: Add a test that init sets reservation to null**

Append to `src/cpu.zig` (at the end, alongside the other tests):

```zig
test "Cpu.init sets reservation to null" {
    var dummy_mem: Memory = undefined;
    const cpu = Cpu.init(&dummy_mem, 0);
    try std.testing.expect(cpu.reservation == null);
}
```

- [ ] **Step 3: Run tests**

Run: `zig build test`
Expected: all tests pass, including the new reservation test.

- [ ] **Step 4: Commit**

```bash
git add src/cpu.zig
git commit -m "feat: add LR/SC reservation field to Cpu"
```

---

### Task 2: Decode the M extension (mul/div family)

**Files:**
- Modify: `src/decoder.zig`

**Why this task:** Add the 8 M-extension variants to the `Op` enum and teach `decode()` to recognise them. M instructions share opcode `0b0110011` (OP) with the base RV32I R-type ops but use funct7 `0b0000001` instead of `0b0000000` / `0b0100000`. After this task the decoder recognises RV32IM; the executor will reject them as `UnsupportedInstruction` until Task 3.

- [ ] **Step 1: Write failing decoder tests**

Append these tests to `src/decoder.zig`:

```zig
test "decode MUL x3, x1, x2 → 0x022081B3" {
    // funct7=0000001, rs2=00010, rs1=00001, funct3=000, rd=00011, opcode=0110011
    const i = decode(0x022081B3);
    try std.testing.expectEqual(Op.mul, i.op);
    try std.testing.expectEqual(@as(u5, 3), i.rd);
    try std.testing.expectEqual(@as(u5, 1), i.rs1);
    try std.testing.expectEqual(@as(u5, 2), i.rs2);
}

test "decode MULH x3, x1, x2 → 0x022091B3" {
    // funct3=001
    const i = decode(0x022091B3);
    try std.testing.expectEqual(Op.mulh, i.op);
}

test "decode MULHSU x3, x1, x2 → 0x0220A1B3" {
    // funct3=010
    const i = decode(0x0220A1B3);
    try std.testing.expectEqual(Op.mulhsu, i.op);
}

test "decode MULHU x3, x1, x2 → 0x0220B1B3" {
    // funct3=011
    const i = decode(0x0220B1B3);
    try std.testing.expectEqual(Op.mulhu, i.op);
}

test "decode DIV x3, x1, x2 → 0x0220C1B3" {
    // funct3=100
    const i = decode(0x0220C1B3);
    try std.testing.expectEqual(Op.div, i.op);
}

test "decode DIVU x3, x1, x2 → 0x0220D1B3" {
    // funct3=101, funct7=0000001 (distinct from SRL/SRA which use 0000000/0100000)
    const i = decode(0x0220D1B3);
    try std.testing.expectEqual(Op.divu, i.op);
}

test "decode REM x3, x1, x2 → 0x0220E1B3" {
    // funct3=110
    const i = decode(0x0220E1B3);
    try std.testing.expectEqual(Op.rem, i.op);
}

test "decode REMU x3, x1, x2 → 0x0220F1B3" {
    // funct3=111
    const i = decode(0x0220F1B3);
    try std.testing.expectEqual(Op.remu, i.op);
}

test "unknown funct7 on opcode 0x33 still decodes to illegal" {
    // funct7=0b1111111 (neither 0, 0x20, nor 0x01), funct3=000
    const i = decode(0xFE2081B3);
    try std.testing.expectEqual(Op.illegal, i.op);
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `zig build test`
Expected: compile error — `Op.mul` etc. do not yet exist.

- [ ] **Step 3: Extend the `Op` enum**

In `src/decoder.zig`, modify the `Op` enum. Replace:

```zig
pub const Op = enum {
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
    // (more added in later tasks)
    illegal,
};
```

With:

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
    // (more added in later plans)
    illegal,
};
```

- [ ] **Step 4: Extend the OP-opcode decoder arm to recognise M-extension funct7**

In `src/decoder.zig`, replace the existing `0b0110011` block:

```zig
        0b0110011 => blk: {
            const f3 = funct3(word);
            const f7 = funct7(word);
            const op: Op = switch (f3) {
                0b000 => switch (f7) {
                    0b0000000 => Op.add,
                    0b0100000 => Op.sub,
                    else => Op.illegal,
                },
                0b001 => if (f7 == 0) Op.sll else Op.illegal,
                0b010 => if (f7 == 0) Op.slt else Op.illegal,
                0b011 => if (f7 == 0) Op.sltu else Op.illegal,
                0b100 => if (f7 == 0) Op.xor_ else Op.illegal,
                0b101 => switch (f7) {
                    0b0000000 => Op.srl,
                    0b0100000 => Op.sra,
                    else => Op.illegal,
                },
                0b110 => if (f7 == 0) Op.or_ else Op.illegal,
                0b111 => if (f7 == 0) Op.and_ else Op.illegal,
            };
            break :blk .{ .op = op, .rd = rd(word), .rs1 = rs1(word), .rs2 = rs2(word), .raw = word };
        },
```

With:

```zig
        0b0110011 => blk: {
            const f3 = funct3(word);
            const f7 = funct7(word);
            const op: Op = switch (f3) {
                0b000 => switch (f7) {
                    0b0000000 => Op.add,
                    0b0100000 => Op.sub,
                    0b0000001 => Op.mul,
                    else => Op.illegal,
                },
                0b001 => switch (f7) {
                    0b0000000 => Op.sll,
                    0b0000001 => Op.mulh,
                    else => Op.illegal,
                },
                0b010 => switch (f7) {
                    0b0000000 => Op.slt,
                    0b0000001 => Op.mulhsu,
                    else => Op.illegal,
                },
                0b011 => switch (f7) {
                    0b0000000 => Op.sltu,
                    0b0000001 => Op.mulhu,
                    else => Op.illegal,
                },
                0b100 => switch (f7) {
                    0b0000000 => Op.xor_,
                    0b0000001 => Op.div,
                    else => Op.illegal,
                },
                0b101 => switch (f7) {
                    0b0000000 => Op.srl,
                    0b0100000 => Op.sra,
                    0b0000001 => Op.divu,
                    else => Op.illegal,
                },
                0b110 => switch (f7) {
                    0b0000000 => Op.or_,
                    0b0000001 => Op.rem,
                    else => Op.illegal,
                },
                0b111 => switch (f7) {
                    0b0000000 => Op.and_,
                    0b0000001 => Op.remu,
                    else => Op.illegal,
                },
            };
            break :blk .{ .op = op, .rd = rd(word), .rs1 = rs1(word), .rs2 = rs2(word), .raw = word };
        },
```

- [ ] **Step 5: Handle the new Op variants in the existing `execute.zig` switch**

`execute.zig`'s `dispatch` switch is exhaustive over `Op`. Adding new enum variants without cases makes Zig fail compilation. We satisfy the switch by treating them all as `UnsupportedInstruction` for now — Task 3 replaces this stub.

In `src/execute.zig`, find the line:

```zig
        .ecall, .ebreak => return ExecuteError.UnsupportedInstruction,
```

Replace with:

```zig
        .ecall, .ebreak => return ExecuteError.UnsupportedInstruction,
        // M extension — implemented in Plan 1.B Tasks 3 and 4.
        .mul, .mulh, .mulhsu, .mulhu, .div, .divu, .rem, .remu => return ExecuteError.UnsupportedInstruction,
        // Zifencei — implemented in Plan 1.B Task 5.
        .fence_i => return ExecuteError.UnsupportedInstruction,
        // A extension — implemented in Plan 1.B Tasks 7 and 8.
        .lr_w, .sc_w,
        .amoswap_w, .amoadd_w, .amoxor_w, .amoand_w, .amoor_w,
        .amomin_w, .amomax_w, .amominu_w, .amomaxu_w => return ExecuteError.UnsupportedInstruction,
```

- [ ] **Step 6: Run tests, verify decoder tests pass**

Run: `zig build test`
Expected: all tests pass — the 9 new decoder tests from Step 1 should now be green; no executor tests should regress.

- [ ] **Step 7: Commit**

```bash
git add src/decoder.zig src/execute.zig
git commit -m "feat: decode RV32M instructions (mul, mulh[su|u], div[u], rem[u])"
```

---

### Task 3: Execute M extension — multiply family

**Files:**
- Modify: `src/execute.zig`

**Why this task:** Implement the four multiply instructions. `mul` is the easiest (low-32-of-product, wrapping on u32). `mulh`, `mulhu`, `mulhsu` return the upper 32 bits of a 64-bit product, each with its own signedness rules. Doing this in Zig means widening to 64-bit in the appropriate signedness, multiplying, and slicing the high word.

- [ ] **Step 1: Write failing executor tests**

Append these tests to `src/execute.zig` (at the end, alongside the other executor tests):

```zig
test "MUL: 6 * 7 = 42" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 6);
    rig.cpu.writeReg(2, 7);
    try dispatch(.{ .op = .mul, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 42), rig.cpu.readReg(3));
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.pc);
}

test "MUL: wraps on unsigned overflow (low 32 bits only)" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    // 0x10000 * 0x10000 = 0x100000000, low 32 bits = 0
    rig.cpu.writeReg(1, 0x10000);
    rig.cpu.writeReg(2, 0x10000);
    try dispatch(.{ .op = .mul, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.readReg(3));
}

test "MULH: high bits of signed × signed (negative × negative = positive)" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    // -1 * -1 = 1. High 32 bits of 1 (as 64-bit signed) = 0.
    rig.cpu.writeReg(1, 0xFFFF_FFFF); // -1
    rig.cpu.writeReg(2, 0xFFFF_FFFF); // -1
    try dispatch(.{ .op = .mulh, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.readReg(3));
}

test "MULH: high bits when result spans more than 32 bits" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    // 0x40000000 * 2 = 0x80000000 as i64 (= 2^31). High 32 bits = 0.
    // Try something bigger: 0x40000000 * 4 = 0x100000000. High = 1.
    rig.cpu.writeReg(1, 0x40000000);
    rig.cpu.writeReg(2, 4);
    try dispatch(.{ .op = .mulh, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 1), rig.cpu.readReg(3));
}

test "MULHU: high bits of unsigned × unsigned" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    // 0xFFFFFFFF * 0xFFFFFFFF = 0xFFFFFFFE_00000001. High = 0xFFFFFFFE.
    rig.cpu.writeReg(1, 0xFFFF_FFFF);
    rig.cpu.writeReg(2, 0xFFFF_FFFF);
    try dispatch(.{ .op = .mulhu, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFE), rig.cpu.readReg(3));
}

test "MULHSU: signed × unsigned, rs1 negative" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    // -1 (as i32) * 0xFFFFFFFF (as u32) = -0xFFFFFFFF (as i64) = 0xFFFFFFFF_00000001
    // High 32 bits = 0xFFFFFFFF.
    rig.cpu.writeReg(1, 0xFFFF_FFFF); // -1 signed
    rig.cpu.writeReg(2, 0xFFFF_FFFF); // 4294967295 unsigned
    try dispatch(.{ .op = .mulhsu, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), rig.cpu.readReg(3));
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `zig build test`
Expected: the 6 new tests above fail with `UnsupportedInstruction` (the Task-2 stub).

- [ ] **Step 3: Implement the multiply family**

In `src/execute.zig`, replace this line that was added in Task 2:

```zig
        .mul, .mulh, .mulhsu, .mulhu, .div, .divu, .rem, .remu => return ExecuteError.UnsupportedInstruction,
```

With (note we keep the div/rem stub for Task 4):

```zig
        .mul, .mulh, .mulhsu, .mulhu => {
            const a = cpu.readReg(instr.rs1);
            const b = cpu.readReg(instr.rs2);
            const result: u32 = switch (instr.op) {
                .mul => a *% b,
                .mulh => blk: {
                    const as: i64 = @as(i32, @bitCast(a));
                    const bs: i64 = @as(i32, @bitCast(b));
                    const prod: i64 = as * bs;
                    break :blk @truncate(@as(u64, @bitCast(prod)) >> 32);
                },
                .mulhu => blk: {
                    const au: u64 = a;
                    const bu: u64 = b;
                    const prod: u64 = au * bu;
                    break :blk @truncate(prod >> 32);
                },
                .mulhsu => blk: {
                    const as: i64 = @as(i32, @bitCast(a));
                    const bu: i64 = @intCast(b); // unsigned rs2, zero-extended
                    const prod: i64 = as * bu;
                    break :blk @truncate(@as(u64, @bitCast(prod)) >> 32);
                },
                else => unreachable,
            };
            cpu.writeReg(instr.rd, result);
            cpu.pc +%= 4;
        },
        .div, .divu, .rem, .remu => return ExecuteError.UnsupportedInstruction,
```

**Note on `mulhsu` overflow safety:** signed(rs1) ∈ [−2³¹, 2³¹−1] and unsigned(rs2) ∈ [0, 2³²−1]. The product magnitude is at most 2³¹ × (2³²−1) = 2⁶³ − 2³¹, which fits in i64. Zig's unchecked `*` is safe here; `*%` is not needed.

- [ ] **Step 4: Run tests, verify they pass**

Run: `zig build test`
Expected: all tests pass — the 6 new multiply tests are green; the `div`/`rem` tests (when they exist in Task 4) are still stubbed as `UnsupportedInstruction` but we haven't written those tests yet.

- [ ] **Step 5: Commit**

```bash
git add src/execute.zig
git commit -m "feat: execute RV32M multiply instructions (mul, mulh[su|u])"
```

---

### Task 4: Execute M extension — divide / remainder family (with edge cases)

**Files:**
- Modify: `src/execute.zig`

**Why this task:** `div`/`divu`/`rem`/`remu` have two RISC-V-specified edge cases that differ from most architectures: division by zero returns `−1` (all ones) as quotient and the dividend as remainder; signed overflow (`INT_MIN / −1`) returns `INT_MIN` as quotient and `0` as remainder. Neither edge case traps. This task encodes those rules precisely.

- [ ] **Step 1: Write failing executor tests**

Append to `src/execute.zig`:

```zig
test "DIV: 42 / 6 = 7" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 42);
    rig.cpu.writeReg(2, 6);
    try dispatch(.{ .op = .div, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 7), rig.cpu.readReg(3));
}

test "DIV: signed truncation toward zero (-7 / 2 = -3, not -4)" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, @bitCast(@as(i32, -7)));
    rig.cpu.writeReg(2, 2);
    try dispatch(.{ .op = .div, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -3))), rig.cpu.readReg(3));
}

test "DIV: division by zero returns -1 (all ones)" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 42);
    rig.cpu.writeReg(2, 0);
    try dispatch(.{ .op = .div, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), rig.cpu.readReg(3));
}

test "DIV: signed overflow (INT_MIN / -1) returns INT_MIN" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0x8000_0000); // INT_MIN
    rig.cpu.writeReg(2, @bitCast(@as(i32, -1)));
    try dispatch(.{ .op = .div, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), rig.cpu.readReg(3));
}

test "DIVU: unsigned divide by zero returns all-ones" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 42);
    rig.cpu.writeReg(2, 0);
    try dispatch(.{ .op = .divu, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), rig.cpu.readReg(3));
}

test "DIVU: large unsigned divide" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0xFFFF_FFFE); // 4294967294
    rig.cpu.writeReg(2, 2);
    try dispatch(.{ .op = .divu, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x7FFF_FFFF), rig.cpu.readReg(3));
}

test "REM: 42 % 6 = 0" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 42);
    rig.cpu.writeReg(2, 6);
    try dispatch(.{ .op = .rem, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.readReg(3));
}

test "REM: result takes sign of dividend (-7 rem 2 = -1)" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, @bitCast(@as(i32, -7)));
    rig.cpu.writeReg(2, 2);
    try dispatch(.{ .op = .rem, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -1))), rig.cpu.readReg(3));
}

test "REM: division by zero returns dividend" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 42);
    rig.cpu.writeReg(2, 0);
    try dispatch(.{ .op = .rem, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 42), rig.cpu.readReg(3));
}

test "REM: signed overflow (INT_MIN rem -1) returns 0" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0x8000_0000); // INT_MIN
    rig.cpu.writeReg(2, @bitCast(@as(i32, -1)));
    try dispatch(.{ .op = .rem, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.readReg(3));
}

test "REMU: unsigned remainder by zero returns dividend" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 42);
    rig.cpu.writeReg(2, 0);
    try dispatch(.{ .op = .remu, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 42), rig.cpu.readReg(3));
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `zig build test`
Expected: the 11 new tests fail with `UnsupportedInstruction`.

- [ ] **Step 3: Implement div / divu / rem / remu**

In `src/execute.zig`, replace this stub (added in Task 2, still present after Task 3):

```zig
        .div, .divu, .rem, .remu => return ExecuteError.UnsupportedInstruction,
```

With:

```zig
        .div, .divu, .rem, .remu => {
            const a = cpu.readReg(instr.rs1);
            const b = cpu.readReg(instr.rs2);
            const result: u32 = switch (instr.op) {
                .div => blk: {
                    if (b == 0) break :blk 0xFFFF_FFFF; // div-by-zero → -1
                    const as: i32 = @bitCast(a);
                    const bs: i32 = @bitCast(b);
                    if (as == std.math.minInt(i32) and bs == -1) break :blk a; // overflow → INT_MIN
                    break :blk @bitCast(@divTrunc(as, bs));
                },
                .divu => if (b == 0) @as(u32, 0xFFFF_FFFF) else a / b,
                .rem => blk: {
                    if (b == 0) break :blk a; // div-by-zero → dividend
                    const as: i32 = @bitCast(a);
                    const bs: i32 = @bitCast(b);
                    if (as == std.math.minInt(i32) and bs == -1) break :blk 0; // overflow → 0
                    break :blk @bitCast(@rem(as, bs));
                },
                .remu => if (b == 0) a else a % b,
                else => unreachable,
            };
            cpu.writeReg(instr.rd, result);
            cpu.pc +%= 4;
        },
```

**Note on Zig div operators:** `@divTrunc(a, b)` truncates toward zero (matches RISC-V `div`). `@rem(a, b)` takes the sign of the dividend (matches RISC-V `rem`). The `INT_MIN / -1` case is hand-rolled because Zig's `@divTrunc` panics on this overflow in Debug mode — we intercept before calling it.

- [ ] **Step 4: Run tests, verify they pass**

Run: `zig build test`
Expected: all tests pass, including the 11 new div/rem tests.

- [ ] **Step 5: Commit**

```bash
git add src/execute.zig
git commit -m "feat: execute RV32M divide/remainder with div-by-zero and overflow semantics"
```

---

### Task 5: Decode and execute `fence.i` (Zifencei)

**Files:**
- Modify: `src/decoder.zig`
- Modify: `src/execute.zig`

**Why this task:** `fence.i` is the sole Zifencei instruction. It shares opcode `0b0001111` (MISC-MEM) with `fence` but uses funct3 `0b001`. Semantically it's an I-cache synchronisation barrier — since our emulator fetches straight from memory on every instruction with no caching, it's a no-op. Small task, both decode and execute land together.

- [ ] **Step 1: Write a failing decoder test for `fence.i`**

Append to `src/decoder.zig`:

```zig
test "decode FENCE.I → 0x0000100F" {
    // opcode=0001111, rd=0, funct3=001, rs1=0, imm=0
    const i = decode(0x0000100F);
    try std.testing.expectEqual(Op.fence_i, i.op);
}

test "FENCE (funct3=0) still decodes to fence, not fence_i" {
    // opcode=0001111, rd=0, funct3=000, rs1=0, imm=0
    const i = decode(0x0000000F);
    try std.testing.expectEqual(Op.fence, i.op);
}
```

- [ ] **Step 2: Run tests, verify the new test fails**

Run: `zig build test`
Expected: `decode FENCE.I` test fails (currently `0b0001111` opcode blindly returns `Op.fence`).

- [ ] **Step 3: Split the MISC-MEM arm by funct3**

In `src/decoder.zig`, replace the single-line MISC-MEM arm:

```zig
        0b0001111 => return .{ .op = .fence, .raw = word },
```

With:

```zig
        0b0001111 => {
            // MISC-MEM: funct3 selects fence (000) vs fence.i (001).
            return switch (funct3(word)) {
                0b000 => .{ .op = .fence, .raw = word },
                0b001 => .{ .op = .fence_i, .raw = word },
                else => .{ .op = .illegal, .raw = word },
            };
        },
```

- [ ] **Step 4: Write a failing executor test for `fence.i`**

Append to `src/execute.zig`:

```zig
test "FENCE.I is a no-op, advances PC by 4" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try dispatch(.{ .op = .fence_i }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.pc);
}
```

- [ ] **Step 5: Replace the `fence_i` stub**

In `src/execute.zig`, find this stub from Task 2:

```zig
        // Zifencei — implemented in Plan 1.B Task 5.
        .fence_i => return ExecuteError.UnsupportedInstruction,
```

Replace with:

```zig
        .fence_i => {
            // No I-cache to invalidate; single hart, fetch-from-memory every step.
            cpu.pc +%= 4;
        },
```

- [ ] **Step 6: Run tests, verify all pass**

Run: `zig build test`
Expected: all tests pass — the two new decoder tests and the new executor test are green.

- [ ] **Step 7: Commit**

```bash
git add src/decoder.zig src/execute.zig
git commit -m "feat: decode and execute fence.i (Zifencei) as a no-op"
```

---

### Task 6: Decode the A extension (AMO opcode 0x2F)

**Files:**
- Modify: `src/decoder.zig`

**Why this task:** The A extension occupies opcode `0b0101111`, which Plan A never handled (all non-recognised opcodes fall through to `Op.illegal`). A instructions encode their operation in a 5-bit funct5 (bits 31:27), with bits 26 and 25 used for the `aq`/`rl` acquire/release hints (ignored on single-hart). funct3 is fixed at `0b010` to signal 32-bit width (RV32A has no D-width variants). We add a `funct5` bitfield helper and a new decoder arm that dispatches all 11 A variants.

- [ ] **Step 1: Add a failing decoder test for `lr.w`**

Append to `src/decoder.zig`:

```zig
test "decode LR.W x3, (x1) → 0x1000A1AF" {
    // opcode=0101111, rd=00011, funct3=010, rs1=00001, rs2=00000,
    // aq=0, rl=0, funct5=00010 → 0x1000A1AF
    const i = decode(0x1000A1AF);
    try std.testing.expectEqual(Op.lr_w, i.op);
    try std.testing.expectEqual(@as(u5, 3), i.rd);
    try std.testing.expectEqual(@as(u5, 1), i.rs1);
}

test "decode SC.W x3, x2, (x1) → 0x1820A1AF" {
    // funct5=00011, rs2=00010
    const i = decode(0x1820A1AF);
    try std.testing.expectEqual(Op.sc_w, i.op);
    try std.testing.expectEqual(@as(u5, 3), i.rd);
    try std.testing.expectEqual(@as(u5, 1), i.rs1);
    try std.testing.expectEqual(@as(u5, 2), i.rs2);
}

test "decode AMOSWAP.W x3, x2, (x1) → 0x0820A1AF" {
    // funct5=00001
    const i = decode(0x0820A1AF);
    try std.testing.expectEqual(Op.amoswap_w, i.op);
}

test "decode AMOADD.W x3, x2, (x1) → 0x0020A1AF" {
    // funct5=00000
    const i = decode(0x0020A1AF);
    try std.testing.expectEqual(Op.amoadd_w, i.op);
}

test "decode AMOXOR.W → funct5=00100" {
    const i = decode(0x2020A1AF);
    try std.testing.expectEqual(Op.amoxor_w, i.op);
}

test "decode AMOAND.W → funct5=01100" {
    const i = decode(0x6020A1AF);
    try std.testing.expectEqual(Op.amoand_w, i.op);
}

test "decode AMOOR.W → funct5=01000" {
    const i = decode(0x4020A1AF);
    try std.testing.expectEqual(Op.amoor_w, i.op);
}

test "decode AMOMIN.W → funct5=10000" {
    const i = decode(0x8020A1AF);
    try std.testing.expectEqual(Op.amomin_w, i.op);
}

test "decode AMOMAX.W → funct5=10100" {
    const i = decode(0xA020A1AF);
    try std.testing.expectEqual(Op.amomax_w, i.op);
}

test "decode AMOMINU.W → funct5=11000" {
    const i = decode(0xC020A1AF);
    try std.testing.expectEqual(Op.amominu_w, i.op);
}

test "decode AMOMAXU.W → funct5=11100" {
    const i = decode(0xE020A1AF);
    try std.testing.expectEqual(Op.amomaxu_w, i.op);
}

test "AMO with funct3 != 010 decodes to illegal (no D-width in RV32A)" {
    // Same as amoswap.w but funct3=011 → illegal
    const i = decode(0x0820B1AF);
    try std.testing.expectEqual(Op.illegal, i.op);
}

test "AMO with unknown funct5 decodes to illegal" {
    // funct5=11111 (not allocated)
    const i = decode(0xF820A1AF);
    try std.testing.expectEqual(Op.illegal, i.op);
}

test "aq/rl bits in AMO are decoded but don't change Op (amoswap.w with aq=1,rl=1)" {
    // Same as amoswap.w test but with aq=1, rl=1 → bits 26,25 set.
    // funct5=00001, aq=1, rl=1 → bits 31..25 = 0000_1_1_1 = 0x07 → 0x0E
    // Full word: 0x0E20A1AF
    const i = decode(0x0E20A1AF);
    try std.testing.expectEqual(Op.amoswap_w, i.op);
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `zig build test`
Expected: all 14 new decoder tests fail — the decoder falls through the opcode switch to `Op.illegal` for opcode `0b0101111`.

- [ ] **Step 3: Add a funct5 bitfield helper**

In `src/decoder.zig`, add after the existing `funct7` helper (around line 79):

```zig
pub fn funct5(word: u32) u5 {
    return @truncate((word >> 27) & 0x1F);
}
```

- [ ] **Step 4: Add the AMO decoder arm**

In `src/decoder.zig`'s `decode` function, add a new top-level opcode arm **before** the `else => .{ .op = .illegal, .raw = word }` line:

```zig
        0b0101111 => blk: {
            // RV32A — all instructions share opcode 0x2F, funct3 = 010 (W-width).
            // funct5 (bits 31:27) distinguishes the 11 variants.
            // Bits 26 (aq) and 25 (rl) are decoded into the raw word but not
            // acted on; single-hart emulation has no reordering to suppress.
            if (funct3(word) != 0b010) break :blk .{ .op = .illegal, .raw = word };
            const f5 = funct5(word);
            const op: Op = switch (f5) {
                0b00010 => .lr_w,
                0b00011 => .sc_w,
                0b00001 => .amoswap_w,
                0b00000 => .amoadd_w,
                0b00100 => .amoxor_w,
                0b01100 => .amoand_w,
                0b01000 => .amoor_w,
                0b10000 => .amomin_w,
                0b10100 => .amomax_w,
                0b11000 => .amominu_w,
                0b11100 => .amomaxu_w,
                else => .illegal,
            };
            break :blk .{ .op = op, .rd = rd(word), .rs1 = rs1(word), .rs2 = rs2(word), .raw = word };
        },
```

- [ ] **Step 5: Run tests, verify all pass**

Run: `zig build test`
Expected: all 14 new decoder tests are green; no existing tests regress.

- [ ] **Step 6: Commit**

```bash
git add src/decoder.zig
git commit -m "feat: decode RV32A atomics (LR.W, SC.W, AMO*)"
```

---

### Task 7: Execute `lr.w` / `sc.w` (load-reserved / store-conditional)

**Files:**
- Modify: `src/execute.zig`

**Why this task:** LR/SC implement a simple cohort of atomic read-modify-write via two instructions: `lr.w` loads a word and records a reservation on the address; `sc.w` stores only if the reservation is still valid. In our single-hart emulator with no interrupts yet, the reservation persists until explicitly cleared by a subsequent `sc.w` (success or failure). Plan 1.C will additionally clear it on trap entry.

- [ ] **Step 1: Write failing executor tests**

Append to `src/execute.zig`:

```zig
test "LR.W loads a word and records a reservation" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x80, 0xCAFEBABE);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x80);
    try dispatch(.{ .op = .lr_w, .rd = 2, .rs1 = 1 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), rig.cpu.readReg(2));
    try std.testing.expectEqual(@as(?u32, mem_mod.RAM_BASE + 0x80), rig.cpu.reservation);
}

test "SC.W succeeds when reservation matches, writes 0 to rd" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.reservation = mem_mod.RAM_BASE + 0x80;
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x80);
    rig.cpu.writeReg(2, 0xDEADBEEF);
    try dispatch(.{ .op = .sc_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.readReg(3)); // 0 = success
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x80));
    try std.testing.expect(rig.cpu.reservation == null); // cleared after SC.W
}

test "SC.W fails when no reservation is held, writes nonzero to rd" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.reservation = null;
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x80);
    rig.cpu.writeReg(2, 0xDEADBEEF);
    try dispatch(.{ .op = .sc_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expect(rig.cpu.readReg(3) != 0); // nonzero = failure
    // Memory must NOT be updated on SC.W failure.
    try std.testing.expectEqual(@as(u32, 0), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x80));
}

test "SC.W fails when reservation address doesn't match" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.reservation = mem_mod.RAM_BASE + 0x40; // reserved at 0x40
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x80); // writing to 0x80
    rig.cpu.writeReg(2, 0xDEADBEEF);
    try dispatch(.{ .op = .sc_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expect(rig.cpu.readReg(3) != 0);
    try std.testing.expect(rig.cpu.reservation == null); // cleared regardless
}

test "LR.W on misaligned address returns MisalignedAccess" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x81); // misaligned
    try std.testing.expectError(ExecuteError.MisalignedAccess, dispatch(.{ .op = .lr_w, .rd = 2, .rs1 = 1 }, &rig.cpu));
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `zig build test`
Expected: the 5 new tests fail with `UnsupportedInstruction`.

- [ ] **Step 3: Implement `lr.w` and `sc.w`**

In `src/execute.zig`, find this stub (from Task 2):

```zig
        // A extension — implemented in Plan 1.B Tasks 7 and 8.
        .lr_w, .sc_w,
        .amoswap_w, .amoadd_w, .amoxor_w, .amoand_w, .amoor_w,
        .amomin_w, .amomax_w, .amominu_w, .amomaxu_w => return ExecuteError.UnsupportedInstruction,
```

Replace with (keeping the AMO stub for Task 8):

```zig
        .lr_w => {
            const addr = cpu.readReg(instr.rs1);
            if (addr & 3 != 0) return ExecuteError.MisalignedAccess;
            const val = cpu.memory.loadWord(addr) catch |e| return mapMemErr(e);
            cpu.reservation = addr;
            cpu.writeReg(instr.rd, val);
            cpu.pc +%= 4;
        },
        .sc_w => {
            const addr = cpu.readReg(instr.rs1);
            if (addr & 3 != 0) return ExecuteError.MisalignedAccess;
            const holds = (cpu.reservation != null and cpu.reservation.? == addr);
            if (holds) {
                cpu.memory.storeWord(addr, cpu.readReg(instr.rs2)) catch |e| return mapMemErr(e);
            }
            cpu.reservation = null; // always cleared after SC.W (success or failure)
            cpu.writeReg(instr.rd, if (holds) @as(u32, 0) else @as(u32, 1));
            cpu.pc +%= 4;
        },
        .amoswap_w, .amoadd_w, .amoxor_w, .amoand_w, .amoor_w,
        .amomin_w, .amomax_w, .amominu_w, .amomaxu_w => return ExecuteError.UnsupportedInstruction,
```

- [ ] **Step 4: Run tests, verify all pass**

Run: `zig build test`
Expected: the 5 new LR/SC tests are green; AMO tests still unwritten.

- [ ] **Step 5: Commit**

```bash
git add src/execute.zig
git commit -m "feat: execute LR.W and SC.W with per-hart reservation tracking"
```

---

### Task 8: Execute AMO operations (9 variants)

**Files:**
- Modify: `src/execute.zig`

**Why this task:** The 9 AMO variants (`amoswap`, `amoadd`, `amoxor`, `amoand`, `amoor`, `amomin`, `amomax`, `amominu`, `amomaxu`) share a common shape: load rs1's address, compute a new value from the loaded word and rs2, store the new value back, return the original loaded value in rd. The variants differ only in the compute step. We factor the common load-compute-store-writeback into a single grouped switch arm (matching Plan A's style for the `add`/`sub`/... group).

- [ ] **Step 1: Write failing executor tests**

Append to `src/execute.zig`:

```zig
test "AMOSWAP.W returns old value, stores rs2" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 0xAAAA);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x40);
    rig.cpu.writeReg(2, 0xBBBB);
    try dispatch(.{ .op = .amoswap_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xAAAA), rig.cpu.readReg(3));       // old
    try std.testing.expectEqual(@as(u32, 0xBBBB), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x40)); // new
}

test "AMOADD.W returns old value, stores (old + rs2) with wrap" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 10);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x40);
    rig.cpu.writeReg(2, 32);
    try dispatch(.{ .op = .amoadd_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 10), rig.cpu.readReg(3));
    try std.testing.expectEqual(@as(u32, 42), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x40));
}

test "AMOXOR.W: old XOR rs2" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 0x0F0F_0F0F);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x40);
    rig.cpu.writeReg(2, 0xFF00_FF00);
    try dispatch(.{ .op = .amoxor_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x0F0F_0F0F), rig.cpu.readReg(3));
    try std.testing.expectEqual(@as(u32, 0xF00F_F00F), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x40));
}

test "AMOAND.W: old AND rs2" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 0xFFFF_FFFF);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x40);
    rig.cpu.writeReg(2, 0x0000_FFFF);
    try dispatch(.{ .op = .amoand_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), rig.cpu.readReg(3));
    try std.testing.expectEqual(@as(u32, 0x0000_FFFF), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x40));
}

test "AMOOR.W: old OR rs2" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 0x0000_00FF);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x40);
    rig.cpu.writeReg(2, 0xFF00_0000);
    try dispatch(.{ .op = .amoor_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFF00_00FF), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x40));
}

test "AMOMIN.W signed: min(-1, 0) = -1" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 0xFFFF_FFFF); // -1 as i32
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x40);
    rig.cpu.writeReg(2, 0);
    try dispatch(.{ .op = .amomin_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), rig.cpu.readReg(3));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x40));
}

test "AMOMAX.W signed: max(-1, 0) = 0" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 0xFFFF_FFFF);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x40);
    rig.cpu.writeReg(2, 0);
    try dispatch(.{ .op = .amomax_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x40));
}

test "AMOMINU.W unsigned: min(0xFFFFFFFF, 0) = 0" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 0xFFFF_FFFF);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x40);
    rig.cpu.writeReg(2, 0);
    try dispatch(.{ .op = .amominu_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x40));
}

test "AMOMAXU.W unsigned: max(0xFFFFFFFF, 0) = 0xFFFFFFFF" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 0xFFFF_FFFF);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x40);
    rig.cpu.writeReg(2, 0);
    try dispatch(.{ .op = .amomaxu_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x40));
}

test "AMO on misaligned address returns MisalignedAccess" {
    var rig: Rig = undefined;
    try rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, mem_mod.RAM_BASE + 0x41); // misaligned
    rig.cpu.writeReg(2, 1);
    try std.testing.expectError(ExecuteError.MisalignedAccess, dispatch(.{ .op = .amoadd_w, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu));
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `zig build test`
Expected: the 10 new AMO tests fail with `UnsupportedInstruction`.

- [ ] **Step 3: Implement the AMO group**

In `src/execute.zig`, replace this stub:

```zig
        .amoswap_w, .amoadd_w, .amoxor_w, .amoand_w, .amoor_w,
        .amomin_w, .amomax_w, .amominu_w, .amomaxu_w => return ExecuteError.UnsupportedInstruction,
```

With:

```zig
        .amoswap_w, .amoadd_w, .amoxor_w, .amoand_w, .amoor_w,
        .amomin_w, .amomax_w, .amominu_w, .amomaxu_w => {
            const addr = cpu.readReg(instr.rs1);
            if (addr & 3 != 0) return ExecuteError.MisalignedAccess;
            const old = cpu.memory.loadWord(addr) catch |e| return mapMemErr(e);
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
            cpu.memory.storeWord(addr, new) catch |e| return mapMemErr(e);
            cpu.writeReg(instr.rd, old);
            cpu.pc +%= 4;
        },
```

- [ ] **Step 4: Run tests, verify all pass**

Run: `zig build test`
Expected: all tests pass — the 10 new AMO tests are green.

- [ ] **Step 5: Commit**

```bash
git add src/execute.zig
git commit -m "feat: execute RV32A atomic memory operations (AMO*)"
```

---

### Task 9: Hand-crafted RV32IMA demo binary + `e2e-mul` build step

**Files:**
- Create: `tests/programs/mul_demo/encode_mul_demo.zig`
- Create: `tests/programs/mul_demo/README.md`
- Modify: `build.zig`

**Why this task:** This is the Plan 1.B payoff. A small hand-encoded program that exercises every new extension Plan 1.B introduces: `mul` (M), `amoswap.w` (A), `divu`/`remu` (M — formatting 42 into digits), `fence.i` (Zifencei), plus the Plan A RV32I baseline. It computes `6 * 7 = 42`, atomically swaps the result into a memory slot, formats the integer into ASCII, writes `"42\n"` to UART, and halts. Wired as a new `zig build e2e-mul` step.

- [ ] **Step 1: Create `tests/programs/mul_demo/encode_mul_demo.zig`**

```zig
const std = @import("std");
const Io = std.Io;

// Register aliases (RISC-V ABI numeric register names).
const ZERO: u5 = 0;
const T0: u5 = 5;
const T1: u5 = 6;
const T2: u5 = 7;
const T3: u5 = 28;
const T4: u5 = 29;
const T5: u5 = 30;
const T6: u5 = 31;

// === Encoders for the instructions we use ===

fn lui(rd: u5, imm20: u20) u32 {
    return (@as(u32, imm20) << 12) | (@as(u32, rd) << 7) | 0b0110111;
}

fn addi(rd: u5, rs1: u5, imm: i12) u32 {
    const imm_u: u32 = @bitCast(@as(i32, imm));
    return ((imm_u & 0xFFF) << 20) | (@as(u32, rs1) << 15) | (@as(u32, rd) << 7) | 0b0010011;
}

fn sb(rs1: u5, rs2: u5, imm: i12) u32 {
    const imm_u: u32 = @bitCast(@as(i32, imm));
    const imm_high: u32 = (imm_u >> 5) & 0x7F;
    const imm_low: u32 = imm_u & 0x1F;
    return (imm_high << 25) | (@as(u32, rs2) << 20) | (@as(u32, rs1) << 15) |
        (@as(u32, 0b000) << 12) | (imm_low << 7) | 0b0100011;
}

fn rType(rd: u5, rs1: u5, rs2: u5, funct3: u3, funct7: u7, opcode: u7) u32 {
    return (@as(u32, funct7) << 25) | (@as(u32, rs2) << 20) | (@as(u32, rs1) << 15) |
        (@as(u32, funct3) << 12) | (@as(u32, rd) << 7) | @as(u32, opcode);
}

fn mul(rd: u5, rs1: u5, rs2: u5) u32 {
    return rType(rd, rs1, rs2, 0b000, 0b0000001, 0b0110011);
}

fn divu(rd: u5, rs1: u5, rs2: u5) u32 {
    return rType(rd, rs1, rs2, 0b101, 0b0000001, 0b0110011);
}

fn remu(rd: u5, rs1: u5, rs2: u5) u32 {
    return rType(rd, rs1, rs2, 0b111, 0b0000001, 0b0110011);
}

fn amoswap_w(rd: u5, rs1: u5, rs2: u5) u32 {
    // funct5=00001, aq=0, rl=0 → funct7 = 0b0000100
    return rType(rd, rs1, rs2, 0b010, 0b0000100, 0b0101111);
}

fn fence_i() u32 {
    // opcode=0001111, funct3=001, rs1=0, rd=0, imm=0
    return (@as(u32, 0b001) << 12) | 0b0001111;
}

// === The program ===

const PROGRAM_BASE: u32 = 0x8000_0000;
const FLAG_OFFSET: u32 = 0x200; // scratch word in RAM, reserved for amoswap.w

fn buildProgram() [18]u32 {
    return .{
        // Setup: compute 6 * 7 = 42
        addi(T1, ZERO, 6),                 // t1 = 6
        addi(T2, ZERO, 7),                 // t2 = 7
        mul(T4, T1, T2),                   // t4 = 42
        // Flag address: t3 = RAM_BASE + FLAG_OFFSET
        lui(T3, 0x80000),                  // t3 = 0x80000000
        addi(T3, T3, @intCast(FLAG_OFFSET)), // t3 += 0x200
        // Atomically swap *t3 (initially 0) with t4 (42). t5 receives old value (= 0).
        amoswap_w(T5, T3, T4),             // t5 = *t3; *t3 = t4
        // Format 42 into two ASCII digits via divu/remu by 10.
        addi(T1, ZERO, 10),                // t1 = 10 (divisor)
        divu(T6, T4, T1),                  // t6 = 4 (tens digit)
        remu(T4, T4, T1),                  // t4 = 2 (ones digit)
        addi(T6, T6, 48),                  // t6 = '4'
        addi(T4, T4, 48),                  // t4 = '2'
        // A no-op instruction-fence before the output block — exercises Zifencei.
        fence_i(),                          // no-op on our emulator
        // Print "42\n" to UART.
        lui(T0, 0x10000),                  // t0 = UART base (0x10000000)
        sb(T0, T6, 0),                     // UART <- '4'
        sb(T0, T4, 0),                     // UART <- '2'
        addi(T1, ZERO, 10),                // t1 = 10 ('\n')
        sb(T0, T1, 0),                     // UART <- '\n'
        // Halt.
        lui(T0, 0x100),                    // t0 = 0x00100000 (halt MMIO)
        sb(T0, ZERO, 0),                   // *t0 = 0 → halt
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.gpa;

    const argv = try init.minimal.args.toSlice(a);
    defer a.free(argv);

    var stderr_buffer: [256]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    if (argv.len != 2) {
        stderr.print("usage: {s} <output-path>\n", .{argv[0]}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    }

    var file = try Io.Dir.cwd().createFile(io, argv[1], .{});
    defer file.close(io);

    var out_buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &out_buffer);
    const w = &file_writer.interface;

    const program = buildProgram();
    try w.writeAll(std.mem.sliceAsBytes(&program));

    // Pad out to FLAG_OFFSET so that RAM_BASE + FLAG_OFFSET is addressable
    // (the program pre-loads RAM with zeros for the flag slot implicitly via
    // Memory.init's @memset, but we still want the binary to be long enough
    // that the loader writes a defined zero into that slot — belt and braces).
    const code_size: u32 = @intCast(program.len * 4);
    if (FLAG_OFFSET + 4 <= code_size) @panic("program overlaps flag slot");
    try w.splatByteAll(0, FLAG_OFFSET + 4 - code_size);

    try w.flush();
}
```

- [ ] **Step 2: Create the README**

`tests/programs/mul_demo/README.md`:

```markdown
# Hand-crafted RV32IMA demo

`encode_mul_demo.zig` is a Zig host-side program that emits a raw RISC-V
binary exercising every ISA extension added in Plan 1.B: **M** (`mul`,
`divu`, `remu`), **A** (`amoswap.w`), and **Zifencei** (`fence.i`).

Run by hand:

```
zig build mul-demo
zig build run -- --raw 0x80000000 zig-out/mul_demo.bin
```

Expected output: `42\n`.

The program:

1. Loads 6 and 7 into t1/t2 and computes 6×7=42 via `mul`.
2. Atomically swaps 42 into a scratch RAM slot with `amoswap.w`, leaving
   the slot's previous value (0) in t5.
3. Formats 42 into two ASCII digits using `divu`/`remu` (÷10 and rem 10).
4. Issues `fence.i` as a no-op I-cache barrier (just to exercise the
   opcode; we have no I-cache).
5. Writes `'4'`, `'2'`, `'\n'` to the UART THR at 0x10000000.
6. Writes 0 to the halt MMIO at 0x00100000 to exit.

This is scaffolding for Plan 1.B only. Plan 1.D will replace hand-crafted
binaries with cross-compiled Zig programs that run in U-mode via the
M-mode monitor.
```

- [ ] **Step 3: Wire `mul-demo` and `e2e-mul` steps into `build.zig`**

In `build.zig`, find this block (the existing hello demo wiring):

```zig
    // === Hand-crafted hello world demo (Task 17) ===
    // The encoder is a host tool that emits a raw RV32I binary.
    const hello_encoder = b.addExecutable(.{
        .name = "encode_hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/hello/encode_hello.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const hello_run = b.addRunArtifact(hello_encoder);
    const hello_bin = hello_run.addOutputFileArg("hello.bin");
    const install_hello = b.addInstallFile(hello_bin, "hello.bin");

    const hello_step = b.step("hello", "Build the hand-crafted hello world binary");
    hello_step.dependOn(&install_hello.step);

    // End-to-end test: run the emulator against the freshly-built hello.bin
    // and assert the UART output equals "hello world\n".
    const e2e_run = b.addRunArtifact(exe);
    e2e_run.addArgs(&.{ "--raw", "0x80000000" });
    e2e_run.addFileArg(hello_bin);
    e2e_run.expectStdOutEqual("hello world\n");

    const e2e_step = b.step("e2e", "Run the end-to-end hello world test");
    e2e_step.dependOn(&e2e_run.step);
}
```

Append immediately before the final closing brace (`}`) of the build function:

```zig

    // === Hand-crafted RV32IMA mul/amo/div demo (Plan 1.B Task 9) ===
    const mul_demo_encoder = b.addExecutable(.{
        .name = "encode_mul_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/mul_demo/encode_mul_demo.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const mul_demo_run = b.addRunArtifact(mul_demo_encoder);
    const mul_demo_bin = mul_demo_run.addOutputFileArg("mul_demo.bin");
    const install_mul_demo = b.addInstallFile(mul_demo_bin, "mul_demo.bin");

    const mul_demo_step = b.step("mul-demo", "Build the hand-crafted RV32IMA demo binary");
    mul_demo_step.dependOn(&install_mul_demo.step);

    // End-to-end test: run the emulator against mul_demo.bin, assert output.
    const e2e_mul_run = b.addRunArtifact(exe);
    e2e_mul_run.addArgs(&.{ "--raw", "0x80000000" });
    e2e_mul_run.addFileArg(mul_demo_bin);
    e2e_mul_run.expectStdOutEqual("42\n");

    const e2e_mul_step = b.step("e2e-mul", "Run the end-to-end RV32IMA demo test");
    e2e_mul_step.dependOn(&e2e_mul_run.step);
```

- [ ] **Step 4: Build the demo binary and inspect it**

Run: `zig build mul-demo`
Expected: succeeds, leaves `zig-out/mul_demo.bin`.

Run: `xxd zig-out/mul_demo.bin | head -10`
Expected: the first 72 bytes are the 18 encoded instructions; after offset `0x200` you'll see the reserved flag word (all zeros).

- [ ] **Step 5: Run the demo manually to see the output**

Run: `zig build run -- --raw 0x80000000 zig-out/mul_demo.bin`
Expected: prints exactly `42` followed by a newline, exits 0.

- [ ] **Step 6: Run the automated end-to-end test**

Run: `zig build e2e-mul`
Expected: succeeds silently. Failure mode: prints a diff of expected vs actual stdout.

- [ ] **Step 7: Run the full test suite plus both e2e demos**

Run: `zig build test && zig build e2e && zig build e2e-mul`
Expected: all three succeed.

- [ ] **Step 8: Commit**

```bash
git add tests/programs/mul_demo/ build.zig
git commit -m "feat: hand-crafted RV32IMA demo prints 42 via mul/amoswap/divu/remu/fence.i

A tiny hand-encoded program that exercises every ISA extension added in
Plan 1.B. Run with 'zig build e2e-mul' (or 'zig build run -- --raw
0x80000000 zig-out/mul_demo.bin' to watch the output by hand)."
```

---

### Task 10: Update README to reflect RV32IMA support

**Files:**
- Modify: `README.md`

**Why this task:** The README currently advertises only `zig build e2e` (the Plan A hello world). After Plan 1.B it should mention the new `e2e-mul` step and call out that the emulator now implements RV32IMA (not just RV32I). Small housekeeping; closes the plan.

- [ ] **Step 1: Update the Building table in `README.md`**

Find this row in the existing `README.md`:

```markdown
| `zig build e2e` | Encode → emulate → assert stdout equals `hello world\n` |
```

Replace with:

```markdown
| `zig build e2e` | Encode → emulate → assert stdout equals `hello world\n` (RV32I) |
| `zig build mul-demo` | Build the hand-crafted RV32IMA demo binary to `zig-out/mul_demo.bin` |
| `zig build e2e-mul` | Encode → emulate → assert stdout equals `42\n` (exercises M + A + Zifencei) |
```

- [ ] **Step 2: Update the prose below the table**

Find this paragraph in `README.md`:

```markdown
The `hello` and `e2e` steps are worth a closer look: a small host-side
encoder (`tests/programs/hello/encode_hello.zig`) emits a raw RV32I binary,
which `e2e` feeds to `ccc --raw 0x80000000` and checks the UART output.
All three artifacts (encoder, binary, emulator run) are wired into the
build graph so changes propagate automatically.
```

Replace with:

```markdown
The `hello`/`e2e` and `mul-demo`/`e2e-mul` step pairs are worth a closer
look: each has a small host-side encoder under `tests/programs/` that
emits a raw binary, which the corresponding `e2e*` step feeds to
`ccc --raw 0x80000000` and checks the UART output. All artifacts
(encoder, binary, emulator run) are wired into the build graph so
changes propagate automatically. The `e2e` demo covers RV32I only; the
`e2e-mul` demo additionally exercises M (`mul`, `divu`, `remu`), A
(`amoswap.w`), and Zifencei (`fence.i`).
```

- [ ] **Step 3: Update the Status line**

Find:

```markdown
Currently on **Phase 1 — RISC-V CPU emulator**. Design is approved;
implementation plan 1.A (minimum viable emulator) is drafted.
```

Replace with:

```markdown
Currently on **Phase 1 — RISC-V CPU emulator**. Plans 1.A (RV32I) and
1.B (M + A + Zifencei) are merged. Plan 1.C (Zicsr + privilege + traps)
is next.
```

- [ ] **Step 4: Verify the README renders cleanly**

Run: `cat README.md`
Expected: table rows aligned; no stray backticks or markdown errors.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: mention RV32IMA support and e2e-mul demo in README"
```

---

## Plan 1.B complete

At this point you can run:

```bash
zig build test                 # all unit tests pass (Plan A + 50-ish Plan B tests)
zig build e2e                  # Plan A: hello world RV32I demo (still green)
zig build e2e-mul              # Plan B: 42\n RV32IMA demo
zig build run -- --raw 0x80000000 zig-out/mul_demo.bin
# prints "42"
```

You have a full RV32IMA decoder and executor. The emulator still runs
in a single privilege mode with no CSRs, no traps, and only `--raw`
loading — those land in Plan 1.C.

**Next:** Brainstorm and write **Plan 1.C — Zicsr, privilege model, and
synchronous trap handling**. Plan 1.C introduces M/U-mode, the CSR file,
the trap entry/exit sequence, `ecall`/`ebreak`/`mret`/`wfi` with real
semantics, the CLINT device, ELF loading, the `--trace` flag, and the
first `riscv-tests` passes (`rv32ui-p-*`, `rv32um-p-*`, `rv32ua-p-*`,
`rv32mi-p-*`).

---

## Spec coverage check (self-review)

Plan 1.B covers the following Phase 1 spec items:

- **ISA** — Adds M, A, Zifencei on top of Plan 1.A's RV32I. Zicsr remains
  deferred to 1.C.
- **Cpu state** — One new field (`reservation: ?u32`) for LR/SC. No
  privilege mode, no CSRs.
- **Memory layout** — Unchanged.
- **Devices** — Unchanged. CLINT deferred to 1.C.
- **Boot model** — `--raw` only; ELF deferred to 1.D.
- **Testing** — Per-instruction Zig unit tests (~50 new tests) + a new
  hand-crafted end-to-end demo (`e2e-mul`). `riscv-tests` deferred to 1.C.

What's intentionally NOT in this plan (and which plan picks it up):

| Spec item | Plan |
|-----------|------|
| Zicsr (`csrrw[i]`, `csrrs[i]`, `csrrc[i]`) | 1.C |
| CSR file (`misa`, `mstatus`, `mtvec`, `mepc`, `mcause`, `mtval`, `mie`, `mip`, `mhartid`, `mvendorid`, `marchid`, `mimpid`) | 1.C |
| Privilege levels (M + U) | 1.C |
| Synchronous trap entry/exit, `mret`, `wfi` | 1.C |
| Real `ecall` / `ebreak` (still stubbed as `UnsupportedInstruction`) | 1.C |
| CLINT (`msip`, `mtimecmp`, `mtime`) | 1.C |
| ELF32 loader | 1.D |
| `--trace` flag, register/memory dump on unhandled trap | 1.C / 1.D |
| M-mode monitor + cross-compiled Zig hello world | 1.D |
| `riscv-tests` integration (`rv32ui-p-*`, `rv32um-p-*`, `rv32ua-p-*`, `rv32mi-p-*`) | 1.C |
| QEMU-diff debug harness | 1.D |
| S-mode, Sv32 page tables | Phase 2 |
| CLINT interrupt delivery | Phase 2 |
