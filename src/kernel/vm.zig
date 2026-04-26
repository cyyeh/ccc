// tests/programs/kernel/vm.zig — kernel-side Sv32 page-table builder.
//
// We never walk page tables from the kernel — the emulator does that on
// every access. We only CONSTRUCT them here. Layout mirrors the emulator's
// memory.zig: 2-level walk, 4KB pages only, PTE bits { V R W X U G A D }.
//
// Kernel is direct-mapped (VA==PA) at 0x80000000+, so physical addresses
// returned by page_alloc can be dereferenced as pointers during the build.
//
// Phase 2 keeps the kernel in a single address space (the process's page
// table), which means kmain's own executing instructions — those between
// the `csrw satp` and `sfence.vma` in Task 7 — must be mapped in that
// table's kernel region. mapKernelAndMmio handles that.

const page_alloc = @import("page_alloc.zig");
const kprintf = @import("kprintf.zig");

pub const PAGE_SIZE: u32 = 4096;
pub const PAGE_SHIFT: u5 = 12;

// PTE flag bits — match src/memory.zig layout exactly.
pub const PTE_V: u32 = 1 << 0;
pub const PTE_R: u32 = 1 << 1;
pub const PTE_W: u32 = 1 << 2;
pub const PTE_X: u32 = 1 << 3;
pub const PTE_U: u32 = 1 << 4;
pub const PTE_G: u32 = 1 << 5;
pub const PTE_A: u32 = 1 << 6;
pub const PTE_D: u32 = 1 << 7;

// Convenience flag combinations. We pre-set A and D on every leaf we
// install — the emulator's translate() would do the same on first
// access, but pre-setting avoids the write-back dance for pages the
// kernel knows will be touched.
pub const KERNEL_TEXT: u32 = PTE_R | PTE_X | PTE_G | PTE_A | PTE_D;
pub const KERNEL_RODATA: u32 = PTE_R | PTE_G | PTE_A | PTE_D;
pub const KERNEL_DATA: u32 = PTE_R | PTE_W | PTE_G | PTE_A | PTE_D;
pub const KERNEL_MMIO: u32 = PTE_R | PTE_W | PTE_G | PTE_A | PTE_D;
pub const USER_RWX: u32 = PTE_R | PTE_W | PTE_X | PTE_U | PTE_A | PTE_D;
pub const USER_RW: u32 = PTE_R | PTE_W | PTE_U | PTE_A | PTE_D;

fn vpn1(va: u32) u32 {
    return (va >> 22) & 0x3FF;
}
fn vpn0(va: u32) u32 {
    return (va >> 12) & 0x3FF;
}

fn ppnOfPte(pte: u32) u32 {
    // PPN occupies bits 31:10 of the 32-bit PTE, where bits 9:8 are RSW.
    // PTE layout: [PPN (22)][RSW (2)][DAGU XWR V (8)].
    return (pte >> 10) & 0x3F_FFFF;
}

fn makeLeaf(pa: u32, flags: u32) u32 {
    // pa must be PAGE_SIZE-aligned.
    return ((pa >> 12) << 10) | (flags & 0xFF);
}

fn makePointer(child_pa: u32) u32 {
    // Pointer PTE: V=1, R=W=X=0, PPN = child_pa >> 12.
    return ((child_pa >> 12) << 10) | PTE_V;
}

fn ptePtr(table_pa: u32, index: u32) *volatile u32 {
    return @ptrFromInt(table_pa + index * 4);
}

pub fn allocRoot() ?u32 {
    return page_alloc.alloc();
}

/// Map a single 4KB page at `va` to physical page `pa` with the given flags.
/// Panics if `va` or `pa` is not PAGE_SIZE-aligned, if the L0 leaf is
/// already populated, or if the L1 entry is a leaf (Phase 2 rejects
/// superpages so we never write one, but we guard in case a future bug
/// corrupts the root).
pub fn mapPage(root_pa: u32, va: u32, pa: u32, flags: u32) void {
    if ((va & (PAGE_SIZE - 1)) != 0) {
        kprintf.panic("vm.mapPage: unaligned va {x}", .{va});
    }
    if ((pa & (PAGE_SIZE - 1)) != 0) {
        kprintf.panic("vm.mapPage: unaligned pa {x}", .{pa});
    }

    const l1_idx = vpn1(va);
    const l1_entry = ptePtr(root_pa, l1_idx);
    var l0_table_pa: u32 = undefined;
    if ((l1_entry.* & PTE_V) == 0) {
        l0_table_pa = page_alloc.allocZeroPage();
        l1_entry.* = makePointer(l0_table_pa);
    } else {
        // Valid L1 entry — must be a pointer (superpages rejected).
        if ((l1_entry.* & (PTE_R | PTE_W | PTE_X)) != 0) {
            kprintf.panic("vm.mapPage: unexpected L1 leaf at va {x}", .{va});
        }
        l0_table_pa = ppnOfPte(l1_entry.*) << 12;
    }

    const l0_idx = vpn0(va);
    const l0_entry = ptePtr(l0_table_pa, l0_idx);
    if ((l0_entry.* & PTE_V) != 0) {
        kprintf.panic("vm.mapPage: remap at va {x} (old pte {x})", .{ va, l0_entry.* });
    }
    l0_entry.* = makeLeaf(pa, flags | PTE_V);
}

