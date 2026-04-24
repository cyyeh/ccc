const std = @import("std");
const halt_dev = @import("devices/halt.zig");
const uart_dev = @import("devices/uart.zig");
const clint_dev = @import("devices/clint.zig");
const cpu_mod = @import("cpu.zig");
pub const PrivilegeMode = cpu_mod.PrivilegeMode;
const Cpu = cpu_mod.Cpu;

pub const RAM_BASE: u32 = 0x8000_0000;
pub const RAM_SIZE_DEFAULT: usize = 128 * 1024 * 1024;

pub const Access = enum { fetch, load, store };

// ---------------------------------------------------------------------------
// Sv32 PTE bit constants (RISC-V privileged spec §4.3.1)
// ---------------------------------------------------------------------------
pub const PTE_V: u32 = 1 << 0;
pub const PTE_R: u32 = 1 << 1;
pub const PTE_W: u32 = 1 << 2;
pub const PTE_X: u32 = 1 << 3;
pub const PTE_U: u32 = 1 << 4;
pub const PTE_G: u32 = 1 << 5;
pub const PTE_A: u32 = 1 << 6;
pub const PTE_D: u32 = 1 << 7;

/// Build a 4-KB leaf PTE from a physical address and permission flags.
/// The caller must include PTE_V in `flags`.
pub fn makeLeafPte(pa: u32, flags: u32) u32 {
    return ((pa >> 12) << 10) | flags;
}

/// Build a pointer (non-leaf) PTE pointing at `child_table_pa`.
/// V=1, R=W=X=0 marks it as a pointer per the Sv32 spec.
pub fn makePointerPte(child_table_pa: u32) u32 {
    return ((child_table_pa >> 12) << 10) | PTE_V;
}

pub const TranslationError = error{
    InstPageFault,
    LoadPageFault,
    StorePageFault,
};

pub const MemoryError = error{
    OutOfBounds,
    MisalignedAccess,
    UnexpectedRegister,
    WriteFailed,
    Halt,
};

