const std = @import("std");

pub const Op = enum {
    // RV32I — base integer (Plan 1.A)
    lui,
    auipc,
    jal,
    jalr,
    beq,
    bne,
    blt,
    bge,
    bltu,
    bgeu,
    lb,
    lh,
    lw,
    lbu,
    lhu,
    sb,
    sh,
    sw,
    addi,
    slti,
    sltiu,
    xori,
    ori,
    andi,
    slli,
    srli,
    srai,
    add,
    sub,
    sll,
    slt,
    sltu,
    xor_,
    srl,
    sra,
    or_,
    and_,
    fence,
    ecall,
    ebreak,
    // RV32M — multiply/divide (Plan 1.B, Task 2)
    mul,
    mulh,
    mulhsu,
    mulhu,
    div,
    divu,
    rem,
    remu,
    // Zifencei (Plan 1.B, Task 5)
    fence_i,
    // RV32A — atomics (Plan 1.B, Task 6)
    lr_w,
    sc_w,
    amoswap_w,
    amoadd_w,
    amoxor_w,
    amoand_w,
    amoor_w,
    amomin_w,
    amomax_w,
    amominu_w,
    amomaxu_w,
    // (more added in later plans)
    illegal,
};

pub const Instruction = struct {
    op: Op,
    rd: u5 = 0,
    rs1: u5 = 0,
    rs2: u5 = 0,
    imm: i32 = 0,
    raw: u32 = 0,
};

// Bitfield helpers
pub fn opcode(word: u32) u7 {
    return @truncate(word & 0x7F);
}

pub fn rd(word: u32) u5 {
    return @truncate((word >> 7) & 0x1F);
}

pub fn rs1(word: u32) u5 {
    return @truncate((word >> 15) & 0x1F);
}

pub fn rs2(word: u32) u5 {
    return @truncate((word >> 20) & 0x1F);
}

pub fn funct3(word: u32) u3 {
    return @truncate((word >> 12) & 0x7);
}

pub fn funct7(word: u32) u7 {
    return @truncate((word >> 25) & 0x7F);
}

// U-type immediate: bits 31:12 → upper 20 bits of result, lower 12 are zero.
pub fn immU(word: u32) i32 {
    return @bitCast(word & 0xFFFF_F000);
}

// I-type immediate: bits 31:20 sign-extended.
pub fn immI(word: u32) i32 {
    const raw: u32 = (word >> 20) & 0xFFF;
    // Sign-extend bit 11 of raw to 32 bits.
    return @as(i32, @intCast(@as(i12, @bitCast(@as(u12, @truncate(raw))))));
}

// B-type immediate: bits 31|7|30:25|11:8, multiplied by 2 implicitly.
pub fn immB(word: u32) i32 {
    const imm12: u32 = (word >> 31) & 0x1;
    const imm10_5: u32 = (word >> 25) & 0x3F;
    const imm4_1: u32 = (word >> 8) & 0xF;
    const imm11: u32 = (word >> 7) & 0x1;
    const unsigned: u32 =
        (imm12 << 12) |
        (imm11 << 11) |
        (imm10_5 << 5) |
        (imm4_1 << 1);
    if (imm12 == 1) {
        return @bitCast(unsigned | 0xFFFF_E000);
    }
    return @bitCast(unsigned);
}

// S-type immediate: bits 31:25 || 11:7 sign-extended.
pub fn immS(word: u32) i32 {
    const high: u32 = (word >> 25) & 0x7F;
    const low: u32 = (word >> 7) & 0x1F;
    const unsigned: u32 = (high << 5) | low;
    if ((high & 0x40) != 0) {
        return @bitCast(unsigned | 0xFFFF_F000);
    }
    return @bitCast(unsigned);
}

