# ccc — web demo

A single-page browser demo of [`ccc`](../), a from-scratch RISC-V CPU
emulator written in Zig. The same emulator modules that power the
native CLI (`cpu.zig`, `memory.zig`, `elf.zig`, `devices/*.zig`) are
cross-compiled to `wasm32-freestanding` via a thin entry point
(`demo/web_main.zig`) and loaded into your browser. Three RV32 programs
ship with the page:

- **`shell.elf`** (default) — a full Phase 3.E + 3.F shell. The page
  loads `kernel-fs.elf` (M-mode boot shim → S-mode kernel → cooked-mode
  console → fork/exec → on-disk init) plus `shell-fs.img` (a 4 MB FS
  image with `/bin/{sh,ls,cat,echo,mkdir,rm,edit}` + `/etc/motd`).
  Click the terminal, then type `ls /bin`, `cat /etc/motd`,
  `echo hi > /tmp/x`, `edit /etc/motd`, `^C` to cancel a foreground
  program, `exit` to halt. **Requires a physical keyboard — desktop
  or laptop only.** Disk writes live in wasm linear memory and reset
  on every page load.
- **`snake.elf`** — an interactive snake game. A bare M-mode
  supervisor drives a CLINT timer IRQ for the game tick and polls
  UART RX for input. Click the terminal, then move with `W` / `A` /
  `S` / `D`, press `Space` to start, `Q` to quit. **Requires a
  physical keyboard — desktop or laptop only**, mobile and tablet
  browsers can't send key input.
- **`hello.elf`** — non-interactive "hello world". Runs to halt and
  auto-displays its captured instruction trace.

**Live:** https://cyyeh.github.io/ccc/web/

## How it works

1. `zig build wasm` cross-compiles `demo/web_main.zig` to
   `wasm32-freestanding`, installed as `zig-out/web/ccc.wasm` (~38 KB).
2. `web_main.zig` exposes a chunked-step API rather than a blocking
   `run()`:
   - `runStart(elf_len, trace, disk_len) -> i32`, `runStep(max_instructions) -> i32`
   - `setMtimeNs(ns) -> void`, `pushInput(byte) -> void`
   - `outputPtr` / `consumeOutput` for UART output
   - `tracePtr` / `traceLen` for the optional instruction trace
   - `elfBufferPtr` / `elfBufferCap` for the in-wasm ELF load buffer
   - `diskBufferPtr` / `diskBufferCap` for the optional disk-image load buffer
3. `runner.js` is a Web Worker that fetches `ccc.wasm` and the
   selected ELF on demand, copies the ELF bytes into the wasm load
   buffer, and drives `runStep()` in 50 000-instruction chunks via
   `setTimeout`. Yielding between chunks lets the Worker service
   `pushInput` messages — a single blocking `run()` couldn't. When
   the selected program has a disk image (currently only `shell.elf`,
   which fetches `shell-fs.img`), the Worker fetches it in parallel
   with the ELF and copies it into a 4 MB `disk_buffer` exposed by the
   wasm via `diskBufferPtr/Cap`; `runStart` then receives a non-zero
   `disk_len` and wires the buffer slice into the emulator's block
   device.
4. `demo.js` (main thread) decodes captured UART bytes through a
   ~120-line ANSI interpreter (`ansi.js`, full-redraw subset) into a
   focusable `<pre>` and forwards key events to the Worker. The
   `<select>` swaps programs on demand without rebuilding the wasm.

Zero JavaScript dependencies, zero WASM imports — `WebAssembly.instantiate(bytes, {})`
takes an empty import object. The browser is the RISC-V machine.

## Local development

```sh
./scripts/stage-web.sh                    # build + copy all five wasm/ELF/disk artifacts into web/
python3 -m http.server -d . 8000          # any static server works
open http://localhost:8000/web/
```

`web/ccc.wasm`, `web/hello.elf`, `web/snake.elf`, `web/kernel-fs.elf`,
and `web/shell-fs.img` are gitignored — all five are produced by
`zig build wasm` and overlaid into the Pages artifact in CI. Run
`stage-web.sh` (or `zig build wasm` + the five `cp` commands it wraps)
before serving locally.

## Adding another demo

Programs are fetched on demand and copied into a fixed wasm-side load
buffer, so adding one is a static-asset + small JS change — no wasm
rebuild required:

1. Build the new `.elf` (must use the same UART MMIO + exit
   conventions ccc already understands) and drop it next to
   `index.html`.
2. Add an entry to `ELF_URLS` and an `<option>` to the `<select>` in
   `web/demo.js` / `web/index.html`.
3. If the program halts (vs. running forever like snake), optionally
   add its index to `TRACE_PROGRAMS` in `demo.js` to auto-display the
   instruction trace after halt.
