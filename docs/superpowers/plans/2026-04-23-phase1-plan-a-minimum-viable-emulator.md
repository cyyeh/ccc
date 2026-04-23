# Phase 1 Plan A — Minimum Viable RISC-V Emulator (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a minimum-viable RISC-V CPU emulator in Zig that can run a hand-crafted RV32I binary printing `hello world\n` to an emulated UART, then halt.

**Architecture:** A single-binary CLI emulator that loads a raw program at a given physical address, then runs an interpretation loop: fetch a 4-byte word at PC, decode into a tagged-value `Instruction`, dispatch to per-opcode execute logic, repeat. Memory operations route by address to either RAM (a flat byte array) or one of two MMIO devices (UART for output, Halt for termination). No privilege levels, no traps, no CSRs in this plan — those arrive in Plans 1.B/1.C.

**Tech Stack:** Zig 0.14.x (pinned in `build.zig.zon`), no external dependencies, host platform macOS (also works on Linux).

**Spec reference:** `docs/superpowers/specs/2026-04-23-phase1-cpu-emulator-design.md` — Plan 1.A implements the subset of that spec marked "minimum viable" below.

**Plan 1.A scope (subset of Phase 1 spec):**

- ISA: **RV32I** integer instructions only (no M, no A, no Zicsr proper)
- Privilege: M-mode only, no privilege transitions
- Devices: NS16550A UART (output), Halt MMIO
- Memory: 128 MB RAM at `0x80000000`
- Boot: `--raw <addr>` only (no ELF yet)
- Testing: per-instruction Zig unit tests + one end-to-end hello-world test
- System instructions (`fence`, `ecall`, `ebreak`): stubbed (FENCE no-op; ECALL/EBREAK return error.UnsupportedInstruction → halt with diagnostic)

Plans 1.B–1.D fill in the rest of Phase 1 (M+A extensions, CSRs, privilege model, traps, ELF, monitor, end-to-end Zig hello world).

---

## File structure (final state at end of Plan 1.A)

```
ccc/
├── .gitignore
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig                  # CLI: parse args, load file, wire emulator, run
│   ├── cpu.zig                   # Cpu: regs, pc, step()/run(), error type
│   ├── memory.zig                # Memory: RAM array + MMIO routing
│   ├── decoder.zig               # decode(u32) → Instruction
│   ├── execute.zig               # dispatch(Instruction, *Cpu) — big switch
│   └── devices/
│       ├── halt.zig              # Halt MMIO device
│       └── uart.zig              # NS16550A subset (output)
└── tests/
    └── programs/
        └── hello/
            ├── encode_hello.zig  # Zig program that emits the raw RISC-V binary
            └── README.md         # Brief: how the demo works
```

**Module responsibilities:**

- `cpu.zig` — owns hart state and the run loop. Knows nothing about specific instructions.
- `memory.zig` — owns the address space. Routes accesses to RAM or MMIO devices by address.
- `decoder.zig` — pure: 32-bit word in, `Instruction` value out. No state.
- `execute.zig` — per-instruction execution. Big switch on `Instruction.op`. Calls into `Memory` for loads/stores.
- `devices/halt.zig` — single-register MMIO. Any write returns `error.Halt` and stores the byte as the host exit code.
- `devices/uart.zig` — NS16550A model. Writes go to a configurable `std.io.AnyWriter` (host stdout in production, an `ArrayList` in tests).
- `main.zig` — argv parsing, file loading, wiring everything together.

---

## Conventions used in this plan

- All Zig code targets Zig 0.14.x. If the engineer is on a newer Zig, syntax may need minor adjustments (`std.io.bufferedWriter`, `std.process.argsAlloc`, etc. APIs are version-sensitive).
- Tests live as inline `test "name" { ... }` blocks within source files. `zig build test` runs all of them.
- Each task ends with a commit. Commit messages follow Conventional Commits (`feat:`, `test:`, `chore:`).
- All files use 4-space indentation (Zig convention is technically 4 spaces; `zig fmt` enforces it).

---

## Tasks

### Task 1: Project scaffolding

**Files:**
- Create: `ccc/.gitignore`
- Create: `ccc/build.zig`
- Create: `ccc/build.zig.zon`
- Create: `ccc/src/main.zig`

**Why this task:** Stand up the Zig project so we can compile and run something. No emulator logic yet — just confirm the toolchain works and we can build/run/test.

- [ ] **Step 1: Create `.gitignore`**

```
zig-cache/
zig-out/
.zig-cache/
*.bin
.DS_Store
```

- [ ] **Step 2: Create `build.zig.zon`**

Run `zig init` once to generate a fingerprint, then replace the file contents with:

```zig
.{
    .name = .ccc,
    .version = "0.1.0",
    .fingerprint = 0x0,  // replace with whatever zig init generated
    .minimum_zig_version = "0.14.0",
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "tests",
    },
}
```

If `zig init` is unavailable or generates a substantially different shape on this Zig version, write the file by hand and let Zig tell you what's missing on first build — then fix it.

- [ ] **Step 3: Create `build.zig`**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ccc",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the emulator");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&test_run.step);
}
```

- [ ] **Step 4: Create minimal `src/main.zig`**

```zig
const std = @import("std");

pub fn main() !void {
    try std.io.getStdOut().writer().print("ccc stub — toolchain works\n", .{});
}

test "trivial" {
    try std.testing.expect(true);
}
```

- [ ] **Step 5: Verify build + run + test**

Run: `zig build`
Expected: succeeds silently, leaves binary in `zig-out/bin/ccc`.

Run: `zig build run`
Expected: prints `ccc stub — toolchain works`.

Run: `zig build test`
Expected: succeeds (one trivial test passes).

- [ ] **Step 6: Commit**

```bash
git add .gitignore build.zig build.zig.zon src/main.zig
git commit -m "chore: scaffold Zig project for ccc emulator"
```

---

### Task 2: CPU state struct

**Files:**
- Create: `src/cpu.zig`
- Modify: `src/main.zig` (add a `_ = @import("cpu.zig");` so its tests get picked up)

**Why this task:** Stand up the `Cpu` struct that holds registers and PC. Enforce the RISC-V invariant that x0 is hardwired to zero. We'll add `step()`/`run()` after Memory and Decoder exist.

- [ ] **Step 1: Write the failing test**

Create `src/cpu.zig`:

```zig
const std = @import("std");

pub const Cpu = struct {
    regs: [32]u32,
    pc: u32,

    pub fn init() Cpu {
        return .{
            .regs = [_]u32{0} ** 32,
            .pc = 0,
        };
    }

    pub fn readReg(self: *const Cpu, idx: u5) u32 {
        _ = self;
        _ = idx;
        @panic("not implemented");
    }

    pub fn writeReg(self: *Cpu, idx: u5, value: u32) void {
        _ = self;
        _ = idx;
        _ = value;
        @panic("not implemented");
    }
};

test "x0 is hardwired to zero — write is a no-op" {
    var cpu = Cpu.init();
    cpu.writeReg(0, 0xDEADBEEF);
    try std.testing.expectEqual(@as(u32, 0), cpu.readReg(0));
}

test "writeReg/readReg round-trip for x1" {
    var cpu = Cpu.init();
    cpu.writeReg(1, 0xCAFEBABE);
    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), cpu.readReg(1));
}

test "all registers initialise to zero" {
    const cpu = Cpu.init();
    var i: u5 = 0;
    while (true) : (i += 1) {
        try std.testing.expectEqual(@as(u32, 0), cpu.readReg(i));
        if (i == 31) break;
    }
}
```

Add to `src/main.zig` so its tests are discovered:

```zig
const std = @import("std");

comptime {
    _ = @import("cpu.zig");
}

pub fn main() !void {
    try std.io.getStdOut().writer().print("ccc stub — toolchain works\n", .{});
}

test "trivial" {
    try std.testing.expect(true);
}
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `zig build test`
Expected: panics in `readReg` / `writeReg` (`@panic("not implemented")`).

- [ ] **Step 3: Implement `readReg` and `writeReg`**

In `src/cpu.zig`, replace the panicking bodies:

```zig
pub fn readReg(self: *const Cpu, idx: u5) u32 {
    if (idx == 0) return 0;
    return self.regs[idx];
}

pub fn writeReg(self: *Cpu, idx: u5, value: u32) void {
    if (idx == 0) return; // x0 hardwired to zero
    self.regs[idx] = value;
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `zig build test`
Expected: all 4 tests pass (1 trivial + 3 in cpu.zig).

- [ ] **Step 5: Commit**

```bash
git add src/cpu.zig src/main.zig
git commit -m "feat: add Cpu struct with x0-hardwired register file"
```

---

### Task 3: Memory subsystem (RAM only, no routing yet)

**Files:**
- Create: `src/memory.zig`
- Modify: `src/main.zig` (add `_ = @import("memory.zig");`)

**Why this task:** Stand up flat 128 MB RAM at `0x80000000` with little-endian load/store of byte/halfword/word. No MMIO routing yet — that arrives once we have devices (Tasks 4–6).

- [ ] **Step 1: Write the failing test**

Create `src/memory.zig`:

```zig
const std = @import("std");

pub const RAM_BASE: u32 = 0x8000_0000;
pub const RAM_SIZE: usize = 128 * 1024 * 1024; // 128 MB

pub const MemoryError = error{
    OutOfBounds,
    MisalignedAccess,
};

pub const Memory = struct {
    ram: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Memory {
        const ram = try allocator.alloc(u8, RAM_SIZE);
        @memset(ram, 0);
        return .{ .ram = ram, .allocator = allocator };
    }

    pub fn deinit(self: *Memory) void {
        self.allocator.free(self.ram);
    }

    pub fn loadByte(self: *const Memory, addr: u32) MemoryError!u8 {
        _ = self; _ = addr;
        @panic("not implemented");
    }

    pub fn loadHalfword(self: *const Memory, addr: u32) MemoryError!u16 {
        _ = self; _ = addr;
        @panic("not implemented");
    }

    pub fn loadWord(self: *const Memory, addr: u32) MemoryError!u32 {
        _ = self; _ = addr;
        @panic("not implemented");
    }

    pub fn storeByte(self: *Memory, addr: u32, value: u8) MemoryError!void {
        _ = self; _ = addr; _ = value;
        @panic("not implemented");
    }

    pub fn storeHalfword(self: *Memory, addr: u32, value: u16) MemoryError!void {
        _ = self; _ = addr; _ = value;
        @panic("not implemented");
    }

    pub fn storeWord(self: *Memory, addr: u32, value: u32) MemoryError!void {
        _ = self; _ = addr; _ = value;
        @panic("not implemented");
    }
};

test "store/load byte round-trips" {
    var mem = try Memory.init(std.testing.allocator);
    defer mem.deinit();
    try mem.storeByte(RAM_BASE + 100, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), try mem.loadByte(RAM_BASE + 100));
}

test "word store/load is little-endian" {
    var mem = try Memory.init(std.testing.allocator);
    defer mem.deinit();
    try mem.storeWord(RAM_BASE + 0, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u8, 0xEF), try mem.loadByte(RAM_BASE + 0));
    try std.testing.expectEqual(@as(u8, 0xBE), try mem.loadByte(RAM_BASE + 1));
    try std.testing.expectEqual(@as(u8, 0xAD), try mem.loadByte(RAM_BASE + 2));
    try std.testing.expectEqual(@as(u8, 0xDE), try mem.loadByte(RAM_BASE + 3));
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), try mem.loadWord(RAM_BASE + 0));
}

