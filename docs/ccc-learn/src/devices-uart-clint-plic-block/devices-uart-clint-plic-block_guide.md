# devices-uart-clint-plic-block: A Beginner's Guide

## What's a "Peripheral"?

A peripheral is anything that's not the CPU or RAM. The keyboard. The display. The disk. The clock. The network card.

In the simplest possible computer, the CPU has built-in pins that connect to each peripheral. But in any real machine, peripherals are far more varied than the CPU's pin layout, so there's an indirection: the CPU has a generic "memory bus" that lets it read/write any address, and peripherals listen on the bus for *their* addresses.

That's MMIO — covered in the previous topic. This topic is about *four specific peripherals* `ccc` emulates:

1. **UART** — the terminal pipe.
2. **CLINT** — a clock + timer.
3. **PLIC** — a switchboard for "device wants attention."
4. **Block device** — a tiny disk.

---

## UART: The Slow Pipe

A UART is a 1-byte-wide pipe. You write a byte to one end (the THR — transmit holding register); the byte travels (slowly, on real hardware) to the other end and pops out (on a screen, into a serial terminal). You can also receive: bytes show up in a small buffer (the RX FIFO); you read from that.

The "U" in UART = "universal." It's the lowest common denominator of communication: every microcontroller, every server's IPMI port, every 1980s terminal had one.

In `ccc`:
- **Writing a byte to address 0x10000000** prints it on stdout.
- **Reading from address 0x10000000** dequeues a byte from the FIFO.

That's the whole user-facing API. The other registers (LCR, FCR, IER, etc.) hold settings the kernel writes to configure the simulated baud rate and so on — `ccc` accepts those writes and reads them back, but doesn't simulate the underlying behavior (since we have no real wire).

### Why a FIFO?

The kernel can't always read keystrokes the instant they arrive — it might be in the middle of something else. So the UART has a 256-byte buffer (a FIFO — first-in-first-out queue). Bytes pile up there until the kernel comes back to drain them.

If the FIFO fills up while the kernel ignores it, new bytes get dropped. This is rare in practice (humans type slowly), but a stress test could trigger it.

### How does the kernel know "RX has data"?

The UART can ask the **PLIC** (interrupt controller) to alert the CPU when the FIFO transitions from empty to non-empty. The PLIC ID for the UART is **source 10**. So when you press 'a':

1. The runtime calls `uart.pushRx('a')`.
2. The FIFO went from empty to non-empty → `plic.assertSource(10)`.
3. PLIC raises `mip.SEIP` (S-external pending).
4. CPU takes a trap to S-mode at the next instruction boundary.
5. Kernel's trap handler asks PLIC "what fired?" → "source 10."
6. Kernel runs the UART ISR, drains the FIFO, processes the byte.

This is the *interrupt-driven* I/O model. Compare with **polling**, where the kernel asks "any data?" in a loop. Polling is wasteful when you're idle; interrupt-driven only wakes the kernel when work arrives.

---

## CLINT: The Metronome

A CPU all by itself has no sense of time. It just executes instructions one after another. A CLINT (Core-Local Interruptor) gives it a clock.

Two parts:
- **`mtime`** — a 64-bit counter that advances on its own (in `ccc`, in proportion to host wall-clock).
- **`mtimecmp`** — a 64-bit "alarm clock." When `mtime ≥ mtimecmp`, the CPU's `mip.MTIP` bit becomes 1.

Pattern:
1. Kernel reads `mtime`, e.g. 100.
2. Kernel writes `mtimecmp = 200` (set alarm for 100 ticks from now).
3. Kernel does whatever.
4. Eventually, `mtime` reaches 200 → MTIP → trap fires → kernel's MTI handler runs.
5. Handler does its bookkeeping (update tick counter, run scheduler), then writes `mtimecmp = mtime + 100` to set the *next* alarm.

That's how the kernel gets a periodic tick — by always re-arming the alarm in the handler.

`ccc`'s CLINT also has **`msip`** (M-mode software interrupt pending — bit-flip to deliver an IRQ to yourself). Unused in single-hart `ccc`; it's for multi-hart IPIs (inter-processor interrupts) on bigger machines.

