# Snake demo — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a playable WASD snake game running on the existing RV32IMA emulator core, in both the CLI (`zig build run-snake`) and the browser demo (selectable from a `<select>` next to `hello.elf`). Add `zig build e2e-snake` as a deterministic CI gate.

**Architecture:** Bare M-mode RV32 program (`snake.elf`) driven by CLINT timer interrupts at 8 Hz. Game logic lives in a target-independent `game.zig` so it can be unit-tested on native; the freestanding `snake.zig` adds MMIO + boot. Browser side: refactor `demo/web_main.zig` from a single blocking `run()` into chunked `runStart` / `runStep` (so the Worker can drain output and forward input between chunks); add a `~120-line` ANSI interpreter (full-redraw subset only) and a Web Worker that turns the chunked-step crank.

**Tech Stack:** Zig 0.16 (`riscv32-freestanding-none` for snake.elf, `wasm32-freestanding-none` for browser, native for game.zig tests + verify_e2e.zig). Web: vanilla JS (Worker, `WebAssembly.instantiate`, `BigInt`-typed wasm i64 args). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-04-25-snake-demo-design.md`

**Working directory:** all commands assume cwd = `/Users/cyyeh/Desktop/ccc/.worktrees/snake-demo` (after Task 0). Branch: `snake-demo`.

---

## File Structure

**New files:**
- `tests/programs/snake/linker.ld` — load `.text.init` at 0x80000000, define `_stack_top`, `_bss_start`, `_bss_end`, expose `tohost` symbol
- `tests/programs/snake/monitor.S` — `_start` (clear .bss → set sp → install trap_vector → enable mstatus.MIE + mie.MTIE → program first mtimecmp → wfi loop), `trap_vector` (caller-saved save/restore + call `snakeTrap`)
- `tests/programs/snake/game.zig` — pure game logic, native-testable
- `tests/programs/snake/snake.zig` — freestanding integration: `snakeTrap`, `tickHandler`, `render`, `drainOneInputByte`, `halt`
- `tests/programs/snake/test_input.txt` — deterministic byte sequence for e2e (28-30 bytes; tuned in T18)
- `tests/programs/snake/verify_e2e.zig` — host-compiled verifier (mirrors `tests/programs/kernel/verify_e2e.zig`)
- `web/ansi.js` — ANSI subset interpreter (`CSI 2 J`, `CSI [r;c] H`, `CSI ?25 l/h`, UTF-8) over a 32×16 char screen
- `web/runner.js` — Web Worker; runs the chunked `runStep` loop; routes `pushInput` and `consumeOutput`

**Modified files:**
- `build.zig` — add `snake-elf`, `snake-test` (native game.zig tests), `run-snake`, `e2e-snake` steps; embed `snake.elf` in the wasm build alongside `hello.elf`
- `demo/web_main.zig` — replace single blocking `run()` with module-level emulator state + `runStart` / `runStep` / `setMtimeNs` / `consumeOutput` / `pushInput` / `selectProgram`; embed `snake.elf`
- `web/index.html` — add `<select>` (default `snake.elf`), focusable `<pre tabindex="0">`, "click to play" hint
- `web/demo.css` — focus outline on the `<pre>`, click-hint overlay, monospace tightening
- `web/demo.js` — rewrite to use the Worker (~80 → ~150 lines); wire `<select>` change → Worker `select`; keystroke filter → Worker `input`; Worker `output` → `ansi.feed` → re-render
- `.github/workflows/pages.yml` — add `zig build e2e-snake` to the test matrix

---

## Task ordering rationale

1. **T0**: worktree setup. Skip if you prefer to work on `main`; otherwise this is a one-time gesture.
2. **T1**: minimal `snake.elf` skeleton that boots and halts. Confirms the build wiring before any game logic exists.
3. **T2–T8**: TDD on `game.zig` against the native target. Pure data manipulation — fastest iteration loop in the project. Each task is one "feature" with its tests.
4. **T9–T10**: assembly side of `snake.elf`: full boot + trap entry. After this the program is structurally ready for an interrupt-driven loop.
5. **T11–T16**: integrate `game.zig` into `snake.zig`. After T16 you can play the game in a CLI tty (with stty raw mode set up by T17).
6. **T17–T19**: CLI run target, e2e test, CI integration. After T19 the project has a green PR gate for snake.
7. **T20–T22**: refactor `demo/web_main.zig`. The biggest single change in the plan; do it before any browser-side code so the new exports are real.
8. **T23–T26**: browser side. ANSI interpreter (T23) → Worker (T24) → UI scaffolding (T25) → wire it together (T26).
9. **T27**: manual browser smoke test. The final gate before claiming done.

---

## Task 0: Setup worktree

**Files:** none (just git plumbing).

The brainstorming skill normally creates the worktree but didn't this round. Create one now to keep main clean while you build.

- [ ] **Step 1: Create the worktree and branch**

```bash
cd /Users/cyyeh/Desktop/ccc
git worktree add .worktrees/snake-demo -b snake-demo
cd .worktrees/snake-demo
```

Expected: a new directory `.worktrees/snake-demo` containing a checkout on branch `snake-demo`. (The repo's `.gitignore` already ignores `.worktrees/` per `a7012e5`.)

- [ ] **Step 2: Verify state**

```bash
git status
zig build test
```

Expected: clean working tree on `snake-demo`; `zig build test` passes (sanity check that you have a working baseline).

---

## Task 1: Bootstrap `snake.elf` skeleton

**Files:**
- Create: `tests/programs/snake/linker.ld`
- Create: `tests/programs/snake/monitor.S`
- Create: `tests/programs/snake/snake.zig`
- Modify: `build.zig` (append a `snake-elf` step block)

**Reference patterns to mirror:**
- `tests/programs/hello/linker.ld` — same load address, same section layout
- `tests/programs/hello/monitor.S` lines 18–58 — boot pattern (no PMP setup needed; ccc doesn't model PMP and snake stays in M-mode)
- `build.zig` lines 142–191 — `hello-elf` build wiring

After this task, `zig build snake-elf` produces an ELF that does nothing but halt cleanly, exit code 0.

- [ ] **Step 1: Write `tests/programs/snake/linker.ld`**

```ld
/* Linker script for snake.elf (Phase 3 demo). Mirrors hello/linker.ld
 * but exposes _bss_start / _bss_end so monitor.S can zero BSS before
 * Zig code (which has lots of mutable module-level state) runs. */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128M
}

SECTIONS {
    . = 0x80000000;

    .text.init : { KEEP(*(.text.init)) } > RAM
    .text      : { *(.text .text.*) }    > RAM
    .rodata    : { *(.rodata .rodata.*) } > RAM
    .data      : { *(.data .data.*) }    > RAM

    .bss : {
        _bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    /* 16 KB stack — snake's tick handler nests one frame deep, but
     * the Zig render path uses fixed buffers, so 16 KB is generous. */
    . = ALIGN(16);
    . = . + 0x4000;
    _stack_top = .;

    /* tohost: a 4-byte word the program writes to halt the emulator.
     * src/elf.zig resolves this symbol at load time and routes writes
     * to mem.tohost_addr → halt device. Same convention as riscv-tests
     * and hello.elf (hello hardcodes 0x00100000 instead, but both
     * paths end up at the halt MMIO). */
    . = ALIGN(8);
    tohost = .;
    . = . + 8;

    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.eh_frame)
        *(.riscv.attributes)
    }
}
```

- [ ] **Step 2: Write a minimal `tests/programs/snake/monitor.S`**

This skeleton just halts. The full boot sequence (BSS clear, trap setup, timer init, wfi loop) lands in T9.

```asm
# Phase 3 snake.elf — minimal skeleton. Boots, halts via tohost.
# Full boot + trap setup arrives in T9.

.section .text.init, "ax", @progbits
.globl _start
_start:
    la      sp, _stack_top
    # Write 1 to tohost low byte → halt with exit code 0.
    # The halt MMIO encoding is "low byte = exit code"; non-zero
    # value in tohost signals "test passed" per riscv-tests convention,
    # which our halt device interprets as exit_code = 0.
    la      t0, tohost
    li      t1, 1
    sw      t1, 0(t0)
1:  j       1b
```

- [ ] **Step 3: Write a minimal `tests/programs/snake/snake.zig`**

Zig source is needed so `build.zig` has something to compile into the executable's Zig object. For now it's empty.

```zig
// tests/programs/snake/snake.zig
//
// Freestanding M-mode snake. Skeleton for now — game logic and trap
// dispatch arrive in later tasks. monitor.S currently halts before
// reaching any Zig code, so this file just needs to exist as a
// linkable object.

comptime {
    // Force a non-empty .bss so the linker emits the section
    // and our `_bss_start`/`_bss_end` symbols resolve.
    @export(&_placeholder, .{ .name = "_snake_placeholder" });
}