test "halfword store/load is little-endian" {
    var mem = try Memory.init(std.testing.allocator);
    defer mem.deinit();
    try mem.storeHalfword(RAM_BASE + 0, 0xBEEF);
    try std.testing.expectEqual(@as(u8, 0xEF), try mem.loadByte(RAM_BASE + 0));
    try std.testing.expectEqual(@as(u8, 0xBE), try mem.loadByte(RAM_BASE + 1));
    try std.testing.expectEqual(@as(u16, 0xBEEF), try mem.loadHalfword(RAM_BASE + 0));
}

test "out-of-RAM access returns OutOfBounds" {
    var mem = try Memory.init(std.testing.allocator);
    defer mem.deinit();
    try std.testing.expectError(MemoryError.OutOfBounds, mem.loadByte(0));
    try std.testing.expectError(MemoryError.OutOfBounds, mem.loadByte(0x9000_0000));
}

test "misaligned word load returns MisalignedAccess" {
    var mem = try Memory.init(std.testing.allocator);
    defer mem.deinit();
    try std.testing.expectError(MemoryError.MisalignedAccess, mem.loadWord(RAM_BASE + 1));
}
```

Add to `src/main.zig` test discovery:

```zig
comptime {
    _ = @import("cpu.zig");
    _ = @import("memory.zig");
}
```

- [ ] **Step 2: Run tests, verify they panic**

Run: `zig build test`
Expected: panics on first call into `storeByte`/etc.

- [ ] **Step 3: Implement load/store**

Replace the panicking bodies in `src/memory.zig`:

```zig
fn ramOffset(addr: u32) MemoryError!usize {
    if (addr < RAM_BASE) return MemoryError.OutOfBounds;
    const offset = addr - RAM_BASE;
    if (offset >= RAM_SIZE) return MemoryError.OutOfBounds;
    return @as(usize, offset);
}

pub fn loadByte(self: *const Memory, addr: u32) MemoryError!u8 {
    const off = try ramOffset(addr);
    return self.ram[off];
}

pub fn loadHalfword(self: *const Memory, addr: u32) MemoryError!u16 {
    if (addr & 1 != 0) return MemoryError.MisalignedAccess;
    const off = try ramOffset(addr);
    if (off + 2 > RAM_SIZE) return MemoryError.OutOfBounds;
    return std.mem.readInt(u16, self.ram[off..][0..2], .little);
}

pub fn loadWord(self: *const Memory, addr: u32) MemoryError!u32 {
    if (addr & 3 != 0) return MemoryError.MisalignedAccess;
    const off = try ramOffset(addr);
    if (off + 4 > RAM_SIZE) return MemoryError.OutOfBounds;
    return std.mem.readInt(u32, self.ram[off..][0..4], .little);
}

pub fn storeByte(self: *Memory, addr: u32, value: u8) MemoryError!void {
    const off = try ramOffset(addr);
    self.ram[off] = value;
}

pub fn storeHalfword(self: *Memory, addr: u32, value: u16) MemoryError!void {
    if (addr & 1 != 0) return MemoryError.MisalignedAccess;
    const off = try ramOffset(addr);
    if (off + 2 > RAM_SIZE) return MemoryError.OutOfBounds;
    std.mem.writeInt(u16, self.ram[off..][0..2], value, .little);
}

pub fn storeWord(self: *Memory, addr: u32, value: u32) MemoryError!void {
    if (addr & 3 != 0) return MemoryError.MisalignedAccess;
    const off = try ramOffset(addr);
    if (off + 4 > RAM_SIZE) return MemoryError.OutOfBounds;
    std.mem.writeInt(u32, self.ram[off..][0..4], value, .little);
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/memory.zig src/main.zig
git commit -m "feat: add 128 MB RAM with little-endian load/store and bounds checks"
```

---

### Task 4: Halt MMIO device

**Files:**
- Create: `src/devices/halt.zig`
- Modify: `src/main.zig` (add `_ = @import("devices/halt.zig");`)

**Why this task:** Add the simplest possible MMIO device — writing any byte to address `0x00100000` halts the emulator with that byte as the exit code. Used by demo programs and (later) test harnesses to terminate cleanly.

- [ ] **Step 1: Write the failing test**

Create `src/devices/halt.zig`:

```zig
const std = @import("std");

pub const HALT_BASE: u32 = 0x0010_0000;
pub const HALT_SIZE: u32 = 8;

pub const HaltError = error{Halt};

pub const Halt = struct {
    exit_code: ?u8 = null,

    pub fn init() Halt {
        return .{};
    }

    pub fn writeByte(self: *Halt, offset: u32, value: u8) HaltError!void {
        _ = self; _ = offset; _ = value;
        @panic("not implemented");
    }
};

test "writing any byte sets exit_code and returns error.Halt" {
    var halt = Halt.init();
    try std.testing.expectError(HaltError.Halt, halt.writeByte(0, 42));
    try std.testing.expectEqual(@as(?u8, 42), halt.exit_code);
}

test "exit_code is null before any write" {
    const halt = Halt.init();
    try std.testing.expectEqual(@as(?u8, null), halt.exit_code);
}
```

Add to `src/main.zig`:

```zig
comptime {
    _ = @import("cpu.zig");
    _ = @import("memory.zig");
    _ = @import("devices/halt.zig");
}
```

- [ ] **Step 2: Run, verify panic**

Run: `zig build test`
Expected: panics in `writeByte`.

- [ ] **Step 3: Implement `writeByte`**

```zig
pub fn writeByte(self: *Halt, offset: u32, value: u8) HaltError!void {
    _ = offset; // entire range maps to halt
    self.exit_code = value;
    return HaltError.Halt;
}
```

- [ ] **Step 4: Verify pass**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/devices/halt.zig src/main.zig
git commit -m "feat: add Halt MMIO device"
```

---

### Task 5: UART device (output-focused NS16550A subset)

**Files:**
- Create: `src/devices/uart.zig`
- Modify: `src/main.zig` (add `_ = @import("devices/uart.zig");`)

**Why this task:** Add the UART that bytes get written to. Output goes to a configurable `std.io.AnyWriter` so tests can capture it; production wires it to host stdout.

- [ ] **Step 1: Write the failing test**

Create `src/devices/uart.zig`:

```zig
const std = @import("std");

pub const UART_BASE: u32 = 0x1000_0000;
pub const UART_SIZE: u32 = 0x100;

// 16550 register offsets we care about.
const REG_THR: u32 = 0x00; // Transmit Holding Register (write)
const REG_RBR: u32 = 0x00; // Receive Buffer Register (read) — stubbed
const REG_IER: u32 = 0x01;
const REG_FCR: u32 = 0x02;
const REG_LCR: u32 = 0x03;
const REG_MCR: u32 = 0x04;
const REG_LSR: u32 = 0x05; // Line Status Register
const REG_MSR: u32 = 0x06;
const REG_SR:  u32 = 0x07; // Scratch

const LSR_THRE: u8 = 0x20; // Transmit Holding Register Empty
const LSR_TEMT: u8 = 0x40; // Transmitter Empty

pub const UartError = error{
    UnexpectedRegister,
    WriteFailed,
};

pub const Uart = struct {
    writer: std.io.AnyWriter,
    // Echo-back state for poke-and-peek registers.
    ier: u8 = 0,
    lcr: u8 = 0,
    mcr: u8 = 0,
    sr:  u8 = 0,

    pub fn init(writer: std.io.AnyWriter) Uart {
        return .{ .writer = writer };
    }

    pub fn readByte(self: *Uart, offset: u32) UartError!u8 {
        _ = self; _ = offset;
        @panic("not implemented");
    }

    pub fn writeByte(self: *Uart, offset: u32, value: u8) UartError!void {
        _ = self; _ = offset; _ = value;
        @panic("not implemented");
    }
};

test "writing to THR sends byte to writer" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var uart = Uart.init(buf.writer().any());
    try uart.writeByte(REG_THR, 'A');
    try uart.writeByte(REG_THR, 'B');
    try std.testing.expectEqualStrings("AB", buf.items);
}

test "LSR always reports ready" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var uart = Uart.init(buf.writer().any());
    const lsr = try uart.readByte(REG_LSR);
    try std.testing.expectEqual(@as(u8, LSR_THRE | LSR_TEMT), lsr);
}

test "LCR/MCR/IER/SR round-trip" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var uart = Uart.init(buf.writer().any());
    try uart.writeByte(REG_LCR, 0x83);
    try uart.writeByte(REG_MCR, 0x0B);
    try uart.writeByte(REG_IER, 0x05);
    try uart.writeByte(REG_SR, 0xAA);
    try std.testing.expectEqual(@as(u8, 0x83), try uart.readByte(REG_LCR));
    try std.testing.expectEqual(@as(u8, 0x0B), try uart.readByte(REG_MCR));
    try std.testing.expectEqual(@as(u8, 0x05), try uart.readByte(REG_IER));
    try std.testing.expectEqual(@as(u8, 0xAA), try uart.readByte(REG_SR));
}

test "RBR (read of THR offset) returns 0 (input stubbed)" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var uart = Uart.init(buf.writer().any());
    try std.testing.expectEqual(@as(u8, 0), try uart.readByte(REG_RBR));
}
```

Add to `src/main.zig`:

```zig
comptime {
    _ = @import("cpu.zig");
    _ = @import("memory.zig");
    _ = @import("devices/halt.zig");
    _ = @import("devices/uart.zig");
}
```

- [ ] **Step 2: Run, verify panic**

Run: `zig build test`
Expected: panics in `readByte`/`writeByte`.

- [ ] **Step 3: Implement `readByte` and `writeByte`**

```zig
pub fn readByte(self: *Uart, offset: u32) UartError!u8 {
    return switch (offset) {
        REG_RBR => 0, // input stubbed in Plan 1.A
        REG_IER => self.ier,
        REG_FCR => 0, // FCR/IIR: read returns 0
        REG_LCR => self.lcr,
        REG_MCR => self.mcr,
        REG_LSR => LSR_THRE | LSR_TEMT,
        REG_MSR => 0,
        REG_SR  => self.sr,
        else    => UartError.UnexpectedRegister,
    };
}

pub fn writeByte(self: *Uart, offset: u32, value: u8) UartError!void {
    switch (offset) {
        REG_THR => {
            self.writer.writeByte(value) catch return UartError.WriteFailed;
        },
        REG_IER => self.ier = value,
        REG_FCR => {}, // accept, no-op
        REG_LCR => self.lcr = value,
        REG_MCR => self.mcr = value,
        REG_LSR => {}, // read-only on real hardware; ignore writes
        REG_MSR => {},
        REG_SR  => self.sr = value,
        else => return UartError.UnexpectedRegister,
    }
}
```

- [ ] **Step 4: Verify tests pass**

Run: `zig build test`
Expected: all UART tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/devices/uart.zig src/main.zig
git commit -m "feat: add NS16550A UART (output-focused subset)"
```

---

### Task 6: Memory routing — wire UART and Halt into Memory

**Files:**
- Modify: `src/memory.zig`

**Why this task:** Now that we have devices, route memory accesses to them. After this task, a single `Memory.storeByte(0x10000000, 'A')` call results in `'A'` flowing through the UART writer; `Memory.storeByte(0x00100000, 0)` triggers `error.Halt`. This is the integration point that lets the CPU drive devices through normal load/store.

- [ ] **Step 1: Update `Memory` to hold device pointers and add tests**

Replace `src/memory.zig`'s top-level structure:

```zig
const std = @import("std");
const halt_dev = @import("devices/halt.zig");
const uart_dev = @import("devices/uart.zig");

pub const RAM_BASE: u32 = 0x8000_0000;
pub const RAM_SIZE: usize = 128 * 1024 * 1024;

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
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        halt: *halt_dev.Halt,
        uart: *uart_dev.Uart,
    ) !Memory {
        const ram = try allocator.alloc(u8, RAM_SIZE);
        @memset(ram, 0);
        return .{ .ram = ram, .halt = halt, .uart = uart, .allocator = allocator };
    }

    pub fn deinit(self: *Memory) void {
        self.allocator.free(self.ram);
    }

    fn ramOffset(addr: u32) MemoryError!usize {
        if (addr < RAM_BASE) return MemoryError.OutOfBounds;
        const offset = addr - RAM_BASE;
        if (offset >= RAM_SIZE) return MemoryError.OutOfBounds;
        return @as(usize, offset);
    }

    fn inRange(addr: u32, base: u32, size: u32) bool {
        return addr >= base and addr < base +% size;
    }

    pub fn loadByte(self: *Memory, addr: u32) MemoryError!u8 {
        if (inRange(addr, uart_dev.UART_BASE, uart_dev.UART_SIZE)) {
            return self.uart.readByte(addr - uart_dev.UART_BASE)
                catch |e| switch (e) {
                    error.UnexpectedRegister => MemoryError.UnexpectedRegister,
                    error.WriteFailed => MemoryError.WriteFailed,
                };
        }
        if (inRange(addr, halt_dev.HALT_BASE, halt_dev.HALT_SIZE)) {
            return 0;
        }
        const off = try ramOffset(addr);
        return self.ram[off];
    }

    pub fn loadHalfword(self: *Memory, addr: u32) MemoryError!u16 {
        if (addr & 1 != 0) return MemoryError.MisalignedAccess;
        const lo = try self.loadByte(addr);
        const hi = try self.loadByte(addr + 1);
        return (@as(u16, hi) << 8) | @as(u16, lo);
    }

    pub fn loadWord(self: *Memory, addr: u32) MemoryError!u32 {
        if (addr & 3 != 0) return MemoryError.MisalignedAccess;
        // Fast path for RAM:
        if (addr >= RAM_BASE) {
            const off = try ramOffset(addr);
            if (off + 4 > RAM_SIZE) return MemoryError.OutOfBounds;
            return std.mem.readInt(u32, self.ram[off..][0..4], .little);
        }
        // Generic byte-by-byte path for MMIO:
        const b0 = try self.loadByte(addr);
        const b1 = try self.loadByte(addr + 1);
        const b2 = try self.loadByte(addr + 2);
        const b3 = try self.loadByte(addr + 3);
        return (@as(u32, b3) << 24) | (@as(u32, b2) << 16) |
               (@as(u32, b1) << 8)  |  @as(u32, b0);
    }

    pub fn storeByte(self: *Memory, addr: u32, value: u8) MemoryError!void {
        if (inRange(addr, uart_dev.UART_BASE, uart_dev.UART_SIZE)) {
            self.uart.writeByte(addr - uart_dev.UART_BASE, value)
                catch |e| switch (e) {
                    error.UnexpectedRegister => return MemoryError.UnexpectedRegister,
                    error.WriteFailed => return MemoryError.WriteFailed,
                };
            return;
        }
        if (inRange(addr, halt_dev.HALT_BASE, halt_dev.HALT_SIZE)) {
            self.halt.writeByte(addr - halt_dev.HALT_BASE, value)
                catch |e| switch (e) {
                    error.Halt => return MemoryError.Halt,
                };
            return;
        }
        const off = try ramOffset(addr);
        self.ram[off] = value;
    }

    pub fn storeHalfword(self: *Memory, addr: u32, value: u16) MemoryError!void {
        if (addr & 1 != 0) return MemoryError.MisalignedAccess;
        try self.storeByte(addr,     @truncate(value));
        try self.storeByte(addr + 1, @truncate(value >> 8));
    }

    pub fn storeWord(self: *Memory, addr: u32, value: u32) MemoryError!void {
        if (addr & 3 != 0) return MemoryError.MisalignedAccess;
        if (addr >= RAM_BASE) {
            const off = try ramOffset(addr);
            if (off + 4 > RAM_SIZE) return MemoryError.OutOfBounds;
            std.mem.writeInt(u32, self.ram[off..][0..4], value, .little);
            return;
        }
        try self.storeByte(addr,     @truncate(value));
        try self.storeByte(addr + 1, @truncate(value >> 8));
        try self.storeByte(addr + 2, @truncate(value >> 16));
        try self.storeByte(addr + 3, @truncate(value >> 24));
    }
};
```

Update the existing tests to construct devices first, and add new routing tests:

```zig
const TestRig = struct {
    halt: halt_dev.Halt,
    uart: uart_dev.Uart,
    buf: std.ArrayList(u8),
    mem: Memory,

    fn init(allocator: std.mem.Allocator) !TestRig {
        var rig: TestRig = undefined;
        rig.halt = halt_dev.Halt.init();
        rig.buf = std.ArrayList(u8).init(allocator);
        rig.uart = uart_dev.Uart.init(rig.buf.writer().any());
        rig.mem = try Memory.init(allocator, &rig.halt, &rig.uart);
        return rig;
    }

    fn deinit(self: *TestRig) void {
        self.mem.deinit();
        self.buf.deinit();
    }
};

