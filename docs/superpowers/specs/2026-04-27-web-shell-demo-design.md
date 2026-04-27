# Web shell demo — design

**Status:** brainstormed 2026-04-27 (awaiting review)
**Branch / worktree:** TBD (suggest `web-shell-demo` at `.worktrees/web-shell-demo`)
**Goal:** A visitor of `https://cyyeh.github.io/ccc/web/` lands on a working `$`
shell prompt by default and can run the full Phase 3.E + 3.F shell experience
in the browser — `ls /bin`, `cat /etc/motd`, `echo hi > /tmp/x`, `edit /etc/motd`,
`^C` to cancel a foreground program, `exit`. Same kernel and same userland
binaries as `zig build kernel-fs run -- --disk shell-fs.img kernel-fs.elf` on
the CLI, just driven by the browser. Snake and hello stay as alternative
options in the dropdown; shell becomes the new default.

This is the first browser demo that exercises ccc's filesystem layer, cooked-mode
line discipline, and process model end-to-end through human input.

## Why

Phase 3 (multi-process OS + filesystem + shell) is complete. The CLI demos
already show the full shell working against `shell-fs.img`, but the live web
demo only ships `snake.elf` (interactive game) and `hello.elf` (auto-runs +
trace). Visitors who land on the page have no way to feel the OS — the
filesystem, the cooked-mode console, the editor, the `^C` chain — even though
all of it already works on the CLI.

The new shell demo closes that gap with a small wasm-side delta: a
`disk_buffer` next to the existing `elf_buffer`, two new exports, and one
signature change to `runStart`. The browser-side change is bigger but
mechanical: a wider terminal, scroll-on-newline, a richer key map, and a
parallel disk fetch. Snake and hello stay byte-identical on the wire — the
disk surface is opt-in per `runStart`.

## Non-goals

- **Disk persistence across page reloads.** Pristine on every page load (Q2-A).
  Each `runStart` re-copies `shell-fs.img` over `disk_buffer`. No IndexedDB,
  no quota handling, no stale-image versioning. Refresh = clean slate.
- **Lazy block fetch / sector-on-demand.** Shell-fs.img is 4 MB and Pages
  serves it gzipped (zero-block heavy). Up-front fetch keeps the wasm import
  object empty (`{}`) and the kernel's block driver synchronous from its
  perspective.
- **Browser tests for `ansi.js` or the wasm runner.** Snake-demo already
  punted on this for the same reasons (`ansi.js` ~120 lines, eyeball-checkable;
  no Node-driven wasm test infra exists). Manual browser smoke test is the
  gate. Add automated suites when complexity demands it.
- **`kernel-multi.elf` / `kernel-fork.elf` / `kernel-fs.elf` (read-only) as
  separate dropdown entries.** The shell already implies fork/exec/wait/FS
  worked end-to-end. Surfacing them individually would clutter the dropdown
  without adding signal.
- **Per-program terminal sizing.** Single 80×24 grid for everything (Q3-A);
  snake's 32×16 game render naturally sits in the top-left of the bigger box,
  with free space around it. No resize-on-program-switch logic.
- **Tab completion, command history, autocomplete, paste handling.** These
  are shell improvements, not browser-demo concerns. Same shell as the CLI.
- **Mobile / touch input.** Shell needs alphanumeric keys; mobile keyboards
  send composition events that don't map cleanly to per-byte input. Same
  device-warning panel snake has.
- **Sound, color, mouse.** No `\a` beep, no SGR color sequences, no mouse
  events. Pure ASCII + UTF-8 box-drawing (already supported).
- **A second terminal viewport** (e.g. a "boot log" panel separate from the
  shell). One `<pre>`, one ANSI interpreter.

## Approach

### Architecture overview

The shell experience is a disk-aware variant of the existing snake/hello
flow, not a separate runtime. Same `web_main.zig` chunked `runStep` loop,
same Worker ↔ main-thread message protocol, same wasm module — extended in
three precise places.