pub const Memory = struct {
    ram: []u8,
    halt: *halt_dev.Halt,
    uart: *uart_dev.Uart,
    clint: *clint_dev.Clint,
    /// If set, writes inside [tohost_addr, tohost_addr+8) terminate the run
    /// via `MemoryError.Halt`. Used by riscv-tests which signal pass/fail by
    /// writing to a `tohost` symbol.
    tohost_addr: ?u32,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        halt: *halt_dev.Halt,
        uart: *uart_dev.Uart,
        clint: *clint_dev.Clint,
        tohost_addr: ?u32,
        ram_size: usize,
    ) !Memory {
        const ram = try allocator.alloc(u8, ram_size);
        @memset(ram, 0);
        return .{
            .ram = ram,
            .halt = halt,
            .uart = uart,
            .clint = clint,
            .tohost_addr = tohost_addr,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Memory) void {
        self.allocator.free(self.ram);
    }

    fn ramOffset(self: *const Memory, addr: u32) MemoryError!usize {
        if (addr < RAM_BASE) return MemoryError.OutOfBounds;
        const offset = addr - RAM_BASE;
        if (offset >= self.ram.len) return MemoryError.OutOfBounds;
        return @as(usize, offset);
    }

    fn inRange(addr: u32, base: u32, size: u32) bool {
        return addr >= base and addr < base +% size;
    }

    fn inTohost(self: *const Memory, addr: u32) bool {
        const base = self.tohost_addr orelse return false;
        return addr >= base and addr < base +% 8;
    }

    pub fn loadBytePhysical(self: *Memory, addr: u32) MemoryError!u8 {
        if (inRange(addr, uart_dev.UART_BASE, uart_dev.UART_SIZE)) {
            return self.uart.readByte(addr - uart_dev.UART_BASE) catch |e| switch (e) {
                error.UnexpectedRegister => MemoryError.UnexpectedRegister,
                error.WriteFailed => MemoryError.WriteFailed,
            };
        }
        if (inRange(addr, halt_dev.HALT_BASE, halt_dev.HALT_SIZE)) {
            return 0;
        }
        if (inRange(addr, clint_dev.CLINT_BASE, clint_dev.CLINT_SIZE)) {
            return self.clint.readByte(addr - clint_dev.CLINT_BASE) catch |e| switch (e) {
                error.UnexpectedRegister => MemoryError.UnexpectedRegister,
            };
        }
        const off = try self.ramOffset(addr);
        return self.ram[off];
    }

    pub fn loadHalfwordPhysical(self: *Memory, addr: u32) MemoryError!u16 {
        if (addr & 1 != 0) return MemoryError.MisalignedAccess;
        const lo = try self.loadBytePhysical(addr);
        const hi = try self.loadBytePhysical(addr + 1);
        return (@as(u16, hi) << 8) | @as(u16, lo);
    }

    pub fn loadWordPhysical(self: *Memory, addr: u32) MemoryError!u32 {
        if (addr & 3 != 0) return MemoryError.MisalignedAccess;
        // Fast path for RAM:
        if (addr >= RAM_BASE) {
            const off = try self.ramOffset(addr);
            if (off + 4 > self.ram.len) return MemoryError.OutOfBounds;
            return std.mem.readInt(u32, self.ram[off..][0..4], .little);
        }
        // Generic byte-by-byte path for MMIO:
        const b0 = try self.loadBytePhysical(addr);
        const b1 = try self.loadBytePhysical(addr + 1);
        const b2 = try self.loadBytePhysical(addr + 2);
        const b3 = try self.loadBytePhysical(addr + 3);
        return (@as(u32, b3) << 24) | (@as(u32, b2) << 16) |
            (@as(u32, b1) << 8) | @as(u32, b0);
    }

    pub fn storeBytePhysical(self: *Memory, addr: u32, value: u8) MemoryError!void {
        if (inRange(addr, uart_dev.UART_BASE, uart_dev.UART_SIZE)) {
            self.uart.writeByte(addr - uart_dev.UART_BASE, value) catch |e| switch (e) {
                error.UnexpectedRegister => return MemoryError.UnexpectedRegister,
                error.WriteFailed => return MemoryError.WriteFailed,
            };
            return;
        }
        if (inRange(addr, halt_dev.HALT_BASE, halt_dev.HALT_SIZE)) {
            self.halt.writeByte(addr - halt_dev.HALT_BASE, value) catch |e| switch (e) {
                error.Halt => return MemoryError.Halt,
            };
            return;
        }
        if (inRange(addr, clint_dev.CLINT_BASE, clint_dev.CLINT_SIZE)) {
            self.clint.writeByte(addr - clint_dev.CLINT_BASE, value) catch |e| switch (e) {
                error.UnexpectedRegister => return MemoryError.UnexpectedRegister,
            };
            return;
        }
        // tohost: any write inside the 8-byte region halts the run. We still
        // commit the byte to RAM so post-mortem inspection sees the value.
        if (self.inTohost(addr)) {
            const off = try self.ramOffset(addr);
            self.ram[off] = value;
            // riscv-tests HTIF convention: the first nonzero byte written to
            // tohost encodes the result. Value 1 == PASS (exit 0); any other
            // nonzero value v == FAIL with test number (v >> 1).
            if (self.halt.exit_code == null and value != 0) {
                self.halt.exit_code = if (value == 1) 0 else value >> 1;
            }
            return MemoryError.Halt;
        }
        const off = try self.ramOffset(addr);
        self.ram[off] = value;
    }

    pub fn storeHalfwordPhysical(self: *Memory, addr: u32, value: u16) MemoryError!void {
        if (addr & 1 != 0) return MemoryError.MisalignedAccess;
        try self.storeBytePhysical(addr, @truncate(value));
        try self.storeBytePhysical(addr + 1, @truncate(value >> 8));
    }

    pub fn storeWordPhysical(self: *Memory, addr: u32, value: u32) MemoryError!void {
        if (addr & 3 != 0) return MemoryError.MisalignedAccess;
        if (addr >= RAM_BASE and !self.inTohost(addr)) {
            const off = try self.ramOffset(addr);
            if (off + 4 > self.ram.len) return MemoryError.OutOfBounds;
            std.mem.writeInt(u32, self.ram[off..][0..4], value, .little);
            return;
        }
        try self.storeBytePhysical(addr, @truncate(value));
        try self.storeBytePhysical(addr + 1, @truncate(value >> 8));
        try self.storeBytePhysical(addr + 2, @truncate(value >> 16));
        try self.storeBytePhysical(addr + 3, @truncate(value >> 24));
    }

    // ------------------------------------------------------------------
    // Translation-aware accessors.
    //
    // These are the load/store APIs used by the execute pipeline: each
    // first calls `translate` (which honors satp / effective privilege
    // / MPRV) and then funnels through the physical-address bypass.
    // ------------------------------------------------------------------

    pub fn loadByte(self: *Memory, va: u32, cpu: *const Cpu) (MemoryError || TranslationError)!u8 {
        const pa = try self.translate(va, .load, effectivePriv(cpu, .load), cpu);
        return self.loadBytePhysical(pa);
    }

    pub fn loadHalfword(self: *Memory, va: u32, cpu: *const Cpu) (MemoryError || TranslationError)!u16 {
        const pa = try self.translate(va, .load, effectivePriv(cpu, .load), cpu);
        return self.loadHalfwordPhysical(pa);
    }

    pub fn loadWord(self: *Memory, va: u32, cpu: *const Cpu) (MemoryError || TranslationError)!u32 {
        const pa = try self.translate(va, .load, effectivePriv(cpu, .load), cpu);
        return self.loadWordPhysical(pa);
    }

    pub fn storeByte(self: *Memory, va: u32, value: u8, cpu: *const Cpu) (MemoryError || TranslationError)!void {
        const pa = try self.translate(va, .store, effectivePriv(cpu, .store), cpu);
        return self.storeBytePhysical(pa, value);
    }

    pub fn storeHalfword(self: *Memory, va: u32, value: u16, cpu: *const Cpu) (MemoryError || TranslationError)!void {
        const pa = try self.translate(va, .store, effectivePriv(cpu, .store), cpu);
        return self.storeHalfwordPhysical(pa, value);
    }

    pub fn storeWord(self: *Memory, va: u32, value: u32, cpu: *const Cpu) (MemoryError || TranslationError)!void {
        const pa = try self.translate(va, .store, effectivePriv(cpu, .store), cpu);
        return self.storeWordPhysical(pa, value);
    }

    /// Virtual-to-physical address translation.
    ///
    /// `effective_priv` is the effective privilege level (may differ from
    /// `cpu.privilege` when MPRV is set — Task 19 will compute it).
    /// `cpu` provides read access to satp and all mstatus fields needed by
    /// Tasks 15-19 (mstatus_mxr, mstatus_sum, mstatus_mprv, mstatus_mpp).
    ///
    /// M-mode always produces an identity mapping regardless of satp.
    /// Non-M-mode with satp.MODE == Bare (bit 31 == 0) also returns identity.
    /// Sv32 4-KB-leaf page walk (satp.MODE == 1): see RISC-V priv spec §4.3.2.
    pub fn translate(
        self: *Memory,
        va: u32,
        access: Access,
        effective_priv: PrivilegeMode,
        cpu: *const Cpu,
    ) TranslationError!u32 {
        // M-mode always identity, regardless of satp.
        if (effective_priv == .M) return va;
        // Non-M + MODE == Bare (satp bit 31 == 0) → identity.
        const mode = (cpu.csr.satp >> 31) & 1;
        if (mode == 0) return va;

        // Sv32 walk — 4KB leaves only, superpage (L1 leaf) rejected.
        // PTE reads and A/D write-backs use the physical-address bypass
        // (`*Physical`) — the translating variants would recurse through
        // this very function.
        const vpn1: u32 = (va >> 22) & 0x3FF;
        const vpn0: u32 = (va >> 12) & 0x3FF;
        const off: u32 = va & 0xFFF;
        const root_pa: u32 = (cpu.csr.satp & 0x003F_FFFF) << 12;

        // Level-1 PTE lookup.
        const l1_pte_pa = root_pa + vpn1 * 4;
        const l1_pte = self.loadWordPhysical(l1_pte_pa) catch return pageFaultFor(access);
        if ((l1_pte & PTE_V) == 0) return pageFaultFor(access);
        if ((l1_pte & (PTE_R | PTE_W | PTE_X)) != 0) {
            // Superpage leaf at L1 — Phase 2 rejects (not yet implemented).
            return pageFaultFor(access);
        }

        // Level-0 PTE lookup.
        const l0_table_pa = ((l1_pte >> 10) & 0x003F_FFFF) << 12;
        const l0_pte_pa = l0_table_pa + vpn0 * 4;
        const l0_pte = self.loadWordPhysical(l0_pte_pa) catch return pageFaultFor(access);
        if ((l0_pte & PTE_V) == 0) return pageFaultFor(access);
        // A pointer PTE (R|W|X == 0) at leaf level is invalid per spec §4.3.2 step 5.
        if ((l0_pte & (PTE_R | PTE_W | PTE_X)) == 0) return pageFaultFor(access);

        const leaf_pa = ((l0_pte >> 10) & 0x003F_FFFF) << 12;

        // Permission check
        const pte_u = (l0_pte & PTE_U) != 0;
        const pte_r = (l0_pte & PTE_R) != 0;
        const pte_w = (l0_pte & PTE_W) != 0;
        const pte_x = (l0_pte & PTE_X) != 0;

        // U-bit vs privilege
        if (effective_priv == .U and !pte_u) return pageFaultFor(access);
        if (effective_priv == .S) {
            if (access == .fetch and pte_u) return pageFaultFor(access);  // S never executes U pages
            if (access != .fetch and pte_u and !cpu.csr.mstatus_sum) return pageFaultFor(access);
        }

        // Access-type vs PTE.R/W/X (with MXR extending readability)
        const effective_readable = pte_r or (pte_x and cpu.csr.mstatus_mxr);
        switch (access) {
            .fetch => if (!pte_x) return pageFaultFor(access),
            .load  => if (!effective_readable) return pageFaultFor(access),
            .store => if (!pte_w) return pageFaultFor(access),
        }

        // A/D bit update-in-place.
        //
        // RISC-V privileged spec §4.3.1 specifies two allowed implementations for
        // A/D: (a) raise a page fault when A=0 (or D=0 on store), letting the OS
        // set them; (b) update them in place as part of the hardware walk. We use
        // (b) — simpler for the emulator and avoids needing an OS A/D handler.
        var new_pte = l0_pte;
        var dirty = false;
        if ((l0_pte & PTE_A) == 0) {
            new_pte |= PTE_A;
            dirty = true;
        }
        if (access == .store and (l0_pte & PTE_D) == 0) {
            new_pte |= PTE_D;
            dirty = true;
        }
        if (dirty) {
            // Physical-address bypass: this write targets the PTE itself,
            // not a virtual address, so it MUST NOT recurse through
            // `storeWord`.
            self.storeWordPhysical(l0_pte_pa, new_pte) catch return pageFaultFor(access);
        }

        return leaf_pa | off;
    }
};

