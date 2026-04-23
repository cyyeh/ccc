const std = @import("std");

pub const Op = enum {
    lui,
    auipc,
    // (more added in later tasks)
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

pub fn decode(word: u32) Instruction {
    return switch (opcode(word)) {
        0b0110111 => .{ .op = .lui, .rd = rd(word), .imm = immU(word), .raw = word },
        0b0010111 => .{ .op = .auipc, .rd = rd(word), .imm = immU(word), .raw = word },
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
