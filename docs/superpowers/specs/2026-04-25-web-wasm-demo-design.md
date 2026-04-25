# Web WASM demo — design

**Status:** approved 2026-04-25
**Branch / worktree:** `web-wasm-demo` at `.worktrees/web-wasm-demo`
**Goal:** A visitor of `https://cyyeh.github.io/ccc/` can click a link, land
on a page, and watch the actual `ccc` emulator binary — compiled to
WebAssembly — load `hello.elf` and print `hello world`. Same Zig source as
the CLI, no parallel implementation.

This is the smallest possible "the project works" experience for a deck
viewer who doesn't have a Zig toolchain handy.

## Why

The deck (`index.html`) is already on GitHub Pages. The "Prologue · the
demo" slide tells viewers what they'd see if they ran `zig build hello-elf
&& ./zig-out/bin/ccc zig-out/bin/hello.elf`. Today they have to take that on
faith. After this work they can press a button.

Bonus: also gives the project its first CI gate.

## Non-goals

- Run the Phase 2 `kernel.elf` demo. The page is structured so adding it
  later is a one-line addition, but the first ship is hello-only.
- Provide an interactive shell, file picker, or "upload your own ELF"
  feature. Not needed for the demo intent.
- Integrate the demo into a deck slide as an embedded iframe. Two link
  sites in the deck point out to a separate page; that's the whole
  integration.
- Add the `riscv-tests` conformance suite to CI. It needs an external
  RISC-V toolchain (~30s of apt + ~1 min of run); not a regression risk
  for the web demo and not worth the slowdown on every PR.

## Approach

**WASM target:** `wasm32-wasi`. Cross-compile `src/main.zig` unchanged —
Zig 0.16 supports the target out of the box. A small browser WASI
polyfill provides stdin/stdout, a virtual filesystem containing
`hello.elf`, and `proc_exit`. **Zero source changes to ccc.**

**WASI shim:** vendor [`@bjorn3/browser_wasi_shim`](https://github.com/bjorn3/browser_wasi_shim)
(MIT, ~10KB minified, single ES module, no runtime deps). Vendoring keeps
the demo offline-capable and immune to CDN drift.

**hello.elf delivery:** fetch as a separate file (`web/hello.elf`),
browser-cached. Not embedded in the WASM, not base64'd into the JS — the
ELF is the input, treating it as a fetched asset matches the CLI mental
model.

**Output rendering:** terminal-styled `<pre>` matching the deck's
existing `.code` class palette (`--bg`, `--fg`, `--accent`).
Auto-scrolling, fixed-height. Stderr inlined in a slightly dimmer color
so any error output is visible.

## Repository layout (additions)

```
.github/workflows/
  pages.yml                # test → build wasm → deploy Pages

web/                       # GitHub Pages serves this at /web/
  index.html               # demo page
  demo.js                  # WASI shim glue + run loop
  demo.css                 # terminal styling, deck palette
  vendor/
    browser_wasi_shim.js   # vendored, MIT
  README.md                # how it works + how to add another ELF

scripts/
  stage-web.sh             # local dev: build + copy artifacts into web/

# (build artifacts, produced by zig build, NOT committed)
web/ccc.wasm
web/hello.elf
```

`web/ccc.wasm` and `web/hello.elf` are produced by `zig build` and copied
into `web/` only inside CI's Pages artifact; locally, `scripts/stage-web.sh`
copies them so `python3 -m http.server` testing works. Both are
`.gitignore`d.

## Component details

### 1. `build.zig` — new `wasm` step

Add a single new step that cross-compiles `src/main.zig` for
`wasm32-wasi`, `ReleaseSmall`, with the artifact installed under
`zig-out/web/`:

```zig
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
wasm_exe.entry = .disabled;     // _start exported by WASI ABI
wasm_exe.rdynamic = true;
const install_wasm = b.addInstallArtifact(wasm_exe, .{
    .dest_dir = .{ .override = .{ .custom = "web" } },
});
b.step("wasm", "Cross-compile ccc to wasm32-wasi")
    .dependOn(&install_wasm.step);