/// Return the appropriate page-fault error variant for the given access type.
fn pageFaultFor(access: Access) TranslationError {
    return switch (access) {
        .fetch => error.InstPageFault,
        .load => error.LoadPageFault,
        .store => error.StorePageFault,
    };
}

/// Compute the effective privilege for a load/store/fetch.
/// - Fetch: always `cpu.privilege` (MPRV never applies to fetch).
/// - Load/store: `cpu.privilege` normally, but if `cpu.privilege == .M` and
///   `mstatus_mprv` is set, use `mstatus_mpp` as the effective privilege.
///   This lets M-mode execute loads/stores as if from U-mode, used by kernel
///   page-fault handlers that access user memory. Task 19 tests this fully.
pub fn effectivePriv(cpu: *const Cpu, access: Access) PrivilegeMode {
    if (access != .fetch and cpu.privilege == .M and cpu.csr.mstatus_mprv) {
        return @enumFromInt(cpu.csr.mstatus_mpp);
    }
    return cpu.privilege;
}

// Test fixture: the Uart embeds `*std.Io.Writer` pointing into the rig's
// `aw` field, so the rig MUST NOT be moved/copied after init. We use a
// fill-in-place pattern (init takes `*TestRig`) to guarantee stable addresses.
const TestRig = struct {
    halt: halt_dev.Halt,
    uart: uart_dev.Uart,
    clint: clint_dev.Clint,
    aw: std.Io.Writer.Allocating,
    mem: Memory,
    cpu: Cpu,

    fn init(self: *TestRig, allocator: std.mem.Allocator) !void {
        self.halt = halt_dev.Halt.init();
        self.aw = .init(allocator);
        self.uart = uart_dev.Uart.init(&self.aw.writer);
        self.clint = clint_dev.Clint.init(&clint_dev.fixtureClock);
        self.mem = try Memory.init(allocator, &self.halt, &self.uart, &self.clint, null, RAM_SIZE_DEFAULT);
        self.cpu = Cpu.init(&self.mem, RAM_BASE);
    }

    fn deinit(self: *TestRig) void {
        self.mem.deinit();
        self.aw.deinit();
    }
};

