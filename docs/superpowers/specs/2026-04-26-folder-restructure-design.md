# Folder restructure — design

**Status:** approved 2026-04-26
**Branch / worktree:** TBD (suggest `folder-restructure` at `.worktrees/folder-restructure`)
**Goal:** Reorganize the repo so the kernel (a substantial deliverable from Phase 2 onward) and the user-facing guest programs live in directories whose names match their roles, while keeping every existing `zig build` target green and every public link (Pages demo, README path references) intact.

## Why

The current layout has three problems:

1. **`tests/programs/kernel/` is the actual kernel.** It's the project's main deliverable from Phase 2 forward — not a test. A new reader looking for "the kernel" will not find it under `tests/`.
2. **User-facing demos sit next to internal test fixtures.** `snake/` and `hello/` are polished, shipped via the Pages demo. `mul_demo/`, `trap_demo/`, `plic_block_test/` are hand-encoded or asm-only proof-of-emulator-feature fixtures. The shared `tests/programs/` directory hides the distinction.
3. **`tests/` mixes host-side test scaffolding with guest binaries.** Today the directory contains both the `riscv-tests` submodule (host-side conformance harness) and what will eventually be a userland for the OS. As Phase 3.C+ adds more guest programs (shell, ping, browser), this conflation gets worse.

## Non-goals

- **Renaming files inside the moved directories.** This change is path-only. Internal file names (e.g., `kmain.zig`, `boot.S`) keep their current names.
- **Refactoring code inside the kernel or emulator.** Splitting modules, extracting sub-modules, etc., are out of scope.
- **Touching the riscv-tests submodule path.** `tests/riscv-tests/` and `tests/riscv-tests-shim/` stay where they are. No `.gitmodules` rewrite.
- **Renaming `web/`, `scripts/`, `docs/`, `zig-out/`.** Top-level non-source directories are untouched.
- **Renaming build target names** (`zig build kernel-elf`, `zig build e2e-snake`, etc.). Targets keep their current names; only their `b.path(...)` arguments change.
- **Updating frozen plan documents** in `docs/superpowers/plans/`. Those are historical; they freeze with the path references they had at the time. Only specs and READMEs that describe the *current* state are refreshed.

## Approach

### Resulting layout

```
src/
  emulator/                # current src/* moved here
    main.zig               # CLI entry
    lib.zig                # wasm-facing module shim
    wasm_main.zig          # NEW location of demo/web_main.zig
    cpu.zig  decoder.zig  execute.zig  memory.zig
    csr.zig  trap.zig  elf.zig  trace.zig
    devices/
      uart.zig  clint.zig  plic.zig  block.zig  halt.zig
  kernel/                  # current tests/programs/kernel/* moved here
    kmain.zig
    boot.S  trampoline.S  mtimer.S  swtch.S
    elfload.zig
    linker.ld
    verify_e2e.zig
    multiproc_verify_e2e.zig
    user/
      userprog.zig  userprog2.zig  user_linker.ld
programs/                  # guest binaries that run inside the emulator
  hello/                   # current tests/programs/hello/
  snake/                   # current tests/programs/snake/ (incl. game.zig + verify_e2e.zig + test_input.txt)
  mul_demo/                # current tests/programs/mul_demo/
  trap_demo/               # current tests/programs/trap_demo/
  plic_block_test/         # current tests/programs/plic_block_test/
tests/                     # host-side test scaffolding ONLY
  fixtures/                # ELFs for src/emulator/elf.zig unit tests
  riscv-tests/             # submodule (UNCHANGED PATH)
  riscv-tests-shim/        # (UNCHANGED PATH)
  riscv-tests-p.ld
  riscv-tests-s.ld
web/                       # GitHub Pages root (UNCHANGED)
scripts/                   # (UNCHANGED)
docs/                      # (UNCHANGED)
.github/                   # (UNCHANGED unless workflow pins paths — see Risks)
build.zig                  # path strings updated; target names unchanged
build.zig.zon              # (UNCHANGED)
README.md                  # Layout + Building tables refreshed at the end
```

### Three sub-decisions, locked in

1. **Kernel's embedded user payloads stay nested under the kernel.** `userprog.zig`, `userprog2.zig`, `user_linker.ld` move with the kernel to `src/kernel/user/`. They are build-time blobs the kernel embeds; not standalone programs the user runs.