test "RAM byte round-trip via routed Memory" {
    var rig = try TestRig.init(std.testing.allocator);
    defer rig.deinit();
    try rig.mem.storeByte(RAM_BASE + 100, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), try rig.mem.loadByte(RAM_BASE + 100));
}

test "store to UART THR forwards to writer" {
    var rig = try TestRig.init(std.testing.allocator);
    defer rig.deinit();
    try rig.mem.storeByte(uart_dev.UART_BASE, 'X');
    try rig.mem.storeByte(uart_dev.UART_BASE, 'Y');
    try std.testing.expectEqualStrings("XY", rig.buf.items);
}

test "store to halt MMIO returns error.Halt" {
    var rig = try TestRig.init(std.testing.allocator);
    defer rig.deinit();
    try std.testing.expectError(MemoryError.Halt, rig.mem.storeByte(halt_dev.HALT_BASE, 7));
    try std.testing.expectEqual(@as(?u8, 7), rig.halt.exit_code);
}

test "word store/load is little-endian (in RAM)" {
    var rig = try TestRig.init(std.testing.allocator);
    defer rig.deinit();
    try rig.mem.storeWord(RAM_BASE, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u8, 0xEF), try rig.mem.loadByte(RAM_BASE));
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), try rig.mem.loadWord(RAM_BASE));
}

test "out-of-RAM access (and not in any device range) returns OutOfBounds" {
    var rig = try TestRig.init(std.testing.allocator);
    defer rig.deinit();
    try std.testing.expectError(MemoryError.OutOfBounds, rig.mem.loadByte(0x4000_0000));
}

test "misaligned word load returns MisalignedAccess" {
    var rig = try TestRig.init(std.testing.allocator);
    defer rig.deinit();
    try std.testing.expectError(MemoryError.MisalignedAccess, rig.mem.loadWord(RAM_BASE + 1));
}
```

Delete the old (no-routing) tests from earlier — they no longer compile because `Memory.init` now needs device pointers.

- [ ] **Step 2: Run, verify all tests pass**

Run: `zig build test`
Expected: all tests pass (cpu, halt, uart, and the new routed memory tests).

- [ ] **Step 3: Commit**

```bash
git add src/memory.zig
git commit -m "feat: route Memory accesses to UART and Halt MMIO devices"
```

---

### Task 7: Decoder skeleton + LUI + AUIPC

**Files:**
- Create: `src/decoder.zig`
- Modify: `src/main.zig` (add `_ = @import("decoder.zig");`)

**Why this task:** Stand up the `Instruction` type and `decode(u32) → Instruction`. Implement the two upper-immediate instructions (LUI, AUIPC), which are simple U-type and shake out the bitfield helpers we'll reuse for everything else.

- [ ] **Step 1: Write the failing test**

Create `src/decoder.zig`:

```zig
const std = @import("std");

pub const Op = enum {
    lui,
    auipc,
    // (more added in later tasks)
    illegal,
};

pub const Instruction = struct {
    op: Op,
    rd: u5 = 0,
    rs1: u5 = 0,
    rs2: u5 = 0,
    imm: i32 = 0,
    raw: u32 = 0,
};

// Bitfield helpers
pub fn opcode(word: u32) u7 {
    return @truncate(word & 0x7F);
}

pub fn rd(word: u32) u5 {
    return @truncate((word >> 7) & 0x1F);
}

pub fn rs1(word: u32) u5 {
    return @truncate((word >> 15) & 0x1F);
}

pub fn rs2(word: u32) u5 {
    return @truncate((word >> 20) & 0x1F);
}

pub fn funct3(word: u32) u3 {
    return @truncate((word >> 12) & 0x7);
}

pub fn funct7(word: u32) u7 {
    return @truncate((word >> 25) & 0x7F);
}

// U-type immediate: bits 31:12 → upper 20 bits of result, lower 12 are zero.
pub fn immU(word: u32) i32 {
    return @bitCast(word & 0xFFFF_F000);
}

pub fn decode(word: u32) Instruction {
    _ = word;
    @panic("not implemented");
}

test "decode LUI t0, 0x10000 → 0x100002B7" {
    const i = decode(0x100002B7);
    try std.testing.expectEqual(Op.lui, i.op);
    try std.testing.expectEqual(@as(u5, 5), i.rd);
    try std.testing.expectEqual(@as(i32, 0x1000_0000), i.imm);
}

test "decode AUIPC ra, 0x80000 → 0x800000_97" {
    // auipc x1, 0x80000  → opcode=0x17, rd=1, imm[31:12]=0x80000
    const i = decode(0x80000097);
    try std.testing.expectEqual(Op.auipc, i.op);
    try std.testing.expectEqual(@as(u5, 1), i.rd);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x8000_0000))), i.imm);
}

test "unknown opcode decodes to illegal" {
    const i = decode(0x0000_0000); // all-zero is not a valid encoding
    try std.testing.expectEqual(Op.illegal, i.op);
    try std.testing.expectEqual(@as(u32, 0), i.raw);
}
```

Add to `src/main.zig`:

```zig
comptime {
    _ = @import("cpu.zig");
    _ = @import("memory.zig");
    _ = @import("devices/halt.zig");
    _ = @import("devices/uart.zig");
    _ = @import("decoder.zig");
}
```

- [ ] **Step 2: Run, verify panic**

Run: `zig build test`
Expected: panic on first `decode` call.

- [ ] **Step 3: Implement `decode`**

Replace the panicking body:

```zig
pub fn decode(word: u32) Instruction {
    return switch (opcode(word)) {
        0b0110111 => .{ .op = .lui,   .rd = rd(word), .imm = immU(word), .raw = word },
        0b0010111 => .{ .op = .auipc, .rd = rd(word), .imm = immU(word), .raw = word },
        else      => .{ .op = .illegal, .raw = word },
    };
}
```

- [ ] **Step 4: Verify tests pass**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/decoder.zig src/main.zig
git commit -m "feat: add Instruction decoder with LUI and AUIPC"
```

