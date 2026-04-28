# devices-uart-clint-plic-block: In-Depth Analysis

## Introduction

A CPU without peripherals is a black box. It runs instructions but can't tell you anything, can't be told anything, can't read a clock, can't talk to a disk. RISC-V's answer is **memory-mapped peripherals** — devices that appear at fixed physical addresses, accessed by ordinary load/store instructions. We covered the routing in [memory-and-mmio](#memory-and-mmio); this topic covers the four devices themselves.

Each device lives in its own file under `src/emulator/devices/`:

| File | What it is |
|------|------------|
| `uart.zig` | NS16550A serial port — TX byte, RX FIFO. |
| `clint.zig` | Core-Local Interruptor — `mtime`, `mtimecmp`, `msip`. |
| `plic.zig` | Platform-Level Interrupt Controller — 32 sources, claim/complete. |
| `block.zig` | Simple block device — 4 KB sectors, host-file-backed. |

There's also `halt.zig`, a 31-line one-trick device whose only job is "any byte-store inside `[0x00100000, 0x00100008)` terminates the run." We won't dive deep on it.

---

## Part 1: UART (NS16550A)

The UART is the terminal. `kprintf "h"` becomes `*0x10000000 = 'h'` becomes a function call into `uart.zig`'s `writeByte` becomes `self.writer.writeAll("h")` — and the byte appears on stdout (or in the wasm demo, in the JS-side terminal renderer).

### Why NS16550A?

It's an 1980s register set still found in real silicon, QEMU's `virt` machine, and (via documentation) every undergrad OS course. By matching the layout, `ccc`'s kernel-side UART driver could be lifted from xv6 with minimal changes. The relevant registers (offsets from `UART_BASE = 0x10000000`):

| Offset | Name | Purpose |
|--------|------|---------|
| 0x00 | THR (W) | Transmit Holding — write a byte → it goes to the host's writer. |
| 0x00 | RBR (R) | Receive Buffer — read a byte from the RX FIFO. |
| 0x01 | IER | Interrupt Enable Register — kernel sets bit 0 to enable RX-data IRQ. |
| 0x02 | FCR | FIFO Control. |
| 0x03 | LCR | Line Control. |
| 0x04 | MCR | Modem Control. |
| 0x05 | LSR (R) | Line Status — bit 0 = RX-data-available, bit 5 = TX-empty. |
| 0x07 | SR | Scratch register (echo-back). |

