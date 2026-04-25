# Snake demo — design

**Status:** approved 2026-04-25
**Branch / worktree:** TBD (suggest `snake-demo` at `.worktrees/snake-demo`)
**Goal:** A visitor of `https://cyyeh.github.io/ccc/web/` can pick "snake.elf"
from a dropdown, click the terminal area, and play snake — WASD to move, q
to quit, SPACE to restart on death — running on the same RV32IMA core as
the rest of the project. The CLI gets a `zig build run-snake` for tty
play and a `zig build e2e-snake` test gate.

This is the project's first interactive RV32 program: it exercises UART RX
end-to-end (browser keystroke → wasm `pushInput` → Uart.pushRx → drained
inside the snake program) and CLINT timer interrupts (8 Hz game tick),
without dragging in S-mode or kernel-API decisions.

## Why

Phase 3.A merged a UART RX FIFO and PLIC plumbing in March 2026 but the
existing demos don't exercise input from a human. The deck currently
shows `hello.elf` printing one line; visitors have no way to interact
with the computer. Snake is the smallest recognizable interactive program
that uses everything Phase 1 and 2 give us, plus the new RX path —
without needing a shell, a filesystem, or any of Phase 3.B's deliverables.

A secondary goal: the `keystroke → UART.pushRx` browser bridge built here
is the same bridge that Phase 3.B's shell-in-browser will need. Building
it now means the shell demo lands as a one-line ELF swap when it's ready.

## Non-goals

- **`kernel.elf` in the `<select>` dropdown.** The Phase 2 demo deserves
  its own design pass; bundling it in here would hide the choice. Add as
  a follow-up plan once snake ships.
- **Cursor-positioning ANSI** (`CSI r;cH` for partial-update diffs).
  Full-screen redraws at 32×16 @ 8 Hz are ~600 bytes/frame — bandwidth is
  not a concern, and the JS interpreter stays trivial. Add cursor diffs
  when the eventual shell needs them.
- **Color** (`CSI 38;...m`, `CSI 48;...m`). Pure ASCII + box-drawing UTF-8
  is enough for snake. Color comes with the shell.
- **Sound** (UART `\a` beep). Web Audio adds a dependency; not worth it.
- **High-score persistence.** Would require a block-device save convention.
  Demo is one game per run.
- **Arrow-key input.** ESC-sequence parsing in the snake program is
  shell-territory work; Q3 picked WASD-only.
- **Acceleration as snake grows.** Fixed 125 ms/tick. Nice-to-have follow-up.
- **Power-ups, multiple food types, internal walls.** Not classic snake.
- **Snake running as U-mode under `kernel.elf`.** Rejected as too coupled
  with kernel-API design (would need a `read` syscall). Revisit when
  Phase 3.B's shell forces those decisions anyway.
- **Per-instruction trace panel for snake in the web demo.** A continuous
  trace at 8 Hz × full-redraw is MB-sized and useless for understanding
  the program. Hide the existing trace checkbox while `snake.elf` is
  selected; show "trace disabled for interactive programs".
- **PLIC RX IRQ inside the snake program.** ccc's PLIC has only one
  S-mode context, so an M-mode program can't take UART RX as an external
  interrupt directly. The full PLIC RX path is already demonstrated by
  `plic_block_test.elf`; snake polls UART `LSR.DR` inside the timer
  handler instead. Input latency is invisible at 8 Hz.
- **Headless tests for `ansi.js`.** ~120 lines, single-purpose,
  eyeball-checkable. Add a real suite when a second ANSI program (shell)
  lands and the interpreter grows.
- **Browser-side resize / responsive board.** Fixed 32×16 in monospace.
  Mobile users get a horizontal scrollbar; acceptable for the demo.

## Approach

### Architecture overview