---

### Task 8: Execute module + LUI/AUIPC execution

**Files:**
- Create: `src/execute.zig`
- Modify: `src/cpu.zig` (add `step()` that calls into decoder + execute)
- Modify: `src/main.zig` (add `_ = @import("execute.zig");`)

**Why this task:** Wire decode → execute → CPU state mutation. After this task, the CPU can `step()` through real instructions for the first time, even if only LUI and AUIPC are implemented.

- [ ] **Step 1: Write the failing test**

Create `src/execute.zig`:

```zig
const std = @import("std");
const cpu_mod = @import("cpu.zig");
const decoder = @import("decoder.zig");

pub const ExecuteError = error{
    UnsupportedInstruction,
    IllegalInstruction,
    Halt,
    OutOfBounds,
    MisalignedAccess,
    UnexpectedRegister,
    WriteFailed,
};

pub fn dispatch(instr: decoder.Instruction, cpu: *cpu_mod.Cpu) ExecuteError!void {
    _ = instr; _ = cpu;
    @panic("not implemented");
}

const halt_dev = @import("devices/halt.zig");
const uart_dev = @import("devices/uart.zig");
const mem_mod = @import("memory.zig");

const Rig = struct {
    halt: halt_dev.Halt,
    uart: uart_dev.Uart,
    buf: std.ArrayList(u8),
    mem: mem_mod.Memory,
    cpu: cpu_mod.Cpu,

    fn init(allocator: std.mem.Allocator, entry: u32) !Rig {
        var rig: Rig = undefined;
        rig.halt = halt_dev.Halt.init();
        rig.buf = std.ArrayList(u8).init(allocator);
        rig.uart = uart_dev.Uart.init(rig.buf.writer().any());
        rig.mem = try mem_mod.Memory.init(allocator, &rig.halt, &rig.uart);
        rig.cpu = cpu_mod.Cpu.init(&rig.mem, entry);
        return rig;
    }

    fn deinit(self: *Rig) void {
        self.mem.deinit();
        self.buf.deinit();
    }
};

test "LUI loads upper-20-bit immediate into rd, lower 12 bits zero" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try dispatch(.{ .op = .lui, .rd = 5, .imm = @as(i32, @bitCast(@as(u32, 0x1000_0000))) }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x1000_0000), rig.cpu.readReg(5));
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.pc);
}

test "AUIPC = pc + imm" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE + 0x100);
    defer rig.deinit();
    try dispatch(.{ .op = .auipc, .rd = 1, .imm = @as(i32, @bitCast(@as(u32, 0x8000_0000))) }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x100 +% 0x8000_0000, rig.cpu.readReg(1));
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x100 + 4, rig.cpu.pc);
}
```

Modify `src/cpu.zig` to wire `step()`:

```zig
const std = @import("std");
const decoder = @import("decoder.zig");
const execute = @import("execute.zig");
const Memory = @import("memory.zig").Memory;
const MemoryError = @import("memory.zig").MemoryError;

pub const StepError = error{
    UnsupportedInstruction,
    IllegalInstruction,
    Halt,
    OutOfBounds,
    MisalignedAccess,
    UnexpectedRegister,
    WriteFailed,
};

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

    pub fn readReg(self: *const Cpu, idx: u5) u32 {
        if (idx == 0) return 0;
        return self.regs[idx];
    }

    pub fn writeReg(self: *Cpu, idx: u5, value: u32) void {
        if (idx == 0) return;
        self.regs[idx] = value;
    }

    pub fn step(self: *Cpu) StepError!void {
        const word = self.memory.loadWord(self.pc) catch |e| return mapMemErr(e);
        const instr = decoder.decode(word);
        return execute.dispatch(instr, self) catch |e| @errorCast(e);
    }

    fn mapMemErr(e: MemoryError) StepError {
        return switch (e) {
            error.OutOfBounds       => StepError.OutOfBounds,
            error.MisalignedAccess  => StepError.MisalignedAccess,
            error.UnexpectedRegister => StepError.UnexpectedRegister,
            error.WriteFailed       => StepError.WriteFailed,
            error.Halt              => StepError.Halt,
        };
    }
};

test "x0 is hardwired to zero — write is a no-op" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    cpu.writeReg(0, 0xDEADBEEF);
    try std.testing.expectEqual(@as(u32, 0), cpu.readReg(0));
}

test "writeReg/readReg round-trip for x1" {
    var dummy_mem: Memory = undefined;
    var cpu = Cpu.init(&dummy_mem, 0);
    cpu.writeReg(1, 0xCAFEBABE);
    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), cpu.readReg(1));
}

test "all registers initialise to zero" {
    var dummy_mem: Memory = undefined;
    const cpu = Cpu.init(&dummy_mem, 0);
    var i: u5 = 0;
    while (true) : (i += 1) {
        try std.testing.expectEqual(@as(u32, 0), cpu.readReg(i));
        if (i == 31) break;
    }
}
```

Add to `src/main.zig`:

```zig
comptime {
    _ = @import("cpu.zig");
    _ = @import("memory.zig");
    _ = @import("devices/halt.zig");
    _ = @import("devices/uart.zig");
    _ = @import("decoder.zig");
    _ = @import("execute.zig");
}
```

- [ ] **Step 2: Run, verify panic**

Run: `zig build test`
Expected: panic on first `dispatch` call.

- [ ] **Step 3: Implement `dispatch` for LUI and AUIPC**

In `src/execute.zig`:

```zig
pub fn dispatch(instr: decoder.Instruction, cpu: *cpu_mod.Cpu) ExecuteError!void {
    switch (instr.op) {
        .lui => {
            cpu.writeReg(instr.rd, @bitCast(instr.imm));
            cpu.pc +%= 4;
        },
        .auipc => {
            const result: u32 = cpu.pc +% @as(u32, @bitCast(instr.imm));
            cpu.writeReg(instr.rd, result);
            cpu.pc +%= 4;
        },
        .illegal => return ExecuteError.IllegalInstruction,
    }
}
```

- [ ] **Step 4: Verify tests pass**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/cpu.zig src/execute.zig src/main.zig
git commit -m "feat: wire decoder + execute into Cpu.step; implement LUI/AUIPC"
```

---

### Task 9: JAL and JALR

**Files:**
- Modify: `src/decoder.zig` (add J-type immediate, JAL/JALR decoding)
- Modify: `src/execute.zig` (add JAL/JALR execution)

**Why this task:** Add unconditional control flow. JAL is J-type with a tortured 21-bit immediate; JALR is I-type. Both write `pc+4` to rd as the return address.

- [ ] **Step 1: Write tests in `src/decoder.zig`**

Add to `Op` enum:

```zig
pub const Op = enum {
    lui, auipc, jal, jalr,
    illegal,
};
```

Add helpers and tests:

```zig
// I-type immediate: bits 31:20 sign-extended.
pub fn immI(word: u32) i32 {
    const raw: u32 = (word >> 20) & 0xFFF;
    // Sign-extend bit 11 of raw to 32 bits.
    return @as(i32, @intCast(@as(i12, @bitCast(@as(u12, @truncate(raw))))));
}

// J-type immediate: bits scrambled, multiplied by 2 implicitly.
pub fn immJ(word: u32) i32 {
    const imm20:    u32 = (word >> 31) & 0x1;
    const imm10_1:  u32 = (word >> 21) & 0x3FF;
    const imm11:    u32 = (word >> 20) & 0x1;
    const imm19_12: u32 = (word >> 12) & 0xFF;
    const unsigned: u32 =
        (imm20    << 20) |
        (imm19_12 << 12) |
        (imm11    << 11) |
        (imm10_1  << 1);
    // Sign-extend from bit 20.
    if (imm20 == 1) {
        return @bitCast(unsigned | 0xFFE0_0000);
    }
    return @bitCast(unsigned);
}

test "decode JAL ra, +0x10 → opcode 0x6F, rd=1, imm=16" {
    // jal x1, 0x10  →  imm[20|10:1|11|19:12] = 0,0000001000,0,00000000
    // Encoded: bit 31=0, 30:21=0000001000, 20=0, 19:12=00000000, 11:7=00001, 6:0=1101111
    // = 0x010000EF
    const i = decode(0x010000EF);
    try std.testing.expectEqual(Op.jal, i.op);
    try std.testing.expectEqual(@as(u5, 1), i.rd);
    try std.testing.expectEqual(@as(i32, 0x10), i.imm);
}

test "decode JAL with negative offset" {
    // jal x0, -16  encoded as 0xFE1FF06F
    const i = decode(0xFE1FF06F);
    try std.testing.expectEqual(Op.jal, i.op);
    try std.testing.expectEqual(@as(u5, 0), i.rd);
    try std.testing.expectEqual(@as(i32, -16), i.imm);
}

test "decode JALR x1, x2, 4 → opcode 0x67" {
    // funct3 = 000, opcode = 1100111
    // imm[11:0]=0x004, rs1=x2=00010, funct3=000, rd=x1=00001, opcode=1100111
    // = 0x004100E7
    const i = decode(0x004100E7);
    try std.testing.expectEqual(Op.jalr, i.op);
    try std.testing.expectEqual(@as(u5, 1), i.rd);
    try std.testing.expectEqual(@as(u5, 2), i.rs1);
    try std.testing.expectEqual(@as(i32, 4), i.imm);
}
```

Update `decode` switch:

```zig
pub fn decode(word: u32) Instruction {
    return switch (opcode(word)) {
        0b0110111 => .{ .op = .lui,   .rd = rd(word), .imm = immU(word), .raw = word },
        0b0010111 => .{ .op = .auipc, .rd = rd(word), .imm = immU(word), .raw = word },
        0b1101111 => .{ .op = .jal,   .rd = rd(word), .imm = immJ(word), .raw = word },
        0b1100111 => .{ .op = .jalr,  .rd = rd(word), .rs1 = rs1(word), .imm = immI(word), .raw = word },
        else      => .{ .op = .illegal, .raw = word },
    };
}
```

- [ ] **Step 2: Add execute tests in `src/execute.zig`**

```zig
test "JAL stores pc+4 in rd, jumps to pc+offset" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try dispatch(.{ .op = .jal, .rd = 1, .imm = 16 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.readReg(1));
    try std.testing.expectEqual(mem_mod.RAM_BASE + 16, rig.cpu.pc);
}

test "JAL with rd=x0 still jumps but discards link" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try dispatch(.{ .op = .jal, .rd = 0, .imm = -8 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.readReg(0));
    try std.testing.expectEqual(mem_mod.RAM_BASE -% 8, rig.cpu.pc);
}

test "JALR uses rs1+imm for target, clears low bit" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(2, mem_mod.RAM_BASE + 0x101); // odd target
    try dispatch(.{ .op = .jalr, .rd = 1, .rs1 = 2, .imm = 0 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.readReg(1));
    // RISC-V spec: PC = (rs1 + imm) & ~1
    try std.testing.expectEqual(mem_mod.RAM_BASE + 0x100, rig.cpu.pc);
}
```

- [ ] **Step 3: Run, verify failures**

Run: `zig build test`
Expected: decode tests pass; execute tests fail with `error.UnsupportedInstruction` or panic.

- [ ] **Step 4: Implement JAL/JALR in `dispatch`**

Add cases to the `dispatch` switch:

```zig
.jal => {
    const link = cpu.pc +% 4;
    const target = cpu.pc +% @as(u32, @bitCast(instr.imm));
    cpu.writeReg(instr.rd, link);
    cpu.pc = target;
},
.jalr => {
    const link = cpu.pc +% 4;
    const target = (cpu.readReg(instr.rs1) +% @as(u32, @bitCast(instr.imm))) & ~@as(u32, 1);
    cpu.writeReg(instr.rd, link);
    cpu.pc = target;
},
```

- [ ] **Step 5: Verify tests pass**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/decoder.zig src/execute.zig
git commit -m "feat: implement JAL and JALR (unconditional jumps)"
```

