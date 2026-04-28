# memory-and-mmio: A Beginner's Guide

## What Is "Memory" Anyway?

Imagine a giant numbered locker bank. Each locker holds one byte. The lockers are numbered `0`, `1`, `2`, ... up to `0xFFFFFFFF` — about 4 billion of them on a 32-bit machine. To "load a byte from address X," you walk to locker X and look inside. To "store a byte to address X," you put a value in.

That's RAM. Big array, indexed by number, holds 1 byte per slot.

But here's the trick `ccc` (and every real OS) plays:

**Some lockers aren't really lockers. They have hidden trapdoors.**

Locker number `0x10000000`? When you put a byte in it, that byte gets *printed to the terminal*. There's no actual storage there — the locker is wired up to a printer. That's a UART. (Specifically, it's `UART_BASE`, the address of the NS16550A serial port.)

Locker number `0x00100000`? When you put any byte in it, the *whole emulator stops*. There's no storage — the locker is the kill-switch. That's the halt MMIO.

This trick is called **memory-mapped I/O**. Devices appear as ranges of addresses. Loading from them is a function call disguised as a memory read; storing to them is a function call disguised as a memory write.

The big idea: **the CPU doesn't need a separate "talk to a device" instruction.** It just uses regular `lw` and `sw` to addresses that happen to be wired to devices.

---

## The Map

Inside `ccc`, the address space looks like this:

```
0x0010_0000  halt            (write any byte → emulator stops)
0x0200_0000  CLINT           (timer + software interrupt)
0x0C00_0000  PLIC            (interrupt controller)
0x1000_0000  UART            (the terminal)
0x1000_1000  block device    (the disk)
0x8000_0000  RAM (128 MB)    (real storage starts here)
```

Anything outside these regions is "off the map" and produces an error if you touch it. So most of the 4 billion possible addresses are *invalid*.

---

## How Does the CPU Tell?

When the emulator gets a load like `lw a0, 0(a1)` and `a1 = 0x10000000`, it doesn't know in advance "oh, this is a UART access." It just does:

```python
def loadBytePhysical(addr):
    if UART_BASE <= addr < UART_BASE + UART_SIZE:
        return uart.readByte(addr - UART_BASE)
    if HALT_BASE <= addr < HALT_BASE + HALT_SIZE:
        return 0
    if CLINT_BASE <= addr < CLINT_BASE + CLINT_SIZE:
        return clint.readByte(addr - CLINT_BASE)
    if PLIC_BASE <= addr < PLIC_BASE + PLIC_SIZE:
        return plic.readByte(addr - PLIC_BASE)
    if BLOCK_BASE <= addr < BLOCK_BASE + BLOCK_SIZE:
        return block.readByte(addr - BLOCK_BASE)
    if addr >= RAM_BASE:
        return ram[addr - RAM_BASE]
    raise OutOfBounds
```

That's literally what `Memory.loadBytePhysical` does in `memory.zig`. A series of "is this address in this range?" checks, with RAM as the fall-through.

It works because the device base addresses are far apart — there's no overlap, no ambiguity, just dispatch.

---

## What's a Page Table?

OK, so far we've been talking about *physical* addresses. But the kernel doesn't actually let user programs touch the real address space. They get a *fiction*.

Imagine your boss handed you a map of the office, but the map's room numbers are made up. Room `1` on the map is actually room `247` in real life. Room `2` is room `15`. Etc. You can't see the real rooms — only the fake ones the boss chose to show you. To go *anywhere*, you ask the boss "where's room 1, really?" and follow them.

That's a **page table.** Every U-mode and S-mode load/store/fetch goes through one. The CPU asks "where does virtual address `0x00010000` actually live?" and the page-table walk answers "physical address `0x80104000`." Then the load happens at the physical address.

Why bother?

1. **Isolation.** Two processes can both think they live at virtual address `0x00010000`, but their page tables map them to different physical pages. Neither can see the other.
2. **Layout flexibility.** Code can pretend it's at `0x00010000` even if it's actually at `0x80103000`. Programs become position-independent at the OS level.
3. **Permissions.** Each page-table entry has bits saying "readable", "writable", "executable", "user-accessible." A bad pointer dereference becomes a *page fault* — a controlled trap, not a crash.

### The Sv32 walk

`ccc` uses **Sv32**: 32-bit virtual addresses, 4 KB pages, two levels of page table.

A virtual address is split:

```
 31         22 21         12 11          0
 |   VPN[1]  |   VPN[0]    |    offset    |
   "which L1   "which L0    "which byte
    entry?"     entry?"      in the page?"
```

The walk:

1. Start with `satp` (the "address-space register") which points to the **L1 page table** in physical memory.
2. Use `VPN[1]` (top 10 bits of the VA) to index into L1 → get an **L1 PTE**.
3. The L1 PTE points to an **L0 page table**. Use `VPN[0]` to index into L0 → get an **L0 PTE**.
4. The L0 PTE points to a **physical 4 KB page**. The bottom 12 bits of the VA select a byte within it.

Each PTE is 32 bits — 22 bits of physical-page-number plus 10 bits of flags (R, W, X, U, V, etc.). If at any step the V (valid) bit is 0, the walk fails and you get a **page fault**.

In `ccc`'s `memory.zig`:

```zig
const vpn1 = (va >> 22) & 0x3FF;     // top 10 bits
const vpn0 = (va >> 12) & 0x3FF;     // next 10 bits
const off  = va & 0xFFF;             // bottom 12 bits

const root_pa = (satp & 0x003F_FFFF) << 12;
const l1_pte = loadWordPhysical(root_pa + vpn1 * 4);
// ... validity check, permissions check ...
const l0_table_pa = ((l1_pte >> 10) & 0x003F_FFFF) << 12;
const l0_pte = loadWordPhysical(l0_table_pa + vpn0 * 4);
// ... validity check, permissions check ...
const leaf_pa = ((l0_pte >> 10) & 0x003F_FFFF) << 12;
return leaf_pa | off;
```

That's it. ~30 lines of `>>` and `&` and PTE flag checks.

---

## What Happens If You Get a Bad Address?

Three flavors of "bad":

1. **Misaligned.** You tried to load a 4-byte word from an address that isn't divisible by 4. Returns `MisalignedAccess` error → the executor turns it into a `load_addr_misaligned` trap.
2. **Out of bounds.** The address isn't in any device range and isn't in RAM. Returns `OutOfBounds` → executor → `load_access_fault` trap.
3. **Page fault.** Translation found a PTE with V=0, or you tried to write to a page without W=1, or U-mode hit a non-U page, etc. → `LoadPageFault` (or `StorePageFault`/`InstPageFault` for the analogous cases) → executor → matching trap.

All three lead to *traps* — controlled, recoverable transfers of control to the kernel. We dive into traps in [csrs-traps-and-privilege](#csrs-traps-and-privilege).

---

## Why Doesn't the Kernel Get Page Faults?

The kernel runs in **M-mode** (and later, S-mode). In M-mode, the page table is *bypassed entirely*. M-mode loads and stores use the address as-is, no translation. That's why the boot shim can write to `mtvec` and the UART without any setup — there's no page table involved.

In S-mode (the kernel's normal mode), translation happens, but the kernel sets up its page table to map every kernel-relevant page identity (virtual address == physical address). So the kernel can keep using the same addresses without surprises, but the user can't.

There's a subtle exception: when the kernel needs to *read user memory* (e.g., to copy the path string for `openat`). That goes through translation. But the kernel knows what to do — it's expecting to walk the user's page table, not its own.

---

## What's `MMIO_SIZE` Actually Mean?

Each device declares a base + size:

- `UART_BASE = 0x10000000`, `UART_SIZE = 0x100` → UART occupies 256 bytes.
- `BLOCK_BASE = 0x10001000`, `BLOCK_SIZE = 0x10` → block device is just 16 bytes.
- `PLIC_BASE = 0x0c000000`, size = 4 MB.

Wait, **4 MB for an interrupt controller?** That's huge.

The PLIC actually uses ~30 bytes of meaningful state, but it spreads them across 4 MB of address space because the spec says "priority register at offset N×4, enable register at offset 0x2000 + context×0x80, ..." — the addresses are convenient for masking but most of them are unused. `plic.readByte(off)` returns 0 for any offset that doesn't have meaningful state.

---

## Try It

Drop into the `Interactive` tab. There's a virtual-address translator: type a virtual address + a `satp` value + walk the L1/L0 tables you build, watch the resulting PA come out the other side. There's also an MMIO inspector that shows what each address range is wired to.

---

## Quick Reference

| Concept | One-liner |
|---------|-----------|
| Address space | A flat 32-bit range, mostly empty, with RAM and devices in fixed slots. |
| MMIO | "Memory-mapped I/O" — devices appear as address ranges; load/store routes to device code. |
| RAM | The big array of bytes from `0x80000000` upward (128 MB by default). |
| Sv32 | RISC-V's 32-bit page-table format: 4 KB pages, two table levels (L1 + L0). |
| satp | The CSR holding the L1 root table's PPN — the "current page table" pointer. |
| PTE | Page-Table Entry, 32 bits: PPN + R/W/X/U/V/G/A/D flag bits. |
| Page fault | Translation failed → `InstPageFault` / `LoadPageFault` / `StorePageFault`. |
| MPRV | M-mode "act like user for loads/stores" — fetch is unaffected. |
| tohost | A magic MMIO range used by `riscv-tests` to signal pass/fail and exit. |
| Identity map | VA == PA. M-mode is always identity; the kernel's own pages are mapped 1:1. |