2. **Per-program e2e verifiers stay next to their target.** `verify_e2e.zig` / `multiproc_verify_e2e.zig` move to `src/kernel/`. `tests/programs/snake/verify_e2e.zig` moves to `programs/snake/`. Co-located = easier to navigate; `tests/` stays focused on shared scaffolding (riscv-tests, fixtures for `src/emulator/elf.zig`).

3. **`demo/` collapses into `src/emulator/`.** `demo/web_main.zig` becomes `src/emulator/wasm_main.zig` and the empty `demo/` directory is removed. It's not a demo, it's a wasm entry point for the emulator.

### Migration plan (chunked, each chunk green before the next)

Each chunk = (a) `git mv` files; (b) update `build.zig` `b.path(...)` arguments; (c) update Zig `@import` paths where the relative path changed; (d) run the verification gate; (e) commit.

**Chunk 1 — `src/*` → `src/emulator/*`**
- Move the eleven `.zig` files and the `devices/` subdirectory.
- Update `build.zig` references.
- Intra-emulator `@import("...")` calls between siblings stay valid.
- Imports from *outside* `src/` (kernel verifier, `demo/web_main.zig`) update in later chunks.
- Gate: full verification suite.

**Chunk 2 — `tests/programs/kernel/*` → `src/kernel/*`**
- Move `kmain.zig`, all `.S` files, `elfload.zig`, `linker.ld`, both `*verify_e2e.zig` files, and the `user/` subdirectory.
- Update `build.zig` references.
- Update any `@import` from kernel files to `src/emulator/lib.zig` (or whichever emulator module the verifier uses).
- Gate: `e2e-kernel`, `e2e-multiproc-stub`, `kernel-elf`, `kernel-multi`, plus full suite.

**Chunk 3 — `tests/programs/{hello,snake,mul_demo,trap_demo,plic_block_test}/` → `programs/*`**
- Five `git mv` operations.
- Update `build.zig` references (~25 path strings).
- Update the `--input` path arg in the snake e2e step (`programs/snake/test_input.txt`).
- Gate: `e2e-hello-elf`, `e2e-snake`, `e2e`, `e2e-mul`, `e2e-trap`, `e2e-plic-block`, plus full suite.

**Chunk 4 — `demo/web_main.zig` → `src/emulator/wasm_main.zig`**
- `git mv` the file; remove the empty `demo/` directory.
- Update `build.zig` wasm target's `b.path(...)`.
- Update the `@import` of `lib.zig` inside the file if its relative path changed.
- Gate: `zig build wasm`, then `scripts/stage-web.sh` and a visual check that `web/index.html` runs both `hello.elf` and `snake.elf`.

**Chunk 5 — README updates**
- Top-level `README.md`: rewrite the "Layout" tree block; spot-check the "Building" table for any path mentions in flag/file columns.
- `web/README.md`: update path references (most are relative to `web/`, but check).
- `scripts/README.md`: update if any script descriptions reference moved paths.

### Verification gate (run at the end of every chunk)

```
zig build test
zig build e2e
zig build e2e-mul
zig build e2e-trap
zig build e2e-hello-elf
zig build e2e-kernel
zig build e2e-multiproc-stub
zig build e2e-plic-block
zig build e2e-snake
zig build riscv-tests
zig build wasm
zig build hello-elf
zig build kernel-elf
zig build kernel-multi
zig build snake-elf
zig build plic-block-test
zig build fixtures
```

Chunk 4 additionally runs `scripts/stage-web.sh` and asks for a visual check (snake plays, hello prints, ANSI rendering intact). The `web/` directory's gitignored `.elf` and `.wasm` artifacts are regenerated by the build; not manually moved.

## Risks

- **`build.zig` is 34 KB and references each program's path 4–8 times.** A missed path silently fails one target. Mitigation: the chunked verification gate catches a dropped target on the same commit it's introduced.
- **`@import` paths inside moved Zig files.** Most use sibling-relative imports that survive the move; cross-directory imports (e.g., kernel verifier importing the emulator) need explicit rewrites. Implementation plan enumerates these.
- **`.github/workflows/pages.yml` may hard-code paths.** Verify the workflow during implementation; update if needed.
- **In-flight branches/worktrees.** `.worktrees/` is non-empty. Concurrent work that touches `tests/programs/...` will conflict on rebase. Land or rebase those before this change. (Caller's responsibility, not blocking this design.)
- **GitHub Pages cache.** Pages serves the `web/` directory directly; no path moves there, so no risk to deployed URLs.

## Approval

Approved as of the user's "ok" on 2026-04-26. Implementation plan to follow at `docs/superpowers/plans/2026-04-26-folder-restructure-plan.md`.