var _placeholder: u8 = 0;
```

- [ ] **Step 4: Append the `snake-elf` block to `build.zig`**

Insert AFTER the existing `e2e_plic_block_step` block (around line 419 of `build.zig`). Use the same `rv_target` already defined at lines 126–138.

```zig
    // === Snake demo (Phase 3) ===
    const snake_monitor_obj = b.addObject(.{
        .name = "snake-monitor",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
        }),
    });
    snake_monitor_obj.root_module.addAssemblyFile(b.path("tests/programs/snake/monitor.S"));

    const snake_zig_obj = b.addObject(.{
        .name = "snake-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/snake/snake.zig"),
            .target = rv_target,
            .optimize = .ReleaseSmall,
            .strip = false,
            .single_threaded = true,
        }),
    });

    const snake_elf = b.addExecutable(.{
        .name = "snake.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    snake_elf.root_module.addObject(snake_monitor_obj);
    snake_elf.root_module.addObject(snake_zig_obj);
    snake_elf.setLinkerScript(b.path("tests/programs/snake/linker.ld"));
    snake_elf.entry = .{ .symbol_name = "_start" };

    const install_snake_elf = b.addInstallArtifact(snake_elf, .{});
    const snake_elf_step = b.step("snake-elf", "Build the Phase 3 snake.elf demo");
    snake_elf_step.dependOn(&install_snake_elf.step);
```

- [ ] **Step 5: Build and verify**

```bash
zig build snake-elf
ls -l zig-out/bin/snake.elf
zig build run -- zig-out/bin/snake.elf
echo "exit=$?"
```

Expected: ELF builds with no warnings; `ls` shows non-zero size; running it produces no output and exits with code 0 (since tohost-low-byte=1 → halt exit 0).

- [ ] **Step 6: Commit**

```bash
git add tests/programs/snake/ build.zig
git commit -m "snake: bootstrap skeleton — boots, halts cleanly"
```

---

## Task 2: `game.zig` types + `Game.init` + native test step

**Files:**
- Create: `tests/programs/snake/game.zig`
- Modify: `build.zig` (add a `snake-test` step that runs game.zig's tests on native)

`game.zig` is pure data manipulation — no `@import("std").Io`, no MMIO, no inline asm. That lets us cross-compile it to native and run unit tests in milliseconds. The freestanding `snake.zig` will `@import("game.zig")` later.

After this task: `zig build snake-test` runs and passes one test (init produces correct initial state).

- [ ] **Step 1: Write the failing test in `tests/programs/snake/game.zig`**

```zig
//! Pure snake game logic. Target-independent (no Io, no MMIO, no asm).
//! `snake.zig` (freestanding) imports this and adds the M-mode wrapping;
//! `zig build snake-test` runs these unit tests against the native target.

const std = @import("std");

pub const W: u8 = 32;            // total board cols including border
pub const H: u8 = 15;            // total board rows including border (HUD is row 0 of the terminal, separate)
pub const PLAY_W: u8 = W - 2;    // 30 playable cols (1..W-2)
pub const PLAY_H: u8 = H - 2;    // 13 playable rows (1..H-2)
pub const MAX_SNAKE: u16 = @as(u16, PLAY_W) * @as(u16, PLAY_H);

pub const Dir = enum(u8) { Up, Down, Left, Right };

pub const Cell = struct { x: u8, y: u8 };

pub const State = enum(u8) { Playing, GameOver };

pub const AdvanceResult = enum(u8) { Moved, Grew, CollisionWall, CollisionSelf };

pub const Game = struct {
    snake_x: [MAX_SNAKE]u8,
    snake_y: [MAX_SNAKE]u8,
    head: u16,
    tail: u16,
    len: u16,
    dir: Dir,
    pending_dir: ?Dir,
    food: ?Cell,
    score: u32,
    rng: u32,
    state: State,
    game_started: bool,

    pub fn init(spawn: Cell) Game {
        var g: Game = .{
            .snake_x = [_]u8{0} ** MAX_SNAKE,
            .snake_y = [_]u8{0} ** MAX_SNAKE,
            .head = 2,
            .tail = 0,
            .len = 3,
            .dir = .Right,
            .pending_dir = null,
            .food = null,
            .score = 0,
            .rng = 0,
            .state = .Playing,
            .game_started = false,
        };
        // Snake of length 3, head at spawn, tail extending left.
        g.snake_x[0] = spawn.x - 2; g.snake_y[0] = spawn.y;
        g.snake_x[1] = spawn.x - 1; g.snake_y[1] = spawn.y;
        g.snake_x[2] = spawn.x;     g.snake_y[2] = spawn.y;
        return g;
    }
};

test "Game.init: snake length 3, head at spawn, facing right" {
    const g = Game.init(.{ .x = 16, .y = 7 });
    try std.testing.expectEqual(@as(u16, 3), g.len);
    try std.testing.expectEqual(Dir.Right, g.dir);
    try std.testing.expectEqual(@as(u8, 16), g.snake_x[g.head]);
    try std.testing.expectEqual(@as(u8, 7),  g.snake_y[g.head]);
    try std.testing.expectEqual(@as(u8, 14), g.snake_x[g.tail]);
    try std.testing.expectEqual(State.Playing, g.state);
    try std.testing.expect(!g.game_started);
}
```

- [ ] **Step 2: Add the `snake-test` step to `build.zig`**

Append after the `snake-elf` block from T1. Native target so tests run on the host machine.

```zig
    const snake_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/programs/snake/game.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const snake_test = b.addTest(.{ .root_module = snake_test_mod });
    const snake_test_run = b.addRunArtifact(snake_test);
    const snake_test_step = b.step("snake-test", "Run game.zig unit tests on native");
    snake_test_step.dependOn(&snake_test_run.step);
```

- [ ] **Step 3: Run the test, expect PASS**

```bash
zig build snake-test
```

Expected: `1 passed; 0 failed`. (The test exercises only `init`, which is already complete.)

- [ ] **Step 4: Commit**

```bash
git add tests/programs/snake/game.zig build.zig
git commit -m "snake: game.zig types + Game.init + native test step"
```

---

## Task 3: `Game.advance` + wall collision

**Files:** `tests/programs/snake/game.zig`

`advance` moves the head one cell in `self.dir`, then checks collision. Out-of-bounds → `CollisionWall`. We'll add self-collision in T5.

- [ ] **Step 1: Write the failing tests at the bottom of `game.zig`**

```zig
test "advance: moves head one cell right" {
    var g = Game.init(.{ .x = 16, .y = 7 });
    const r = g.advance();
    try std.testing.expectEqual(AdvanceResult.Moved, r);
    try std.testing.expectEqual(@as(u8, 17), g.snake_x[g.head]);
    try std.testing.expectEqual(@as(u8, 7),  g.snake_y[g.head]);
    try std.testing.expectEqual(@as(u16, 3), g.len);
}

test "advance: hits right wall returns CollisionWall" {
    // Spawn at (PLAY_W - 1, 7). Snake head is at (PLAY_W, 7) — that's the
    // right border (column W-1 = 31). Wait: spawn places head AT spawn.x.
    // PLAY_W = 30, so playable cols are 1..30. Border at col 31. Spawn
    // head at (30, 7); advancing right puts it at (31, 7) — hits border.
    var g = Game.init(.{ .x = PLAY_W, .y = 7 });
    const r = g.advance();
    try std.testing.expectEqual(AdvanceResult.CollisionWall, r);
    try std.testing.expectEqual(State.GameOver, g.state);
}

test "advance: hits left wall" {
    var g = Game.init(.{ .x = 5, .y = 7 });
    g.dir = .Left;
    g.advance(); // (4,7)
    g.advance(); // (3,7)
    g.advance(); // (2,7)
    g.advance(); // (1,7) — last playable
    const r = g.advance(); // (0,7) — border
    try std.testing.expectEqual(AdvanceResult.CollisionWall, r);
}

test "advance: hits top wall" {
    var g = Game.init(.{ .x = 16, .y = 5 });
    g.dir = .Up;
    g.advance(); g.advance(); g.advance(); g.advance(); // (16,1)
    const r = g.advance(); // (16,0) — top border
    try std.testing.expectEqual(AdvanceResult.CollisionWall, r);
}

test "advance: hits bottom wall" {
    var g = Game.init(.{ .x = 16, .y = PLAY_H - 1 });
    g.dir = .Down;
    g.advance(); // (16, PLAY_H) — border row
    // PLAY_H = 13, so playable rows are 1..13. Border at row 14.
    // y starts at PLAY_H - 1 = 12. advance to 13 (still playable),
    // advance again to 14 (border) → wall.
    const r = g.advance();
    try std.testing.expectEqual(AdvanceResult.CollisionWall, r);
}
```

- [ ] **Step 2: Run, verify they fail**

```bash
zig build snake-test
```

Expected: compile error (no `advance` method) or `5 failures`. Either way — fails. If compile error, that counts as "fails."

- [ ] **Step 3: Implement `Game.advance` (no food path yet)**

Add inside the `Game` struct, after `init`:

```zig
    pub fn advance(self: *Game) AdvanceResult {
        // Compute new head position.
        const head_x = self.snake_x[self.head];
        const head_y = self.snake_y[self.head];
        var nx: i16 = head_x;
        var ny: i16 = head_y;
        switch (self.dir) {
            .Up    => ny -= 1,
            .Down  => ny += 1,
            .Left  => nx -= 1,
            .Right => nx += 1,
        }

        // Wall check: playable area is x in [1, PLAY_W], y in [1, PLAY_H].
        if (nx <= 0 or nx > PLAY_W or ny <= 0 or ny > PLAY_H) {
            self.state = .GameOver;
            return .CollisionWall;
        }

        // Move head + tail forward (no food eaten in this task).
        const new_head: u16 = (self.head + 1) % MAX_SNAKE;
        self.snake_x[new_head] = @intCast(nx);
        self.snake_y[new_head] = @intCast(ny);
        self.head = new_head;
        self.tail = (self.tail + 1) % MAX_SNAKE;
        // len unchanged.
        return .Moved;
    }
```

- [ ] **Step 4: Run, expect PASS**

```bash
zig build snake-test
```

Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tests/programs/snake/game.zig
git commit -m "snake: Game.advance + wall collision"
```

---

## Task 4: `applyDirIfLegal` (180° rejection)

**Files:** `tests/programs/snake/game.zig`

Snake refuses to reverse directly into itself. `applyDirIfLegal` is called once per tick, before `advance`, and flips `dir` to `pending_dir` only if the new direction isn't a 180° reversal.

- [ ] **Step 1: Write failing tests**

```zig
test "applyDirIfLegal: 90° turn accepted" {
    var g = Game.init(.{ .x = 16, .y = 7 });
    g.pending_dir = .Up;
    g.applyDirIfLegal();
    try std.testing.expectEqual(Dir.Up, g.dir);
    try std.testing.expectEqual(@as(?Dir, null), g.pending_dir);
}

test "applyDirIfLegal: 180° reversal rejected" {
    var g = Game.init(.{ .x = 16, .y = 7 }); // facing Right
    g.pending_dir = .Left;
    g.applyDirIfLegal();
    try std.testing.expectEqual(Dir.Right, g.dir); // unchanged
    try std.testing.expectEqual(@as(?Dir, null), g.pending_dir); // still cleared
}

test "applyDirIfLegal: same direction is a no-op" {
    var g = Game.init(.{ .x = 16, .y = 7 });
    g.pending_dir = .Right;
    g.applyDirIfLegal();
    try std.testing.expectEqual(Dir.Right, g.dir);
}

test "applyDirIfLegal: no pending is a no-op" {
    var g = Game.init(.{ .x = 16, .y = 7 });
    g.pending_dir = null;
    g.applyDirIfLegal();
    try std.testing.expectEqual(Dir.Right, g.dir);
}
```

- [ ] **Step 2: Run, verify they fail**

```bash
zig build snake-test
```

Expected: compile error (method missing) or 4 failures.

- [ ] **Step 3: Implement `applyDirIfLegal`**

Add inside `Game`, alongside `advance`:

```zig
    pub fn applyDirIfLegal(self: *Game) void {
        const p = self.pending_dir orelse return;
        const reversal = switch (self.dir) {
            .Up    => p == .Down,
            .Down  => p == .Up,
            .Left  => p == .Right,
            .Right => p == .Left,
        };
        if (!reversal) self.dir = p;
        self.pending_dir = null;
    }
```

- [ ] **Step 4: Run, expect PASS**

```bash
zig build snake-test
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add tests/programs/snake/game.zig
git commit -m "snake: applyDirIfLegal (180° reversal rejection)"
```

---

## Task 5: Self-collision detection

**Files:** `tests/programs/snake/game.zig`

A snake of length ≥ 5 can bite itself: U-turn through the body. `advance` must check the new head cell against the existing body before placing it.

- [ ] **Step 1: Write the failing test**

```zig
test "advance: self-collision when head re-enters body" {
    // Build a length-5 snake forming a hook so the next move re-enters.
    //
    //   ##H        positions (using 1-indexed playable):
    //   #          (5,5) (6,5) (5,6) (5,7) (6,7)  with head at (6,7)
    //   ##         heading Up. Next advance: (6,6) — collides with body.
    //
    // We can't construct this purely by `init` + `advance`, so build the
    // ring buffer manually then call advance.
    var g = Game.init(.{ .x = 6, .y = 7 });
    // Override the snake to a 5-cell hook ending at (6,7) facing Up.
    g.len = 5;
    g.tail = 0;
    g.head = 4;
    const path = [_]Cell{
        .{ .x = 5, .y = 5 }, // tail
        .{ .x = 6, .y = 5 },
        .{ .x = 6, .y = 6 },
        .{ .x = 5, .y = 6 }, // body cell that the next Up move from (6,7)... wait
        .{ .x = 6, .y = 7 }, // head
    };
    for (path, 0..) |c, i| {
        g.snake_x[i] = c.x;
        g.snake_y[i] = c.y;
    }
    g.dir = .Up;
    // Next move: head goes (6,7) → (6,6). (6,6) is in the body (index 2).
    const r = g.advance();
    try std.testing.expectEqual(AdvanceResult.CollisionSelf, r);
    try std.testing.expectEqual(State.GameOver, g.state);
}

test "advance: tail-cell collision is OK (tail moves away)" {
    // After `advance`, the tail vacates its current cell. So if the
    // head moves INTO the current tail cell, that's allowed in real
    // snake (this is the "chasing your own tail" scenario). Most
    // implementations special-case this; for simplicity we follow
    // the strict rule: any body cell collision = death. Document this
    // as a deliberate choice. If tests are ever added to assert the
    // permissive variant, change `advance` to skip the tail in the
    // collision scan.
    //
    // No new behavior to test here; this is just a comment-anchor.
    _ = Game.init(.{ .x = 16, .y = 7 });
}
```

- [ ] **Step 2: Run, verify the first test fails**

```bash
zig build snake-test
```

Expected: 1 new failure (the `self-collision` test).

- [ ] **Step 3: Add self-collision check to `advance`**

Modify `advance` — insert the body scan AFTER the wall check and BEFORE moving the head:

```zig
        // Self-collision: scan the current body for (nx, ny).
        // Walk len cells starting at tail.
        var i: u16 = 0;
        var idx: u16 = self.tail;
        while (i < self.len) : (i += 1) {
            if (self.snake_x[idx] == @as(u8, @intCast(nx)) and
                self.snake_y[idx] == @as(u8, @intCast(ny)))
            {
                self.state = .GameOver;
                return .CollisionSelf;
            }
            idx = (idx + 1) % MAX_SNAKE;
        }
```

- [ ] **Step 4: Run, expect PASS**

```bash
zig build snake-test
```

Expected: all tests pass (the second "test" is comment-anchor only).

- [ ] **Step 5: Commit**

```bash
git add tests/programs/snake/game.zig
git commit -m "snake: self-collision detection"
```

---

## Task 6: xorshift32 RNG + `nextRng`

**Files:** `tests/programs/snake/game.zig`

xorshift32 is the smallest decent RNG: ~3 lines, period ≈ 4 billion, no multiply needed. Seeded by the first key press (from mtime in the freestanding wrapper); never seeded with 0 (xorshift32 is degenerate from 0).

- [ ] **Step 1: Write failing tests**

```zig
test "nextRng: nonzero seed produces nonzero output" {
    var g = Game.init(.{ .x = 16, .y = 7 });
    g.rng = 0x1234_5678;
    const r1 = g.nextRng();
    const r2 = g.nextRng();
    try std.testing.expect(r1 != 0);
    try std.testing.expect(r2 != 0);
    try std.testing.expect(r1 != r2);
}

test "nextRng: deterministic with fixed seed" {
    var g1 = Game.init(.{ .x = 16, .y = 7 });
    var g2 = Game.init(.{ .x = 16, .y = 7 });
    g1.rng = 42;
    g2.rng = 42;
    try std.testing.expectEqual(g1.nextRng(), g2.nextRng());
    try std.testing.expectEqual(g1.nextRng(), g2.nextRng());
}
```

- [ ] **Step 2: Run, verify failures**

```bash
zig build snake-test
```

- [ ] **Step 3: Implement `nextRng`**

```zig
    pub fn nextRng(self: *Game) u32 {
        // xorshift32. Self.rng must be nonzero before the first call.
        var x = self.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.rng = x;
        return x;
    }
```

- [ ] **Step 4: Run, expect PASS**

```bash
zig build snake-test
```

- [ ] **Step 5: Commit**

```bash
git add tests/programs/snake/game.zig
git commit -m "snake: xorshift32 RNG"
```

---

## Task 7: `placeFood` (rejection sampling)

**Files:** `tests/programs/snake/game.zig`

Pick a random cell in the playable area `[1..PLAY_W] × [1..PLAY_H]`. If it's on the snake, retry. The retry is bounded by `MAX_SNAKE` attempts; if no spot found (impossible in practice — board has at most 390 cells, snake can't fill them all without winning), leave food as `null` (treated as "no food this round").

- [ ] **Step 1: Write failing tests**

```zig
test "placeFood: lands inside the playable area" {
    var g = Game.init(.{ .x = 16, .y = 7 });
    g.rng = 1;
    g.placeFood();
    const f = g.food.?;
    try std.testing.expect(f.x >= 1 and f.x <= PLAY_W);
    try std.testing.expect(f.y >= 1 and f.y <= PLAY_H);
}

test "placeFood: never on the snake body" {
    var g = Game.init(.{ .x = 16, .y = 7 });
    g.rng = 7;
    var iter: u32 = 0;
    while (iter < 100) : (iter += 1) {
        g.placeFood();
        const f = g.food.?;
        var i: u16 = 0;
        var idx: u16 = g.tail;
        while (i < g.len) : (i += 1) {
            try std.testing.expect(!(g.snake_x[idx] == f.x and g.snake_y[idx] == f.y));
            idx = (idx + 1) % MAX_SNAKE;
        }
    }
}
```

- [ ] **Step 2: Run, verify failures**

```bash
zig build snake-test
```

- [ ] **Step 3: Implement `placeFood`**

```zig
    pub fn placeFood(self: *Game) void {
        var attempts: u32 = 0;
        while (attempts < MAX_SNAKE) : (attempts += 1) {
            const r = self.nextRng();
            const x: u8 = @intCast((r % PLAY_W) + 1);             // 1..PLAY_W
            const y: u8 = @intCast(((r >> 8) % PLAY_H) + 1);      // 1..PLAY_H
            // Reject if on snake.
            var i: u16 = 0;
            var idx: u16 = self.tail;
            var on_snake = false;
            while (i < self.len) : (i += 1) {
                if (self.snake_x[idx] == x and self.snake_y[idx] == y) {
                    on_snake = true;
                    break;
                }
                idx = (idx + 1) % MAX_SNAKE;
            }
            if (!on_snake) {
                self.food = .{ .x = x, .y = y };
                return;
            }
        }
        self.food = null; // unreachable in practice
    }
```

- [ ] **Step 4: Run, expect PASS**

```bash
zig build snake-test
```

- [ ] **Step 5: Commit**

```bash
git add tests/programs/snake/game.zig
git commit -m "snake: placeFood with rejection sampling"
```

---

## Task 8: Eat-food path (score++, len++, food respawn)

**Files:** `tests/programs/snake/game.zig`

When `advance` lands the new head on `food`: score increments, length increments, the tail does NOT advance this tick (so the snake grows by 1), and a new food is placed. Returns `Grew` instead of `Moved`.

- [ ] **Step 1: Write the failing test**

```zig
test "advance onto food: score++, len++, food respawned, tail stays" {
    var g = Game.init(.{ .x = 16, .y = 7 });
    g.rng = 1;
    // Place food immediately to the right of the head (head at (16,7), food at (17,7)).
    g.food = .{ .x = 17, .y = 7 };
    const tail_x_before = g.snake_x[g.tail];
    const tail_y_before = g.snake_y[g.tail];
    const r = g.advance();
    try std.testing.expectEqual(AdvanceResult.Grew, r);
    try std.testing.expectEqual(@as(u32, 1), g.score);
    try std.testing.expectEqual(@as(u16, 4), g.len);
    // Tail did NOT advance.
    try std.testing.expectEqual(tail_x_before, g.snake_x[g.tail]);
    try std.testing.expectEqual(tail_y_before, g.snake_y[g.tail]);
    // New food was placed (rng was nonzero, so placeFood succeeded).
    try std.testing.expect(g.food != null);
    // New food is not at (17,7) (the eaten one).
    try std.testing.expect(!(g.food.?.x == 17 and g.food.?.y == 7));
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Modify `advance` to handle food**

Replace the "Move head + tail forward" block at the bottom of `advance` with:

```zig
        // Move head into (nx, ny).
        const new_head: u16 = (self.head + 1) % MAX_SNAKE;
        self.snake_x[new_head] = @intCast(nx);
        self.snake_y[new_head] = @intCast(ny);
        self.head = new_head;

        // Food check.
        const ate = if (self.food) |f|
            (f.x == @as(u8, @intCast(nx)) and f.y == @as(u8, @intCast(ny)))
        else
            false;

        if (ate) {
            self.score += 1;
            self.len += 1;
            self.placeFood();
            return .Grew;
        }

        // No food eaten — advance tail (snake moves, doesn't grow).
        self.tail = (self.tail + 1) % MAX_SNAKE;
        return .Moved;
```

- [ ] **Step 4: Run, expect PASS**

```bash
zig build snake-test
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add tests/programs/snake/game.zig
git commit -m "snake: eat-food path (score, len, respawn)"
```

---

## Task 9: `monitor.S` — full boot sequence

**Files:** `tests/programs/snake/monitor.S` (rewrite)

Replace the placeholder skeleton with the real boot sequence: clear .bss, set sp, install `trap_vector` in `mtvec`, enable `mstatus.MIE` + `mie.MTIE`, program first `mtimecmp`, enter the `wfi` idle loop. The `trap_vector` is a forward declaration that lives at the bottom of this file (filled in next task — for now it's a stub that just returns).

After this task, snake.elf boots into the wfi loop and waits for an interrupt that never comes (test it with a 2-second timeout to confirm it's idling, not hung in code).

- [ ] **Step 1: Rewrite `tests/programs/snake/monitor.S`**

```asm
# Phase 3 snake.elf — M-mode boot + idle loop + trap stub.
#
# Boot sequence:
#   1. Set sp = _stack_top.
#   2. Clear .bss (Zig module-level state lives here and assumes zero-init).
#   3. Install trap_vector at mtvec.
#   4. Enable mstatus.MIE and mie.MTIE.
#   5. Program first mtimecmp = mtime + period (1.25M ticks @ 10 MHz = 125 ms).
#   6. Enter wfi loop.
#
# CLINT MMIO (per src/devices/clint.zig):
#   mtime     = 0x0200BFF8 (64-bit, low at 0x0200BFF8)
#   mtimecmp  = 0x02004000 (64-bit, low at 0x02004000)
#
# trap_vector is a stub for this task — just returns via mret without doing
# anything. T10 fills it in with caller-saved save/restore + call snakeTrap.

.section .text.init, "ax", @progbits
.globl _start
_start:
    # 1. sp.
    la      sp, _stack_top

    # 2. Clear .bss [_bss_start, _bss_end).
    la      t0, _bss_start
    la      t1, _bss_end
bss_clear_loop:
    bgeu    t0, t1, bss_clear_done
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       bss_clear_loop
bss_clear_done:

    # 3. Install trap vector (direct mode; address must be 4-byte aligned).
    la      t0, trap_vector
    csrw    mtvec, t0

    # 4. Enable timer interrupt.
    li      t0, (1 << 7)              # mie.MTIE = bit 7
    csrs    mie, t0
    li      t0, (1 << 3)              # mstatus.MIE = bit 3
    csrs    mstatus, t0

    # 5. Program first mtimecmp = mtime + 1_250_000 ticks (125 ms @ 10 MHz).
    li      t1, 0x0200BFF8            # mtime addr
    li      t2, 0x02004000            # mtimecmp addr
    lw      a0, 0(t1)                 # mtime low
    lw      a1, 4(t1)                 # mtime high
    li      t3, 1250000               # period (low word)
    add     a0, a0, t3
    sltu    t4, a0, t3                # carry
    add     a1, a1, t4                # propagate carry into high
    sw      a0, 0(t2)
    sw      a1, 4(t2)

    # 6. Enter wfi loop. The CPU sleeps until any enabled interrupt fires.
    # When MTI fires, trap_vector runs, returns here, we wfi again.
idle:
    wfi
    j       idle

# ---- Trap vector (stub) -------------------------------------------------
# T10 replaces this with the real save/restore + call snakeTrap.
# For now, just mret. (No real interrupt should fire yet — the very first
# MTI happens 125 ms after boot, but if the program is e2e-tested with a
# short timeout, the test exits before then. Manual `zig build run` will
# show the ELF idling forever; kill it with Ctrl+C.)
.balign 4
.globl trap_vector
trap_vector:
    mret
```

- [ ] **Step 2: Build and verify the ELF compiles**

```bash
zig build snake-elf
```

Expected: clean build.

- [ ] **Step 3: Smoke-test that it idles (kill after 1 second)**

```bash
timeout 1 zig build run -- zig-out/bin/snake.elf
echo "exit=$?"
```

Expected: exit code 124 (timeout's SIGTERM signal). NOT 0 — that would mean the program halted; not 1 — that would mean a panic or unhandled trap. 124 confirms the program is idling in `wfi` waiting for an interrupt that does eventually fire (after 125 ms) but hits the stub and returns to wfi. After 1 second it gets killed.

If you see exit code 0, the program is halting somewhere unexpected — investigate. If you see a trap dump, `trap_vector` isn't 4-byte aligned or `mtvec` isn't being written.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/snake/monitor.S
git commit -m "snake: full boot — bss clear, mtvec, MIE, mtimecmp, wfi"
```

---

## Task 10: `monitor.S` — real `trap_vector` (caller-saved save/restore + call snakeTrap)

**Files:**
- Modify: `tests/programs/snake/monitor.S` (replace the stub `trap_vector` at the bottom)
- Modify: `tests/programs/snake/snake.zig` (add an empty `snakeTrap` so the link works)

In M-mode, an interrupt arriving while we're in `wfi` saves `pc` to `mepc` and jumps to `mtvec`. We save caller-saved registers (the wfi loop's "callee" surface), call `snakeTrap` (Zig), restore, mret. Snake's wfi loop has no live registers other than `sp` and `ra` (none of t/a are live across `wfi`), so technically we only need to save `ra`. But Zig's calling convention assumes all caller-saved regs may be clobbered; to be safe and to mirror `tests/programs/kernel/trampoline.S`, we save all of them.

