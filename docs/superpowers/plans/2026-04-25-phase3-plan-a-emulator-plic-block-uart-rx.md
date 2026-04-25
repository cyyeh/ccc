# Phase 3 Plan A — Emulator: PLIC + UART RX + block device + `--disk` (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Phase 2 emulator with the **three new MMIO devices** Phase 3 needs from hardware: a **Platform-Level Interrupt Controller (PLIC)** with one S-mode hart context, a **simple block device** (4 registers, 4 KB sector size, async via PLIC IRQ #1), and a **UART RX path** (256-byte FIFO + level IRQ #10). External interrupts are delegated to S-mode (`mideleg.SEIP = 1`); the kernel's `s_trap_dispatch` handles claim/complete in Phase 3.C+. Phase 3.A is **emulator-only** — no kernel-side code lands. The headline acceptance test is `tests/programs/plic_block_test/`: a small S-mode test program that boots through M, drops to S, programs the PLIC + block device, sleeps in `wfi`, takes a delegated S-external interrupt, claims the source, reads back, completes, and halts. `wfi` becomes a real idle (the step loop blocks until the next interrupt-edge instead of busy-stepping). Two new CLI flags arrive: `--disk PATH` (back the block device with a host file) and `--input PATH` (stream a host file into the UART RX FIFO for scripted tests). Without `--disk` the device reports "no media"; without `--input` the emulator drains host stdin non-blockingly in the idle path.

**Architecture:** Two new device modules (`src/devices/plic.zig`, `src/devices/block.zig`) sit alongside the Phase 1/2 trio (Halt, UART, CLINT). They expose the same `readByte` / `writeByte` shape used by `memory.zig`'s MMIO dispatcher. The PLIC tracks 32 pending bits, 32 priority registers, S-context enable bits, S-context threshold, and a single-claimed-source slot. Devices push pending changes through a tiny `assertSource(N)` / `deassertSource(N)` API; the PLIC samples nothing on its own. The PLIC's only deliverability output is `hasPendingForS()` — wired into `cpu.csr.mip.SEIP` via the same live-read pattern Phase 2 used for MTIP (`csr.zig` ORs the bit into `CSR_MIP` reads; `csr.zig` MIP write-mask already excludes SEIP). M-mode external (`MEIP`) is hardwired off — `mie.MEIE` is never enabled by anyone in our system, so we don't model an M-mode hart context. `cpu.check_interrupt` requires no algorithm change; the priority resolution from 2.B already handles SEI at the right slot. The block device synchronously copies 4 KB between RAM and a host-backed file on `CMD` write; the IRQ fires "on the next instruction boundary" via a deferred-assertion latch the CPU step loop polls and feeds into `plic.assertSource(1)`. UART grows a 256-byte ring-buffer RX FIFO; bytes arriving (level: while non-empty) raise `plic.assertSource(10)`. `wfi` becomes a real idle: when no interrupt is deliverable and the host hasn't given us bytes yet, the emulator's step loop yields a 1 ms `poll(stdin, 1)` slice and re-checks; loop exits when an interrupt-edge fires or `stdin` closes. `main.zig` parses `--disk PATH` (passes a `?std.fs.File` into the block device) and `--input PATH` (allocates a small RX-pump struct that streams bytes into the UART FIFO during idle). Integration test `plic_block_test/` reuses the kernel-skeleton build pattern: M-mode boot.S sets up `medeleg/mideleg/sie/PLIC`, drops to S; an S-mode trap handler in the same .S handles the PLIC interrupt; the test halts via the existing `0x00100000` halt MMIO with exit code 0 on success.

**Tech Stack:** Zig 0.16.x (pinned in `build.zig.zon`), no new external dependencies. The host-side `--disk` backing uses `std.fs.File.openAbsolute`/`std.fs.cwd().openFile`. The host-side `stdin` pump uses POSIX `poll(2)` via `std.c.poll` — macOS-friendly, single-threaded, no host pthreads. The integration test is built with the same RV32 cross-compile config (`generic_rv32+m+a`) used by Plan 2.C's kernel.

**Spec reference:** `docs/superpowers/specs/2026-04-25-phase3-multi-process-os-design.md` — Plan 3.A covers spec §Architecture (emulator delta rows for `cpu`, `trap`, `memory`, `devices/uart`, `devices/plic`, `devices/block`, `main`), §Memory layout (PLIC at `0x0c00_0000` and block at `0x1000_1000`), §Devices (UART RX, PLIC, Block register map), §Privilege & trap model (external-interrupt delegation, boot shim's `mideleg.SEIP` + PLIC enables), §CLI (`--disk`, `--input`), §Testing strategy item 1 (emulator unit tests), and §Implementation plan decomposition entry **3.A**. The RISC-V Privileged Spec sections on PLIC behavior (§3.1.9 + the standalone PLIC spec at sifive.com/documentation) and external-interrupt routing (§3.1.6) are authoritative; the phase spec takes precedence if they disagree.

**Plan 3.A scope (subset of Phase 3 spec):**

- **PLIC (`src/devices/plic.zig`)** — 32 sources × 1 hart context (S-mode):
  - **MMIO map** (offsets relative to `0x0c00_0000`):
    - `0x0000_0000` — source 0 priority (reserved, hardwired 0)
    - `0x0000_0004 .. 0x0000_007C` — sources 1..31 priority, u32 each, value 0..7. Writes outside that range are masked to 7. Reads return stored value.
    - `0x0000_1000` — pending bits for sources 0..31 (read-only u32). Bit 0 hardwired 0 (source 0 reserved).
    - `0x0000_2080` — S-mode hart-context enable bits (sources 0..31). Bit 0 hardwired 0.
    - `0x0020_1000` — S-mode threshold (u32, value 0..7).
    - `0x0020_1004` — S-mode claim/complete: read = claim (atomic), write = complete (acknowledgement).
    - All other offsets in `[0x0c00_0000, 0x0c40_0000)` read 0 / accept-and-drop writes.
  - **Public API (kernel-side will use these in 3.C+, but Phase 3.A drives them from device modules):**
    - `pub fn assertSource(self: *Plic, irq: u5) void` — sets pending bit; idempotent.
    - `pub fn deassertSource(self: *Plic, irq: u5) void` — clears pending bit; idempotent.
    - `pub fn hasPendingForS(self: *const Plic) bool` — true iff at least one source is `pending & enabled[S] & priority > threshold[S]`.
  - **Claim semantics:** read of `claim_complete` returns the highest-priority enabled-and-pending source ID for the S-context (ties broken by lowest ID), and atomically clears that source's pending bit. If no source qualifies, returns 0.
  - **Complete semantics:** write to `claim_complete` is a no-op in our model (the spec treats it as an "ack" notifying the gateway, but with our level-vs-edge model, the device controls re-assertion; nothing in PLIC state changes on complete). We still accept the write for spec compliance.
  - **No M-mode hart context.** We never model M-external. The kernel's boot shim leaves `mie.MEIE = 0` and the spec mandates we never set it.

- **Block device (`src/devices/block.zig`)** — 4 registers, 4 KB sector size, host-file-backed, async:
  - **MMIO map** (offsets relative to `0x1000_1000`):
    - `0x0` — `SECTOR` (u32, RW). Sector index. Reads and writes round-trip plainly.
    - `0x4` — `BUFFER` (u32, RW). Physical address of guest's 4 KB buffer. Must be 4-byte aligned (we don't enforce alignment beyond word access; misalignment gets caught by RAM bounds when transfer happens).
    - `0x8` — `CMD` (u32, W). Write `1` = read disk → RAM, `2` = write RAM → disk, `0` = reset (no-op for now), other = error. Reading returns 0.
    - `0xC` — `STATUS` (u32, R). `0` = ready (last op ok), `2` = error (bad command, transfer failed, sector out of range), `3` = no-media (no `--disk`). Phase 3.A does not produce `1` (busy) — transfers are CPU-synchronous from the device's POV.
  - **Storage:** `disk_file: ?std.fs.File`. When non-null, reads/writes seek to `sector * 4096` and transfer 4 KB. When null (no `--disk`), any `CMD` write sets `STATUS = 3` and skips the transfer.
  - **IRQ:** every successful `CMD` write (and every error) sets `pending_irq = true`. The CPU step loop polls this flag at the top of each step (before fetch); when set, it calls `plic.assertSource(1)` and clears the flag. This realizes "raise on next instruction boundary" in the spec.
  - **Error handling:** `CMD ∉ {0, 1, 2}` → `STATUS = 2`. `SECTOR >= NSECTORS` (1024) → `STATUS = 2`. RAM bounds violation when copying → `STATUS = 2`. Host I/O error from the file → `STATUS = 2`. Every error still sets `pending_irq` so the kernel observes a completion edge.

