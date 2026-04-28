# memory-and-mmio: Code Cases

> Real artifacts from `ccc` showing the address-space + paging layer at work. Open each cited file alongside reading these.

---

### Case 1: How `printf` becomes a UART byte (Plan 1.A → 2.C, throughout)

**Background**

In `ccc`, every printed character on stdout starts as a write to memory. There is no `printf` syscall in the emulator's emulator-level — only a 32-bit store to address `0x10000000`.

**What happened**

When the kernel's `kprintf` writes the letter `'h'`:

1. `kprintf.zig` calls `uart.putByte('h')` — kernel side, in `src/kernel/uart.zig`.
2. That function does `*(volatile u8*)0x10000000 = 'h';` (in Zig: a `[*c]volatile u8` store).
3. The store turns into an `sb` instruction with `addr = 0x10000000`.
4. `execute.dispatch` enters the `.sb` arm, calls `cpu.memory.storeByte(addr, value, cpu)`.
5. `storeByte` translates: M-mode → identity → PA = 0x10000000.
6. `storeBytePhysical` runs the dispatch cascade. UART_BASE = 0x10000000 ≤ 0x10000000 < 0x10000000 + 0x100 → match.
7. Calls `uart.writeByte(0, 'h')` (offset 0 = THR, the transmit-holding register).
8. `uart.zig`'s `writeByte` writes to `*std.Io.Writer` — which is the host's stdout.
9. The character appears.

The whole MMIO subsystem exists for this single round-trip pattern.

**Relevance to memory-and-mmio**

This is the single most-exercised path in the codebase. Every "hello world", every kernel log line, every shell prompt goes through it. If `loadBytePhysical`/`storeBytePhysical` ever broke its `inRange` ordering, this test would notice instantly.

**References**

- `src/emulator/memory.zig` (`storeBytePhysical` cascade)
- `src/emulator/devices/uart.zig` (`writeByte` THR forwarding)
- `tests/e2e/hello_elf.zig` (asserts the printed bytes round-trip correctly)

---

### Case 2: PLIC — 4 MB of address space for ~30 bytes of state (Plan 3.A, 2026-04)

**Background**

Why does PLIC own *4 megabytes* of address space when its meaningful registers fit in less than a page? Read the spec and you'll see that the address layout is a function of "context" + "source." A real chip might have hundreds of contexts; with one S-mode hart and 32 sources, `ccc`'s instance is sparse.

**What happened**

The PLIC layout looks like (from `src/emulator/devices/plic.zig`):

- `0x0C00_0000 + src*4` — priority register for source `src` (4 bytes each, 32 sources → 128 bytes).
- `0x0C00_1000 + ctx*0x80` — pending registers (one per context).
- `0x0C00_2000 + ctx*0x80` — enable registers.
- `0x0C20_0000 + ctx*0x1000` — threshold + claim/complete (one register pair per context).

That last line is the killer: each context gets a 4 KB slot for one register pair. With one context (S-mode hart 0), we use 8 bytes out of a 4 KB slot. With 8 hypothetical contexts, you'd use 64 bytes out of 32 KB. The address layout *scales* with hardware-platform variants; software-emulated, the unused regions are just `readByte` returning 0.

In `ccc`, `plic.zig`'s `readByte`/`writeByte` handle every legal offset and return 0 (or accept the write as a no-op) for any unrecognized one. The 4 MB region in `memory.zig` is just a bound; most addresses inside it have no semantics.

**Relevance to memory-and-mmio**

A reminder that "MMIO range size" doesn't mean "the device has that much state." It means "the spec reserved that many addresses for the family." Sparse address spaces are a normal consequence of platform conventions.

**References**

- `src/emulator/devices/plic.zig`
- `src/emulator/memory.zig` (`PLIC_BASE`/`PLIC_SIZE`)

---

### Case 3: The first identity map (Plan 2.A / 2.C, 2026-04)

**Background**