test "RAM byte round-trip via routed Memory" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    try rig.mem.storeBytePhysical(RAM_BASE + 100, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), try rig.mem.loadBytePhysical(RAM_BASE + 100));
}

test "store to UART THR forwards to writer" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    try rig.mem.storeBytePhysical(uart_dev.UART_BASE, 'X');
    try rig.mem.storeBytePhysical(uart_dev.UART_BASE, 'Y');
    try std.testing.expectEqualStrings("XY", rig.aw.written());
}

test "store to halt MMIO returns error.Halt" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    try std.testing.expectError(MemoryError.Halt, rig.mem.storeBytePhysical(halt_dev.HALT_BASE, 7));
    try std.testing.expectEqual(@as(?u8, 7), rig.halt.exit_code);
}

test "word store/load is little-endian (in RAM)" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    try rig.mem.storeWordPhysical(RAM_BASE, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u8, 0xEF), try rig.mem.loadBytePhysical(RAM_BASE));
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), try rig.mem.loadWordPhysical(RAM_BASE));
}

test "out-of-RAM access (and not in any device range) returns OutOfBounds" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    try std.testing.expectError(MemoryError.OutOfBounds, rig.mem.loadBytePhysical(0x4000_0000));
}

test "misaligned word load returns MisalignedAccess" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    try std.testing.expectError(MemoryError.MisalignedAccess, rig.mem.loadWordPhysical(RAM_BASE + 1));
}

