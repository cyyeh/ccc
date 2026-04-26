# Folder Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `src/*` → `src/emulator/*`, `tests/programs/kernel/` → `src/kernel/`, `tests/programs/{hello,snake,mul_demo,trap_demo,plic_block_test}/` → `programs/*`, and consolidate the three host-side e2e verifiers at `tests/e2e/{kernel,multiproc,snake}.zig`. `demo/` is unchanged. Every `zig build *` target stays green at every chunk boundary.

**Architecture:** Path-only refactor in four committed chunks. Internal `@import("./...")` calls between sibling files survive every move because they're relative. The wasm build's `@import("ccc")` resolves through `build.zig`'s named module — only `build.zig` changes for that. Host-side e2e verifiers import only `std` and spawn the emulator as a subprocess, so their renames are purely path changes. Each chunk: `git mv` the files, edit `build.zig`, run the full verification gate, commit.

**Tech Stack:** Zig 0.16.0, git (`git mv`, `git worktree`), bash.

**Reference spec:** `docs/superpowers/specs/2026-04-26-folder-restructure-design.md`

---

## File structure (post-restructure)

```
src/
  emulator/                 # was src/
    main.zig  lib.zig
    cpu.zig  decoder.zig  execute.zig  memory.zig
    csr.zig  trap.zig  elf.zig  trace.zig
    devices/
      uart.zig  clint.zig  plic.zig  block.zig  halt.zig
  kernel/                   # was tests/programs/kernel/ (minus the e2e verifiers)
    kmain.zig
    boot.S  trampoline.S  mtimer.S  swtch.S
    elfload.zig
    linker.ld
    user/
      userprog.zig  userprog2.zig  user_linker.ld
programs/                   # NEW top-level dir
  hello/  snake/  mul_demo/  trap_demo/  plic_block_test/
tests/
  e2e/                      # NEW
    kernel.zig              # was tests/programs/kernel/verify_e2e.zig
    multiproc.zig           # was tests/programs/kernel/multiproc_verify_e2e.zig
    snake.zig               # was tests/programs/snake/verify_e2e.zig
  fixtures/                 # unchanged
  riscv-tests/              # unchanged (submodule)
  riscv-tests-shim/         # unchanged
  riscv-tests-p.ld  riscv-tests-s.ld
demo/                       # unchanged (kept top-level per spec amendment)
  web_main.zig
web/  scripts/  docs/  .github/  build.zig  build.zig.zon  README.md
```

**Build.zig path changes (33 strings total):**

| Chunk | Count | Change |
|---|---|---|
| 2 (Chunk 1) | 2 | `src/main.zig` → `src/emulator/main.zig`; `src/lib.zig` → `src/emulator/lib.zig` |
| 3 (Chunk 2) | 15 | 13 prefix `tests/programs/kernel/` → `src/kernel/`; 2 verifier paths → `tests/e2e/{kernel,multiproc}.zig` |
| 4 (Chunk 3) | 16 | 1 verifier path → `tests/e2e/snake.zig`; 15 prefix `tests/programs/` → `programs/` |

No Zig `@import` edits are required:
- `src/emulator/*` files use sibling imports (`@import("cpu.zig")`, `@import("devices/halt.zig")`) — relative paths survive moving the whole tree under `emulator/`.
- `src/kernel/*` files use sibling imports (`@import("uart.zig")`, etc.).
- `programs/*/{snake,hello,...}.zig` use sibling imports (e.g., `snake.zig` imports `game.zig`).
- `demo/web_main.zig` uses `@import("ccc")` — the named module declared in `build.zig`. Only `build.zig`'s `b.path("src/lib.zig")` arg changes.
- The three e2e verifiers in `tests/e2e/*.zig` only `@import("std")` and spawn `ccc` as a subprocess — pure path move.

---

## Verification gate (run at the end of every chunk)

