// src/kernel/elfload.zig — kernel-side ELF32 loader.
//
// Phase 3.B: parse an ELF32 RISC-V EXEC blob, walk PT_LOAD program
// headers, and for each segment allocate physical frames and install
// user PTEs at the segment's p_vaddr. Returns the entry PC (e_entry).
//
// All Phase 3.B segments map with USER_RWX. Plan 3.E will refine to
// per-segment R/W/X based on p_flags.

const std = @import("std");

pub const ElfError = error{
    BadMagic,
    NotElf32,
    NotLittleEndian,
    NotRiscV,
    NotExecutable,
    SegmentOutOfRange,
    OutOfMemory,
};

const EI_CLASS = 4;
const EI_DATA = 5;
const ELFCLASS32: u8 = 1;
const ELFDATA2LSB: u8 = 1;
const EM_RISCV: u16 = 0xF3;
const ET_EXEC: u16 = 2;
const PT_LOAD: u32 = 1;

pub const PageAllocFn = *const fn () ?u32;
pub const MapFn = *const fn (pgdir: u32, va: u32, pa: u32, flags: u32) void;
/// Look up an already-mapped PA for `va` in `pgdir`. Returns null if unmapped.
pub const LookupFn = *const fn (pgdir: u32, va: u32) ?u32;

pub fn parse(blob: []const u8) ElfError!struct { entry: u32, ph_off: u32, ph_num: u16, ph_entsize: u16 } {
    if (blob.len < 52) return ElfError.BadMagic;
    if (!std.mem.eql(u8, blob[0..4], "\x7FELF")) return ElfError.BadMagic;
    if (blob[EI_CLASS] != ELFCLASS32) return ElfError.NotElf32;
    if (blob[EI_DATA] != ELFDATA2LSB) return ElfError.NotLittleEndian;
    const e_type = std.mem.readInt(u16, blob[16..18], .little);
    if (e_type != ET_EXEC) return ElfError.NotExecutable;
    const e_machine = std.mem.readInt(u16, blob[18..20], .little);
    if (e_machine != EM_RISCV) return ElfError.NotRiscV;
    return .{
        .entry = std.mem.readInt(u32, blob[24..28], .little),
        .ph_off = std.mem.readInt(u32, blob[28..32], .little),
        .ph_num = std.mem.readInt(u16, blob[44..46], .little),
        .ph_entsize = std.mem.readInt(u16, blob[42..44], .little),
    };
}

pub fn load(blob: []const u8, pgdir: u32, alloc_fn: PageAllocFn, map_fn: MapFn, lookup_fn: LookupFn, user_flags: u32) ElfError!u32 {
    const hdr = try parse(blob);

    var i: u32 = 0;
    while (i < hdr.ph_num) : (i += 1) {
        const off = hdr.ph_off + i * hdr.ph_entsize;
        if (off + 32 > blob.len) return ElfError.SegmentOutOfRange;
        const p_type = std.mem.readInt(u32, blob[off..][0..4], .little);
        if (p_type != PT_LOAD) continue;

        const p_offset = std.mem.readInt(u32, blob[off + 4 ..][0..4], .little);
        const p_vaddr = std.mem.readInt(u32, blob[off + 8 ..][0..4], .little);
        const p_filesz = std.mem.readInt(u32, blob[off + 16 ..][0..4], .little);
        const p_memsz = std.mem.readInt(u32, blob[off + 20 ..][0..4], .little);

        if (@as(usize, p_offset) + @as(usize, p_filesz) > blob.len) return ElfError.SegmentOutOfRange;

        const PAGE_SIZE: u32 = 4096;
        const va_start: u32 = p_vaddr & ~@as(u32, PAGE_SIZE - 1);
        const va_end: u32 = (p_vaddr + p_memsz + PAGE_SIZE - 1) & ~@as(u32, PAGE_SIZE - 1);
        if (va_end < va_start) return ElfError.SegmentOutOfRange;

        var va = va_start;
        while (va < va_end) : (va += PAGE_SIZE) {
            // If a prior PT_LOAD segment already allocated+mapped this page
            // (two segments sharing a 4 KB page), reuse the existing frame.
            const pa = if (lookup_fn(pgdir, va)) |existing_pa|
                existing_pa
            else blk: {
                const new_pa = alloc_fn() orelse return ElfError.OutOfMemory;
                map_fn(pgdir, va, new_pa, user_flags);
                break :blk new_pa;
            };

            // NOTE(Phase 3.E): shared-page reuse skips map_fn for the second
            // segment, so its p_flags are silently ignored here. Phase 3.E must
            // OR the desired flags onto the existing PTE instead of skipping.
            // Copy bytes that fall in this page from the blob.
            const seg_lo = if (va < p_vaddr) p_vaddr else va;
            const seg_hi = @min(va + PAGE_SIZE, p_vaddr + p_filesz);
            if (seg_hi > seg_lo) {
                const dst: [*]volatile u8 = @ptrFromInt(pa + (seg_lo - va));
                const src_off = p_offset + (seg_lo - p_vaddr);
                var k: u32 = 0;
                while (k < seg_hi - seg_lo) : (k += 1) dst[k] = blob[src_off + k];
            }
            // Tail (seg's [filesz, memsz) within this page) stays zero
            // because alloc_fn returns zeroed pages.
        }
    }

    return hdr.entry;
}

test "parse rejects empty blob" {
    if (@import("builtin").os.tag != .freestanding) {
        const empty: []const u8 = &.{};
        try std.testing.expectError(ElfError.BadMagic, parse(empty));
    }
}

test "parse rejects bad magic" {
    if (@import("builtin").os.tag != .freestanding) {
        var bogus: [64]u8 = .{0} ** 64;
        bogus[0] = 'X';
        try std.testing.expectError(ElfError.BadMagic, parse(&bogus));
    }
}

test "parse accepts the minimal.elf fixture" {
    if (@import("builtin").os.tag != .freestanding) {
        const fixture = @import("minimal_elf_fixture").bytes;
        const hdr = try parse(fixture);
        try std.testing.expect(hdr.entry != 0);
        try std.testing.expect(hdr.ph_num >= 1);
    }
}