// J-type immediate: bits scrambled, multiplied by 2 implicitly.
pub fn immJ(word: u32) i32 {
    const imm20: u32 = (word >> 31) & 0x1;
    const imm10_1: u32 = (word >> 21) & 0x3FF;
    const imm11: u32 = (word >> 20) & 0x1;
    const imm19_12: u32 = (word >> 12) & 0xFF;
    const unsigned: u32 =
        (imm20 << 20) |
        (imm19_12 << 12) |
        (imm11 << 11) |
        (imm10_1 << 1);
    // Sign-extend from bit 20.
    if (imm20 == 1) {
        return @bitCast(unsigned | 0xFFE0_0000);
    }
    return @bitCast(unsigned);
}

pub fn decode(word: u32) Instruction {
    return switch (opcode(word)) {
        0b0110111 => .{ .op = .lui, .rd = rd(word), .imm = immU(word), .raw = word },
        0b0010111 => .{ .op = .auipc, .rd = rd(word), .imm = immU(word), .raw = word },
        0b1101111 => .{ .op = .jal, .rd = rd(word), .imm = immJ(word), .raw = word },
        0b1100111 => .{ .op = .jalr, .rd = rd(word), .rs1 = rs1(word), .imm = immI(word), .raw = word },
        0b1100011 => blk: {
            const op: Op = switch (funct3(word)) {
                0b000 => .beq,
                0b001 => .bne,
                0b100 => .blt,
                0b101 => .bge,
                0b110 => .bltu,
                0b111 => .bgeu,
                else => .illegal,
            };
            break :blk .{ .op = op, .rs1 = rs1(word), .rs2 = rs2(word), .imm = immB(word), .raw = word };
        },
        0b0000011 => blk: {
            const op: Op = switch (funct3(word)) {
                0b000 => .lb,
                0b001 => .lh,
                0b010 => .lw,
                0b100 => .lbu,
                0b101 => .lhu,
                else => .illegal,
            };
            break :blk .{ .op = op, .rd = rd(word), .rs1 = rs1(word), .imm = immI(word), .raw = word };
        },
        0b0100011 => blk: {
            const op: Op = switch (funct3(word)) {
                0b000 => .sb,
                0b001 => .sh,
                0b010 => .sw,
                else => .illegal,
            };
            break :blk .{ .op = op, .rs1 = rs1(word), .rs2 = rs2(word), .imm = immS(word), .raw = word };
        },
        0b0010011 => blk: {
            const f3 = funct3(word);
            const f7 = funct7(word);
            const shamt: i32 = @intCast((word >> 20) & 0x1F);
            const op: Op = switch (f3) {
                0b000 => .addi,
                0b010 => .slti,
                0b011 => .sltiu,
                0b100 => .xori,
                0b110 => .ori,
                0b111 => .andi,
                0b001 => if (f7 == 0) Op.slli else Op.illegal,
                0b101 => switch (f7) {
                    0b0000000 => Op.srli,
                    0b0100000 => Op.srai,
                    else => Op.illegal,
                },
            };
            const imm: i32 = if (op == .slli or op == .srli or op == .srai) shamt else immI(word);
            break :blk .{ .op = op, .rd = rd(word), .rs1 = rs1(word), .imm = imm, .raw = word };
        },
        0b0110011 => blk: {
            const f3 = funct3(word);
            const f7 = funct7(word);
            const op: Op = switch (f3) {
                0b000 => switch (f7) {
                    0b0000000 => Op.add,
                    0b0100000 => Op.sub,
                    0b0000001 => Op.mul,
                    else => Op.illegal,
                },
                0b001 => switch (f7) {
                    0b0000000 => Op.sll,
                    0b0000001 => Op.mulh,
                    else => Op.illegal,
                },
                0b010 => switch (f7) {
                    0b0000000 => Op.slt,
                    0b0000001 => Op.mulhsu,
                    else => Op.illegal,
                },
                0b011 => switch (f7) {
                    0b0000000 => Op.sltu,
                    0b0000001 => Op.mulhu,
                    else => Op.illegal,
                },
                0b100 => switch (f7) {
                    0b0000000 => Op.xor_,
                    0b0000001 => Op.div,
                    else => Op.illegal,
                },
                0b101 => switch (f7) {
                    0b0000000 => Op.srl,
                    0b0100000 => Op.sra,
                    0b0000001 => Op.divu,
                    else => Op.illegal,
                },
                0b110 => switch (f7) {
                    0b0000000 => Op.or_,
                    0b0000001 => Op.rem,
                    else => Op.illegal,
                },
                0b111 => switch (f7) {
                    0b0000000 => Op.and_,
                    0b0000001 => Op.remu,
                    else => Op.illegal,
                },
            };
            break :blk .{ .op = op, .rd = rd(word), .rs1 = rs1(word), .rs2 = rs2(word), .raw = word };
        },
        0b0001111 => return .{ .op = .fence, .raw = word },
        0b1110011 => {
            // SYSTEM: funct3 must be 000, then imm distinguishes ecall (0) vs ebreak (1).
            if (funct3(word) != 0) return .{ .op = .illegal, .raw = word };
            const imm12: u32 = (word >> 20) & 0xFFF;
            return switch (imm12) {
                0 => .{ .op = .ecall, .raw = word },
                1 => .{ .op = .ebreak, .raw = word },
                else => .{ .op = .illegal, .raw = word },
            };
        },
        else => .{ .op = .illegal, .raw = word },
    };
}