```
Browser (web/index.html + demo.js + runner.js + ansi.js)
  ├─ <select>:  shell.elf (default) | snake.elf | hello.elf
  ├─ <pre>:     80×24 monospace, scroll-on-newline (was 32×16, no scroll)
  ├─ keydown:   per-program key map. Shell map = full ASCII +
  │             ^C/^D/^U/^S/^X (Ctrl+letter → byte) +
  │             Enter→\n + Backspace→\x7f + Tab→\t + Esc→\x1b +
  │             ArrowU/D/R/L → 3-byte ESC [ A/B/C/D
  └─ Worker:    on "start", if program has a disk:
                  fetch ELF + disk in parallel
                  copy ELF into elfBuffer (existing)
                  copy disk into diskBuffer (NEW)
                  runStart(elf_len, trace, disk_len)

Wasm (demo/web_main.zig)
  ├─ elf_buffer    (existing, 2 MB)
  ├─ disk_buffer   (NEW, 4 MB — sized for shell-fs.img)
  ├─ NEW exports:  diskBufferPtr(), diskBufferCap()
  ├─ runStart now takes (elf_len, trace, disk_len);
  │   disk_len=0 → no block device backing (snake/hello path, unchanged)
  │   disk_len>0 → hand disk_buffer[0..disk_len] slice to Block.init
  └─ Block reads/writes mutate the in-wasm buffer; never persisted
     (refresh = pristine disk, per Q2-A)

Build (build.zig + scripts/stage-web.sh)
  ├─ wasm step now also installs:
  │   - zig-out/web/kernel-fs.elf  (the FS-mode kernel — already built)
  │   - zig-out/web/shell-fs.img   (already built by shell-fs-img step)
  └─ stage-web.sh copies both into web/ for local dev
```

**Key invariant:** snake and hello call `runStart(elf_len, trace, 0)` —
identical bytes-on-the-wire to today. Zero behavioral change for existing
programs. The disk surface is opt-in per-run.

### Wasm changes (`demo/web_main.zig`)

Three additions and one signature change in `web_main.zig`. The other
emulator modules (`cpu.zig`, `memory.zig`, etc.) are untouched. The one
exception is `block.zig`, which may grow a small `initWithSlice([]u8)`
constructor if it doesn't already have a slice-backed init alongside
its file-backed one — see the open question below.

**1. New disk receive buffer** (mirrors the existing `elf_buffer` pattern):

```zig
const DISK_BUFFER_CAP: u32 = 4 * 1024 * 1024;   // sized for shell-fs.img
var disk_buffer: [DISK_BUFFER_CAP]u8 = undefined;

export fn diskBufferPtr() [*]u8 { return &disk_buffer; }
export fn diskBufferCap() u32   { return DISK_BUFFER_CAP; }
```

**2. Extend `runStart` to take `disk_len`:**

```zig
export fn runStart(elf_len: u32, trace: i32, disk_len: u32) i32 {
    // ... existing validation + teardown ...
    const disk_slice: ?[]u8 =
        if (disk_len == 0) null
        else if (disk_len > DISK_BUFFER_CAP) return -6
        else disk_buffer[0..disk_len];

    // Block gets a backing slice when one was supplied; otherwise
    // initialised with no backing (the snake/hello path, unchanged).
    state_storage.block = if (disk_slice) |buf|
        block_dev.Block.initWithSlice(buf)
    else
        block_dev.Block.init();

    // Memory.init unchanged — already accepts null for the disk-path arg.
    // ... rest of init ...
}
```

**3. Lifecycle:**
- `disk_buffer` is `undefined` static memory; JS overwrites `[0..disk_len]`
  before each `runStart` (via `diskBufferPtr` + `set()`). No zeroing needed —
  same pattern as `elf_buffer`.
- Block-device writes from the kernel mutate `disk_buffer` in place. On the
  next `runStart` (e.g. user picks shell again), JS re-copies the pristine
  `shell-fs.img` over it → fresh disk per run.
- New error code `-6` for `disk_len > DISK_BUFFER_CAP`.

**Wasm size impact:** linear memory grows by 4 MB (one extra page-aligned
static buffer). The compiled `ccc.wasm` itself stays ~50 KB — buffer is BSS,
not code.

### Browser changes (`web/`)

**`web/runner.js` — parallel disk fetch + copy:**

```js
if (msg.type === "start") {
  const myRunId = ++currentRunId;
  // ELF + (optional) disk fetched in parallel
  const elfFetch  = fetch(msg.elfUrl).then(r => r.arrayBuffer());
  const diskFetch = msg.diskUrl
    ? fetch(msg.diskUrl).then(r => r.arrayBuffer())
    : Promise.resolve(null);
  const [elfBuf, diskBuf] = await Promise.all([elfFetch, diskFetch]);
  if (myRunId !== currentRunId) return;

  // Copy ELF (existing) ...
  // Copy disk if present:
  let diskLen = 0;
  if (diskBuf) {
    const bytes = new Uint8Array(diskBuf);
    if (bytes.length > exports.diskBufferCap()) throw new Error("disk too large");
    new Uint8Array(memory.buffer, exports.diskBufferPtr(), bytes.length).set(bytes);
    diskLen = bytes.length;
  }
  exports.runStart(elfBytes.length, trace, diskLen);
  runLoop(myRunId);
}
```