/// Look up the physical address backing `va` in `root_pa`'s Sv32 table.
/// Returns the PA if a valid leaf PTE exists, null otherwise.
pub fn lookupPA(root_pa: u32, va: u32) ?u32 {
    const l1_idx = vpn1(va);
    const l1_entry = ptePtr(root_pa, l1_idx);
    if ((l1_entry.* & PTE_V) == 0) return null;
    if ((l1_entry.* & (PTE_R | PTE_W | PTE_X)) != 0) return null; // superpage — not used
    const l0_table_pa = ppnOfPte(l1_entry.*) << 12;
    const l0_idx = vpn0(va);
    const l0_entry = ptePtr(l0_table_pa, l0_idx);
    if ((l0_entry.* & PTE_V) == 0) return null;
    return ppnOfPte(l0_entry.*) << 12;
}

/// Map a contiguous VA region to a contiguous PA region, page by page.
/// `va` and `pa` must be PAGE_SIZE-aligned; `len` is rounded up to a
/// PAGE_SIZE multiple.
pub fn mapRange(root_pa: u32, va: u32, pa: u32, len: u32, flags: u32) void {
    const aligned_len = (len + (PAGE_SIZE - 1)) & ~(PAGE_SIZE - 1);
    var off: u32 = 0;
    while (off < aligned_len) : (off += PAGE_SIZE) {
        mapPage(root_pa, va + off, pa + off, flags);
    }
}

// Linker symbols — boundaries of each kernel section, all 4KB-aligned
// by linker.ld.
extern const _text_start: u8;
extern const _text_end: u8;
extern const _rodata_start: u8;
extern const _rodata_end: u8;
extern const _data_start: u8;
extern const _data_end: u8;
extern const _bss_start: u8;
extern const _bss_end: u8;
extern const _kstack_bottom: u8;
extern const _kstack_top: u8;

fn extU32(sym: *const u8) u32 {
    return @intCast(@intFromPtr(sym));
}

/// Map the kernel's own direct-mapped image plus the MMIO strip into
/// `root_pa`. Kernel VA == Kernel PA for every page we install here.
///
/// After this call, `csrw satp; sfence.vma` can safely switch to the
/// new page table — the executing kernel's .text will still be
/// reachable, its stack will still be valid, and its UART/Halt writes
/// will still hit the real MMIO.
pub fn mapKernelAndMmio(root_pa: u32) void {
    const text_s = extU32(&_text_start);
    const text_e = extU32(&_text_end);
    mapRange(root_pa, text_s, text_s, text_e - text_s, KERNEL_TEXT);

    const rodata_s = extU32(&_rodata_start);
    const rodata_e = extU32(&_rodata_end);
    if (rodata_e > rodata_s) {
        mapRange(root_pa, rodata_s, rodata_s, rodata_e - rodata_s, KERNEL_RODATA);
    }

    const data_s = extU32(&_data_start);
    const data_e = extU32(&_data_end);
    if (data_e > data_s) {
        mapRange(root_pa, data_s, data_s, data_e - data_s, KERNEL_DATA);
    }

    const bss_s = extU32(&_bss_start);
    const bss_e = extU32(&_bss_end);
    if (bss_e > bss_s) {
        mapRange(root_pa, bss_s, bss_s, bss_e - bss_s, KERNEL_DATA);
    }

    const stack_s = extU32(&_kstack_bottom);
    const stack_e = extU32(&_kstack_top);
    mapRange(root_pa, stack_s, stack_s, stack_e - stack_s, KERNEL_DATA);

    // Also cover the free-page region managed by the free-list allocator.
    // We need the kernel to be able to dereference any allocator-owned
    // page during page-table walks (e.g. reading an L0 table produced by
    // a prior alloc). Map all kernel-direct RAM beyond heap_start up to
    // RAM_END; over-mapping is harmless (unreferenced PTEs cost nothing).
    // heap_start is a fixed boundary set by init() — not a moving cursor.
    const heap_s = page_alloc.heapStart();
    mapRange(root_pa, heap_s, heap_s, page_alloc.RAM_END - heap_s, KERNEL_DATA);

    // MMIO — one page each, identity-mapped, S-only.
    mapPage(root_pa, 0x0010_0000, 0x0010_0000, KERNEL_MMIO); // Halt
    // CLINT spans 0x02000000..0x0200FFFF (64KB). One page is the mtime/
    // mtimecmp window; the kernel only touches that page in S-mode.
    // Future plans touching msip elsewhere in CLINT should extend this.
    mapPage(root_pa, 0x0200_0000, 0x0200_0000, KERNEL_MMIO);
    mapPage(root_pa, 0x0200_4000, 0x0200_4000, KERNEL_MMIO);
    // UART is one page.
    mapPage(root_pa, 0x1000_0000, 0x1000_0000, KERNEL_MMIO);
}

