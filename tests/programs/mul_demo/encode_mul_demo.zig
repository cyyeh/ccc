const std = @import("std");
const Io = std.Io;

// Register aliases (RISC-V ABI numeric register names).
const ZERO: u5 = 0;
const T0: u5 = 5;
const T1: u5 = 6;
const T2: u5 = 7;
const T3: u5 = 28;
const T4: u5 = 29;
const T5: u5 = 30;
const T6: u5 = 31;

// === Encoders for the instructions we use ===

fn lui(rd: u5, imm20: u20) u32 {
    return (@as(u32, imm20) << 12) | (@as(u32, rd) << 7) | 0b0110111;
}

fn addi(rd: u5, rs1: u5, imm: i12) u32 {
    const imm_u: u32 = @bitCast(@as(i32, imm));
    return ((imm_u & 0xFFF) << 20) | (@as(u32, rs1) << 15) | (@as(u32, rd) << 7) | 0b0010011;
}

fn sb(rs1: u5, rs2: u5, imm: i12) u32 {
    const imm_u: u32 = @bitCast(@as(i32, imm));
    const imm_high: u32 = (imm_u >> 5) & 0x7F;
    const imm_low: u32 = imm_u & 0x1F;
    return (imm_high << 25) | (@as(u32, rs2) << 20) | (@as(u32, rs1) << 15) |
        (@as(u32, 0b000) << 12) | (imm_low << 7) | 0b0100011;
}

fn rType(rd: u5, rs1: u5, rs2: u5, funct3: u3, funct7: u7, opcode: u7) u32 {
    return (@as(u32, funct7) << 25) | (@as(u32, rs2) << 20) | (@as(u32, rs1) << 15) |
        (@as(u32, funct3) << 12) | (@as(u32, rd) << 7) | @as(u32, opcode);
}

fn mul(rd: u5, rs1: u5, rs2: u5) u32 {
    return rType(rd, rs1, rs2, 0b000, 0b0000001, 0b0110011);
}

fn divu(rd: u5, rs1: u5, rs2: u5) u32 {
    return rType(rd, rs1, rs2, 0b101, 0b0000001, 0b0110011);
}

fn remu(rd: u5, rs1: u5, rs2: u5) u32 {
    return rType(rd, rs1, rs2, 0b111, 0b0000001, 0b0110011);
}

fn amoswap_w(rd: u5, rs1: u5, rs2: u5) u32 {
    // funct5=00001, aq=0, rl=0 → funct7 = 0b0000100
    return rType(rd, rs1, rs2, 0b010, 0b0000100, 0b0101111);
}

fn fence_i() u32 {
    // opcode=0001111, funct3=001, rs1=0, rd=0, imm=0
    return (@as(u32, 0b001) << 12) | 0b0001111;
}

// === The program ===

const PROGRAM_BASE: u32 = 0x8000_0000;
const FLAG_OFFSET: u32 = 0x200; // scratch word in RAM, reserved for amoswap.w

fn buildProgram() [19]u32 {
    return .{
        // Setup: compute 6 * 7 = 42
        addi(T1, ZERO, 6),                 // t1 = 6
        addi(T2, ZERO, 7),                 // t2 = 7
        mul(T4, T1, T2),                   // t4 = 42
        // Flag address: t3 = RAM_BASE + FLAG_OFFSET
        lui(T3, 0x80000),                  // t3 = 0x80000000
        addi(T3, T3, @intCast(FLAG_OFFSET)), // t3 += 0x200
        // Atomically swap *t3 (initially 0) with t4 (42). t5 receives old value (= 0).
        amoswap_w(T5, T3, T4),             // t5 = *t3; *t3 = t4
        // Format 42 into two ASCII digits via divu/remu by 10.
        addi(T1, ZERO, 10),                // t1 = 10 (divisor)
        divu(T6, T4, T1),                  // t6 = 4 (tens digit)
        remu(T4, T4, T1),                  // t4 = 2 (ones digit)
        addi(T6, T6, 48),                  // t6 = '4'
        addi(T4, T4, 48),                  // t4 = '2'
        // A no-op instruction-fence before the output block — exercises Zifencei.
        fence_i(),                          // no-op on our emulator
        // Print "42\n" to UART.
        lui(T0, 0x10000),                  // t0 = UART base (0x10000000)
        sb(T0, T6, 0),                     // UART <- '4'
        sb(T0, T4, 0),                     // UART <- '2'
        addi(T1, ZERO, 10),                // t1 = 10 ('\n')
        sb(T0, T1, 0),                     // UART <- '\n'
        // Halt.
        lui(T0, 0x100),                    // t0 = 0x00100000 (halt MMIO)
        sb(T0, ZERO, 0),                   // *t0 = 0 → halt
    };
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

    const program = buildProgram();
    try w.writeAll(std.mem.sliceAsBytes(&program));

    // Pad out to FLAG_OFFSET so that RAM_BASE + FLAG_OFFSET is addressable
    // (the program pre-loads RAM with zeros for the flag slot implicitly via
    // Memory.init's @memset, but we still want the binary to be long enough
    // that the loader writes a defined zero into that slot — belt and braces).
    const code_size: u32 = @intCast(program.len * 4);
    if (FLAG_OFFSET + 4 <= code_size) @panic("program overlaps flag slot");
    try w.splatByteAll(0, FLAG_OFFSET + 4 - code_size);

    try w.flush();
}
