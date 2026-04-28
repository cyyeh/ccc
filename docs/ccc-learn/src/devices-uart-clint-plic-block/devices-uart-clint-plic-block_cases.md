# devices-uart-clint-plic-block: Code Cases

> Concrete `ccc` artifacts that exercise each device.

---

### Case 1: Tracing one keystroke into `cat` (Plan 3.E, 2026-04)

**Background**

The shell test pipes `tests/e2e/shell_input.txt` through `--input`. The first byte (a literal `'l'` for the `ls` command) has to travel from the host file → UART RX FIFO → kernel → shell.

**What happened**

1. CLI: `--input tests/e2e/shell_input.txt` configures an `RxPump` on the UART.
2. Boot. Kernel starts, eventually calls `wfi` waiting for input.
3. `cpu.idleSpin` notices `rx_pump != null`, calls `pump.drainOne(io, uart)`.
4. `drainOne` reads one byte from the host file: `'l'`. Calls `uart.pushRx(0x6c)`.
5. FIFO went empty → non-empty. `plic.assertSource(10)`.
6. `idleSpin` calls `check_interrupt` again — now `mip.SEIP = 1`. SEI fires; trap to S.
7. Kernel's ISR claims source 10, drains the FIFO byte by byte, calls `console.feedByte(0x6c)`.
8. `console.feedByte` echoes 'l' (writes 0x6c to UART THR — back out the way it came), buffers in the line buffer.
9. CPU returns to `wfi`. Next iteration of `idleSpin` drains the next byte.

This **byte-per-iteration** pacing is the magic. Without it, all 51 bytes of `shell_input.txt` would arrive simultaneously, the kernel ISR would drain them all at once, but the shell's echo would happen *after* — resulting in `lsls /bin\n...` instead of `ls /bin\n` echoed line-by-line.

**References**

- `src/emulator/devices/uart.zig` (`RxPump`, `pushRx`)
- `src/emulator/cpu.zig` (`idleSpin` → `pump.drainOne`)
- `tests/e2e/shell.zig` (the verifier)
- `tests/e2e/shell_input.txt` (the 51-byte fixture)

---

### Case 2: The `plic_block_test` integration ELF (Plan 3.A, 2026-04)

**Background**

When Plan 3.A landed, it needed an end-to-end test that exercised CMD → IRQ → trap → claim → halt. `programs/plic_block_test/test.S` is an asm-only program that does exactly that — no kernel, no S-mode trap dispatcher, just bare M-mode setting up + handling everything.

**What happened**

The test program:

1. Sets `mtvec` to its in-line trap handler.
2. Configures PLIC: source 1 priority = 1, enable = 1, threshold = 0.
3. Programs the block device: SECTOR=0, BUFFER_PA=0x80100000, CMD=1.
4. The CMD-byte-3 write triggers `performTransfer`. Reads sector 0 (the boot sector — empty in the test image) into 0x80100000.
5. `pending_irq = true`.
6. Next instruction (a `j .` infinite loop) → `cpu.step` services pending_irq → asserts PLIC source 1.
7. `mip.MEIP = 1` (M-external).
8. Trap to M. Handler claims source 1, verifies the result (sector 0 starts with the expected magic bytes), writes to halt MMIO.

`zig build e2e-plic-block` runs this and asserts exit code 0. The test was the proof point that all four devices' interactions worked correctly.

**References**

- `programs/plic_block_test/test.S`
- `build.zig` target `e2e-plic-block`
- The test image creation in `build.zig` step `BuildPlicBlockImage`

---

### Case 3: How `mtime` works without libc on wasm (Plan 3 wasm port)

**Background**

The wasm build of `ccc` runs in a Web Worker. It cannot link libc. So `clint.zig`'s default `clock_source` can't call `clock_gettime`.

**What happened**

`clint.zig` uses comptime branching:

```zig
fn defaultClockSource() i128 {
    switch (comptime builtin.os.tag) {
        .freestanding => return 0,
        .wasi => /* WASI clock */,
        else => /* libc clock_gettime */,
    }
}
```

The `freestanding` arm returns 0 — which would freeze MTIP forever. So the wasm entry point in `demo/web_main.zig` exposes `setMtimeNs(ns)` so the JS side can pump time:

```zig
pub export fn setMtimeNs(ns: i64) void {
    ccc.mtime_ns_override = ns;
}
```

JS calls this on every `runStep` chunk with `performance.now() * 1e6`. `clint.zig`'s alternate clock source reads the override:

```zig
fn webClock() i128 {
    return ccc.mtime_ns_override;
}
```

`web_main.zig` passes `&webClock` to `Clint.init` instead of the default. Time advances when JS calls `setMtimeNs`; otherwise it freezes (which is fine — the wasm Worker is sleeping between chunks anyway).

**Relevance to devices**