```

Same `minimal_elf_fixture` import is test-only; harmless for the wasm
build.

### 2. `web/demo.js` — WASI runtime glue

Public surface: one function, `runDemo(elfPath)`, that:

1. Fetches `ccc.wasm` and the chosen ELF in parallel.
2. Constructs a WASI instance from `browser_wasi_shim` with these fds:
   - 0 (stdin): empty `MemoryFile`
   - 1 (stdout), 2 (stderr): `OpenFile`s wrapping `MemoryFile`s with an
     `onWrite` hook that decodes UTF-8 and appends to the page's
     `<pre id="output">` (stdout normal, stderr dimmer)
   - 3: `PreopenDirectory('/', { 'hello.elf': MemoryFile(elfBytes) })`
3. Instantiates the WASM module with `wasi_snapshot_preview1` imports.
4. Calls `wasi.start(instance)` inside try/catch (the shim's `proc_exit`
   throws to unwind).
5. Reports the exit code in the UI when the run finishes.

The `onWrite` hook is not built into bjorn3's `MemoryFile` directly. We
either subclass it (~15 lines) or use `ConsoleStdout.lineBuffered`, which
the shim ships with — pick whichever is cleaner once the source is in
hand. Either way, no functional risk.

### 3. `web/index.html` — the demo page

One page, deck-matching aesthetic:

- Header: `ccc` brand mark, title `hello world, in your browser`,
  one-line subtitle `the same Zig source as ./ccc — compiled to wasm32-wasi`.
- "▶ run ccc hello.elf" button. Auto-runs once on first paint so visitors
  who don't click still see output. Button text becomes "▶ run again"
  after first run.
- Terminal-style `<pre id="output">` matching deck `.code` styling,
  fixed height (~360px), auto-scrolls to bottom on append.
- Footer block: `← back to the deck` link, `view source on GitHub` link,
  three-line plain-English explanation of what just happened. File sizes
  shown approximately in prose ("a few hundred KB of WASM, a few KB of
  ELF") — no build-time substitution.

**Future kernel.elf path (per scope decision C):** `runDemo()` already
takes an `elfPath` argument. Adding a second demo means: one extra
`<button>`, one extra fetch, one extra `MemoryFile` entry. No structural
changes.

### 4. Deck integration — `index.html` (existing)

Two new link sites — title slide + prologue/demo slide:

```html
<!-- Title slide, after .title-line-2 -->
<a class="demo-link" href="web/">▶ try it in your browser →</a>

<!-- Prologue slide, after the existing <pre class="code"> -->
<a class="demo-link" href="web/">▶ run this in your browser →</a>
```

New CSS rule `.demo-link`: accent color, monospace font, subtle
inset border, hover transition that lightens it. Opens in same tab so
the browser back button returns to the deck.

`deck-stage.js` does not need changes — it's content-agnostic.

### 5. `.github/workflows/pages.yml` — CI workflow

Single workflow, two jobs:

| Job | Runs on | Steps |
|---|---|---|
| `test` | push to `main` + every PR | checkout (with submodules), setup Zig 0.16.0, `zig build test`, `zig build e2e`, `zig build e2e-mul`, `zig build e2e-trap`, `zig build e2e-hello-elf`, `zig build e2e-kernel`, `zig build wasm` (smoke-test the wasm cross-compile) |
| `build-and-deploy` | push to `main` only, `needs: test` | checkout, setup Zig, `zig build wasm hello-elf`, stage `_site/` (copy `index.html`, `deck-stage.js`, `.nojekyll`, `web/`, then overlay `ccc.wasm` + `hello.elf`), `actions/upload-pages-artifact@v3`, `actions/deploy-pages@v4` |

Permissions: `contents: read`, `pages: write`, `id-token: write` (Pages
deploy requires OIDC).

Concurrency: `group: pages, cancel-in-progress: false` (let an in-flight
deploy finish so we don't leave Pages in a half-published state).

`workflow_dispatch` trigger included for manual re-runs.

### 6. `scripts/stage-web.sh` — local dev convenience

Two-liner that runs `zig build wasm hello-elf` then copies the artifacts
into `web/` so `python3 -m http.server -d <repo-root> 8000` serves the
working demo at `http://localhost:8000/web/`. Used by humans only — CI
inlines the same logic.