---

### Task 10: Branches (BEQ/BNE/BLT/BGE/BLTU/BGEU)

**Files:**
- Modify: `src/decoder.zig` (add B-type immediate, branch decoding)
- Modify: `src/execute.zig` (add branch execution)

**Why this task:** Conditional control flow. Six branch instructions, all B-type, all dispatched by funct3. Test taken-branch and not-taken-branch for at least one each.

- [ ] **Step 1: Extend decoder**

Add to `Op` enum:

```zig
pub const Op = enum {
    lui, auipc, jal, jalr,
    beq, bne, blt, bge, bltu, bgeu,
    illegal,
};
```

Add B-type immediate helper and tests:

```zig
// B-type immediate: bits 31|7|30:25|11:8, multiplied by 2 implicitly.
pub fn immB(word: u32) i32 {
    const imm12:   u32 = (word >> 31) & 0x1;
    const imm10_5: u32 = (word >> 25) & 0x3F;
    const imm4_1:  u32 = (word >> 8)  & 0xF;
    const imm11:   u32 = (word >> 7)  & 0x1;
    const unsigned: u32 =
        (imm12   << 12) |
        (imm11   << 11) |
        (imm10_5 << 5)  |
        (imm4_1  << 1);
    if (imm12 == 1) {
        return @bitCast(unsigned | 0xFFFF_E000);
    }
    return @bitCast(unsigned);
}

test "decode BEQ t2, x0, +0x10 → 0x00038863" {
    const i = decode(0x00038863);
    try std.testing.expectEqual(Op.beq, i.op);
    try std.testing.expectEqual(@as(u5, 7), i.rs1);
    try std.testing.expectEqual(@as(u5, 0), i.rs2);
    try std.testing.expectEqual(@as(i32, 16), i.imm);
}

test "decode BNE with negative offset" {
    // bne x1, x2, -8  → imm = -8
    // Encoding: imm12=1, imm11=1, imm10_5=111111, imm4_1=1100
    // bit 31=1, 30:25=111111, 24:20=00010, 19:15=00001, 14:12=001, 11:8=1100, 7=1, 6:0=1100011
    // = 0xFE209CE3
    const i = decode(0xFE209CE3);
    try std.testing.expectEqual(Op.bne, i.op);
    try std.testing.expectEqual(@as(u5, 1), i.rs1);
    try std.testing.expectEqual(@as(u5, 2), i.rs2);
    try std.testing.expectEqual(@as(i32, -8), i.imm);
}
```

Add branch decode case:

```zig
0b1100011 => {
    const op: Op = switch (funct3(word)) {
        0b000 => .beq,
        0b001 => .bne,
        0b100 => .blt,
        0b101 => .bge,
        0b110 => .bltu,
        0b111 => .bgeu,
        else  => .illegal,
    };
    return .{ .op = op, .rs1 = rs1(word), .rs2 = rs2(word), .imm = immB(word), .raw = word };
},
```

- [ ] **Step 2: Add execute tests**

```zig
test "BEQ taken: jumps when rs1 == rs2" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 42);
    rig.cpu.writeReg(2, 42);
    try dispatch(.{ .op = .beq, .rs1 = 1, .rs2 = 2, .imm = 12 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 12, rig.cpu.pc);
}

test "BEQ not-taken: pc += 4 when rs1 != rs2" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 42);
    rig.cpu.writeReg(2, 0);
    try dispatch(.{ .op = .beq, .rs1 = 1, .rs2 = 2, .imm = 12 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.pc);
}

test "BLT signed: -1 < 1" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, @bitCast(@as(i32, -1)));
    rig.cpu.writeReg(2, 1);
    try dispatch(.{ .op = .blt, .rs1 = 1, .rs2 = 2, .imm = 8 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 8, rig.cpu.pc);
}

test "BLTU unsigned: 0xFFFF_FFFF NOT < 1" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0xFFFF_FFFF);
    rig.cpu.writeReg(2, 1);
    try dispatch(.{ .op = .bltu, .rs1 = 1, .rs2 = 2, .imm = 8 }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.pc);
}
```

- [ ] **Step 3: Run, verify failures**

Run: `zig build test`
Expected: branch execute tests fail.

- [ ] **Step 4: Implement branches in `dispatch`**

```zig
.beq, .bne, .blt, .bge, .bltu, .bgeu => {
    const a = cpu.readReg(instr.rs1);
    const b = cpu.readReg(instr.rs2);
    const taken = switch (instr.op) {
        .beq  => a == b,
        .bne  => a != b,
        .blt  => @as(i32, @bitCast(a)) <  @as(i32, @bitCast(b)),
        .bge  => @as(i32, @bitCast(a)) >= @as(i32, @bitCast(b)),
        .bltu => a <  b,
        .bgeu => a >= b,
        else  => unreachable,
    };
    if (taken) {
        cpu.pc = cpu.pc +% @as(u32, @bitCast(instr.imm));
    } else {
        cpu.pc +%= 4;
    }
},
```

- [ ] **Step 5: Verify pass**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/decoder.zig src/execute.zig
git commit -m "feat: implement conditional branches (BEQ/BNE/BLT/BGE/BLTU/BGEU)"
```

---

### Task 11: Loads and stores (LB/LH/LW/LBU/LHU/SB/SH/SW)

**Files:**
- Modify: `src/decoder.zig` (add load/store decoding, S-type immediate)
- Modify: `src/execute.zig` (add load/store execution)

**Why this task:** Connect the CPU to memory. Loads sign- or zero-extend; stores truncate. After this task, programs can read/write RAM and devices.

- [ ] **Step 1: Extend decoder**

Add to `Op`:

```zig
pub const Op = enum {
    lui, auipc, jal, jalr,
    beq, bne, blt, bge, bltu, bgeu,
    lb, lh, lw, lbu, lhu,
    sb, sh, sw,
    illegal,
};
```

Add S-type immediate helper:

```zig
// S-type immediate: bits 31:25 || 11:7 sign-extended.
pub fn immS(word: u32) i32 {
    const high: u32 = (word >> 25) & 0x7F;
    const low:  u32 = (word >> 7)  & 0x1F;
    const unsigned: u32 = (high << 5) | low;
    if ((high & 0x40) != 0) {
        return @bitCast(unsigned | 0xFFFF_F000);
    }
    return @bitCast(unsigned);
}
```

Add tests:

```zig
test "decode LB t2, 0(t1) → 0x00030383" {
    const i = decode(0x00030383);
    try std.testing.expectEqual(Op.lb, i.op);
    try std.testing.expectEqual(@as(u5, 7), i.rd);
    try std.testing.expectEqual(@as(u5, 6), i.rs1);
    try std.testing.expectEqual(@as(i32, 0), i.imm);
}

test "decode SB t2, 0(t0) → 0x00728023" {
    const i = decode(0x00728023);
    try std.testing.expectEqual(Op.sb, i.op);
    try std.testing.expectEqual(@as(u5, 5), i.rs1);
    try std.testing.expectEqual(@as(u5, 7), i.rs2);
    try std.testing.expectEqual(@as(i32, 0), i.imm);
}

test "decode LW with positive offset" {
    // lw x5, 8(x6)  → imm=8, rs1=6, funct3=010, rd=5, opcode=0000011
    // bits 31:20=0x008, 19:15=00110, 14:12=010, 11:7=00101, 6:0=0000011
    // = 0x00832283
    const i = decode(0x00832283);
    try std.testing.expectEqual(Op.lw, i.op);
    try std.testing.expectEqual(@as(u5, 5), i.rd);
    try std.testing.expectEqual(@as(u5, 6), i.rs1);
    try std.testing.expectEqual(@as(i32, 8), i.imm);
}

test "decode SW with negative offset" {
    // sw x5, -4(x6)  → imm=-4, rs1=6, rs2=5, funct3=010, opcode=0100011
    // imm[11:5]=1111111, imm[4:0]=11100
    // bits 31:25=1111111, 24:20=00101, 19:15=00110, 14:12=010, 11:7=11100, 6:0=0100011
    // = 0xFE532E23
    const i = decode(0xFE532E23);
    try std.testing.expectEqual(Op.sw, i.op);
    try std.testing.expectEqual(@as(u5, 6), i.rs1);
    try std.testing.expectEqual(@as(u5, 5), i.rs2);
    try std.testing.expectEqual(@as(i32, -4), i.imm);
}
```

Add load/store decode cases:

```zig
0b0000011 => {
    const op: Op = switch (funct3(word)) {
        0b000 => .lb,
        0b001 => .lh,
        0b010 => .lw,
        0b100 => .lbu,
        0b101 => .lhu,
        else  => .illegal,
    };
    return .{ .op = op, .rd = rd(word), .rs1 = rs1(word), .imm = immI(word), .raw = word };
},
0b0100011 => {
    const op: Op = switch (funct3(word)) {
        0b000 => .sb,
        0b001 => .sh,
        0b010 => .sw,
        else  => .illegal,
    };
    return .{ .op = op, .rs1 = rs1(word), .rs2 = rs2(word), .imm = immS(word), .raw = word };
},
```

- [ ] **Step 2: Add execute tests**

```zig
test "LB sign-extends a negative byte" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeByte(mem_mod.RAM_BASE + 0x40, 0xFF); // -1 as i8
    rig.cpu.writeReg(1, mem_mod.RAM_BASE);
    try dispatch(.{ .op = .lb, .rd = 2, .rs1 = 1, .imm = 0x40 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), rig.cpu.readReg(2));
}

test "LBU zero-extends" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeByte(mem_mod.RAM_BASE + 0x40, 0xFF);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE);
    try dispatch(.{ .op = .lbu, .rd = 2, .rs1 = 1, .imm = 0x40 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x0000_00FF), rig.cpu.readReg(2));
}

test "LH sign-extends a negative halfword" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeHalfword(mem_mod.RAM_BASE + 0x40, 0x8000);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE);
    try dispatch(.{ .op = .lh, .rd = 2, .rs1 = 1, .imm = 0x40 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_8000), rig.cpu.readReg(2));
}

test "LW round-trip" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try rig.mem.storeWord(mem_mod.RAM_BASE + 0x40, 0xDEAD_BEEF);
    rig.cpu.writeReg(1, mem_mod.RAM_BASE);
    try dispatch(.{ .op = .lw, .rd = 2, .rs1 = 1, .imm = 0x40 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), rig.cpu.readReg(2));
}

test "SB stores low byte of rs2" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, mem_mod.RAM_BASE);
    rig.cpu.writeReg(2, 0xDEAD_BE12);
    try dispatch(.{ .op = .sb, .rs1 = 1, .rs2 = 2, .imm = 8 }, &rig.cpu);
    try std.testing.expectEqual(@as(u8, 0x12), try rig.mem.loadByte(mem_mod.RAM_BASE + 8));
}

