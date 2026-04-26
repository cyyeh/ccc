const std = @import("std");
const Io = std.Io;

// Register aliases (RISC-V ABI numeric register names).
const ZERO: u5 = 0;
const T0: u5 = 5;
const T1: u5 = 6;
const T2: u5 = 7;
const T3: u5 = 28;

// === Encoders for the instructions we use ===

fn lui(rd: u5, imm20: u20) u32 {
    return (@as(u32, imm20) << 12) | (@as(u32, rd) << 7) | 0b0110111;
}

fn addi(rd: u5, rs1: u5, imm: i12) u32 {
    const imm_u: u32 = @bitCast(@as(i32, imm));
    return ((imm_u & 0xFFF) << 20) | (@as(u32, rs1) << 15) | (@as(u32, rd) << 7) | 0b0010011;
}

fn lb(rd: u5, rs1: u5, imm: i12) u32 {
    const imm_u: u32 = @bitCast(@as(i32, imm));
    return ((imm_u & 0xFFF) << 20) | (@as(u32, rs1) << 15) |
        (@as(u32, 0b000) << 12) | (@as(u32, rd) << 7) | 0b0000011;
}

fn sb(rs1: u5, rs2: u5, imm: i12) u32 {
    const imm_u: u32 = @bitCast(@as(i32, imm));
    const imm_high: u32 = (imm_u >> 5) & 0x7F;
    const imm_low: u32 = imm_u & 0x1F;
    return (imm_high << 25) | (@as(u32, rs2) << 20) | (@as(u32, rs1) << 15) |
        (@as(u32, 0b000) << 12) | (imm_low << 7) | 0b0100011;
}

fn beq(rs1: u5, rs2: u5, offset: i13) u32 {
    const o: u32 = @bitCast(@as(i32, offset));
    const imm12: u32 = (o >> 12) & 1;
    const imm10_5: u32 = (o >> 5) & 0x3F;
    const imm4_1: u32 = (o >> 1) & 0xF;
    const imm11: u32 = (o >> 11) & 1;
    return (imm12 << 31) | (imm10_5 << 25) | (@as(u32, rs2) << 20) |
        (@as(u32, rs1) << 15) | (@as(u32, 0b000) << 12) | (imm4_1 << 8) |
        (imm11 << 7) | 0b1100011;
}

fn jal(rd: u5, offset: i21) u32 {
    const o: u32 = @bitCast(@as(i32, offset));
    const imm20: u32 = (o >> 20) & 1;
    const imm10_1: u32 = (o >> 1) & 0x3FF;
    const imm11: u32 = (o >> 11) & 1;
    const imm19_12: u32 = (o >> 12) & 0xFF;
    return (imm20 << 31) | (imm10_1 << 21) | (imm11 << 20) |
        (imm19_12 << 12) | (@as(u32, rd) << 7) | 0b1101111;
}

// === The program ===

const PROGRAM_BASE: u32 = 0x8000_0000;
const STRING_OFFSET: u32 = 0x100;
const HELLO = "hello world\n";

fn buildProgram() [10]u32 {
    return .{
        // Setup
        lui(T0, 0x10000), // t0 = 0x10000000 (UART)
        lui(T1, 0x80000), // t1 = 0x80000000 (RAM base)
        addi(T1, T1, @intCast(STRING_OFFSET)), // t1 += STRING_OFFSET
        // Loop:
        lb(T2, T1, 0), // t2 = *t1
        beq(T2, ZERO, 0x10), // if t2 == 0, jump to halt (+16)
        sb(T0, T2, 0), // *t0 = t2 (UART)
        addi(T1, T1, 1), // t1++
        jal(ZERO, -16), // jump back to loop
        // Halt:
        lui(T3, 0x100), // t3 = 0x00100000 (halt MMIO)
        sb(T3, ZERO, 0), // *t3 = 0 (halt)
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.gpa;

    const argv = try init.minimal.args.toSlice(a);
    defer a.free(argv);

    // stderr writer for usage.
    var stderr_buffer: [256]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    if (argv.len != 2) {
        stderr.print("usage: {s} <output-path>\n", .{argv[0]}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    }

    var file = try Io.Dir.cwd().createFile(io, argv[1], .{});
    defer file.close(io);

    var out_buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &out_buffer);
    const w = &file_writer.interface;

    const program = buildProgram();
    try w.writeAll(std.mem.sliceAsBytes(&program));

    const code_size: u32 = @intCast(program.len * 4);
    if (STRING_OFFSET < code_size) @panic("program too long");
    try w.splatByteAll(0, STRING_OFFSET - code_size);

    try w.writeAll(HELLO);
    try w.writeByte(0);

    try w.flush();
}
