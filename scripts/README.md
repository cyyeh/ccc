# scripts/

Debug and development scripts. None of these run in CI — the CI workflow
(`.github/workflows/pages.yml`) inlines the equivalent build + stage steps
for the web-demo deploy.

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

Build the wasm and copy it into `web/` so a local static server can serve
the browser demo end-to-end. Used by humans only — CI inlines the same
two steps in the `build-and-deploy` job.

```
./scripts/stage-web.sh
python3 -m http.server -d . 8000
open http://localhost:8000/web/
```

`web/ccc.wasm` is gitignored. Re-run the script after any change to
`demo/web_main.zig`, the emulator core, or `hello.elf`.
