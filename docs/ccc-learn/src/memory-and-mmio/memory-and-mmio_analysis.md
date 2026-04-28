# memory-and-mmio: In-Depth Analysis

## Introduction

Once you have a CPU that runs instructions ([rv32-cpu-and-decode](#rv32-cpu-and-decode)), the next question is: when one of those instructions does `lw a0, 0(a1)`, *where does the data come from?* RAM? A memory-mapped device? A page-table walk?

This topic explains `ccc`'s answer. There are exactly three flavors of address space:

1. **RAM** — 128 MB starting at `0x80000000`. Real bytes in a host-allocated `[]u8` slice.
2. **MMIO regions** — fixed address ranges (UART, CLINT, PLIC, block, halt, "tohost") that route loads/stores into device emulation code instead of RAM.
3. **Sv32 virtual addresses** — the user/supervisor view of memory, translated by a page-table walk before reaching steps 1 or 2.

The three are layered: a virtual address gets translated into a physical address, the physical address gets dispatched to RAM or one of the MMIO ranges. The whole thing is implemented in `src/emulator/memory.zig`, ~840 lines, and most of it is bookkeeping.

---

## Part 1: The physical address space

### The memory map

```
0x0010_0000 ── 0x0010_0008    halt MMIO       (8 bytes — store any byte = halt)
0x0200_0000 ── 0x0200_FFFF    CLINT           (timer + software-IRQ regs)
0x0C00_0000 ── 0x0C40_0000    PLIC            (4 MB; mostly sparse)
0x1000_0000 ── 0x1000_00FF    UART (NS16550A) (256 bytes; only ~10 used)
0x1000_1000 ── 0x1000_100F    block device    (16 bytes — CMD + status + buffer PA)
0x8000_0000 ── 0x8800_0000    RAM             (128 MB default; --memory <MB> overrides)
```

Every other address — `0x0000_0000`, `0x4000_0000`, anywhere outside these ranges — produces `MemoryError.OutOfBounds` on access.

These addresses come from real RISC-V conventions (CLINT and PLIC are nailed down by the Privileged ISA's "platform-level recommendations"; UART and block are picked to match xv6 / QEMU's `virt` machine). There's nothing magic about them — they're just numbers we agreed on.

### The `Memory` struct

`Memory` owns the RAM slice and pointers to each device:

```zig
pub const Memory = struct {
    ram: []u8,
    halt: *halt_dev.Halt,
    uart: *uart_dev.Uart,
    clint: *clint_dev.Clint,
    plic: *plic_dev.Plic,
    block: *block_dev.Block,
    io: std.Io,             // host I/O for block-device file ops
    tohost_addr: ?u32,      // riscv-tests pass/fail signal address
    allocator: std.mem.Allocator,
};
```

Notice: every device is a *pointer*, not embedded by value. The reason is that devices hold pointers back into the host (e.g., the UART has `*std.Io.Writer` for its TX target). Embedding would mean those pointers get invalidated if `Memory` ever moves. The fix in `ccc/src/emulator/main.zig` is the `TestRig`/`Rig` pattern: allocate everything heap-stable, give `Memory.init` references, and require `defer rig.deinit()`.

---

## Part 2: Routing a load — the `loadBytePhysical` cascade

When the executor calls `mem.loadBytePhysical(addr)`, the function checks each MMIO range in turn, falling through to RAM if none match:

```zig
pub fn loadBytePhysical(self: *Memory, addr: u32) MemoryError!u8 {
    if (inRange(addr, UART_BASE, UART_SIZE))   return self.uart.readByte(addr - UART_BASE);
    if (inRange(addr, HALT_BASE, HALT_SIZE))   return 0;
    if (inRange(addr, CLINT_BASE, CLINT_SIZE)) return self.clint.readByte(addr - CLINT_BASE);
    if (inRange(addr, PLIC_BASE, PLIC_SIZE))   return self.plic.readByte(addr - PLIC_BASE);
    if (inRange(addr, BLOCK_BASE, BLOCK_SIZE)) return self.block.readByte(addr - BLOCK_BASE);
    const off = try self.ramOffset(addr);
    return self.ram[off];
}
```

The `inRange` helper is six lines, no surprises. The cascade is hand-written rather than a table-lookup because the number of devices is small enough (5) that branch-predict-friendly `if` chains are likely the fastest dispatch on modern host CPUs anyway.

`storeBytePhysical` mirrors this exactly, with one extra wrinkle: writing to `BLOCK_BASE + 0xB` (the high byte of the CMD word) triggers `block.performTransfer`. This is the "write submits the request" semantics — see [devices-uart-clint-plic-block](#devices-uart-clint-plic-block).

### Why byte-by-byte?

Loads and stores at u16/u32 granularity *could* hit a device at one byte boundary and RAM at another (theoretically). To handle that uniformly, MMIO accesses are byte-addressed in the device APIs (`uart.readByte(reg)`, etc.), and the `loadHalfwordPhysical` / `loadWordPhysical` functions check the alignment first, then assemble the wider value from byte loads — *unless* the address is in RAM, in which case there's a fast path that uses `std.mem.readInt` directly:

```zig
pub fn loadWordPhysical(self: *Memory, addr: u32) MemoryError!u32 {
    if (addr & 3 != 0) return MemoryError.MisalignedAccess;
    if (addr >= RAM_BASE) {
        const off = try self.ramOffset(addr);
        return std.mem.readInt(u32, self.ram[off..][0..4], .little);
    }
    // MMIO byte-by-byte fallback
    ...
}
```

This single fast path dominates real workloads: kernel and user code do millions of RAM loads for every UART or CLINT access. Hot path stays hot.

### Endianness

RISC-V is little-endian. `std.mem.readInt(u32, slice, .little)` and `writeInt(..., .little)` make this explicit. Tests verify it:

```zig
try mem.storeWordPhysical(RAM_BASE, 0xDEAD_BEEF);
try expect(0xEF == mem.loadBytePhysical(RAM_BASE));         // low byte first
try expect(0xDEAD_BEEF == mem.loadWordPhysical(RAM_BASE));
```

### Misalignment

`storeWordPhysical(addr, ...)` with `addr & 3 != 0` returns `MemoryError.MisalignedAccess`. The executor catches this and routes to the `store_addr_misaligned` trap. Same for halfwords (`addr & 1 != 0`) and word fetches.

---

## Part 3: Sv32 paging — virtual addresses

When the kernel turns on paging (by setting `satp.MODE = 1` and `satp.PPN = root_table_PA >> 12`), all S-mode and U-mode loads/stores/fetches go through a translation step. M-mode is always identity-mapped — that's a hard rule in the spec, so the boot shim and the M-mode monitor never have to worry about translation.

### The Sv32 layout

A 32-bit virtual address splits into:

```
 31         22 21         12 11          0
 |  VPN[1]   |   VPN[0]    |    offset    |
   10 bits      10 bits        12 bits
```

VPN[1] indexes the 1024-entry **L1 page table**. VPN[0] indexes the 1024-entry **L0 page table** that the L1 entry points at. The 12-bit offset selects a byte within the resulting 4 KB page.

A **PTE (page-table entry)** is 32 bits:

```
 31              10 9  8 7 6 5 4 3 2 1 0
 |     PPN        |   |D|A|G|U|X|W|R|V|
                   ↑rsv
```

`V` = valid. `R/W/X` = read/write/execute permissions. `U` = user-accessible (S-mode can't access if U=1 unless `mstatus.SUM`). `G` = global (TLB hint, `ccc` ignores). `A` = accessed. `D` = dirty.

`ccc/src/emulator/memory.zig` exposes these as constants so kernel-side code (`vm.zig` in the kernel topic) can use them without redefinition:

```zig
pub const PTE_V: u32 = 1 << 0;
pub const PTE_R: u32 = 1 << 1;
pub const PTE_W: u32 = 1 << 2;
pub const PTE_X: u32 = 1 << 3;
pub const PTE_U: u32 = 1 << 4;
pub const PTE_G: u32 = 1 << 5;
pub const PTE_A: u32 = 1 << 6;
pub const PTE_D: u32 = 1 << 7;
```

The two helper functions `makeLeafPte(pa, flags)` and `makePointerPte(child_table_pa)` build PTEs correctly so the kernel doesn't have to remember the bit shifts.

### The walk: `Memory.translate`

```zig
pub fn translate(self: *Memory, va: u32, access: Access,
                 effective_priv: PrivilegeMode, cpu: *const Cpu) TranslationError!u32 {
    if (effective_priv == .M) return va;       // M is identity, period.
    if ((cpu.csr.satp >> 31) & 1 == 0) return va; // Bare mode: identity too.

    const vpn1 = (va >> 22) & 0x3FF;
    const vpn0 = (va >> 12) & 0x3FF;
    const off  = va & 0xFFF;
    const root_pa = (cpu.csr.satp & 0x003F_FFFF) << 12;

    // L1 walk
    const l1_pte_pa = root_pa + vpn1 * 4;
    const l1_pte = self.loadWordPhysical(l1_pte_pa) catch return pageFaultFor(access);
    if ((l1_pte & PTE_V) == 0) return pageFaultFor(access);
    if ((l1_pte & (PTE_R | PTE_W | PTE_X)) != 0) return pageFaultFor(access); // L1 leaf rejected

    // L0 walk
    const l0_table_pa = ((l1_pte >> 10) & 0x003F_FFFF) << 12;
    const l0_pte = self.loadWordPhysical(l0_table_pa + vpn0 * 4) catch return pageFaultFor(access);
    if ((l0_pte & PTE_V) == 0) return pageFaultFor(access);
    if ((l0_pte & (PTE_R | PTE_W | PTE_X)) == 0) return pageFaultFor(access); // L0 pointer rejected

    // Permission checks (R/W/X, U-bit, MXR, SUM)
    ...

    // A/D bit update-in-place
    var new_pte = l0_pte;
    if ((l0_pte & PTE_A) == 0) new_pte |= PTE_A;
    if (access == .store and (l0_pte & PTE_D) == 0) new_pte |= PTE_D;
    if (new_pte != l0_pte) self.storeWordPhysical(l0_pte_pa, new_pte) catch ...;

    const leaf_pa = ((l0_pte >> 10) & 0x003F_FFFF) << 12;
    return leaf_pa | off;
}
```

A few things `ccc` declined to support:

- **Superpages.** A leaf PTE at L1 (with `R|W|X != 0`) would map a 4 MB page. `ccc` rejects it (`return pageFaultFor(access)`). The kernel never tries to install one, so this is enforcement-by-rejection.
- **TLB.** No translation cache. Every load/store/fetch walks the table. This is slow, but correct, and removes a whole class of "did I forget a `sfence.vma`?" bugs. `sfence.vma` decodes to a no-op.

### Permission checks

The code does the spec-mandated tower of checks:

1. **U-bit vs privilege.** If `effective_priv == .U` and `!pte_u`, fault. If `effective_priv == .S` and `pte_u`, the access is fault unless `mstatus.SUM` is set (and *never* allowed for fetch — S-mode CANNOT execute from a U-page even with SUM).
2. **MXR (make executable readable).** If `mstatus.MXR` is set, the X bit also enables R for load purposes. This lets the kernel read user instruction text without separately marking it readable.
3. **Access type.** Fetch needs X, load needs R-or-MXR-X, store needs W.
4. **A/D update-in-place.** RISC-V allows two implementations: trap to OS for A/D updates, or hardware-walk updates the PTE. `ccc` chose hardware-walk (simpler emulator, removes the need for an OS A/D fault handler).

### MPRV — the kernel's "act like user" knob

```zig
pub fn effectivePriv(cpu: *const Cpu, access: Access) PrivilegeMode {
    if (access != .fetch and cpu.privilege == .M and cpu.csr.mstatus_mprv) {
        return @enumFromInt(cpu.csr.mstatus_mpp);
    }
    return cpu.privilege;
}
```

When **`MPRV=1`** and we're in M-mode, **loads and stores** use the privilege saved in `MPP` instead of M-mode's own. Fetch is *unaffected*. This is how the M-mode monitor reads U-mode argument buffers without disabling paging entirely.

`ccc` doesn't use MPRV in its kernel — the S-mode kernel is normally not under MPRV semantics. But the test for it (`test "translate: MPRV with MPP=U triggers user permission check"` in memory.zig) keeps the code path correct for any future use.

---

## Part 4: The "tohost" backdoor (riscv-tests)

The `riscv-tests` conformance suite signals pass/fail by writing to a symbol named `tohost`. `ccc/src/emulator/elf.zig` reads the ELF symbol table on load; if it sees `tohost`, it sets `Memory.tohost_addr` to that virtual address.

Then in `storeBytePhysical`:

```zig
if (self.inTohost(addr)) {
    self.ram[off] = value;          // commit the byte for inspection
    if (value != 0) self.halt.exit_code = ...;
    return MemoryError.Halt;        // terminate the run
}
```

A single byte-store inside the tohost range terminates the emulator with the right exit code. `value == 1` is PASS; anything else is FAIL with the test number encoded in the upper bits.

This MMIO-as-test-channel pattern is unique to riscv-tests; production kernels never write to tohost.

---

## Part 5: Translation-aware accessors

The `loadByte`/`loadHalfword`/`loadWord`/`storeByte`/etc. methods are the API that the executor uses for normal data accesses. They each:

1. Compute `effective_priv` (honoring MPRV).
2. Call `translate(va, access, effective_priv, cpu)` to get a physical address.
3. Call the matching `*Physical` method.

Faults at step 2 propagate as `TranslationError` (`InstPageFault`, `LoadPageFault`, `StorePageFault`). Faults at step 3 propagate as `MemoryError`. Both are union'd into `LoadOrTransError = MemoryError || TranslationError` in `execute.zig` so a single `catch` handles both.

For instruction fetch, `cpu.step` calls `mem.translate(pc, .fetch, cpu.privilege, cpu)` directly and then `mem.loadWordPhysical(pa)` — bypassing the `loadWord` wrapper because MPRV doesn't apply to fetch.

---

## Part 6: The fast-path mental model

For a user-mode `lw a0, 0(a1)` accessing a normal data page:

1. `execute.dispatch` enters the `.lw` arm.
2. Computes VA = `regs[a1] + 0`.
3. Calls `mem.loadWord(va, cpu)`.
4. Inside: `effectivePriv` returns U (because privilege is U, MPRV not set).
5. `translate` walks the page table: L1 PTE → L0 PTE → leaf PA.
6. Checks U-bit, R-bit, hits A=0 → sets A → writes the PTE back.
7. Returns leaf_pa | offset.
8. `loadWordPhysical` checks alignment, sees address is in RAM, takes the fast path: `std.mem.readInt(u32, ram[off..][0..4], .little)`.
9. Returns the value to `dispatch`, which writes it to `regs[a0]`.

For a kernel `sw t0, 0(t1)` to a UART register (in M-mode):

1. `dispatch` enters the `.sw` arm.
2. Computes VA = `regs[t1] + 0` — say, `0x10000000` (UART_BASE).
3. Calls `mem.storeWord(va, val, cpu)`.
4. `effectivePriv` returns M.
5. `translate` returns immediately with `va = 0x10000000` (M is identity).
6. `storeWordPhysical` sees address is below RAM_BASE, falls through to the byte-by-byte path, hits the UART range, calls `uart.writeByte` four times, characters appear on stdout.

That's the whole memory-and-mmio story.

---

## Summary & Key Takeaways

1. **The physical address space is small.** RAM at `0x8000_0000` (128 MB), five MMIO regions, one tohost backdoor. Everything else is `OutOfBounds`.

2. **MMIO is just routing.** `loadBytePhysical` is a cascade of `inRange` checks; the right device gets the call. There is no "memory-mapped I/O hardware" — there's a switch statement.

3. **RAM has a fast path.** Word and halfword loads/stores in RAM use `std.mem.readInt`/`writeInt` directly. MMIO accesses go byte-by-byte, which is slower but uniform.

4. **Endianness is little-endian, explicit.** `.little` everywhere; tests verify the ordering.

5. **Sv32 paging is two-level, 4 KB pages only.** No superpages. No TLB. Every translation walks the table; `sfence.vma` is a no-op.

6. **PTE flag bits — V, R, W, X, U, G, A, D — are each one bit.** `memory.zig` exports them as `PTE_*` constants so the kernel can build PTEs without recopying the layout.

7. **A/D bits update in-place during the walk.** `ccc` chose hardware-walk semantics — fewer trap handlers needed.

8. **M-mode is always identity.** No translation, ever. Same for non-M with `satp.MODE == 0` (Bare).

9. **MPRV lets M-mode loads/stores use S/U privilege.** Fetch is never MPRV-affected. The kernel topic explores when this is useful.

10. **The `tohost` MMIO is a test-only backdoor.** Writing inside `[tohost_addr, tohost_addr+8)` terminates the run with a pass/fail code. Set up by the ELF loader if it sees a `tohost` symbol.

11. **Translation-aware accessors (`loadWord`, etc.) are what the executor uses.** They wrap `translate + *Physical`. The fetch path calls them separately to skip MPRV.
