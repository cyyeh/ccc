# Web WASM demo — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cross-compile the `ccc` emulator core to `wasm32-freestanding` via a new thin entry point (`src/web_main.zig`), ship a single-page web demo to GitHub Pages that runs `hello.elf` in the browser, and add a CI workflow that gates Pages deploy on the existing test suite.

**Architecture:** New `src/web_main.zig` (~80 lines) imports the existing emulator modules (`cpu.zig`, `memory.zig`, `elf.zig`, `devices/*.zig`) verbatim. `hello.elf` is embedded at compile time via `@embedFile`. UART output is captured into a fixed in-wasm buffer; JS reads it via exported `outputPtr()` / `outputLen()` after calling `run() -> i32`. No WASI, no vendored JS shim. Single GitHub Actions workflow runs the existing test suite and (on `main`) deploys the deck + demo to Pages.

**Tech Stack:** Zig 0.16 (`wasm32-freestanding` target, `ReleaseSmall`, `std.heap.wasm_allocator`, `std.Io.Writer.fixed`), GitHub Actions (`mlugg/setup-zig`, `actions/upload-pages-artifact@v3`, `actions/deploy-pages@v4`).

**Spec:** `docs/superpowers/specs/2026-04-25-web-wasm-demo-design.md`

**Working directory:** all commands assume cwd = `/Users/cyyeh/Desktop/ccc/.worktrees/web-wasm-demo` (the worktree root). Branch: `web-wasm-demo`.

---

## File Structure

**New files:**
- `src/web_main.zig` — freestanding wasm entry point
- `web/index.html` — demo page
- `web/demo.js` — ~30 lines: instantiate, call run(), read output buffer
- `web/demo.css` — terminal styling matching deck palette
- `web/README.md` — how the demo works + how to add another ELF
- `scripts/stage-web.sh` — local dev: build wasm, copy into `web/`
- `.github/workflows/pages.yml` — single workflow with test + deploy jobs

**Modified files:**
- `build.zig` — add `wasm` step (cross-compile `src/web_main.zig` to `wasm32-freestanding`, install to `zig-out/web/`, depends on `hello-elf`)
- `src/devices/clint.zig` — wrap `defaultClockSource` in a comptime switch on `builtin.os.tag` so the freestanding branch returns 0 (no libc symbols). Native and wasi branches preserved.
- `index.html` (deck) — add `.demo-link` CSS class + two link sites (title slide + prologue slide)
- `README.md` — mention the live web demo
- `.gitignore` — ignore `web/ccc.wasm`

**Notes vs. the prior wasi-flavored plan:**
- No `web/vendor/` directory and no vendored `browser_wasi_shim`. The freestanding wasm has zero JS-side dependencies.
- No separate `web/hello.elf` file. The ELF is embedded at compile time via `@embedFile` in `web_main.zig`.
- Tasks 1–2 of the prior plan are now Task 1 (combined: build.zig + web_main.zig + clint.zig comptime switch).

---

## Task ordering rationale

