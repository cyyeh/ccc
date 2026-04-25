const std = @import("std");
const Memory = @import("memory.zig").Memory;

pub const ElfError = error{
    FileTooSmall,
    BadMagic,
    NotElf32,
    NotLittleEndian,
    NotRiscV,
    NotExecutable,
    SegmentOutOfRange,
    InvalidSectionTable,
};

pub const LoadResult = struct {
    entry: u32,
    tohost_addr: ?u32,
};

const EI_CLASS = 4;
const EI_DATA = 5;
const ELFCLASS32: u8 = 1;
const ELFDATA2LSB: u8 = 1;
const EM_RISCV: u16 = 0xF3;
const ET_EXEC: u16 = 2;
const PT_LOAD: u32 = 1;
const SHT_SYMTAB: u32 = 2;
const SHT_STRTAB: u32 = 3;

pub fn parseAndLoad(data: []const u8, memory: *Memory) ElfError!LoadResult {
    if (data.len < 52) return ElfError.FileTooSmall;

    if (!std.mem.eql(u8, data[0..4], "\x7FELF")) return ElfError.BadMagic;
    if (data[EI_CLASS] != ELFCLASS32) return ElfError.NotElf32;
    if (data[EI_DATA] != ELFDATA2LSB) return ElfError.NotLittleEndian;

    const e_type = std.mem.readInt(u16, data[16..18], .little);
    if (e_type != ET_EXEC) return ElfError.NotExecutable;
    const e_machine = std.mem.readInt(u16, data[18..20], .little);
    if (e_machine != EM_RISCV) return ElfError.NotRiscV;

    const e_entry = std.mem.readInt(u32, data[24..28], .little);
    const e_phoff = std.mem.readInt(u32, data[28..32], .little);
    const e_shoff = std.mem.readInt(u32, data[32..36], .little);
    const e_phentsize = std.mem.readInt(u16, data[42..44], .little);
    const e_phnum = std.mem.readInt(u16, data[44..46], .little);
    const e_shentsize = std.mem.readInt(u16, data[46..48], .little);
    const e_shnum = std.mem.readInt(u16, data[48..50], .little);

    // Copy PT_LOAD segments
    var ph_i: usize = 0;
    while (ph_i < e_phnum) : (ph_i += 1) {
        const off = e_phoff + ph_i * e_phentsize;
        if (off + 32 > data.len) return ElfError.SegmentOutOfRange;
        const p_type = std.mem.readInt(u32, data[off..][0..4], .little);
        if (p_type != PT_LOAD) continue;

        const p_offset = std.mem.readInt(u32, data[off + 4 ..][0..4], .little);
        const p_paddr = std.mem.readInt(u32, data[off + 12 ..][0..4], .little);
        const p_filesz = std.mem.readInt(u32, data[off + 16 ..][0..4], .little);
        const p_memsz = std.mem.readInt(u32, data[off + 20 ..][0..4], .little);

        if (p_offset + p_filesz > data.len) return ElfError.SegmentOutOfRange;

        var j: u32 = 0;
        while (j < p_filesz) : (j += 1) {
            memory.storeBytePhysical(p_paddr + j, data[p_offset + j]) catch return ElfError.SegmentOutOfRange;
        }
        while (j < p_memsz) : (j += 1) {
            memory.storeBytePhysical(p_paddr + j, 0) catch return ElfError.SegmentOutOfRange;
        }
    }

    // Find tohost via symbol table
    var tohost_addr: ?u32 = null;
    if (e_shnum > 0 and e_shoff != 0) {
        var symtab_off: u32 = 0;
        var symtab_size: u32 = 0;
        var symtab_link: u32 = 0;
        var sh_i: usize = 0;
        while (sh_i < e_shnum) : (sh_i += 1) {
            const shoff = e_shoff + sh_i * e_shentsize;
            if (shoff + 40 > data.len) return ElfError.InvalidSectionTable;
            const sh_type = std.mem.readInt(u32, data[shoff + 4 ..][0..4], .little);
            if (sh_type != SHT_SYMTAB) continue;
            symtab_off = std.mem.readInt(u32, data[shoff + 16 ..][0..4], .little);
            symtab_size = std.mem.readInt(u32, data[shoff + 20 ..][0..4], .little);
            symtab_link = std.mem.readInt(u32, data[shoff + 24 ..][0..4], .little);
            break;
        }
        if (symtab_size > 0) {
            const strtab_shoff = e_shoff + symtab_link * e_shentsize;
            if (strtab_shoff + 40 > data.len) return ElfError.InvalidSectionTable;
            const strtab_off = std.mem.readInt(u32, data[strtab_shoff + 16 ..][0..4], .little);
            const strtab_size = std.mem.readInt(u32, data[strtab_shoff + 20 ..][0..4], .little);
            if (strtab_off + strtab_size > data.len) return ElfError.InvalidSectionTable;

            const SYMSIZE: u32 = 16;
            var sym_i: u32 = 0;
            while (sym_i < symtab_size) : (sym_i += SYMSIZE) {
                const e_off = symtab_off + sym_i;
                if (e_off + SYMSIZE > data.len) break;
                const st_name = std.mem.readInt(u32, data[e_off..][0..4], .little);
                const st_value = std.mem.readInt(u32, data[e_off + 4 ..][0..4], .little);
                const name_start = strtab_off + st_name;
                if (name_start >= data.len) continue;
                var end = name_start;
                while (end < data.len and data[end] != 0) : (end += 1) {}
                const name = data[name_start..end];
                if (std.mem.eql(u8, name, "tohost")) {
                    tohost_addr = st_value;
                    break;
                }
            }
        }
    }

    return .{ .entry = e_entry, .tohost_addr = tohost_addr };
}

