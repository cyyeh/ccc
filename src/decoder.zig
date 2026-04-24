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
    // Zicsr (Plan 1.C, Task 3)
    csrrw,
    csrrs,
    csrrc,
    csrrwi,
    csrrsi,
    csrrci,
    // Machine-mode privileged (Plan 1.C, Task 9)
    mret,
    wfi,
    // Supervisor-mode privileged (Plan 2.A, Task 9)
    sret,
    // Supervisor-mode TLB flush (Plan 2.A, Task 10)
    sfence_vma,
    // (more added in later plans)
    illegal,
};

pub const Instruction = struct {
    op: Op,
    rd: u5 = 0,
    rs1: u5 = 0, // on csrr*i, this slot holds the 5-bit uimm (not a register)
    rs2: u5 = 0,
    imm: i32 = 0,
    csr: u12 = 0,
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

pub fn funct5(word: u32) u5 {
    return @truncate((word >> 27) & 0x1F);
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
        0b0001111 => {
            // MISC-MEM: funct3 selects fence (000) vs fence.i (001).
            return switch (funct3(word)) {
                0b000 => .{ .op = .fence, .raw = word },
                0b001 => .{ .op = .fence_i, .raw = word },
                else => .{ .op = .illegal, .raw = word },
            };
        },
        0b1110011 => blk: {
            const f3 = funct3(word);
            const imm12: u32 = (word >> 20) & 0xFFF;
            if (f3 == 0b000) {
                // sfence.vma: top7 = 0b0001001, rs1 = VA reg, rs2 = ASID reg.
                // Must be checked before the imm12 dispatch because top7 != 0.
                const top7: u7 = @truncate((word >> 25) & 0x7F);
                if (top7 == 0b0001001) {
                    return .{
                        .op = .sfence_vma,
                        .rs1 = rs1(word),
                        .rs2 = rs2(word),
                        .raw = word,
                    };
                }
                // ecall / ebreak / sret / mret / wfi — distinguished by the full 12-bit imm field.
                // rd and rs1 are required to be zero for these; if they're not, the
                // instruction is still a valid encoding per spec, so we don't check.
                const op: Op = switch (imm12) {
                    0x000 => .ecall,
                    0x001 => .ebreak,
                    0x102 => .sret,
                    0x302 => .mret,
                    0x105 => .wfi,
                    else => .illegal,
                };
                break :blk .{ .op = op, .raw = word };
            }
            // Zicsr — 12-bit csr address lives in bits 31:20.
            const csr_addr: u12 = @truncate(imm12);
            const op: Op = switch (f3) {
                0b001 => .csrrw,
                0b010 => .csrrs,
                0b011 => .csrrc,
                0b100 => .illegal, // reserved funct3
                0b101 => .csrrwi,
                0b110 => .csrrsi,
                0b111 => .csrrci,
                else => .illegal, // f3 == 0 handled above
            };
            break :blk .{
                .op = op,
                .rd = rd(word),
                .rs1 = rs1(word),
                .csr = csr_addr,
                .raw = word,
            };
        },
        0b0101111 => blk: {
            // RV32A — all instructions share opcode 0x2F, funct3 = 010 (W-width).
            // funct5 (bits 31:27) distinguishes the 11 variants.
            // Bits 26 (aq) and 25 (rl) are decoded into the raw word but not
            // acted on; single-hart emulation has no reordering to suppress.
            if (funct3(word) != 0b010) break :blk .{ .op = .illegal, .raw = word };
            const f5 = funct5(word);
            const op: Op = switch (f5) {
                0b00010 => .lr_w,
                0b00011 => .sc_w,
                0b00001 => .amoswap_w,
                0b00000 => .amoadd_w,
                0b00100 => .amoxor_w,
                0b01100 => .amoand_w,
                0b01000 => .amoor_w,
                0b10000 => .amomin_w,
                0b10100 => .amomax_w,
                0b11000 => .amominu_w,
                0b11100 => .amomaxu_w,
                else => .illegal,
            };
            break :blk .{ .op = op, .rd = rd(word), .rs1 = rs1(word), .rs2 = rs2(word), .raw = word };
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

test "decode FENCE.I → 0x0000100F" {
    // opcode=0001111, rd=0, funct3=001, rs1=0, imm=0
    const i = decode(0x0000100F);
    try std.testing.expectEqual(Op.fence_i, i.op);
}

test "FENCE (funct3=0) still decodes to fence, not fence_i" {
    // opcode=0001111, rd=0, funct3=000, rs1=0, imm=0
    const i = decode(0x0000000F);
    try std.testing.expectEqual(Op.fence, i.op);
}

test "decode LR.W x3, (x1) → 0x1000A1AF" {
    // opcode=0101111, rd=00011, funct3=010, rs1=00001, rs2=00000,
    // aq=0, rl=0, funct5=00010 → 0x1000A1AF
    const i = decode(0x1000A1AF);
    try std.testing.expectEqual(Op.lr_w, i.op);
    try std.testing.expectEqual(@as(u5, 3), i.rd);
    try std.testing.expectEqual(@as(u5, 1), i.rs1);
}

test "decode SC.W x3, x2, (x1) → 0x1820A1AF" {
    // funct5=00011, rs2=00010
    const i = decode(0x1820A1AF);
    try std.testing.expectEqual(Op.sc_w, i.op);
    try std.testing.expectEqual(@as(u5, 3), i.rd);
    try std.testing.expectEqual(@as(u5, 1), i.rs1);
    try std.testing.expectEqual(@as(u5, 2), i.rs2);
}

test "decode AMOSWAP.W x3, x2, (x1) → 0x0820A1AF" {
    // funct5=00001
    const i = decode(0x0820A1AF);
    try std.testing.expectEqual(Op.amoswap_w, i.op);
}

test "decode AMOADD.W x3, x2, (x1) → 0x0020A1AF" {
    // funct5=00000
    const i = decode(0x0020A1AF);
    try std.testing.expectEqual(Op.amoadd_w, i.op);
}

test "decode AMOXOR.W → funct5=00100" {
    const i = decode(0x2020A1AF);
    try std.testing.expectEqual(Op.amoxor_w, i.op);
}

test "decode AMOAND.W → funct5=01100" {
    const i = decode(0x6020A1AF);
    try std.testing.expectEqual(Op.amoand_w, i.op);
}

test "decode AMOOR.W → funct5=01000" {
    const i = decode(0x4020A1AF);
    try std.testing.expectEqual(Op.amoor_w, i.op);
}

test "decode AMOMIN.W → funct5=10000" {
    const i = decode(0x8020A1AF);
    try std.testing.expectEqual(Op.amomin_w, i.op);
}

test "decode AMOMAX.W → funct5=10100" {
    const i = decode(0xA020A1AF);
    try std.testing.expectEqual(Op.amomax_w, i.op);
}

test "decode AMOMINU.W → funct5=11000" {
    const i = decode(0xC020A1AF);
    try std.testing.expectEqual(Op.amominu_w, i.op);
}

test "decode AMOMAXU.W → funct5=11100" {
    const i = decode(0xE020A1AF);
    try std.testing.expectEqual(Op.amomaxu_w, i.op);
}

test "AMO with funct3 != 010 decodes to illegal (no D-width in RV32A)" {
    // Same as amoswap.w but funct3=011 → illegal
    const i = decode(0x0820B1AF);
    try std.testing.expectEqual(Op.illegal, i.op);
}

test "AMO with unknown funct5 decodes to illegal" {
    // funct5=11111 (not allocated)
    const i = decode(0xF820A1AF);
    try std.testing.expectEqual(Op.illegal, i.op);
}

test "aq/rl bits in AMO are decoded but don't change Op (amoswap.w with aq=1,rl=1)" {
    // Same as amoswap.w test but with aq=1, rl=1 → bits 26,25 set.
    // funct5=00001, aq=1, rl=1 → bits 31..25 = 0000_1_1_1 = 0x07 → 0x0E
    // Full word: 0x0E20A1AF
    const i = decode(0x0E20A1AF);
    try std.testing.expectEqual(Op.amoswap_w, i.op);
}

test "decode CSRRW a0, mstatus, t0 → 0x300292F3" {
    // csrrw x5 (t0) into mstatus (0x300), read into x5 (t0)? Let's pick clear operands.
    // csrrw rd=x5, rs1=x5, csr=0x300 → bits: csr[31:20]=0x300, rs1[19:15]=00101,
    // funct3[14:12]=001, rd[11:7]=00101, opcode[6:0]=1110011
    //   = 0b001100000000_00101_001_00101_1110011
    //   = 0x300292F3
    const i = decode(0x300292F3);
    try std.testing.expectEqual(Op.csrrw, i.op);
    try std.testing.expectEqual(@as(u5, 5), i.rd);
    try std.testing.expectEqual(@as(u5, 5), i.rs1);
    try std.testing.expectEqual(@as(u12, 0x300), i.csr);
}

test "decode CSRRS rd=x1, rs1=x0, csr=mhartid → 0xF14022F3 has rd=5, not 1; re-encode" {
    // csrrs rd=x5 (t0), rs1=x0, csr=0xF14 (mhartid)
    // bits: 0xF14 << 20 | 0 << 15 | 010 << 12 | 5 << 7 | 0b1110011
    //   = 0xF140_0000 | 0 | 0x2000 | 0x0280 | 0x73
    //   = 0xF14022F3
    const i = decode(0xF14022F3);
    try std.testing.expectEqual(Op.csrrs, i.op);
    try std.testing.expectEqual(@as(u5, 5), i.rd);
    try std.testing.expectEqual(@as(u5, 0), i.rs1);
    try std.testing.expectEqual(@as(u12, 0xF14), i.csr);
}

test "decode CSRRC rd=x3, rs1=x4, csr=mtvec" {
    // csrrc rd=x3, rs1=x4, csr=0x305 (mtvec)
    // 0x305 << 20 | 4 << 15 | 011 << 12 | 3 << 7 | 0x73
    //   = 0x3050_0000 | 0x0002_0000 | 0x3000 | 0x0180 | 0x73
    //   = 0x305231F3
    const i = decode(0x305231F3);
    try std.testing.expectEqual(Op.csrrc, i.op);
    try std.testing.expectEqual(@as(u5, 3), i.rd);
    try std.testing.expectEqual(@as(u5, 4), i.rs1);
    try std.testing.expectEqual(@as(u12, 0x305), i.csr);
}

test "decode CSRRWI rd=x1, uimm=0x1F, csr=mepc — uimm lives in the rs1 slot" {
    // csrrwi rd=x1, zimm=0x1F (= 31), csr=0x341 (mepc)
    // 0x341 << 20 | 0x1F << 15 | 101 << 12 | 1 << 7 | 0x73
    //   = 0x3410_0000 | 0x000F_8000 | 0x5000 | 0x0080 | 0x73
    //   = 0x341FD0F3
    const i = decode(0x341FD0F3);
    try std.testing.expectEqual(Op.csrrwi, i.op);
    try std.testing.expectEqual(@as(u5, 1), i.rd);
    try std.testing.expectEqual(@as(u5, 0x1F), i.rs1); // uimm stashed in rs1 slot
    try std.testing.expectEqual(@as(u12, 0x341), i.csr);
}

test "decode CSRRSI rd=x0, uimm=0, csr=0xC00 (cycle — unsupported in Phase 1 but decode succeeds)" {
    // csrrsi rd=x0, zimm=0, csr=0xC00
    // 0xC00 << 20 | 0 << 15 | 110 << 12 | 0 << 7 | 0x73
    //   = 0xC000_0000 | 0 | 0x6000 | 0 | 0x73
    //   = 0xC0006073
    const i = decode(0xC0006073);
    try std.testing.expectEqual(Op.csrrsi, i.op);
    try std.testing.expectEqual(@as(u5, 0), i.rd);
    try std.testing.expectEqual(@as(u5, 0), i.rs1);
    try std.testing.expectEqual(@as(u12, 0xC00), i.csr);
}

test "decode CSRRCI rd=x7, uimm=0b10101, csr=mie" {
    // csrrci rd=x7, zimm=0x15, csr=0x304 (mie)
    // 0x304 << 20 | 0x15 << 15 | 111 << 12 | 7 << 7 | 0x73
    //   = 0x3040_0000 | 0x000A_8000 | 0x7000 | 0x0380 | 0x73
    //   = 0x304AF3F3
    const i = decode(0x304AF3F3);
    try std.testing.expectEqual(Op.csrrci, i.op);
    try std.testing.expectEqual(@as(u5, 7), i.rd);
    try std.testing.expectEqual(@as(u5, 0x15), i.rs1);
    try std.testing.expectEqual(@as(u12, 0x304), i.csr);
}

test "SYSTEM with funct3=100 decodes to illegal (reserved in Zicsr)" {
    // csr=0x300, rs1=0, funct3=100 (reserved), rd=5, opcode=0x73
    // 0x300 << 20 | 0 << 15 | 100 << 12 | 5 << 7 | 0x73
    //   = 0x30004_2F3
    const i = decode(0x300042F3);
    try std.testing.expectEqual(Op.illegal, i.op);
}

test "decode: sret" {
    const ins = decode(0x10200073);
    try std.testing.expectEqual(Op.sret, ins.op);
}

test "decode: sfence.vma zero, zero" {
    const ins = decode(0x12000073);
    try std.testing.expectEqual(Op.sfence_vma, ins.op);
    try std.testing.expectEqual(@as(u5, 0), ins.rs1);
    try std.testing.expectEqual(@as(u5, 0), ins.rs2);
}

test "decode: sfence.vma t0, t1 captures rs1 and rs2" {
    // rs1=5 (t0), rs2=6 (t1), top7=0b0001001
    const word: u32 = (0b0001001 << 25) | (6 << 20) | (5 << 15) | (0 << 12) | (0 << 7) | 0b1110011;
    const ins = decode(word);
    try std.testing.expectEqual(Op.sfence_vma, ins.op);
    try std.testing.expectEqual(@as(u5, 5), ins.rs1);
    try std.testing.expectEqual(@as(u5, 6), ins.rs2);
}