1. Tasks 1–2 prove the wasm build works end-to-end (cheapest blocker — if `wasm32-freestanding` fails on `web_main.zig`'s use of `std.Io.Writer.fixed` or `std.heap.wasm_allocator`, everything else needs revisiting).
2. Tasks 3–6 build the demo page bottom-up (CSS → HTML → JS → stage script).
3. Task 7 is the manual local-browser verification gate before touching the deck.
4. Tasks 8–9 wire the deck links.
5. Tasks 10–12 finalize artifacts (web README, .gitignore, project README).
6. Task 13 is the CI workflow — last because all the prior work needs to be in place for the deploy step to do anything meaningful.
7. Task 14 documents the manual GH Pages settings flip.

---

## Task 1: build.zig wasm step + clint.zig comptime clock switch

**Files:**
- Modify: `build.zig` (append a new `wasm` step)
- Modify: `src/devices/clint.zig` (wrap `defaultClockSource` in a comptime switch on `builtin.os.tag`)

This task only sets up the build infrastructure. It does NOT yet write `src/web_main.zig` (Task 2). After this task, `zig build wasm` will fail because `src/web_main.zig` doesn't exist — that's expected; the failing build is wired up so Task 2 just needs to add the file.

**Actually, since the build target file doesn't exist yet, doing only Task 1's edits would leave the build broken. So Task 1 below adds a placeholder `src/web_main.zig` that just exports `run() -> i32 { return 0; }` to prove the cross-compile works in isolation, then Task 2 fills it in with the real emulator wiring.**

- [ ] **Step 1: Add the comptime switch to clint.zig**

Read `src/devices/clint.zig` lines 1-25 first to confirm the current state.

The current `defaultClockSource` (lines ~14–24) calls `std.c.clock_gettime`. Wrap it in a comptime switch on `builtin.os.tag`. Add `const builtin = @import("builtin");` near the top of the file (after `const std = @import("std");`).

New `defaultClockSource`:

```zig
fn defaultClockSource() i128 {
    // Comptime branch on target. Native uses libc; WASI uses the WASI
    // ABI directly; wasm32-freestanding (web demo) returns 0 — the
    // browser-side entry point passes a custom clock source instead,
    // and a constant default is fine because hello.elf doesn't poll
    // mtime. Keeping this branch with no libc references guarantees
    // the freestanding link succeeds even if Zig's DCE doesn't remove
    // this function.
    switch (comptime builtin.os.tag) {
        .freestanding => return 0,
        .wasi => {
            var ns: u64 = undefined;
            _ = std.os.wasi.clock_time_get(.MONOTONIC, 1, &ns);
            return @intCast(ns);
        },
        else => {
            var ts: std.c.timespec = undefined;
            if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
            const sec: i128 = @intCast(ts.sec);
            const nsec: i128 = @intCast(ts.nsec);
            return sec * 1_000_000_000 + nsec;
        },
    }
}
```

- [ ] **Step 2: Add the wasm step to build.zig**

Read the end of `build.zig` to find the insertion point. Find the existing `install_hello_elf` variable (it's the `b.addInstallArtifact` for `hello.elf` — used by the `hello-elf` step). The new wasm step needs `install_hello_elf` to run first because `web_main.zig` will `@embedFile` it.

Append to the bottom of `build()` (just above the closing `}`):

```zig
    // === Phase 1.W — Web demo: cross-compile ccc to wasm32-freestanding ===
    // Thin entry point in src/web_main.zig that imports the existing
    // emulator modules and exports a minimal run/outputPtr/outputLen
    // interface for the browser. The web_main.zig file embeds hello.elf
    // at compile time, so this step depends on the hello-elf build.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_exe = b.addExecutable(.{
        .name = "ccc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web_main.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        }),
    });
    wasm_exe.entry = .disabled;        // we call our own export, not _start
    wasm_exe.rdynamic = true;          // expose `export fn` symbols
    const install_wasm = b.addInstallArtifact(wasm_exe, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
    });
    // Make sure hello.elf is built before we try to @embedFile it.
    install_wasm.step.dependOn(&install_hello_elf.step);
    const wasm_step = b.step("wasm", "Cross-compile ccc to wasm32-freestanding");
    wasm_step.dependOn(&install_wasm.step);
```

If the existing variable is named differently (e.g., `install_hello`), use the actual name. Confirm by `grep -n "install.*hello.*elf\b" build.zig`.

- [ ] **Step 3: Create a placeholder src/web_main.zig**

Just enough to prove the cross-compile works. Real wiring is Task 2.

```zig
const std = @import("std");

export fn run() i32 {
    return 0;
}

export fn outputPtr() [*]const u8 {
    return &output_buf;
}

export fn outputLen() u32 {
    return 0;
}

var output_buf: [16 * 1024]u8 = undefined;
```

- [ ] **Step 4: Run the wasm build**

Run: `zig build wasm`

Expected: exits 0. Verify:

```bash
ls -lh zig-out/web/ccc.wasm
file zig-out/web/ccc.wasm
```

Expected: `ccc.wasm` exists, very small (likely <10KB for the placeholder); `file` reports `WebAssembly (wasm) binary module`.

If the build fails:
- "entry point not found" → the `entry = .disabled` flag may have a different name in this Zig version; check `b.addExecutable` doc (`grep -A 30 "fn addExecutable" /opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std/Build.zig | head -50`). Likely `entry` is correct in 0.16.
- libc reference error from `clint.zig` → the comptime switch in Step 1 didn't take. Re-check the edit landed and that `builtin.os.tag` is being matched correctly.
- "wasm_allocator not found" or similar → these come up in Task 2; for Task 1's placeholder, you shouldn't hit them.

- [ ] **Step 5: Verify native + tests still pass**

```bash
zig build
zig build test
zig build e2e-hello-elf
```

All exit 0. The `clint.zig` change must not break native — the `else` branch is byte-equivalent to the original.

- [ ] **Step 6: Commit**

```bash
git add build.zig src/devices/clint.zig src/web_main.zig
git commit -m "$(cat <<'EOF'
build: add zig build wasm (freestanding) + comptime clock switch

Cross-compile to wasm32-freestanding, ReleaseSmall, installed to
zig-out/web/ccc.wasm. Depends on hello-elf so a future @embedFile
sees a fresh ELF. Wraps clint.zig's defaultClockSource in a
comptime switch on builtin.os.tag — freestanding returns 0
(no libc), native path is byte-equivalent.

Adds a placeholder src/web_main.zig (real wiring in next commit)
to validate the cross-compile in isolation.
EOF
)"
```

---

## Task 2: Real `src/web_main.zig` wiring

**Files:**
- Modify: `src/web_main.zig` (replace placeholder with real emulator wiring)

- [ ] **Step 1: Replace the placeholder**

Overwrite `src/web_main.zig` with:

```zig
const std = @import("std");
const cpu_mod = @import("cpu.zig");
const mem_mod = @import("memory.zig");
const halt_dev = @import("devices/halt.zig");
const uart_dev = @import("devices/uart.zig");
const clint_dev = @import("devices/clint.zig");
const elf_mod = @import("elf.zig");

// hello.elf is embedded at compile time. The build graph guarantees
// this file is fresh before the wasm build runs (build.zig wires
// install_wasm to depend on install_hello_elf).
const hello_elf = @embedFile("../zig-out/bin/hello.elf");

// 16 KB is comfortable headroom for a "hello world" run.
var output_buf: [16 * 1024]u8 = undefined;
var output_writer: std.Io.Writer = .fixed(&output_buf);

// hello.elf doesn't poll mtime, so a constant clock is sufficient.
fn zeroClock() i128 {
    return 0;
}

// 16 MiB of guest RAM is plenty for hello.elf.
const RAM_SIZE: usize = 16 * 1024 * 1024;

export fn outputPtr() [*]const u8 {
    return &output_buf;
}

export fn outputLen() u32 {
    return @intCast(output_writer.end);
}

export fn run() i32 {
    output_writer.end = 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var halt = halt_dev.Halt.init();
    var uart = uart_dev.Uart.init(&output_writer);
    var clint = clint_dev.Clint.init(zeroClock);

    var mem = mem_mod.Memory.init(a, &halt, &uart, &clint, null, RAM_SIZE) catch return -1;
    defer mem.deinit();

    const result = elf_mod.parseAndLoad(hello_elf, &mem) catch return -2;
    mem.tohost_addr = result.tohost_addr;

    var cpu = cpu_mod.Cpu.init(&mem, result.entry);
    cpu.run() catch return -3;

    output_writer.flush() catch {};
    return @intCast(halt.exit_code orelse 0);
}
```

**API uncertainty handling:** if any of the following Zig 0.16 APIs differ from what's used above, **adapt to the actual API and report the deviation in the self-review** (don't silently rewrite the design):

- `std.heap.wasm_allocator` — should be a `std.mem.Allocator` value usable as an arena backing allocator
- `std.Io.Writer.fixed(&buf)` — should return a `std.Io.Writer` that writes into a fixed buffer; if the constructor name differs (e.g., `.initFixed`), use the real name
- `output_writer.end` — should expose how many bytes have been written; if the field is named differently (e.g., `pos`, `len`, `count`), use the real name
- `output_writer.flush()` — may not exist on a `fixed` writer (since it has nowhere to drain to); if so, drop the call — bytes written via `print`/`writeAll` already land in the buffer

If any API is missing entirely (e.g., `std.heap.wasm_allocator` was removed), STOP and report.

- [ ] **Step 2: Run the wasm build**

Run: `zig build wasm`

Expected: exits 0. Wasm size will jump from a few KB to ~50–150KB (now contains the emulator code + embedded ELF).

```bash
ls -lh zig-out/web/ccc.wasm
file zig-out/web/ccc.wasm
```

If it fails on a Zig stdlib API, see Step 1's "API uncertainty handling" — adapt and re-run.

- [ ] **Step 3: Sanity-check the wasm with wasm-objdump (if available)**

If `wasm-objdump` is on PATH (`which wasm-objdump`), run:

```bash
wasm-objdump -x zig-out/web/ccc.wasm | grep -E "^\s*export\[|memory\[" | head -20
```

Expected: see `export[0..N]` entries including `run`, `outputPtr`, `outputLen`, and `memory`. No imports (other than possibly Zig runtime stuff).

If `wasm-objdump` isn't installed, skip — the real check is the browser test in Task 7.

- [ ] **Step 4: Commit**

```bash
git add src/web_main.zig
git commit -m "$(cat <<'EOF'
src: real web_main.zig — embed hello.elf, run emulator, capture output

Replaces the Task 1 placeholder. Imports cpu/memory/elf/devices
modules verbatim from the existing emulator core. Captures UART
output into a fixed in-wasm buffer; JS reads it via outputPtr() +
outputLen() after calling run() -> exit_code.
EOF
)"
```

---

## Task 3: Demo page CSS

**Files:**
- Create: `web/demo.css`

- [ ] **Step 1: Write demo.css**

Create `web/demo.css`:

```css
:root {
  --bg: #14110d;
  --fg: #faf9f5;
  --accent: #d97757;
  --muted: #8a8070;
  --panel: #1e1a14;
  --panel-border: #2d261d;
  --dim: #5a5247;
}

* { box-sizing: border-box; }

html, body {
  margin: 0;
  padding: 0;
  background: var(--bg);
  color: var(--fg);
  font-family: -apple-system, BlinkMacSystemFont, "Inter", "Helvetica Neue", Arial, sans-serif;
  font-size: 18px;
  line-height: 1.5;
  min-height: 100vh;
}

.page {
  max-width: 920px;
  margin: 0 auto;
  padding: 64px 32px 96px;
}

.brand {
  font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  font-weight: 700;
  color: var(--accent);
  font-size: 64px;
  letter-spacing: 0.04em;
  line-height: 1;
}

h1 {
  font-size: 36px;
  font-weight: 600;
  letter-spacing: -0.01em;
  margin: 24px 0 8px;
}

.subtitle {
  color: var(--muted);
  font-size: 16px;
  letter-spacing: 0.04em;
  margin-bottom: 32px;
}

.controls {
  display: flex;
  gap: 12px;
  margin-bottom: 16px;
}

button.run {
  font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  font-size: 16px;
  background: transparent;
  color: var(--accent);
  border: 1px solid var(--accent);
  padding: 10px 18px;
  border-radius: 6px;
  cursor: pointer;
  transition: background-color 120ms ease, color 120ms ease;
}
button.run:hover:not(:disabled) {
  background: var(--accent);
  color: var(--bg);
}
button.run:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.status {
  font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  font-size: 14px;
  color: var(--muted);
  margin-bottom: 8px;
  min-height: 1.5em;
}

pre.output {
  background: var(--panel);
  border: 1px solid var(--panel-border);
  border-radius: 8px;
  color: var(--fg);
  font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  font-size: 15px;
  line-height: 1.55;
  padding: 20px 24px;
  height: 360px;
  overflow-y: auto;
  margin: 0 0 32px;
  white-space: pre-wrap;
  word-break: break-word;
}
pre.output .stderr { color: var(--muted); }
pre.output .meta   { color: var(--dim); }

.explain {
  color: var(--muted);
  font-size: 15px;
  margin-bottom: 32px;
}
.explain code {
  font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  color: var(--fg);
  background: var(--panel);
  padding: 1px 6px;
  border-radius: 4px;
}

.footer-links {
  display: flex;
  gap: 24px;
  font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  font-size: 14px;
}
.footer-links a {
  color: var(--accent);
  text-decoration: none;
}
.footer-links a:hover { color: var(--fg); }
```

- [ ] **Step 2: Commit**

```bash
git add web/demo.css
git commit -m "web: terminal-style CSS for the demo page"
```

---

## Task 4: Demo page HTML

**Files:**
- Create: `web/index.html`

- [ ] **Step 1: Write web/index.html**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>ccc — hello world, in your browser</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" href="demo.css">
  <script src="demo.js" defer></script>
</head>
<body>
  <div class="page">
    <div class="brand">ccc</div>
    <h1>hello world, in your browser</h1>
    <div class="subtitle">the same Zig core as <code>./ccc</code> — compiled to <code>wasm32-freestanding</code></div>

    <div class="controls">
      <button class="run" id="run-btn" disabled>loading…</button>
    </div>
    <div class="status" id="status">fetching ccc.wasm…</div>
    <pre class="output" id="output"></pre>

    <p class="explain">
      This page fetched <code>ccc.wasm</code> (a few hundred KB of WebAssembly
      with <code>hello.elf</code> embedded at compile time), instantiated it
      with no imports, and called the wasm <code>run()</code> export. UART
      output was captured into a buffer inside wasm linear memory; this page
      copied it out via <code>outputPtr()</code> and <code>outputLen()</code>.
      No server, no remote execution, no JavaScript dependencies — your
      browser is the RISC-V machine.
    </p>

    <div class="footer-links">
      <a href="../">← back to the deck</a>
      <a href="https://github.com/cyyeh/ccc">view source on GitHub</a>
    </div>
  </div>
</body>
</html>
```

(Note: no `type="module"` on the script tag — `web/demo.js` doesn't import anything, so plain `defer` is enough.)

- [ ] **Step 2: Commit**

```bash
git add web/index.html
git commit -m "web: demo page skeleton (HTML + script wiring)"
```

---

## Task 5: Browser glue (`web/demo.js`)

**Files:**
- Create: `web/demo.js`

- [ ] **Step 1: Write demo.js**

```js
const outputEl = document.getElementById("output");
const statusEl = document.getElementById("status");
const runBtn   = document.getElementById("run-btn");

function appendOutput(text, cls) {
  if (!text) return;
  const span = document.createElement("span");
  if (cls) span.className = cls;
  span.textContent = text;
  outputEl.appendChild(span);
  outputEl.scrollTop = outputEl.scrollHeight;
}

function setStatus(text) { statusEl.textContent = text; }
function clearOutput() { outputEl.textContent = ""; }

let instance = null;
let wasmSizeKB = 0;

async function load() {
  setStatus("fetching ccc.wasm…");
  const resp = await fetch("ccc.wasm");
  if (!resp.ok) throw new Error(`ccc.wasm: HTTP ${resp.status}`);
  const bytes = await resp.arrayBuffer();
  wasmSizeKB = (bytes.byteLength / 1024).toFixed(1);
  const result = await WebAssembly.instantiate(bytes, {});
  instance = result.instance;
  setStatus(`loaded · wasm ${wasmSizeKB} KB`);
  runBtn.disabled = false;
  runBtn.textContent = "▶ run ccc hello.elf";
}

function runDemo() {
  if (!instance) return;
  clearOutput();
  setStatus("running ccc /hello.elf…");
  runBtn.disabled = true;

  let exitCode = -100;
  try {
    exitCode = instance.exports.run();
  } catch (e) {
    appendOutput(`runtime error: ${e}\n`, "stderr");
  }

  const ptr = instance.exports.outputPtr();
  const len = instance.exports.outputLen();
  const bytes = new Uint8Array(instance.exports.memory.buffer, ptr, len);
  appendOutput(new TextDecoder().decode(bytes));
  appendOutput(`\n[exit ${exitCode}]\n`, "meta");

  setStatus(`done · exit ${exitCode}`);
  runBtn.disabled = false;
  runBtn.textContent = "▶ run again";
}

runBtn.addEventListener("click", runDemo);

load()
  .then(runDemo)
  .catch((e) => {
    setStatus(`error: ${e.message}`);
    appendOutput(`failed to load demo: ${e.message}\n`, "stderr");
  });
```

- [ ] **Step 2: Commit**

```bash
git add web/demo.js
git commit -m "web: demo glue — instantiate, call run(), copy out output buffer"
```

---

## Task 6: Local stage script

**Files:**
- Create: `scripts/stage-web.sh`

- [ ] **Step 1: Write scripts/stage-web.sh**

```bash
#!/usr/bin/env bash
# Stage build artifacts into web/ for local browser testing.
# Usage:  ./scripts/stage-web.sh
# Then:   python3 -m http.server -d . 8000
# Open:   http://localhost:8000/web/
set -euo pipefail

cd "$(dirname "$0")/.."

zig build wasm

cp zig-out/web/ccc.wasm web/ccc.wasm

echo "staged: web/ccc.wasm ($(wc -c <web/ccc.wasm) bytes)"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/stage-web.sh`

- [ ] **Step 3: Run it to verify**

Run: `./scripts/stage-web.sh`

Expected: builds succeed, prints `staged: web/ccc.wasm (NNNNN bytes)`. Verify:

```bash
ls -lh web/ccc.wasm
```

- [ ] **Step 4: Commit (script only — artifact is gitignored next task)**

```bash
git add scripts/stage-web.sh
git commit -m "scripts: stage-web.sh — build wasm into web/ for local serving"
```

---

## Task 7: Local browser verification

**No file changes — manual verification gate before touching the deck.**

- [ ] **Step 1: Start a local server**

Run (in a second terminal, or with `&` for background):

```bash
python3 -m http.server -d . 8000
```

- [ ] **Step 2: Open the demo in a browser**

Open: `http://localhost:8000/web/`

Expected:
- The page loads with the `ccc` brand mark, "hello world, in your browser" heading, and a button.
- Status shows `fetching ccc.wasm…` briefly, then `loaded · wasm NNN KB`, then `running ccc /hello.elf…`, then `done · exit 0`.
- The output `<pre>` shows: `hello world` and a `[exit 0]` meta line.

- [ ] **Step 3: Click "▶ run again"**

Expected: output clears, runs again, prints `hello world` and `[exit 0]`.

- [ ] **Step 4: Open the browser devtools Network tab and reload**

Expected: only `ccc.wasm`, `demo.js`, `demo.css`, and `index.html` are fetched. No 404s. No fetch for `hello.elf` (it's embedded).

- [ ] **Step 5: Open the devtools Console**

Expected: no uncaught errors.

- [ ] **Step 6: Stop the server**

- [ ] **Step 7: If anything failed, debug before continuing**

Common issues:
- Output is empty but `[exit 0]` appears → the `output_writer.end` field is named differently in this Zig version (or the `fixed` writer doesn't track `end`); check the actual Writer struct in `/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std/Io.zig` and adjust `outputLen()` accordingly
- Garbled UTF-8 → `TextDecoder` should handle it; check that `outputLen()` returns bytes, not codepoints
- `ccc.wasm` 404 → run `./scripts/stage-web.sh` to refresh the staged artifact
- Wasm instantiation fails → check console for the error; usually means the wasm module has unexpected imports (it shouldn't have any). Run `wasm-objdump -x web/ccc.wasm | grep import` to confirm.

Do not proceed to Task 8 until the demo prints `hello world` end-to-end.

---

## Task 8: Add `.demo-link` style to the deck

**Files:**
- Modify: `index.html` (deck) — append a CSS rule inside the existing `<style>` block

- [ ] **Step 1: Find the right CSS block**

Run: `grep -n "site-footer a:hover" index.html`

Expected: one match. The `.demo-link` rule goes immediately after the closing `}` of `.site-footer a:hover { color: #fff; }`, before the print-media query.

- [ ] **Step 2: Append the .demo-link CSS rule**

Use the Edit tool with surrounding context to insert this rule:

```css
    .demo-link {
      display: inline-block;
      margin-top: 24px;
      font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
      font-size: 22px;
      color: var(--accent);
      text-decoration: none;
      padding: 10px 18px;
      border: 1px solid var(--accent);
      border-radius: 8px;
      transition: background-color 140ms ease, color 140ms ease;
    }
    .demo-link:hover {
      background: var(--accent);
      color: var(--bg);
    }
```

- [ ] **Step 3: Verify the file still parses**

Run: `python3 -c "from html.parser import HTMLParser; HTMLParser().feed(open('index.html').read()); print('ok')"`

Expected: prints `ok`.

- [ ] **Step 4: Commit**

```bash
git add index.html
git commit -m "deck: add .demo-link style for web-demo links"
```

---

## Task 9: Add demo links to title + prologue slides

**Files:**
- Modify: `index.html` (deck) — two link insertions

- [ ] **Step 1: Add link to the title slide**

Find this block in `index.html`:

```html
  <section class="title" data-label="Title">
    <div class="brand">ccc</div>
    <div class="brand-rule"></div>
    <div class="title-line-1">a web browser, from scratch</div>
    <div class="title-line-2">a RISC-V computer in Zig · emulator → kernel → OS → network → browser</div>
  </section>
```

Insert before `</section>`:

```html
    <a class="demo-link" href="web/">▶ try it in your browser</a>
```

- [ ] **Step 2: Add link to the prologue/demo slide**

Find this block:

```html
    <pre class="code">$ zig build hello-elf
$ ./zig-out/bin/ccc zig-out/bin/hello.elf
<span class="a">hello world</span>
$ echo $?
<span class="a">0</span></pre>
  </section>
```

Insert after the closing `</pre>` and before `</section>`:

```html
    <a class="demo-link" href="web/">▶ run this in your browser</a>
```

- [ ] **Step 3: Verify links exist**

```bash
grep -c "demo-link" index.html      # expect 4 (CSS rule + hover + 2 links)
grep 'href="web/"' index.html       # expect 2 matches
```

- [ ] **Step 4: Commit**

```bash
git add index.html
git commit -m "deck: link title + prologue slides to web/ demo"
```

---

## Task 10: Web demo README

**Files:**
- Create: `web/README.md`

- [ ] **Step 1: Write web/README.md**

```markdown
# ccc — web demo

A single-page browser demo of [`ccc`](../), a from-scratch RISC-V CPU
emulator written in Zig. The same emulator modules that power the
native CLI (`cpu.zig`, `memory.zig`, `elf.zig`, `devices/*.zig`) are
cross-compiled to `wasm32-freestanding` via a thin entry point
(`src/web_main.zig`) and loaded into your browser, where they run
`hello.elf` and print `hello world`.

**Live:** https://cyyeh.github.io/ccc/web/

## How it works

1. `zig build wasm` cross-compiles `src/web_main.zig` to
   `wasm32-freestanding`, installed as `zig-out/web/ccc.wasm`.
2. `web_main.zig` `@embedFile`s `hello.elf` at compile time, captures
   UART output into a fixed in-wasm buffer, and exposes three exports:
   `run() -> i32`, `outputPtr() -> [*]u8`, `outputLen() -> u32`.
3. `demo.js` fetches `ccc.wasm`, calls `WebAssembly.instantiate(bytes, {})`
   (no imports needed), invokes `run()`, then reads the captured bytes
   from `instance.exports.memory.buffer` using `outputPtr()` + `outputLen()`.

There are zero JavaScript dependencies and zero WASM imports. The
browser is the RISC-V machine.

## Local development

```sh
./scripts/stage-web.sh                    # build + copy ccc.wasm into web/
python3 -m http.server -d . 8000          # any static server works
open http://localhost:8000/web/
```

`web/ccc.wasm` is gitignored — it is produced by `zig build wasm` and
overlaid into the Pages artifact in CI.

## Adding another demo (e.g., kernel.elf)

The page is structured so a second demo is a small additive change:

1. In `src/web_main.zig`, add another `@embedFile` (e.g., for `kernel.elf`)
   and an additional export (e.g., `run_kernel() -> i32`) that wires up
   the same Memory/Cpu/etc. with the new ELF.
2. Extend `scripts/stage-web.sh` and the `build-and-deploy` job in
   `.github/workflows/pages.yml` to ensure `kernel.elf` is built before
   `zig build wasm`.
3. Add a second `<button>` in `web/index.html` and a small handler in
   `web/demo.js` that calls `instance.exports.run_kernel()` instead of
   `run()`. The output-capture path is identical.
```

- [ ] **Step 2: Commit**

```bash
git add web/README.md
git commit -m "web: README explaining the demo + how to extend it"
```

---

## Task 11: Gitignore web artifacts

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Read current .gitignore**

Run: `cat .gitignore`

Expected: six lines — `zig-cache/`, `zig-out/`, `.zig-cache/`, `*.bin`, `.DS_Store`, `.worktrees/`.

- [ ] **Step 2: Append one line**

Add to the end of `.gitignore`:

```
web/ccc.wasm
```

(Just one line — no `web/hello.elf` since the ELF is embedded into the wasm in this design, not a separate file.)

- [ ] **Step 3: Verify**

```bash
git status web/ -s            # web/ccc.wasm must NOT appear if previously staged
git check-ignore web/ccc.wasm # expect path echoed
```

- [ ] **Step 4: Commit**

```bash
git add .gitignore
git commit -m "gitignore: web/ccc.wasm (built by zig)"
```

---

## Task 12: Update project README

**Files:**
- Modify: `README.md` (top-level)

- [ ] **Step 1: Add a "Live demo" line near the top**

Read `README.md` to find the spot. The current intro reads:

```markdown
# ccc — Claude Code Computer

Building a working RISC-V computer from scratch in Zig — emulator, kernel,
OS, networking, and a tiny text-mode web browser. No Linux. No TLS. No
graphics.

## Goal
```

Insert this block immediately after the intro paragraph (before `## Goal`):

```markdown
**Live demo:** [https://cyyeh.github.io/ccc/web/](https://cyyeh.github.io/ccc/web/)
— `ccc` cross-compiled to `wasm32-freestanding`, running `hello.elf` in your
browser. Same Zig core as the CLI; new ~80-line entry point for the browser.

```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "readme: link the live web demo"
```

---

## Task 13: GitHub Actions workflow

**Files:**
- Create: `.github/workflows/pages.yml`

- [ ] **Step 1: Create the workflows directory**

Run: `mkdir -p .github/workflows`

- [ ] **Step 2: Write pages.yml**

```yaml
name: pages

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: pages
  cancel-in-progress: false

jobs:
  test:
    name: test (zig build + e2e)
    runs-on: ubuntu-latest
    steps:
      - name: Checkout (with submodules)
        uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Set up Zig 0.16.0
        uses: mlugg/setup-zig@v1
        with:
          version: 0.16.0

      - name: zig build test
        run: zig build test

      - name: zig build e2e (RV32I hello)
        run: zig build e2e

      - name: zig build e2e-mul (RV32IMA)
        run: zig build e2e-mul

      - name: zig build e2e-trap (privilege/traps)
        run: zig build e2e-trap

      - name: zig build e2e-hello-elf (Phase 1 DoD)
        run: zig build e2e-hello-elf

      - name: zig build e2e-kernel (Phase 2 DoD)
        run: zig build e2e-kernel

      - name: zig build wasm (smoke-test cross-compile)
        run: zig build wasm

  build-and-deploy:
    name: build wasm + deploy Pages
    needs: test
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deploy.outputs.page_url }}
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Zig 0.16.0
        uses: mlugg/setup-zig@v1
        with:
          version: 0.16.0

      - name: Build wasm
        run: zig build wasm

      - name: Stage Pages artifact
        run: |
          mkdir -p _site/web
          cp index.html deck-stage.js .nojekyll _site/
          cp -r web/. _site/web/
          cp zig-out/web/ccc.wasm _site/web/ccc.wasm
          ls -lh _site _site/web

      - name: Configure Pages
        uses: actions/configure-pages@v5

      - name: Upload Pages artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: _site

      - name: Deploy to GitHub Pages
        id: deploy
        uses: actions/deploy-pages@v4
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/pages.yml
git commit -m "$(cat <<'EOF'
ci: pages workflow — test gate + build wasm + deploy GH Pages

test job runs on every PR + push to main; build-and-deploy runs only
on push to main and is gated on test passing.
EOF
)"
```

---

## Task 14: Push the branch and open PR

- [ ] **Step 1: Push the branch**

```bash
git push -u origin web-wasm-demo
```

- [ ] **Step 2: Open a PR**

```bash
gh pr create --title "web wasm demo + CI" --body "$(cat <<'EOF'
## Summary

- Cross-compile ccc to `wasm32-freestanding` via a new ~80-line
  `src/web_main.zig` entry point that imports the existing emulator
  modules verbatim.
- Add a single-page web demo in `web/` that runs `hello.elf` in the
  browser. Zero JS dependencies, zero WASM imports.
- Link to the demo from the deck's title slide and prologue slide.
- Add a GitHub Actions workflow that runs the existing test/e2e suite
  on every PR and (on `main`) deploys the deck + demo to GitHub Pages.

Spec: `docs/superpowers/specs/2026-04-25-web-wasm-demo-design.md`
Plan: `docs/superpowers/plans/2026-04-25-web-wasm-demo.md`

## Test plan

- [ ] CI `test` job is green
- [ ] After merge: CI `build-and-deploy` job is green
- [ ] After merge: https://cyyeh.github.io/ccc/web/ prints `hello world`
- [ ] After merge: deck title + prologue slides each have a working demo link
EOF
)"
```

- [ ] **Step 3: Watch the test job + wait for review**

Wait for the `test` job (or use `gh run watch`). Expected: green. After review, the user merges and the `build-and-deploy` job auto-runs.

---

## Task 15: One-time GitHub Pages settings flip (manual, for the user)

- [ ] **Step 1:** Go to `https://github.com/cyyeh/ccc/settings/pages`.
- [ ] **Step 2:** Under "Build and deployment" → "Source", change from "Deploy from a branch" to "GitHub Actions". Save.
- [ ] **Step 3:** After the next push to `main`, visit `https://cyyeh.github.io/ccc/web/`. Expected: the demo loads and prints `hello world`. If the deploy job fails with `Pages site not found`, the source flip wasn't saved — go back to Step 2.

---

## Definition of done (recap from spec)

- ✅ `https://cyyeh.github.io/ccc/web/` loads and prints `hello world` in Chrome / Firefox / Safari.
- ✅ Deck title + prologue slides each contain a working `web/` link.
- ✅ Push to `main` triggers the workflow; both jobs pass; Pages updates within ~3 minutes.
- ✅ PR triggers only the `test` job; failure blocks merge.
- ✅ `scripts/stage-web.sh` produces a working local demo.
- ✅ Top-level README mentions and links the web demo.