## Manual one-time steps the user must do

1. **GitHub Pages source:** in repo Settings → Pages, change source from
   "Deploy from a branch" to "GitHub Actions". (CI cannot flip this
   itself.) Without this step the workflow's `actions/deploy-pages@v4`
   step will fail with a clear error message.
2. **First merge to main:** the deploy job only runs on `push` to `main`;
   PR runs validate via the `test` job only. Plan the first merge after
   the PR is reviewed.

## Testing strategy

- **Unit / e2e coverage of ccc itself:** the existing `zig build test`,
  `e2e`, `e2e-mul`, `e2e-trap`, `e2e-hello-elf`, `e2e-kernel` steps run
  on every push and every PR. No new tests needed for the emulator —
  the wasm build runs identical Zig source.
- **WASM build smoke test:** the `test` job runs `zig build wasm` so
  PRs catch wasm cross-compile regressions before main.
- **Web demo functional test:** manual for v1. Open
  `http://localhost:8000/web/` after `scripts/stage-web.sh`, confirm
  `hello world` appears, exit code = 0. A future Playwright /
  headless-Chromium gate is plausible but out of scope for this spec.

## Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `wasm32-wasi` build fails on a Zig stdlib I/O API used in `main.zig` | low — Zig 0.16's `std.Io` was designed for WASI parity | If it does fail, the spec is not invalidated; we fall back to a tiny `src/web_main.zig` (option B from brainstorming) and keep everything else identical. Localised change. |
| `browser_wasi_shim` doesn't implement an import ccc calls (e.g., a clock or random fn) | low — ccc's CLI is plain stdio + file read | Stub the missing import in `demo.js` (e.g., `clock_time_get` returning a fixed value). Document the stub. |
| WASM binary is too large for a snappy demo | low — `ReleaseSmall` should land under 500KB | If it's actually a problem, run `wasm-opt -Oz` in CI. Not pre-emptive. |
| GitHub Pages source not flipped to Actions | medium — easy oversight | Spec calls it out; first deploy will fail loudly with an actionable error. |

## Out of scope (explicitly)

- Adding the Phase 2 `kernel.elf` demo. It would just work — `kernel.elf`
  is another RISC-V binary that ccc loads, so no new infrastructure is
  needed; only a second button + fetch + `MemoryFile` entry. The Q2/C
  extensibility hook is in the design specifically so this can be a
  small follow-up PR. Just not v1.
- An interactive shell or stdin-driven UX. The current `main.zig` reads
  from a file and prints; matching that exactly is the win.
- Pre-rendered output as a fallback (e.g., showing static "hello world"
  if WASM fails). Either WASM works or we show the error — no
  fake-success path.
- A separate `pages-only` workflow split from the test job. Single
  workflow now; split later if CI duration becomes painful.

## Definition of done

- `https://cyyeh.github.io/ccc/web/` loads and prints `hello world` in a
  major modern browser (Chrome / Firefox / Safari).
- The deck title slide and prologue slide each contain a working
  `web/` link.
- A push to `main` triggers the workflow; both jobs pass; Pages updates
  within ~3 minutes.
- A PR triggers only the `test` job; failure blocks merge.
- `scripts/stage-web.sh` produces a working local demo.
- README mentions the web demo and links to it.