test "SW stores full word" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, mem_mod.RAM_BASE);
    rig.cpu.writeReg(2, 0xCAFE_BABE);
    try dispatch(.{ .op = .sw, .rs1 = 1, .rs2 = 2, .imm = 0x10 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xCAFE_BABE), try rig.mem.loadWord(mem_mod.RAM_BASE + 0x10));
}

test "SB to UART address forwards to writer" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0x1000_0000);
    rig.cpu.writeReg(2, 'A');
    try dispatch(.{ .op = .sb, .rs1 = 1, .rs2 = 2, .imm = 0 }, &rig.cpu);
    try std.testing.expectEqualStrings("A", rig.buf.items);
}
```

- [ ] **Step 3: Run, verify failures**

Run: `zig build test`
Expected: load/store execute tests fail.

- [ ] **Step 4: Implement loads and stores in `dispatch`**

```zig
.lb, .lh, .lw, .lbu, .lhu => {
    const addr = cpu.readReg(instr.rs1) +% @as(u32, @bitCast(instr.imm));
    const value: u32 = switch (instr.op) {
        .lb => blk: {
            const byte = cpu.memory.loadByte(addr) catch |e| return mapMemErr(e);
            break :blk @bitCast(@as(i32, @as(i8, @bitCast(byte))));
        },
        .lbu => blk: {
            const byte = cpu.memory.loadByte(addr) catch |e| return mapMemErr(e);
            break :blk @as(u32, byte);
        },
        .lh => blk: {
            const half = cpu.memory.loadHalfword(addr) catch |e| return mapMemErr(e);
            break :blk @bitCast(@as(i32, @as(i16, @bitCast(half))));
        },
        .lhu => blk: {
            const half = cpu.memory.loadHalfword(addr) catch |e| return mapMemErr(e);
            break :blk @as(u32, half);
        },
        .lw => cpu.memory.loadWord(addr) catch |e| return mapMemErr(e),
        else => unreachable,
    };
    cpu.writeReg(instr.rd, value);
    cpu.pc +%= 4;
},
.sb => {
    const addr = cpu.readReg(instr.rs1) +% @as(u32, @bitCast(instr.imm));
    const value: u8 = @truncate(cpu.readReg(instr.rs2));
    cpu.memory.storeByte(addr, value) catch |e| return mapMemErr(e);
    cpu.pc +%= 4;
},
.sh => {
    const addr = cpu.readReg(instr.rs1) +% @as(u32, @bitCast(instr.imm));
    const value: u16 = @truncate(cpu.readReg(instr.rs2));
    cpu.memory.storeHalfword(addr, value) catch |e| return mapMemErr(e);
    cpu.pc +%= 4;
},
.sw => {
    const addr = cpu.readReg(instr.rs1) +% @as(u32, @bitCast(instr.imm));
    cpu.memory.storeWord(addr, cpu.readReg(instr.rs2)) catch |e| return mapMemErr(e);
    cpu.pc +%= 4;
},
```

Add the helper at file scope (mirroring `cpu.zig`'s `mapMemErr`):

```zig
fn mapMemErr(e: mem_mod.MemoryError) ExecuteError {
    return switch (e) {
        error.OutOfBounds        => ExecuteError.OutOfBounds,
        error.MisalignedAccess   => ExecuteError.MisalignedAccess,
        error.UnexpectedRegister => ExecuteError.UnexpectedRegister,
        error.WriteFailed        => ExecuteError.WriteFailed,
        error.Halt               => ExecuteError.Halt,
    };
}
```

- [ ] **Step 5: Verify pass**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/decoder.zig src/execute.zig
git commit -m "feat: implement loads and stores (LB/LH/LW/LBU/LHU/SB/SH/SW)"
```

---

### Task 12: ALU immediate (ADDI/SLTI/SLTIU/XORI/ORI/ANDI/SLLI/SRLI/SRAI)

**Files:**
- Modify: `src/decoder.zig`
- Modify: `src/execute.zig`

**Why this task:** All 9 register-immediate ALU instructions. SLLI/SRLI/SRAI use shamt (5 bits) instead of a 12-bit immediate; SRAI is distinguished from SRLI by funct7=0x20.

- [ ] **Step 1: Extend decoder**

Add to `Op`:

```zig
addi, slti, sltiu, xori, ori, andi,
slli, srli, srai,
```

Add tests:

```zig
test "decode ADDI x5, x0, -1 → 0xFFF00293" {
    const i = decode(0xFFF00293);
    try std.testing.expectEqual(Op.addi, i.op);
    try std.testing.expectEqual(@as(u5, 5), i.rd);
    try std.testing.expectEqual(@as(u5, 0), i.rs1);
    try std.testing.expectEqual(@as(i32, -1), i.imm);
}

test "decode SLLI x1, x2, 4 → 0x00411093" {
    // funct7=0000000, shamt=00100, rs1=00010, funct3=001, rd=00001, opcode=0010011
    const i = decode(0x00411093);
    try std.testing.expectEqual(Op.slli, i.op);
    try std.testing.expectEqual(@as(u5, 1), i.rd);
    try std.testing.expectEqual(@as(u5, 2), i.rs1);
    try std.testing.expectEqual(@as(i32, 4), i.imm);
}

test "decode SRAI x1, x2, 4 → 0x40415093" {
    // funct7=0100000, shamt=00100, rs1=00010, funct3=101, rd=00001, opcode=0010011
    const i = decode(0x40415093);
    try std.testing.expectEqual(Op.srai, i.op);
    try std.testing.expectEqual(@as(i32, 4), i.imm);
}
```

Add the immediate-ALU decode case:

```zig
0b0010011 => {
    const f3 = funct3(word);
    const f7 = funct7(word);
    const shamt: i32 = @intCast((word >> 20) & 0x1F);
    const op: Op = switch (f3) {
        0b000 => .addi,
        0b010 => .slti,
        0b011 => .sltiu,
        0b100 => .xori,
        0b110 => .ori,
        0b111 => .andi,
        0b001 => if (f7 == 0) Op.slli else Op.illegal,
        0b101 => switch (f7) {
            0b0000000 => Op.srli,
            0b0100000 => Op.srai,
            else      => Op.illegal,
        },
    };
    const imm: i32 = if (op == .slli or op == .srli or op == .srai) shamt else immI(word);
    return .{ .op = op, .rd = rd(word), .rs1 = rs1(word), .imm = imm, .raw = word };
},
```

- [ ] **Step 2: Add execute tests**

```zig
test "ADDI computes rs1 + imm with sign extension" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 100);
    try dispatch(.{ .op = .addi, .rd = 2, .rs1 = 1, .imm = -10 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 90), rig.cpu.readReg(2));
}

test "SLTI: signed comparison" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, @bitCast(@as(i32, -5)));
    try dispatch(.{ .op = .slti, .rd = 2, .rs1 = 1, .imm = 0 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 1), rig.cpu.readReg(2));
}

test "SLTIU: unsigned comparison treats imm as unsigned-extended" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 5);
    // imm = -1 → unsigned 0xFFFF_FFFF, so 5 < 0xFFFF_FFFF → 1
    try dispatch(.{ .op = .sltiu, .rd = 2, .rs1 = 1, .imm = -1 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 1), rig.cpu.readReg(2));
}

test "XORI / ORI / ANDI bitwise ops" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0xF0F0_F0F0);
    try dispatch(.{ .op = .xori, .rd = 2, .rs1 = 1, .imm = @bitCast(@as(u32, 0x0F0)) }, &rig.cpu);
    // 0xF0F0_F0F0 ^ 0x0000_00F0 (sign-extended from 0x0F0 = +240) = 0xF0F0_F000
    try std.testing.expectEqual(@as(u32, 0xF0F0_F000), rig.cpu.readReg(2));
}

test "SLLI shifts left by shamt" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 1);
    try dispatch(.{ .op = .slli, .rd = 2, .rs1 = 1, .imm = 4 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 16), rig.cpu.readReg(2));
}

test "SRAI: arithmetic right shift preserves sign" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0xFFFF_FFF0); // -16
    try dispatch(.{ .op = .srai, .rd = 2, .rs1 = 1, .imm = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFC), rig.cpu.readReg(2)); // -4
}

test "SRLI: logical right shift" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0xFFFF_FFF0);
    try dispatch(.{ .op = .srli, .rd = 2, .rs1 = 1, .imm = 4 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x0FFF_FFFF), rig.cpu.readReg(2));
}
```

- [ ] **Step 3: Run, verify failures**

Run: `zig build test`
Expected: ALU-immediate execute tests fail.

- [ ] **Step 4: Implement in `dispatch`**

```zig
.addi, .slti, .sltiu, .xori, .ori, .andi => {
    const a = cpu.readReg(instr.rs1);
    const imm_u: u32 = @bitCast(instr.imm);
    const result: u32 = switch (instr.op) {
        .addi  => a +% imm_u,
        .slti  => if (@as(i32, @bitCast(a)) < instr.imm) 1 else 0,
        .sltiu => if (a < imm_u) 1 else 0,
        .xori  => a ^ imm_u,
        .ori   => a | imm_u,
        .andi  => a & imm_u,
        else   => unreachable,
    };
    cpu.writeReg(instr.rd, result);
    cpu.pc +%= 4;
},
.slli, .srli, .srai => {
    const a = cpu.readReg(instr.rs1);
    const shamt: u5 = @intCast(instr.imm & 0x1F);
    const result: u32 = switch (instr.op) {
        .slli => a << shamt,
        .srli => a >> shamt,
        .srai => @bitCast(@as(i32, @bitCast(a)) >> shamt),
        else  => unreachable,
    };
    cpu.writeReg(instr.rd, result);
    cpu.pc +%= 4;
},
```

- [ ] **Step 5: Verify pass**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/decoder.zig src/execute.zig
git commit -m "feat: implement ALU-immediate ops (ADDI/SLTI/SLTIU/XORI/ORI/ANDI/SLLI/SRLI/SRAI)"
```

---

### Task 13: ALU register (ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND)

**Files:**
- Modify: `src/decoder.zig`
- Modify: `src/execute.zig`

**Why this task:** All 10 R-type ALU ops. Same shape as immediate variants but two register operands. ADD vs SUB and SRL vs SRA disambiguated by funct7.

- [ ] **Step 1: Extend decoder**

Add to `Op` (note: `or`/`and` are Zig keywords; suffix with `_`):

```zig
add, sub, sll, slt, sltu, xor_, srl, sra, or_, and_,
```

Hmm — to keep the Op variants short, prefer `bit_or`, `bit_and`, `bit_xor`. Choose ONE convention and use it throughout. This plan uses **`xor_`, `or_`, `and_`** with trailing underscore.

Add a test:

```zig
test "decode ADD x3, x1, x2 → 0x002081B3" {
    // funct7=0000000, rs2=00010, rs1=00001, funct3=000, rd=00011, opcode=0110011
    const i = decode(0x002081B3);
    try std.testing.expectEqual(Op.add, i.op);
    try std.testing.expectEqual(@as(u5, 3), i.rd);
    try std.testing.expectEqual(@as(u5, 1), i.rs1);
    try std.testing.expectEqual(@as(u5, 2), i.rs2);
}