test "decode LUI t0, 0x10000 → 0x100002B7" {
    const i = decode(0x100002B7);
    try std.testing.expectEqual(Op.lui, i.op);
    try std.testing.expectEqual(@as(u5, 5), i.rd);
    try std.testing.expectEqual(@as(i32, 0x1000_0000), i.imm);
}

test "decode AUIPC ra, 0x80000 → 0x800000_97" {
    // auipc x1, 0x80000  → opcode=0x17, rd=1, imm[31:12]=0x80000
    const i = decode(0x80000097);
    try std.testing.expectEqual(Op.auipc, i.op);
    try std.testing.expectEqual(@as(u5, 1), i.rd);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x8000_0000))), i.imm);
}

test "unknown opcode decodes to illegal" {
    const i = decode(0x0000_0000); // all-zero is not a valid encoding
    try std.testing.expectEqual(Op.illegal, i.op);
    try std.testing.expectEqual(@as(u32, 0), i.raw);
}

test "decode JAL ra, +0x10 → opcode 0x6F, rd=1, imm=16" {
    // jal x1, 0x10  →  imm[20|10:1|11|19:12] = 0,0000001000,0,00000000
    // Encoded: bit 31=0, 30:21=0000001000, 20=0, 19:12=00000000, 11:7=00001, 6:0=1101111
    // = 0x010000EF
    const i = decode(0x010000EF);
    try std.testing.expectEqual(Op.jal, i.op);
    try std.testing.expectEqual(@as(u5, 1), i.rd);
    try std.testing.expectEqual(@as(i32, 0x10), i.imm);
}

test "decode JAL with negative offset" {
    // jal x0, -16  encoded as 0xFF1FF06F
    // (Plan text had 0xFE1FF06F which actually encodes -32; corrected to match -16 per RISC-V J-type layout.)
    const i = decode(0xFF1FF06F);
    try std.testing.expectEqual(Op.jal, i.op);
    try std.testing.expectEqual(@as(u5, 0), i.rd);
    try std.testing.expectEqual(@as(i32, -16), i.imm);
}

test "decode JALR x1, x2, 4 → opcode 0x67" {
    // funct3 = 000, opcode = 1100111
    // imm[11:0]=0x004, rs1=x2=00010, funct3=000, rd=x1=00001, opcode=1100111
    // = 0x004100E7
    const i = decode(0x004100E7);
    try std.testing.expectEqual(Op.jalr, i.op);
    try std.testing.expectEqual(@as(u5, 1), i.rd);
    try std.testing.expectEqual(@as(u5, 2), i.rs1);
    try std.testing.expectEqual(@as(i32, 4), i.imm);
}