test "word load from CLINT mtime returns nonzero after clock advances" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    clint_dev.fixture_clock_ns = 0;
    rig.clint.epoch_ns = 0;
    clint_dev.fixture_clock_ns = 10_000; // 100 ticks
    const v = try rig.mem.loadWordPhysical(clint_dev.CLINT_BASE + 0xBFF8);
    try std.testing.expectEqual(@as(u32, 100), v);
}

test "translate: Bare mode returns identity from U-mode" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    // U-mode, satp = 0 means MODE = Bare
    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = 0;
    const pa = try rig.mem.translate(0x8000_0000, .load, .U, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), pa);
}

test "translate: M-mode always identity even with Sv32 MODE" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    // M-mode, satp has bit 31 set (Sv32) with bogus PPN
    rig.cpu.privilege = .M;
    rig.cpu.csr.satp = (1 << 31) | 0x1234;
    const pa = try rig.mem.translate(0x8000_0000, .load, .M, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), pa);
}

test "translate: Sv32 4K leaf, U-mode, matches VA→PA" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();

    const root_pa: u32 = 0x8010_0000;
    const l0_table_pa: u32 = 0x8010_1000;
    const leaf_pa: u32 = 0x8020_0000;

    // VA 0x00010000 → VPN[1]=0, VPN[0]=0x10, offset=0
    try rig.mem.storeWordPhysical(root_pa + 0, makePointerPte(l0_table_pa));
    try rig.mem.storeWordPhysical(l0_table_pa + 0x10 * 4, makeLeafPte(leaf_pa, PTE_V | PTE_R | PTE_W | PTE_U));

    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);

    const pa = try rig.mem.translate(0x0001_0000, .load, .U, &rig.cpu);
    try std.testing.expectEqual(leaf_pa, pa);
}

test "translate: Sv32 4K leaf preserves offset" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();

    const root_pa: u32 = 0x8010_0000;
    const l0_table_pa: u32 = 0x8010_1000;
    const leaf_pa: u32 = 0x8020_0000;

    try rig.mem.storeWordPhysical(root_pa + 0, makePointerPte(l0_table_pa));
    try rig.mem.storeWordPhysical(l0_table_pa + 0x10 * 4, makeLeafPte(leaf_pa, PTE_V | PTE_R | PTE_W | PTE_U));

    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);

    const pa = try rig.mem.translate(0x0001_0ABC, .load, .U, &rig.cpu);
    try std.testing.expectEqual(leaf_pa + 0xABC, pa);
}