Most of the registers are software-visible state with no semantics in `ccc` (we don't simulate baud rates, parity, DCD line, etc.). The two that *do* matter:

- **THR (write)**: `*0x10000000 = 'X'` calls `uart.writeByte(0, 'X')` which calls `self.writer.writeAll(&.{'X'})`. That's the entire TX path. The host stdout (or the in-memory writer in tests) gets the byte.
- **RX FIFO**: a 256-byte ring buffer. `pushRx(byte)` enqueues; `readByte(0)` dequeues. The CPU model never reads stdin synchronously — instead the `idleSpin` loop calls `rx_pump.drainOne(...)` to push bytes into the FIFO from `--input` files (CLI) or from JS messages (wasm).

### The level IRQ via PLIC source 10

When the FIFO transitions from empty to non-empty, `pushRx` calls `plic.assertSource(10)`. PLIC source 10 is reserved for UART-RX. The PLIC then drives `mip.SEIP = 1` if the source is pending+enabled at S, and the kernel's S-trap dispatcher routes that into `uart.isr` (in the kernel-side `src/kernel/uart.zig`).

The IRQ is **level-triggered**: as long as the FIFO has data, source 10 stays asserted. The kernel's ISR drains the FIFO and only when empty does the source deassert. This is what stops the kernel from missing keystrokes if multiple bytes arrive faster than the ISR can drain.

### `RxPump` — pacing `--input` bytes

The CLI `--input PATH` flag opens a file and feeds it byte-by-byte into the UART RX FIFO. But not all at once — that would race with the cooked-mode echo. Instead, `idleSpin` calls `rx_pump.drainOne` once per iteration; the pump pushes one byte and waits. The shell sees each byte, echoes it, and the next byte arrives only when the shell loops back to `read()`.

This pattern is critical for the e2e tests that script shell sessions through `--input`. See [console-and-editor](#console-and-editor) for the cooked-mode echo dance.

---

## Part 2: CLINT — the timer

The Core-Local Interruptor provides:

- **`mtime`** at `0x0200_BFF8` — a 64-bit free-running counter, advances at host wall-clock rate.
- **`mtimecmp`** at `0x0200_4000` — a 64-bit comparator. When `mtime ≥ mtimecmp`, `mip.MTIP` becomes 1.
- **`msip`** at `0x0200_0000` — a 1-bit software-set interrupt (M software interrupt). Used in multi-hart IPIs; `ccc` is single-hart so it's unused.

`Clint` reads `mtime` from a comptime-branched `clock_source`:

```zig
fn defaultClockSource() i128 {
    switch (comptime builtin.os.tag) {
        .freestanding => return 0,             // wasm: caller supplies a clock
        .wasi => /* wasi clock_time_get */,
        else => /* libc clock_gettime */,
    }
}
```

The host comptime check is critical: the wasm build can't link against libc, so the freestanding branch returns 0 (which the browser-side code overrides with a JS-supplied clock anyway).

`epoch_ns` is captured at `Clint.init`. `mtime` returns `(now_ns - epoch_ns) / 100` so the first read is small, not a huge wall-clock value.

### `MTIP` is overlaid live

We saw this in [csrs-traps-and-privilege](#csrs-traps-and-privilege): `mip.MTIP` doesn't have storage. Whenever code reads `mip`, the live value is `cpu.csr.mip | (clint.isMtipPending() << 7)`. So setting `mtimecmp = 100` at `mtime = 50` produces `MTIP = 0`; advancing `mtime` to 200 produces `MTIP = 1`, no other bookkeeping.

---

## Part 3: PLIC — the interrupt switchboard

The PLIC routes 32 device-source IRQs to the S-mode external-interrupt line. `ccc`'s setup:

- 32 source IDs (1..31; ID 0 is hardwired to "no source").
- 1 hart context (S-mode hart 0).
- 3-bit per-source priority (0..7; 0 = "off").
- 5-bit-equivalent S-context threshold; only sources with `priority > threshold` are deliverable.

### Address layout (4 MB)

```
0x0C00_0000 + src*4  → priority[src]      (one 4-byte register per source)
0x0C00_1000 + ctx*0x80 → pending[ctx]      (32 bits = 32 sources)
0x0C00_2000 + ctx*0x80 → enable[ctx]       (per-context enable mask)
0x0C20_0000 + ctx*0x1000 → threshold       (per-context priority floor)
0x0C20_0004 + ctx*0x1000 → claim/complete (read = claim; write = complete)
```

Most of those 4 MB of address space is unused. `plic.zig`'s `readByte`/`writeByte` decode the offset and dispatch; unrecognized offsets return 0 / discard writes.

### `claim` and `complete`

A trap handler reads the claim register to find out *which* source fired. The read:

1. Walks all 32 sources, finds the highest-priority one that's pending+enabled+(prio > threshold).
2. Returns its source ID (1..31), or 0 if none qualify.
3. **Atomically clears that source's pending bit.**

Step 3 is the key invariant — once you've claimed a source, the PLIC won't claim it again until the device asserts it anew. This ensures that even if your handler is slow, you won't get a "double claim" on the same IRQ.

The handler does its device work, then writes the same source ID to the **complete** register. That re-allows the source's pending bit to be set (it's not "complete" until written). For level-triggered sources, the device usually keeps asserting until the kernel clears its underlying cause — so right after `complete`, the source pending bit comes back if the device isn't drained.

### Byte-wise claim quirk

The kernel reads the claim register as a 4-byte word, but the MMIO byte path reads bytes one at a time. To make this work atomically, `plic.zig` uses a `claim_latch`: the first byte (offset 0) performs the actual claim and stores the result; bytes 1–3 just slice from the latch. After byte 3, the latch is reset. So a `lw` from the claim register works correctly via four `readByte` calls.

---

## Part 4: Block device — the disk

A simple MMIO block device serves 4 KB sectors out of a host file (or a wasm linear-memory slice). 16 bytes of registers:

| Offset | Name | Purpose |
|--------|------|---------|
| 0x0–0x3 | SECTOR | Which sector to read/write. |
| 0x4–0x7 | BUFFER_PA | Where in RAM to source/sink the data. |
| 0x8–0xB | CMD | 1 = read, 2 = write, 0 = idle. |
| 0xC–0xF | STATUS | 0 = ready, 2 = error, 3 = no-media. |

### The submit-on-write pattern

The kernel programs a transfer by writing SECTOR, BUFFER_PA, then CMD. As we saw in [memory-and-mmio](#memory-and-mmio), the trigger fires when the *high byte of the CMD word* (offset 0xB) gets written — that's the assumption that the kernel writes CMD as a `sw` (which produces four byte-stores in order, byte 3 last).

```zig
if (off == 0xB) {
    self.block.performTransfer(self.io, self.ram);
}
```

`performTransfer`:
1. Reads SECTOR + BUFFER_PA from `pending_cmd`.
2. Validates: BUFFER_PA aligned, BUFFER_PA + 4096 fits in RAM, SECTOR < NSECTORS.
3. For Read: opens the host file (or slice), seeks to `sector * 4096`, reads 4096 bytes into `ram[buffer_pa - RAM_BASE..]`.
4. For Write: reverse.
5. Sets STATUS = Ready (or Error).
6. Sets `pending_irq = true`.

Step 6 is the deferred IRQ. `cpu.step` services it at the *next* instruction boundary by calling `plic.assertSource(1)`. Source 1 is the block-device IRQ.

This decoupling is critical: the transfer happens *during* the kernel's `sw` to CMD (synchronously, host-side), but the IRQ doesn't visibly assert until the next instruction. The kernel's flow becomes "submit; sleep; ISR wakes me; check status." If the IRQ asserted *during* the `sw`, it would land mid-instruction.

### Wasm path

When `disk_slice` is set (the wasm demo path), `performTransfer` reads/writes from that in-memory slice instead of a host file. This is how `shell-fs.img` runs in the browser tab — the JS side fetches the 4 MB image, hands it to wasm as a `Uint8Array`, and `disk_slice` points into it.

---

## Part 5: How they all fire together

Take a single keystroke. You press `'a'` in the demo:

1. JS-side: `worker.postMessage({type: 'input', byte: 0x61})`.
2. Wasm-side `pushInput` → `uart.pushRx(0x61)`.
3. `pushRx` notes the FIFO went from empty to non-empty → `plic.assertSource(10)`.
4. CLINT timer is *also* ticking forward; let's assume `mtimecmp = 1000` and `mtime = 999` right now.
5. The CPU is in `wfi` (idle). `idleSpin` checks deferred IRQs (none). Calls `check_interrupt`.
6. `check_interrupt` consults `mip`: `MTIP = 0` (CLINT not yet at threshold), `SEIP = 1` (PLIC source 10 pending+enabled at S).
7. Walks priority order: MEI > MSI > MTI > **SEI** ... → SEI wins.
8. Delegated to S → `enter_interrupt(9, cpu)` → `pc = stvec`, `cpu.privilege = .S`.
9. Kernel's S-trap entry → reads `scause`, sees 9 (S-external) → calls `plic.claim()` → returns 10.
10. Dispatches to `uart.isr` → reads RBR until empty → calls `console.feedByte(0x61)` for each byte.
11. Cooked-mode console echoes 'a' (calls `uart.putByte(0x61)` → THR → `writer.writeAll(...)`).
12. PLIC source 10 still asserted (FIFO empty now → uart.isr calls `plic.deassertSource(10)`).
13. Handler writes 10 back to complete register.
14. `sret` → back to wherever `wfi` was.

That's the most common trap path in `ccc`: a UART RX byte traveling through the device cascade into the kernel.

---

## Summary & Key Takeaways

1. **Five MMIO devices.** UART (TX byte / RX FIFO), CLINT (timer + msip), PLIC (32 sources), block (disk), halt (kill switch). Each is one Zig file under `devices/`.

2. **UART is NS16550A-compatible.** Most registers are echo-back state; THR (write) and RBR (read via FIFO) are the only ones that *do* anything. Plus LSR for status polling.

3. **UART RX is level-triggered via PLIC source 10.** The FIFO transition from empty to non-empty asserts; drain to empty deasserts.

4. **CLINT provides `mtime` and `mtimecmp`.** Live `mip.MTIP` overlay — no storage. `mtime` reads via comptime-branched clock source so the wasm build doesn't pull libc.

5. **PLIC has 32 sources, 1 S-context.** 4 MB of address space, mostly sparse. Priority + threshold + enable + claim/complete protocol.

6. **PLIC `claim` atomically clears the chosen source's pending bit.** Prevents double-claim. `complete` re-allows the bit to be set later.

7. **Block device is 16 bytes of registers.** Submit-on-write at offset 0xB triggers the transfer synchronously; IRQ deferred to the next instruction boundary.

8. **`pending_irq` defers IRQ assertion.** Critical to maintain the "interrupts at instruction boundaries" invariant.

9. **`disk_slice` vs `disk_file`.** Wasm uses the slice (in-memory image fetched from JS); CLI uses the file. Setting both is a programmer error.

10. **`RxPump` paces `--input` one byte per iteration.** Lets the cooked-mode echo race with arriving bytes correctly.