test "decode SUB x3, x1, x2 → 0x402081B3" {
    const i = decode(0x402081B3);
    try std.testing.expectEqual(Op.sub, i.op);
}
```

Add R-type decode case:

```zig
0b0110011 => {
    const f3 = funct3(word);
    const f7 = funct7(word);
    const op: Op = switch (f3) {
        0b000 => switch (f7) {
            0b0000000 => Op.add,
            0b0100000 => Op.sub,
            else      => Op.illegal,
        },
        0b001 => if (f7 == 0) Op.sll  else Op.illegal,
        0b010 => if (f7 == 0) Op.slt  else Op.illegal,
        0b011 => if (f7 == 0) Op.sltu else Op.illegal,
        0b100 => if (f7 == 0) Op.xor_ else Op.illegal,
        0b101 => switch (f7) {
            0b0000000 => Op.srl,
            0b0100000 => Op.sra,
            else      => Op.illegal,
        },
        0b110 => if (f7 == 0) Op.or_  else Op.illegal,
        0b111 => if (f7 == 0) Op.and_ else Op.illegal,
    };
    return .{ .op = op, .rd = rd(word), .rs1 = rs1(word), .rs2 = rs2(word), .raw = word };
},
```

- [ ] **Step 2: Add execute tests**

```zig
test "ADD: rs1 + rs2 wraps mod 2^32" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0xFFFF_FFFF);
    rig.cpu.writeReg(2, 1);
    try dispatch(.{ .op = .add, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.readReg(3));
}

test "SUB: rs1 - rs2 wraps mod 2^32" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0);
    rig.cpu.writeReg(2, 1);
    try dispatch(.{ .op = .sub, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), rig.cpu.readReg(3));
}

test "SLL: shifts by low 5 bits of rs2 only" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 1);
    rig.cpu.writeReg(2, 0xFFFF_FFE0 | 4); // shift amount = 4 (low 5 bits)
    try dispatch(.{ .op = .sll, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 16), rig.cpu.readReg(3));
}

test "SRA: arithmetic right shift preserves sign" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    rig.cpu.writeReg(1, 0xFFFF_FFF0);
    rig.cpu.writeReg(2, 4);
    try dispatch(.{ .op = .sra, .rd = 3, .rs1 = 1, .rs2 = 2 }, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), rig.cpu.readReg(3));
}
```

- [ ] **Step 3: Run, verify failures**

Run: `zig build test`
Expected: R-type execute tests fail.

- [ ] **Step 4: Implement in `dispatch`**

```zig
.add, .sub, .sll, .slt, .sltu, .xor_, .srl, .sra, .or_, .and_ => {
    const a = cpu.readReg(instr.rs1);
    const b = cpu.readReg(instr.rs2);
    const shamt: u5 = @intCast(b & 0x1F);
    const result: u32 = switch (instr.op) {
        .add  => a +% b,
        .sub  => a -% b,
        .sll  => a << shamt,
        .slt  => if (@as(i32, @bitCast(a)) < @as(i32, @bitCast(b))) 1 else 0,
        .sltu => if (a < b) 1 else 0,
        .xor_ => a ^ b,
        .srl  => a >> shamt,
        .sra  => @bitCast(@as(i32, @bitCast(a)) >> shamt),
        .or_  => a | b,
        .and_ => a & b,
        else  => unreachable,
    };
    cpu.writeReg(instr.rd, result);
    cpu.pc +%= 4;
},
```

- [ ] **Step 5: Verify pass**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/decoder.zig src/execute.zig
git commit -m "feat: implement R-type ALU ops (ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND)"
```

---

### Task 14: System stubs (FENCE, ECALL, EBREAK)

**Files:**
- Modify: `src/decoder.zig`
- Modify: `src/execute.zig`

**Why this task:** Decode the three SYSTEM-class instructions. FENCE no-ops (single-core, no reordering); ECALL and EBREAK return `error.UnsupportedInstruction` which halts the run loop with a diagnostic. Plan 1.C will replace these stubs with real trap handling.

- [ ] **Step 1: Extend decoder**

Add to `Op`:

```zig
fence, ecall, ebreak,
```

Add tests:

```zig
test "decode FENCE → 0x0FF0000F" {
    // FENCE pred=1111, succ=1111, rs1=0, funct3=000, rd=0, opcode=0001111
    const i = decode(0x0FF0000F);
    try std.testing.expectEqual(Op.fence, i.op);
}

test "decode ECALL → 0x00000073" {
    const i = decode(0x00000073);
    try std.testing.expectEqual(Op.ecall, i.op);
}

test "decode EBREAK → 0x00100073" {
    const i = decode(0x00100073);
    try std.testing.expectEqual(Op.ebreak, i.op);
}
```

Add decode cases:

```zig
0b0001111 => return .{ .op = .fence, .raw = word },
0b1110011 => {
    // SYSTEM: funct3 must be 000, then imm distinguishes ecall (0) vs ebreak (1).
    if (funct3(word) != 0) return .{ .op = .illegal, .raw = word };
    const imm12: u32 = (word >> 20) & 0xFFF;
    return switch (imm12) {
        0 => .{ .op = .ecall,  .raw = word },
        1 => .{ .op = .ebreak, .raw = word },
        else => .{ .op = .illegal, .raw = word },
    };
},
```

- [ ] **Step 2: Add execute tests**

```zig
test "FENCE is a no-op that advances PC" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try dispatch(.{ .op = .fence }, &rig.cpu);
    try std.testing.expectEqual(mem_mod.RAM_BASE + 4, rig.cpu.pc);
}

test "ECALL returns UnsupportedInstruction in Plan 1.A" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try std.testing.expectError(ExecuteError.UnsupportedInstruction, dispatch(.{ .op = .ecall }, &rig.cpu));
}

test "EBREAK returns UnsupportedInstruction in Plan 1.A" {
    var rig = try Rig.init(std.testing.allocator, mem_mod.RAM_BASE);
    defer rig.deinit();
    try std.testing.expectError(ExecuteError.UnsupportedInstruction, dispatch(.{ .op = .ebreak }, &rig.cpu));
}
```

- [ ] **Step 3: Run, verify failures**

Run: `zig build test`
Expected: FENCE test fails (or PC mismatch); ECALL/EBREAK tests fail.

- [ ] **Step 4: Implement in `dispatch`**

```zig
.fence => {
    cpu.pc +%= 4;
},
.ecall, .ebreak => return ExecuteError.UnsupportedInstruction,
```

- [ ] **Step 5: Verify pass**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/decoder.zig src/execute.zig
git commit -m "feat: stub system instructions (FENCE no-op, ECALL/EBREAK error)"
```

---

### Task 15: Cpu.run loop with halt detection

**Files:**
- Modify: `src/cpu.zig`

**Why this task:** Wrap `step()` in a loop that exits cleanly on `error.Halt` (writes to halt MMIO from inside loads/stores) and propagates other errors.

- [ ] **Step 1: Add a test that exercises run-then-halt**

Add to `src/cpu.zig`:

```zig
test "Cpu.run halts cleanly when program writes to halt MMIO" {
    var halt = @import("devices/halt.zig").Halt.init();
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var uart = @import("devices/uart.zig").Uart.init(buf.writer().any());
    var mem = try Memory.init(std.testing.allocator, &halt, &uart);
    defer mem.deinit();

    // Hand-encoded program at RAM_BASE:
    //   lui   t0, 0x100        ; t0 = 0x00100000 (halt MMIO)
    //   sb    zero, 0(t0)      ; *t0 = 0 → halt
    const RAM_BASE = @import("memory.zig").RAM_BASE;
    try mem.storeWord(RAM_BASE,     0x001002B7); // lui t0, 0x100
    try mem.storeWord(RAM_BASE + 4, 0x00028023); // sb zero, 0(t0)

    var cpu = Cpu.init(&mem, RAM_BASE);
    try cpu.run();
    try std.testing.expectEqual(@as(?u8, 0), halt.exit_code);
}

test "Cpu.run propagates UnsupportedInstruction" {
    var halt = @import("devices/halt.zig").Halt.init();
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var uart = @import("devices/uart.zig").Uart.init(buf.writer().any());
    var mem = try Memory.init(std.testing.allocator, &halt, &uart);
    defer mem.deinit();

    const RAM_BASE = @import("memory.zig").RAM_BASE;
    try mem.storeWord(RAM_BASE, 0x00000073); // ECALL

    var cpu = Cpu.init(&mem, RAM_BASE);
    try std.testing.expectError(StepError.UnsupportedInstruction, cpu.run());
}
```

- [ ] **Step 2: Verify the first test fails (no `run` method yet)**

Run: `zig build test`
Expected: compilation error: "no member named 'run'".

- [ ] **Step 3: Implement `run()`**

Add to the `Cpu` struct in `src/cpu.zig`:

```zig
pub fn run(self: *Cpu) StepError!void {
    while (true) {
        self.step() catch |err| switch (err) {
            error.Halt => return,
            else => return err,
        };
    }
}
```

- [ ] **Step 4: Verify pass**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/cpu.zig
git commit -m "feat: add Cpu.run loop with clean halt and error propagation"
```

---

### Task 16: CLI — `--raw` mode and file loading

**Files:**
- Modify: `src/main.zig`

**Why this task:** Make the emulator usable as a command-line tool. Parses `--raw <hex-addr> <file>`, loads the file into RAM at the given address, wires CPU/memory/devices, runs, exits with the halt code (or non-zero on error).

- [ ] **Step 1: Replace `src/main.zig` with the real CLI**

```zig
const std = @import("std");
const cpu_mod = @import("cpu.zig");
const mem_mod = @import("memory.zig");
const halt_dev = @import("devices/halt.zig");
const uart_dev = @import("devices/uart.zig");

comptime {
    _ = @import("cpu.zig");
    _ = @import("memory.zig");
    _ = @import("devices/halt.zig");
    _ = @import("devices/uart.zig");
    _ = @import("decoder.zig");
    _ = @import("execute.zig");
}

const Args = struct {
    raw_addr: ?u32 = null,
    file: ?[]const u8 = null,
};

fn parseArgs(argv: []const [:0]const u8) !Args {
    var args: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--raw")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            args.raw_addr = try std.fmt.parseInt(u32, argv[i], 0);
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try printUsage();
            std.process.exit(0);
        } else if (a.len > 0 and a[0] == '-') {
            std.debug.print("unknown option: {s}\n", .{a});
            return error.UnknownOption;
        } else {
            if (args.file != null) return error.TooManyPositional;
            args.file = a;
        }
    }
    if (args.file == null) return error.MissingFile;
    if (args.raw_addr == null) return error.RawAddrRequired;
    return args;
}

fn printUsage() !void {
    const w = std.io.getStdErr().writer();
    try w.print(
        \\usage: ccc --raw <hex-addr> <program.bin>
        \\
        \\Plan 1.A only supports raw-binary loading (--raw is required).
        \\ELF support arrives in Plan 1.C.
        \\
    , .{});
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const argv = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, argv);

    const args = parseArgs(argv) catch {
        try printUsage();
        std.process.exit(2);
    };

    const file_data = try std.fs.cwd().readFileAlloc(a, args.file.?, 16 * 1024 * 1024);

    var halt = halt_dev.Halt.init();
    var stdout = std.io.getStdOut();
    var bw = std.io.bufferedWriter(stdout.writer());
    defer bw.flush() catch {};
    var uart = uart_dev.Uart.init(bw.writer().any());

    var mem = try mem_mod.Memory.init(a, &halt, &uart);
    defer mem.deinit();

    // Load program bytes into RAM at raw_addr.
    const load_addr = args.raw_addr.?;
    for (file_data, 0..) |b, idx| {
        try mem.storeByte(load_addr + @as(u32, @intCast(idx)), b);
    }

    var cpu = cpu_mod.Cpu.init(&mem, load_addr);
    cpu.run() catch |err| {
        try bw.flush();
        std.debug.print("\nemulator stopped: {s} (PC=0x{X:0>8})\n", .{ @errorName(err), cpu.pc });
        std.process.exit(1);
    };
    try bw.flush();
    std.process.exit(halt.exit_code orelse 0);
}
```