test "translate: U-mode cannot access a page with U=0" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWordPhysical(root_pa, makePointerPte(l0_pa));
    try rig.mem.storeWordPhysical(l0_pa + 0x10 * 4, makeLeafPte(leaf_pa,
        PTE_V | PTE_R | PTE_W));  // U=0
    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);
    try std.testing.expectError(error.LoadPageFault,
        rig.mem.translate(0x0001_0000, .load, .U, &rig.cpu));
}

test "translate: S-mode without SUM cannot access U=1 page" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWordPhysical(root_pa, makePointerPte(l0_pa));
    try rig.mem.storeWordPhysical(l0_pa + 0x10 * 4, makeLeafPte(leaf_pa,
        PTE_V | PTE_R | PTE_W | PTE_U));
    rig.cpu.privilege = .S;
    rig.cpu.csr.mstatus_sum = false;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);
    try std.testing.expectError(error.LoadPageFault,
        rig.mem.translate(0x0001_0000, .load, .S, &rig.cpu));
}

test "translate: S-mode with SUM=1 may access U=1 page for load/store but never for fetch" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWordPhysical(root_pa, makePointerPte(l0_pa));
    try rig.mem.storeWordPhysical(l0_pa + 0x10 * 4, makeLeafPte(leaf_pa,
        PTE_V | PTE_R | PTE_W | PTE_X | PTE_U));
    rig.cpu.privilege = .S;
    rig.cpu.csr.mstatus_sum = true;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);

    // load ok
    _ = try rig.mem.translate(0x0001_0000, .load, .S, &rig.cpu);
    // store ok
    _ = try rig.mem.translate(0x0001_0000, .store, .S, &rig.cpu);
    // fetch from U=1 page is always a fault
    try std.testing.expectError(error.InstPageFault,
        rig.mem.translate(0x0001_0000, .fetch, .S, &rig.cpu));
}

test "translate: write to page without W bit is a store page fault" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWordPhysical(root_pa, makePointerPte(l0_pa));
    try rig.mem.storeWordPhysical(l0_pa + 0x10 * 4, makeLeafPte(leaf_pa,
        PTE_V | PTE_R | PTE_U));  // no W
    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);
    try std.testing.expectError(error.StorePageFault,
        rig.mem.translate(0x0001_0000, .store, .U, &rig.cpu));
}

test "translate: fetch from R-only page is a fault; fetch from X page succeeds" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWordPhysical(root_pa, makePointerPte(l0_pa));
    try rig.mem.storeWordPhysical(l0_pa + 0x10 * 4, makeLeafPte(leaf_pa,
        PTE_V | PTE_R | PTE_U));  // R only
    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);
    try std.testing.expectError(error.InstPageFault,
        rig.mem.translate(0x0001_0000, .fetch, .U, &rig.cpu));

    try rig.mem.storeWordPhysical(l0_pa + 0x10 * 4, makeLeafPte(leaf_pa,
        PTE_V | PTE_X | PTE_U));  // X only
    _ = try rig.mem.translate(0x0001_0000, .fetch, .U, &rig.cpu);
}

test "translate: MXR=1 allows load from X-only page" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWordPhysical(root_pa, makePointerPte(l0_pa));
    try rig.mem.storeWordPhysical(l0_pa + 0x10 * 4, makeLeafPte(leaf_pa,
        PTE_V | PTE_X | PTE_U));  // X only
    rig.cpu.privilege = .U;
    rig.cpu.csr.mstatus_mxr = false;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);
    try std.testing.expectError(error.LoadPageFault,
        rig.mem.translate(0x0001_0000, .load, .U, &rig.cpu));
    rig.cpu.csr.mstatus_mxr = true;
    _ = try rig.mem.translate(0x0001_0000, .load, .U, &rig.cpu);
}

test "translate: PTE.A is set on successful load" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWordPhysical(root_pa, makePointerPte(l0_pa));
    const initial_pte = makeLeafPte(leaf_pa, PTE_V | PTE_R | PTE_U);  // A=0
    try rig.mem.storeWordPhysical(l0_pa + 0x10 * 4, initial_pte);
    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);

    _ = try rig.mem.translate(0x0001_0000, .load, .U, &rig.cpu);
    const pte_after = try rig.mem.loadWordPhysical(l0_pa + 0x10 * 4);
    try std.testing.expect((pte_after & PTE_A) != 0);
}