pub const USER_TEXT_VA: u32 = 0x0001_0000;
pub const USER_STACK_TOP: u32 = 0x0003_2000;
pub const USER_STACK_BOTTOM: u32 = 0x0003_0000;
pub const USER_STACK_PAGES: u32 = 2;

pub const RootPolicy = enum { leave_root, free_root };

/// Walk one L0 table and free every U-flagged leaf via the supplied callback.
/// Returns true iff at least one leaf was found (used by callers to decide
/// whether the L0 table itself is reclaimable).
///
/// Takes a pointer rather than a PA so the host test can pass a stack-
/// allocated table whose address might exceed u32 range. The production
/// caller (`unmapUser`) converts its u32 PA via `@ptrFromInt`.
pub fn freeLeavesInL0(
    table: *volatile [1024]u32,
    free_fn: *const fn (u32) void,
) bool {
    var any: bool = false;
    var i: u32 = 0;
    while (i < 1024) : (i += 1) {
        const v = table[i];
        if ((v & PTE_V) == 0) continue;
        if ((v & PTE_U) == 0) continue;
        const leaf_pa = ppnOfPte(v) << 12;
        free_fn(leaf_pa);
        table[i] = 0;
        any = true;
    }
    return any;
}

/// Tear down all user mappings under `pgdir`. Frees every U-flagged leaf
/// page, the L0 tables that hosted them, and (if `policy == .free_root`)
/// the L1 root itself. Kernel + MMIO leaves (which carry G=1 and lack
/// PTE_U) are left intact.
pub fn unmapUser(pgdir: u32, sz: u32, policy: RootPolicy) void {
    _ = sz; // 3.C walks every L1 entry; sz is only used as a hint by future plans.

    // Walk every L1 entry.
    var l1_idx: u32 = 0;
    while (l1_idx < 1024) : (l1_idx += 1) {
        const l1_e = ptePtr(pgdir, l1_idx);
        const l1_v = l1_e.*;
        if ((l1_v & PTE_V) == 0) continue;
        // Reject superpages (Plan 2 invariant — never written by mapPage).
        if ((l1_v & (PTE_R | PTE_W | PTE_X)) != 0) continue;

        const l0_pa = ppnOfPte(l1_v) << 12;

        // Determine if the L0 table backs ANY user mapping by walking it.
        // freeLeavesInL0 frees the user leaves and reports whether any
        // were freed. If yes, the L0 table itself is purely user-purpose
        // (kernel + MMIO live at non-overlapping L1 indexes), so we free
        // it too.
        const l0_table: *volatile [1024]u32 = @ptrFromInt(l0_pa);
        const had_user = freeLeavesInL0(l0_table, &page_alloc.free);
        if (had_user) {
            page_alloc.free(l0_pa);
            l1_e.* = 0;
        }
    }

    if (policy == .free_root) {
        page_alloc.free(pgdir);
    }
}