- [ ] **Step 2: Build and smoke-test usage**

Run: `zig build`
Expected: succeeds.

Run: `zig build run`
Expected: prints usage, exits with code 2.

- [ ] **Step 3: Commit**

```bash
git add src/main.zig
git commit -m "feat: add CLI with --raw <addr> mode for loading raw RISC-V binaries"
```

---

### Task 17: Hand-crafted hello world demo (THE PAYOFF)

**Files:**
- Create: `tests/programs/hello/encode_hello.zig`
- Create: `tests/programs/hello/README.md`
- Modify: `build.zig` (add a `hello` step that builds `encode_hello` and emits `hello.bin`; add an end-to-end `e2e` test step)

**Why this task:** This is the demo. We hand-encode a tiny RV32I program with helper functions, build it into a raw binary, run it through our emulator, and verify the output is `hello world\n`. After this task, Plan 1.A is **done**.

- [ ] **Step 1: Create `tests/programs/hello/encode_hello.zig`**

```zig
const std = @import("std");

// Register aliases (RISC-V ABI numeric register names).
const ZERO: u5 = 0;
const T0:   u5 = 5;
const T1:   u5 = 6;
const T2:   u5 = 7;
const T3:   u5 = 28;

// === Encoders for the instructions we use ===

fn lui(rd: u5, imm20: u20) u32 {
    return (@as(u32, imm20) << 12) | (@as(u32, rd) << 7) | 0b0110111;
}

fn addi(rd: u5, rs1: u5, imm: i12) u32 {
    const imm_u: u32 = @bitCast(@as(i32, imm));
    return ((imm_u & 0xFFF) << 20) | (@as(u32, rs1) << 15) | (@as(u32, rd) << 7) | 0b0010011;
}

fn lb(rd: u5, rs1: u5, imm: i12) u32 {
    const imm_u: u32 = @bitCast(@as(i32, imm));
    return ((imm_u & 0xFFF) << 20) | (@as(u32, rs1) << 15) |
           (0b000 << 12) | (@as(u32, rd) << 7) | 0b0000011;
}

fn sb(rs1: u5, rs2: u5, imm: i12) u32 {
    const imm_u: u32 = @bitCast(@as(i32, imm));
    const imm_high: u32 = (imm_u >> 5) & 0x7F;
    const imm_low:  u32 = imm_u & 0x1F;
    return (imm_high << 25) | (@as(u32, rs2) << 20) | (@as(u32, rs1) << 15) |
           (0b000 << 12) | (imm_low << 7) | 0b0100011;
}

fn beq(rs1: u5, rs2: u5, offset: i13) u32 {
    const o: u32 = @bitCast(@as(i32, offset));
    const imm12:   u32 = (o >> 12) & 1;
    const imm10_5: u32 = (o >> 5)  & 0x3F;
    const imm4_1:  u32 = (o >> 1)  & 0xF;
    const imm11:   u32 = (o >> 11) & 1;
    return (imm12 << 31) | (imm10_5 << 25) | (@as(u32, rs2) << 20) |
           (@as(u32, rs1) << 15) | (0b000 << 12) | (imm4_1 << 8) |
           (imm11 << 7) | 0b1100011;
}

fn jal(rd: u5, offset: i21) u32 {
    const o: u32 = @bitCast(@as(i32, offset));
    const imm20:    u32 = (o >> 20) & 1;
    const imm10_1:  u32 = (o >> 1)  & 0x3FF;
    const imm11:    u32 = (o >> 11) & 1;
    const imm19_12: u32 = (o >> 12) & 0xFF;
    return (imm20 << 31) | (imm10_1 << 21) | (imm11 << 20) |
           (imm19_12 << 12) | (@as(u32, rd) << 7) | 0b1101111;
}

// === The program ===

const PROGRAM_BASE: u32 = 0x8000_0000;
const STRING_OFFSET: u32 = 0x100;
const HELLO = "hello world\n";

fn buildProgram() [10]u32 {
    return .{
        // Setup
        lui(T0, 0x10000),                       // t0 = 0x10000000 (UART)
        lui(T1, 0x80000),                       // t1 = 0x80000000 (RAM base)
        addi(T1, T1, @intCast(STRING_OFFSET)),  // t1 += STRING_OFFSET
        // Loop:
        lb(T2, T1, 0),                          // t2 = *t1
        beq(T2, ZERO, 0x10),                    // if t2 == 0, jump to halt (+16)
        sb(T0, T2, 0),                          // *t0 = t2 (UART)
        addi(T1, T1, 1),                        // t1++
        jal(ZERO, -16),                         // jump back to loop
        // Halt:
        lui(T3, 0x100),                         // t3 = 0x00100000 (halt MMIO)
        sb(T3, ZERO, 0),                        // *t3 = 0 (halt)
    };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);

    if (args.len != 2) {
        std.debug.print("usage: {s} <output-path>\n", .{args[0]});
        std.process.exit(1);
    }

    var file = try std.fs.cwd().createFile(args[1], .{});
    defer file.close();
    var bw = std.io.bufferedWriter(file.writer());
    const w = bw.writer();

    const program = buildProgram();
    try w.writeAll(std.mem.sliceAsBytes(&program));

    const code_size: u32 = @intCast(program.len * 4);
    if (STRING_OFFSET < code_size) @panic("program too long");
    try w.writeByteNTimes(0, STRING_OFFSET - code_size);

    try w.writeAll(HELLO);
    try w.writeByte(0);

    try bw.flush();
}
```

- [ ] **Step 2: Create the README**

`tests/programs/hello/README.md`:

```markdown
# Hand-crafted hello world

`encode_hello.zig` is a Zig program that emits a raw RISC-V binary at
`hello.bin`. Run by hand:

```
zig run tests/programs/hello/encode_hello.zig -- hello.bin
zig build run -- --raw 0x80000000 hello.bin
```

The binary contains a tiny RV32I program followed by the string
`hello world\n\0` at offset `0x100`. The program loops: read a byte from
the string, write it to UART, advance the pointer; when it hits `\0` it
writes to the halt MMIO and the emulator exits.

This is throwaway scaffolding for Plan 1.A. Plan 1.D replaces it with a
proper Zig-cross-compiled hello world that runs in U-mode through the
M-mode monitor.
```

- [ ] **Step 3: Wire `hello` and `e2e` steps into `build.zig`**

Replace `build.zig` with:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ccc",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the emulator");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&test_run.step);

    // Build the hello.bin demo binary.
    const hello_encoder = b.addExecutable(.{
        .name = "encode_hello",
        .root_source_file = b.path("tests/programs/hello/encode_hello.zig"),
        .target = b.graph.host,  // runs on host, not emulator target
        .optimize = .Debug,
    });
    const hello_run = b.addRunArtifact(hello_encoder);
    const hello_out = hello_run.addOutputFileArg("hello.bin");
    const hello_step = b.step("hello", "Build the hand-crafted hello world binary");
    const install_hello = b.addInstallFile(hello_out, "hello.bin");
    hello_step.dependOn(&install_hello.step);

    // End-to-end test: run hello.bin through the emulator and check stdout.
    const e2e_run = b.addRunArtifact(exe);
    e2e_run.addArgs(&.{ "--raw", "0x80000000" });
    e2e_run.addFileArg(hello_out);
    e2e_run.expectStdOutEqual("hello world\n");
    const e2e_step = b.step("e2e", "Run end-to-end hello-world test");
    e2e_step.dependOn(&e2e_run.step);
}
```

- [ ] **Step 4: Build the demo binary and inspect it**

Run: `zig build hello`
Expected: succeeds, leaves `zig-out/hello.bin`.

Run: `xxd zig-out/hello.bin | head -20`
Expected: first 40 bytes are RISC-V instructions (you'll see byte patterns ending in `b7`/`13`/`83`/etc., which are the RV32I opcodes); around offset `0x100` you'll see `68 65 6c 6c 6f 20 77 6f 72 6c 64 0a 00` = `hello world\n\0`.

- [ ] **Step 5: Run the demo manually to see the output**

Run: `zig build run -- --raw 0x80000000 zig-out/hello.bin`
Expected: prints exactly `hello world` (followed by a newline) and exits with code 0.

- [ ] **Step 6: Run the automated end-to-end test**

Run: `zig build e2e`
Expected: succeeds silently. Failure mode: shows a diff of expected vs. actual stdout.

- [ ] **Step 7: Run the full test suite one last time**

Run: `zig build test && zig build e2e`
Expected: both succeed.

- [ ] **Step 8: Commit**

```bash
git add tests/programs/hello/ build.zig
git commit -m "feat: hand-crafted RV32I hello world end-to-end demo

This is the Plan 1.A payoff: a hand-encoded RISC-V program that
loops over a string, writes each byte to the emulated UART, and
halts when it hits the null terminator. Build with 'zig build hello'
and run with 'zig build e2e' (or 'zig build run -- --raw 0x80000000
zig-out/hello.bin' to see the output by hand)."
```

---

## Plan 1.A complete

At this point you can run:

```bash
zig build test    # all unit tests pass
zig build e2e     # end-to-end hello world succeeds
zig build run -- --raw 0x80000000 zig-out/hello.bin  # see "hello world" printed
```

You have a working RV32I CPU emulator. It only knows base integer instructions, has no concept of privilege or traps, and can only load raw binaries — but it runs a real RISC-V program you can read in a hex dump.

**Next:** Brainstorm and write **Plan 1.B — Complete ISA (M extension, A extension, full Zicsr machinery)**. After Plan 1.B, the emulator passes the official `rv32ui-p-*`, `rv32um-p-*`, and `rv32ua-p-*` tests from the riscv-tests suite.

---

## Spec coverage check (self-review)

This plan covers the following Phase 1 spec sections in part:

- **ISA** — RV32I integer base only (M, A, Zicsr proper deferred to Plans 1.B/1.C).
- **Privilege** — None (plan deferred to 1.C).
- **Devices** — UART (output), Halt (full); CLINT deferred to 1.B/1.C.
- **Memory layout** — RAM at `0x80000000`, UART at `0x10000000`, Halt at `0x00100000` (matches spec).
- **Boot model** — `--raw` only (ELF deferred to 1.C).
- **Testing** — Per-instruction Zig unit tests + one end-to-end demo. riscv-tests integration deferred to 1.B; QEMU-diff harness deferred to 1.D.
- **Decoder style** — Big switch on opcode and funct fields, as specced.
- **Module layout** — Matches the spec's proposed file structure.

What's intentionally NOT in this plan (and which plan picks it up):

| Spec item | Plan |
|-----------|------|
| M extension | 1.B |
| A extension | 1.B |
| FENCE.I, full CSR machinery | 1.B |
| S-mode, page tables | (Phase 2) |
| U-mode, real trap handling, mret/wfi | 1.C |
| ELF loader | 1.C |
| CLINT timer wiring | 1.C (Phase 2 for interrupts) |
| `--trace`, crash dump | 1.D |
| M-mode monitor + Zig hello.zig | 1.D |
| riscv-tests integration | 1.B |
| QEMU-diff harness | 1.D |