```
Browser (web/index.html, demo.js, ansi.js, runner.js)
  ├─ <select>:    snake.elf (default) | hello.elf
  ├─ <pre>:       32×16 monospace, tabindex="0", "click to play" hint until focused
  ├─ keydown:     w/a/s/d/q/Space  →  postMessage({type:"input", byte}) → Worker
  └─ Worker:      runs the wasm in CHUNKS — see "Wasm loop architecture" below.
                  Each turn: setMtimeNs(now); runStep(N); drain consumeOutput;
                  forward input bytes via pushInput; yield via setTimeout(0).
                                              │
                                              ▼ posts {type:"output", bytes} to main
                                                main thread feeds bytes into ansi.js
                                                ANSI interpreter updates 32×16 screen
                                                buffer, renders <pre>.textContent
                       ─────────────────────────────────────────────
ccc.wasm (demo/web_main.zig + emulator core)
  Existing exports:  outputPtr, tracePtr, traceLen
                     (run() is removed — replaced by runStart + runStep)
  New exports:       runStart(programIdx: u32, trace: i32) -> i32
                     runStep(maxInstructions: u32) -> i32   (-1 still running, else exit code)
                     setMtimeNs(ns: i64)                    (BigInt from JS)
                     consumeOutput() -> u32                  (count of unconsumed bytes; advances drain pointer)
                     pushInput(byte: u32)                    (UART RX FIFO push)
                     selectProgram(idx: u32)                 (kept as alias of runStart's first arg)
  Embedded:          hello.elf (today), snake.elf (new)
                                              │
                                              ▼ ELF loaded, emulated
                       ─────────────────────────────────────────────
snake.elf — bare M-mode RV32I program
  Boot (monitor.S):  set sp, install M-mode trap vector, enable mstatus.MIE + mie.MTIE,
                     program first mtimecmp (now + 125 ms ≈ 1_250_000 ticks @ 10 MHz),
                     enter idle loop:  wfi ; j idle
  Trap (trap.S):     save caller-saved regs, call snakeTrap(), restore, mret
  snakeTrap() (Zig): drain UART RBR (poll LSR.DR), fold latest direction
                     advance state, render full frame
                     if first key of fresh game: seed RNG from mtime
                     if quit: write tohost (halt)
                     advance mtimecmp += period
```

Three privileges? No — this program is M-mode only. The kernel demo
already covers M/S/U; snake's job is "first interactive RV32 program",
not "second multi-privilege demo."

### Snake program internals

**File layout** (mirrors `tests/programs/hello/`):

```
tests/programs/snake/
  monitor.S        boot: sp, mtvec, mstatus.MIE+mie.MTIE, first mtimecmp, wfi loop
  trap.S           trap entry: save caller-saved regs, call snakeTrap(), restore, mret
  snake.zig        game logic + render
  linker.ld        load at 0x8000_0000, M-mode, .text/.rodata/.bss/.stack
  test_input.txt   deterministic byte sequence for e2e-snake
```

**Module-level state in `snake.zig`** (no allocation; everything in BSS):

- `board: [15][32]u8` — playfield (top row 0 of 16 is the HUD)
- `snake_x: [15*32]u8`, `snake_y: [15*32]u8` — ring buffer of segments
- `head: u16`, `tail: u16`, `len: u16` — ring indices
- `dir: enum { Up, Down, Left, Right }` — current direction
- `pending_dir: ?dir` — queued by input, applied at next tick start
- `score: u32`
- `rng: u32` — xorshift32 state, 0 means "unseeded"
- `state: enum { Playing, GameOver }`
- `quit_requested: bool`

**Tick handler logic** (called from trap.S on every MTI):

1. `drainInput()` — **at most one byte per tick.** If `LSR.DR` is set, pop
   one byte from `RBR` and switch on it:
   - `w/a/s/d` (lowercase): on first key of a fresh game AND `rng == 0`,
     seed `rng` from current `mtime`. Then set `pending_dir` (and
     `game_started = true` if not yet).
   - `q`: `quit_requested = true`.
   - `' '` (SPACE): if `state == GameOver`, reset board / snake / score
     and set `state = Playing`. (rng stays seeded across restarts.)
   - other: ignored.

   **Why one-per-tick (not drain-the-FIFO):** the e2e test feeds a
   ~30-byte input file all at once, but we want each byte to drive
   one tick of behavior so multi-tick interactions like wall collision
   are testable. Real-time gameplay is unaffected: max input latency is
   one tick (125 ms), and bursts of player keys queue in the FIFO and
   are drained at one byte per tick — imperceptible at WASD-style
   gameplay tempo.