---

## PLIC: The Switchboard

In a real machine, dozens of devices might want to interrupt the CPU. The CPU has *one* "external interrupt" line. Who picks which device wins? **The PLIC.**

A PLIC is essentially a multiplexer with priority. Each device has a numbered "source" (UART = 10, block device = 1, etc.). The PLIC tracks, per source:
- **Priority** (0–7; 0 = off).
- **Pending** (1 = asserted but not claimed).
- **Enabled** (per-context — does this S-mode hart care about this source?).

When *any* source is pending+enabled+(prio > threshold), the PLIC asserts `mip.SEIP` to the CPU. The CPU traps. The kernel reads the **claim register** to find out which specific source won — and the act of claiming **atomically clears** that source's pending bit.

Then the kernel handles it. When done, it writes the source ID back to the **complete register** to say "I'm finished; you can re-pend if needed."

### Level vs edge

Most PLIC sources are **level-triggered**: they stay asserted until the device's underlying condition is cleared. The UART RX source stays high as long as the FIFO has data. The kernel's ISR has to drain the FIFO before claiming completes.

If a source were **edge-triggered**, it would assert briefly and then drop. If the kernel was busy and missed the edge, the IRQ would be lost forever. PLIC sources are level-triggered for safety.

---

## Block Device: The Tiny Disk

`ccc`'s block device serves 4 KB sectors out of a host file. To read sector 17:

1. Kernel writes `SECTOR = 17` (offset 0).
2. Kernel writes `BUFFER_PA = 0x80100000` (offset 4) — where in RAM the data should land.
3. Kernel writes `CMD = 1` (offset 8) — read.
4. The transfer happens synchronously inside the host (it's just a `pread` from the disk file).
5. Status flips to Ready. An IRQ is *deferred* to the next instruction boundary.
6. Next instruction → PLIC source 1 asserts → kernel's block ISR runs → wakes up whoever was sleeping.

The "submit-on-CMD-write" pattern is unusual in real hardware (which uses doorbell registers + queue pairs), but for a teaching emulator, it's perfect: no async machinery, no DMA controller, just memcpy.

The kernel-side block driver in `src/kernel/block.zig` enforces "one outstanding request at a time": `submit` then `sleep on &req`; the ISR wakes the sleeper. Multiple kernel callers serialize naturally.

---

## Putting Them Together: Where Do Interrupts Come From?

Three of the four devices generate interrupts:

- **UART RX** → PLIC source 10 → `mip.SEIP` → S-mode trap.
- **Block completion** → PLIC source 1 → `mip.SEIP` → S-mode trap.
- **CLINT timer** → `mip.MTIP` → M-mode trap (or S, if `mideleg.MTI` is set; `ccc` keeps it at M).

Note CLINT bypasses PLIC — its IRQ goes straight into `mip.MTIP`. PLIC is only for *external* devices.

The halt device doesn't produce IRQs (writing to it just terminates the run).

---

## Try It

The `Interactive` tab has a UART/PLIC playground: feed bytes into the UART RX FIFO, watch source 10 assert in the PLIC, see the kernel's trap fire. There's also a CLINT explorer where you set `mtimecmp` and watch `MTIP` flip when the timer crosses.

---

## Quick Reference

| Concept | One-liner |
|---------|-----------|
| UART | NS16550A serial port. THR (write) → host stdout. RX FIFO + PLIC src 10. |
| CLINT | `mtime` (free-running counter) + `mtimecmp` (alarm) + `msip` (software IRQ). |
| PLIC | Routes 32 source IRQs to S-mode external. Claim/complete protocol. |
| block | 16-byte MMIO + 4 KB sectors backed by host file or wasm slice. |
| halt | Write any byte to 0x00100000 → emulator stops. |
| Source 10 | UART RX. Level-triggered. |
| Source 1 | Block-device completion. Level-triggered. |
| MTIP | Live overlay from CLINT — no storage in `mip`. |
| `pending_irq` | Block device defers IRQ to next instruction boundary. |
| `RxPump` | Paces `--input` bytes one-per-iteration into UART RX. |
