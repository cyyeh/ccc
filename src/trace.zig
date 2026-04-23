const std = @import("std");
const decoder = @import("decoder.zig");

/// Format one line of instruction trace to `writer`. Format:
///   PC=0x80000004 RAW=0x00000013  addi  [x5 := 0x00000007]
///
/// Bracketed suffixes list: (a) the rd write if any, (b) the PC
/// redirect if post_pc != pre_pc + 4.
pub fn formatInstr(
    writer: *std.Io.Writer,
    pre_pc: u32,
    instr: decoder.Instruction,
    pre_rd: u32,
    post_rd: u32,
    post_pc: u32,
) !void {
    try writer.print("PC=0x{X:0>8} RAW=0x{X:0>8}  {s}", .{ pre_pc, instr.raw, @tagName(instr.op) });
    if (instr.rd != 0 and pre_rd != post_rd) {
        try writer.print("  [x{d} := 0x{X:0>8}]", .{ instr.rd, post_rd });
    }
    const expected_next = pre_pc +% 4;
    if (post_pc != expected_next) {
        try writer.print("  [pc -> 0x{X:0>8}]", .{post_pc});
    }
    try writer.print("\n", .{});
    try writer.flush();
}

test "format an addi with rd write" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const i: decoder.Instruction = .{ .op = .addi, .rd = 5, .rs1 = 0, .imm = 7, .raw = 0x00700293 };
    try formatInstr(&aw.writer, 0x80000000, i, 0, 7, 0x80000004);
    try std.testing.expectEqualStrings(
        "PC=0x80000000 RAW=0x00700293  addi  [x5 := 0x00000007]\n",
        aw.written(),
    );
}

test "format a jal shows pc redirect" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const i: decoder.Instruction = .{ .op = .jal, .rd = 1, .imm = 16, .raw = 0x010000EF };
    try formatInstr(&aw.writer, 0x80000000, i, 0, 0x80000004, 0x80000010);
    try std.testing.expectEqualStrings(
        "PC=0x80000000 RAW=0x010000EF  jal  [x1 := 0x80000004]  [pc -> 0x80000010]\n",
        aw.written(),
    );
}

test "format an illegal has no rd write and no pc change (pre-trap)" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const i: decoder.Instruction = .{ .op = .illegal, .raw = 0xDEADBEEF };
    try formatInstr(&aw.writer, 0x80000100, i, 0, 0, 0x80000104);
    try std.testing.expectEqualStrings(
        "PC=0x80000100 RAW=0xDEADBEEF  illegal\n",
        aw.written(),
    );
}
