const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.gpa;

    const argv = try init.minimal.args.toSlice(a);
    defer a.free(argv);

    var stderr_buffer: [256]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    if (argv.len != 2) {
        stderr.print("usage: {s} <output-path>\n", .{argv[0]}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    }

    const out_path = argv[1];

    var buf: [512]u8 = undefined;
    @memset(&buf, 0);

    // ELF header (52 bytes)
    buf[0..4].* = "\x7FELF".*;
    buf[4] = 1; // ELFCLASS32
    buf[5] = 1; // ELFDATA2LSB
    buf[6] = 1; // EI_VERSION
    std.mem.writeInt(u16, buf[16..18], 2, .little); // e_type = ET_EXEC
    std.mem.writeInt(u16, buf[18..20], 0xF3, .little); // e_machine = EM_RISCV
    std.mem.writeInt(u32, buf[20..24], 1, .little); // e_version
    std.mem.writeInt(u32, buf[24..28], 0x8000_0000, .little); // e_entry
    std.mem.writeInt(u32, buf[28..32], 52, .little); // e_phoff
    std.mem.writeInt(u32, buf[32..36], 140, .little); // e_shoff
    std.mem.writeInt(u16, buf[40..42], 52, .little); // e_ehsize
    std.mem.writeInt(u16, buf[42..44], 32, .little); // e_phentsize
    std.mem.writeInt(u16, buf[44..46], 1, .little); // e_phnum
    std.mem.writeInt(u16, buf[46..48], 40, .little); // e_shentsize
    std.mem.writeInt(u16, buf[48..50], 4, .little); // e_shnum
    std.mem.writeInt(u16, buf[50..52], 0, .little); // e_shstrndx

    // Program header at 52 (32 bytes)
    const ph = buf[52..84];
    std.mem.writeInt(u32, ph[0..4], 1, .little); // p_type = PT_LOAD
    std.mem.writeInt(u32, ph[4..8], 84, .little); // p_offset = 84
    std.mem.writeInt(u32, ph[8..12], 0x8000_0000, .little); // p_vaddr
    std.mem.writeInt(u32, ph[12..16], 0x8000_0000, .little); // p_paddr
    std.mem.writeInt(u32, ph[16..20], 4, .little); // p_filesz
    std.mem.writeInt(u32, ph[20..24], 4, .little); // p_memsz
    std.mem.writeInt(u32, ph[24..28], 5, .little); // p_flags
    std.mem.writeInt(u32, ph[28..32], 4, .little); // p_align

    // Text at 84: ECALL = 0x00000073
    std.mem.writeInt(u32, buf[84..88], 0x00000073, .little);

    // .symtab at 88-119 (2 entries × 16 bytes): entry 0 null, entry 1 tohost
    const sym1 = buf[88 + 16 .. 88 + 32];
    std.mem.writeInt(u32, sym1[0..4], 1, .little); // st_name = offset 1 in strtab
    std.mem.writeInt(u32, sym1[4..8], 0x8000_1000, .little); // st_value
    std.mem.writeInt(u32, sym1[8..12], 8, .little); // st_size
    sym1[12] = 0x11; // st_info = GLOBAL OBJECT
    sym1[13] = 0;
    std.mem.writeInt(u16, sym1[14..16], 1, .little); // st_shndx

    // .strtab at 120: "\0tohost\0"
    buf[120] = 0;
    buf[121] = 't';
    buf[122] = 'o';
    buf[123] = 'h';
    buf[124] = 'o';
    buf[125] = 's';
    buf[126] = 't';
    buf[127] = 0;

    // Section headers at 140: 4 × 40 = 160 bytes → total file = 300
    // Section 0: null header (already zero-filled).
    // Section 1: .text (SHT_PROGBITS) at shoff 140+40.
    const sh1 = buf[140 + 40 .. 140 + 80];
    std.mem.writeInt(u32, sh1[4..8], 1, .little); // SHT_PROGBITS
    std.mem.writeInt(u32, sh1[12..16], 0x8000_0000, .little); // sh_addr
    std.mem.writeInt(u32, sh1[16..20], 84, .little); // sh_offset
    std.mem.writeInt(u32, sh1[20..24], 4, .little); // sh_size

    // Section 2: .symtab (SHT_SYMTAB) at shoff 140+80.
    const sh2 = buf[140 + 80 .. 140 + 120];
    std.mem.writeInt(u32, sh2[4..8], 2, .little); // SHT_SYMTAB
    std.mem.writeInt(u32, sh2[16..20], 88, .little); // sh_offset
    std.mem.writeInt(u32, sh2[20..24], 32, .little); // sh_size
    std.mem.writeInt(u32, sh2[24..28], 3, .little); // sh_link → entry 3
    std.mem.writeInt(u32, sh2[36..40], 16, .little); // sh_entsize

    // Section 3: .strtab (SHT_STRTAB) at shoff 140+120.
    const sh3 = buf[140 + 120 .. 140 + 160];
    std.mem.writeInt(u32, sh3[4..8], 3, .little); // SHT_STRTAB
    std.mem.writeInt(u32, sh3[16..20], 120, .little); // sh_offset
    std.mem.writeInt(u32, sh3[20..24], 8, .little); // sh_size

    const total: usize = 300;

    var file = try Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);

    var out_buffer: [512]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &out_buffer);
    const w = &file_writer.interface;
    try w.writeAll(buf[0..total]);
    try w.flush();
}