```bash
zig build test && \
zig build snake-test && \
zig build e2e && \
zig build e2e-mul && \
zig build e2e-trap && \
zig build e2e-hello-elf && \
zig build e2e-kernel && \
zig build e2e-multiproc-stub && \
zig build e2e-plic-block && \
zig build e2e-snake && \
zig build riscv-tests && \
zig build wasm && \
zig build hello-elf && \
zig build kernel-elf && \
zig build kernel-multi && \
zig build snake-elf && \
zig build plic-block-test && \
zig build fixtures
```

Expected: every command exits 0. Any non-zero is a regression — STOP and diagnose before proceeding to the next chunk.

---

## Task 1: Set up worktree and establish baseline

**Files:** none modified.

- [ ] **Step 1: Verify clean working tree on main**

Run from `/Users/cyyeh/Desktop/ccc`:

```bash
git -C /Users/cyyeh/Desktop/ccc status --porcelain
git -C /Users/cyyeh/Desktop/ccc rev-parse --abbrev-ref HEAD
```

Expected: empty output from `status --porcelain`; `main` from `rev-parse`. If output is non-empty, stash or commit first.

- [ ] **Step 2: Create the worktree**

```bash
git -C /Users/cyyeh/Desktop/ccc worktree add .worktrees/folder-restructure -b folder-restructure
```

Expected: `Preparing worktree (new branch 'folder-restructure')` on stderr; `HEAD is now at <sha> ...` on stdout.