2. If `state == Playing`:
   - If `pending_dir` is set and not a 180° reversal of `dir`, apply it.
     (180° reversals are silently rejected, matching every snake game ever.)
   - `advance()`: compute new head cell from `dir`. If wall → `state = GameOver`.
     Otherwise check collision with body[1..]; if hit → `state = GameOver`.
     Otherwise: write head into board. If new head cell is food, `score += 1`,
     advance head index but don't move tail (snake grows by 1); place new
     food via rejection sampling (`nextRng() % W`, `nextRng() % H`, retry
     if cell is occupied). If not food, advance head and tail (snake moves).
   - `renderPlaying()`: emit clear+home, HUD line, 15 board rows.
3. If `state == GameOver`:
   - `renderGameOver()`: same playing frame, then center-overlay a 5×12
     panel using box-drawing chars.
4. If `quit_requested`: write nonzero to `tohost` (halts emulator).
5. `advanceMtimecmp(period_ticks)`: read current `mtime`, add period, write
   `mtimecmp`. (Doesn't matter if we drift slightly; player can't tell.)

**Rendering format** (one frame ≈ 600 bytes):

```
\x1b[2J\x1b[H                                   ← clear + home cursor
SNAKE  score: 7  (q quit)\r\n                  ← HUD: row 0 of terminal
+------------------------------+\r\n            ← 15 board rows × 32 cols
|                              |\r\n              ' ' empty, '#' body, 'O' head, '*' food
|         O##                  |\r\n              borders: '+' '-' '|'
... (13 more)
+------------------------------+\r\n
```

**GAME OVER overlay** — re-renders the same frame above, then writes a
centered 5-row × 12-col panel using UTF-8 box-drawing chars
(`╔══╗║╚═══╝`). The bytes are valid UTF-8 multibyte sequences; tty
terminals render them as single cells, and `ansi.js` reassembles them
into a single screen-cell write (see ANSI interpreter notes below).

**Boot sequence (`monitor.S` sketch):**

```
.option arch, +zicsr
_start:
    la   sp, _stack_top
    la   t0, trap_vector
    csrw mtvec, t0
    li   t0, (1 << 11)              # mie.MTIE
    csrw mie, t0
    li   t0, (1 << 3)               # mstatus.MIE
    csrs mstatus, t0
    # program first mtimecmp = mtime + 125ms @ 10MHz
    li   t1, 0x0200BFF8             # mtime
    li   t2, 0x02004000             # mtimecmp
    lw   a0, 0(t1)
    lw   a1, 4(t1)
    li   t3, 1250000
    add  a0, a0, t3
    sw   a0, 0(t2)
    sw   a1, 4(t2)
idle:
    wfi
    j    idle
```

**Halt mechanism**: snake writes nonzero to the `tohost` symbol's address
(resolved by the existing ELF loader, same path `hello.elf` and the
riscv-tests use). No emulator changes needed.

### Browser bridge + ANSI interpreter

**Files added/modified:**

```
demo/web_main.zig    rewritten: replace run() with runStart + runStep,
                                add setMtimeNs + pushInput + selectProgram
                                + consumeOutput; embed snake.elf alongside
                                hello.elf; module-level emulator state
src/lib.zig          unchanged (re-export shim)
web/index.html       extend: + <select>, focus styling on <pre>, click hint
web/demo.css         extend: + .focus-hint, monospace tightening
web/demo.js          rewritten: ~80 → ~150 lines; owns Worker + UI + select
web/runner.js        NEW: ~100 lines; Web Worker; chunked runStep loop;
                          drains output; routes input
web/ansi.js          NEW: ~120 lines; ANSI interpreter over a 32×16 char buffer
```