- **UART RX path (`src/devices/uart.zig` extension)**:
  - **256-byte ring-buffer RX FIFO.** Public API:
    - `pub fn pushRx(self: *Uart, b: u8) bool` — returns `false` when full (caller must back off; for now nobody uses the return — we drop on overflow with a `dropped_count` debug counter, matching real 16550 behavior).
    - `pub fn rxLen(self: *const Uart) u16` — bytes available to read.
  - **Register changes:**
    - `REG_RBR` (offset `0x00`, read): if FIFO non-empty, pops next byte; if empty, returns 0. (This matches real 16550: spurious RBR reads return whatever's in the holding register, and 0 is a valid "I have nothing for you" answer.)
    - `REG_LSR` (offset `0x05`, read): bit 0 (`DR` = "data ready") now set when `rxLen() > 0`. THRE/TEMT bits unchanged from Phase 1.
  - **IRQ:** `pushRx` (when transitioning empty→non-empty) calls `plic.assertSource(10)`. Reading `REG_RBR` to drain to empty calls `plic.deassertSource(10)`.

- **`memory.zig` MMIO dispatch.** `loadBytePhysical` / `storeBytePhysical` get two new `inRange` arms before the RAM fast path: `[0x0c00_0000, 0x0c40_0000)` → PLIC; `[0x1000_1000, 0x1000_1010)` → Block. Block's range is tight (16 bytes) so a misdispatch is loud. PLIC's range is the spec's full 4 MB legacy aperture so unmapped offsets just read 0 (matches the lenient pattern we already use for CLINT).

- **`cpu.zig` external-interrupt wiring.** No new code in `check_interrupt` — the priority loop already handles SEI at the right slot (cause code 9). `pendingInterrupts(cpu)` gains an OR with `(plic.hasPendingForS() ? (1 << 9) : 0)` so SEIP tracks PLIC live, exactly mirroring Phase 2.B's MTIP pattern. `csr.zig`'s `CSR_MIP` and `CSR_SIP` read paths gain the same OR. The MIP write mask already excludes SEIP (it's set to platform-controlled in our 2.B mask, but Phase 2 needed software writes for testing — Plan 3.A tightens `MIP_WRITE_MASK` to exclude bit 9 since a real PLIC owns it).

- **`wfi` idle.** `execute.zig`'s `.wfi` arm currently does `cpu.pc +%= 4` and returns. New behavior: in a loop, call `pumpInputAndDevices(cpu)` (drain any host stdin into UART RX FIFO; service deferred block-device IRQ-edge), then `cpu.check_interrupt(cpu)`. If `check_interrupt` returned true (a trap was taken), `wfi` returns — the trap handler will be entered by the next `step` iteration. If false, sleep ~1 ms via `std.Thread.sleep(1_000_000)` and loop. After at most a configurable max-spin (10 seconds) without ever observing a wakeable event, return; the program is wedged and `cpu.run`'s next step will refetch `wfi` and we loop again — externally observable behavior is "hang", not divergence. Phase 3.A's integration test never hits this max-spin because the block IRQ fires on the very next instruction.

- **Trace.** `formatInterruptMarker` extended to print PLIC source ID for cause `9` (S-external) when the trap is taken: `--- interrupt 9 (supervisor external, src N) taken in <old>, now <new> ---`. Source ID is read from the PLIC at marker-emit time (it's the about-to-be-claimed source — non-destructive: we re-call a `peekHighestPendingForS` helper that doesn't clear the bit). For non-external interrupts, the existing format is unchanged. New `formatBlockTransfer` emits `--- block: <op> sector <S> at PA 0x<P> ---` between instructions when the block device performs a transfer; `op ∈ {"read", "write"}`.

- **CLI.** `--disk PATH` opens the file `O_RDWR` (creates if missing? **no** — fail loudly so a typo doesn't silently zero an existing image). The opened file is passed to the `Block.init`. `--input PATH` opens `O_RDONLY`; the `RxPump` struct holds the file handle plus a tiny "is EOF" flag. `--disk-latency CYCLES` is parsed and stored but never consulted in Phase 3.A (reserved in spec).

- **Build wiring.** `tests/programs/plic_block_test/` follows the `tests/programs/kernel/` structure but tinier:
  - `boot.S` — M-mode boot shim (similar to Phase 2 kernel's `boot.S` but: skip CLINT timer setup, just `mideleg.SEIP=1`, set `sie.SEIE`, set PLIC enables/priority/threshold, drop to S).
  - `test.S` — S-mode test logic (in asm so we don't need a Zig user runtime). Programs the block device, executes `wfi`, traps on PLIC interrupt, claims, verifies, completes, halts.
  - `linker.ld` — places `.text.init` at `0x80000000` (M entry), `.text` after, all in RAM. Single ELF, one PT_LOAD.
  - `build.zig` adds `plic-block-test` step (builds the ELF) and `e2e-plic-block` step (runs `ccc --disk <generated 4 MB image> --input /dev/null plic_block_test.elf`). The test image is a 4 MB file pre-populated with one known sector of magic bytes in sector 0; the test reads sector 0, verifies the magic matches, halts with exit code 0.

**Not in Plan 3.A (explicitly):**

- Any kernel-side code (`tests/programs/kernel/` modifications) → Plans 3.B–3.F.
- Multi-context PLIC (M-mode hart context, multi-hart) — never planned.
- Real disk-latency modeling — Phase 3.A reserves the `--disk-latency` flag as a no-op.
- IRQ priority preemption inside the PLIC — there's no in-service tracking; we don't enforce "lower priority can't preempt higher in-service" because the kernel won't have nested interrupts in Phase 3.
- The PLIC's `enable_M` (M-mode hart context) registers — out of spec.
- Block device write-coalescing, bufcache integration — Phase 3.D.
- UART line discipline (echo, ^C handling, cooked vs. raw mode) — Phase 3.E.
- `console_set_mode` / `set_fg_pid` syscalls — Phase 3.C/E.
- `--disk-latency` actually delaying transfers — flag accepted, never used.
- A QEMU-compatible ABI for the block device. We use a custom 4-register MMIO; QEMU's `virtio-blk` is not modeled.

**Deviation from Plan 2.D's closing note:** none. Plan 2.D marked Phase 2 done; Phase 3 begins with this plan. The roadmap entry for Phase 3 explicitly lists "block device driver, simple filesystem" — Phase 3.A delivers the device-side substrate.

---

## File structure (final state at end of Plan 3.A)

```
ccc/
├── .gitignore                                       ← UNCHANGED
├── .gitmodules                                      ← UNCHANGED
├── build.zig                                        ← MODIFIED (+plic_block_test build; +e2e-plic-block step)
├── build.zig.zon                                    ← UNCHANGED
├── README.md                                        ← MODIFIED (status line; new flags; trace markers note)
├── src/
│   ├── main.zig                                     ← MODIFIED (+--disk +--input +--disk-latency parsing; opens disk file; wires RxPump into idle)
│   ├── cpu.zig                                      ← MODIFIED (pendingInterrupts ORs in PLIC SEIP; step polls block deferred-IRQ; wfi reworked via execute.zig)
│   ├── memory.zig                                   ← MODIFIED (+PLIC and Block in MMIO dispatch; new ?*Plic and ?*Block fields; init takes both)
│   ├── decoder.zig                                  ← UNCHANGED (wfi already decoded)
│   ├── execute.zig                                  ← MODIFIED (wfi: real idle loop, calls cpu.idleSpin)
│   ├── csr.zig                                      ← MODIFIED (CSR_MIP/CSR_SIP read ORs in live SEIP from PLIC; MIP_WRITE_MASK drops bit 9)
│   ├── trap.zig                                     ← UNCHANGED (priority order already covers SEI; enter_interrupt already routes via mideleg)
│   ├── elf.zig                                      ← UNCHANGED
│   ├── trace.zig                                    ← MODIFIED (formatInterruptMarker takes optional source-id; +formatBlockTransfer)
│   └── devices/
│       ├── halt.zig                                 ← UNCHANGED
│       ├── uart.zig                                 ← MODIFIED (RX FIFO, RBR pop, LSR.DR, plic interaction)
│       ├── clint.zig                                ← UNCHANGED
│       ├── plic.zig                                 ← NEW (Plic struct, MMIO read/write, pending/enable/threshold, claim/complete, hasPendingForS)
│       └── block.zig                                ← NEW (Block struct, register storage, sync transfer, deferred-IRQ flag)
└── tests/
    ├── programs/
    │   ├── hello/, mul_demo/, trap_demo/,
    │   │   hello_elf/                               ← UNCHANGED
    │   ├── kernel/                                  ← UNCHANGED (Phase 2)
    │   └── plic_block_test/                         ← NEW
    │       ├── boot.S                               M-mode setup + drop to S
    │       ├── test.S                               S-mode body + trap handler
    │       └── linker.ld                            Single PT_LOAD at 0x80000000
    ├── fixtures/                                    ← UNCHANGED
    ├── riscv-tests/                                 ← UNCHANGED
    ├── riscv-tests-p.ld                             ← UNCHANGED
    ├── riscv-tests-s.ld                             ← UNCHANGED
    └── riscv-tests-shim/                            ← UNCHANGED
```

**Module responsibilities (deltas vs Plan 2.D):**

- **`devices/plic.zig`** — new module. `Plic` struct holds: `priority: [32]u3`, `pending: u32`, `enable_s: u32`, `threshold_s: u3`, `last_claimed_s: u32` (debug-only). `init` sets all to zero. `readByte(offset)` and `writeByte(offset, byte)` follow the byte-wise pattern of `clint.zig` so word-sized loads/stores get the standard byte-aggregation in `memory.zig`. `assertSource(irq)` / `deassertSource(irq)` mutate `pending`. `claim()` returns the winner ID and clears the bit. `hasPendingForS()` is a pure query.
- **`devices/block.zig`** — new module. `Block` struct holds: `sector: u32`, `buffer_pa: u32`, `status: u32`, `pending_irq: bool`, `disk_file: ?std.fs.File`. Calls into `cpu.memory` indirectly via a back-pointer (we wire it through `Block.init(memory: *Memory)` later — but for Plan 3.A's first task the read/write transfer happens via `Block.performTransfer(self, mem)` taking the memory by argument from `memory.storeBytePhysical`). `readByte` / `writeByte` follow the byte-wise pattern. `performTransfer(self, ram: []u8)` actually moves bytes between the host file and a slice of RAM.
- **`devices/uart.zig`** — gains a fixed 256-byte ring buffer (`rx_buf: [256]u8`, `rx_head: u16`, `rx_tail: u16`, `rx_count: u16`) and an optional back-pointer to PLIC (`plic: ?*Plic`, set after construction in `main.zig`'s startup). `readByte(REG_RBR)` pops; `pushRx` appends and toggles PLIC source 10.
- **`memory.zig`** — `Memory` struct gains `plic: *Plic` and `block: *Block` fields (always present; no-disk simply means `block.disk_file` is null). `init` signature grows two parameters. `loadBytePhysical` / `storeBytePhysical` get two new `inRange` arms. The block device's actual transfer execution happens via `block.performTransfer(self.ram[ram_off..ram_off+4096])` after `storeBytePhysical` writes the `CMD` byte and observes the side-effect.
- **`cpu.zig`** — `pendingInterrupts(cpu)` gains a third OR (SEIP from PLIC). `Cpu.step` gains a top-of-function call to `cpu.memory.block.servicePendingIrq(cpu.memory.plic)` so a deferred block IRQ fires on the next instruction boundary, matching the spec. `Cpu` gains an `idle_spin` helper called by `execute.zig`'s wfi arm.
- **`execute.zig`** — the `.wfi` arm changes: M-mode wfi calls `cpu.idle_spin()` which loops on `check_interrupt` and `pumpDevices` until a trap is taken (or the time-bound expires). U-mode wfi still traps illegal. PC advance happens after the spin, matching Phase 2 (so a returning trap handler observes `pc + 4`, but in our case `wfi` returns to its successor instruction unchanged — `cpu.idle_spin` is conceptually "wait, then return", and the trap entry from inside the spin redirects PC to `stvec.BASE` so the +4 advance is moot when an interrupt fired).
- **`csr.zig`** — `CSR_MIP` and `CSR_SIP` read paths each gain an OR on bit 9 (SEIP) when the live PLIC says S has a pending source. `MIP_WRITE_MASK` loses bit 9 (SEIP is now PLIC-controlled, not software-writable). Existing tests that wrote SEIP via `csrWrite(MIP, 1<<9)` need migrating to `cpu.memory.plic.assertSource(...)` — Task 9 owns this migration.
- **`trace.zig`** — `formatInterruptMarker` signature gains an optional `?u5 plic_src` argument; when `cause_code == 9` and the argument is non-null, the marker line includes `, src N`. New `formatBlockTransfer(writer, op_kind, sector, pa)` emits one line.
- **`main.zig`** — `parseArgs` learns `--disk PATH`, `--input PATH`, `--disk-latency CYCLES`. Disk file opens in `main` and is passed to `Block.init`. `--input` opens the file and feeds bytes through a small `RxPump` that the idle loop drains.
- **`build.zig`** — adds the plic_block_test build pipeline (asm-only, similar to riscv-tests) and an `e2e-plic-block` step that runs `ccc --disk zig-out/plic_block_test.img zig-out/bin/plic_block_test.elf` and asserts exit code 0. A small host-side encoder generates the 4 MB test image (sector 0 = magic bytes, rest zero).

---

## Conventions used in this plan

- All Zig code targets Zig 0.16.x. Same API surface as Plan 2.D.
- Tests live as inline `test "name" { ... }` blocks alongside the code under test. `zig build test` runs every test reachable from `src/main.zig`. `main.zig`'s `comptime { _ = @import(...) }` block is updated when new files arrive (Tasks 1 and 9).
- Each task ends with a TDD cycle: write failing test, see it fail, implement minimally, verify pass, commit. Commit messages follow Conventional Commits.
- When extending a grouped switch (memory.zig MMIO dispatch, csr.zig CSR address arms, the build.zig family list), we show the full block so diffs are unambiguous.
- RISC-V spec bit positions and PLIC offsets are quoted inline in tests when they appear as magic numbers, so a reviewer doesn't have to cross-reference.
- All new tests exercise a single behavioral contract. PLIC tests enumerate one priority/threshold/enable configuration per test rather than table-driven — keeps failure messages pinpoint.
- Whenever a test needs a real `Memory`, it uses a local `setupRig()` helper. Per Plan 2.A/B convention, we don't extract a shared rig module — each file gets its own copy. The helper in Plan 3.A grows two arguments (PLIC, Block) but stays per-file.
- Task order respects strict dependencies: PLIC storage before the API that mutates it; PLIC's `hasPendingForS` before csr.zig consumes it; Block storage before performTransfer; Memory dispatch arms before main.zig wiring; integration test last.

---

## Tasks

### Task 1: Create `devices/plic.zig` — empty module + storage

**Files:**
- Create: `src/devices/plic.zig`
- Modify: `src/main.zig` (the comptime test-import block)

**Why this task first:** The PLIC is the substrate every other Phase 3.A task interacts with — block, UART, CSR mip wiring, integration test. Landing the empty module first gives later tasks a place to add storage and behavior without churning module boundaries. We also wire `_ = @import("devices/plic.zig");` into `main.zig`'s comptime block now so the file's tests run from the start.

- [ ] **Step 1: Write a failing test that the new module exists and exposes a `Plic` struct with `init`**

Create `src/devices/plic.zig`:

```zig
const std = @import("std");

pub const PLIC_BASE: u32 = 0x0c00_0000;
pub const PLIC_SIZE: u32 = 0x0040_0000; // 4 MB legacy aperture

pub const Plic = struct {
    pub fn init() Plic {
        return .{};
    }
};

test "Plic.init constructs a default Plic" {
    const p = Plic.init();
    _ = p;
}
```

Add to `src/main.zig`'s comptime block:

```zig
comptime {
    _ = @import("cpu.zig");
    _ = @import("memory.zig");
    _ = @import("devices/halt.zig");
    _ = @import("devices/uart.zig");
    _ = @import("devices/clint.zig");
    _ = @import("devices/plic.zig");   // <-- NEW
    _ = @import("decoder.zig");
    _ = @import("execute.zig");
    _ = @import("csr.zig");
    _ = @import("trap.zig");
    _ = @import("elf.zig");
    _ = @import("trace.zig");
}
```

- [ ] **Step 2: Run the test to verify it passes (sanity-only, no failure expected since the test only asserts the type compiles)**

Run: `zig build test`
Expected: all tests pass. The new test "Plic.init constructs a default Plic" runs and passes.

- [ ] **Step 3: (No further implementation in Task 1.)** The module is intentionally empty pending Tasks 2-7.

- [ ] **Step 4: Commit**

```bash
git add src/devices/plic.zig src/main.zig
git commit -m "feat(plic): scaffold devices/plic.zig with empty Plic struct"
```

---

### Task 2: PLIC — per-source priority storage + register read/write

**Files:**
- Modify: `src/devices/plic.zig`

**Why now:** Priority is the simplest PLIC sub-feature: 32 registers, no cross-register state, exact byte-wise round-trip semantics. Landing it before pending/enable/threshold means later tasks can write tests that depend on real priority values.

PLIC priority register offset layout (u32 each, little-endian byte access):
- Offset `0x0000` — source 0 (reserved, hardwired 0).
- Offsets `0x0004 .. 0x007C` — sources 1..31.

Each priority is u3 (values 0..7) per the spec; we mask writes to that range.

- [ ] **Step 1: Write failing tests for priority byte round-trip and value masking**

Append to `src/devices/plic.zig`:

```zig
test "priority source 1 byte round-trip" {
    var p = Plic.init();
    try p.writeByte(0x0004, 0x05); // src 1 priority byte 0
    try std.testing.expectEqual(@as(u8, 0x05), try p.readByte(0x0004));
}

test "priority source 0 is hardwired zero (writes dropped)" {
    var p = Plic.init();
    try p.writeByte(0x0000, 0x07);
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x0000));
}

test "priority writes mask to 0..7 (drops upper bits)" {
    var p = Plic.init();
    try p.writeByte(0x0004, 0xFF); // 0xFF -> masked to 0x07
    try std.testing.expectEqual(@as(u8, 0x07), try p.readByte(0x0004));
    // Upper bytes of the priority u32 always read 0 (priority is u3).
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x0005));
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x0006));
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x0007));
}

test "priority source 31 is the last writable priority slot" {
    var p = Plic.init();
    try p.writeByte(0x007C, 0x03);
    try std.testing.expectEqual(@as(u8, 0x03), try p.readByte(0x007C));
}
```

- [ ] **Step 2: Run the tests to verify they fail (no `readByte`/`writeByte` exist yet)**

Run: `zig build test`
Expected: compile error: `Plic` has no member `readByte` / `writeByte`.

- [ ] **Step 3: Add storage and the byte accessors**

Replace the body of `Plic` and add the `PlicError` enum:

```zig
pub const PlicError = error{UnexpectedRegister};

pub const NSOURCES: u32 = 32;

pub const Plic = struct {
    /// Per-source priority. Index 0 hardwired 0 (source 0 reserved by spec).
    /// Indices 1..31 hold u3 (0..7).
    priority: [NSOURCES]u3 = [_]u3{0} ** NSOURCES,

    pub fn init() Plic {
        return .{};
    }

    pub fn readByte(self: *const Plic, offset: u32) PlicError!u8 {
        // Priority registers: 0x0000..0x007F (u32 per source, src 0..31).
        if (offset < 0x0080) {
            const src: u5 = @intCast(offset / 4);
            const byte_in_word: u2 = @intCast(offset % 4);
            // Priority is u3, lives in byte 0 of the u32; bytes 1..3 are 0.
            if (byte_in_word == 0) return @as(u8, self.priority[src]);
            return 0;
        }
        // Out-of-range (the rest of the 4 MB aperture): lenient zero.
        return 0;
    }

    pub fn writeByte(self: *Plic, offset: u32, value: u8) PlicError!void {
        if (offset < 0x0080) {
            const src: u5 = @intCast(offset / 4);
            const byte_in_word: u2 = @intCast(offset % 4);
            // Source 0 is reserved — writes silently dropped.
            if (src == 0) return;
            // Only byte 0 stores; mask to u3.
            if (byte_in_word == 0) {
                self.priority[src] = @intCast(value & 0x07);
            }
            // Bytes 1..3 are write-ignored (priority is u3).
            return;
        }
        // Out-of-range writes silently dropped.
    }
};
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: all four new tests pass; previous tests unchanged.

- [ ] **Step 5: Commit**

```bash
git add src/devices/plic.zig
git commit -m "feat(plic): per-source priority registers (0x000-0x07F)"
```

---

### Task 3: PLIC — pending bits + `assertSource` / `deassertSource`

**Files:**
- Modify: `src/devices/plic.zig`

**Why now:** Devices push state changes through these two functions; tests for enable/threshold/claim need to seed pending bits via the public API rather than poking storage directly. This task introduces the read-only pending register at offset `0x1000`.

PLIC pending register: u32 at offset `0x1000`. Bit N reflects pending for source N. Bit 0 hardwired 0. Read-only from MMIO; mutated via `assertSource` / `deassertSource`.

- [ ] **Step 1: Write failing tests for the pending register and the API**

Append to `src/devices/plic.zig`:

```zig
test "assertSource(5) sets pending bit 5" {
    var p = Plic.init();
    p.assertSource(5);
    // Pending u32 lives at offset 0x1000.
    try std.testing.expectEqual(@as(u8, 0b0010_0000), try p.readByte(0x1000)); // byte 0, bit 5
}

test "deassertSource(5) clears pending bit 5" {
    var p = Plic.init();
    p.assertSource(5);
    p.deassertSource(5);
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x1000));
}

test "assertSource(0) is a no-op (source 0 reserved)" {
    var p = Plic.init();
    p.assertSource(0);
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x1000));
}

test "assertSource is idempotent" {
    var p = Plic.init();
    p.assertSource(10);
    p.assertSource(10);
    p.assertSource(10);
    // Bit 10 sits in byte 1 (bit 2 of byte 1).
    try std.testing.expectEqual(@as(u8, 0b0000_0100), try p.readByte(0x1001));
}

test "MMIO writes to pending register are dropped (read-only)" {
    var p = Plic.init();
    try p.writeByte(0x1000, 0xFF);
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x1000));
}

test "assertSource(31) reaches byte 3" {
    var p = Plic.init();
    p.assertSource(31);
    try std.testing.expectEqual(@as(u8, 0x80), try p.readByte(0x1003)); // bit 7 of byte 3
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: compile error: `Plic` has no member `assertSource` / `deassertSource`.

- [ ] **Step 3: Add the storage field and the three new methods; extend readByte/writeByte for offset 0x1000-0x1003**

Modify the `Plic` struct (full new state):

```zig
pub const Plic = struct {
    priority: [NSOURCES]u3 = [_]u3{0} ** NSOURCES,
    /// Pending bits. Bit N pending for source N. Bit 0 hardwired 0.
    /// Mutated via assertSource/deassertSource and (later) cleared on claim.
    pending: u32 = 0,

    pub fn init() Plic {
        return .{};
    }

    pub fn assertSource(self: *Plic, irq: u5) void {
        if (irq == 0) return;
        self.pending |= @as(u32, 1) << irq;
    }

    pub fn deassertSource(self: *Plic, irq: u5) void {
        if (irq == 0) return;
        self.pending &= ~(@as(u32, 1) << irq);
    }

    pub fn readByte(self: *const Plic, offset: u32) PlicError!u8 {
        if (offset < 0x0080) {
            const src: u5 = @intCast(offset / 4);
            const byte_in_word: u2 = @intCast(offset % 4);
            if (byte_in_word == 0) return @as(u8, self.priority[src]);
            return 0;
        }
        // Pending register: u32 at 0x1000..0x1003.
        if (offset >= 0x1000 and offset < 0x1004) {
            const shift: u5 = @intCast((offset - 0x1000) * 8);
            return @truncate(self.pending >> shift);
        }
        return 0;
    }

    pub fn writeByte(self: *Plic, offset: u32, value: u8) PlicError!void {
        if (offset < 0x0080) {
            const src: u5 = @intCast(offset / 4);
            const byte_in_word: u2 = @intCast(offset % 4);
            if (src == 0) return;
            if (byte_in_word == 0) {
                self.priority[src] = @intCast(value & 0x07);
            }
            return;
        }
        // Pending register is read-only.
        if (offset >= 0x1000 and offset < 0x1004) return;
        // Out-of-range writes silently dropped.
    }
};
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: all six new tests pass; previous tests unchanged.

- [ ] **Step 5: Commit**

```bash
git add src/devices/plic.zig
git commit -m "feat(plic): pending bits with assertSource/deassertSource"
```

---

### Task 4: PLIC — S-context enable bits

**Files:**
- Modify: `src/devices/plic.zig`

**Why now:** Enable bits gate which sources can be delivered to the S-mode hart context. Threshold (Task 5) and claim (Task 6) compose with enables. We model only the S-context (no M-context) per spec.

S-context enable register: u32 at offset `0x2080`. Bit N permits source N to drive `mip.SEIP` for the S-context. Bit 0 hardwired 0.

- [ ] **Step 1: Write failing tests for the enable register**

Append to `src/devices/plic.zig`:

```zig
test "S-context enable register byte round-trip" {
    var p = Plic.init();
    try p.writeByte(0x2080, 0xFE); // enable srcs 1..7
    try std.testing.expectEqual(@as(u8, 0xFE), try p.readByte(0x2080));
}

test "S-context enable bit 0 is hardwired zero (writes dropped)" {
    var p = Plic.init();
    try p.writeByte(0x2080, 0xFF);
    // Bit 0 stays 0; bits 1..7 honored.
    try std.testing.expectEqual(@as(u8, 0xFE), try p.readByte(0x2080));
}

test "S-context enable spans all 4 bytes (sources 0..31)" {
    var p = Plic.init();
    try p.writeByte(0x2080, 0x02); // src 1
    try p.writeByte(0x2081, 0x04); // src 10
    try p.writeByte(0x2082, 0x00);
    try p.writeByte(0x2083, 0x80); // src 31
    try std.testing.expectEqual(@as(u8, 0x02), try p.readByte(0x2080));
    try std.testing.expectEqual(@as(u8, 0x04), try p.readByte(0x2081));
    try std.testing.expectEqual(@as(u8, 0x80), try p.readByte(0x2083));
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: tests fail because reads at `0x2080` return 0 (out-of-range arm) and writes are silently dropped.

- [ ] **Step 3: Add `enable_s` storage and the new dispatch arms in readByte/writeByte**

Modify the struct (showing only the new field + the new branches):

```zig
pub const Plic = struct {
    priority: [NSOURCES]u3 = [_]u3{0} ** NSOURCES,
    pending: u32 = 0,
    /// S-mode hart context enable bits. Bit N permits source N to drive
    /// the S-context's claim/threshold gate. Bit 0 hardwired 0.
    enable_s: u32 = 0,

    pub fn init() Plic {
        return .{};
    }

    // ... assertSource, deassertSource unchanged ...

    pub fn readByte(self: *const Plic, offset: u32) PlicError!u8 {
        if (offset < 0x0080) { /* priority — unchanged */
            const src: u5 = @intCast(offset / 4);
            const byte_in_word: u2 = @intCast(offset % 4);
            if (byte_in_word == 0) return @as(u8, self.priority[src]);
            return 0;
        }
        if (offset >= 0x1000 and offset < 0x1004) { /* pending — unchanged */
            const shift: u5 = @intCast((offset - 0x1000) * 8);
            return @truncate(self.pending >> shift);
        }
        // S-context enables: 0x2080..0x2083.
        if (offset >= 0x2080 and offset < 0x2084) {
            const shift: u5 = @intCast((offset - 0x2080) * 8);
            return @truncate(self.enable_s >> shift);
        }
        return 0;
    }

    pub fn writeByte(self: *Plic, offset: u32, value: u8) PlicError!void {
        if (offset < 0x0080) { /* priority — unchanged */
            const src: u5 = @intCast(offset / 4);
            const byte_in_word: u2 = @intCast(offset % 4);
            if (src == 0) return;
            if (byte_in_word == 0) self.priority[src] = @intCast(value & 0x07);
            return;
        }
        if (offset >= 0x1000 and offset < 0x1004) return;
        // S-context enables.
        if (offset >= 0x2080 and offset < 0x2084) {
            const off: u5 = @intCast((offset - 0x2080) * 8);
            const mask: u32 = @as(u32, 0xFF) << off;
            const new_byte: u32 = @as(u32, value) << off;
            self.enable_s = (self.enable_s & ~mask) | new_byte;
            // Bit 0 hardwired zero.
            self.enable_s &= ~@as(u32, 1);
            return;
        }
    }
};
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: all three new tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/devices/plic.zig
git commit -m "feat(plic): S-context enable register (0x2080)"
```

---

### Task 5: PLIC — S-context threshold register

**Files:**
- Modify: `src/devices/plic.zig`

**Why now:** Threshold completes the gate equation `(pending & enable & priority > threshold)` that `hasPendingForS` will compute in Task 7. Threshold is a single u32 (low 3 bits used) at offset `0x20_1000`.

- [ ] **Step 1: Write failing tests for the threshold register**

Append to `src/devices/plic.zig`:

```zig
test "S-context threshold byte round-trip with masking" {
    var p = Plic.init();
    try p.writeByte(0x20_1000, 0x07);
    try std.testing.expectEqual(@as(u8, 0x07), try p.readByte(0x20_1000));
    // Upper bytes of the threshold u32 are always 0 (threshold is u3).
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x20_1001));
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x20_1002));
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x20_1003));
}

test "S-context threshold writes mask to 0..7" {
    var p = Plic.init();
    try p.writeByte(0x20_1000, 0xFF);
    try std.testing.expectEqual(@as(u8, 0x07), try p.readByte(0x20_1000));
}

test "S-context threshold defaults to 0" {
    const p = Plic.init();
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x20_1000));
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: reads at `0x20_1000` return 0 from the lenient out-of-range arm; the write is dropped, so the round-trip test fails (expected 0x07, got 0).

- [ ] **Step 3: Add `threshold_s` storage + dispatch arms**

Add the new field and the new cases:

```zig
pub const Plic = struct {
    priority: [NSOURCES]u3 = [_]u3{0} ** NSOURCES,
    pending: u32 = 0,
    enable_s: u32 = 0,
    /// S-context threshold (u3 0..7). A source's priority must be strictly
    /// greater than this to be deliverable.
    threshold_s: u3 = 0,

    // ... unchanged init, assertSource, deassertSource ...

    pub fn readByte(self: *const Plic, offset: u32) PlicError!u8 {
        if (offset < 0x0080) { /* priority — unchanged */ ... }
        if (offset >= 0x1000 and offset < 0x1004) { /* pending — unchanged */ ... }
        if (offset >= 0x2080 and offset < 0x2084) { /* enable_s — unchanged */ ... }
        // S-context threshold: 0x20_1000..0x20_1003.
        if (offset >= 0x20_1000 and offset < 0x20_1004) {
            const byte_in_word: u2 = @intCast(offset - 0x20_1000);
            if (byte_in_word == 0) return @as(u8, self.threshold_s);
            return 0;
        }
        return 0;
    }

    pub fn writeByte(self: *Plic, offset: u32, value: u8) PlicError!void {
        if (offset < 0x0080) { /* priority — unchanged */ ... }
        if (offset >= 0x1000 and offset < 0x1004) return;
        if (offset >= 0x2080 and offset < 0x2084) { /* enable_s — unchanged */ ... }
        // S-context threshold.
        if (offset >= 0x20_1000 and offset < 0x20_1004) {
            const byte_in_word: u2 = @intCast(offset - 0x20_1000);
            if (byte_in_word == 0) self.threshold_s = @intCast(value & 0x07);
            return;
        }
    }
};
```

(Spell out the unchanged arms in your edit — the comments above are shorthand for "keep what's there.")

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: all three new tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/devices/plic.zig
git commit -m "feat(plic): S-context threshold register (0x20_1000)"
```

---

### Task 6: PLIC — claim/complete register + `claim()` API

**Files:**
- Modify: `src/devices/plic.zig`

**Why now:** Claim is the read side-effecting register: reading returns the highest-priority pending+enabled source whose priority > threshold, and atomically clears that source's pending bit. Complete (write to the same register) is a notification — for our model it does nothing, but we accept the write. Tasks 7+ depend on `claim()`'s semantics being correct.

Spec rule (https://github.com/riscv/riscv-plic-spec):
- Result = the highest-priority pending+enabled source for the context, with ties broken by lowest source ID.
- Pending bit is cleared atomically with the read.
- Returns 0 if no source qualifies.

- [ ] **Step 1: Write failing tests for `claim()` and the MMIO register**

Append to `src/devices/plic.zig`:

```zig
test "claim returns 0 when no source pending" {
    var p = Plic.init();
    try std.testing.expectEqual(@as(u32, 0), p.claim());
}

test "claim returns sole pending source and clears its bit" {
    var p = Plic.init();
    try p.writeByte(0x0004, 1);   // src 1 priority 1
    try p.writeByte(0x2080, 0x02); // enable src 1
    p.assertSource(1);
    try std.testing.expectEqual(@as(u32, 1), p.claim());
    // pending bit cleared after claim.
    try std.testing.expectEqual(@as(u32, 0), p.pending);
    // Subsequent claim returns 0.
    try std.testing.expectEqual(@as(u32, 0), p.claim());
}

test "claim picks highest priority among pending+enabled" {
    var p = Plic.init();
    try p.writeByte(0x0004, 2); // src 1 priority 2
    try p.writeByte(0x000C, 5); // src 3 priority 5
    try p.writeByte(0x0028, 3); // src 10 priority 3
    try p.writeByte(0x2080, 0xFE); // enable srcs 1..7
    try p.writeByte(0x2081, 0x04); // enable src 10
    p.assertSource(1);
    p.assertSource(3);
    p.assertSource(10);
    // src 3 wins (priority 5 > 3 > 2).
    try std.testing.expectEqual(@as(u32, 3), p.claim());
    // src 1 and 10 still pending.
    try std.testing.expect((p.pending & (1 << 1)) != 0);
    try std.testing.expect((p.pending & (1 << 10)) != 0);
}

test "claim breaks priority ties by lowest source ID" {
    var p = Plic.init();
    try p.writeByte(0x0004, 4); // src 1 priority 4
    try p.writeByte(0x0008, 4); // src 2 priority 4
    try p.writeByte(0x2080, 0x06); // enable srcs 1, 2
    p.assertSource(2);
    p.assertSource(1);
    try std.testing.expectEqual(@as(u32, 1), p.claim());
}

test "claim ignores sources whose priority <= threshold" {
    var p = Plic.init();
    try p.writeByte(0x0004, 3);     // src 1 priority 3
    try p.writeByte(0x2080, 0x02);  // enable src 1
    try p.writeByte(0x20_1000, 3);  // threshold = 3
    p.assertSource(1);
    // priority 3 is NOT > 3 → not deliverable.
    try std.testing.expectEqual(@as(u32, 0), p.claim());
    // Pending bit still set (claim didn't fire).
    try std.testing.expect((p.pending & (1 << 1)) != 0);
}

test "claim ignores disabled sources" {
    var p = Plic.init();
    try p.writeByte(0x0004, 4);
    // enable_s zero — src 1 not enabled.
    p.assertSource(1);
    try std.testing.expectEqual(@as(u32, 0), p.claim());
}

test "claim register MMIO read is the same as claim() function" {
    var p = Plic.init();
    try p.writeByte(0x0004, 1);
    try p.writeByte(0x2080, 0x02);
    p.assertSource(1);
    // Word read at 0x20_1004 should yield 1, byte-by-byte.
    const b0 = try p.readByte(0x20_1004);
    const b1 = try p.readByte(0x20_1005);
    const b2 = try p.readByte(0x20_1006);
    const b3 = try p.readByte(0x20_1007);
    const v: u32 = @as(u32, b0) | (@as(u32, b1) << 8) | (@as(u32, b2) << 16) | (@as(u32, b3) << 24);
    try std.testing.expectEqual(@as(u32, 1), v);
}

test "complete (write to claim register) is a no-op" {
    var p = Plic.init();
    try p.writeByte(0x20_1004, 1);
    try p.writeByte(0x20_1005, 0);
    try p.writeByte(0x20_1006, 0);
    try p.writeByte(0x20_1007, 0);
    // No state observed; just doesn't crash.
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: compile error: `Plic` has no member `claim`.

- [ ] **Step 3: Implement `claim()` and the MMIO arm at offset 0x20_1004**

Add the method:

```zig
/// Claim the highest-priority pending+enabled source whose priority is
/// strictly greater than the S-context threshold. Returns the source ID
/// (1..31) or 0 if no source qualifies. Atomically clears the chosen
/// source's pending bit.
pub fn claim(self: *Plic) u32 {
    var best_id: u32 = 0;
    var best_prio: u3 = 0;
    var i: u5 = 1;
    while (true) : (i += 1) {
        if ((self.pending & (@as(u32, 1) << i)) != 0 and
            (self.enable_s & (@as(u32, 1) << i)) != 0)
        {
            const prio = self.priority[i];
            if (prio > self.threshold_s and prio > best_prio) {
                best_prio = prio;
                best_id = i;
            }
        }
        if (i == 31) break;
    }
    if (best_id != 0) {
        self.pending &= ~(@as(u32, 1) << @intCast(best_id));
    }
    return best_id;
}
```

Extend `readByte` for the claim register, and `writeByte` for the complete register:

```zig
pub fn readByte(self: *const Plic, offset: u32) PlicError!u8 {
    // ... priority, pending, enable_s, threshold arms unchanged ...

    // S-context claim/complete: 0x20_1004..0x20_1007. Reading is destructive.
    if (offset >= 0x20_1004 and offset < 0x20_1008) {
        // Cast away const for the destructive read — claim mutates state.
        // Spec says claim is atomic; we model it as a single byte triggers
        // the claim and subsequent bytes return the rest of that 32-bit value.
        // Real hardware does this with a 32-bit read; our byte-wise dispatcher
        // calls readByte 4 times. We implement the claim on byte 0 and store
        // the result in a sticky scratch field (claim_latch) for bytes 1..3.
        return self.byteOfClaimLatch(@intCast(offset - 0x20_1004));
    }
    return 0;
}
```

To support the byte-wise dispatcher reading a 32-bit claim across four `readByte` calls, add a small latch:

```zig
pub const Plic = struct {
    priority: [NSOURCES]u3 = [_]u3{0} ** NSOURCES,
    pending: u32 = 0,
    enable_s: u32 = 0,
    threshold_s: u3 = 0,
    /// Latch for byte-wise reads of the claim register: byte 0 triggers
    /// the claim and stores the result here; bytes 1..3 return slices of it.
    /// Reset after byte 3 so the next byte-0 read performs a fresh claim.
    claim_latch: u32 = 0,
    claim_latch_valid: bool = false,

    // ... assertSource, deassertSource unchanged ...

    pub fn claim(self: *Plic) u32 {
        // ... (function body as above) ...
    }

    fn byteOfClaimLatch(self: *Plic, byte: u2) u8 {
        if (byte == 0) {
            self.claim_latch = self.claim();
            self.claim_latch_valid = true;
            return @truncate(self.claim_latch);
        }
        if (!self.claim_latch_valid) return 0;
        const b: u8 = @truncate(self.claim_latch >> (@as(u5, byte) * 8));
        if (byte == 3) self.claim_latch_valid = false;
        return b;
    }

    pub fn readByte(self: *Plic, offset: u32) PlicError!u8 {
        // Note: signature changed to *Plic (mutable) because byte 0 of the
        // claim register triggers a destructive claim. Callers that hold
        // a *const Plic must obtain a mutable pointer for these reads —
        // memory.zig's dispatcher already holds *Memory which exposes the
        // PLIC mutably.
        if (offset < 0x0080) { /* priority — unchanged */ ... }
        if (offset >= 0x1000 and offset < 0x1004) { /* pending — unchanged */ ... }
        if (offset >= 0x2080 and offset < 0x2084) { /* enable_s — unchanged */ ... }
        if (offset >= 0x20_1000 and offset < 0x20_1004) { /* threshold — unchanged */ ... }
        if (offset >= 0x20_1004 and offset < 0x20_1008) {
            return self.byteOfClaimLatch(@intCast(offset - 0x20_1004));
        }
        return 0;
    }

    pub fn writeByte(self: *Plic, offset: u32, value: u8) PlicError!void {
        if (offset < 0x0080) { /* priority — unchanged */ ... }
        if (offset >= 0x1000 and offset < 0x1004) return;
        if (offset >= 0x2080 and offset < 0x2084) { /* enable_s — unchanged */ ... }
        if (offset >= 0x20_1000 and offset < 0x20_1004) { /* threshold — unchanged */ ... }
        // Complete: writes are accepted and ignored.
        if (offset >= 0x20_1004 and offset < 0x20_1008) {
            _ = value;
            return;
        }
    }
};
```

Note that `readByte` now takes `*Plic` (mutable) instead of `*const Plic`. Existing tests that use `*const Plic` for read need updating — let your editor surface every call site and change them to `*Plic`. There should be no `*const` callers outside `plic.zig`'s own tests at this point.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: all eight new tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/devices/plic.zig
git commit -m "feat(plic): claim/complete (0x20_1004) with priority/threshold gating"
```

---

### Task 7: PLIC — `hasPendingForS()` deliverability summary

**Files:**
- Modify: `src/devices/plic.zig`

**Why now:** Tasks 8 and 9 wire the PLIC's "is anything deliverable for the S-context?" output into `cpu.csr.mip.SEIP`. We expose this as a single non-destructive query. `hasPendingForS` mirrors the `claim()` logic but never mutates state — so reading `mip` doesn't accidentally claim.

- [ ] **Step 1: Write failing tests for `hasPendingForS`**

Append to `src/devices/plic.zig`:

```zig
test "hasPendingForS: false on init" {
    const p = Plic.init();
    try std.testing.expect(!p.hasPendingForS());
}

test "hasPendingForS: true when source pending+enabled+priority>threshold" {
    var p = Plic.init();
    try p.writeByte(0x0004, 4);       // src 1 priority 4
    try p.writeByte(0x2080, 0x02);    // enable src 1
    try p.writeByte(0x20_1000, 3);    // threshold 3
    p.assertSource(1);
    try std.testing.expect(p.hasPendingForS());
}

test "hasPendingForS: false when priority not > threshold" {
    var p = Plic.init();
    try p.writeByte(0x0004, 3);       // src 1 priority 3
    try p.writeByte(0x2080, 0x02);
    try p.writeByte(0x20_1000, 3);    // threshold = priority → NOT >
    p.assertSource(1);
    try std.testing.expect(!p.hasPendingForS());
}

test "hasPendingForS: false when source disabled" {
    var p = Plic.init();
    try p.writeByte(0x0004, 4);
    // enable_s = 0
    p.assertSource(1);
    try std.testing.expect(!p.hasPendingForS());
}

test "hasPendingForS does NOT clear pending (non-destructive)" {
    var p = Plic.init();
    try p.writeByte(0x0004, 4);
    try p.writeByte(0x2080, 0x02);
    p.assertSource(1);
    _ = p.hasPendingForS();
    try std.testing.expect((p.pending & (1 << 1)) != 0);
    try std.testing.expect(p.hasPendingForS());
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: compile error: `Plic` has no member `hasPendingForS`.

- [ ] **Step 3: Implement `hasPendingForS`**

Add the method:

```zig
/// Non-destructive query: does any source have pending=1, enabled=1,
/// and priority > S-context threshold? Used by csr.zig to derive
/// mip.SEIP without claiming the source.
pub fn hasPendingForS(self: *const Plic) bool {
    const candidates = self.pending & self.enable_s;
    if (candidates == 0) return false;
    var i: u5 = 1;
    while (true) : (i += 1) {
        if ((candidates & (@as(u32, 1) << i)) != 0 and
            self.priority[i] > self.threshold_s)
        {
            return true;
        }
        if (i == 31) break;
    }
    return false;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: all five new tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/devices/plic.zig
git commit -m "feat(plic): non-destructive hasPendingForS query"
```

---

### Task 8: `memory.zig` — dispatch PLIC MMIO range

**Files:**
- Modify: `src/memory.zig`
- Modify: callers of `Memory.init` (cpu.zig tests, memory.zig tests, main.zig — see below)

**Why now:** The PLIC has a working register file and a public API; now make it reachable from guest code via MMIO. We also widen `Memory` to hold a `*Plic` pointer (always required — no `?*` here, since the PLIC is part of the platform model now).

- [ ] **Step 1: Write a failing test that a load/store at PLIC base routes to the device**

Append to `src/memory.zig`:

```zig
test "MMIO load at PLIC base reads from PLIC" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();

    // Set src 1 priority via direct PLIC API, then read via MMIO.
    rig.plic.priority[1] = 5;
    const v = try rig.mem.loadBytePhysical(0x0c00_0004);
    try std.testing.expectEqual(@as(u8, 5), v);
}

test "MMIO store at PLIC priority offset routes to PLIC" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();

    try rig.mem.storeBytePhysical(0x0c00_0004, 3);
    try std.testing.expectEqual(@as(u3, 3), rig.plic.priority[1]);
}

test "MMIO assertSource path: pending visible via MMIO read" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    rig.plic.assertSource(5);
    const b = try rig.mem.loadBytePhysical(0x1000_1000); // wrong addr — PLIC pending is 0x0c00_1000
    _ = b;
    const correct = try rig.mem.loadBytePhysical(0x0c00_1000);
    try std.testing.expectEqual(@as(u8, 1 << 5), correct);
}
```

- [ ] **Step 2: Run the tests to verify they fail (compile error: `rig.plic` doesn't exist)**

Run: `zig build test`
Expected: compile error in `src/memory.zig` because `TestRig` has no `plic` field; further, `Memory.init` doesn't accept a `*Plic` arg.

- [ ] **Step 3: Add `plic: *Plic` to `Memory`, extend `init` signature, add MMIO dispatch arms, update `TestRig`, update every caller of `Memory.init`**

Add the import and field:

```zig
const plic_dev = @import("devices/plic.zig");

pub const Memory = struct {
    ram: []u8,
    halt: *halt_dev.Halt,
    uart: *uart_dev.Uart,
    clint: *clint_dev.Clint,
    plic: *plic_dev.Plic,                // NEW
    tohost_addr: ?u32,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        halt: *halt_dev.Halt,
        uart: *uart_dev.Uart,
        clint: *clint_dev.Clint,
        plic: *plic_dev.Plic,            // NEW
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
            .plic = plic,
            .tohost_addr = tohost_addr,
            .allocator = allocator,
        };
    }
    // ... unchanged: deinit, ramOffset, inRange, inTohost ...
};
```

Add the MMIO dispatch arms in `loadBytePhysical` and `storeBytePhysical`. Place them BEFORE the RAM fast path; arrange after the existing CLINT arm so all MMIO ranges sit together:

```zig
pub fn loadBytePhysical(self: *Memory, addr: u32) MemoryError!u8 {
    if (inRange(addr, uart_dev.UART_BASE, uart_dev.UART_SIZE)) { /* ... */ }
    if (inRange(addr, halt_dev.HALT_BASE, halt_dev.HALT_SIZE)) return 0;
    if (inRange(addr, clint_dev.CLINT_BASE, clint_dev.CLINT_SIZE)) { /* ... */ }
    if (inRange(addr, plic_dev.PLIC_BASE, plic_dev.PLIC_SIZE)) {
        return self.plic.readByte(addr - plic_dev.PLIC_BASE) catch |e| switch (e) {
            error.UnexpectedRegister => MemoryError.UnexpectedRegister,
        };
    }
    const off = try self.ramOffset(addr);
    return self.ram[off];
}