test "freeLeavesInL0 frees user leaves and skips kernel/MMIO leaves" {
    if (@import("builtin").os.tag != .freestanding) {
        const std = @import("std");

        var table: [1024]u32 align(PAGE_SIZE) = .{0} ** 1024;

        // makeLeaf preserves only the low 8 PTE bits (USER_RWX/KERNEL_DATA
        // don't include PTE_V), so OR it in here to mimic mapPage.
        // Slot 0: U leaf at PA 0x1000.
        table[0] = makeLeaf(0x1000, USER_RWX | PTE_V);
        // Slot 1: kernel leaf (G=1, no U) at PA 0x2000.
        table[1] = makeLeaf(0x2000, KERNEL_DATA | PTE_V);
        // Slot 2: invalid (V=0).
        table[2] = 0;
        // Slot 3: U leaf at PA 0x4000.
        table[3] = makeLeaf(0x4000, USER_RWX | PTE_V);

        const Recorder = struct {
            var freed: [16]u32 = undefined;
            var n: usize = 0;
            fn cb(pa: u32) void {
                freed[n] = pa;
                n += 1;
            }
        };
        Recorder.n = 0;

        const any = freeLeavesInL0(&table, &Recorder.cb);

        try std.testing.expect(any);
        try std.testing.expectEqual(@as(usize, 2), Recorder.n);
        try std.testing.expectEqual(@as(u32, 0x1000), Recorder.freed[0]);
        try std.testing.expectEqual(@as(u32, 0x4000), Recorder.freed[1]);
        // U slots are zeroed; kernel slot is preserved.
        try std.testing.expectEqual(@as(u32, 0), table[0]);
        try std.testing.expect(table[1] != 0);
        try std.testing.expectEqual(@as(u32, 0), table[3]);
    }
}

pub const CopyError = error{OutOfMemory};

/// Walk every user PTE in `src` from VA 0 up to `sz` (page-rounded up),
/// allocate a fresh frame in `dst`, copy 4 KB from src PA to dst PA, and
/// install at the same VA in `dst` with USER_RWX flags.
///
/// On any allocation failure: free every dst leaf already installed
/// (via unmapUser with .leave_root), and return error.OutOfMemory.
/// `dst`'s root is NOT freed by this function — caller owns root teardown.
pub fn copyUvm(src: u32, dst: u32, sz: u32) CopyError!void {
    const end_va = (sz + (PAGE_SIZE - 1)) & ~@as(u32, PAGE_SIZE - 1);
    var va: u32 = 0;
    while (va < end_va) : (va += PAGE_SIZE) {
        const src_pa = lookupPA(src, va) orelse continue;

        const dst_pa = page_alloc.alloc() orelse {
            // Rollback: free every leaf already installed in dst.
            unmapUser(dst, end_va, .leave_root);
            return CopyError.OutOfMemory;
        };

        // Direct copy via kernel-direct-mapped PA pointers.
        const src_ptr: [*]const volatile u8 = @ptrFromInt(src_pa);
        const dst_ptr: [*]volatile u8 = @ptrFromInt(dst_pa);
        var i: u32 = 0;
        while (i < PAGE_SIZE) : (i += 1) dst_ptr[i] = src_ptr[i];

        mapPage(dst, va, dst_pa, USER_RWX);
    }
}

/// Copy the 2-page user stack region from `src` to `dst`. Allocates two
/// fresh frames in `dst`, memcpys 4 KB each, installs as USER_RW at
/// USER_STACK_BOTTOM .. USER_STACK_BOTTOM + 8 KB.
///
/// On allocation failure, frees the (possibly partial) stack pages
/// already installed in `dst`. `dst`'s root is NOT freed.
pub fn copyUserStack(src: u32, dst: u32) CopyError!void {
    var i: u32 = 0;
    while (i < USER_STACK_PAGES) : (i += 1) {
        const va = USER_STACK_BOTTOM + i * PAGE_SIZE;
        const src_pa = lookupPA(src, va) orelse continue;

        const dst_pa = page_alloc.alloc() orelse {
            // Rollback only the user-stack range (leave the rest of dst
            // intact; copyUvm's caller may still want to use other pages).
            // We use unmapUser which is idempotent and only touches U leaves.
            unmapUser(dst, USER_STACK_TOP, .leave_root);
            return CopyError.OutOfMemory;
        };

        const src_ptr: [*]const volatile u8 = @ptrFromInt(src_pa);
        const dst_ptr: [*]volatile u8 = @ptrFromInt(dst_pa);
        var k: u32 = 0;
        while (k < PAGE_SIZE) : (k += 1) dst_ptr[k] = src_ptr[k];

        mapPage(dst, va, dst_pa, USER_RW);
    }
}

/// Allocate USER_STACK_PAGES (2) zeroed frames, map them at
/// USER_STACK_BOTTOM..USER_STACK_TOP with U+R+W. Returns false on OOM,
/// in which case partial mappings remain in pgdir (caller frees).
pub fn mapUserStack(root_pa: u32) bool {
    var s: u32 = 0;
    while (s < USER_STACK_PAGES) : (s += 1) {
        const stack_pa = page_alloc.alloc() orelse return false;
        const va = USER_STACK_BOTTOM + s * PAGE_SIZE;
        mapPage(root_pa, va, stack_pa, USER_RW);
    }
    return true;
}