### Wasm loop architecture (chunked execution)

The existing `hello.elf` demo calls `run()` once and reads `outputLen`
after it returns — fine for a program that halts in <100 ms. Snake
never halts until `q`, so a blocking `run()` would lock the Worker:
Web Workers are single-threaded, and while `run()` is executing, the
Worker can't service `setInterval` callbacks or process incoming
`postMessage` listeners. Both output draining AND input forwarding
would stall.

The fix: **chunk the wasm execution from the JS side.** The wasm
exposes a `runStart` / `runStep` pair that lets the Worker turn the
crank itself. Module-level state in `web_main.zig` holds the current
emulator (CPU, memory, devices) across chunks.

**Worker main loop:**

```
Main thread                                Web Worker (runner.js)
───────────                                ────────────────────────
demo.js                                    – load ccc.wasm bytes via fetch
  load runner.js as Worker                 – instantiate (no imports)
  on <select> change:
    postMessage {type:"select", idx}       – on {type:"select", idx}:
                                             stash idx, await {type:"start"}
                                           – on {type:"start"}:
  on click <pre>: focus, send "start"        exports.runStart(idx, 0)
                                             record startMs = performance.now()
                                             enter chunked loop (below)

                                           – chunked loop:
                                               while (true):
                                                 elapsedNs =
                                                   (performance.now() - startMs) * 1e6
                                                 exports.setMtimeNs(BigInt(elapsedNs))
                                                 exit = exports.runStep(50_000)
                                                 len = exports.consumeOutput()
                                                 if (len > 0):
                                                   bytes = copy from outputPtr()..len
                                                   postMessage {type:"output", bytes}
                                                 if (exit !== -1):
                                                   postMessage {type:"halt", code: exit}
                                                   break
                                                 await new Promise(r => setTimeout(r, 0))

  on keydown (filtered):                   – on {type:"input", byte}:
    postMessage {type:"input", byte}         exports.pushInput(byte)
                                             (UART RX FIFO; bytes wait there
                                              for the snake program to drain
                                              on its next tick — pushing
                                              raises PLIC src 10 internally,
                                              but snake polls LSR.DR anyway)

  on message from worker:
    if "output": ansi.feed(bytes); render()
    if "halt":   show "press restart"
```

The `setTimeout(0)` between chunks is the key responsiveness mechanism:
the Worker's event loop runs once per turn, processing any pending
`{type:"input"}` messages and applying them via `pushInput` *before* the
next `runStep`. Latency from keypress → snake-can-see-it: at most one
chunk (~5 ms) plus one tick boundary (≤ 125 ms). Imperceptible.

**Why a Worker at all?** The chunked loop runs 50K wasm instructions per
turn (~1–10 ms depending on machine). Doing this on the main thread
would jank `requestAnimationFrame` and CSS transitions. The Worker keeps
emulation off the UI thread.

**Why `setMtimeNs` (not a JS-imported clock)?** Keeps the wasm import
list empty — same constraint we held in the existing demo. The clock
source inside the wasm reads a module-level `i128` that JS updates
between chunks. mtime is "frozen" within a chunk (no real-time advance
during a `runStep`), but updated each chunk to current `performance.now()`.
For an 8 Hz game with 5 ms chunks, mtime resolution is plenty.

**Why `runStep` returns `-1` for "still running":** `i32` exit codes
fit naturally into native sign-extended `i32`; using `-1` as a sentinel
avoids needing a separate "halted" flag export.

**Output buffer overflow risk:** the existing 16 KB `output_buf` would
fill in ~3 seconds of snake play (~4800 B/s). `consumeOutput` resets
`output_writer.end` to 0 when its returned count equals the current
write position — i.e., when JS has fully drained, the wasm "rewinds."
This is safe because the Worker calls `consumeOutput` on every turn,
so the drain mark is always at the write position by the time the next
chunk runs.

### Browser bridge components