The CLINT is the *only* device whose behavior depends on host wall-clock. Comptime branching keeps the wasm port libc-free; the override pattern lets the JS host control time.

**References**

- `src/emulator/devices/clint.zig`
- `demo/web_main.zig`
- `web/runner.js` (calls `setMtimeNs` on each chunk)

---

### Case 4: Snake's timer-driven game loop (Plan 3 demo)

**Background**

`programs/snake/snake.zig` is a 32×16 ASCII snake game that runs as a bare M-mode RV32 program. It uses the CLINT timer to drive its game tick (~10 Hz) and the UART RX to read WASD/q/SPACE keystrokes.

**What happened**

The game's main loop:

1. Set `mtimecmp = mtime + GAME_TICK_NS / 100` (next tick alarm).
2. `wfi`.
3. Trap fires (either MTI from the timer, or SEI from a key press).
4. Trap handler:
   - If MTI: ack (move mtimecmp), bump game state, redraw.
   - If SEI: claim source 10, read RBR, queue keystroke for the game's input handler.
5. `mret`.
6. Loop back to step 1.

The game runs purely in M-mode for simplicity (no S-mode kernel; this isn't an OS demo). It exercises CLINT (for the tick), UART (for input + screen drawing), and PLIC (for routing UART RX).

`zig build run-snake` plays it under `stty raw mode` so single keystrokes get through. `zig build e2e-snake` pipes a deterministic input file and asserts the output contains `GAME OVER`.

**References**

- `programs/snake/snake.zig`
- `programs/snake/game.zig` (pure-logic helpers, target-independent)
- `scripts/run-snake.sh`
- `tests/e2e/snake.zig`

---

### Case 5: PLIC's byte-wise claim latch (Plan 3.A, 2026-04)

**Background**

The PLIC's claim register lives at `0x0C20_0004`. The kernel reads it as a 4-byte word (`lw`). But MMIO accesses go byte-by-byte (in `loadWordPhysical`'s MMIO path). If `claim` performed a fresh claim each byte read, you'd claim *four* sources for one `lw`.

**What happened**

`plic.zig`'s `readByte(off)` for the claim register:

```zig
0x0004 => {  // byte 0 of claim register
    if (!self.claim_latch_valid) {
        self.claim_latch = self.claim();
        self.claim_latch_valid = true;
    }
    return @truncate(self.claim_latch);
},
0x0005, 0x0006 => return @truncate(self.claim_latch >> ((off - 0x0004) * 8)),
0x0007 => {
    const result = @truncate(self.claim_latch >> 24);
    self.claim_latch_valid = false;  // reset for next read
    return result;
},
```

Byte 0 performs the actual claim and stores the result in a latch; bytes 1–3 just slice the latch; byte 3 resets the latch so the next byte-0 read is fresh.

A subtle invariant: this only works if the kernel reads the claim register as `lw` (which produces byte loads in order 0, 1, 2, 3). If the kernel ever read it as 4 separate byte loads in random order, the latch would mis-fire. The kernel always uses `lw`, so this works.

**Relevance**

The claim/complete protocol is the cornerstone of PLIC correctness. Getting the byte-wise read right was non-trivial and the `claim_latch` is the cleanest fix.

**References**

- `src/emulator/devices/plic.zig` (`readByte` claim arm + `claim()` itself)
- `src/kernel/plic.zig` (kernel-side that does the `lw`)

---

### Case 6: Block device `disk_slice` for the wasm shell demo (Plan 3.E, 2026-04)

**Background**

The web demo's headline feature is running the full `kernel-fs.elf` shell against `shell-fs.img` *in the browser tab*. But the wasm build can't open files. How does the disk get there?

**What happened**

JS-side: `runner.js` fetches `shell-fs.img` (4 MB) into an `ArrayBuffer`, copies it into wasm linear memory at a known address, calls `setDiskSlice(ptr, len)`.

Wasm-side: `setDiskSlice` calls `block.attachSlice(slice)`:

```zig
pub fn attachSlice(self: *Block, slice: []u8) void {
    self.disk_slice = slice;
    self.status = @intFromEnum(Status.Ready);
}
```

`performTransfer` then prefers `disk_slice` over `disk_file`:

```zig
if (self.disk_slice) |slice| {
    // memcpy between slice and ram
} else if (self.disk_file) |f| {
    // pread/pwrite
} else {
    self.status = @intFromEnum(Status.NoMedia);
}
```

In the browser, *writes* land in the slice (and are visible to wasm). They don't survive a page reload (because there's no host file to persist to), but within a session, `e2e-persist`-style testing works.

**References**

- `src/emulator/devices/block.zig` (`disk_slice` field + `performTransfer` branch)
- `demo/web_main.zig` (`setDiskSlice` export)
- `web/runner.js` (the JS that fetches `shell-fs.img` and hands it over)