**`web/demo.js` — program tables + per-program key map:**

```js
const W = 80, H = 24;                      // was 32, 16
const ELF_URLS  = { "0": "./hello.elf", "1": "./snake.elf", "2": "./kernel-fs.elf" };
const DISK_URLS = { "2": "./shell-fs.img" };  // shell only
// existing TRACE_PROGRAMS unchanged ("0" = hello)

// Key handler picks the map by current program:
//   snake   → existing 6-key WASD/Space/Q map
//   hello   → no input
//   shell   → wide map (ASCII printables + Ctrl+letter→0x01..0x1a +
//             Enter→0x0a + Backspace→0x7f + Tab→0x09 + Esc→0x1b +
//             ArrowU/D/R/L → 3-byte ESC [ A/B/C/D)
// Modifier rule: only e.ctrlKey is intercepted (Cmd/Alt pass through, so
// Cmd+R / Cmd+T / browser shortcuts still work). preventDefault only when
// we forward a byte; never swallow unmapped keys.
//
// Multi-byte keys (arrows): worker.postMessage({type:"input", byte}) one
// per byte, in order. The Worker's pushInput export handles a single byte
// at a time — same as snake.

worker.postMessage({ type: "start", runId, elfUrl, diskUrl: DISK_URLS[idx], trace });
```

**`web/ansi.js` — scroll-on-newline:**

The existing fixed-grid model stays. One change in the `\n` branch: when
`row === H - 1`, `screen.shift()` + `screen.push(new Array(W).fill(" "))`
instead of clamping. Same scroll on cursor positioning past the last row
(paranoia bound on `ESC [ r;c H` with r > H, though the editor shouldn't
emit such positions at 80×24).

**`web/index.html` + `web/demo.css`:**
- Dropdown reorder: `<option value="2" selected>shell.elf</option>` first,
  then snake, then hello.
- New `<div id="shell-instructions">` cheat-sheet card (toggled by
  `updateProgramInstructions`):
  > **shell:** type a command and press Enter · try `ls /bin`,
  > `cat /etc/motd`, `edit /etc/motd` · `^C` cancel · `exit` to halt
- Same device-warning row as snake (mobile/tablet can't drive
  per-byte keyboard input).
- `<pre id="output">` CSS bumps width from `32ch`→`80ch` and grows ~24 lines
  tall. Snake's 32×16 game render naturally sits in the top-left of the
  bigger box; free space around it; no rework.

### Build wiring + page polish

**`build.zig` (wasm step)** — mirror the existing `hello.elf`/`snake.elf`
install pattern:

```zig
// alongside the existing install_web_hello / install_web_snake:
const install_web_kernel_fs    = b.addInstallFile(kernel_fs_elf.getEmittedBin(), "web/kernel-fs.elf");
const install_web_shell_fs_img = b.addInstallFile(shell_fs_img,                  "web/shell-fs.img");
wasm_step.dependOn(&install_web_kernel_fs.step);
wasm_step.dependOn(&install_web_shell_fs_img.step);
```

`kernel_fs_elf` and `shell_fs_img` already exist as LazyPaths in `build.zig`
(Phase 3.D and 3.E built them); the wasm step just adds two install hops.
No new build logic.

**`scripts/stage-web.sh`** — two new `cp` lines after the existing ones,
plus byte-count echoes for parity.

**`.gitignore`** — add `web/kernel-fs.elf` and `web/shell-fs.img` next to
the existing `web/hello.elf` / `web/snake.elf` entries.

**CI (`.github/workflows/pages.yml`)** — no change expected. The existing
job runs `zig build wasm` and deploys `web/` (or `zig-out/web/`); both new
artifacts now land in the same place. Verify during impl that the deploy
step picks them up (shell-fs.img is the largest single artifact, ~4 MB; if
a copy step has a missing wildcard or per-file allowlist, this is where it
will silently disappear).

