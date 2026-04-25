# Web WASM demo — design

**Status:** approved 2026-04-25 (revised same day to switch from `wasm32-wasi` to `wasm32-freestanding`)
**Branch / worktree:** `web-wasm-demo` at `.worktrees/web-wasm-demo`
**Goal:** A visitor of `https://cyyeh.github.io/ccc/` can click a link, land
on a page, and watch the actual `ccc` emulator core — compiled to
WebAssembly — load `hello.elf` and print `hello world`. Same Zig source
modules as the CLI (`cpu.zig`, `memory.zig`, `decoder.zig`, ...);
just a tiny new entry point file (`demo/web_main.zig`) for the browser.

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
  later is a small additive change, but the first ship is hello-only.
- Provide an interactive shell, file picker, or "upload your own ELF"
  feature. Not needed for the demo intent.
- Integrate the demo into a deck slide as an embedded iframe. Two link
  sites in the deck point out to a separate page; that's the whole
  integration.
- Add the `riscv-tests` conformance suite to CI. It needs an external
  RISC-V toolchain (~30s of apt + ~1 min of run); not a regression risk
  for the web demo and not worth the slowdown on every PR.

## Approach

**WASM target:** `wasm32-freestanding` (revised from initial `wasm32-wasi`
choice — see "Revision history" below). No WASI ABI; no JS-side WASI
shim. The wasm module exports a tiny, explicit interface and imports
nothing.

**Entry point:** new `demo/web_main.zig` (~80 lines). Imports the existing
emulator modules (`cpu.zig`, `memory.zig`, `elf.zig`, `devices/*.zig`) via
a single `ccc` named module exposed by `src/lib.zig` (a thin re-export
shim — see Component details for why one module, not six). Embeds
`hello.elf` at compile time via `@embedFile`. Captures
UART output into a fixed in-wasm buffer (`std.Io.Writer.fixed`). Uses a
no-op clock (`fn () i128 { return 0; }`) since `hello.elf` doesn't poll
mtime.

**Public wasm interface (exports):**
- `run() -> i32` — clears the output buffer, runs the embedded ELF,
  returns the exit code.
- `outputPtr() -> [*]const u8` — pointer to the output buffer (lives
  in linear memory).
- `outputLen() -> u32` — number of valid bytes in the output buffer.
- `memory` — auto-exported wasm linear memory.

**Public wasm interface (imports):** none. The module is self-contained.

**Browser-side:** ~30 lines of JS. `WebAssembly.instantiate(bytes)`,
call `run()`, copy bytes from `instance.exports.memory.buffer` using
`outputPtr()` + `outputLen()`, decode UTF-8, append to a `<pre>`.

**One small clint.zig change:** the existing `defaultClockSource()` in
`src/devices/clint.zig` calls `std.c.clock_gettime`, which won't link
against `wasm32-freestanding` (no libc) and isn't needed (`demo/web_main.zig`
doesn't call `Clint.initDefault`). Wrap it in a comptime switch on
`builtin.os.tag` so the freestanding branch returns `0` and pulls no
libc symbols. Native code path is byte-equivalent.

## Repository layout (additions)

```
.github/workflows/
  pages.yml                # test → build wasm → deploy Pages

demo/
  web_main.zig             # new: freestanding wasm entry point

src/
  lib.zig                  # new: re-export shim consumed by demo/web_main.zig

web/                       # GitHub Pages serves this at /web/
  index.html               # demo page
  demo.js                  # ~30 lines: instantiate, call run(), read output
  demo.css                 # terminal styling, deck palette
  README.md                # how the demo works + how to add another ELF

scripts/
  stage-web.sh             # local dev: build + copy wasm into web/

# (build artifacts, produced by zig build, NOT committed)
web/ccc.wasm
```

`hello.elf` is embedded into the wasm at compile time (no separate
`web/hello.elf` file needed). `web/ccc.wasm` is produced by
`zig build wasm` and overlaid into the Pages artifact in CI; locally,
`scripts/stage-web.sh` copies it. Gitignored.

## Component details

### 1. `build.zig` — new `wasm` step

Add a single new step that cross-compiles `demo/web_main.zig` for
`wasm32-freestanding`, `ReleaseSmall`, with the artifact installed
under `zig-out/web/`. A single `ccc` named module (rooted at
`src/lib.zig`) gives `demo/web_main.zig` access to the emulator
without escaping its own package root:

```zig
const wasm_target = b.resolveTargetQuery(.{
    .cpu_arch = .wasm32,
    .os_tag = .freestanding,
});
const ccc_module = b.createModule(.{
    .root_source_file = b.path("src/lib.zig"),
});
const wasm_exe = b.addExecutable(.{
    .name = "ccc",
    .root_module = b.createModule(.{
        .root_source_file = b.path("demo/web_main.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "ccc", .module = ccc_module },
        },
    }),
});
wasm_exe.entry = .disabled;        // we call our own export, not _start
wasm_exe.rdynamic = true;          // expose `export fn` symbols
const install_wasm = b.addInstallArtifact(wasm_exe, .{
    .dest_dir = .{ .override = .{ .custom = "web" } },
});
b.step("wasm", "Cross-compile ccc to wasm32-freestanding")
    .dependOn(&install_wasm.step);
```

Why one `ccc` module instead of six (`cpu`, `memory`, …)? The emulator
files cross-import each other via relative paths (`cpu.zig` does
`@import("memory.zig")`, etc.), so declaring each as its own module
trips Zig's "file exists in modules X and Y" check. Funneling everything
through `src/lib.zig` keeps every emulator file inside one module tree.

The `wasm` step depends on `hello.elf` being built first (since
`web_main.zig` does `@embedFile("../zig-out/bin/hello.elf")`):

```zig
install_wasm.step.dependOn(b.getInstallStep()); // ensures hello-elf is built first
// or, more precisely:
install_wasm.step.dependOn(&install_hello_elf.step);
```

The implementer chooses whichever dependency wiring matches the existing
`install_hello_elf` variable name in build.zig.

### 2. `demo/web_main.zig` — freestanding entry point

~80 lines. Pulls the existing emulator modules in via the single `ccc`
named module wired up by build.zig (rooted at `src/lib.zig`):

```zig
const std = @import("std");
const ccc = @import("ccc");
const cpu_mod = ccc.cpu;
const mem_mod = ccc.memory;
const halt_dev = ccc.halt;
const uart_dev = ccc.uart;
const clint_dev = ccc.clint;
const elf_mod = ccc.elf;

// hello.elf is embedded at compile time. The build graph guarantees
// this file is fresh before the wasm build runs.
const hello_elf = @embedFile("../zig-out/bin/hello.elf");

// 16 KB is comfortable headroom for a "hello world" run. Increase if
// future demos generate more output.
var output_buf: [16 * 1024]u8 = undefined;
var output_writer: std.Io.Writer = .fixed(&output_buf);

// hello.elf doesn't poll mtime, so a constant clock is sufficient.
fn zeroClock() i128 { return 0; }

// 16 MiB of guest RAM is plenty for hello.elf (which runs in a few KB).
// Adjustable via a compile-time constant if future demos need more.
const RAM_SIZE: usize = 16 * 1024 * 1024;

export fn outputPtr() [*]const u8 { return &output_buf; }
export fn outputLen() u32 { return @intCast(output_writer.end); }

export fn run() i32 {
    output_writer.end = 0; // reset for re-runs

    var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var halt = halt_dev.Halt.init();
    var uart = uart_dev.Uart.init(&output_writer);
    var clint = clint_dev.Clint.init(zeroClock);

    var mem = mem_mod.Memory.init(a, &halt, &uart, &clint, null, RAM_SIZE)
        catch return -1;
    defer mem.deinit();

    const result = elf_mod.parseAndLoad(hello_elf, &mem) catch return -2;
    mem.tohost_addr = result.tohost_addr;

    var cpu = cpu_mod.Cpu.init(&mem, result.entry);
    cpu.run() catch return -3;

    output_writer.flush() catch {};
    return @intCast(halt.exit_code orelse 0);
}
```

This file replaces, for the wasm target, what `main.zig` does for the CLI:
parse args (none — the ELF is embedded), wire devices, load ELF, run CPU,
return exit code. No `std.process.Init`, no `std.Io.File`, no filesystem,
no argv. Everything that crosses the wasm boundary does so explicitly via
`export fn`.

The exit codes (-1, -2, -3) are private to the wasm interface — the JS
side displays them as "[exit -2]" etc. for debugging. Positive exits
match the guest's halt code.

### 3. `web/demo.js` — JS runtime

~30 lines. No WASI shim. No vendored dependencies.