test "decode BEQ t2, x0, +0x10 → 0x00038863" {
    // beq x7, x0, +16
    // imm = 16 → imm[12]=0, imm[11]=0, imm[10:5]=000000, imm[4:1]=1000
    // bit31=0, bits[30:25]=000000, rs2=00000, rs1=00111, funct3=000,
    // bits[11:8]=1000, bit7=0, opcode=1100011
    // = 0x00038863
    const i = decode(0x00038863);
    try std.testing.expectEqual(Op.beq, i.op);
    try std.testing.expectEqual(@as(u5, 7), i.rs1);
    try std.testing.expectEqual(@as(u5, 0), i.rs2);
    try std.testing.expectEqual(@as(i32, 16), i.imm);
}

test "decode BNE with negative offset" {
    // bne x1, x2, -8
    // imm = -8 → 13-bit two's complement = 0x1FF8
    // imm[12]=1, imm[11]=1, imm[10:5]=111111, imm[4:1]=1100
    // bit31=1, bits[30:25]=111111, rs2=00010, rs1=00001, funct3=001,
    // bits[11:8]=1100, bit7=1, opcode=1100011
    // = 0xFE209CE3  (plan encoding verified correct)
    const i = decode(0xFE209CE3);
    try std.testing.expectEqual(Op.bne, i.op);
    try std.testing.expectEqual(@as(u5, 1), i.rs1);
    try std.testing.expectEqual(@as(u5, 2), i.rs2);
    try std.testing.expectEqual(@as(i32, -8), i.imm);
}

test "decode LB t2, 0(t1) → 0x00030383" {
    const i = decode(0x00030383);
    try std.testing.expectEqual(Op.lb, i.op);
    try std.testing.expectEqual(@as(u5, 7), i.rd);
    try std.testing.expectEqual(@as(u5, 6), i.rs1);
    try std.testing.expectEqual(@as(i32, 0), i.imm);
}

test "decode SB t2, 0(t0) → 0x00728023" {
    const i = decode(0x00728023);
    try std.testing.expectEqual(Op.sb, i.op);
    try std.testing.expectEqual(@as(u5, 5), i.rs1);
    try std.testing.expectEqual(@as(u5, 7), i.rs2);
    try std.testing.expectEqual(@as(i32, 0), i.imm);
}

test "decode LW with positive offset" {
    // lw x5, 8(x6)  → imm=8, rs1=6, funct3=010, rd=5, opcode=0000011
    // bits 31:20=0x008, 19:15=00110, 14:12=010, 11:7=00101, 6:0=0000011
    // = 0x00832283
    const i = decode(0x00832283);
    try std.testing.expectEqual(Op.lw, i.op);
    try std.testing.expectEqual(@as(u5, 5), i.rd);
    try std.testing.expectEqual(@as(u5, 6), i.rs1);
    try std.testing.expectEqual(@as(i32, 8), i.imm);
}

test "decode SW with negative offset" {
    // sw x5, -4(x6)  → imm=-4, rs1=6, rs2=5, funct3=010, opcode=0100011
    // imm[11:5]=1111111, imm[4:0]=11100
    // bits 31:25=1111111, 24:20=00101, 19:15=00110, 14:12=010, 11:7=11100, 6:0=0100011
    // = 0xFE532E23
    const i = decode(0xFE532E23);
    try std.testing.expectEqual(Op.sw, i.op);
    try std.testing.expectEqual(@as(u5, 6), i.rs1);
    try std.testing.expectEqual(@as(u5, 5), i.rs2);
    try std.testing.expectEqual(@as(i32, -4), i.imm);
}

test "decode ADDI x5, x0, -1 → 0xFFF00293" {
    const i = decode(0xFFF00293);
    try std.testing.expectEqual(Op.addi, i.op);
    try std.testing.expectEqual(@as(u5, 5), i.rd);
    try std.testing.expectEqual(@as(u5, 0), i.rs1);
    try std.testing.expectEqual(@as(i32, -1), i.imm);
}

test "decode SLLI x1, x2, 4 → 0x00411093" {
    // funct7=0000000, shamt=00100, rs1=00010, funct3=001, rd=00001, opcode=0010011
    const i = decode(0x00411093);
    try std.testing.expectEqual(Op.slli, i.op);
    try std.testing.expectEqual(@as(u5, 1), i.rd);
    try std.testing.expectEqual(@as(u5, 2), i.rs1);
    try std.testing.expectEqual(@as(i32, 4), i.imm);
}

