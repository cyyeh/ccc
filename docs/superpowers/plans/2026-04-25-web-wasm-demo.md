# Web WASM demo — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cross-compile `ccc` to `wasm32-wasi`, ship a single-page web demo to GitHub Pages that runs `hello.elf` in the browser, and add a CI workflow that gates Pages deploy on the existing test suite.

**Architecture:** Same `src/main.zig` source compiled twice — native CLI and `wasm32-wasi`. A vendored browser WASI polyfill (bjorn3's `browser_wasi_shim`, ~10KB MIT) wires WASI imports to a JS runtime that captures stdout/stderr into a terminal-style `<pre>` and exposes `hello.elf` through a virtual preopen dir. A single GitHub Actions workflow runs the existing test suite and (on `main`) deploys the deck + demo to Pages.

**Tech Stack:** Zig 0.16 (`wasm32-wasi` target, `ReleaseSmall`), `@bjorn3/browser_wasi_shim` (vendored ESM), GitHub Actions (`actions/setup-zig`, `actions/upload-pages-artifact@v3`, `actions/deploy-pages@v4`).

**Spec:** `docs/superpowers/specs/2026-04-25-web-wasm-demo-design.md`

**Working directory:** all commands assume cwd = `/Users/cyyeh/Desktop/ccc/.worktrees/web-wasm-demo` (the worktree root). Branch: `web-wasm-demo`.

---

## File Structure

**New files:**
- `web/index.html` — demo page
- `web/demo.js` — WASI shim glue + run loop
- `web/demo.css` — terminal styling matching deck palette
- `web/vendor/browser_wasi_shim.js` — vendored shim (single ESM file)
- `web/README.md` — how the demo works + how to add another ELF
- `scripts/stage-web.sh` — local dev: build wasm + hello.elf, copy into `web/`
- `.github/workflows/pages.yml` — single workflow with test + deploy jobs
- `docs/superpowers/plans/2026-04-25-web-wasm-demo.md` — this file

**Modified files:**
- `build.zig` — add `wasm` step (cross-compile `src/main.zig` to `wasm32-wasi`, install to `zig-out/web/`)
- `index.html` (deck) — add `.demo-link` CSS class + two link sites (title slide + prologue slide)
- `README.md` — mention the live web demo
- `.gitignore` — ignore `web/ccc.wasm`, `web/hello.elf`

---

## Task ordering rationale

1. Tasks 1–2 prove the wasm build works (cheapest blocker — if `wasm32-wasi` fails on `main.zig`, everything else needs revisiting).
2. Tasks 3–7 build the demo page bottom-up (vendor → CSS → HTML → JS → stage script).
3. Task 8 is the manual local-browser verification gate before touching the deck.
4. Tasks 9–10 wire the deck links.
5. Tasks 11–13 finalize artifacts (web README, .gitignore, project README).
6. Task 14 is the CI workflow — last because all the prior work needs to be in place for the deploy step to do anything meaningful.
7. Task 15 documents the manual GH Pages settings flip.

---

## Task 1: Cross-compile `ccc` to `wasm32-wasi`

**Files:**
- Modify: `build.zig` (append a new `wasm` step before the closing `}` of `build()`)

- [ ] **Step 1: Find the right insertion point in build.zig**

Read the end of `build.zig` to confirm where to add the new step. The new block goes after the last existing `b.step(...)` call but before the closing `}` of the `build` function.

Run: `tail -30 build.zig`

Expected: see the closing `}` of `pub fn build(b: *std.Build) void { ... }`. Add the new code immediately above it.

- [ ] **Step 2: Append the wasm step**

Add this block at the bottom of `build()` (just above the closing `}`):

```zig
    // === Phase 1.W — Web demo: cross-compile ccc to wasm32-wasi ===
    // Same src/main.zig as the native CLI; a browser WASI shim
    // provides stdin/stdout, args, and a virtual preopen dir.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    const wasm_exe = b.addExecutable(.{
        .name = "ccc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        }),
    });
    // The minimal_elf_fixture import is test-only and harmless here.
    wasm_exe.root_module.addAnonymousImport("minimal_elf_fixture", .{
        .root_source_file = b.path("tests/fixtures/minimal_elf.zig"),
    });
    // wasm32-wasi exports `_start` per the WASI ABI; no separate entry.
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;
    const install_wasm = b.addInstallArtifact(wasm_exe, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
    });
    const wasm_step = b.step("wasm", "Cross-compile ccc to wasm32-wasi");
    wasm_step.dependOn(&install_wasm.step);
```

- [ ] **Step 3: Run the wasm build**

Run: `zig build wasm`

Expected: exits 0, no output, produces `zig-out/web/ccc.wasm`. Verify:

```bash
ls -lh zig-out/web/ccc.wasm
file zig-out/web/ccc.wasm
```

Expected `file` output contains: `WebAssembly (wasm) binary module`.

If the build fails:
- If error is "entry point not found" → remove `wasm_exe.entry = .disabled;` (older Zig versions don't have it as a property; setting `wasm_exe.entry_point = ...` instead)
- If error mentions `_start` not exported → set `wasm_exe.rdynamic = true;` (already in the snippet) and re-check
- If error is about a stdlib API (e.g., `std.Io.Dir`, `std.process.Init`) being unavailable on `wasm32-wasi` → STOP. The `wasm32-wasi` Zig target doesn't support that API. Switch to plan B (freestanding + `src/web_main.zig`). Report the error and ask before changing direction.

- [ ] **Step 4: Verify the native build still works**

Run: `zig build`

Expected: exits 0, produces `zig-out/bin/ccc` as before. (Sanity check — adding the wasm step must not have broken anything.)

- [ ] **Step 5: Commit**

```bash
git add build.zig
git commit -m "$(cat <<'EOF'
build: add zig build wasm step for wasm32-wasi cross-compile

Same src/main.zig source as the native CLI, ReleaseSmall, installed
to zig-out/web/ccc.wasm. Foundation for the browser demo.
EOF
)"
```

---

## Task 2: Vendor `browser_wasi_shim`

**Files:**
- Create: `web/vendor/browser_wasi_shim.js` (single ESM bundle, ~10KB)
- Create: `web/vendor/.gitkeep` is unnecessary — the shim file is the directory's reason to exist

- [ ] **Step 1: Create the directory**

Run: `mkdir -p web/vendor`

Expected: directory exists. (No file inside yet.)

- [ ] **Step 2: Download the shim from npm via esm.sh**

Run:

```bash
curl -fsSL "https://esm.sh/@bjorn3/browser_wasi_shim@0.4.1?bundle&target=es2022" -o web/vendor/browser_wasi_shim.js
```

Expected: file exists, ~10–30KB. Verify:

```bash
ls -lh web/vendor/browser_wasi_shim.js
head -5 web/vendor/browser_wasi_shim.js
```

Expected `head` output: looks like a JS module (starts with `/* esm.sh ... */` or similar comment header).

If the download fails or the version is unavailable, fall back to:

```bash
# Alternate: latest version
curl -fsSL "https://esm.sh/@bjorn3/browser_wasi_shim?bundle&target=es2022" -o web/vendor/browser_wasi_shim.js
```

If that also fails, the implementer should `npm install @bjorn3/browser_wasi_shim` in a temporary directory and bundle the dist file manually with `esbuild` or just concatenate the dist files. Report and ask if no quick path works.

- [ ] **Step 3: Verify the shim's exported names**

The demo.js (Task 5) imports specific names from the shim. Confirm what's exported:

```bash
grep -E '^export ' web/vendor/browser_wasi_shim.js | head -20
```

Expected: see exports including (at least) `WASI`, `File`, `OpenFile`, `PreopenDirectory`, `ConsoleStdout`. **Write down the exact names** — Task 5's demo.js imports must match. If any name differs (e.g., `Directory` vs `MemoryDirectory`), use the actual exported name in Task 5.

- [ ] **Step 4: Commit**

```bash
git add web/vendor/browser_wasi_shim.js
git commit -m "$(cat <<'EOF'
web: vendor @bjorn3/browser_wasi_shim (MIT)

ES module shim that maps wasi_snapshot_preview1 imports to a JS
runtime — used by the browser demo to provide stdout/stderr capture
and a virtual preopen dir containing hello.elf.
EOF
)"
```

---

## Task 3: Demo page CSS

**Files:**
- Create: `web/demo.css`

- [ ] **Step 1: Write demo.css**

Create `web/demo.css` with this content (palette mirrors the deck's `--bg` / `--fg` / `--accent`):

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

## Task 4: Demo page HTML skeleton

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
  <script type="module" src="demo.js" defer></script>
</head>
<body>
  <div class="page">
    <div class="brand">ccc</div>
    <h1>hello world, in your browser</h1>
    <div class="subtitle">the same Zig source as <code>./ccc</code> — compiled to <code>wasm32-wasi</code></div>

    <div class="controls">
      <button class="run" id="run-btn" disabled>loading…</button>
    </div>
    <div class="status" id="status">fetching ccc.wasm and hello.elf…</div>
    <pre class="output" id="output"></pre>

    <p class="explain">
      This page fetched <code>ccc.wasm</code> (a few hundred KB of WebAssembly)
      and <code>hello.elf</code> (a few KB of RISC-V), then ran them with
      <a href="vendor/browser_wasi_shim.js">a small WASI shim</a>.
      No server, no remote execution — your browser is the RISC-V machine.
    </p>

    <div class="footer-links">
      <a href="../">← back to the deck</a>
      <a href="https://github.com/cyyeh/ccc">view source on GitHub</a>
    </div>
  </div>
</body>
</html>
```

- [ ] **Step 2: Commit**

```bash
git add web/index.html
git commit -m "web: demo page skeleton (HTML + script wiring)"
```

---

## Task 5: WASI runtime glue (`web/demo.js`)

**Files:**
- Create: `web/demo.js`

> **Note:** the imports below assume the names you confirmed in Task 2 Step 3. If your shim version exports different names (e.g., `Directory` vs `PreopenDirectory`, or no `ConsoleStdout`), substitute the real names. The functional logic (preopen `/`, capture stdout/stderr, instantiate, call `start`) is the same.

- [ ] **Step 1: Write demo.js**

```js
import {
  WASI,
  File,
  OpenFile,
  PreopenDirectory,
  ConsoleStdout,
} from "./vendor/browser_wasi_shim.js";

const outputEl = document.getElementById("output");
const statusEl = document.getElementById("status");
const runBtn   = document.getElementById("run-btn");

function appendOutput(text, cls) {
  const span = document.createElement("span");
  if (cls) span.className = cls;
  span.textContent = text;
  outputEl.appendChild(span);
  outputEl.scrollTop = outputEl.scrollHeight;
}

function setStatus(text) { statusEl.textContent = text; }
function clearOutput() { outputEl.textContent = ""; }

// Cache fetched bytes so "run again" doesn't re-fetch.
let wasmBytes = null;
let elfBytes  = null;

async function preload() {
  setStatus("fetching ccc.wasm and hello.elf…");
  const [wasmResp, elfResp] = await Promise.all([
    fetch("ccc.wasm"),
    fetch("hello.elf"),
  ]);
  if (!wasmResp.ok) throw new Error(`ccc.wasm: ${wasmResp.status}`);
  if (!elfResp.ok)  throw new Error(`hello.elf: ${elfResp.status}`);
  wasmBytes = await wasmResp.arrayBuffer();
  elfBytes  = new Uint8Array(await elfResp.arrayBuffer());
  setStatus(`loaded · wasm ${(wasmBytes.byteLength / 1024).toFixed(1)} KB · elf ${elfBytes.byteLength} B`);
  runBtn.disabled = false;
  runBtn.textContent = "▶ run ccc hello.elf";
}

async function runDemo(elfPath = "hello.elf") {
  if (!wasmBytes || !elfBytes) await preload();
  clearOutput();
  setStatus(`running ccc /${elfPath}…`);
  runBtn.disabled = true;

  const fds = [
    new OpenFile(new File([])),                             // 0: stdin (empty)
    ConsoleStdout.lineBuffered((line) => appendOutput(line + "\n")),         // 1: stdout
    ConsoleStdout.lineBuffered((line) => appendOutput(line + "\n", "stderr")), // 2: stderr
    new PreopenDirectory("/", new Map([
      [elfPath, new File(elfBytes)],
    ])),                                                    // 3: preopen "/"
  ];

  const wasi = new WASI(["ccc", "/" + elfPath], [], fds);
  const { instance } = await WebAssembly.instantiate(wasmBytes, {
    wasi_snapshot_preview1: wasi.wasiImport,
  });

  let exitCode = 0;
  try {
    wasi.start(instance);
  } catch (e) {
    // The shim throws to unwind on proc_exit; check for an exit code.
    if (typeof e === "object" && e !== null && "code" in e) {
      exitCode = e.code;
    } else if (e && e.message && /exit code: (\d+)/.test(e.message)) {
      exitCode = Number(RegExp.$1);
    } else {
      appendOutput(`\n[runtime error] ${e}\n`, "stderr");
      exitCode = -1;
    }
  }

  appendOutput(`\n`, "meta");
  appendOutput(`[exit ${exitCode}]\n`, "meta");
  setStatus(`done · exit ${exitCode}`);
  runBtn.disabled = false;
  runBtn.textContent = "▶ run again";
}

runBtn.addEventListener("click", () => runDemo());

// Auto-run on first load so visitors see output without clicking.
preload()
  .then(() => runDemo())
  .catch((e) => {
    setStatus(`error: ${e.message}`);
    appendOutput(`failed to load demo: ${e.message}\n`, "stderr");
  });
```

- [ ] **Step 2: Commit**

```bash
git add web/demo.js
git commit -m "web: WASI runtime glue — fetch wasm+elf, capture stdio, run"
```

---

## Task 6: Local dev stage script

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

zig build wasm hello-elf

cp zig-out/web/ccc.wasm web/ccc.wasm
cp zig-out/bin/hello.elf web/hello.elf

echo "staged: web/ccc.wasm ($(wc -c <web/ccc.wasm) bytes), web/hello.elf ($(wc -c <web/hello.elf) bytes)"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/stage-web.sh`

- [ ] **Step 3: Run it to verify**

Run: `./scripts/stage-web.sh`

Expected: builds succeed, prints `staged: web/ccc.wasm (NNNNN bytes), web/hello.elf (MMM bytes)`. Verify:

```bash
ls -lh web/ccc.wasm web/hello.elf
```

Both files present.

- [ ] **Step 4: Commit (script only — artifacts are gitignored next task)**

```bash
git add scripts/stage-web.sh
git commit -m "scripts: stage-web.sh — build wasm+hello.elf into web/ for local serving"
```

---

## Task 7: Ignore staged web artifacts

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Read current .gitignore**

Run: `cat .gitignore`

Expected output (from baseline): six lines — `zig-cache/`, `zig-out/`, `.zig-cache/`, `*.bin`, `.DS_Store`, `.worktrees/`.

- [ ] **Step 2: Append two lines**

Add to the end of `.gitignore`:

```
web/ccc.wasm
web/hello.elf
```

- [ ] **Step 3: Verify the staged artifacts are now ignored**

Run: `git status web/ -s`

Expected: only the source files (`web/index.html`, `web/demo.js`, `web/demo.css`, `web/vendor/browser_wasi_shim.js`) should appear if they weren't already committed. `web/ccc.wasm` and `web/hello.elf` must NOT appear.

Run: `git check-ignore web/ccc.wasm web/hello.elf`

Expected output: both paths echoed (proves they're ignored).

- [ ] **Step 4: Commit**

```bash
git add .gitignore
git commit -m "gitignore: web/ccc.wasm and web/hello.elf (built by zig)"
```

---

## Task 8: Local browser verification

**No file changes — manual verification gate before touching the deck.**

- [ ] **Step 1: Start a local server**

Run (in a second terminal, or with `&` for background):

```bash
python3 -m http.server -d . 8000
```

Or, if `python3` isn't available, any other static-file server rooted at the worktree.

- [ ] **Step 2: Open the demo in a browser**

Open: `http://localhost:8000/web/`

Expected:
- The page loads with the `ccc` brand mark, "hello world, in your browser" heading, and a button.
- Status shows `fetching ccc.wasm and hello.elf…` briefly.
- Status updates to `loaded · wasm NNN KB · elf NN B`, then `running ccc /hello.elf…`, then `done · exit 0`.
- The output `<pre>` shows: `hello world` (and a `[exit 0]` meta line).

- [ ] **Step 3: Click "▶ run again"**

Expected: output clears, runs again, prints `hello world` and `[exit 0]`.

- [ ] **Step 4: Open the browser devtools Network tab and reload**

Expected: `ccc.wasm` and `hello.elf` are fetched. No 404s.

- [ ] **Step 5: Open the devtools Console**

Expected: no uncaught errors. (Some shim implementations log warnings about unsupported imports — those are fine as long as the run completes.)

- [ ] **Step 6: Stop the server**

Kill the `python3 -m http.server` process.

- [ ] **Step 7: If anything failed, debug before continuing**

Common issues:
- Shim import names don't match (Task 5 imports vs Task 2 exports) → fix imports in `web/demo.js`, recommit
- `proc_exit` not throwing → not all shim versions throw on exit; the demo's exit-code parsing falls back gracefully, but verify the output still appears
- WASM compile error in browser → check console for `WebAssembly.instantiate` rejection; usually means wasm file is corrupted or not a wasm binary (re-run `zig build wasm`)
- `path_open` for `/hello.elf` fails (no such file) → preopen dir wasn't set up correctly; check that `PreopenDirectory("/", ...)` is at index 3 in `fds` and the path the WASM passes matches `/hello.elf`

Do not proceed to Task 9 until the demo prints `hello world` end-to-end.

---

## Task 9: Add `.demo-link` style to the deck

**Files:**
- Modify: `index.html` (deck) — append a CSS rule inside the existing `<style>` block

- [ ] **Step 1: Find the right CSS block to append to**

Run: `grep -n "site-footer a:hover" index.html`

Expected: one match; this is the last rule before the print-media query and the closing `</style>`. Add the new rule immediately after the matched line's block ends.

- [ ] **Step 2: Append the .demo-link CSS rule**

Find the line `.site-footer a:hover { color: #fff; }` and insert the new rule on the line below `}` that closes its block. Use the Edit tool to make this change with surrounding context.

CSS rule to add:

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

Expected: prints `ok`. (Sanity check that the edit didn't break the HTML.)

- [ ] **Step 4: Commit**

```bash
git add index.html
git commit -m "deck: add .demo-link style for web-demo links"
```

---

## Task 10: Add demo links to title + prologue slides

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

Insert one new line right before `</section>`:

```html
    <a class="demo-link" href="web/">▶ try it in your browser</a>
```

The block becomes:

```html
  <section class="title" data-label="Title">
    <div class="brand">ccc</div>
    <div class="brand-rule"></div>
    <div class="title-line-1">a web browser, from scratch</div>
    <div class="title-line-2">a RISC-V computer in Zig · emulator → kernel → OS → network → browser</div>
    <a class="demo-link" href="web/">▶ try it in your browser</a>
  </section>
```

- [ ] **Step 2: Add link to the prologue/demo slide**

Find this block in `index.html`:

```html
    <pre class="code">$ zig build hello-elf
$ ./zig-out/bin/ccc zig-out/bin/hello.elf
<span class="a">hello world</span>
$ echo $?
<span class="a">0</span></pre>
  </section>
```

Insert one new line right after the closing `</pre>`, before `</section>`:

```html
    <a class="demo-link" href="web/">▶ run this in your browser</a>
```

The block becomes:

```html
    <pre class="code">$ zig build hello-elf
$ ./zig-out/bin/ccc zig-out/bin/hello.elf
<span class="a">hello world</span>
$ echo $?
<span class="a">0</span></pre>
    <a class="demo-link" href="web/">▶ run this in your browser</a>
  </section>
```

- [ ] **Step 3: Verify links exist**

Run: `grep -c "demo-link" index.html`

Expected: `4` (CSS rule + hover rule + two link instances). If you see `2`, the CSS edit (Task 9) didn't land — check.

Run: `grep 'href="web/"' index.html`

Expected: two matches.

- [ ] **Step 4: (Manual) refresh the deck in browser**

If you still have a server running, open `http://localhost:8000/` and verify:
- Title slide shows the "▶ try it in your browser" button under the subtitle.
- Prologue slide shows the "▶ run this in your browser" button under the code block.
- Clicking either navigates to `/web/` and the demo loads.

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "deck: link title + prologue slides to web/ demo"
```

---

## Task 11: Web demo README

**Files:**
- Create: `web/README.md`

- [ ] **Step 1: Write web/README.md**

```markdown
# ccc — web demo

A single-page browser demo of [`ccc`](../), a from-scratch RISC-V CPU
emulator written in Zig. The same `src/main.zig` source that produces the
native CLI is cross-compiled to `wasm32-wasi` and loaded into your
browser, where it runs `hello.elf` and prints `hello world`.

**Live:** https://cyyeh.github.io/ccc/web/

## How it works

1. `zig build wasm` cross-compiles `src/main.zig` to `wasm32-wasi`,
   installed as `zig-out/web/ccc.wasm`.
2. `vendor/browser_wasi_shim.js` (vendored
   [`@bjorn3/browser_wasi_shim`](https://github.com/bjorn3/browser_wasi_shim),
   MIT) implements `wasi_snapshot_preview1` in JavaScript: stdin/stdout,
   args, environ, and a virtual file system.
3. `demo.js` fetches `ccc.wasm` + `hello.elf`, builds a WASI instance with
   `hello.elf` mounted at `/`, and calls `wasi.start(instance)`.
4. UART output from inside the emulator becomes WASI `fd_write(1, ...)`,
   which the shim hands to a callback that appends to the page's
   `<pre>`.

The browser is the RISC-V machine. There is no server execution.

## Local development

```sh
./scripts/stage-web.sh                    # build + copy artifacts into web/
python3 -m http.server -d . 8000          # any static server works
open http://localhost:8000/web/
```

`web/ccc.wasm` and `web/hello.elf` are gitignored — they are produced
by `zig build` and overlaid into the Pages artifact in CI.

## Adding another demo (e.g., kernel.elf)

The page is structured so a second demo is a tiny addition:

1. Add a build step or use an existing one (e.g., `zig build kernel-elf`)
   so the ELF lands somewhere copyable.
2. Extend `scripts/stage-web.sh` and the `build-and-deploy` job in
   `.github/workflows/pages.yml` to copy the second ELF into `web/`.
3. Add a second `<button>` in `index.html`.
4. In `demo.js`, fetch the second ELF and call `runDemo("kernel.elf")`.
   The `runDemo(elfPath)` API was designed for this; no other changes
   needed.
```

- [ ] **Step 2: Commit**

```bash
git add web/README.md
git commit -m "web: README explaining the demo + how to extend it"
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
— `ccc` cross-compiled to `wasm32-wasi`, running `hello.elf` in your
browser. Same Zig source as the CLI.

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

Expected: directory exists.

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

      - name: Build wasm + hello.elf
        run: zig build wasm hello-elf

      - name: Stage Pages artifact
        run: |
          mkdir -p _site/web
          cp index.html deck-stage.js .nojekyll _site/
          cp -r web/. _site/web/
          cp zig-out/web/ccc.wasm _site/web/ccc.wasm
          cp zig-out/bin/hello.elf _site/web/hello.elf
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

- [ ] **Step 3: Local syntax sanity check (optional but cheap)**

If `actionlint` is installed, run: `actionlint .github/workflows/pages.yml`

Expected: no errors. If `actionlint` is not installed, skip — the real check is in CI.

- [ ] **Step 4: Commit**

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

## Task 14: Push the branch and verify CI

**Files:** none — this is a verification + handoff step.

- [ ] **Step 1: Push the branch**

```bash
git push -u origin web-wasm-demo
```

Expected: branch published to `origin`. The PR will trigger the `test` job; the `build-and-deploy` job will be skipped (it's gated on `push to main`).

- [ ] **Step 2: Open a PR**

```bash
gh pr create --title "web wasm demo + CI" --body "$(cat <<'EOF'
## Summary

- Cross-compile `ccc` to `wasm32-wasi` (new `zig build wasm` step).
- Add a single-page web demo in `web/` that runs `hello.elf` in the
  browser via `@bjorn3/browser_wasi_shim` (vendored, MIT, ~10KB).
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

- [ ] **Step 3: Watch the test job**

Wait for the `test` job to finish (or use `gh run watch`). Expected: green.

If the `test` job fails:
- `e2e-kernel` flaking due to tick-count nondeterminism → re-run; the test should be deterministic but check
- `wasm` step failing on a Zig stdlib API → STOP. This is the same risk as Task 1 Step 3. Discuss before continuing.
- Submodule checkout failing → confirm `submodules: recursive` is in the checkout step

- [ ] **Step 4: Wait for review and merge**

Once the user reviews and merges, the `build-and-deploy` job will run automatically.

---

## Task 15: One-time GitHub Pages settings flip (manual)

**This task is for the user, not the implementer.** The CI workflow uses GitHub's "Pages from Actions" deployment, which requires a one-time settings change.

- [ ] **Step 1: Open repo settings**

Go to `https://github.com/cyyeh/ccc/settings/pages`.

- [ ] **Step 2: Set source to "GitHub Actions"**

Under "Build and deployment" → "Source", change from "Deploy from a branch" to "GitHub Actions". Save.

- [ ] **Step 3: Verify after first deploy**

After the next push to `main`, visit `https://cyyeh.github.io/ccc/web/`. Expected: the demo page loads and prints `hello world`.

If the deploy job fails with `Get Pages site failed` or `Pages site not found`, the source flip wasn't saved — go back to Step 2.

---

## Definition of done (recap from spec)

- ✅ `https://cyyeh.github.io/ccc/web/` loads and prints `hello world` in Chrome / Firefox / Safari.
- ✅ Deck title + prologue slides each contain a working `web/` link.
- ✅ Push to `main` triggers the workflow; both jobs pass; Pages updates within ~3 minutes.
- ✅ PR triggers only the `test` job; failure blocks merge.
- ✅ `scripts/stage-web.sh` produces a working local demo.
- ✅ Top-level README mentions and links the web demo.