pub fn storeBytePhysical(self: *Memory, addr: u32, value: u8) MemoryError!void {
    if (inRange(addr, uart_dev.UART_BASE, uart_dev.UART_SIZE)) { /* ... */ }
    if (inRange(addr, halt_dev.HALT_BASE, halt_dev.HALT_SIZE)) { /* ... */ }
    if (inRange(addr, clint_dev.CLINT_BASE, clint_dev.CLINT_SIZE)) { /* ... */ }
    if (inRange(addr, plic_dev.PLIC_BASE, plic_dev.PLIC_SIZE)) {
        self.plic.writeByte(addr - plic_dev.PLIC_BASE, value) catch |e| switch (e) {
            error.UnexpectedRegister => return MemoryError.UnexpectedRegister,
        };
        return;
    }
    if (self.inTohost(addr)) { /* ... */ }
    const off = try self.ramOffset(addr);
    self.ram[off] = value;
}
```

Update `TestRig` to allocate a Plic:

```zig
const TestRig = struct {
    halt: halt_dev.Halt,
    uart: uart_dev.Uart,
    clint: clint_dev.Clint,
    plic: plic_dev.Plic,
    aw: std.Io.Writer.Allocating,
    mem: Memory,
    cpu: Cpu,

    fn init(self: *TestRig, allocator: std.mem.Allocator) !void {
        self.halt = halt_dev.Halt.init();
        self.aw = .init(allocator);
        self.uart = uart_dev.Uart.init(&self.aw.writer);
        self.clint = clint_dev.Clint.init(&clint_dev.fixtureClock);
        self.plic = plic_dev.Plic.init();
        self.mem = try Memory.init(allocator, &self.halt, &self.uart, &self.clint, &self.plic, null, RAM_SIZE_DEFAULT);
        self.cpu = Cpu.init(&self.mem, RAM_BASE);
    }

    fn deinit(self: *TestRig) void {
        self.mem.deinit();
        self.aw.deinit();
    }
};
```

Update every other call site of `Memory.init` to pass a Plic. The compiler will surface them. They are:

- `src/cpu.zig` — every test that calls `Memory.init`. Add a local `var plic = plic_dev.Plic.init();` and pass `&plic`.
- `src/csr.zig` — same pattern in tests that build a real Memory.
- `src/main.zig` — production path. Add `var plic = plic_dev.Plic.init();` near the existing CLINT init and pass `&plic`.
- `src/cpu.zig`'s `cpuRig` helper — extend the `CpuRig` struct with a `plic: plic_dev.Plic` field, init it, and pass to `Memory.init`.

Mechanically: search and replace, validating each call site with the test runner.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: all three new tests in memory.zig pass; all existing tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/memory.zig src/cpu.zig src/csr.zig src/main.zig
git commit -m "feat(memory): dispatch PLIC MMIO at 0x0c00_0000"
```

