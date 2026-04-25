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

/// Map the user program: copy each 4 KB chunk of `blob` into a fresh
/// physical frame, install a U+R+W+X leaf PTE at VA 0x0001_0000 + k*4K.
/// Then allocate 2 stack pages mapped at VA 0x0003_0000 + {0, 4K}
/// with U+R+W (no X). The user's sp is initialized to USER_STACK_TOP
/// by kmain before sret.
pub fn mapUser(root_pa: u32, blob_ptr: [*]const u8, blob_len: u32) void {
    // Round up blob length to PAGE_SIZE for allocation purposes.
    const page_count: u32 = (blob_len + (PAGE_SIZE - 1)) >> PAGE_SHIFT;
    var i: u32 = 0;
    while (i < page_count) : (i += 1) {
        const user_pa = page_alloc.allocZeroPage();
        // Copy up to PAGE_SIZE bytes from blob[i*PAGE_SIZE..] into this frame.
        const src_off = i * PAGE_SIZE;
        const remaining = if (blob_len > src_off) blob_len - src_off else 0;
        const copy_len = @min(remaining, PAGE_SIZE);
        const dst: [*]volatile u8 = @ptrFromInt(user_pa);
        var j: u32 = 0;
        while (j < copy_len) : (j += 1) dst[j] = blob_ptr[src_off + j];

        const va = USER_TEXT_VA + i * PAGE_SIZE;
        mapPage(root_pa, va, user_pa, USER_RWX);
    }

    // User stack: 2 pages, U+R+W, zero-initialized (already zero from
    // allocZeroPage).
    var s: u32 = 0;
    while (s < USER_STACK_PAGES) : (s += 1) {
        const stack_pa = page_alloc.allocZeroPage();
        const va = USER_STACK_BOTTOM + s * PAGE_SIZE;
        mapPage(root_pa, va, stack_pa, USER_RW);
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
