# devices-uart-clint-plic-block: Further Learning Resources

---

## Specifications & datasheets

**[NS16550A UART datasheet](http://byterunner.com/16550.html)**
- The 1980s register layout `ccc/src/emulator/devices/uart.zig` follows. THR/RBR/IER/FCR/LCR/LSR + their bit fields. Difficulty: Reference.

**[RISC-V PLIC Specification](https://github.com/riscv/riscv-plic-spec)**
- The official PLIC spec. ~30 pages. Defines the address layout, claim/complete protocol, priority/threshold semantics. Difficulty: Reference.

**[RISC-V CLINT (in the Privileged ISA spec)](https://riscv.org/technical/specifications/)**
- Not its own spec; described as part of the platform-level recommendations. The mtime/mtimecmp register addresses are the de-facto standard. Difficulty: Reference.

**[virtio-blk specification](https://docs.oasis-open.org/virtio/virtio/v1.1/csprd01/virtio-v1.1-csprd01.html#x1-2410006)**
- For comparison with `ccc`'s much simpler block device. Real production block emulation uses virtio. Difficulty: Reference.

---

## Books

**[Operating Systems: Three Easy Pieces — Chapter 36 ("I/O Devices")](http://pages.cs.wisc.edu/~remzi/OSTEP/file-devices.pdf)**
- Free online. Polling vs interrupt-driven I/O, the canonical "device protocol" pattern. Pairs perfectly with `ccc`'s block device. Difficulty: Beginner.

**[xv6 book — Chapter 5 (interrupts and device drivers)](https://pdos.csail.mit.edu/6.S081/2024/xv6/book-riscv-rev3.pdf)**
- xv6's UART, PLIC, and timer drivers. `ccc`'s kernel-side drivers are direct descendants. Difficulty: Intermediate.

**[Linux Device Drivers, 3rd ed. — Corbet, Rubini, Kroah-Hartman](https://lwn.net/Kernel/LDD3/)**
- Free PDF. Old (Linux 2.6) but the concepts (IRQ handling, polling, DMA, device trees) all apply. Difficulty: Advanced.

---

## Comparable code

**[xv6-riscv: `kernel/uart.c`, `kernel/plic.c`, `kernel/virtio_disk.c`](https://github.com/mit-pdos/xv6-riscv/tree/riscv/kernel)**
- The driver triplet. Read alongside `ccc/src/kernel/{uart,plic,block}.zig`. Difficulty: Intermediate.

**[OpenSBI — `lib/utils/serial/uart8250.c`](https://github.com/riscv-software-src/opensbi)**
- Production firmware UART driver. Lots of features `ccc` skips (FIFO depth probing, fractional baud divisors). Difficulty: Advanced.

**[QEMU's `hw/intc/sifive_plic.c` and `hw/timer/sifive_clint.c`](https://github.com/qemu/qemu/tree/master/hw)**
- Production-grade PLIC and CLINT. Multi-hart, multiple contexts, exact spec compliance. Difficulty: Advanced.

**[Marvell's open-source NS16550 drivers](https://github.com/torvalds/linux/blob/master/drivers/tty/serial/8250/8250_core.c)**
- Linux's 8250-family driver. Real-world UART driver complexity (DMA, flow control, hot-plug). Difficulty: Advanced.

---

## Articles

**["What is an Interrupt Controller?" — chmrr](https://chrisclaremont.com/posts/what-is-an-interrupt-controller/)**
- A short blog post explaining the conceptual role of a PLIC-equivalent. Difficulty: Beginner.

**["The 16550 UART, in detail" — Beej's Guide](https://beej.us/guide/bgnet/html/)**
- Older, longer piece. The register-by-register walk through is what makes the spec readable. Difficulty: Beginner.

**["RISC-V PLIC Demystified" — Andrew Waterman talks at RISC-V Summit](https://www.youtube.com/results?search_query=RISC-V+PLIC+demystified)**
- Various conference talks on YouTube about PLIC design. The protocol-level explanation is more accessible than the spec. Difficulty: Intermediate.

---

## Tools

**`zig build run-snake`**
- The codebase's own playable snake. The most fun way to see CLINT + UART + PLIC interact in real time. Just keystrokes (WASD/q/space) and a redrawn ASCII grid.

**[picocom / minicom](https://www.gnu.org/software/inetutils/manual/html_node/picocom-and-minicom.html)**
- Real serial terminal emulators. If you ever connect to a real RISC-V dev board's UART, these are what you'd use. Difficulty: Beginner.

**[`stty raw cbreak`](https://man7.org/linux/man-pages/man1/stty.1.html)**
- The terminal mode `run-snake.sh` uses to enable single-keystroke input. Worth understanding for the [console-and-editor](#console-and-editor) topic.

---

## When you're ready

You now have all the hardware pieces. Next up: **[kernel-boot-and-syscalls](#kernel-boot-and-syscalls)** — how a real kernel uses these devices to bring up a multi-process OS.