---

### Task 9: `csr.zig` + `cpu.zig` — live SEIP from PLIC

**Files:**
- Modify: `src/csr.zig` (CSR_MIP read arm, CSR_SIP read arm, MIP_WRITE_MASK, existing MIP/SIP tests)
- Modify: `src/cpu.zig` (`pendingInterrupts` helper)

**Why now:** With memory dispatch wired and `hasPendingForS` available, software can observe the PLIC's external-interrupt line via `mip.SEIP`. This mirrors Phase 2.B's MTIP-from-CLINT plumbing exactly. `cpu.check_interrupt` doesn't change algorithmically — it only sees an extra bit in the effective MIP.

- [ ] **Step 1: Write failing tests for live SEIP plumbing**

Append to `src/csr.zig` tests:

```zig
test "CSR_MIP read reflects live SEIP from PLIC when pending+enabled+over-threshold" {
    var rig = try csrTestRig();
    defer rig.deinit();
    // Set up PLIC: src 1 priority 4, enabled, threshold 0, pending.
    try rig.cpu.memory.plic.writeByte(0x0004, 4);
    try rig.cpu.memory.plic.writeByte(0x2080, 0x02);
    rig.cpu.memory.plic.assertSource(1);
    const v = try csrRead(&rig.cpu, CSR_MIP);
    try std.testing.expectEqual(@as(u32, 1 << 9), v & (1 << 9)); // SEIP set
}

test "CSR_MIP read: SEIP stays clear when PLIC says not deliverable" {
    var rig = try csrTestRig();
    defer rig.deinit();
    // PLIC default: nothing pending.
    const v = try csrRead(&rig.cpu, CSR_MIP);
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 9));
}

test "CSR_SIP read also reflects live SEIP from PLIC" {
    var rig = try csrTestRig();
    defer rig.deinit();
    try rig.cpu.memory.plic.writeByte(0x0004, 4);
    try rig.cpu.memory.plic.writeByte(0x2080, 0x02);
    rig.cpu.memory.plic.assertSource(1);
    const v = try csrRead(&rig.cpu, CSR_SIP);
    try std.testing.expectEqual(@as(u32, 1 << 9), v & (1 << 9));
}

test "CSR_MIP write masks out SEIP (PLIC owns it now)" {
    var rig = try csrTestRig();
    defer rig.deinit();
    try csrWrite(&rig.cpu, CSR_MIP, 1 << 9);
    // Stored mip.SEIP must remain 0; live read still 0 because PLIC has no pending.
    const v = try csrRead(&rig.cpu, CSR_MIP);
    try std.testing.expectEqual(@as(u32, 0), v & (1 << 9));
}

test "cpu.check_interrupt: SEIP delivers to S when delegated" {
    var rig = try csrTestRig();
    defer rig.deinit();
    rig.cpu.privilege = .U;
    rig.cpu.csr.stvec = 0x8000_0500;
    rig.cpu.csr.mideleg = 1 << 9;       // delegate SEIP
    rig.cpu.csr.mie = (1 << 9);         // enable SEIE
    rig.cpu.csr.mstatus_sie = true;
    // PLIC: src 1 priority 4, enabled, threshold 0, pending.
    try rig.cpu.memory.plic.writeByte(0x0004, 4);
    try rig.cpu.memory.plic.writeByte(0x2080, 0x02);
    rig.cpu.memory.plic.assertSource(1);

    const taken = @import("cpu.zig").check_interrupt(&rig.cpu);
    try std.testing.expect(taken);
    try std.testing.expectEqual(@as(u32, (1 << 31) | 9), rig.cpu.csr.scause);
    try std.testing.expectEqual(@import("cpu.zig").PrivilegeMode.S, rig.cpu.privilege);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: tests fail because the CSR_MIP read returns the stored bit (0); SEIP is not OR'd in. The check_interrupt test fails for the same reason.

- [ ] **Step 3: Wire SEIP into the CSR read paths and `pendingInterrupts`**

In `src/csr.zig`, find the `CSR_MIP` read arm (around line 242 per the existing code) and add the SEIP OR alongside the MTIP one:

```zig
CSR_MIP => blk: {
    var v = cpu.csr.mip;
    if (cpu.memory.clint.isMtipPending()) v |= 1 << 7;
    if (cpu.memory.plic.hasPendingForS()) v |= 1 << 9;
    break :blk v;
},
```

Find the `CSR_SIP` read arm (around line 199) and do the same:

```zig
CSR_SIP => blk: {
    var v = cpu.csr.mip & SIP_READ_MASK;
    if (cpu.memory.clint.isMtipPending()) v |= 1 << 7;
    if (cpu.memory.plic.hasPendingForS()) v |= 1 << 9;
    break :blk v;
},
```

Update `MIP_WRITE_MASK` to drop bit 9:

```zig
pub const MIP_WRITE_MASK: u32 =
    (1 << 1)  | // SSIP
    (1 << 3)  | // MSIP
    (1 << 5)  | // STIP
    (1 << 11);  // MEIP