**ANSI interpreter** (`ansi.js`) — small state machine, full-redraw subset:

```
states:    GROUND → ESC → CSI → (collect params) → final byte:
                                                    'J' arg 2  → clear screen, cursor (0,0)
                                                    'H' no args  → cursor (0,0)
                                                    'H' r;c    → cursor (r-1, c-1) (kept for forward compat)
                                                    '?25l'/'?25h' → no-op
                                                    other      → consume + ignore
GROUND printable:    write screen[row][col], col++; wrap at W to (row+1, 0); clamp at H
GROUND '\n':         row++ (clamp), col stays
GROUND '\r':         col = 0
GROUND '\t', other:  ignored
UTF-8 multibyte:     bytes 0xC0..0xF7 start a sequence, 0x80..0xBF continue;
                     reassemble into one JS code unit, write 1 cell
```

Render: after `feed(bytes)` returns, build `screen.map(r => r.join("")).join("\n")`
and assign to `<pre>.textContent`. Cheap at 32×16.

**Focus + keystroke filtering**: `<pre tabindex="0">` so it's keyboard-focusable.
`keydown` listener attaches to the `<pre>` (not `document`) so unfocused
page keys still work normally. Allowed bytes: `w/a/s/d` (case-insensitive
→ lowercase ASCII), `q` (`0x71`), SPACE (`0x20`). For matched keys,
`e.preventDefault()`; for everything else, no-op (browser shortcuts like
Cmd+L, Cmd+W stay intact).

**Trace panel**: hide the existing "show instruction trace" checkbox
when `snake.elf` is selected (toggle on `<select>` change). Keep it for
`hello.elf`.

### Build, test, CI

**`build.zig` additions** (mirroring `hello-elf` / `e2e-hello-elf`):

```
zig build snake-elf      Compile snake.elf  (→ zig-out/bin/snake.elf)
zig build run-snake      Build snake.elf, run via ccc CLI; reads stdin (--input -).
                         Step wraps exec with `stty -icanon -echo` so single
                         keystrokes work on macOS, restores on exit.
zig build e2e-snake      Pipe tests/programs/snake/test_input.txt through --input,
                         assert exit==0 AND stdout contains "GAME OVER" + "score: 0".
zig build wasm           (existing) — extended to embed snake.elf alongside hello.elf.
```

**`tests/programs/snake/test_input.txt`** — deterministic byte sequence
in the shape `d…d w…w q`:

```
ddddddddwwwwwwwwwwwwwwwwwwwwwq
```

- The `d` run keeps the snake moving right but is sized **not** to hit
  the right wall.
- The `w` run turns the snake up and is sized to **overshoot** whatever
  upward distance is needed to hit the top wall — extra `w` bytes after
  death are processed in `GameOver` state and ignored, so overshoot is
  free.
- Trailing `q` is consumed in `GameOver` state and quits.

Exact d/w counts are tuned during implementation once spawn position is
locked. The test asserts on the *strings* `GAME OVER` and `score: 0`,
neither of which depends on which exact byte killed the snake.

**Wall-clock duration**: drain-one-per-tick × 8 Hz × ~30 input bytes
≈ **~4 seconds** of real wall-clock time per `e2e-snake` run, because
`mtime` in the CLI is backed by `clock_gettime`. Comparable to the
existing `e2e-kernel` runtime; acceptable for CI.

**Verification harness**: `tests/programs/snake/verify_e2e.zig`
(mirrors `tests/programs/kernel/verify_e2e.zig`) — builds the snake ELF,
runs `ccc --input test_input.txt zig-out/bin/snake.elf`, captures stdout,
asserts the two strings appear and the exit code is 0 (clean halt via
tohost, not a trap).

**CI integration** — add `zig build e2e-snake` to the existing test
matrix in `.github/workflows/pages.yml`. Joins `e2e-hello`, `e2e-mul`,
`e2e-trap`, `e2e-hello-elf`, `e2e-kernel`, `e2e-plic-block`. No new
infrastructure.

