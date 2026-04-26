# How `snake.elf` runs end-to-end

Reference notes on the under-the-hood execution path of the Phase 3 snake
demo: from the host shell command down to the timer interrupt that drives
each frame, and back out to the terminal.

Snake runs **bare-metal in M-mode** on the emulated RV32 hart. It does not
go through the Phase 2/3 kernel — there is no S-mode, no Sv32 paging, no
syscalls, no scheduler. The whole game is one ELF: an asm boot stub, a
trap vector, and a Zig tick handler.

## Big picture

```
host shell  ──exec──▶  ccc (Zig RV32 emulator process)
                          │
                          │ load ELF, set PC, run hart
                          ▼
                       emulated RV32 hart (M-mode)
                          │
            ┌─────────────┼─────────────┐
            │             │             │
        monitor.S    trap_vector    snakeTrap (Zig)
        boot stub    (asm shim)     game tick handler
            │             ▲             │
            └──── wfi ────┘             │
                          ▲             │
                          │             ▼
                  CLINT MTI fires    UART writes
                  every 125 ms       (frame bytes)
                                         │
                                         ▼
                                    host stdout
```

Heartbeat: **CLINT timer fires → trap → poll one input byte → step game
→ render frame → re-arm timer → `wfi`**. Repeat at ~8 Hz.

## Layer 1 — host: the `ccc` emulator process

`scripts/run-snake.sh` puts the host TTY in raw mode and execs:

```
ccc --input /dev/stdin snake.elf
```

`ccc` is the Zig-written RV32 emulator (`src/emulator/main.zig`). On
startup it:

1. **Loads the ELF** — `src/emulator/elf.zig` walks `PT_LOAD` segments
   and copies them into emulated RAM (128 MB at `0x80000000`). It also
   resolves the linker symbol `tohost` → registers that physical address
   as the halt-MMIO trigger (`programs/snake/linker.ld:39`).
2. **Initializes the hart** — `cpu.zig` zeroes regs, sets
   `pc = ehdr.entry` (i.e. `_start`), `priv = M`.
3. **Wires devices** —
   - UART NS16550A at `0x1000_0000` (`src/emulator/devices/uart.zig`)
   - CLINT at `0x0200_0000` (`src/emulator/devices/clint.zig`)
   - Halt MMIO at `0x0010_0000` (`src/emulator/devices/halt.zig`)
4. **Starts a host stdin → UART RX pump** — because of
   `--input /dev/stdin`, raw keystrokes from the host TTY land in the
   UART's 256-byte RX FIFO.

## Layer 2 — emulator fetch/decode/execute loop

Per cycle, in `src/emulator/execute.zig`:

```
fetch (memory.zig: translate + load)
 → decode (decoder.zig: RV32IMA + Zicsr + Zifencei)
 → execute (regs / CSRs / memory / branch)
 → check pending interrupts (trap.zig: mip & mie & priority)
 → advance mtime (clint.zig)
```

Two emulator-specific behaviors matter for snake:

- **`wfi` → `cpu.idleSpin`**: instead of busy-stepping, the emulator
  fast-forwards `mtime` to the nearest pending interrupt deadline. The
  `wfi` loop is effectively free.
- **Memory dispatch** (`memory.zig`): every load/store checks the
  address — RAM, UART (THR/RBR/LSR), CLINT (`mtime`/`mtimecmp`), or
  halt. Stores to the resolved `tohost` address terminate the run.

## Layer 3 — guest boot: `monitor.S`

Bare-metal M-mode boot (`programs/snake/monitor.S:18`):

1. `sp = _stack_top` (16 KB stack carved by linker).
2. Zero `.bss` (Zig module-level state lives there and assumes
   zero-init).
3. `csrw mtvec, trap_vector` (direct mode; address must be 4-byte
   aligned).
4. Set `mie.MTIE` (bit 7) and `mstatus.MIE` (bit 3) — timer
   interrupts unmasked.
5. Program first `mtimecmp = mtime + 1_250_000` (125 ms @ 10 MHz
   emulated clock).
6. `wfi; j idle` — sleep forever, woken only by interrupts.

CLINT MMIO addresses (must match `src/emulator/devices/clint.zig`):

| Reg       | Address       | Width |
|-----------|---------------|-------|
| `mtime`     | `0x0200_BFF8` | 64-bit |
| `mtimecmp`  | `0x0200_4000` | 64-bit |

## Layer 4 — the tick: trap → handler → mret

The CLINT compares `mtime` to `mtimecmp` each cycle; when it trips,
`mip.MTIP` is raised. The trap engine (`src/emulator/trap.zig`):

- saves PC → `mepc`
- sets `mcause = 0x80000007` (machine timer interrupt)
- jumps to `mtvec` → `trap_vector`

`trap_vector` (`programs/snake/monitor.S:69`) is a thin asm shim:
saves the 16 caller-saved regs (`ra`, `t0..t6`, `a0..a7`) onto the
stack, calls `snakeTrap` (Zig), restores them, `mret`. Callee-saved
`s0..s11` are preserved by Zig's `extern` calling convention so the
shim leaves them alone.

`snakeTrap` (`programs/snake/snake.zig:242`) on every tick:

1. **First call only**: `Game.init` at the play-area center, render the
   empty board, arm the next `mtimecmp`, return early.
