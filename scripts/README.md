# scripts/

Debug and development scripts. None of these run in CI.

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
