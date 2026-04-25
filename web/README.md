# ccc — web demo

A single-page browser demo of [`ccc`](../), a from-scratch RISC-V CPU
emulator written in Zig. The same emulator modules that power the
native CLI (`cpu.zig`, `memory.zig`, `elf.zig`, `devices/*.zig`) are
cross-compiled to `wasm32-freestanding` via a thin entry point
(`demo/web_main.zig`) and loaded into your browser, where they run
`hello.elf` and print `hello world`.

**Live:** https://cyyeh.github.io/ccc/web/

## How it works

1. `zig build wasm` cross-compiles `demo/web_main.zig` to
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

1. In `demo/web_main.zig`, add another `@embedFile` (e.g., for `kernel.elf`)
   and an additional export (e.g., `run_kernel() -> i32`) that wires up
   the same Memory/Cpu/etc. with the new ELF.
2. Extend `scripts/stage-web.sh` and the `build-and-deploy` job in
   `.github/workflows/pages.yml` to ensure `kernel.elf` is built before
   `zig build wasm`.
3. Add a second `<button>` in `web/index.html` and a small handler in
   `web/demo.js` that calls `instance.exports.run_kernel()` instead of
   `run()`. The output-capture path is identical.