2. **`drainOneInputByte()`** — polls UART `LSR.DR` (`0x1000_0005`
   bit 0). If set, reads `RBR` (`0x1000_0000`) and routes the byte:
   - `q` → `quit_requested = true`
   - SPACE → restart on game-over
   - WASD → set `pending_dir`. Lazy-seeds the xorshift32 RNG from
     `mtime` on the *first* movement key, then places food.
3. If `quit_requested`: store `1` to `tohost` → emulator halts (see
   Layer 5).
4. If `Playing` and the game has started: `game.applyDirIfLegal()`,
   `game.advance()` — pure logic in `programs/snake/game.zig`. Moves
   head, wraps tail unless food eaten, checks self-collision and wall
   collision.
5. **`render()`** — paints a 32×15 char `frame[][]` (border, snake
   body `#` / head `O`, food `*`, optional centered GAME OVER panel),
   then writes `\x1b[2J\x1b[H` + the frame to UART THR
   (`0x1000_0000`) byte-by-byte.
6. **`advanceMtimecmp()`** — adds `TICK_PERIOD` (1.25M cycles) to
   schedule the next tick.
7. `mret` → resume at the `wfi` in `monitor.S:idle`.

## Layer 5 — termination

When the player hits `q`:

1. `handleInput` sets `quit_requested = true`.
2. Next tick: `snakeTrap` calls `halt()`.
3. `halt()` does `tohost = 1`. The store address resolves to the
   linker-script-assigned `tohost` symbol (Layer 1 step 1).
4. `memory.zig` recognizes the address as the halt trigger, marks the
   hart halted.
5. The emulator main loop exits with status 0; `ccc` returns to the
   shell.
6. The `trap` in `run-snake.sh` restores the host TTY (`stty
   "$SAVED_STTY"`).

## Why the I/O is asymmetric

- **Output is direct MMIO writes**: every char goes UART THR → host
  stdout immediately. No interrupts, no buffering.
- **Input is polled, not interrupt-driven**: the kernel-level path
  uses PLIC source 10 to route UART RX to S-mode external interrupts,
  but snake is M-mode-only and never touches the PLIC. It checks
  `LSR.DR` once per 125 ms tick — which is why typing too many keys
  per tick can drop bytes beyond the 256-byte FIFO.

## File map

| File                                  | Role |
|---------------------------------------|------|
| `scripts/run-snake.sh`                | Host wrapper: `stty -icanon -echo`, exec `ccc --input /dev/stdin snake.elf`, restore TTY on exit |
| `src/emulator/main.zig`               | `ccc` CLI entry, `--input` plumbing |
| `src/emulator/elf.zig`                | ELF32 loader, resolves `tohost` symbol |
| `src/emulator/cpu.zig`                | Hart state, `idleSpin` (wfi fast-forward) |
| `src/emulator/decoder.zig`            | RV32IMA + Zicsr + Zifencei decoder |
| `src/emulator/execute.zig`            | Instruction execution + interrupt check |
| `src/emulator/memory.zig`             | RAM + MMIO dispatch |
| `src/emulator/trap.zig`               | Sync + async trap entry, `mret` exit |
| `src/emulator/csr.zig`                | M/S CSRs, live `MTIP` from CLINT |
| `src/emulator/devices/uart.zig`       | NS16550A: TX → host stdout, 256 B RX FIFO |
| `src/emulator/devices/clint.zig`      | `mtime` / `mtimecmp`, raises `mip.MTIP` |
| `src/emulator/devices/halt.zig`       | Halt MMIO at `0x0010_0000` |
| `programs/snake/monitor.S`            | M-mode boot stub + `trap_vector` asm shim |
| `programs/snake/linker.ld`            | RAM origin `0x80000000`, `_bss_start/_bss_end`, `_stack_top`, `tohost` |
| `programs/snake/snake.zig`            | `snakeTrap` tick handler, UART/CLINT MMIO, `render()` |
| `programs/snake/game.zig`             | Pure game logic (target-independent, has unit tests) |
| `tests/e2e/snake.zig`                 | E2E verifier — pipes `snake_input.txt`, asserts `GAME OVER` + `score: 0` |
| `tests/e2e/snake_input.txt`           | Deterministic input fixture |

## Build steps that produce these artifacts

| Step                  | Output |
|-----------------------|--------|
| `zig build snake-elf` | `zig-out/bin/snake.elf` |
| `zig build`           | `zig-out/bin/ccc` (the emulator) |
| `zig build run-snake` | Builds both above, then runs `scripts/run-snake.sh` |
| `zig build snake-test`| Native unit tests for `programs/snake/game.zig` |
| `zig build e2e-snake` | Headless deterministic run via `tests/e2e/snake.zig` |

## Comparison: snake vs the kernel path

|                       | snake.elf            | kernel.elf / kernel-multi.elf       |
|-----------------------|----------------------|--------------------------------------|
| Privilege             | M-mode only          | M-mode boot shim + S-mode + U-mode   |
| Paging                | None (identity RAM)  | Sv32 page tables                     |
| Trap delegation       | None                 | `medeleg` / `mideleg` to S           |
| Timer source          | CLINT MTI direct     | CLINT MTI → forwarded as SSIP        |
| UART RX               | Polled `LSR.DR`      | PLIC src 10 → S-mode external IRQ    |
| Scheduler             | None (single program)| Round-robin over `ptable[NPROC=16]`  |
| Halt                  | Store to `tohost`    | Store to `tohost` (same convention)  |

Snake is the simplest non-trivial program the emulator runs — useful as
a sanity check for CLINT, UART, and the M-mode trap path in isolation.