// SEIP (bit 9) was previously software-writable for testing; now PLIC-owned.
```

In `src/cpu.zig`, modify `pendingInterrupts` (around line 193):

```zig
fn pendingInterrupts(cpu: *const Cpu) u32 {
    var mip = cpu.csr.mip;
    if (cpu.memory.clint.isMtipPending()) mip |= 1 << 7;
    if (cpu.memory.plic.hasPendingForS()) mip |= 1 << 9;
    return mip;
}
```

Migrate any existing test that writes `mip.SEIP` directly. Search for `1 << 9` and `SEIP` in `src/csr.zig`'s test section. There are at most a couple of tests that injected SEIP via `csrWrite(MIP, 1<<9)`; rewrite them to use `cpu.memory.plic.assertSource(...)` (and pre-program priority/enable/threshold) for the SEIP path. Tests asserting `MIP_WRITE_MASK` rejects bit 9 should now expect 0 after the masked write.

If there are NO existing tests that write `mip.SEIP` from software (a reasonable possibility), skip this migration entirely.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: all five new tests pass; previously-existing tests pass after migration.

- [ ] **Step 5: Commit**

```bash
git add src/csr.zig src/cpu.zig
git commit -m "feat(csr): live SEIP from PLIC into mip/sip reads; check_interrupt picks it up"
```

---

### Task 10: Create `devices/block.zig` — register storage + identity readback

**Files:**
- Create: `src/devices/block.zig`
- Modify: `src/main.zig` (the comptime test-import block)

**Why now:** Same structuring move as Task 1: scaffold the device with storage, exhaustive register coverage, and round-trip readback before the actual transfer logic in Tasks 11/12.

Block device MMIO map (offsets relative to `0x1000_1000`):
- `0x0` — `SECTOR` (u32, RW)
- `0x4` — `BUFFER` (u32, RW)
- `0x8` — `CMD`    (u32, W). Reads return 0.
- `0xC` — `STATUS` (u32, R). Default `3` (no media).

- [ ] **Step 1: Write failing tests for register round-trip**

Create `src/devices/block.zig`:

```zig
const std = @import("std");

pub const BLOCK_BASE: u32 = 0x1000_1000;
pub const BLOCK_SIZE: u32 = 0x10;

pub const SECTOR_BYTES: u32 = 4096;
pub const NSECTORS: u32 = 1024; // 4 MB total disk

pub const BlockError = error{UnexpectedRegister};

pub const Status = enum(u32) {
    Ready    = 0,
    Busy     = 1,    // never produced in Phase 3.A
    Error    = 2,
    NoMedia  = 3,
};

pub const Cmd = enum(u32) {
    None  = 0,
    Read  = 1,
    Write = 2,
};

pub const Block = struct {
    sector: u32 = 0,
    buffer_pa: u32 = 0,
    status: u32 = @intFromEnum(Status.NoMedia),
    /// Raised by writeByte(CMD) when a transfer completes (or fails).
    /// Polled by cpu.step at the top of each cycle to assert PLIC src 1.
    pending_irq: bool = false,
    /// Optional host-file backing. When null, every CMD sets STATUS=NoMedia.
    disk_file: ?std.fs.File = null,

    pub fn init() Block {
        return .{};
    }

    pub fn readByte(self: *const Block, offset: u32) BlockError!u8 {
        return switch (offset) {
            0x0...0x3 => @truncate(self.sector >> @as(u5, @intCast((offset - 0x0) * 8))),
            0x4...0x7 => @truncate(self.buffer_pa >> @as(u5, @intCast((offset - 0x4) * 8))),
            0x8...0xB => 0,             // CMD reads as 0
            0xC...0xF => @truncate(self.status >> @as(u5, @intCast((offset - 0xC) * 8))),
            else => BlockError.UnexpectedRegister,
        };
    }

    pub fn writeByte(self: *Block, offset: u32, value: u8) BlockError!void {
        switch (offset) {
            0x0...0x3 => {
                const shift: u5 = @intCast((offset - 0x0) * 8);
                self.sector = (self.sector & ~(@as(u32, 0xFF) << shift)) | (@as(u32, value) << shift);
            },
            0x4...0x7 => {
                const shift: u5 = @intCast((offset - 0x4) * 8);
                self.buffer_pa = (self.buffer_pa & ~(@as(u32, 0xFF) << shift)) | (@as(u32, value) << shift);
            },
            0x8...0xB => {
                // CMD: in Task 10 we accept and drop. Tasks 11/12 will react.
            },
            0xC...0xF => {
                // STATUS: writes ignored.
            },
            else => return BlockError.UnexpectedRegister,
        }
    }
};

test "default status is NoMedia (no --disk)" {
    const b = Block.init();
    try std.testing.expectEqual(@as(u8, 3), try b.readByte(0xC));
}

test "SECTOR byte round-trip" {
    var b = Block.init();
    try b.writeByte(0x0, 0x12);
    try b.writeByte(0x1, 0x34);
    try b.writeByte(0x2, 0x56);
    try b.writeByte(0x3, 0x78);
    try std.testing.expectEqual(@as(u32, 0x78563412), b.sector);
    try std.testing.expectEqual(@as(u8, 0x12), try b.readByte(0x0));
    try std.testing.expectEqual(@as(u8, 0x78), try b.readByte(0x3));
}

test "BUFFER byte round-trip" {
    var b = Block.init();
    try b.writeByte(0x4, 0xAA);
    try b.writeByte(0x5, 0xBB);
    try b.writeByte(0x6, 0xCC);
    try b.writeByte(0x7, 0xDD);
    try std.testing.expectEqual(@as(u32, 0xDDCCBBAA), b.buffer_pa);
}

test "CMD read returns 0 (write-only)" {
    var b = Block.init();
    try b.writeByte(0x8, 0x01);
    try std.testing.expectEqual(@as(u8, 0), try b.readByte(0x8));
}

test "out-of-range offset returns UnexpectedRegister" {
    var b = Block.init();
    try std.testing.expectError(BlockError.UnexpectedRegister, b.readByte(0x10));
    try std.testing.expectError(BlockError.UnexpectedRegister, b.writeByte(0x10, 0));
}
```

Add the import to `main.zig`'s comptime block:

```zig
comptime {
    _ = @import("cpu.zig");
    _ = @import("memory.zig");
    _ = @import("devices/halt.zig");
    _ = @import("devices/uart.zig");
    _ = @import("devices/clint.zig");
    _ = @import("devices/plic.zig");
    _ = @import("devices/block.zig"); // <-- NEW
    _ = @import("decoder.zig");
    _ = @import("execute.zig");
    _ = @import("csr.zig");
    _ = @import("trap.zig");
    _ = @import("elf.zig");
    _ = @import("trace.zig");
}
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `zig build test`
Expected: all five new tests pass.

- [ ] **Step 3: (No implementation beyond Step 1 — the file is the implementation.)**

- [ ] **Step 4: Commit**

```bash
git add src/devices/block.zig src/main.zig
git commit -m "feat(block): scaffold devices/block.zig with register storage"
```

---

### Task 11: Block device — `--disk`-backed transfer (read + write) via `performTransfer`

**Files:**
- Modify: `src/devices/block.zig`

**Why now:** Wire CMD writes to actual host-file I/O. We expose `performTransfer(self, ram: []u8) void` separately from `writeByte(CMD)` so the `memory.zig` dispatcher can pass in the RAM slice — the device doesn't hold a back-pointer to memory. `writeByte(CMD)` records a "pending command" boolean; the dispatcher (called from `storeBytePhysical` after the byte write) calls `performTransfer` if the boolean is set.

This decouples device tests (no Memory needed) from integration tests.

- [ ] **Step 1: Write failing tests for `performTransfer`**

Append to `src/devices/block.zig`:

```zig
test "performTransfer with no disk: status NoMedia, pending_irq set" {
    var b = Block.init();
    var ram_buf: [4096]u8 = [_]u8{0xAA} ** 4096;
    try b.writeByte(0x8, 1); // CMD = Read
    b.performTransfer(ram_buf[0..]);
    try std.testing.expectEqual(@intFromEnum(Status.NoMedia), b.status);
    try std.testing.expect(b.pending_irq);
    // RAM untouched.
    try std.testing.expectEqual(@as(u8, 0xAA), ram_buf[0]);
}

test "performTransfer Read with disk copies sector into RAM at buffer_pa offset" {
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "/tmp/ccc_block_test_{d}.img", .{std.time.milliTimestamp()});
    var f = try std.fs.createFileAbsolute(tmp_path, .{ .read = true, .truncate = true });
    defer f.close();
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};
    // Write 4 KB of magic into sector 0.
    var sector_data: [SECTOR_BYTES]u8 = undefined;
    for (sector_data[0..], 0..) |*p, i| p.* = @truncate(i & 0xFF);
    try f.writeAll(sector_data[0..]);

    var b = Block.init();
    b.disk_file = f;
    // 4 KB RAM "slice" anchored at PA 0x80000000. We only use the first 4 KB,
    // but performTransfer expects the slice's index 0 to correspond to PA
    // 0x80000000 — so b.buffer_pa = 0x80000000 means "copy to ram[0..4096]".
    var ram_buf: [SECTOR_BYTES]u8 = [_]u8{0} ** SECTOR_BYTES;

    b.sector = 0;
    b.buffer_pa = 0x80000000;
    try b.writeByte(0x8, 1);
    b.performTransfer(ram_buf[0..]);

    try std.testing.expectEqual(@intFromEnum(Status.Ready), b.status);
    try std.testing.expect(b.pending_irq);
    try std.testing.expectEqualSlices(u8, sector_data[0..], ram_buf[0..]);
}

test "performTransfer Write with disk copies RAM out to disk file" {
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "/tmp/ccc_block_write_{d}.img", .{std.time.milliTimestamp()});
    var f = try std.fs.createFileAbsolute(tmp_path, .{ .read = true, .truncate = true });
    defer f.close();
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};
    try f.setEndPos(SECTOR_BYTES);

    var b = Block.init();
    b.disk_file = f;
    var ram_buf: [SECTOR_BYTES]u8 = undefined;
    for (ram_buf[0..], 0..) |*p, i| p.* = @truncate((i + 7) & 0xFF);

    b.sector = 0;
    b.buffer_pa = 0x80000000;
    try b.writeByte(0x8, 2); // Write
    b.performTransfer(ram_buf[0..]);

    try std.testing.expectEqual(@intFromEnum(Status.Ready), b.status);
    try std.testing.expect(b.pending_irq);
    try f.seekTo(0);
    var verify: [SECTOR_BYTES]u8 = undefined;
    _ = try f.readAll(verify[0..]);
    try std.testing.expectEqualSlices(u8, ram_buf[0..], verify[0..]);
}

test "performTransfer with bad CMD sets Error status" {
    var b = Block.init();
    var ram_buf: [SECTOR_BYTES]u8 = undefined;
    b.buffer_pa = 0x80000000;
    try b.writeByte(0x8, 99); // bogus
    b.performTransfer(ram_buf[0..]);
    try std.testing.expectEqual(@intFromEnum(Status.Error), b.status);
    try std.testing.expect(b.pending_irq);
}

test "performTransfer with sector out of range sets Error status" {
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "/tmp/ccc_block_oor_{d}.img", .{std.time.milliTimestamp()});
    var f = try std.fs.createFileAbsolute(tmp_path, .{ .read = true, .truncate = true });
    defer f.close();
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};
    try f.setEndPos(SECTOR_BYTES);

    var b = Block.init();
    b.disk_file = f;
    b.sector = NSECTORS;             // 1024 — out of range
    b.buffer_pa = 0x80000000;
    var ram_buf: [SECTOR_BYTES]u8 = undefined;
    try b.writeByte(0x8, 1); // Read
    b.performTransfer(ram_buf[0..]);
    try std.testing.expectEqual(@intFromEnum(Status.Error), b.status);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: compile error: `Block` has no member `performTransfer`. Tests can't run.

- [ ] **Step 3: Implement `performTransfer` and the pending-cmd machinery**

Add a `pending_cmd` field and the new method:

```zig
pub const Block = struct {
    sector: u32 = 0,
    buffer_pa: u32 = 0,
    status: u32 = @intFromEnum(Status.NoMedia),
    pending_irq: bool = false,
    /// Latest CMD value written; performTransfer consumes it.
    pending_cmd: u32 = 0,
    disk_file: ?std.fs.File = null,

    // ... unchanged init, readByte ...

    pub fn writeByte(self: *Block, offset: u32, value: u8) BlockError!void {
        switch (offset) {
            0x0...0x3 => {
                const shift: u5 = @intCast((offset - 0x0) * 8);
                self.sector = (self.sector & ~(@as(u32, 0xFF) << shift)) | (@as(u32, value) << shift);
            },
            0x4...0x7 => {
                const shift: u5 = @intCast((offset - 0x4) * 8);
                self.buffer_pa = (self.buffer_pa & ~(@as(u32, 0xFF) << shift)) | (@as(u32, value) << shift);
            },
            0x8...0xB => {
                const shift: u5 = @intCast((offset - 0x8) * 8);
                self.pending_cmd = (self.pending_cmd & ~(@as(u32, 0xFF) << shift)) | (@as(u32, value) << shift);
            },
            0xC...0xF => {},
            else => return BlockError.UnexpectedRegister,
        }
    }

    /// Run the latest CMD against the disk file, copying to/from `ram`
    /// at offset `buffer_pa - 0x80000000` (caller is responsible for the
    /// translation; if the offset is out of range, set Error). After the
    /// transfer (success OR failure), set `pending_irq = true`.
    ///
    /// `ram` is the RAM slice corresponding to physical address space starting
    /// at 0x80000000. The CPU step loop calls this with `&memory.ram` after
    /// observing CMD-write side effects.
    pub fn performTransfer(self: *Block, ram: []u8) void {
        defer self.pending_irq = true;
        defer self.pending_cmd = 0;

        // Reset CMD: nothing to do.
        if (self.pending_cmd == 0) {
            // No actual transfer was requested — but pending_irq is still
            // raised so the driver observes an edge for any latched CMD=0
            // reset. Status becomes Ready so a polling driver can drain.
            self.status = @intFromEnum(Status.Ready);
            return;
        }

        // No disk → NoMedia for any non-zero CMD.
        const f = self.disk_file orelse {
            self.status = @intFromEnum(Status.NoMedia);
            return;
        };

        // Bad CMD?
        if (self.pending_cmd != 1 and self.pending_cmd != 2) {
            self.status = @intFromEnum(Status.Error);
            return;
        }

        // Sector range.
        if (self.sector >= NSECTORS) {
            self.status = @intFromEnum(Status.Error);
            return;
        }

        // RAM range. buffer_pa is a physical address; we expect 0x8000_0000-based.
        // Compute offset; bounds-check; set Error if out of range.
        const RAM_BASE: u32 = 0x8000_0000;
        if (self.buffer_pa < RAM_BASE) {
            self.status = @intFromEnum(Status.Error);
            return;
        }
        const ram_off: usize = @intCast(self.buffer_pa - RAM_BASE);
        if (ram_off + SECTOR_BYTES > ram.len) {
            self.status = @intFromEnum(Status.Error);
            return;
        }
        const slice = ram[ram_off .. ram_off + SECTOR_BYTES];

        // Seek to byte offset = sector * 4 KB.
        const byte_off: u64 = @as(u64, self.sector) * SECTOR_BYTES;
        f.seekTo(byte_off) catch {
            self.status = @intFromEnum(Status.Error);
            return;
        };

        if (self.pending_cmd == 1) {
            const n = f.readAll(slice) catch {
                self.status = @intFromEnum(Status.Error);
                return;
            };
            if (n != SECTOR_BYTES) {
                self.status = @intFromEnum(Status.Error);
                return;
            }
        } else {
            // pending_cmd == 2 — write
            f.writeAll(slice) catch {
                self.status = @intFromEnum(Status.Error);
                return;
            };
        }

        self.status = @intFromEnum(Status.Ready);
    }
};
```

The tests in Step 1 already use `b.buffer_pa = 0x80000000` with a 4 KB `ram_buf`. `performTransfer` interprets the slice's index 0 as PA `0x80000000`, so this maps the buffer at the RAM base. Production callers (memory.zig in Task 12) will pass `self.ram` (the full RAM slice) and any `buffer_pa` in `[0x80000000, 0x80000000 + ram.len)` resolves correctly via the `ram_off = buffer_pa - RAM_BASE` arithmetic.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: all five new tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/devices/block.zig
git commit -m "feat(block): performTransfer reads/writes 4 KB sectors against host disk file"
```