test "reject files smaller than an ELF header" {
    var halt = @import("devices/halt.zig").Halt.init();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var uart = @import("devices/uart.zig").Uart.init(&aw.writer);
    var clint = @import("devices/clint.zig").Clint.init(&@import("devices/clint.zig").zeroClock);
    var plic = @import("devices/plic.zig").Plic.init();
    var block = @import("devices/block.zig").Block.init();
    var mem = try Memory.init(std.testing.allocator, &halt, &uart, &clint, &plic, &block, std.testing.io, null, 1024);
    defer mem.deinit();
    try std.testing.expectError(ElfError.FileTooSmall, parseAndLoad(&[_]u8{0}, &mem));
}

test "reject wrong magic" {
    var halt = @import("devices/halt.zig").Halt.init();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var uart = @import("devices/uart.zig").Uart.init(&aw.writer);
    var clint = @import("devices/clint.zig").Clint.init(&@import("devices/clint.zig").zeroClock);
    var plic = @import("devices/plic.zig").Plic.init();
    var block = @import("devices/block.zig").Block.init();
    var mem = try Memory.init(std.testing.allocator, &halt, &uart, &clint, &plic, &block, std.testing.io, null, 1024);
    defer mem.deinit();
    var bogus = [_]u8{0} ** 64;
    bogus[0] = 'Z';
    bogus[1] = 'O';
    bogus[2] = 'M';
    bogus[3] = 'G';
    try std.testing.expectError(ElfError.BadMagic, parseAndLoad(&bogus, &mem));
}

test "load minimal.elf fixture, extract entry and tohost" {
    const fixture = @import("minimal_elf_fixture").bytes;
    var halt = @import("devices/halt.zig").Halt.init();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var uart = @import("devices/uart.zig").Uart.init(&aw.writer);
    var clint = @import("devices/clint.zig").Clint.init(&@import("devices/clint.zig").zeroClock);
    var plic = @import("devices/plic.zig").Plic.init();
    var block = @import("devices/block.zig").Block.init();
    const mem_mod = @import("memory.zig");
    var mem = try Memory.init(std.testing.allocator, &halt, &uart, &clint, &plic, &block, std.testing.io, null, mem_mod.RAM_SIZE_DEFAULT);
    defer mem.deinit();
    const result = try parseAndLoad(fixture, &mem);
    try std.testing.expectEqual(mem_mod.RAM_BASE, result.entry);
    try std.testing.expect(result.tohost_addr != null);
    try std.testing.expectEqual(@as(u32, 0x8000_1000), result.tohost_addr.?);
    try std.testing.expectEqual(@as(u8, 0x73), try mem.loadBytePhysical(mem_mod.RAM_BASE));
}
