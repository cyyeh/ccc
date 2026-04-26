# scripts/

Debug and development scripts. None of these run in CI — the CI workflow
(`.github/workflows/pages.yml`) inlines the equivalent build + stage steps
for the web-demo deploy, and skips the QEMU-diff and run-snake helpers
(developer aids only).

## `qemu-diff.sh`

Compare per-instruction execution of an ELF in QEMU vs. our emulator. First
divergence is almost always the bug.

Requirements: `qemu-system-riscv32` on PATH (`brew install qemu` or
`apt install qemu-system-misc`).

```
scripts/qemu-diff.sh zig-out/bin/hello.elf
scripts/qemu-diff.sh zig-out/bin/hello.elf 500      # compare 500 instructions
```

Exit 0 = traces match over requested instruction count.
Exit 1 = divergence; diff printed to stdout.
Exit 2 = usage / environment error.

## `qemu-diff-kernel.sh`

Same idea as `qemu-diff.sh`, scoped to `zig-out/bin/kernel.elf` (the Phase 2
kernel). Wraps `qemu-diff.sh` with the trap-delegation + CLINT setup that
the kernel needs from QEMU's reference run. Used as a Phase 2 debug aid.

```
scripts/qemu-diff-kernel.sh
scripts/qemu-diff-kernel.sh 1000
```

Same exit-code conventions as `qemu-diff.sh`. Same QEMU requirement.

## `stage-web.sh`

Run `zig build wasm` and copy the three browser-demo artifacts into
`web/` so a local static server can serve the demo end-to-end:

- `web/ccc.wasm` — emulator core, ~38 KB.
- `web/hello.elf` — the non-interactive trace demo.
- `web/snake.elf` — the interactive snake game.

Used by humans only — CI's `build-and-deploy` job inlines the same
build + cp steps directly into the Pages staging step.

```
./scripts/stage-web.sh
python3 -m http.server -d . 8000
open http://localhost:8000/web/
```

All three files are gitignored. Re-run the script after any change to
`demo/web_main.zig`, the emulator core, `hello.elf`, or `snake.elf`.

## `run-snake.sh`

Play `zig-out/bin/snake.elf` in the CLI under raw-mode tty so single
WASD / Space / `q` keystrokes reach the guest UART without buffering.
Save / restore tty state on exit (including Ctrl+C). Equivalent to
`zig build run-snake`; the script form is convenient when iterating
on the snake program without rerunning the build graph.

```
zig build snake-elf       # builds zig-out/bin/snake.elf
./scripts/run-snake.sh
```

Errors out with a hint if `zig-out/bin/ccc` or `zig-out/bin/snake.elf`
isn't present.