All subsequent `bash` commands run with `cwd = /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure`. (For Bash tool calls in this plan, prefix every command with `cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && ...` or set the agent's working directory once.)

- [ ] **Step 3: Establish a passing baseline**

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
zig build test && zig build snake-test && zig build e2e && zig build e2e-mul && zig build e2e-trap && zig build e2e-hello-elf && zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-plic-block && zig build e2e-snake && zig build riscv-tests && zig build wasm && zig build hello-elf && zig build kernel-elf && zig build kernel-multi && zig build snake-elf && zig build plic-block-test && zig build fixtures
```

Expected: every command exits 0. If any fails, the failure pre-existed — STOP and surface to the user; do not begin the move.

---

## Task 2: Chunk 1 — Move `src/*` → `src/emulator/*`

**Files:**
- Move: `src/main.zig src/lib.zig src/cpu.zig src/decoder.zig src/execute.zig src/memory.zig src/csr.zig src/trap.zig src/elf.zig src/trace.zig src/devices/` → `src/emulator/...`
- Modify: `build.zig` (2 `b.path()` strings)

- [ ] **Step 1: Move all src/ files into src/emulator/**

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
mkdir -p src/emulator && \
git mv src/main.zig src/emulator/main.zig && \
git mv src/lib.zig src/emulator/lib.zig && \
git mv src/cpu.zig src/emulator/cpu.zig && \
git mv src/decoder.zig src/emulator/decoder.zig && \
git mv src/execute.zig src/emulator/execute.zig && \
git mv src/memory.zig src/emulator/memory.zig && \
git mv src/csr.zig src/emulator/csr.zig && \
git mv src/trap.zig src/emulator/trap.zig && \
git mv src/elf.zig src/emulator/elf.zig && \
git mv src/trace.zig src/emulator/trace.zig && \
git mv src/devices src/emulator/devices && \
ls src/emulator src/emulator/devices src/
```

Expected from the final `ls`:
- `src/emulator/`: `csr.zig cpu.zig decoder.zig devices elf.zig execute.zig lib.zig main.zig memory.zig trace.zig trap.zig`
- `src/emulator/devices/`: `block.zig clint.zig halt.zig plic.zig uart.zig`
- `src/`: `emulator`

- [ ] **Step 2: Update build.zig — main.zig path**

Use the `Edit` tool on `/Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure/build.zig`:

```
old_string: b.path("src/main.zig")
new_string: b.path("src/emulator/main.zig")
```

(There is exactly one occurrence at line 10.)

- [ ] **Step 3: Update build.zig — lib.zig path**

Use the `Edit` tool on `/Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure/build.zig`:

```
old_string: b.path("src/lib.zig")
new_string: b.path("src/emulator/lib.zig")
```

(There is exactly one occurrence at line 777.)

- [ ] **Step 4: Confirm no stray src-prefix references remain in build.zig**

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
grep -n 'b.path("src/' build.zig
```

Expected: only two matches, both with the `src/emulator/` prefix:
```
10:            .root_source_file = b.path("src/emulator/main.zig"),
777:        .root_source_file = b.path("src/emulator/lib.zig"),
```

- [ ] **Step 5: Run the verification gate**

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
zig build test && zig build snake-test && zig build e2e && zig build e2e-mul && zig build e2e-trap && zig build e2e-hello-elf && zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-plic-block && zig build e2e-snake && zig build riscv-tests && zig build wasm && zig build hello-elf && zig build kernel-elf && zig build kernel-multi && zig build snake-elf && zig build plic-block-test && zig build fixtures
```

Expected: every command exits 0.

- [ ] **Step 6: Commit**

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
git add -A && \
git commit -m "$(cat <<'EOF'
refactor: move src/* to src/emulator/*

Group emulator source under src/emulator/ to make room for src/kernel/
in the next chunk. Path-only change; sibling @import calls survive the
move. build.zig: only src/{main,lib}.zig path strings updated.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Chunk 2 — Move kernel + extract e2e verifiers

**Files:**
- Move: `tests/programs/kernel/` → `src/kernel/` (then split off two verifier files to `tests/e2e/`)
- Modify: `build.zig` (15 `b.path()` strings)

- [ ] **Step 1: Move the kernel directory and split off the e2e verifiers**

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
mkdir -p tests/e2e && \
git mv tests/programs/kernel src/kernel && \
git mv src/kernel/verify_e2e.zig tests/e2e/kernel.zig && \
git mv src/kernel/multiproc_verify_e2e.zig tests/e2e/multiproc.zig && \
ls src/kernel src/kernel/user tests/e2e tests/programs
```

Expected from the final `ls`:
- `src/kernel/`: `boot.S elfload.zig kmain.zig linker.ld mtimer.S swtch.S trampoline.S user`
- `src/kernel/user/`: `user_linker.ld userprog.zig userprog2.zig`
- `tests/e2e/`: `kernel.zig multiproc.zig`
- `tests/programs/`: `hello mul_demo plic_block_test snake trap_demo` (no `kernel/`)

- [ ] **Step 2: Update build.zig — kernel verifier path (single proc)**

Use `Edit` on `build.zig`:

```
old_string: b.path("tests/programs/kernel/verify_e2e.zig")
new_string: b.path("tests/e2e/kernel.zig")
```

(Single occurrence at line 428.)

- [ ] **Step 3: Update build.zig — kernel verifier path (multiproc)**

Use `Edit` on `build.zig`:

```
old_string: b.path("tests/programs/kernel/multiproc_verify_e2e.zig")
new_string: b.path("tests/e2e/multiproc.zig")
```

(Single occurrence at line 445.)

- [ ] **Step 4: Update build.zig — bulk-rename remaining kernel paths**

Use `Edit` on `build.zig` with `replace_all: true`:

```
old_string: tests/programs/kernel/
new_string: src/kernel/
replace_all: true
```

This replaces every remaining occurrence of the prefix in:
- `tests/programs/kernel/elfload.zig` (line 48)
- `tests/programs/kernel/boot.S` (229)
- `tests/programs/kernel/trampoline.S` (239)
- `tests/programs/kernel/mtimer.S` (249)
- `tests/programs/kernel/swtch.S` (259)
- `tests/programs/kernel/user/userprog.zig` (265)
- `tests/programs/kernel/user/user_linker.ld` (284, 325)
- `tests/programs/kernel/user/userprog2.zig` (306)
- `tests/programs/kernel/kmain.zig` (348, 362)
- `tests/programs/kernel/linker.ld` (388, 413)

- [ ] **Step 5: Confirm no `tests/programs/kernel` references remain**

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
grep -n 'tests/programs/kernel' build.zig
```

Expected: no output.

- [ ] **Step 6: Run the verification gate**

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
zig build test && zig build snake-test && zig build e2e && zig build e2e-mul && zig build e2e-trap && zig build e2e-hello-elf && zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-plic-block && zig build e2e-snake && zig build riscv-tests && zig build wasm && zig build hello-elf && zig build kernel-elf && zig build kernel-multi && zig build snake-elf && zig build plic-block-test && zig build fixtures
```

Expected: every command exits 0.

- [ ] **Step 7: Commit**

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
git add -A && \
git commit -m "$(cat <<'EOF'
refactor: move kernel to src/kernel; extract e2e verifiers to tests/e2e

The kernel becomes a peer of src/emulator/ since it's a Phase 2+
deliverable, not a test. Host-side e2e verifiers consolidate at
tests/e2e/{kernel,multiproc}.zig. Verifiers only import std and spawn
ccc as a subprocess — no @import edits required.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Chunk 3 — Move guest programs + snake e2e

**Files:**
- Move: `tests/programs/{hello,snake,mul_demo,trap_demo,plic_block_test}/` → `programs/*`; `programs/snake/verify_e2e.zig` → `tests/e2e/snake.zig`
- Remove: empty `tests/programs/` directory
- Modify: `build.zig` (16 `b.path()` strings)

- [ ] **Step 1: Move all guest programs and the snake verifier**

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
mkdir -p programs && \
git mv tests/programs/hello programs/hello && \
git mv tests/programs/snake programs/snake && \
git mv tests/programs/mul_demo programs/mul_demo && \
git mv tests/programs/trap_demo programs/trap_demo && \
git mv tests/programs/plic_block_test programs/plic_block_test && \
git mv programs/snake/verify_e2e.zig tests/e2e/snake.zig && \
rmdir tests/programs && \
ls programs programs/snake tests/e2e tests
```

Expected from the final `ls`:
- `programs/`: `hello mul_demo plic_block_test snake trap_demo`
- `programs/snake/`: `game.zig linker.ld monitor.S snake.zig test_input.txt` (no `verify_e2e.zig`)
- `tests/e2e/`: `kernel.zig multiproc.zig snake.zig`
- `tests/`: `e2e fixtures riscv-tests riscv-tests-p.ld riscv-tests-s.ld riscv-tests-shim` (no `programs/`)

- [ ] **Step 2: Update build.zig — snake verifier path**

Use `Edit` on `build.zig`:

```
old_string: b.path("tests/programs/snake/verify_e2e.zig")
new_string: b.path("tests/e2e/snake.zig")
```

(Single occurrence at line 597.)

- [ ] **Step 3: Update build.zig — bulk-rename all remaining `tests/programs/` paths**

Use `Edit` on `build.zig` with `replace_all: true`:

```
old_string: tests/programs/
new_string: programs/
replace_all: true
```

This replaces every remaining occurrence (15 strings):
- `tests/programs/hello/encode_hello.zig` (line 64)
- `tests/programs/mul_demo/encode_mul_demo.zig` (91)
- `tests/programs/trap_demo/encode_trap_demo.zig` (117)
- `tests/programs/hello/monitor.S` (167)
- `tests/programs/hello/hello.zig` (172)
- `tests/programs/hello/linker.ld` (193)
- `tests/programs/plic_block_test/boot.S` (481)
- `tests/programs/plic_block_test/test.S` (491)
- `tests/programs/plic_block_test/linker.ld` (505)
- `tests/programs/plic_block_test/make_img.zig` (516)
- `tests/programs/snake/monitor.S` (543)
- `tests/programs/snake/snake.zig` (548)
- `tests/programs/snake/linker.ld` (568)
- `tests/programs/snake/game.zig` (576)
- `tests/programs/snake/test_input.txt` (606)

- [ ] **Step 4: Confirm no `tests/programs/` references remain**

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
grep -n 'tests/programs' build.zig
```

Expected: no output.

- [ ] **Step 5: Run the verification gate**

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
zig build test && zig build snake-test && zig build e2e && zig build e2e-mul && zig build e2e-trap && zig build e2e-hello-elf && zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-plic-block && zig build e2e-snake && zig build riscv-tests && zig build wasm && zig build hello-elf && zig build kernel-elf && zig build kernel-multi && zig build snake-elf && zig build plic-block-test && zig build fixtures
```

Expected: every command exits 0.

- [ ] **Step 6: Smoke-test the wasm web demo locally**

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
scripts/stage-web.sh
```

Expected: prints `staged: web/ccc.wasm (...) bytes`, `staged: web/hello.elf (...) bytes`, `staged: web/snake.elf (...) bytes`.

Then start a local server in the background and visually verify:

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
python3 -m http.server -d . 8000
```

(Run in foreground or background; the engineer opens `http://localhost:8000/web/` in a browser and confirms:
1. The page loads (no console errors).
2. `snake.elf` (default) renders the game board; clicking the terminal and pressing `W`/`A`/`S`/`D` moves a snake; pressing `Q` quits.
3. Switching the dropdown to `hello.elf` runs it, shows `hello world`, and auto-displays the instruction trace.

When done, kill the server with `Ctrl-C`.)

If anything fails the smoke test, STOP and diagnose — do not commit.

- [ ] **Step 7: Commit**

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
git add -A && \
git commit -m "$(cat <<'EOF'
refactor: move guest programs to programs/; snake e2e to tests/e2e

hello, snake, mul_demo, trap_demo, plic_block_test become top-level
guest programs under programs/. Snake's e2e verifier joins kernel and
multiproc under tests/e2e/. tests/programs/ is removed; tests/ now
contains only host-side scaffolding (e2e/, fixtures/, riscv-tests*).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Chunk 4 — Update READMEs

**Files:**
- Modify: `README.md` (Layout section + grep for stray refs)
- Modify: `web/README.md` (only if grep finds stale paths)
- Modify: `scripts/README.md` (only if grep finds stale paths)
- Modify: `build.zig` (doc comment cleanup, see Step 4)

- [ ] **Step 1: Read current README.md Layout section**

Read `/Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure/README.md` lines 200–260 to confirm the Layout block boundaries (it starts with `## Layout` and the embedded triple-backtick fence).

- [ ] **Step 2: Replace the README.md Layout block**

Use the `Edit` tool on `/Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure/README.md` to swap the entire Layout code block. Find the existing block (between the triple-backticks under `## Layout`) and replace its contents with:

```
src/
  emulator/
    main.zig          # CLI entry point (ELF default, --raw fallback; --disk/--input/--trace/etc.)
    lib.zig           # re-export shim consumed by the wasm build (one named module)
    cpu.zig           # hart state: regs, PC, privilege, CSRs, LR/SC reservation; idleSpin (wfi)
    decoder.zig       # RV32IMA + Zicsr + Zifencei + mret/sret/wfi/sfence.vma decoder
    execute.zig       # instruction execution + trap-routing; wfi → cpu.idleSpin
    memory.zig        # RAM + MMIO dispatch (UART, CLINT, PLIC, block, halt, tohost) + Sv32 translation
    csr.zig           # M/S CSRs with field masks, privilege checks, live MTIP/SEIP from devices
    trap.zig          # sync + async trap entry, mret/sret exit, medeleg/mideleg routing
    elf.zig           # ELF32 loader (entry + tohost symbol resolution)
    trace.zig         # --trace one-line-per-instruction formatter + interrupt/block markers
    devices/
      uart.zig        # NS16550A UART (TX + 256B RX FIFO + level IRQ via PLIC src 10)
      halt.zig        # test-only halt device at 0x00100000
      clint.zig       # Core-Local Interruptor (msip, mtimecmp, mtime; raises mip.MTIP; comptime clock branch for wasm)
      plic.zig        # Platform-Level Interrupt Controller (32 sources, S-context, claim/complete)
      block.zig       # Simple MMIO block device (4 KB sectors, host-file-backed via --disk)
  kernel/             # Phase 2/3.B: M-mode boot + S-mode kernel + ptable scheduler + ELF-loaded userprogs
    kmain.zig         # S-mode entry; allocates PID 1, builds address space, switches to scheduler
    boot.S            # M-mode boot shim
    trampoline.S      # user/kernel trampoline
    mtimer.S          # mtimer ISR
    swtch.S           # context switch
    elfload.zig       # in-kernel ELF32 loader (PT_LOAD walker + page-table installer)
    linker.ld         # kernel.elf load layout
    user/
      userprog.zig    # PID 1 user payload (embedded into kernel.elf)
      userprog2.zig   # PID 2 user payload (embedded into kernel-multi.elf)
      user_linker.ld  # user-side linker script
demo/
  web_main.zig        # freestanding wasm entry — runStart/runStep/setMtimeNs/pushInput/consumeOutput, fixed 2 MB ELF buffer (programs fetched at runtime, not embedded)
programs/
  hello/              # Phase 1: RV32I hello-world encoder + Phase 1.D Zig-compiled hello.elf
  snake/              # Phase 3 demo: bare M-mode RV32 snake game + game.zig pure-logic
  mul_demo/           # Phase 1: RV32IMA demo encoder (prints "42\n")
  trap_demo/          # Phase 1.C: privilege demo (prints "trap ok\n")
  plic_block_test/    # Phase 3.A: asm-only integration test (CMD → IRQ → trap → claim → halt)
tests/
  e2e/                # host-side end-to-end verifiers (Zig programs that spawn ccc and assert stdout)
    kernel.zig        # Plan 2.D verifier (Phase 2 §Definition of done)
    multiproc.zig     # Plan 3.B verifier (PID 1 + PID 2 interleaving)
    snake.zig         # snake e2e verifier (deterministic input → GAME OVER)
  fixtures/           # tiny hand-crafted ELF used only by elf.zig tests
  riscv-tests/        # upstream submodule: riscv-software-src/riscv-tests
  riscv-tests-shim/   # weak handlers + riscv_test.h overrides for the shared test env
  riscv-tests-p.ld    # linker script for the 'p' (physical/M-mode) environment
  riscv-tests-s.ld    # linker script for the rv32si-p-* family (S-mode test body)
web/                  # GitHub Pages root (https://cyyeh.github.io/ccc/web/)
  index.html          # demo page (program selector + focusable terminal + auto-trace panel)
  demo.css            # palette matches the deck
  demo.js             # main thread: Worker host, ANSI renderer, program-select handler, keystroke filter
  runner.js           # Web Worker: chunked runStep loop, ELF fetch, output/trace drain
  ansi.js             # ~120-line ANSI subset interpreter (CSI 2J/H/?25, UTF-8 reassembly)
  ccc.wasm            # built artifact (~38 KB; emulator core only) — gitignored
  hello.elf           # built artifact (~10 KB; fetched at runtime) — gitignored
  snake.elf           # built artifact (~1.4 MB Debug; fetched at runtime) — gitignored
  README.md           # how the demo works + how to add another ELF
scripts/
  qemu-diff.sh           # debug aid: per-instruction trace diff vs qemu-system-riscv32
  qemu-diff-kernel.sh    # same, scoped to kernel.elf (Phase 2 debugging)
  stage-web.sh           # local dev: zig build wasm + copy ccc.wasm + hello.elf + snake.elf into web/
  run-snake.sh           # CLI snake wrapper (stty raw mode + restore on exit)
docs/
  superpowers/
    specs/          # design docs per phase (brainstormed + approved)
    plans/          # implementation plans per phase
  references/       # notes on RISC-V specifics (traps, etc.)
.github/
  workflows/
    pages.yml       # CI: test on every PR; build wasm + deploy Pages on push to main
build.zig           # build graph: ccc + tests + demos + fixtures + riscv-tests + plic-block-test + wasm
build.zig.zon       # pinned Zig version + dependencies
```

- [ ] **Step 3: Confirm no stale source-path references remain in README.md**

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
grep -nE 'tests/programs/|src/cpu\.zig|src/memory\.zig|src/elf\.zig|src/devices/' README.md
```

Expected: no output. If matches appear, edit each to use the new path.

- [ ] **Step 4: Clean up stale build.zig doc comments**

`build.zig` has a few in-line comments that reference paths now changed:

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
grep -nE 'tests/programs/|src/lib\.zig|demo/web_main\.zig' build.zig
```

Two comment-only references will appear (around the kernel block and the wasm block) — they describe paths that moved. The build itself works regardless, but for accuracy update each comment in place. Examples:

- Line ~17 comment block: `... a separate module rooted at demo/web_main.zig ...` — keep (still accurate).
- Lines ~217–220 comment: `Two-piece build: ... kernel.elf — M-mode boot.S + mtimer.S + trampoline.S + kernel Zig (kmain, vm, page_alloc, trap, syscall, uart, kprintf) all linked per kernel/linker.ld ...` — already path-agnostic; keep.
- Lines ~759–778 comment: mentions `demo/web_main.zig` — still accurate.

If grep finds a comment that references an old path, edit it. Skip if every match describes a path that's still correct.

- [ ] **Step 5: Spot-check web/README.md and scripts/README.md**

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
grep -nE 'tests/programs/|src/cpu\.zig|src/memory\.zig|src/elf\.zig' web/README.md scripts/README.md
```

Expected: no output. (`web/README.md` mentions `cpu.zig`, `memory.zig`, `elf.zig`, `devices/*.zig` without the `src/` prefix — those bare filenames remain accurate descriptions of the modules.) If any matches surface, update each to the new path.

- [ ] **Step 6: Re-run the verification gate**

(README changes don't affect the build, but re-run to be certain nothing else slipped.)

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
zig build test && zig build snake-test && zig build e2e && zig build e2e-mul && zig build e2e-trap && zig build e2e-hello-elf && zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-plic-block && zig build e2e-snake && zig build riscv-tests && zig build wasm && zig build hello-elf && zig build kernel-elf && zig build kernel-multi && zig build snake-elf && zig build plic-block-test && zig build fixtures
```

Expected: every command exits 0.

- [ ] **Step 7: Commit**

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
git add README.md web/README.md scripts/README.md build.zig && \
git commit -m "$(cat <<'EOF'
docs: update README path references for folder restructure

Top-level README Layout block rewritten to reflect src/{emulator,kernel}/
+ programs/ + tests/e2e/. web/README.md and scripts/README.md spot-checked
for stale source-path references. build.zig doc comments cleaned up.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Final summary and hand-off

**Files:** none modified.

- [ ] **Step 1: Confirm clean tree and four-commit series**

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
git status && \
git log --oneline main..HEAD
```

Expected:
- `git status`: `nothing to commit, working tree clean`
- `git log`: 4 commits (src→src/emulator, kernel+e2e, programs+snake e2e, docs)

- [ ] **Step 2: Final full gate run**

```bash
cd /Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure && \
zig build test && zig build snake-test && zig build e2e && zig build e2e-mul && zig build e2e-trap && zig build e2e-hello-elf && zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-plic-block && zig build e2e-snake && zig build riscv-tests && zig build wasm && zig build hello-elf && zig build kernel-elf && zig build kernel-multi && zig build snake-elf && zig build plic-block-test && zig build fixtures
```

Expected: every command exits 0.

- [ ] **Step 3: Hand back to the user**

Print a summary message:
- Branch: `folder-restructure` at `/Users/cyyeh/Desktop/ccc/.worktrees/folder-restructure`
- Commits: 4 (refactor × 3 + docs × 1)
- Verification: every chunk-boundary gate passed; final gate passed
- Wasm demo: locally smoke-tested in browser (Task 4 Step 6)
- Next: user merges (PR or fast-forward into main); worktree teardown is the user's call (`git worktree remove .worktrees/folder-restructure` after merge).