**`web/README.md`** — add `shell.elf` to the programs list at the top
(default; full Phase-3 shell + utilities + editor with cheat-sheet of
try-commands). Brief mention that shell-fs.img is fetched on demand.
"How it works" section gets one sentence about the disk-buffer plumbing.

**Top-level `README.md`** — the existing "Live demo" line gets a small
expansion ("Pick `shell.elf` (default — full shell with editor and `^C`),
`snake.elf` (WASD), or `hello.elf` (auto-trace)"). No deeper changes —
Phase 3 already has its full status block.

### Testing & verification

**Existing automated gates that MUST stay green** (no new code in their
path; they prove the kernel-side correctness end-to-end):

| Gate | Proves |
|---|---|
| `zig build test` | unit + kernel host tests |
| `zig build e2e-shell` | scripted `ls /bin / echo / cat / rm / exit` session |
| `zig build e2e-editor` | edit/save round-trip through the editor |
| `zig build e2e-persist` | block-device writes survive restart |
| `zig build e2e-cancel` | `^C` kill-flag chain |

If any of those break, the kernel side regressed — fix before continuing.
Wasm-side bugs cannot break these.

`zig build wasm` is not a regression gate but does pick up new behavior:
it now also installs `kernel-fs.elf` and `shell-fs.img` into `zig-out/web/`
alongside the existing `ccc.wasm` / `hello.elf` / `snake.elf`. Verify
those four artifacts end up there.

**No new automated test added.** The wasm contract change is a single new
parameter on `runStart` plus two new exports; the JS layer is small and
mechanical; no Node-driven wasm test infra exists today (snake-demo
explicitly punted on the same grounds for `ansi.js`). A future plan can
add a Node smoke test that drives `runStart` against `kernel-fs.elf` +
`shell-fs.img` and asserts `"$ "` appears in `consumeOutput`, but it's
not a gate for this work.

**Manual browser smoke test (mandatory before merge), documented in the PR:**

1. `./scripts/stage-web.sh && python3 -m http.server -d . 8000`, open
   `http://localhost:8000/web/`.
2. Page lands on `shell.elf` selected; cheat-sheet card visible; dropdown
   shows shell/snake/hello.
3. Within ≤ 2s, `$ ` prompt appears (otherwise add a "booting…" indicator —
   see Open question below).
4. Click terminal, type `ls /bin` <Enter> → see all 9 entries.
5. `cat /etc/motd` <Enter> → "hello from phase 3".
6. `echo hi > /tmp/x` <Enter>; `cat /tmp/x` <Enter> → "hi".
7. `edit /etc/motd` <Enter> → editor enters raw mode; arrow-keys move
   cursor; type a char; `^S` save, `^X` exit; `cat /etc/motd` shows the
   edit.
8. Start `cat` (no args, blocks on stdin); press `^C` → `^C\n$ ` returns.
9. Switch dropdown to `snake.elf` → snake plays in the upper-left of the
   bigger box; WASD/Space/Q work.
10. Switch back to `shell.elf` → fresh `$` prompt, no leaked state from
    snake or from the previous shell session (proves disk is re-copied
    per `runStart`).
11. Refresh page → previous shell edits to `/etc/motd` are gone (proves
    pristine-on-load per Q2-A).

## Open questions for impl, not design

- **Boot indicator.** If kernel boot to first `$` prompt is visibly slow
  (>2s in browser), add a "booting…" placeholder in the terminal box that's
  cleared on first output byte. Probably not needed — kernel-fs boots in
  milliseconds on the CLI — but call out if observed.
- **Backspace byte.** Confirm `src/kernel/console.zig` accepts 0x7f as
  backspace (most likely, since that's the standard DEL on the wire). If
  it only handles 0x08, the JS sends 0x08 instead. Five-minute check,
  two-line JS edit either way.
- **`Block.initWithSlice`.** If `block.zig` already has a slice-backed
  init (CLI uses an mmapped file; the slice version may already exist as
  a sibling), reuse it. Otherwise add a small constructor.

## Definition of done

- Visiting `https://cyyeh.github.io/ccc/web/` lands on `shell.elf` selected
  by default and a `$` prompt within ~2s.
- All 11 manual smoke-test steps pass.
- All existing `zig build test` + `e2e-*` + `wasm` gates pass.
- `web/README.md` documents the new program; top-level `README.md` mentions
  it in the "Live demo" line.
- Snake and hello continue to work byte-identically (no changes to their
  `runStart` shape — they just pass `disk_len=0`).