**No tests for the JS/ANSI side.** ~120 lines, eyeball-verifiable; the
snake program itself is the integration test for the renderer (broken
ANSI = visibly broken screen). Reconsider when a second ANSI program
ships.

**Manual verification before claiming done:**

- `zig build run-snake` in a tty: play, eat 5+ food, die on wall, restart
  with SPACE, quit with q.
- `zig build run-snake` in a tty: play to length ≥ 4, deliberately
  collide with own body, confirm GAME OVER.
- `zig build wasm` → `./scripts/stage-web.sh` → `python3 -m http.server` →
  visit page, click `<pre>`, play snake, verify GAME OVER overlay, restart,
  switch dropdown to hello.elf and back, confirm both work.
- `zig build e2e-snake` and full `zig build test` both green.

## Definition of done

1. Visiting `https://cyyeh.github.io/ccc/web/` shows `snake.elf` selected
   in the dropdown by default. Clicking the terminal area focuses it.
   Pressing W/A/S/D moves a snake. Eating food increases the score.
   Hitting a wall or your own body shows `GAME OVER` overlay. SPACE
   restarts. Q halts.
2. `zig build run-snake` plays in a macOS terminal with single-keystroke
   input.
3. `zig build e2e-snake` is green and joins CI on every PR.
4. `zig build test`, `zig build e2e-hello-elf`, `zig build e2e-kernel`,
   `zig build e2e-plic-block` all still pass — no regressions.

## Open questions / decisions made

All decisions captured during brainstorming (Q1–Q7):

- **Q1 — scope**: B (CLI + browser, no kernel integration).
- **Q2 — display**: full-redraw, not cursor-positioning diffs.
- **Q3 — input**: WASD only, `q` quit, SPACE restart on game-over.
- **Q4 — geometry/rate**: 32 cols × 16 rows (15 play + 1 HUD), 8 Hz tick.
- **Q5 — walls/death**: classic (solid walls, GAME OVER overlay,
  SPACE restart, q quit).
- **Q6 — game loop**: M-mode bare, CLINT timer IRQ, poll UART `LSR.DR`
  inside timer handler.
- **Q7 — defaults**: xorshift32 seeded from mtime at first key; one food
  at a time; HUD `SNAKE  score: N  (q quit)` on row 0; box-drawing
  GAME OVER panel; minimal ANSI subset in JS; new wasm exports
  `pushInput`, `selectProgram`, `consumeOutput`; deterministic e2e via
  fixed input file ending in `q`; build targets `snake-elf` /
  `run-snake` / `e2e-snake` mirroring `hello-elf`; embed snake.elf in
  wasm; Web Worker hosts wasm so the main thread stays responsive.

Three refinements added during spec writing (third found during plan writing 2026-04-26):

- **Game starts in `.Playing` but does not advance until the first key
  press.** This removes any timing dependency between the e2e input
  file's first byte and the first MTI, making the test fully deterministic
  even if the input pump and the timer interrupt race on the first tick.
  Adds one boolean (`game_started`) to module state; tick handler skips
  `advance()` and `renderPlaying()` until it's true. Initial render of
  the empty board still happens on tick 0 so the player sees the field.
- **`drainInput()` consumes at most one byte per tick** (not while-DR-set).
  Required for the e2e test: each input byte must drive one tick of
  behavior, so multi-tick interactions like wall collision can be exercised
  by a single deterministic input file. Real-time gameplay is unaffected
  (input latency ≤ 125 ms; key bursts queue in the 256-byte FIFO and are
  drained one per tick).
- **Wasm uses chunked execution, not a single blocking `run()`.** The
  Worker can't be locked inside `run()` — it needs to service input
  messages and post output messages between turns. Replaced `run()` with
  `runStart()` + `runStep(maxInstructions)` and added `setMtimeNs(ns)`
  so the JS event loop drives the simulation clock. The existing
  `hello.elf` flow is preserved (a single `runStart` + `runStep` loop
  produces equivalent output). See "Wasm loop architecture" section
  above for the full rationale.