When the kernel boots in `kernel.elf`, the M-mode boot shim sets up enough of the world that S-mode can take over. One critical step: build a page table that maps every kernel-relevant VA to PA identity-style (VA == PA). Without that, the very first kernel instruction after `mret` would page-fault — the trap handler would page-fault — and the system would loop forever.

**What happened**

`src/kernel/kmain.zig` allocates an L1 table (1024 entries × 4 bytes = 4 KB) at a fixed PA, then for every needed range:
- The kernel text (where the kernel itself lives — `0x80000000` upward, ~30 KB).
- The kernel data + BSS.
- Every MMIO range needed by the kernel: UART, CLINT, PLIC, block.

For each, it walks (logically): pick the L1 entry by `VPN[1]`, allocate or find the L0 table, set the leaf PTE to `(PA >> 12) << 10 | PTE_V | PTE_R | PTE_W | PTE_X` (full kernel perms — no U bit).

The build helpers `makePointerPte` and `makeLeafPte` from `src/emulator/memory.zig` are reused here — kernel-side `vm.zig` imports them so it doesn't have to re-derive the bit shifts.

After `csrw satp, ...` enables Sv32, the CPU keeps executing — because the page right *above* the current PC is mapped identity. Without that one PTE, the next fetch would page-fault.

**Relevance to memory-and-mmio**

The identity-map pattern is the kernel's bridge from "no paging" to "paging on": same addresses, same code, same data, but now there's a translation layer. Every Phase-2-and-up demo depends on this working. Get the kernel-text mapping wrong by one page and `kernel.elf` deadlocks immediately.

**References**

- `src/kernel/kmain.zig` (the early page-table setup)
- `src/kernel/vm.zig` (the helpers)
- `src/emulator/memory.zig` (the PTE constants + `makeLeafPte`)
- `tests/e2e/kernel.zig` (passes only if the identity map works)

---

### Case 4: A page fault during U-mode `addi` (Plan 1.D, 2026-04)

**Background**

Phase 1.D added U-mode + Sv32. The first time the test suite ran a U-mode program through an empty page table (no PTEs), every fetch should fault. Specifically: the test in `cpu.zig` named `"instruction page fault: step() from unmapped PC in U-mode updates mcause and mtval"`.

**What happened**

The test:

1. Allocates `Memory`. Sets `cpu.privilege = .U`. Sets `cpu.csr.satp = (1 << 31) | (root_pa >> 12)`. Sets `cpu.csr.mtvec = 0x8000_1000`.
2. Sets `cpu.pc = 0x0001_0000` — a virtual address with no PTE backing it.
3. Calls `cpu.step()`.
4. Inside `step`: `check_interrupt` returns false (no IRQs pending). `mem.translate(0x0001_0000, .fetch, .U, cpu)` walks the table: L1[0] is zero → `PTE.V = 0` → returns `error.InstPageFault`.
5. `step` catches `error.InstPageFault` and calls `trap.enter(.instr_page_fault, pre_pc, cpu)`.
6. Trap.enter sets `cpu.csr.mcause = 12` (instruction page fault), `cpu.csr.mtval = 0x0001_0000` (the faulting PC), `cpu.csr.mepc = 0x0001_0000`, switches privilege to M, jumps to `mtvec`.

Result: `step` returns normally; the next `step` would fetch from `0x8000_1000`. Test assertions:

```zig
try expect(@intFromEnum(trap.Cause.instr_page_fault) == cpu.csr.mcause); // 12
try expect(0x0001_0000 == cpu.csr.mtval);
try expect(.M == cpu.privilege);
try expect(0x8000_1000 == cpu.pc);
```

**Relevance to memory-and-mmio**

This test is the proof that the translation→trap path works *at the very first edge case*. If `translate` ever returned the wrong fault variant, or didn't return a fault when it should, `mcause` would show something else and the test would fail loudly. That's why it lives in `cpu.zig` next to the CPU struct — it's a foundational check for every Phase-2+ run.

**References**

- `src/emulator/cpu.zig` (test of same name)
- `src/emulator/trap.zig` (`trap.enter` + `Cause` enum)
- `src/emulator/memory.zig` (`pageFaultFor` mapping)