```js
const outputEl = document.getElementById("output");
const statusEl = document.getElementById("status");
const runBtn   = document.getElementById("run-btn");

let instance = null;

async function load() {
  setStatus("fetching ccc.wasm…");
  const resp = await fetch("ccc.wasm");
  if (!resp.ok) throw new Error(`ccc.wasm: ${resp.status}`);
  const bytes = await resp.arrayBuffer();
  const result = await WebAssembly.instantiate(bytes, {});
  instance = result.instance;
  setStatus(`loaded · wasm ${(bytes.byteLength / 1024).toFixed(1)} KB`);
  runBtn.disabled = false;
  runBtn.textContent = "▶ run ccc hello.elf";
}

function runDemo() {
  clearOutput();
  setStatus("running ccc /hello.elf…");
  runBtn.disabled = true;

  const exitCode = instance.exports.run();
  const ptr = instance.exports.outputPtr();
  const len = instance.exports.outputLen();
  const bytes = new Uint8Array(instance.exports.memory.buffer, ptr, len);
  appendOutput(new TextDecoder().decode(bytes));
  appendOutput(`\n[exit ${exitCode}]\n`, "meta");

  setStatus(`done · exit ${exitCode}`);
  runBtn.disabled = false;
  runBtn.textContent = "▶ run again";
}

// (helpers: setStatus, clearOutput, appendOutput defined inline)
runBtn.addEventListener("click", runDemo);
load().then(runDemo).catch((e) => {
  setStatus(`error: ${e.message}`);
  appendOutput(`failed: ${e.message}\n`, "stderr");
});
```

**Future kernel.elf path (per scope decision C):** add another export
(`run_kernel() -> i32`) in `demo/web_main.zig` that uses
`@embedFile("../zig-out/bin/kernel.elf")`. Add a second button in
`index.html`. Add ~5 lines of JS to call the new export. No WASI plumbing
to retro-fit — the `run/outputPtr/outputLen/memory` interface stays.

### 4. `web/index.html` — the demo page

Single page, deck-matching aesthetic:

- Header: `ccc` brand mark, title `hello world, in your browser`,
  one-line subtitle `the same Zig core as ./ccc — compiled to wasm32-freestanding`.
- "▶ run ccc hello.elf" button. Auto-runs once on first paint so visitors
  who don't click still see output. Button text becomes "▶ run again"
  after first run.
- Terminal-style `<pre id="output">` matching deck `.code` styling,
  fixed height (~360px), auto-scrolls to bottom on append.
- Footer block: `← back to the deck` link, `view source on GitHub` link,
  three-line plain-English explanation. File sizes shown approximately
  in prose ("a few hundred KB of WASM").

### 5. `src/devices/clint.zig` — comptime clock-source switch

Wrap `defaultClockSource` in a comptime switch on `builtin.os.tag`:

```zig
const builtin = @import("builtin");

fn defaultClockSource() i128 {
    switch (comptime builtin.os.tag) {
        .freestanding => return 0,           // wasm32-freestanding (web demo)
        .wasi => {                            // (kept for future flexibility)
            var ns: u64 = undefined;
            _ = std.os.wasi.clock_time_get(.MONOTONIC, 1, &ns);
            return @intCast(ns);
        },
        else => {                             // POSIX hosts (macOS/Linux/etc.)
            var ts: std.c.timespec = undefined;
            if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
            const sec: i128 = @intCast(ts.sec);
            const nsec: i128 = @intCast(ts.nsec);
            return sec * 1_000_000_000 + nsec;
        },
    }
}
```

Native code path is byte-equivalent (just wrapped in a switch arm).
The `freestanding` branch is the only one ever taken in the wasm build
and pulls no libc symbols — meaning even if Zig's DCE doesn't remove
`defaultClockSource`, the wasm build links cleanly.

### 6. Deck integration — `index.html` (existing)

Two new link sites — title slide + prologue/demo slide:

```html
<!-- Title slide, after .title-line-2 -->
<a class="demo-link" href="web/">▶ try it in your browser →</a>

<!-- Prologue slide, after the existing <pre class="code"> -->
<a class="demo-link" href="web/">▶ run this in your browser →</a>
```

New CSS rule `.demo-link`: accent color, monospace, subtle border,
hover transition. Opens in same tab so the browser back button returns
to the deck.

`deck-stage.js` does not need changes — it's content-agnostic.