Reference: `tests/programs/kernel/trampoline.S` (S-mode equivalent — use it for the offset table layout but skip the sscratch dance since we don't switch privilege).

- [ ] **Step 1: Replace the trap_vector stub in `monitor.S`**

```asm
# ---- Trap vector (real) -------------------------------------------------
# Caller-saved register save/restore around a call to snakeTrap (Zig).
# Stack frame: 64 bytes for ra + t0..t6 + a0..a7. (Callee-saved s0..s11
# don't need saving — Zig's `extern` fn convention preserves them.)

.balign 4
.globl trap_vector
trap_vector:
    addi    sp, sp, -64
    sw      ra,  0(sp)
    sw      t0,  4(sp)
    sw      t1,  8(sp)
    sw      t2, 12(sp)
    sw      a0, 16(sp)
    sw      a1, 20(sp)
    sw      a2, 24(sp)
    sw      a3, 28(sp)
    sw      a4, 32(sp)
    sw      a5, 36(sp)
    sw      a6, 40(sp)
    sw      a7, 44(sp)
    sw      t3, 48(sp)
    sw      t4, 52(sp)
    sw      t5, 56(sp)
    sw      t6, 60(sp)

    call    snakeTrap

    lw      ra,  0(sp)
    lw      t0,  4(sp)
    lw      t1,  8(sp)
    lw      t2, 12(sp)
    lw      a0, 16(sp)
    lw      a1, 20(sp)
    lw      a2, 24(sp)
    lw      a3, 28(sp)
    lw      a4, 32(sp)
    lw      a5, 36(sp)
    lw      a6, 40(sp)
    lw      a7, 44(sp)
    lw      t3, 48(sp)
    lw      t4, 52(sp)
    lw      t5, 56(sp)
    lw      t6, 60(sp)
    addi    sp, sp, 64
    mret
```

- [ ] **Step 2: Add a no-op `snakeTrap` to `snake.zig`**

Replace the placeholder `comptime { @export(...) }` block with:

```zig
// tests/programs/snake/snake.zig
//
// Freestanding M-mode snake. Zig side of the program: trap dispatch,
// I/O, and game state.

const game_mod = @import("game.zig");

export fn snakeTrap() callconv(.c) void {
    // T11 fills this in. For now, just return — the trap_vector
    // restores regs and mrets back to the wfi loop, where we'll
    // immediately wfi again until the NEXT interrupt fires (which
    // it won't, because we haven't reprogrammed mtimecmp).
}
```

- [ ] **Step 3: Build and verify**

```bash
zig build snake-elf
```

Expected: clean build. (Linker resolves `snakeTrap` because the C-ABI export emits a non-mangled symbol.)

- [ ] **Step 4: Smoke-test**

```bash
timeout 1 zig build run -- zig-out/bin/snake.elf
echo "exit=$?"
```

Expected: exit 124 (still idling). With `--trace`, you should see one MTI at ~tick 1.25M and the trap returning to wfi.

- [ ] **Step 5: Commit**

```bash
git add tests/programs/snake/monitor.S tests/programs/snake/snake.zig
git commit -m "snake: real trap_vector (save/restore + call snakeTrap)"
```

---

## Task 11: `snakeTrap` dispatcher + halt helper + game state

**Files:** `tests/programs/snake/snake.zig`

Wire up: a module-level `Game` instance, a halt helper that writes to `tohost`, and a `snakeTrap` that on the first tick halts the emulator. This proves the trap path works end-to-end before we add any rendering.

- [ ] **Step 1: Update `snake.zig`**

```zig
// tests/programs/snake/snake.zig
//
// Freestanding M-mode snake. Zig side of the program: trap dispatch,
// I/O, and game state.

const game_mod = @import("game.zig");

// Module-level state (lives in .bss, zeroed by monitor.S).
var game: game_mod.Game = undefined;
var initialized: bool = false;
var quit_requested: bool = false;

// MMIO addresses (must match src/memory.zig + src/devices/*.zig).
const MTIME_LOW: u32 = 0x0200_BFF8;
const MTIMECMP_LOW: u32 = 0x0200_4000;
const TICK_PERIOD: u32 = 1_250_000;  // 125 ms @ 10 MHz

// `tohost` is a linker-resolved symbol; the ELF loader resolves writes
// to its address into the halt MMIO. Match the riscv-tests convention:
// store value 1 → exit code 0.
extern var tohost: u32;

fn halt() noreturn {
    tohost = 1;
    while (true) {}
}

fn advanceMtimecmp() void {
    // Read current mtime, add period, write to mtimecmp. Same carry
    // handling as monitor.S's initial program.
    const mt_low_ptr: *volatile u32 = @ptrFromInt(MTIME_LOW);
    const mt_high_ptr: *volatile u32 = @ptrFromInt(MTIME_LOW + 4);
    const mtcmp_low_ptr: *volatile u32 = @ptrFromInt(MTIMECMP_LOW);
    const mtcmp_high_ptr: *volatile u32 = @ptrFromInt(MTIMECMP_LOW + 4);

    const lo = mt_low_ptr.*;
    const hi = mt_high_ptr.*;
    const new_lo = lo +% TICK_PERIOD;
    const carry: u32 = if (new_lo < TICK_PERIOD) 1 else 0;
    mtcmp_low_ptr.* = new_lo;
    mtcmp_high_ptr.* = hi + carry;
}

export fn snakeTrap() callconv(.c) void {
    if (!initialized) {
        game = game_mod.Game.init(.{
            .x = @as(u8, game_mod.PLAY_W) / 2 + 1, // ~16
            .y = @as(u8, game_mod.PLAY_H) / 2 + 1, // ~7
        });
        initialized = true;
    }

    // T13 will replace this with real tick logic. For now: just halt
    // on the first tick to prove the trap path works.
    halt();

    // Unreachable in this task; T13+:
    // advanceMtimecmp();
}
```

- [ ] **Step 2: Build and run**

```bash
zig build snake-elf
zig build run -- zig-out/bin/snake.elf
echo "exit=$?"
```

Expected: program halts after ~125 ms with exit code 0. (No output yet.)

- [ ] **Step 3: Verify trap actually fires (with --trace)**

```bash
zig build run -- --trace zig-out/bin/snake.elf 2>&1 | grep -E "interrupt|tohost|halt" | head -20
```

Expected: see `--- interrupt 7 (machine timer) taken in M, now M ---` followed by a trap dispatch path. Confirms snakeTrap was reached.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/snake/snake.zig
git commit -m "snake: snakeTrap dispatcher, halt helper, halt-on-first-tick smoke"
```

---

## Task 12: Render — clear + home + HUD + 15 board rows

**Files:** `tests/programs/snake/snake.zig`

Implement `render` and call it from `snakeTrap` before halting. After this, the smoke run prints one frame to UART then halts.

The frame is exactly 16 terminal rows: 1 HUD + 15 board (top + bottom border + 13 playable rows interior).

- [ ] **Step 1: Add UART helpers + render to `snake.zig`**

Append after `advanceMtimecmp`:

```zig
const UART_THR: u32 = 0x1000_0000;

fn uartPut(b: u8) void {
    const thr: *volatile u8 = @ptrFromInt(UART_THR);
    thr.* = b;
}

fn uartPutSlice(s: []const u8) void {
    for (s) |b| uartPut(b);
}

fn uartPutDecimal(n: u32) void {
    if (n == 0) {
        uartPut('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var i: usize = 0;
    var v = n;
    while (v > 0) : (v /= 10) {
        buf[i] = @intCast('0' + (v % 10));
        i += 1;
    }
    while (i > 0) {
        i -= 1;
        uartPut(buf[i]);
    }
}

// Frame buffer: 15 rows × 32 cols. Filled by `paint`, written to UART
// by `flush`. Lives in .bss (zeroed by monitor.S).
var frame: [game_mod.H][game_mod.W]u8 = undefined;

fn paint() void {
    // Borders + interior.
    var y: u8 = 0;
    while (y < game_mod.H) : (y += 1) {
        var x: u8 = 0;
        while (x < game_mod.W) : (x += 1) {
            const top_or_bot = (y == 0 or y == game_mod.H - 1);
            const left_or_right = (x == 0 or x == game_mod.W - 1);
            if (top_or_bot and left_or_right) {
                frame[y][x] = '+';
            } else if (top_or_bot) {
                frame[y][x] = '-';
            } else if (left_or_right) {
                frame[y][x] = '|';
            } else {
                frame[y][x] = ' ';
            }
        }
    }
    // Snake body.
    var i: u16 = 0;
    var idx: u16 = game.tail;
    while (i < game.len) : (i += 1) {
        const sx = game.snake_x[idx];
        const sy = game.snake_y[idx];
        if (sx < game_mod.W and sy < game_mod.H) {
            frame[sy][sx] = if (idx == game.head) 'O' else '#';
        }
        idx = (idx + 1) % game_mod.MAX_SNAKE;
    }
    // Food.
    if (game.food) |f| {
        if (f.x < game_mod.W and f.y < game_mod.H) frame[f.y][f.x] = '*';
    }
}

fn render() void {
    paint();
    // Clear screen + home cursor.
    uartPutSlice("\x1b[2J\x1b[H");
    // HUD row.
    uartPutSlice("SNAKE  score: ");
    uartPutDecimal(game.score);
    uartPutSlice("  (q quit)\r\n");
    // Board.
    var y: u8 = 0;
    while (y < game_mod.H) : (y += 1) {
        var x: u8 = 0;
        while (x < game_mod.W) : (x += 1) uartPut(frame[y][x]);
        uartPutSlice("\r\n");
    }
}
```

- [ ] **Step 2: Replace the body of `snakeTrap`**

```zig
export fn snakeTrap() callconv(.c) void {
    if (!initialized) {
        game = game_mod.Game.init(.{
            .x = @as(u8, game_mod.PLAY_W) / 2 + 1,
            .y = @as(u8, game_mod.PLAY_H) / 2 + 1,
        });
        initialized = true;
    }
    render();
    halt(); // T13 removes this; tick loop continues until quit.
}
```

- [ ] **Step 3: Run and visually verify the frame**

```bash
zig build snake-elf
zig build run -- zig-out/bin/snake.elf
```

Expected: the terminal clears, home cursor, then prints:

```
SNAKE  score: 0  (q quit)
+------------------------------+
|                              |
|                              |
... (more rows)
|         O##                  |   ← snake at row ~7, head 'O' at col 16
... (more rows)
+------------------------------+
```

Exit code 0 after one frame (we still halt at the bottom of `snakeTrap`).

- [ ] **Step 4: Commit**

```bash
git add tests/programs/snake/snake.zig
git commit -m "snake: render — CSI 2J/H + HUD + bordered 15-row board"
```

---

## Task 13: Tick loop — advance game per tick (no input yet)

**Files:** `tests/programs/snake/snake.zig`

Remove the `halt()` from `snakeTrap`. Now the trap fires every 125 ms, snake advances right, eventually hits the right wall, transitions to GameOver, and renders the GameOver state. We don't have a quit mechanism yet (T16 adds q), so use the timeout to bail.

GameOver overlay rendering is left for T15 — for now, just render the static GameOver state (snake stops moving, "GAME OVER" not yet shown).

- [ ] **Step 1: Update `snakeTrap`**

```zig
export fn snakeTrap() callconv(.c) void {
    if (!initialized) {
        game = game_mod.Game.init(.{
            .x = @as(u8, game_mod.PLAY_W) / 2 + 1,
            .y = @as(u8, game_mod.PLAY_H) / 2 + 1,
        });
        // Seed RNG with a constant for now; T14 reseeds from mtime
        // on first key press.
        game.rng = 0xDEAD_BEEF;
        game.placeFood();
        initialized = true;
    }

    // T14 will drain input here.

    if (game.state == .Playing and game.game_started) {
        game.applyDirIfLegal();
        _ = game.advance();
    }
    render();

    advanceMtimecmp();
}
```

Note: `game_started` is still false (T14 sets it on first key), so `advance()` won't run yet. Snake stays put forever.

To exercise the wall-collision path manually before T14 lands, temporarily set `game.game_started = true` after `placeFood()`. Verify, then remove.

- [ ] **Step 2: Temporarily force the game to start, run for ~3 seconds, verify wall hit**

Edit `snakeTrap` to insert `game.game_started = true;` right after `game.placeFood();`.

```bash
zig build snake-elf
timeout 3 zig build run -- zig-out/bin/snake.elf
```

Expected: the screen redraws every 125 ms; you see the snake slide right until its head hits the right border, then the snake stops moving (state = GameOver). Score stays 0 unless the snake happened to slide over the food cell (rng=0xDEADBEEF puts food deterministically — check it manually if curious).

- [ ] **Step 3: Revert the temporary `game_started = true`**

Remove the line you added. Re-build. Now the snake stays still indefinitely.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/snake/snake.zig
git commit -m "snake: tick loop — advance + render every 125 ms"
```

---

## Task 14: Drain UART + WASD/q/SPACE input + RNG seed on first key

**Files:** `tests/programs/snake/snake.zig`

Add `drainOneInputByte` (one byte per tick — see spec rationale). On first WASD key of a fresh game, seed RNG from mtime. On `q`, set quit_requested. On SPACE in GameOver, restart (T15 finishes the GAME-OVER overlay; restart logic itself is part of T16).

For now we wire up just the input handling and the q-quit path. SPACE/restart in GameOver state is a no-op until T16.

- [ ] **Step 1: Add `drainOneInputByte` and the input dispatch**

Append after `uartPutDecimal`:

```zig
const UART_RBR: u32 = 0x1000_0000;
const UART_LSR: u32 = 0x1000_0005;

fn drainOneInputByte() void {
    const lsr: *volatile u8 = @ptrFromInt(UART_LSR);
    if ((lsr.* & 0x01) == 0) return; // DR clear → no byte
    const rbr: *volatile u8 = @ptrFromInt(UART_RBR);
    const b = rbr.*;
    handleInput(b);
}

fn readMtimeLow() u32 {
    const p: *volatile u32 = @ptrFromInt(MTIME_LOW);
    return p.*;
}

fn handleInput(b: u8) void {
    if (b == 'q') {
        quit_requested = true;
        return;
    }
    if (b == ' ') {
        // T16 implements restart. For now, ignore SPACE.
        return;
    }
    const new_dir: ?game_mod.Dir = switch (b) {
        'w', 'W' => .Up,
        's', 'S' => .Down,
        'a', 'A' => .Left,
        'd', 'D' => .Right,
        else => null,
    };
    if (new_dir) |d| {
        if (game.state == .Playing) {
            if (!game.game_started) {
                // First key of a fresh game: seed RNG from mtime, place food, start.
                var seed = readMtimeLow();
                if (seed == 0) seed = 1; // xorshift32 degenerate from 0
                game.rng = seed;
                game.placeFood();
                game.game_started = true;
            }
            game.pending_dir = d;
        }
    }
}
```

- [ ] **Step 2: Wire `drainOneInputByte` and the quit path into `snakeTrap`**

Update `snakeTrap` (replace the entire function):

```zig
export fn snakeTrap() callconv(.c) void {
    if (!initialized) {
        game = game_mod.Game.init(.{
            .x = @as(u8, game_mod.PLAY_W) / 2 + 1,
            .y = @as(u8, game_mod.PLAY_H) / 2 + 1,
        });
        initialized = true;
        render(); // initial frame so the player sees the empty board
        advanceMtimecmp();
        return;
    }

    drainOneInputByte();

    if (quit_requested) halt();

    if (game.state == .Playing and game.game_started) {
        game.applyDirIfLegal();
        _ = game.advance();
    }
    render();

    advanceMtimecmp();
}
```

Note: removed the `placeFood()` from init; food placement now happens on first key (which is also when RNG gets seeded — must be in that order).

- [ ] **Step 3: Build, smoke-play in the CLI**

The default tty is line-buffered, so single keystrokes need raw mode. Quick test using `stty`:

```bash
zig build snake-elf
stty -icanon -echo
zig build run -- --input /dev/stdin zig-out/bin/snake.elf
stty sane
```

In a separate terminal you can't easily — `--input` reads bytes from a file/fd. The proper `run-snake` step (T17) wraps stty correctly. For this smoke test, instead use a fixed input file:

```bash
printf 'wddddwq' > /tmp/snake_smoke.txt
zig build run -- --input /tmp/snake_smoke.txt zig-out/bin/snake.elf
```

Expected: program runs (~1 second), screen redraws several times, snake moves up then right then up then quits cleanly with exit 0. Final state is wherever 'q' was processed.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/snake/snake.zig
git commit -m "snake: drain UART input + WASD/q + RNG seed on first key"
```

---

## Task 15: GAME OVER overlay rendering

**Files:** `tests/programs/snake/snake.zig`

When `game.state == .GameOver`, after rendering the playing frame, overlay a centered 5-row × 14-col panel using box-drawing chars. The frame has been built into `frame[][]` already; we just need a second pass that overwrites the relevant cells before flushing.

UTF-8 box-drawing chars used: `╔` (E2 95 94), `═` (E2 95 90), `╗` (E2 95 97), `║` (E2 95 91), `╚` (E2 95 9A), `╝` (E2 95 9D). Each is 3 bytes; the JS-side ANSI interpreter will reassemble them into one screen cell (T23).

Because `frame` is `[H][W]u8` (one byte per cell), we can't directly store multibyte UTF-8 there. Easiest approach: paint the GAME OVER text into `frame[][]` using ASCII placeholders (`+` `-` `|`), then in `flush` (the loop that writes `frame` to UART) detect those placeholder cells and emit the proper UTF-8 sequence instead. Alternative — much simpler — emit the overlay AFTER the main frame is flushed, using `CSI [r;c] H` cursor positioning. But our agreed ANSI subset doesn't include parameterized cursor positioning yet.

Simplest path: emit the overlay characters directly inline in the frame using ASCII (`+`, `-`, `|`). Box-drawing UTF-8 lands when we extend the ANSI subset. Document this and move on — this is a demo, not a typography contest.

- [ ] **Step 1: Add `paintGameOver` + call it from `render`**

```zig
fn paintGameOver() void {
    // Centered 5×14 panel. (W=32, H=15) → top-left at (col 9, row 5).
    const PW: u8 = 14;
    const PH: u8 = 5;
    const col0: u8 = (game_mod.W - PW) / 2;       // 9
    const row0: u8 = (game_mod.H - PH) / 2;       // 5
    var dy: u8 = 0;
    while (dy < PH) : (dy += 1) {
        var dx: u8 = 0;
        while (dx < PW) : (dx += 1) {
            const top    = (dy == 0);
            const bot    = (dy == PH - 1);
            const left   = (dx == 0);
            const right  = (dx == PW - 1);
            const c: u8 = if ((top or bot) and (left or right)) '+'
                else if (top or bot) '-'
                else if (left or right) '|'
                else ' ';
            frame[row0 + dy][col0 + dx] = c;
        }
    }
    // Lines: row0+1: "  GAME OVER  "
    //        row0+2: "  score: N    "
    //        row0+3: "  SPC retry  "
    const msg1 = "GAME OVER";
    const msg2_prefix = "score: ";
    const msg3 = "SPC retry";

    // row0+1: "GAME OVER" centered in inner 12 cols.
    {
        const inner = PW - 2; // 12
        const start = col0 + 1 + (inner - @as(u8, @intCast(msg1.len))) / 2;
        for (msg1, 0..) |c, i| frame[row0 + 1][start + @as(u8, @intCast(i))] = c;
    }
    // row0+2: "score: N"
    {
        var col = col0 + 2;
        for (msg2_prefix) |c| {
            frame[row0 + 2][col] = c;
            col += 1;
        }
        // Decimal score, up to 5 digits.
        var n = game.score;
        var digits: [5]u8 = undefined;
        var ndigits: usize = 0;
        if (n == 0) {
            digits[0] = '0';
            ndigits = 1;
        } else while (n > 0) : (n /= 10) {
            digits[ndigits] = @intCast('0' + (n % 10));
            ndigits += 1;
        }
        var di = ndigits;
        while (di > 0) {
            di -= 1;
            frame[row0 + 2][col] = digits[di];
            col += 1;
        }
    }
    // row0+3: "SPC retry"
    {
        const inner = PW - 2;
        const start = col0 + 1 + (inner - @as(u8, @intCast(msg3.len))) / 2;
        for (msg3, 0..) |c, i| frame[row0 + 3][start + @as(u8, @intCast(i))] = c;
    }
}
```

Update `render` to call `paintGameOver` after `paint`:

```zig
fn render() void {
    paint();
    if (game.state == .GameOver) paintGameOver();
    uartPutSlice("\x1b[2J\x1b[H");
    uartPutSlice("SNAKE  score: ");
    uartPutDecimal(game.score);
    uartPutSlice("  (q quit)\r\n");
    var y: u8 = 0;
    while (y < game_mod.H) : (y += 1) {
        var x: u8 = 0;
        while (x < game_mod.W) : (x += 1) uartPut(frame[y][x]);
        uartPutSlice("\r\n");
    }
}
```

- [ ] **Step 2: Smoke test**

```bash
zig build snake-elf
printf 'ddddddddddddddddddddddwwwwwwwwwwwq' > /tmp/snake_overlay.txt
zig build run -- --input /tmp/snake_overlay.txt zig-out/bin/snake.elf | tail -20
```

Expected: in the final frames, you see the GAME OVER panel overlaid on the board. The lines visible at the end should include "GAME OVER" and "score: 0".

- [ ] **Step 3: Commit**

```bash
git add tests/programs/snake/snake.zig
git commit -m "snake: GAME OVER overlay (5×14 ASCII panel)"
```

---

## Task 16: SPACE restart in GameOver state

**Files:** `tests/programs/snake/snake.zig`

When game is in `GameOver` and player presses SPACE, reset board / snake / score / state. Keep the seeded `rng` so play across restarts feels different.

- [ ] **Step 1: Add `Game.restart` to `game.zig`**

In `tests/programs/snake/game.zig`, inside `Game`:

```zig
    pub fn restart(self: *Game, spawn: Cell) void {
        const saved_rng = self.rng;
        self.* = Game.init(spawn);
        self.rng = saved_rng;
        // Re-place food immediately if rng is seeded — otherwise wait
        // until first key press in the new game.
        if (saved_rng != 0) {
            self.game_started = true;
            self.placeFood();
        }
    }
```

- [ ] **Step 2: Add a test for `restart`**

```zig
test "restart: preserves rng, resets score/len/state" {
    var g = Game.init(.{ .x = 16, .y = 7 });
    g.rng = 0xCAFE;
    g.score = 42;
    g.len = 8;
    g.state = .GameOver;
    g.restart(.{ .x = 16, .y = 7 });
    try std.testing.expectEqual(@as(u32, 0xCAFE), g.rng);
    try std.testing.expectEqual(@as(u32, 0), g.score);
    try std.testing.expectEqual(@as(u16, 3), g.len);
    try std.testing.expectEqual(State.Playing, g.state);
    try std.testing.expect(g.food != null);
}
```

```bash
zig build snake-test
```

Expected: PASS.

- [ ] **Step 3: Wire SPACE in `snake.zig` `handleInput`**

Replace the `b == ' '` branch:

```zig
    if (b == ' ') {
        if (game.state == .GameOver) {
            game.restart(.{
                .x = @as(u8, game_mod.PLAY_W) / 2 + 1,
                .y = @as(u8, game_mod.PLAY_H) / 2 + 1,
            });
        }
        return;
    }
```

- [ ] **Step 4: Smoke-test restart**

```bash
zig build snake-elf
# Drive into a wall, then SPACE to restart, then move and quit.
printf 'ddddddddddddddddddwwwwwwwwwwwww qaq' > /tmp/snake_restart.txt
# (note the literal space ^ between 'wwwww' and 'qaq')
zig build run -- --input /tmp/snake_restart.txt zig-out/bin/snake.elf | tail -25
```

Expected: see GAME OVER overlay, then a fresh snake on a clean board, then the snake moves left a bit, then quits.

- [ ] **Step 5: Commit**

```bash
git add tests/programs/snake/game.zig tests/programs/snake/snake.zig
git commit -m "snake: SPACE-to-restart preserves RNG"
```

---

## Task 17: `run-snake` build target with stty raw mode wrapper

**Files:**
- Create: `scripts/run-snake.sh`
- Modify: `build.zig` (add `run-snake` step that invokes the script)

The script puts the controlling tty in `-icanon -echo` mode so single keystrokes reach `--input /dev/stdin`. On exit (clean or signaled) it restores `stty sane`.

- [ ] **Step 1: Create `scripts/run-snake.sh`**

```bash
#!/usr/bin/env bash
# Wrapper around `ccc --input /dev/stdin snake.elf` that puts the tty
# in raw mode so single keystrokes reach the program.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

CCC="$ROOT/zig-out/bin/ccc"
SNAKE="$ROOT/zig-out/bin/snake.elf"

if [[ ! -x "$CCC" || ! -f "$SNAKE" ]]; then
  echo "missing artifacts; run 'zig build snake-elf' first" >&2
  exit 1
fi

# Save current tty settings; restore on exit (incl. Ctrl+C).
SAVED_STTY=$(stty -g)
trap 'stty "$SAVED_STTY"' EXIT INT TERM

stty -icanon -echo
exec "$CCC" --input /dev/stdin "$SNAKE"
```

```bash
chmod +x scripts/run-snake.sh
```

- [ ] **Step 2: Add `run-snake` step to `build.zig`**

Append after the snake-test block:

```zig
    const run_snake_cmd = b.addSystemCommand(&.{
        "bash",
        "scripts/run-snake.sh",
    });
    run_snake_cmd.step.dependOn(b.getInstallStep());
    run_snake_cmd.step.dependOn(&install_snake_elf.step);
    const run_snake_step = b.step("run-snake", "Play snake.elf in the CLI (tty raw mode)");
    run_snake_step.dependOn(&run_snake_cmd.step);
```

- [ ] **Step 3: Manual smoke test**

```bash
zig build run-snake
# Press w/a/s/d to move, eat food, hit a wall, see GAME OVER, SPACE to retry, q to quit.
```

Expected: a fully playable game in your terminal. If you can't make the snake change direction, stty isn't taking effect — verify `scripts/run-snake.sh` is being invoked (add `echo "stty=$(stty -g)" >&2` for debugging).

- [ ] **Step 4: Commit**

```bash
git add scripts/run-snake.sh build.zig
git commit -m "snake: run-snake build target (stty raw-mode wrapper)"
```

---

## Task 18: `test_input.txt` + `verify_e2e.zig`

**Files:**
- Create: `tests/programs/snake/test_input.txt`
- Create: `tests/programs/snake/verify_e2e.zig`

Reference: `tests/programs/kernel/verify_e2e.zig` for the host-compiled verifier pattern.

- [ ] **Step 1: Create `tests/programs/snake/test_input.txt`**

```
ddddddddwwwwwwwwwwwwwwwwwwwwwq
```

(no trailing newline — paste as a file with exactly 30 bytes)

```bash
printf 'ddddddddwwwwwwwwwwwwwwwwwwwwwq' > tests/programs/snake/test_input.txt
wc -c tests/programs/snake/test_input.txt
```

Expected: 30 bytes.

The sequence is `d×8 w×21 q`. With drain-one-byte-per-tick: each byte consumes one tick. The snake spawns at (16, 7) length 3 facing Right. After d×8 the snake is heading right but its head is around x=24 (well within bounds). After 1 w it turns up. After ~7 more w's the head reaches the top border and dies on the 8th w. The remaining w's are queued in GameOver state and ignored. Final q quits.

(Tune the d-count or w-count if your spawn position differs — the assertions below don't depend on exact path, only on `GAME OVER` and `score: 0` appearing.)

- [ ] **Step 2: Create `tests/programs/snake/verify_e2e.zig`**

```zig
//! Host-compiled verifier for `zig build e2e-snake`. Runs
//! `ccc --input test_input.txt snake.elf`, captures stdout,
//! asserts the trailing frame contains "GAME OVER" and "score: 0".

const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var args = try std.process.argsWithAllocator(a);
    defer args.deinit();
    _ = args.next(); // skip argv[0]
    const ccc_path = args.next() orelse return error.MissingCccPath;
    const snake_path = args.next() orelse return error.MissingSnakePath;
    const input_path = args.next() orelse return error.MissingInputPath;

    var child = std.process.Child.init(&.{ ccc_path, "--input", input_path, snake_path }, a);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout_buf: std.ArrayList(u8) = .{};
    var stderr_buf: std.ArrayList(u8) = .{};
    try child.collectOutput(a, &stdout_buf, &stderr_buf, 1 * 1024 * 1024);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("snake.elf exited with code {d}\nstderr:\n{s}\n", .{ code, stderr_buf.items });
            return error.NonZeroExit;
        },
        else => {
            std.debug.print("snake.elf terminated abnormally: {any}\n", .{term});
            return error.AbnormalTermination;
        },
    }

    const out = stdout_buf.items;
    if (std.mem.indexOf(u8, out, "GAME OVER") == null) {
        std.debug.print("expected 'GAME OVER' in stdout. last 500 bytes:\n{s}\n",
            .{out[if (out.len > 500) out.len - 500 else 0..]});
        return error.NoGameOver;
    }
    if (std.mem.indexOf(u8, out, "score: 0") == null) {
        std.debug.print("expected 'score: 0' in stdout\n", .{});
        return error.WrongScore;
    }
    // Print PASS line so build output shows progress.
    try std.io.getStdOut().writer().print("e2e-snake: PASS ({d} bytes captured)\n", .{out.len});
}
```

Note: this file uses `std.io.getStdOut().writer()` which has been available since Zig 0.16. If you see a deprecation warning, switch to `std.fs.File.stdout().writer(...)` per the convention used in other `verify_e2e.zig` files in this repo (check `tests/programs/kernel/verify_e2e.zig` for the current idiom).

- [ ] **Step 3: Commit (the e2e build target lands in T19)**

```bash
git add tests/programs/snake/test_input.txt tests/programs/snake/verify_e2e.zig
git commit -m "snake: e2e test input + host-compiled verifier"
```

---

## Task 19: `e2e-snake` build target

**Files:** `build.zig`

- [ ] **Step 1: Append `e2e-snake` block to `build.zig`**

After the `run-snake` block:

```zig
    const snake_verify_e2e = b.addExecutable(.{
        .name = "snake_verify_e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/snake/verify_e2e.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const e2e_snake_run = b.addRunArtifact(snake_verify_e2e);
    e2e_snake_run.addFileArg(exe.getEmittedBin());
    e2e_snake_run.addFileArg(snake_elf.getEmittedBin());
    e2e_snake_run.addFileArg(b.path("tests/programs/snake/test_input.txt"));
    e2e_snake_run.expectExitCode(0);

    const e2e_snake_step = b.step("e2e-snake", "Run snake e2e (deterministic input → GAME OVER + score:0)");
    e2e_snake_step.dependOn(&e2e_snake_run.step);
```

- [ ] **Step 2: Run e2e**

```bash
zig build e2e-snake
```

Expected: ~4 seconds (the wall-clock duration we noted in the spec — drain-one-byte-per-tick × 8 Hz × 30 bytes), then `e2e-snake: PASS (N bytes captured)`.

If the test fails, the verifier prints the last 500 bytes of stdout and a specific error. Most likely tuning issues:
- `NoGameOver`: snake didn't hit a wall. Increase the `w` count in `test_input.txt`.
- `WrongScore`: snake accidentally ate food. Adjust the `d`/`w` counts to avoid food cells (depends on your `0xDEADBEEF`-seeded path; once T14's mtime-seed is in effect, food is at unpredictable positions but the path of `dddd...wwww` rarely crosses them).

- [ ] **Step 3: Verify all existing tests still pass**

```bash
zig build test
zig build e2e-hello-elf
zig build e2e-kernel
zig build e2e-plic-block
zig build snake-test
```

Expected: all green. Snake hasn't touched any emulator-core files yet, so this is a sanity check.

- [ ] **Step 4: Commit**

```bash
git add build.zig
git commit -m "snake: zig build e2e-snake"
```

---

## Task 20: Add `e2e-snake` to CI

**Files:** `.github/workflows/pages.yml`

- [ ] **Step 1: Read the workflow file**

```bash
cat .github/workflows/pages.yml
```

- [ ] **Step 2: Find the test matrix step that runs the existing `e2e-*` builds**

It should look like:

```yaml
      - run: zig build test
      - run: zig build e2e-hello-elf
      - run: zig build e2e-kernel
      - run: zig build e2e-plic-block
```

- [ ] **Step 3: Add `zig build e2e-snake` and `zig build snake-test` to the same matrix**

```yaml
      - run: zig build test
      - run: zig build snake-test
      - run: zig build e2e-hello-elf
      - run: zig build e2e-kernel
      - run: zig build e2e-plic-block
      - run: zig build e2e-snake
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/pages.yml
git commit -m "ci: add snake-test and e2e-snake to PR gate"
```

---

## Task 21: Refactor `demo/web_main.zig` — module-level state + `runStart`/`runStep`

**Files:** `demo/web_main.zig` (rewrite most of it)

The existing `run(trace)` builds the emulator on the stack and blocks until halt. We're replacing it with module-level emulator state plus `runStart` / `runStep`.

After this task: `runStart(0, 0)` initializes for `hello.elf`; a JS loop calling `runStep(N)` drains output via `consumeOutput`. The browser `web/demo.js` doesn't change yet, so the live hello.elf demo will be temporarily broken. T22 + T26 fix it.

- [ ] **Step 1: Read the current `demo/web_main.zig`**

```bash
cat demo/web_main.zig
```

- [ ] **Step 2: Rewrite `demo/web_main.zig`**

```zig
//! Freestanding wasm entry point. Replaces the original blocking
//! run() with chunked runStart / runStep so the JS Worker can
//! turn the simulation crank itself, draining output and forwarding
//! input between turns. See
//! docs/superpowers/specs/2026-04-25-snake-demo-design.md
//! "Wasm loop architecture (chunked execution)" for rationale.

const std = @import("std");
const ccc = @import("ccc");
const cpu_mod = ccc.cpu;
const mem_mod = ccc.memory;
const halt_dev = ccc.halt;
const uart_dev = ccc.uart;
const clint_dev = ccc.clint;
const plic_dev = ccc.plic;
const block_dev = ccc.block;
const elf_mod = ccc.elf;

const hello_elf = @import("hello_elf").BLOB;
// snake_elf import lands in T22 along with selectProgram.

const OUTPUT_BUF_SIZE: usize = 16 * 1024;
var output_buf: [OUTPUT_BUF_SIZE]u8 = undefined;
var output_writer: std.Io.Writer = .fixed(&output_buf);
var output_consumed: usize = 0;

const TRACE_BUF_SIZE: usize = 8 * 1024 * 1024;
var trace_buf: [TRACE_BUF_SIZE]u8 = undefined;
var trace_writer: std.Io.Writer = .fixed(&trace_buf);

const RAM_SIZE: usize = 16 * 1024 * 1024;

// Module-level mtime source — JS sets it via setMtimeNs.
var mtime_ns: i128 = 0;
fn jsClock() i128 {
    return mtime_ns;
}

// Module-level emulator state. All optional; runStart populates them,
// runStep drives them, runStep returns the exit code when the program
// halts (and clears them on the next runStart).
const RunState = struct {
    arena: std.heap.ArenaAllocator,
    halt: halt_dev.Halt,
    uart: uart_dev.Uart,
    clint: clint_dev.Clint,
    plic: plic_dev.Plic,
    block: block_dev.Block,
    mem: mem_mod.Memory,
    cpu: cpu_mod.Cpu,
};

var state_storage: RunState = undefined;
var state: ?*RunState = null;

export fn outputPtr() [*]const u8 {
    return @ptrCast(&output_buf[output_consumed]);
}

export fn consumeOutput() u32 {
    const len = output_writer.end - output_consumed;
    output_consumed = output_writer.end;
    // Rewind: if JS has fully drained, reset both cursors so the buffer
    // doesn't fill up over a long-running snake session.
    if (output_consumed == output_writer.end) {
        output_writer.end = 0;
        output_consumed = 0;
    }
    return @intCast(len);
}

export fn tracePtr() [*]const u8 {
    return &trace_buf;
}

export fn traceLen() u32 {
    return @intCast(trace_writer.end);
}

export fn setMtimeNs(ns: i64) void {
    mtime_ns = @intCast(ns);
}

export fn runStart(program_idx: u32, trace: i32) i32 {
    _ = program_idx; // T22 uses this to switch between hello and snake
    output_writer.end = 0;
    output_consumed = 0;
    trace_writer.end = 0;
    mtime_ns = 0;

    state_storage.arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    const a = state_storage.arena.allocator();

    state_storage.halt = halt_dev.Halt.init();
    state_storage.uart = uart_dev.Uart.init(&output_writer);
    state_storage.clint = clint_dev.Clint.init(&jsClock);
    state_storage.plic = plic_dev.Plic.init();
    state_storage.block = block_dev.Block.init();

    const io: std.Io = std.Io.failing;

    state_storage.mem = mem_mod.Memory.init(
        a, &state_storage.halt, &state_storage.uart,
        &state_storage.clint, &state_storage.plic, &state_storage.block,
        io, null, RAM_SIZE,
    ) catch return -1;

    const result = elf_mod.parseAndLoad(hello_elf, &state_storage.mem) catch return -2;
    state_storage.mem.tohost_addr = result.tohost_addr;

    state_storage.cpu = cpu_mod.Cpu.init(&state_storage.mem, result.entry);
    if (trace != 0) state_storage.cpu.trace_writer = &trace_writer;

    state = &state_storage;
    return 0;
}

export fn runStep(max_instructions: u32) i32 {
    const s = state orelse return -1;
    var i: u32 = 0;
    while (i < max_instructions) : (i += 1) {
        if (s.halt.exit_code) |code| {
            output_writer.flush() catch {};
            if (s.cpu.trace_writer) |tw| tw.flush() catch {};
            // Tear down. Next runStart will rebuild.
            s.mem.deinit();
            s.arena.deinit();
            state = null;
            return @intCast(code);
        }
        s.cpu.stepOne() catch return -3;
    }
    return -1; // still running
}
```

**Note:** `cpu.stepOne()` may not exist in the current `src/cpu.zig`. Check by running:

```bash
grep -nE "pub fn (step|run|stepOne)" src/cpu.zig
```

If `stepOne` doesn't exist, you have two options:
- **(A) Add it to `src/cpu.zig`**: a single-instruction wrapper around the existing instruction-fetch + decode + execute path. This is the "right" change but touches the emulator core. Add tests under the existing `src/cpu.zig` tests if you go this route.
- **(B) Use a new "instruction budget" param on `cpu.run`**: call `s.cpu.run()` with a max-instruction limit; runStep simply calls `cpu.run(N)` and lets the existing run loop honor the budget.

Option B is less invasive. Look at `src/cpu.zig`'s `pub fn run(...)` signature — if it has a max-cycles parameter or similar, use that. If not, adding `stepOne` is the cleanest path. Document the choice in the commit message.

- [ ] **Step 3: Build the wasm to verify compile**

```bash
zig build wasm
```

Expected: clean compile. The browser demo will be broken at runtime (demo.js still calls `run()`), but that's fixed in T26.

- [ ] **Step 4: Commit**

```bash
git add demo/web_main.zig src/cpu.zig  # if you added stepOne
git commit -m "wasm: refactor to module-level state + runStart/runStep"
```

---

## Task 22: `setMtimeNs`, `pushInput`, `selectProgram`, embed `snake.elf`

**Files:**
- Modify: `demo/web_main.zig` (add input forwarding + program selection)
- Modify: `build.zig` (embed snake.elf in wasm alongside hello.elf)

`setMtimeNs` was already added in T21. This task adds the remaining exports.

- [ ] **Step 1: Add `pushInput` and `selectProgram` to `demo/web_main.zig`**

After the existing exports, append:

```zig
export fn pushInput(byte: u32) void {
    if (state) |s| {
        _ = s.uart.pushRx(@intCast(byte));
    }
}

// Program selection — must be called before runStart, since runStart
// loads whichever ELF this last set.
var selected_idx: u32 = 0;
export fn selectProgram(idx: u32) void {
    selected_idx = idx;
}
```

Modify `runStart` to use `selected_idx`:

```zig
    const elf_blob: []const u8 = switch (selected_idx) {
        0 => hello_elf,
        1 => snake_elf,
        else => return -4,
    };
    const result = elf_mod.parseAndLoad(elf_blob, &state_storage.mem) catch return -2;
```

(Replace the existing `parseAndLoad(hello_elf, ...)` line with the above.)

Add the snake_elf import near the top of the file:

```zig
const snake_elf = @import("snake_elf").BLOB;
```

- [ ] **Step 2: Embed `snake.elf` in the wasm build**

Modify `build.zig`. Find the existing `hello_blob_dir` block (~line 609). After it, add:

```zig
    const snake_blob_dir = b.addWriteFiles();
    const snake_blob_zig = snake_blob_dir.add(
        "snake_elf.zig",
        "pub const BLOB = @embedFile(\"snake.elf\");\n",
    );
    _ = snake_blob_dir.addCopyFile(snake_elf.getEmittedBin(), "snake.elf");
    wasm_exe.root_module.addAnonymousImport("snake_elf", .{
        .root_source_file = snake_blob_zig,
    });
```

Then add a dependency:

```zig
    install_wasm.step.dependOn(&install_snake_elf.step);
```

(There's already a similar `install_wasm.step.dependOn(&install_hello_elf.step);` line — add the snake one alongside it.)

- [ ] **Step 3: Build wasm and confirm**

```bash
zig build wasm
ls -lh zig-out/web/ccc.wasm
```

Expected: clean build; wasm is bigger than before (now embeds two ELFs).

- [ ] **Step 4: Commit**

```bash
git add demo/web_main.zig build.zig
git commit -m "wasm: pushInput, selectProgram, embed snake.elf"
```

---

## Task 23: `web/ansi.js` — ANSI subset interpreter

**Files:** Create `web/ansi.js`

Pure-JS module exporting a class. State machine over a 32×16 char screen + UTF-8 reassembly. ~120 lines.

- [ ] **Step 1: Create `web/ansi.js`**

```javascript
// web/ansi.js
//
// Minimal ANSI interpreter: enough escape sequences for snake's
// full-redraw rendering. State machine walks bytes; CSI sequences
// recognized:
//   ESC [ 2 J     → clear screen
//   ESC [ H       → cursor (0,0)
//   ESC [ r;c H   → cursor (r-1, c-1)
//   ESC [ ? 25 l  → hide cursor (no-op visually)
//   ESC [ ? 25 h  → show cursor (no-op)
// Unrecognized sequences are consumed and ignored.
//
// UTF-8 multibyte sequences (lead byte 0xC0–0xF7) are reassembled
// into a single screen cell so box-drawing chars render correctly.

export class Ansi {
  constructor(width, height) {
    this.W = width;
    this.H = height;
    this.screen = new Array(height);
    this._reset();
    this.row = 0;
    this.col = 0;
    this.state = "GROUND";
    this.csiBuf = "";
    this.utf8Pending = null;
  }

  _reset() {
    for (let r = 0; r < this.H; r++) {
      this.screen[r] = new Array(this.W).fill(" ");
    }
  }

  feed(bytes) {
    for (const b of bytes) this._byte(b);
  }

  _byte(b) {
    if (this.state === "GROUND") {
      if (b === 0x1b) { this.state = "ESC"; return; }
      if (b === 0x0a) { this.row = Math.min(this.H - 1, this.row + 1); return; }
      if (b === 0x0d) { this.col = 0; return; }
      if (b < 0x20)   return; // other control: ignore
      if (b >= 0x80) { this._utf8Continue(b); return; }
      if (b >= 0xC0) { this._utf8Start(b); return; }
      this._writeCell(String.fromCharCode(b));
      return;
    }
    if (this.state === "ESC") {
      if (b === 0x5b) { this.state = "CSI"; this.csiBuf = ""; return; }
      this.state = "GROUND"; // unknown ESC sequence, abort
      return;
    }
    if (this.state === "CSI") {
      // Final byte: any of 0x40–0x7E.
      if (b >= 0x40 && b <= 0x7e) {
        this._csi(String.fromCharCode(b), this.csiBuf);
        this.state = "GROUND";
        this.csiBuf = "";
        return;
      }
      this.csiBuf += String.fromCharCode(b);
      return;
    }
  }

  _utf8Start(lead) {
    let need;
    if      ((lead & 0xE0) === 0xC0) need = 1;
    else if ((lead & 0xF0) === 0xE0) need = 2;
    else if ((lead & 0xF8) === 0xF0) need = 3;
    else { return; } // malformed; ignore
    this.utf8Pending = { bytes: [lead], need };
  }

  _utf8Continue(b) {
    if (!this.utf8Pending) return;
    this.utf8Pending.bytes.push(b);
    this.utf8Pending.need -= 1;
    if (this.utf8Pending.need === 0) {
      const arr = new Uint8Array(this.utf8Pending.bytes);
      const ch = new TextDecoder().decode(arr);
      this.utf8Pending = null;
      this._writeCell(ch);
    }
  }

  _writeCell(ch) {
    if (this.row >= this.H) return;
    if (this.col >= this.W) {
      this.col = 0;
      this.row += 1;
      if (this.row >= this.H) return;
    }
    this.screen[this.row][this.col] = ch;
    this.col += 1;
  }

  _csi(final, params) {
    if (final === "J" && params === "2") { this._reset(); return; }
    if (final === "H") {
      if (params === "" || params === "1;1") {
        this.row = 0; this.col = 0; return;
      }
      const m = params.match(/^(\d+);(\d+)$/);
      if (m) {
        this.row = Math.max(0, Math.min(this.H - 1, parseInt(m[1], 10) - 1));
        this.col = Math.max(0, Math.min(this.W - 1, parseInt(m[2], 10) - 1));
      }
      return;
    }
    // ?25l, ?25h, anything else: ignore.
  }

  text() {
    return this.screen.map((row) => row.join("")).join("\n");
  }
}
```

- [ ] **Step 2: Sanity-check with a quick console eval**

(Optional — no automated test per spec.) Open `web/ansi.js` in a browser console:

```javascript
const { Ansi } = await import('./ansi.js');
const a = new Ansi(8, 3);
a.feed([0x1b, 0x5b, 0x32, 0x4a]); // CSI 2 J
a.feed([0x48, 0x69]);              // "Hi"
console.log(a.text());
```

Expected: top-left two cells are `Hi`, rest spaces.

- [ ] **Step 3: Commit**

```bash
git add web/ansi.js
git commit -m "web: ANSI subset interpreter (full-redraw + UTF-8)"
```

---

## Task 24: `web/runner.js` — Web Worker chunked loop

**Files:** Create `web/runner.js`

Hosts the wasm; runs the chunked `runStep` loop; receives `select` / `start` / `input` messages from the main thread; posts `output` and `halt` back.

- [ ] **Step 1: Create `web/runner.js`**

```javascript
// web/runner.js — Web Worker that hosts ccc.wasm and turns the
// chunked-step crank. See the spec's "Wasm loop architecture"
// section for the rationale.

let exports = null;
let memory = null;

self.onmessage = async (e) => {
  const msg = e.data;
  if (msg.type === "init") {
    const resp = await fetch(msg.wasmUrl);
    const bytes = await resp.arrayBuffer();
    const result = await WebAssembly.instantiate(bytes, {});
    exports = result.instance.exports;
    memory = exports.memory;
    self.postMessage({ type: "ready" });
    return;
  }
  if (!exports) return;

  if (msg.type === "select") {
    exports.selectProgram(msg.idx);
    return;
  }
  if (msg.type === "start") {
    const trace = msg.trace ? 1 : 0;
    const rc = exports.runStart(msg.idx, trace);
    if (rc !== 0) {
      self.postMessage({ type: "halt", code: rc });
      return;
    }
    runLoop();
    return;
  }
  if (msg.type === "input") {
    exports.pushInput(msg.byte);
    return;
  }
};

function runLoop() {
  const startMs = performance.now();
  const CHUNK = 50000;

  function tick() {
    const elapsedNs = BigInt(Math.round((performance.now() - startMs) * 1e6));
    exports.setMtimeNs(elapsedNs);
    const exit = exports.runStep(CHUNK);
    drain();
    if (exit !== -1) {
      self.postMessage({ type: "halt", code: exit });
      return;
    }
    setTimeout(tick, 0);
  }
  tick();
}

function drain() {
  const len = exports.consumeOutput();
  if (len === 0) return;
  const ptr = exports.outputPtr();
  // Copy out — message-passing transfer requires a fresh buffer
  // since `memory` is shared with the wasm and might move (it can't,
  // but explicit copy is safe).
  const slice = new Uint8Array(memory.buffer, ptr, len);
  const copy = new Uint8Array(slice); // copies via constructor
  self.postMessage({ type: "output", bytes: copy }, [copy.buffer]);
}
```

- [ ] **Step 2: Commit (manual verification happens in T27)**

```bash
git add web/runner.js
git commit -m "web: runner.js Web Worker (chunked runStep + drain)"
```

---

## Task 25: `web/index.html` + `web/demo.css` — UI scaffolding

**Files:**
- Modify: `web/index.html`
- Modify: `web/demo.css`

Add the `<select>` (default `snake.elf`), make the `<pre>` focusable, add a "click to play" hint that hides on focus.

- [ ] **Step 1: Read current HTML**

```bash
cat web/index.html
```

- [ ] **Step 2: Add `<select>` and focus-hint markup**

Inside the existing terminal-styled section (above the `<pre>`), add:

```html
<div class="program-selector">
  <label for="program-select">program:</label>
  <select id="program-select">
    <option value="1" selected>snake.elf</option>
    <option value="0">hello.elf</option>
  </select>
  <span class="program-hint">(click the terminal to play)</span>
</div>
```

Modify the existing `<pre>` (probably has id="output" or similar) to add `tabindex="0"`:

```html
<pre id="output" tabindex="0"></pre>
```

- [ ] **Step 3: Append focus styling to `web/demo.css`**

```css
.program-selector {
  margin-bottom: 0.5rem;
  font-family: var(--mono, monospace);
  color: var(--ink, #cccccc);
}
.program-selector select {
  background: transparent;
  color: inherit;
  border: 1px solid currentColor;
  padding: 0.1rem 0.3rem;
  font-family: inherit;
  font-size: inherit;
}
.program-hint {
  margin-left: 0.5rem;
  opacity: 0.6;
}
#output {
  outline: none;
  cursor: text;
}
#output:focus {
  outline: 2px solid var(--accent, #66ff99);
  outline-offset: 2px;
}
#output:focus + .program-hint, /* if hint moves below */
.program-selector .program-hint.hidden {
  display: none;
}
```

- [ ] **Step 4: Commit**

```bash
git add web/index.html web/demo.css
git commit -m "web: program selector + focusable terminal + click hint"
```

---

## Task 26: Rewrite `web/demo.js`

**Files:** `web/demo.js` (rewrite)

Wire it all together: load the Worker, pass select changes through, intercept WASD/q/Space when the `<pre>` is focused, feed Worker output bytes into `Ansi`, render `<pre>.textContent`.

- [ ] **Step 1: Rewrite `web/demo.js`**

```javascript
// web/demo.js — main thread: Worker host + terminal renderer.

import { Ansi } from "./ansi.js";

const W = 32, H = 16;
const ansi = new Ansi(W, H);
const out = document.getElementById("output");
const sel = document.getElementById("program-select");
const hint = document.querySelector(".program-hint");

const worker = new Worker("./runner.js", { type: "module" });

const ALLOWED_KEYS = {
  "w": 0x77, "W": 0x77,
  "a": 0x61, "A": 0x61,
  "s": 0x73, "S": 0x73,
  "d": 0x64, "D": 0x64,
  "q": 0x71, "Q": 0x71,
  " ": 0x20,
};

function render() {
  out.textContent = ansi.text();
}

function startCurrent() {
  // Reset display + state.
  ansi._reset();
  ansi.row = 0; ansi.col = 0;
  render();
  worker.postMessage({ type: "start", idx: parseInt(sel.value, 10), trace: 0 });
}

worker.onmessage = (e) => {
  const msg = e.data;
  if (msg.type === "ready") {
    // Initial select + start.
    worker.postMessage({ type: "select", idx: parseInt(sel.value, 10) });
    startCurrent();
    return;
  }
  if (msg.type === "output") {
    ansi.feed(msg.bytes);
    render();
    return;
  }
  if (msg.type === "halt") {
    // Snake quit cleanly. Show a soft hint.
    out.textContent = ansi.text() + "\n[program halted — change selection or refresh to replay]";
    return;
  }
};

worker.postMessage({ type: "init", wasmUrl: "./ccc.wasm" });

sel.addEventListener("change", () => {
  worker.postMessage({ type: "select", idx: parseInt(sel.value, 10) });
  startCurrent();
});

out.addEventListener("focus", () => {
  if (hint) hint.classList.add("hidden");
});

out.addEventListener("blur", () => {
  if (hint) hint.classList.remove("hidden");
});

out.addEventListener("keydown", (e) => {
  const byte = ALLOWED_KEYS[e.key];
  if (byte === undefined) return;
  e.preventDefault();
  worker.postMessage({ type: "input", byte });
});

out.addEventListener("click", () => out.focus());
```

- [ ] **Step 2: Stage and serve locally**

```bash
./scripts/stage-web.sh
python3 -m http.server -d . 8000 &
sleep 1
open http://localhost:8000/web/
```

- [ ] **Step 3: Commit**

```bash
git add web/demo.js
git commit -m "web: rewrite demo.js for Worker + ansi.js + program select"
```

---

## Task 27: Manual browser verification

**Files:** none (smoke test).

This is the final quality gate. Reproduces the Spec §"Definition of done" item 1.

- [ ] **Step 1: Stage + serve**

```bash
./scripts/stage-web.sh
python3 -m http.server -d . 8000
```

(Leave the server running; open the browser in a separate window.)

- [ ] **Step 2: Open the demo**

```bash
open http://localhost:8000/web/
```

- [ ] **Step 3: Verify each behavior**

Tick off each:
- The page loads without errors (DevTools Console clean).
- The `<select>` shows `snake.elf` selected by default.
- An empty board with a small snake at center is visible.
- Clicking the terminal area focuses it (visible outline appears, hint disappears).
- Pressing `d` moves the snake right; pressing `w` turns it up; etc.
- Eating food (the `*`) increments the score in the HUD.
- Hitting a wall shows the GAME OVER overlay.
- Pressing SPACE restarts the game with a fresh board.
- Pressing `q` halts the program (the "[program halted...]" message appears).
- Switching the dropdown to `hello.elf` and back reloads each program correctly.

- [ ] **Step 4: Run the full CI gate locally**

```bash
zig build test
zig build snake-test
zig build e2e-hello-elf
zig build e2e-kernel
zig build e2e-plic-block
zig build e2e-snake
```

Expected: all green.

- [ ] **Step 5: Open a PR**

```bash
git push -u origin snake-demo
gh pr create --title "snake demo: CLI + browser" --body "$(cat <<'EOF'
## Summary
- New `snake.elf`: bare M-mode RV32 game driven by CLINT timer IRQ + UART poll.
- `zig build run-snake` (CLI play) + `zig build e2e-snake` (deterministic CI gate).
- Browser demo extends to a `<select>` dropdown with snake.elf as default; new chunked `runStart`/`runStep` wasm API + ~120-line ANSI interpreter.

## Test plan
- [x] `zig build snake-test` passes (game.zig unit tests)
- [x] `zig build e2e-snake` passes (~4 s wall-clock)
- [x] `zig build run-snake` plays interactively in a tty
- [x] Browser demo: WASD plays snake.elf; SPACE restarts; q halts; selector switches between snake/hello cleanly
- [x] All existing tests still green: `zig build test`, `e2e-hello-elf`, `e2e-kernel`, `e2e-plic-block`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 6: Confirm CI is green**

```bash
gh pr checks
```

Expected: all checks pass on the PR (the new `e2e-snake` step joins existing matrix).

- [ ] **Step 7 (optional): merge**

After review, merge the PR. The Pages workflow (existing) will redeploy the demo with snake.elf available.

---

## Self-review notes

**Spec coverage:**
- Snake program (M-mode, 8 Hz tick, full-redraw, WASD, classic walls, RNG seed on first key, drain-one-byte-per-tick): T1–T16.
- CLI play + e2e: T17–T19.
- CI: T20.
- Wasm chunked refactor: T21–T22.
- Browser ANSI + Worker + UI: T23–T26.
- Manual verification (DoD): T27.

**Known under-specified item:** the choice between `cpu.stepOne()` and a budgeted `cpu.run()` in T21 depends on the current `src/cpu.zig` API. Engineer must inspect and pick. Both options described; the commit message records the choice.

**One known mismatch with spec:** the spec mentions UTF-8 box-drawing chars (`╔══╗`) for the GAME OVER overlay; the plan uses ASCII (`+`, `-`, `|`) instead, with a comment in T15 explaining why (avoiding the per-cell UTF-8 vs `[H][W]u8` framebuffer mismatch). UTF-8 lands in a follow-up plan if needed; doesn't affect any DoD criterion.
