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

pub fn allocRoot() u32 {
    // A fresh Sv32 L1 table is just a zeroed 4KB page.
    return page_alloc.allocZeroPage();
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