### 7. `.github/workflows/pages.yml` — CI workflow

Single workflow, two jobs:

| Job | Runs on | Steps |
|---|---|---|
| `test` | push to `main` + every PR | checkout (with submodules), setup Zig 0.16.0, `zig build test`, `zig build e2e`, `zig build e2e-mul`, `zig build e2e-trap`, `zig build e2e-hello-elf`, `zig build e2e-kernel`, `zig build wasm` (smoke-test the wasm cross-compile) |
| `build-and-deploy` | push to `main` only, `needs: test` | checkout, setup Zig, `zig build wasm`, stage `_site/` (copy `index.html`, `deck-stage.js`, `.nojekyll`, `web/`, then overlay `ccc.wasm`), `actions/upload-pages-artifact@v3`, `actions/deploy-pages@v4` |

Permissions: `contents: read`, `pages: write`, `id-token: write` (Pages
deploy requires OIDC).

Concurrency: `group: pages, cancel-in-progress: false` (let an in-flight
deploy finish so we don't leave Pages in a half-published state).

`workflow_dispatch` trigger included for manual re-runs.

### 8. `scripts/stage-web.sh` — local dev convenience

Two-liner that runs `zig build wasm` then copies the artifact into
`web/` so `python3 -m http.server -d <repo-root> 8000` serves the
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
  the wasm build runs identical Zig modules.
- **WASM build smoke test:** the `test` job runs `zig build wasm` so
  PRs catch wasm cross-compile regressions before main.
- **Web demo functional test:** manual for v1. Open
  `http://localhost:8000/web/` after `scripts/stage-web.sh`, confirm
  `hello world` appears, exit code = 0. A future Playwright /
  headless-Chromium gate is plausible but out of scope for this spec.

## Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `wasm32-freestanding` build fails because `std.heap.wasm_allocator` or `std.Io.Writer.fixed` API has changed in 0.16 | low — both are in 0.16's stable API | Adapt the API call once the implementer confirms the actual signature. The functional design (fixed buffer + arena allocator + capture writer) is stable; only spelling shifts. |
| `defaultClockSource` is still linked in despite never being called from `demo/web_main.zig` | low (we explicitly handle this with the comptime switch) | The comptime-switched freestanding branch has no libc symbols, so the link succeeds either way. |
| `Uart` writer interface (`*std.Io.Writer`) doesn't accept a `fixed` writer | very low — `fixed` returns the abstract `Writer` type by design | If it does, fall back to a custom Writer impl with a 30-line VTable. |
| WASM binary too large | low — `ReleaseSmall` of just the emulator core (no WASI) plus an embedded ~few-KB ELF should land well under 200KB | If it's actually a problem, run `wasm-opt -Oz` in CI. Not pre-emptive. |
| GitHub Pages source not flipped to Actions | medium — easy oversight | Spec calls it out; first deploy will fail loudly with an actionable error. |

## Out of scope (explicitly)

- Adding the Phase 2 `kernel.elf` demo. It would just work — `kernel.elf`
  is another RISC-V binary that ccc loads, so no new infrastructure is
  needed; only a second `@embedFile` + a second exported `run_*()`
  function + a second button. The Q2/C extensibility hook is in the
  design specifically so this can be a small follow-up PR. Just not v1.
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

## Revision history

- **2026-04-25 (initial):** chose `wasm32-wasi` + vendored
  `@bjorn3/browser_wasi_shim` for "no source changes to ccc" — same
  `src/main.zig` cross-compiles to both targets via WASI ABI.
- **2026-04-25 (revised):** switched to `wasm32-freestanding` + a new
  thin `demo/web_main.zig` entry point. Reasons:
  - The wasi path required a libc-linkage workaround in `clint.zig`
    anyway (the `std.c.clock_gettime` call wouldn't link against
    `wasm32-wasi`'s libc-less default). Once we needed source touching,
    the "no source changes" advantage of wasi evaporated.
  - Freestanding gives a smaller, simpler wasm (no WASI ABI overhead;
    explicit one-function export interface) and zero JS-side dependencies
    (no vendored shim, no virtual FS).
  - Browser-side glue shrinks from ~150 lines + 10KB shim to ~30 lines.
  - The `clint.zig` change is now a comptime switch over
    `builtin.os.tag` — a minimal, principled improvement that makes the
    file portable rather than a one-off WASI workaround.