test "translate: PTE.D is set on successful store; A also set" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWordPhysical(root_pa, makePointerPte(l0_pa));
    try rig.mem.storeWordPhysical(l0_pa + 0x10 * 4,
        makeLeafPte(leaf_pa, PTE_V | PTE_R | PTE_W | PTE_U));

    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);

    _ = try rig.mem.translate(0x0001_0000, .store, .U, &rig.cpu);
    const pte_after = try rig.mem.loadWordPhysical(l0_pa + 0x10 * 4);
    try std.testing.expect((pte_after & PTE_A) != 0);
    try std.testing.expect((pte_after & PTE_D) != 0);
}

test "translate: PTE.D stays 0 after a load-only access" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWordPhysical(root_pa, makePointerPte(l0_pa));
    try rig.mem.storeWordPhysical(l0_pa + 0x10 * 4,
        makeLeafPte(leaf_pa, PTE_V | PTE_R | PTE_W | PTE_U));
    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);

    _ = try rig.mem.translate(0x0001_0000, .load, .U, &rig.cpu);
    const pte_after = try rig.mem.loadWordPhysical(l0_pa + 0x10 * 4);
    try std.testing.expect((pte_after & PTE_A) != 0);
    try std.testing.expect((pte_after & PTE_D) == 0);
}

test "loadWord from U-mode through Sv32 translates VA→PA" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWordPhysical(root_pa, makePointerPte(l0_pa));
    try rig.mem.storeWordPhysical(l0_pa + 0x10 * 4,
        makeLeafPte(leaf_pa, PTE_V | PTE_R | PTE_W | PTE_U));
    try rig.mem.storeWordPhysical(leaf_pa, 0x1234_5678);

    rig.cpu.privilege = .U;
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);

    const v = try rig.mem.loadWord(0x0001_0000, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), v);
}

test "MPRV=1 in M-mode: loads use MPP privilege for translation" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();

    // Build a U-mode accessible page: VA 0x0001_0000 → PA 0x8020_0000.
    const root_pa : u32 = 0x8010_0000;
    const l0_pa   : u32 = 0x8010_1000;
    const leaf_pa : u32 = 0x8020_0000;
    try rig.mem.storeWordPhysical(root_pa, makePointerPte(l0_pa));
    try rig.mem.storeWordPhysical(l0_pa + 0x10 * 4,
        makeLeafPte(leaf_pa, PTE_V | PTE_R | PTE_W | PTE_U));
    try rig.mem.storeWordPhysical(leaf_pa, 0xCAFE_BABE);

    // Running in M-mode, but MPRV=1 and MPP=U and Sv32 enabled.
    // A raw M-mode load would be identity-mapped; MPRV must downgrade the
    // effective privilege to U so the load actually walks the page tables.
    rig.cpu.privilege = .M;
    rig.cpu.csr.mstatus_mprv = true;
    rig.cpu.csr.mstatus_mpp = @intFromEnum(PrivilegeMode.U);
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);

    const v = try rig.mem.loadWord(0x0001_0000, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0xCAFE_BABE), v);
}

test "MPRV has no effect on instruction fetch" {
    var rig: TestRig = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();

    // Empty root — any walk would fault. If MPRV affected fetch, the .fetch
    // translate call would walk this empty root and return InstPageFault.
    // It must NOT — fetch always uses cpu.privilege regardless of MPRV.
    const root_pa : u32 = 0x8010_0000;
    try rig.mem.storeWordPhysical(root_pa, 0);

    rig.cpu.privilege = .M;
    rig.cpu.csr.mstatus_mprv = true;
    rig.cpu.csr.mstatus_mpp = @intFromEnum(PrivilegeMode.U);
    rig.cpu.csr.satp = (1 << 31) | (root_pa >> 12);

    // M-mode fetch: should NOT translate even with MPRV. Expect identity pass-through.
    const pa = try rig.mem.translate(0x8000_0000, .fetch, .M, &rig.cpu);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), pa);
}
