const std = @import("std");
const Io = std.Io;

// Register aliases (RISC-V ABI numeric register names).
const ZERO: u5 = 0;
const T0: u5 = 5;
const T1: u5 = 6;
const T2: u5 = 7;
const A0: u5 = 10;

// CSR addresses (match src/csr.zig).
const CSR_MSTATUS: u12 = 0x300;
const CSR_MTVEC: u12 = 0x305;
const CSR_MEPC: u12 = 0x341;
const CSR_MCAUSE: u12 = 0x342;

// === Encoders for the instructions we use ===

fn lui(rd: u5, imm20: u20) u32 {
    return (@as(u32, imm20) << 12) | (@as(u32, rd) << 7) | 0b0110111;
}

fn addi(rd: u5, rs1: u5, imm: i12) u32 {
    const imm_u: u32 = @bitCast(@as(i32, imm));
    return ((imm_u & 0xFFF) << 20) | (@as(u32, rs1) << 15) | (@as(u32, rd) << 7) | 0b0010011;
}

fn lbu(rd: u5, rs1: u5, imm: i12) u32 {
    const imm_u: u32 = @bitCast(@as(i32, imm));
    return ((imm_u & 0xFFF) << 20) | (@as(u32, rs1) << 15) |
        (@as(u32, 0b100) << 12) | (@as(u32, rd) << 7) | 0b0000011;
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

fn csrrw(rd: u5, rs1: u5, csr: u12) u32 {
    return (@as(u32, csr) << 20) | (@as(u32, rs1) << 15) |
        (@as(u32, 0b001) << 12) | (@as(u32, rd) << 7) | 0b1110011;
}

fn csrrs(rd: u5, rs1: u5, csr: u12) u32 {
    return (@as(u32, csr) << 20) | (@as(u32, rs1) << 15) |
        (@as(u32, 0b010) << 12) | (@as(u32, rd) << 7) | 0b1110011;
}

// ecall: 0x00000073
const ECALL: u32 = 0x0000_0073;
// mret: 0x30200073 (imm12=0x302, funct3=000, opcode=0x73)
const MRET: u32 = 0x3020_0073;
// nop: addi x0, x0, 0 → 0x00000013
const NOP: u32 = 0x0000_0013;

// === The program ===

const PROGRAM_BASE: u32 = 0x8000_0000;
const HANDLER_OFFSET: u32 = 0x100;
const U_ENTRY_OFFSET: u32 = 0x200;
const STRING_OFFSET: u32 = 0x300;
const MSG = "trap ok\n";

// Append a single instruction word.
fn emit(list: *std.ArrayList(u32), allocator: std.mem.Allocator, w: u32) !void {
    try list.append(allocator, w);
}

// Pad `list` with NOPs until it reaches `target_bytes / 4` words.
fn padTo(list: *std.ArrayList(u32), allocator: std.mem.Allocator, target_bytes: u32) !void {
    const target_words = target_bytes / 4;
    while (list.items.len < target_words) {
        try list.append(allocator, NOP);
    }
    if (list.items.len > target_words) {
        @panic("section overflow — too many instructions before pad target");
    }
}

fn buildProgram(allocator: std.mem.Allocator) !std.ArrayList(u32) {
    var words: std.ArrayList(u32) = .empty;

    // === Section 0: M-mode entry (0x000) ===
    // Compute handler address in t0 and install it in mtvec.
    try emit(&words, allocator, lui(T0, 0x80000));                 // t0 = 0x80000000
    try emit(&words, allocator, addi(T0, T0, @intCast(HANDLER_OFFSET))); // t0 += 0x100
    try emit(&words, allocator, csrrw(ZERO, T0, CSR_MTVEC));       // mtvec = t0

    // Set mstatus = 0 (MPP = 0b00 = U, MIE = 0, MPIE = 0).
    try emit(&words, allocator, addi(T0, ZERO, 0));                // t0 = 0
    try emit(&words, allocator, csrrw(ZERO, T0, CSR_MSTATUS));     // mstatus = 0

    // Compute U-mode entry address in t0 and install it in mepc.
    try emit(&words, allocator, lui(T0, 0x80000));                 // t0 = 0x80000000
    try emit(&words, allocator, addi(T0, T0, @intCast(U_ENTRY_OFFSET))); // t0 += 0x200
    try emit(&words, allocator, csrrw(ZERO, T0, CSR_MEPC));        // mepc = t0

    // Switch to U-mode and jump to mepc.
    try emit(&words, allocator, MRET);

    // === Section 1: M-mode trap handler (0x100) ===
    try padTo(&words, allocator, HANDLER_OFFSET);

    // Read mcause into t0 (demonstrates CSR read from trap handler).
    try emit(&words, allocator, csrrs(T0, ZERO, CSR_MCAUSE));      // t0 = mcause

    // t1 = UART THR base (0x10000000).
    try emit(&words, allocator, lui(T1, 0x10000));                 // t1 = 0x10000000

    // t2 = string base (0x80000300).
    try emit(&words, allocator, lui(T2, 0x80000));                 // t2 = 0x80000000
    try emit(&words, allocator, addi(T2, T2, @intCast(STRING_OFFSET))); // t2 += 0x300

    // Print loop:
    //   loop_start:
    //     lbu  a0, 0(t2)
    //     beq  a0, zero, +16   ; if null byte, jump past the loop body to halt
    //     sb   a0, 0(t1)       ; UART THR <- a0
    //     addi t2, t2, 1
    //     jal  zero, -16       ; back to loop_start
    //   halt:
    //     lui  t0, 0x100
    //     sb   zero, 0(t0)
    try emit(&words, allocator, lbu(A0, T2, 0));                   // a0 = *t2
    try emit(&words, allocator, beq(A0, ZERO, 16));                // if a0==0, jump to halt (+16 from beq)
    try emit(&words, allocator, sb(T1, A0, 0));                    // *t1 = a0 (UART)
    try emit(&words, allocator, addi(T2, T2, 1));                  // t2++
    try emit(&words, allocator, jal(ZERO, -16));                   // loop back to lbu

    try emit(&words, allocator, lui(T0, 0x100));                   // t0 = 0x00100000 (halt MMIO)
    try emit(&words, allocator, sb(T0, ZERO, 0));                  // *t0 = 0 → halt

    // === Section 2: U-mode entry (0x200) ===
    try padTo(&words, allocator, U_ENTRY_OFFSET);
    try emit(&words, allocator, ECALL);

    return words;
}

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

    var file = try Io.Dir.cwd().createFile(io, argv[1], .{});
    defer file.close(io);

    var out_buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &out_buffer);
    const w = &file_writer.interface;

    var program = try buildProgram(a);
    defer program.deinit(a);

    try w.writeAll(std.mem.sliceAsBytes(program.items));

    // Pad between the last emitted word (U-mode ecall) and the string.
    const code_size: u32 = @intCast(program.items.len * 4);
    if (STRING_OFFSET < code_size) @panic("program overflowed into string area");
    try w.splatByteAll(0, STRING_OFFSET - code_size);

    try w.writeAll(MSG);
    try w.writeByte(0);

    try w.flush();
}