test "decode SRAI x1, x2, 4 → 0x40415093" {
    // funct7=0100000, shamt=00100, rs1=00010, funct3=101, rd=00001, opcode=0010011
    const i = decode(0x40415093);
    try std.testing.expectEqual(Op.srai, i.op);
    try std.testing.expectEqual(@as(i32, 4), i.imm);
}

test "decode ADD x3, x1, x2 → 0x002081B3" {
    // funct7=0000000, rs2=00010, rs1=00001, funct3=000, rd=00011, opcode=0110011
    const i = decode(0x002081B3);
    try std.testing.expectEqual(Op.add, i.op);
    try std.testing.expectEqual(@as(u5, 3), i.rd);
    try std.testing.expectEqual(@as(u5, 1), i.rs1);
    try std.testing.expectEqual(@as(u5, 2), i.rs2);
}

test "decode SUB x3, x1, x2 → 0x402081B3" {
    const i = decode(0x402081B3);
    try std.testing.expectEqual(Op.sub, i.op);
}

test "decode FENCE → 0x0FF0000F" {
    // FENCE pred=1111, succ=1111, rs1=0, funct3=000, rd=0, opcode=0001111
    const i = decode(0x0FF0000F);
    try std.testing.expectEqual(Op.fence, i.op);
}

test "decode ECALL → 0x00000073" {
    const i = decode(0x00000073);
    try std.testing.expectEqual(Op.ecall, i.op);
}

test "decode EBREAK → 0x00100073" {
    const i = decode(0x00100073);
    try std.testing.expectEqual(Op.ebreak, i.op);
}

test "decode MUL x3, x1, x2 → 0x022081B3" {
    // funct7=0000001, rs2=00010, rs1=00001, funct3=000, rd=00011, opcode=0110011
    const i = decode(0x022081B3);
    try std.testing.expectEqual(Op.mul, i.op);
    try std.testing.expectEqual(@as(u5, 3), i.rd);
    try std.testing.expectEqual(@as(u5, 1), i.rs1);
    try std.testing.expectEqual(@as(u5, 2), i.rs2);
}

test "decode MULH x3, x1, x2 → 0x022091B3" {
    // funct3=001
    const i = decode(0x022091B3);
    try std.testing.expectEqual(Op.mulh, i.op);
}

test "decode MULHSU x3, x1, x2 → 0x0220A1B3" {
    // funct3=010
    const i = decode(0x0220A1B3);
    try std.testing.expectEqual(Op.mulhsu, i.op);
}

test "decode MULHU x3, x1, x2 → 0x0220B1B3" {
    // funct3=011
    const i = decode(0x0220B1B3);
    try std.testing.expectEqual(Op.mulhu, i.op);
}

test "decode DIV x3, x1, x2 → 0x0220C1B3" {
    // funct3=100
    const i = decode(0x0220C1B3);
    try std.testing.expectEqual(Op.div, i.op);
}

test "decode DIVU x3, x1, x2 → 0x0220D1B3" {
    // funct3=101, funct7=0000001 (distinct from SRL/SRA which use 0000000/0100000)
    const i = decode(0x0220D1B3);
    try std.testing.expectEqual(Op.divu, i.op);
}

test "decode REM x3, x1, x2 → 0x0220E1B3" {
    // funct3=110
    const i = decode(0x0220E1B3);
    try std.testing.expectEqual(Op.rem, i.op);
}

test "decode REMU x3, x1, x2 → 0x0220F1B3" {
    // funct3=111
    const i = decode(0x0220F1B3);
    try std.testing.expectEqual(Op.remu, i.op);
}

test "unknown funct7 on opcode 0x33 still decodes to illegal" {
    // funct7=0b1111111 (neither 0, 0x20, nor 0x01), funct3=000
    const i = decode(0xFE2081B3);
    try std.testing.expectEqual(Op.illegal, i.op);
}