---

### Task 12: Block device — defer IRQ #1 to the next instruction boundary

**Files:**
- Modify: `src/devices/block.zig` (just docs — `pending_irq` is already there)
- Modify: `src/cpu.zig` (servicePendingBlockIrq at top of step)
- Modify: `src/memory.zig` (storeBytePhysical CMD-byte hook)

**Why now:** With `performTransfer` in place, we still need to (a) actually call `performTransfer` when the kernel writes a CMD byte, and (b) raise PLIC IRQ #1 at the *next* CPU instruction boundary. The CPU is the natural place to do (b): a top-of-step service call that drains `pending_irq`.

For (a): when `memory.storeBytePhysical` writes to the CMD byte (offset `0x8`), it calls `block.performTransfer(self.ram)`. We deliberately do this in memory.zig so the device doesn't hold a back-pointer to memory.

For (b): cpu.step gets a one-line preamble that, if `block.pending_irq`, calls `plic.assertSource(1)` and clears the flag.

- [ ] **Step 1: Write failing tests for the defer-and-assert flow**

Append to `src/cpu.zig` tests:

```zig
test "step asserts PLIC IRQ #1 when block has pending_irq set, then clears the flag" {
    var rig = try cpuRig();
    defer rig.deinit();

    // Manually set pending_irq as if performTransfer just ran.
    rig.cpu.memory.block.pending_irq = true;
    // Place a NOP at PC so step proceeds normally after IRQ delivery.
    try rig.mem.storeWordPhysical(rig.cpu.pc, 0x00000013); // addi x0,x0,0 (nop)

    _ = rig.cpu.step() catch {};
    try std.testing.expect((rig.cpu.memory.plic.pending & (1 << 1)) != 0);
    try std.testing.expect(!rig.cpu.memory.block.pending_irq);
}
```

Append to `src/memory.zig` tests:

```zig
test "storeBytePhysical to CMD byte triggers performTransfer (no media path)" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();

    // Set CMD = 1 (read) byte 0; should trigger performTransfer once.
    try rig.mem.storeBytePhysical(0x1000_1008, 1);
    // Without --disk, status becomes NoMedia and pending_irq is set.
    try std.testing.expectEqual(@as(u8, 3), try rig.mem.loadBytePhysical(0x1000_100C));
    try std.testing.expect(rig.mem.block.pending_irq);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: compile error: `cpu.memory.block` doesn't exist. (Until we add the `block: *Block` field — Step 3.)

- [ ] **Step 3: Add `block: *Block` to Memory; trigger performTransfer on CMD-byte write; service block IRQ at top of cpu.step**

In `src/memory.zig`:

```zig
const block_dev = @import("devices/block.zig");

pub const Memory = struct {
    ram: []u8,
    halt: *halt_dev.Halt,
    uart: *uart_dev.Uart,
    clint: *clint_dev.Clint,
    plic: *plic_dev.Plic,
    block: *block_dev.Block,                  // NEW
    tohost_addr: ?u32,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        halt: *halt_dev.Halt,
        uart: *uart_dev.Uart,
        clint: *clint_dev.Clint,
        plic: *plic_dev.Plic,
        block: *block_dev.Block,              // NEW
        tohost_addr: ?u32,
        ram_size: usize,
    ) !Memory { ... }
};
```

In `loadBytePhysical` and `storeBytePhysical`, add the block range. Note the special CMD trigger:

```zig
pub fn loadBytePhysical(self: *Memory, addr: u32) MemoryError!u8 {
    // ... uart, halt, clint, plic arms ...
    if (inRange(addr, block_dev.BLOCK_BASE, block_dev.BLOCK_SIZE)) {
        return self.block.readByte(addr - block_dev.BLOCK_BASE) catch |e| switch (e) {
            error.UnexpectedRegister => MemoryError.UnexpectedRegister,
        };
    }
    const off = try self.ramOffset(addr);
    return self.ram[off];
}

pub fn storeBytePhysical(self: *Memory, addr: u32, value: u8) MemoryError!void {
    // ... uart, halt, clint, plic arms ...
    if (inRange(addr, block_dev.BLOCK_BASE, block_dev.BLOCK_SIZE)) {
        const off = addr - block_dev.BLOCK_BASE;
        self.block.writeByte(off, value) catch |e| switch (e) {
            error.UnexpectedRegister => return MemoryError.UnexpectedRegister,
        };
        // CMD register lives at offsets 0x8..0xB. The kernel writes the CMD
        // word as four byte-stores (or a single sw — which devolves into the
        // RAM fast path's MMIO bypass that calls storeBytePhysical four
        // times). Trigger the transfer once per CMD byte 3 (high byte) write,
        // by which time all four bytes of pending_cmd are set. This matches
        // what real hardware does on a 4-byte burst write completion.
        if (off == 0xB) {
            self.block.performTransfer(self.ram);
        }
        return;
    }
    if (self.inTohost(addr)) { /* ... unchanged ... */ }
    const off = try self.ramOffset(addr);
    self.ram[off] = value;
}
```

In `src/cpu.zig`'s `step` (right after the `check_interrupt` call, before the fetch):

```zig
pub fn step(self: *Cpu) StepError!void {
    // Service deferred device IRQs from the previous instruction's MMIO writes.
    if (self.memory.block.pending_irq) {
        self.memory.plic.assertSource(1);
        self.memory.block.pending_irq = false;
    }

    if (check_interrupt(self)) return;

    // ... rest of step unchanged ...
}
```

Update `TestRig` and `cpuRig` to construct a `Block` and pass `&block` to `Memory.init`. Migrate every other call site of `Memory.init` (search for `Memory.init(`). The compiler will surface them.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: both new tests pass; all existing tests pass after migration.

- [ ] **Step 5: Commit**

```bash
git add src/cpu.zig src/memory.zig src/devices/block.zig
git commit -m "feat(block): deferred IRQ #1 asserted on next step; performTransfer triggered on CMD-byte 3"
```

---

### Task 13: UART RX FIFO + RBR pop + LSR.DR + PLIC IRQ #10

**Files:**
- Modify: `src/devices/uart.zig`

**Why now:** UART RX is the simplest of the new devices. With PLIC and Block already wired into `Memory`, we extend UART with a 256-byte ring buffer and tie its level-IRQ to PLIC source 10. This task does both the FIFO and the IRQ wiring in one go — the IRQ is two lines and the FIFO without IRQ has no consumer.

The UART's `pushRx` and the PLIC interaction are tested without going through `Memory` — we set `uart.plic = &plic` directly.

- [ ] **Step 1: Write failing tests for FIFO and IRQ behavior**

Append to `src/devices/uart.zig`:

```zig
test "pushRx empty -> non-empty raises PLIC src 10" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var plic = @import("plic.zig").Plic.init();
    var uart = Uart.init(&aw.writer);
    uart.plic = &plic;
    _ = uart.pushRx(0x41);
    try std.testing.expect((plic.pending & (1 << 10)) != 0);
}

test "pushRx then RBR read returns the byte" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var plic = @import("plic.zig").Plic.init();
    var uart = Uart.init(&aw.writer);
    uart.plic = &plic;
    _ = uart.pushRx(0x41);
    try std.testing.expectEqual(@as(u8, 0x41), try uart.readByte(0x00));
}

test "draining FIFO via RBR clears PLIC src 10" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var plic = @import("plic.zig").Plic.init();
    var uart = Uart.init(&aw.writer);
    uart.plic = &plic;
    _ = uart.pushRx(0x41);
    _ = try uart.readByte(0x00);
    try std.testing.expectEqual(@as(u32, 0), plic.pending & (1 << 10));
}

test "LSR.DR (bit 0) reflects FIFO non-empty" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var plic = @import("plic.zig").Plic.init();
    var uart = Uart.init(&aw.writer);
    uart.plic = &plic;
    var lsr = try uart.readByte(0x05);
    try std.testing.expectEqual(@as(u8, 0), lsr & 0x01);
    _ = uart.pushRx(0x41);
    lsr = try uart.readByte(0x05);
    try std.testing.expectEqual(@as(u8, 0x01), lsr & 0x01);
    _ = try uart.readByte(0x00);
    lsr = try uart.readByte(0x05);
    try std.testing.expectEqual(@as(u8, 0), lsr & 0x01);
}

test "FIFO drops bytes when full (256 capacity)" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var plic = @import("plic.zig").Plic.init();
    var uart = Uart.init(&aw.writer);
    uart.plic = &plic;
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        try std.testing.expect(uart.pushRx(@truncate(i & 0xFF)));
    }
    try std.testing.expect(!uart.pushRx(0xFF)); // full → false
}

test "FIFO is FIFO (first in, first out)" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var plic = @import("plic.zig").Plic.init();
    var uart = Uart.init(&aw.writer);
    uart.plic = &plic;
    _ = uart.pushRx(0x10);
    _ = uart.pushRx(0x20);
    _ = uart.pushRx(0x30);
    try std.testing.expectEqual(@as(u8, 0x10), try uart.readByte(0x00));
    try std.testing.expectEqual(@as(u8, 0x20), try uart.readByte(0x00));
    try std.testing.expectEqual(@as(u8, 0x30), try uart.readByte(0x00));
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: compile errors. `Uart` has no `plic` field, no `pushRx`. RBR read returns 0 (Phase 1 stub).

- [ ] **Step 3: Extend Uart with the RX path**

Modify `Uart` to add the new fields and methods:

```zig
const plic_dev = @import("plic.zig");

const RX_CAPACITY: usize = 256;

pub const Uart = struct {
    writer: *std.Io.Writer,
    ier: u8 = 0,
    lcr: u8 = 0,
    mcr: u8 = 0,
    sr: u8 = 0,
    rx_buf: [RX_CAPACITY]u8 = [_]u8{0} ** RX_CAPACITY,
    rx_head: u16 = 0,
    rx_tail: u16 = 0,
    rx_count: u16 = 0,
    /// Set by main.zig after construction. Tests set it directly.
    plic: ?*plic_dev.Plic = null,

    pub fn init(writer: *std.Io.Writer) Uart {
        return .{ .writer = writer };
    }

    pub fn pushRx(self: *Uart, b: u8) bool {
        if (self.rx_count >= RX_CAPACITY) return false;
        const was_empty = self.rx_count == 0;
        self.rx_buf[self.rx_tail] = b;
        self.rx_tail = (self.rx_tail + 1) % RX_CAPACITY;
        self.rx_count += 1;
        if (was_empty) {
            if (self.plic) |p| p.assertSource(10);
        }
        return true;
    }

    pub fn rxLen(self: *const Uart) u16 {
        return self.rx_count;
    }

    fn popRx(self: *Uart) u8 {
        if (self.rx_count == 0) return 0;
        const b = self.rx_buf[self.rx_head];
        self.rx_head = (self.rx_head + 1) % RX_CAPACITY;
        self.rx_count -= 1;
        if (self.rx_count == 0) {
            if (self.plic) |p| p.deassertSource(10);
        }
        return b;
    }

    pub fn readByte(self: *Uart, offset: u32) UartError!u8 {
        return switch (offset) {
            REG_RBR => self.popRx(),
            REG_IER => self.ier,
            REG_FCR => 0,
            REG_LCR => self.lcr,
            REG_MCR => self.mcr,
            REG_LSR => blk: {
                var v: u8 = LSR_THRE | LSR_TEMT;
                if (self.rx_count > 0) v |= 0x01; // DR (Data Ready) bit
                break :blk v;
            },
            REG_MSR => 0,
            REG_SR => self.sr,
            else => UartError.UnexpectedRegister,
        };
    }

    // writeByte unchanged.
};
```

Note `readByte` is now `*Uart` (mutable, because RBR reads pop). The existing `*const Uart` readers will need to change. Search for `readByte(_:` callers and confirm.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: all six new tests pass. The Phase 1 test "RBR (read of THR offset) returns 0 (input stubbed)" still passes because an empty FIFO returns 0.

- [ ] **Step 5: Commit**

```bash
git add src/devices/uart.zig
git commit -m "feat(uart): RX FIFO (256B) + LSR.DR + PLIC source 10 level IRQ"
```

---

### Task 14: WFI — real idle loop until next interrupt-edge

**Files:**
- Modify: `src/execute.zig` (the `.wfi` arm)
- Modify: `src/cpu.zig` (add `idleSpin` helper)

**Why now:** Phase 2 had a no-op WFI because it had no async sources whose timing the host couldn't fast-forward. Phase 3 introduces UART RX (host-stdin pump) and the block-device IRQ that needs an instruction-boundary firing. WFI now blocks the step loop on a `poll`-driven spin until the host gives us a new edge or the bound elapses.

The bound: 10 seconds of wall-clock time without any activity → return so the wedged program can be killed by the user. The integration test never hits this.

- [ ] **Step 1: Write a failing test that WFI returns when an interrupt becomes deliverable**

The test sets up the full delegation/enable chain so that PLIC src 1 → `mip.SEIP` → S-trap is deliverable as soon as the block IRQ fires inside `idleSpin`. Without that chain, `idleSpin` would loop for the full 10s timeout — too slow for unit tests.

Append to `src/cpu.zig` tests:

```zig
test "WFI returns promptly when a deliverable interrupt arrives during idle" {
    var rig = try cpuRig();
    defer rig.deinit();

    // Configure delegation + enable so SEIP delivers to S.
    rig.cpu.privilege = .U;                              // U < S → trap deliverable regardless of sstatus.SIE
    rig.cpu.csr.stvec = 0x8000_0500;
    rig.cpu.csr.mideleg = 1 << 9;                        // delegate SEIP to S
    rig.cpu.csr.mie = 1 << 9;                            // SEIE
    // PLIC: src 1 priority 1, enabled, threshold 0.
    try rig.cpu.memory.plic.writeByte(0x0004, 1);
    try rig.cpu.memory.plic.writeByte(0x2080, 0x02);

    // Pre-arm block IRQ so the first idleSpin iteration asserts PLIC src 1
    // and check_interrupt fires immediately.
    rig.cpu.memory.block.pending_irq = true;

    // Place WFI at PC. (U-mode wfi traps illegal in our model, but here we'll
    // test idleSpin directly to keep the unit-level concern pure.)
    rig.cpu.idleSpin();

    // After idleSpin returns: PLIC src 1 was asserted, the trap was taken,
    // privilege flipped to S, PC redirected to stvec.
    try std.testing.expect((rig.cpu.memory.plic.pending & (1 << 1)) == 0); // claimed? no — assertion only
    // Actually pending bit stays set until claim; what we test is: trap was taken.
    try std.testing.expectEqual(@import("cpu.zig").PrivilegeMode.S, rig.cpu.privilege);
    try std.testing.expectEqual(@as(u32, 0x8000_0500), rig.cpu.pc);
    try std.testing.expectEqual(@as(u32, (1 << 31) | 9), rig.cpu.csr.scause);
    try std.testing.expect(!rig.cpu.memory.block.pending_irq); // serviced
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test`
Expected: compile error: `Cpu` has no member `idleSpin`. (Or, if the type compiles via stub, the test fails because privilege never flips.)

- [ ] **Step 3: Add `idleSpin` to cpu.zig and rewrite the wfi arm**

In `src/cpu.zig`:

