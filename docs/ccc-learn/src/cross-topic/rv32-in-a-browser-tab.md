# Walkthrough: RV32 in a Browser Tab

> The same Zig core that runs as `ccc` on macOS also runs as `ccc.wasm` in a browser tab. This walkthrough explains how — and why the trick is mostly about Zig comptime, not about wasm magic.

The live demo at https://cyyeh.github.io/ccc/web/ is a real RISC-V emulator running in your browser. You can pick `kernel-fs.elf + shell-fs.img` and use the same shell from this site. Or `snake.elf` and play. Or `hello.elf` and watch the trace.

The whole `web/` directory is ~30 KB of JS + ~30 KB of wasm + a few static assets. The Zig core that compiles to that wasm is *the same core* that builds the CLI binary — same `Cpu`, same `Memory`, same `decoder`, same `execute`. No fork, no parallel codebase.

This walkthrough explains the architecture: what's shared, what's split, what tricks make it work.

---

## Part 1: The Three-Way Build

`build.zig` defines three artifacts that share most of their source:

| Build target | Output | Source roots |
|--------------|--------|---------------|
| `zig build` | `zig-out/bin/ccc` (host binary) | `src/emulator/main.zig` + `src/emulator/*.zig` |
| `zig build wasm` | `zig-out/web/ccc.wasm` | `demo/web_main.zig` + `src/emulator/*.zig` |
| `zig build kernel-fs` | `zig-out/bin/kernel-fs.elf` (RV32 ELF) | `src/kernel/*.zig` (cross-compiled to RV32) |

Notice: `src/emulator/*.zig` is shared between the CLI host and the wasm host. Same files. The CLI binary opens stdin/stdout via libc; the wasm binary exposes byte-pump functions to JS. But the CPU, memory, devices, decoder, executor — all the same files.

This works because Zig has **strong cross-compilation** built in. `zig build wasm` invokes the same compiler against the same source with `-target wasm32-freestanding`. As long as the code is target-aware where it needs to be, it just works.

---

## Part 2: `comptime` to the Rescue

The places where the CLI and wasm builds *can't* share are the places that interface with the host:

- Reading the wall clock (`clock_gettime` on POSIX; doesn't exist on freestanding).
- Allocating memory (host's libc malloc; wasm's no-libc).
- Writing to stdout (POSIX write(1, ...); wasm has to expose a buffer).
- Reading from stdin (same).

Zig's `comptime` lets us write the same source with target-aware branches that compile to *only one* of the alternatives:

```zig
fn defaultClockSource() i128 {
    switch (comptime builtin.os.tag) {
        .freestanding => return 0,                              // wasm
        .wasi => /* wasi clock */,
        else => /* libc clock_gettime */,                       // POSIX
    }
}
```

This compiles to:
- On macOS: just the libc branch. The freestanding branch is dead code, eliminated.
- On wasm: just the freestanding branch. No libc symbols referenced. The link succeeds because nothing calls `clock_gettime`.

In **the same Zig file**. No #ifdef hell. No two-version-of-source-tree maintenance.

---

## Part 3: The wasm Entry — `demo/web_main.zig`

`demo/web_main.zig` is the wasm-only top-level. It exports functions for JS to call:

```zig
pub export fn runStart(elf_ptr: u32, elf_len: u32) i32 { ... }
pub export fn runStep(max_instrs: u32) i32 { ... }
pub export fn setMtimeNs(ns: i64) void { ... }
pub export fn pushInput(byte: u32) void { ... }
pub export fn consumeOutput(out_ptr: u32, out_max: u32) u32 { ... }
pub export fn setDiskSlice(ptr: u32, len: u32) void { ... }
```

JS-side, in `web/runner.js`:

```js
const wasm = await WebAssembly.instantiateStreaming(fetch('ccc.wasm'), {});
wasm.exports.runStart(elf_ptr, elf_len);
while (true) {
    const status = wasm.exports.runStep(10000);  // run up to 10K instructions
    if (status === HALT) break;
    // drain output, push input, yield to event loop
    setTimeout(loop, 0);
}
```

The chunked execution is critical. Without it, a single `runStep(infinity)` would block the JS Worker forever — the page would freeze.

---

## Part 4: Why `wfi` Doesn't Block in wasm

The CPU's `idleSpin` function (called by `wfi`) normally spins for up to 10s wall-clock waiting for an interrupt. In the wasm host, that 10s spin would freeze the worker.

The fix is `Cpu.step_mode`:

```zig
pub fn idleSpin(self: *Cpu) void {
    if (self.step_mode) return;  // wasm escape — don't block
    ...
}

pub fn stepOne(self: *Cpu) StepError!void {
    self.step_mode = true;
    defer self.step_mode = false;
    try self.step();
    ...
}
```

In CLI mode, `cpu.run` is the loop, calling `step()` directly. `step_mode = false`. `wfi` blocks normally.

In wasm mode, `runStep` calls `cpu.stepOne` in a loop. `stepOne` sets `step_mode = true` for the duration. If the guest hits `wfi`, `idleSpin` returns immediately. The instruction completes (PC advances past wfi via `execute.zig`'s wfi arm). Loop continues to the next instruction.

This is **5 lines of code** that turn a hangs-the-page bug into a working emulator. The kernel's idle loop becomes a tight no-op spin in wasm; perf is poor (the wasm guest never sleeps), but correctness is preserved.

---

## Part 5: Time in wasm

Wasm freestanding can't read the host clock. The `clint.zig` default returns 0:

```zig
.freestanding => return 0,
```

If `mtime` is always 0, the kernel's timer never fires. That breaks the scheduler.

The fix: `web_main.zig` exposes `setMtimeNs(ns)`, and `clint.zig` is constructed with a custom clock source that reads the override:

```zig
// In web_main.zig:
var current_mtime_ns: i64 = 0;
fn webClock() i128 { return @intCast(current_mtime_ns); }

pub export fn setMtimeNs(ns: i64) void {
    current_mtime_ns = ns;
}

pub export fn runStart(...) i32 {
    var clint = Clint.init(&webClock);
    ...
}
```

JS-side: between `runStep` chunks, JS calls `setMtimeNs(performance.now() * 1e6)` to advance the clock to wall time. The kernel sees `mtime` advancing at real-world rate, and timers fire at the right intervals.

---

## Part 6: I/O in wasm

The CLI host's UART writes go through `std.Io.Writer` to stdout. Wasm has no stdout. Instead, the wasm UART writer collects bytes into a wasm-side buffer:

```zig
const OutputBuf = struct {
    buf: [4096]u8,
    len: u32 = 0,
};
var out_buf: OutputBuf = .{};

const Writer = ... // a writer that appends to out_buf
```

JS calls `consumeOutput(out_ptr, out_max)` periodically. The wasm-side function memcopy's from `out_buf.buf[0..len]` into the JS-provided buffer in linear memory, returns the count, resets `len = 0`. JS reads the linear memory, passes the bytes to the ANSI interpreter for rendering.

For input: JS calls `pushInput(byte)`. Wasm-side `pushInput` calls `uart.pushRx(byte)`. PLIC source 10 fires (eventually). Trap path proceeds normally.

---

## Part 7: The Disk

CLI: `--disk shell-fs.img` opens a host file. `block.zig`'s `disk_file` is set; `performTransfer` reads/writes via `pread`/`pwrite`.

Wasm: there's no host filesystem. Instead, JS fetches the image with `fetch('shell-fs.img')`, gets a `Uint8Array`, copies it into wasm linear memory, and calls `setDiskSlice(ptr, len)`. Wasm-side:

```zig
pub export fn setDiskSlice(ptr: u32, len: u32) void {
    const slice = @as([*]u8, @ptrFromInt(ptr))[0..len];
    block_global.disk_slice = slice;
    block_global.status = @intFromEnum(.Ready);
}
```

`performTransfer` checks `disk_slice` first:

```zig
if (self.disk_slice) |slice| {
    // memcpy between slice and ram
} else if (self.disk_file) |f| {
    // pread/pwrite (CLI path)
}
```

Writes update the in-memory slice. They don't persist across page reload (no host file to write back to), but within a session, persistence works — `e2e-persist`-style behavior.

---

## Part 8: The ANSI Renderer (`web/ansi.js`)

When the kernel writes ANSI escape sequences (`\x1b[2J`, etc.), the wasm UART buffer collects raw bytes. JS reads them. They need to be rendered as terminal output.

`web/ansi.js` is a ~120-line ANSI subset interpreter. It maintains a 2D grid of characters + a cursor position. As bytes stream in, it:

- Plain bytes: write at cursor, advance.
- ESC `[` ... letter: parse as CSI sequence.
- Handles a small set: `2J` (clear), `H` (home), `r;cH` (move), `A/B/C/D` (arrows), `?25h/l` (cursor visibility), UTF-8 reassembly.

Output is rendered as a `<pre>` of the grid. The page redraws when the grid changes.

This is the *only* ANSI implementation in the project. The CLI doesn't need it (the host terminal interprets directly). The browser tab does.

---

## Part 9: The Web Worker

If the Zig wasm runs on the JS main thread, every `runStep` chunk blocks the page. So `web/runner.js` runs in a Web Worker:

```js
// In demo.js (main thread):
const worker = new Worker('runner.js');
worker.postMessage({type: 'load', elf_url: 'kernel-fs.elf'});
worker.onmessage = (e) => {
    if (e.data.type === 'output') ansi.feed(e.data.bytes);
    if (e.data.type === 'halt') console.log('halted');
};

// In runner.js (worker):
const wasm = await fetch_and_instantiate();
wasm.exports.runStart(...);
function loop() {
    wasm.exports.runStep(10000);
    const out = drain_output();
    if (out.length) postMessage({type: 'output', bytes: out});
    if (status === HALT) postMessage({type: 'halt'});
    else setTimeout(loop, 0);
}
loop();
```

Main thread handles input (keypresses) and rendering. Worker handles execution. They communicate via `postMessage`.

Yields to the JS event loop happen via `setTimeout(0)`. This lets the main thread render between chunks.

---

## Part 10: ELF fetched at runtime, not embedded

A subtle but important design: ELFs (`hello.elf`, `snake.elf`, `kernel-fs.elf`, `shell-fs.img`) are *not* baked into `ccc.wasm`. They're separate static assets fetched at runtime:

```js
// Fetch the chosen program when user picks it
const elfBytes = await fetch(`./hello.elf`).then(r => r.arrayBuffer());
const ptr = wasm.exports.alloc_buffer(elfBytes.byteLength);
new Uint8Array(wasm.memory.buffer, ptr, elfBytes.byteLength).set(elfBytes);
wasm.exports.runStart(ptr, elfBytes.byteLength);
```

Why? Because the wasm grows with embedded ELFs. With kernel-fs.elf at 1.7 MB and shell-fs.img at 4 MB, embedding would bloat the wasm to >5 MB. By fetching at runtime, the wasm stays at ~30 KB and ELFs are cached separately by the browser.

The wasm exports `alloc_buffer` (or similar) to give JS a chunk of linear memory to write into.

---

## What this all teaches

1. **Zig comptime is the secret weapon.** One source tree, multiple targets, no #ifdef. The tag-based switches in clint.zig and cpu.zig are surgical — only the bits that *can't* be the same between targets vary.

2. **`step_mode` is a 5-line elegant fix** for an "infinite loop hangs the browser" problem. By making `wfi` a no-op in chunked mode, the same loop semantics work in two very different schedulers.

3. **MMIO is portable.** The block device works whether `disk_file` (CLI) or `disk_slice` (wasm) is set. Same protocol, different backing.

4. **Web Workers are how you keep a wasm app responsive.** Main thread for UI; worker for compute. This is universal for any wasm app that does long-running work.

5. **ANSI is a skill the host needs.** A real terminal interprets escape sequences for free; a browser tab needs `web/ansi.js`. ~120 lines for a teaching subset.

6. **ELFs as runtime fetches.** Don't bake everything into one giant wasm. Use the browser's caching layer.

The end result: same emulator, same kernel, same shell, same demo programs — running in your browser tab as a static site. No server, no plugins, no app store. Just HTML + JS + wasm + assets, deployable to any static-file host.

If `ccc`'s Phase 4 networking ships, the wasm can talk over WebSockets. If Phase 5's text browser ships, you'd be browsing within a browser tab.