---

### Case 5: The tohost backdoor — riscv-tests' pass/fail signal (Plan 1.D, 2026-04)

**Background**

The official RISC-V conformance suite (`tests/riscv-tests/`) signals pass/fail by writing to a symbol named `tohost`. Each test ELF includes a `.tohost` section containing 8 bytes; the suite's macros `RVTEST_PASS` and `RVTEST_FAIL` resolve to a write of `1` (pass) or `(test_num << 1) | 1` (fail).

**What happened**

When `ccc/src/emulator/elf.zig` loads an ELF, it walks the symbol table and looks for the `tohost` symbol. If found, `Memory.tohost_addr` is set to that virtual address (which is in RAM, since the linker places the section there).

`storeBytePhysical` then has a special arm:

```zig
if (self.inTohost(addr)) {
    const off = try self.ramOffset(addr);
    self.ram[off] = value;     // commit byte (so post-mortem inspection works)
    if (self.halt.exit_code == null and value != 0) {
        self.halt.exit_code = if (value == 1) 0 else value >> 1;
    }
    return MemoryError.Halt;
}
```

The byte is committed to RAM *and* the halt is signaled. `cpu.run` propagates `error.Halt` out, returns; `main.zig` reads `halt.exit_code` and exits the host process with that code.

For our 67-test suite, every passing test writes `1` to tohost. The `riscv-tests` build target asserts a clean `0` exit code from all of them.

**Relevance to memory-and-mmio**

A perfectly normal-looking `sb` or `sw` instruction — at a special address — terminates the program. This is MMIO at its purest: the address has *no other* side effect than a function call. The test runner doesn't need a special "halt signal" mechanism in the ABI; it just writes a byte to the right address.

**References**

- `src/emulator/memory.zig` (`inTohost` + the special arm)
- `src/emulator/elf.zig` (symbol-table scan)
- `tests/riscv-tests/env/p/riscv_test.h` (the `RVTEST_PASS`/`FAIL` macros)
- `build.zig` target `riscv-tests`

---

### Case 6: The block device CMD-byte-3 trigger (Plan 3.A, 2026-04)

**Background**

The block device serves 4 KB sectors out of a host file. The kernel "submits" a transfer by writing four bytes (the CMD word: op + sector_lo + sector_hi + buffer_pa_low) into the CMD register at offset 0x8..0xB.

**What happened**

Look at the special case in `storeBytePhysical`:

```zig
if (inRange(addr, BLOCK_BASE, BLOCK_SIZE)) {
    const off = addr - BLOCK_BASE;
    self.block.writeByte(off, value) catch ...;
    if (off == 0xB) {
        self.block.performTransfer(self.io, self.ram);
    }
    return;
}
```

The kernel might write CMD as four `sb`s in any order, or as one `sw`. Either way, `storeWordPhysical`'s MMIO fall-through breaks the word into four byte-stores. The transfer triggers on byte 3 (offset 0xB) — the high byte of the CMD word — assuming the kernel writes byte 3 last.

When the kernel does write CMD as `sw`, `storeWordPhysical` calls `storeBytePhysical` four times in order, so byte 0xB is written last, and `performTransfer` runs after all four bytes are in `pending_cmd`. ✓

If the kernel ever wrote bytes out of order (byte 3 first), the transfer would happen with stale data in bytes 0..2. This is a known constraint, documented in `block.zig`. The kernel doesn't violate it (it always uses `sw`).

**Relevance to memory-and-mmio**

The MMIO byte-by-byte path isn't just routing — it's where device-protocol decisions get encoded. The "trigger on byte 3" rule is half mechanism-of-action, half assumption about the kernel's write pattern.

**References**

- `src/emulator/memory.zig` (`storeBytePhysical` block arm)
- `src/emulator/devices/block.zig` (`performTransfer`)
- `programs/plic_block_test/test.S` (asm-only test that hits this path)
- `build.zig` target `e2e-plic-block`