```zig
/// Idle the CPU until a deliverable interrupt arrives or 10s wall-clock
/// elapses. Called by execute.zig's wfi arm.
///
/// Each iteration: service deferred device IRQs (block); poll host stdin
/// (if a UART pump is wired); check for deliverable interrupts. If a trap
/// fires, return early — the caller's step() will detect cpu.trap_taken
/// and skip the +4 PC advance. If nothing happens, sleep ~1 ms and loop.
pub fn idleSpin(self: *Cpu) void {
    const max_ns: i128 = 10_000_000_000; // 10 s
    const start = std.time.nanoTimestamp();
    while (true) {
        // Service deferred block IRQ.
        if (self.memory.block.pending_irq) {
            self.memory.plic.assertSource(1);
            self.memory.block.pending_irq = false;
        }
        // Drain host stdin if a pump is configured (Task 18 wires this).
        if (self.memory.uart.rx_pump) |pump| {
            pump.drainAvailable(self.memory.uart);
        }
        // Did we just get something interrupt-worthy?
        if (check_interrupt(self)) return;

        if (std.time.nanoTimestamp() - start > max_ns) return;
        // 1 ms sleep — short enough to keep tests fast, long enough to
        // not chew CPU when truly idle.
        std.Thread.sleep(1_000_000);
    }
}
```

Add an `rx_pump: ?*RxPump = null` field to UART, where `RxPump` is the type Task 16 fully fleshes out. For Task 14, declare a stub with the right shape so `idleSpin`'s `pump.drainAvailable(self.memory.uart)` call type-checks. Append to `src/devices/uart.zig`:
```zig
pub const RxPump = struct {
    file: std.fs.File,
    eof: bool = false,

    pub fn drainAvailable(self: *RxPump, uart: *Uart) void {
        // Stub: Task 16 replaces this body with the real non-blocking read.
        _ = self;
        _ = uart;
    }
};
```
Task 16 swaps the body for the real drainer; the field stays `null` until `main.zig` wires a real pump in Task 16.

In `src/execute.zig`'s `.wfi` arm:

```zig
.wfi => {
    if (cpu.privilege == .U) {
        trap.enter(.illegal_instruction, instr.raw, cpu);
        return;
    }
    // Real idle: spin on host events until an interrupt fires or 10s elapses.
    cpu.idleSpin();
    // PC advance: if idleSpin returned because a trap fired, the trap entry
    // already redirected PC to stvec/mtvec; the +4 below is benign because
    // cpu.trap_taken is set and the next step's check_interrupt won't run.
    // If idleSpin returned because of timeout (no event), advance past wfi
    // so we make forward progress.
    if (!cpu.trap_taken) {
        cpu.pc +%= 4;
    }
},
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test`
Expected: the new test passes within milliseconds (the idle-spin's first iteration services the block IRQ).

- [ ] **Step 5: Commit**

```bash
git add src/cpu.zig src/execute.zig src/devices/uart.zig
git commit -m "feat(cpu): wfi idles until interrupt-edge; idleSpin services block IRQ + UART pump"
```

---

### Task 15: `main.zig` — `--disk PATH` and `--disk-latency CYCLES` flags

**Files:**
- Modify: `src/main.zig`

**Why now:** With Block holding a `?std.fs.File`, we now need a CLI path to populate it. `--disk PATH` opens an existing file (no create-on-missing) read-write; `--disk-latency CYCLES` parses-and-stores but is a no-op in Phase 3.A.

- [ ] **Step 1: Write a failing test that the parsed args carry `disk_path` and `disk_latency`**

Append to `src/main.zig` tests:

```zig
test "parseArgs accepts --disk PATH" {
    var stderr_buf: [256]u8 = undefined;
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    _ = stderr_buf;

    const argv = &[_][:0]const u8{ "ccc", "--disk", "/tmp/foo.img", "kernel.elf" };
    const args = try parseArgs(argv[0..], &aw.writer);
    try std.testing.expectEqualStrings("/tmp/foo.img", args.disk_path.?);
    try std.testing.expectEqualStrings("kernel.elf", args.file.?);
}

test "parseArgs accepts --disk-latency NUM" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const argv = &[_][:0]const u8{ "ccc", "--disk-latency", "1000", "kernel.elf" };
    const args = try parseArgs(argv[0..], &aw.writer);
    try std.testing.expectEqual(@as(u32, 1000), args.disk_latency);
}

test "parseArgs default disk_path is null" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const argv = &[_][:0]const u8{ "ccc", "kernel.elf" };
    const args = try parseArgs(argv[0..], &aw.writer);
    try std.testing.expect(args.disk_path == null);
}
```

- [ ] **Step 2: Run the tests to verify they fail (compile error: `Args` has no `disk_path` / `disk_latency`)**

Run: `zig build test`
Expected: compile error.

- [ ] **Step 3: Extend `Args` and `parseArgs`; open the disk file in `main`; pass to Block**

In `src/main.zig`:

```zig
const Args = struct {
    raw_addr: ?u32 = null,
    file: ?[]const u8 = null,
    trace: bool = false,
    halt_on_trap: bool = false,
    memory_mb: u32 = 128,
    disk_path: ?[]const u8 = null,
    disk_latency: u32 = 0,
};

fn parseArgs(argv: []const [:0]const u8, stderr: *Io.Writer) ArgsError!Args {
    var args: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--raw")) { /* unchanged */ }
        else if (std.mem.eql(u8, a, "--trace")) { args.trace = true; }
        else if (std.mem.eql(u8, a, "--halt-on-trap")) { args.halt_on_trap = true; }
        else if (std.mem.eql(u8, a, "--memory")) { /* unchanged */ }
        else if (std.mem.eql(u8, a, "--disk")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            args.disk_path = argv[i];
        }
        else if (std.mem.eql(u8, a, "--disk-latency")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            args.disk_latency = std.fmt.parseInt(u32, argv[i], 0) catch return error.InvalidAddress;
        }
        else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) { /* unchanged */ }
        else if (a.len > 0 and a[0] == '-') { /* unchanged */ }
        else {
            if (args.file != null) return error.TooManyPositional;
            args.file = a;
        }
    }
    if (args.file == null) return error.MissingFile;
    return args;
}
```

In `printUsage`, add the new flags:

```zig
\\  --disk <path>       Back the block device with this file (4 MB image).
\\  --disk-latency <n>  Reserved (no-op in Phase 3.A).
\\  --input <path>      Stream this file's bytes into UART RX (Task 16).
```

In `main`, after constructing `clint`, construct PLIC and Block; open the disk if provided:

```zig
var plic = @import("devices/plic.zig").Plic.init();
var block = @import("devices/block.zig").Block.init();

if (args.disk_path) |path| {
    const f = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| {
        stderr.print("failed to open disk image {s}: {s}\n", .{ path, @errorName(err) }) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };
    block.disk_file = f;
    block.status = @intFromEnum(@import("devices/block.zig").Status.Ready);
}
defer if (block.disk_file) |f| f.close();

// ... unchanged Memory.init plumbing — but now also pass &plic and &block.
var mem = try mem_mod.Memory.init(a, &halt, &uart, &clint, &plic, &block, null, ram_size);
```

Wire UART's PLIC pointer:

```zig
uart.plic = &plic;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: all three new tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/main.zig
git commit -m "feat(cli): --disk PATH and --disk-latency CYCLES flags"
```

---

### Task 16: `main.zig` — `--input PATH` flag + UART RX pump

**Files:**
- Modify: `src/main.zig`
- Modify: `src/devices/uart.zig` (add `RxPump` type if not done in Task 14)

**Why now:** Scripted e2e tests need deterministic input. `--input PATH` streams the file's bytes into the UART RX FIFO during the idle path. Without `--input`, the emulator doesn't drain stdin in 3.A — that's deferred to a real-stdin pump in Phase 3.E (when shell input matters). 3.A's integration test uses `--input /dev/null` and never reads from UART.

- [ ] **Step 1: Write a failing test that --input wires up an RxPump**

Append to `src/main.zig` tests:

```zig
test "parseArgs accepts --input PATH" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const argv = &[_][:0]const u8{ "ccc", "--input", "/dev/null", "kernel.elf" };
    const args = try parseArgs(argv[0..], &aw.writer);
    try std.testing.expectEqualStrings("/dev/null", args.input_path.?);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test`
Expected: compile error: `Args` has no `input_path`.

- [ ] **Step 3: Replace the stub `drainAvailable` body with a real non-blocking drainer; add the `--input` arm to `parseArgs`; wire the pump in `main`**

In `src/devices/uart.zig`, find the stub `drainAvailable` body added in Task 14 and replace it with the real implementation:

```zig
pub fn drainAvailable(self: *RxPump, uart: *Uart) void {
    if (self.eof) return;
    var buf: [64]u8 = undefined;
    // Bound the read by FIFO free space so we never drop bytes.
    const free = @as(usize, RX_CAPACITY) - uart.rx_count;
    if (free == 0) return;
    const n = self.file.read(buf[0..@min(free, buf.len)]) catch 0;
    if (n == 0) {
        self.eof = true;
        return;
    }
    for (buf[0..n]) |b| _ = uart.pushRx(b);
}
```

In `src/main.zig`:

```zig
const Args = struct {
    raw_addr: ?u32 = null,
    file: ?[]const u8 = null,
    trace: bool = false,
    halt_on_trap: bool = false,
    memory_mb: u32 = 128,
    disk_path: ?[]const u8 = null,
    disk_latency: u32 = 0,
    input_path: ?[]const u8 = null,
};
```

Add the `--input` arm in `parseArgs`:

```zig
else if (std.mem.eql(u8, a, "--input")) {
    i += 1;
    if (i >= argv.len) return error.MissingArg;
    args.input_path = argv[i];
}
```

In `main`, after constructing UART:

```zig
var rx_pump_storage: @import("devices/uart.zig").RxPump = undefined;
if (args.input_path) |ipath| {
    const f = std.fs.cwd().openFile(ipath, .{ .mode = .read_only }) catch |err| {
        stderr.print("failed to open input file {s}: {s}\n", .{ ipath, @errorName(err) }) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };
    rx_pump_storage = .{ .file = f };
    uart.rx_pump = &rx_pump_storage;
}
defer if (uart.rx_pump) |p| p.file.close();
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: the new test passes.

- [ ] **Step 5: Commit**

```bash
git add src/main.zig src/devices/uart.zig
git commit -m "feat(cli): --input PATH streams a host file into UART RX FIFO"
```

---

### Task 17: Trace markers — PLIC source ID + block transfer

**Files:**
- Modify: `src/trace.zig` (formatInterruptMarker signature + new formatBlockTransfer)
- Modify: `src/trap.zig` (call formatInterruptMarker with the source-id when external)
- Modify: `src/devices/block.zig` (call formatBlockTransfer in performTransfer if cpu.trace_writer set — see below)
- Modify: `src/cpu.zig` (the block service path that runs on top of step gets a trace hook too)

**Why now:** Both kinds of marker sit in human-debug territory; landing them now keeps trace output sane through the integration test in Task 19.

- [ ] **Step 1: Write failing tests for the new trace formats**

Append to `src/trace.zig` tests:

```zig
test "formatInterruptMarker for S-external includes plic source id" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try formatInterruptMarker(&aw.writer, 9, .U, .S, 1);
    try std.testing.expectEqualStrings("--- interrupt 9 (supervisor external, src 1) taken in U, now S ---\n", aw.written());
}

test "formatInterruptMarker for non-external ignores src arg" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try formatInterruptMarker(&aw.writer, 1, .U, .S, null);
    try std.testing.expectEqualStrings("--- interrupt 1 (supervisor software) taken in U, now S ---\n", aw.written());
}

test "formatBlockTransfer prints op, sector, and PA" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try formatBlockTransfer(&aw.writer, .Read, 42, 0x80100000);
    try std.testing.expectEqualStrings("--- block: read sector 42 at PA 0x80100000 ---\n", aw.written());
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: compile errors. `formatInterruptMarker` doesn't take a 5th arg; `formatBlockTransfer` doesn't exist.

- [ ] **Step 3: Implement the new signatures and the new function**

In `src/trace.zig`:

```zig
const Op = enum { Read, Write };

pub fn formatInterruptMarker(
    w: *std.Io.Writer,
    cause_code: u32,
    from_priv: PrivilegeMode,
    to_priv: PrivilegeMode,
    plic_src: ?u32,
) !void {
    const name = interruptName(cause_code);
    const from = privName(from_priv);
    const to = privName(to_priv);
    if (cause_code == 9 and plic_src != null) {
        try w.print("--- interrupt {d} ({s}, src {d}) taken in {s}, now {s} ---\n",
                    .{ cause_code, name, plic_src.?, from, to });
    } else {
        try w.print("--- interrupt {d} ({s}) taken in {s}, now {s} ---\n",
                    .{ cause_code, name, from, to });
    }
}

pub fn formatBlockTransfer(
    w: *std.Io.Writer,
    op: Op,
    sector: u32,
    pa: u32,
) !void {
    const op_s = switch (op) { .Read => "read", .Write => "write" };
    try w.print("--- block: {s} sector {d} at PA 0x{X:0>8} ---\n", .{ op_s, sector, pa });
}
```

Update every existing call site of `formatInterruptMarker` (only one — `trap.enter_interrupt`) to pass `null` for the new arg:

```zig
trace.formatInterruptMarker(tw, cause_code, from_priv, target, null) catch {};
```

For the external case, we want to pass the source ID. Modify `trap.enter_interrupt`:

```zig
pub fn enter_interrupt(cause_code: u32, cpu: *Cpu) void {
    // ... unchanged delegation logic ...
    if (cpu.trace_writer) |tw| {
        const plic_src: ?u32 = if (cause_code == 9)
            cpu.memory.plic.peekHighestPendingForS()
        else
            null;
        trace.formatInterruptMarker(tw, cause_code, from_priv, target, plic_src) catch {};
    }
    // ... unchanged trap-entry switch ...
}
```

Add `peekHighestPendingForS` to plic.zig:

```zig
/// Same algorithm as claim() but non-destructive — used by trace markers
/// where we want to print the source ID without consuming it.
pub fn peekHighestPendingForS(self: *const Plic) u32 {
    var best_id: u32 = 0;
    var best_prio: u3 = 0;
    var i: u5 = 1;
    while (true) : (i += 1) {
        if ((self.pending & (@as(u32, 1) << i)) != 0 and
            (self.enable_s & (@as(u32, 1) << i)) != 0)
        {
            const prio = self.priority[i];
            if (prio > self.threshold_s and prio > best_prio) {
                best_prio = prio;
                best_id = i;
            }
        }
        if (i == 31) break;
    }
    return best_id;
}
```

In `src/devices/block.zig`'s `performTransfer`, emit the trace marker BEFORE running the transfer (so the line precedes the IRQ marker that follows). Take an optional `?*std.Io.Writer` parameter:

```zig
pub fn performTransfer(self: *Block, ram: []u8, trace_w: ?*std.Io.Writer) void {
    if (trace_w) |tw| {
        const op: @import("../trace.zig").Op = if (self.pending_cmd == 1) .Read else .Write;
        if (self.pending_cmd == 1 or self.pending_cmd == 2) {
            @import("../trace.zig").formatBlockTransfer(tw, op, self.sector, self.buffer_pa) catch {};
        }
    }
    // ... rest of performTransfer unchanged ...
}
```

In `src/memory.zig`, the storeBytePhysical CMD-byte 3 trigger needs a way to pass the trace writer. The cleanest: `Memory` doesn't have a back-pointer to `Cpu`, so we plumb it through. Either:

- (a) Add `trace_writer: ?*std.Io.Writer` to `Memory` and have `Cpu.run`/`Cpu.step` write it before each step.
- (b) Pass `null` in memory.zig's storeBytePhysical, and instead trace in cpu.step's deferred-IRQ servicing. The transfer has *already* happened by then, but the marker still appears between the previous and next instruction in the trace.

Choice (b) is simpler and gives us the right placement. Memory.zig calls `block.performTransfer(self.ram, null)`. cpu.step's deferred-IRQ servicing emits the trace marker via `cpu.trace_writer` if set. We can't recover the op kind after the fact (pending_cmd is cleared) — so block needs to retain the *last completed* op. Add `last_op: ?TraceOp = null` to Block, set inside performTransfer; cpu.step reads and clears it.

Update Block:

```zig
pub const TraceOp = enum { Read, Write };

pub const Block = struct {
    // ... existing fields ...
    last_op: ?TraceOp = null,
    last_sector: u32 = 0,
    last_buffer_pa: u32 = 0,

    pub fn performTransfer(self: *Block, ram: []u8) void {
        // ... existing logic ...
        // After successful (or even unsuccessful) transfer:
        if (self.pending_cmd == 1) self.last_op = .Read;
        if (self.pending_cmd == 2) self.last_op = .Write;
        self.last_sector = self.sector;
        self.last_buffer_pa = self.buffer_pa;
        // ... continue ...
    }
};
```

Update `cpu.step`:

```zig
pub fn step(self: *Cpu) StepError!void {
    // Service deferred device IRQs. Emit trace markers if --trace is on.
    if (self.memory.block.pending_irq) {
        if (self.trace_writer) |tw| {
            if (self.memory.block.last_op) |op| {
                @import("trace.zig").formatBlockTransfer(
                    tw,
                    if (op == .Read) .Read else .Write,
                    self.memory.block.last_sector,
                    self.memory.block.last_buffer_pa,
                ) catch {};
            }
        }
        self.memory.plic.assertSource(1);
        self.memory.block.pending_irq = false;
        self.memory.block.last_op = null;
    }
    if (check_interrupt(self)) return;
    // ... rest unchanged ...
}
```

Reconcile the trace.zig `Op` enum and block.zig's `TraceOp` — keep them in trace.zig only and import where needed (or duplicate; either works). Pick one — using trace.zig's is cleaner.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: all three new trace tests pass; no existing test regresses.

- [ ] **Step 5: Commit**

```bash
git add src/trace.zig src/trap.zig src/devices/plic.zig src/devices/block.zig src/cpu.zig
git commit -m "feat(trace): PLIC source ID in S-external markers; block transfer markers"
```

---

### Task 18: Integration test program — `tests/programs/plic_block_test/`

**Files:**
- Create: `tests/programs/plic_block_test/boot.S`
- Create: `tests/programs/plic_block_test/test.S`
- Create: `tests/programs/plic_block_test/linker.ld`
- Modify: `build.zig` (add the build pipeline)

**Why now:** With every device wired and traceable, prove the whole stack end-to-end via a tiny S-mode program that exercises CMD → IRQ → trap → claim → halt.

The test program does:

1. M-mode: zero BSS, set `mtvec` to a panic vector, set `medeleg` for all U-traps (overkill for this test but matches kernel pattern), set `mideleg.SEIP=1`, program PLIC (priority 1 for src 1, enable src 1 for S, threshold 0), set `sie.SEIE=1`, set `mstatus.MIE=0` (M never delegates externals), set `stvec` to the S-mode trap handler, drop to S via `mret` with `mstatus.MPP=S`.
2. S-mode: set `sstatus.SIE=1`. Write block-device registers: SECTOR=0, BUFFER=0x80100000, CMD=1 (read). Execute `wfi`.
3. S-trap handler: read PLIC claim register, expect 1. Read `STATUS` from block device, expect 0 (Ready). Read first byte at 0x80100000, expect magic byte (0xCC). Write claim register (complete). Halt with exit code 0 (write 1 to halt MMIO).
4. Anything off-script (M-trap, wrong PLIC source, wrong status, wrong magic): halt with non-zero exit code.

The test image is a 4 MB file with sector 0 = 0xCC magic byte at offset 0, rest zero. Built by a host-side encoder.

- [ ] **Step 1: Create the linker script**

Create `tests/programs/plic_block_test/linker.ld`:

```ld
OUTPUT_ARCH("riscv")
ENTRY(_M_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128M
}

SECTIONS {
    . = 0x80000000;

    .text : {
        KEEP(*(.text.init))
        *(.text .text.*)
    } > RAM

    .bss : {
        _bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    /DISCARD/ : {
        *(.note.*) *(.comment) *(.eh_frame) *(.eh_frame_hdr) *(.riscv.attributes)
    }
}
```

- [ ] **Step 2: Create boot.S (M-mode setup)**

Create `tests/programs/plic_block_test/boot.S`:

```asm
# tests/programs/plic_block_test/boot.S — Phase 3.A integration test M-mode shim.

.equ MIDELEG_SEIP, (1 << 9)
.equ MIE_NONE,      0
.equ SIE_SEIE,      (1 << 9)
.equ MSTATUS_MPP_S, (1 << 11)        # MPP=01 (S)
.equ MSTATUS_SIE,   (1 << 1)
.equ PLIC_PRIORITY_1, 0x0c000004
.equ PLIC_ENABLE_S,   0x0c002080
.equ PLIC_THRESHOLD_S,0x0c201000

.section .text.init, "ax", @progbits
.balign 4
.globl _M_start
_M_start:
    la      sp, _bss_end
    addi    sp, sp, 1024              # tiny stack

    # Zero BSS.
    la      t0, _bss_start
    la      t1, _bss_end
1:  beq     t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    # mtvec → panic vector (any M-mode trap = test failure).
    la      t0, m_panic
    csrw    mtvec, t0

    # mideleg.SEIP = 1.
    li      t0, MIDELEG_SEIP
    csrw    mideleg, t0

    # mie = 0 (M takes nothing).
    csrw    mie, zero

    # PLIC: priority src 1 = 1.
    li      t0, PLIC_PRIORITY_1
    li      t1, 1
    sw      t1, 0(t0)
    # Enable src 1 for S.
    li      t0, PLIC_ENABLE_S
    li      t1, (1 << 1)
    sw      t1, 0(t0)
    # Threshold = 0.
    li      t0, PLIC_THRESHOLD_S
    sw      zero, 0(t0)

    # stvec → s_trap_vector.
    la      t0, s_trap_vector
    csrw    stvec, t0

    # sie.SEIE = 1.
    li      t0, SIE_SEIE
    csrw    sie, t0

    # Drop to S at s_main with sstatus.SIE=1.
    li      t0, MSTATUS_SIE
    csrs    sstatus, t0
    li      t0, MSTATUS_MPP_S
    csrs    mstatus, t0
    la      t0, s_main
    csrw    mepc, t0
    mret

# M-mode panic: halt with exit code 2.
.globl m_panic
m_panic:
    li      t0, 0x00100000
    li      t1, 2
    sb      t1, 0(t0)
    j       m_panic
```

- [ ] **Step 3: Create test.S (S-mode body + trap handler)**

Create `tests/programs/plic_block_test/test.S`:

```asm
# tests/programs/plic_block_test/test.S — Phase 3.A integration test S-mode body.

.equ BLK_BASE,      0x10001000
.equ BLK_SECTOR,    0
.equ BLK_BUFFER,    4
.equ BLK_CMD,       8
.equ BLK_STATUS,    0xC

.equ PLIC_CLAIM_S,  0x0c201004
.equ HALT_BASE,     0x00100000
.equ TARGET_PA,     0x80100000

.section .text, "ax", @progbits
.balign 4
.globl s_main
s_main:
    # Program block: SECTOR=0, BUFFER=0x80100000, CMD=1 (read).
    li      t0, BLK_BASE
    sw      zero, BLK_SECTOR(t0)
    li      t1, TARGET_PA
    sw      t1, BLK_BUFFER(t0)
    li      t1, 1
    sw      t1, BLK_CMD(t0)

    # WFI — wait for interrupt.
1:  wfi
    j       1b   # if wfi returns without trap, loop (defensive)

.balign 4
.globl s_trap_vector
s_trap_vector:
    # Verify scause = 0x80000009 (interrupt | SEI).
    csrr    t0, scause
    li      t1, 0x80000009
    bne     t0, t1, fail

    # Claim from PLIC; expect 1.
    li      t0, PLIC_CLAIM_S
    lw      t1, 0(t0)
    li      t2, 1
    bne     t1, t2, fail

    # Block STATUS should be 0 (Ready).
    li      t0, BLK_BASE
    lw      t1, BLK_STATUS(t0)
    bnez    t1, fail

    # Read magic byte from RAM.
    li      t0, TARGET_PA
    lbu     t1, 0(t0)
    li      t2, 0xCC
    bne     t1, t2, fail

    # Complete (write claim).
    li      t0, PLIC_CLAIM_S
    li      t1, 1
    sw      t1, 0(t0)

    # Halt with exit code 0.
    li      t0, HALT_BASE
    sb      zero, 0(t0)
    j       .

fail:
    li      t0, HALT_BASE
    li      t1, 1
    sb      t1, 0(t0)
    j       .
```

- [ ] **Step 4: Wire build.zig to assemble the ELF + generate the test image + run e2e-plic-block**

In `build.zig`, after the existing `kernel-elf` blocks, add:

```zig
// === Phase 3.A integration test ===
const plic_block_boot = b.addObject(.{
    .name = "plic-block-boot",
    .root_module = b.createModule(.{
        .root_source_file = null,
        .target = rv_target,
        .optimize = .Debug,
    }),
});
plic_block_boot.root_module.addAssemblyFile(b.path("tests/programs/plic_block_test/boot.S"));

const plic_block_test_obj = b.addObject(.{
    .name = "plic-block-test",
    .root_module = b.createModule(.{
        .root_source_file = null,
        .target = rv_target,
        .optimize = .Debug,
    }),
});
plic_block_test_obj.root_module.addAssemblyFile(b.path("tests/programs/plic_block_test/test.S"));

const plic_block_elf = b.addExecutable(.{
    .name = "plic_block_test.elf",
    .root_module = b.createModule(.{
        .root_source_file = null,
        .target = rv_target,
        .optimize = .Debug,
        .strip = false,
        .single_threaded = true,
    }),
});
plic_block_elf.root_module.addObject(plic_block_boot);
plic_block_elf.root_module.addObject(plic_block_test_obj);
plic_block_elf.setLinkerScript(b.path("tests/programs/plic_block_test/linker.ld"));
plic_block_elf.entry = .{ .symbol_name = "_M_start" };

const install_plic_block_elf = b.addInstallArtifact(plic_block_elf, .{});
const plic_block_step = b.step("plic-block-test", "Build the Phase 3.A integration test ELF");
plic_block_step.dependOn(&install_plic_block_elf.step);

// Build the 4 MB test image (sector 0 = 0xCC, rest zero).
const make_img = b.addExecutable(.{
    .name = "make_plic_block_img",
    .root_module = b.createModule(.{
        .root_source_file = b.path("tests/programs/plic_block_test/make_img.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }),
});
const make_img_run = b.addRunArtifact(make_img);
const test_img = make_img_run.addOutputFileArg("plic_block_test.img");

// Run e2e-plic-block: ccc --disk <img> <elf>; expect exit 0.
const e2e_plic_block_run = b.addRunArtifact(exe);
e2e_plic_block_run.addArg("--disk");
e2e_plic_block_run.addFileArg(test_img);
e2e_plic_block_run.addFileArg(plic_block_elf.getEmittedBin());
e2e_plic_block_run.expectExitCode(0);

const e2e_plic_block_step = b.step("e2e-plic-block", "Run the Phase 3.A PLIC + block integration test");
e2e_plic_block_step.dependOn(&e2e_plic_block_run.step);
```

Create `tests/programs/plic_block_test/make_img.zig` (host tool):

```zig
const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var args_iter = try std.process.argsWithAllocator(a);
    defer args_iter.deinit();
    _ = args_iter.next(); // program name
    const out_path = args_iter.next() orelse return error.MissingOutputPath;

    var file = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer file.close();
    const SIZE: u64 = 4 * 1024 * 1024;
    try file.setEndPos(SIZE);
    // Write 0xCC at offset 0.
    try file.seekTo(0);
    try file.writeAll(&[_]u8{0xCC});
}
```

- [ ] **Step 5: Run the integration test**

Run: `zig build e2e-plic-block`
Expected: exit code 0. The test ELF goes through M-mode setup, drops to S, programs the block device, takes a PLIC interrupt, claims source 1, verifies the magic byte 0xCC at PA 0x80100000, and halts via the halt MMIO.

- [ ] **Step 6: Commit**

```bash
git add tests/programs/plic_block_test/ build.zig
git commit -m "feat(test): plic_block_test integration test exercises CMD->IRQ->claim path"
```

---

### Task 19: README + status update

**Files:**
- Modify: `README.md`

**Why now:** Phase 3 begins; the README's status line points at Phase 2.D and the device list omits PLIC + block. Update to reflect Plan 3.A landed.

- [ ] **Step 1: Read the current status section**

Run: `grep -n -A 10 "Status" README.md`

- [ ] **Step 2: Update status, device list, CLI, trace markers**

Replace the status line (was something like "Plan 2.D merged — Phase 2 complete"):

```markdown
**Status:** Phase 3 in progress. Plan 3.A merged: PLIC, simple block device,
UART RX, `--disk` and `--input` flags, real `wfi` idle.
```

In the device list (or hardware section), add:

```markdown
- **PLIC** (`0x0c00_0000`, 4 MB) — 32 sources × 1 S-mode hart context.
- **Block device** (`0x1000_1000`, 16 B) — 4 KB sectors, host-file-backed via `--disk`.
- **UART RX** — 256-byte FIFO, level IRQ via PLIC source 10.
```

In the CLI / Usage section, add:

```markdown
- `--disk PATH` — back the block device with this 4 MB host file.
- `--input PATH` — stream this file's bytes into the UART RX FIFO.
- `--disk-latency CYCLES` — reserved (no-op in Phase 3.A).
```

In the trace section (if one exists), add:

```markdown
- `--- interrupt 9 (supervisor external, src N) taken in <old>, now <new> ---`
- `--- block: read sector S at PA 0x<P> ---`
```

- [ ] **Step 3: Run a quick render check**

Run: `cat README.md | head -80`
Expected: status, device list, CLI sections all reflect Plan 3.A.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(readme): Plan 3.A landed — PLIC, block device, UART RX, --disk/--input"
```

---

### Task 20: Run the full test gauntlet

**Files:** none

**Why now:** Final smoke check. Plan 2's e2e tests, Phase 1's e2e tests, and `riscv-tests` should all still pass; `e2e-plic-block` is new.

- [ ] **Step 1: Run unit tests**

Run: `zig build test`
Expected: all unit tests pass (Phase 1 + Phase 2 + Plan 3.A's new tests across `plic.zig`, `block.zig`, `uart.zig`, `memory.zig`, `csr.zig`, `cpu.zig`, `trace.zig`, `main.zig`).

- [ ] **Step 2: Run riscv-tests**

Run: `zig build riscv-tests`
Expected: all rv32{ui,um,ua,mi,si}-p-* pass.

- [ ] **Step 3: Run Phase 1 + Phase 2 e2e**

Run: `zig build e2e && zig build e2e-mul && zig build e2e-trap && zig build e2e-hello-elf && zig build e2e-kernel`
Expected: all pass.

- [ ] **Step 4: Run Phase 3.A e2e**

Run: `zig build e2e-plic-block`
Expected: pass.

- [ ] **Step 5: (No commit.)** This task verifies; if any step fails, fix and re-run.

---

## Wrap-up

Plan 3.A landed when:

- All unit tests in `src/devices/plic.zig`, `src/devices/block.zig`, `src/devices/uart.zig` (RX additions), `src/memory.zig` (new MMIO arms), `src/csr.zig` (live SEIP), `src/cpu.zig` (block IRQ service + idleSpin), `src/main.zig` (CLI), `src/trace.zig` (markers) pass.
- `riscv-tests` (rv32ui/um/ua/mi/si all `-p-*`) still pass — no regression in privileged mode handling.
- `e2e`, `e2e-mul`, `e2e-trap`, `e2e-hello-elf`, `e2e-kernel` (Phase 1 + 2) still pass.
- `e2e-plic-block` (new) passes — the integration test exercises the entire CMD → IRQ → trap → claim → complete → halt path.
- `README.md` reflects the new device set, CLI flags, and trace markers.

Phase 3.B (kernel multi-process foundation) starts from this baseline. The PLIC, block device, and UART RX are *available* to the kernel but no kernel-side driver code exists yet — that's a 3.D problem. The synthetic `plic_block_test` proves the substrate; everything from here is software running on top of it.
