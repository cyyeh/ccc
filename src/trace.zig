const std = @import("std");
const decoder = @import("decoder.zig");
const cpu_mod = @import("cpu.zig");
const PrivilegeMode = cpu_mod.PrivilegeMode;

/// Format one line of instruction trace to `writer`. Format:
///   PC=0x80000004 RAW=0x00000013  [M]  addi  [x5 := 0x00000007]
///
/// The priv column appears between the RAW field and the mnemonic.
/// Bracketed suffixes list: (a) the rd write if any, (b) the PC
/// redirect if post_pc != pre_pc + 4.
pub fn formatInstr(
    writer: *std.Io.Writer,
    priv: PrivilegeMode,
    pre_pc: u32,
    instr: decoder.Instruction,
    pre_rd: u32,
    post_rd: u32,
    post_pc: u32,
) !void {
    const priv_str = switch (priv) {
        .M => "[M]",
        .S => "[S]",
        .U => "[U]",
        .reserved_h => "[?]", // defensive — reserved_h is clamped out on CSR writes
    };
    try writer.print("PC=0x{X:0>8} RAW=0x{X:0>8}  {s}  {s}", .{ pre_pc, instr.raw, priv_str, @tagName(instr.op) });
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
    try formatInstr(&aw.writer, .M, 0x80000000, i, 0, 7, 0x80000004);
    try std.testing.expectEqualStrings(
        "PC=0x80000000 RAW=0x00700293  [M]  addi  [x5 := 0x00000007]\n",
        aw.written(),
    );
}

test "format a jal shows pc redirect" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const i: decoder.Instruction = .{ .op = .jal, .rd = 1, .imm = 16, .raw = 0x010000EF };
    try formatInstr(&aw.writer, .M, 0x80000000, i, 0, 0x80000004, 0x80000010);
    try std.testing.expectEqualStrings(
        "PC=0x80000000 RAW=0x010000EF  [M]  jal  [x1 := 0x80000004]  [pc -> 0x80000010]\n",
        aw.written(),
    );
}

test "format an illegal has no rd write and no pc change (pre-trap)" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const i: decoder.Instruction = .{ .op = .illegal, .raw = 0xDEADBEEF };
    try formatInstr(&aw.writer, .M, 0x80000100, i, 0, 0, 0x80000104);
    try std.testing.expectEqualStrings(
        "PC=0x80000100 RAW=0xDEADBEEF  [M]  illegal\n",
        aw.written(),
    );
}

test "formatInstr emits [M] privilege column" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const i: decoder.Instruction = .{ .op = .addi, .rd = 5, .rs1 = 0, .imm = 7, .raw = 0x00700293 };
    try formatInstr(&aw.writer, .M, 0x80000000, i, 0, 7, 0x80000004);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "[M]") != null);
}

test "formatInstr emits [S] for S-mode and [U] for U-mode" {
    var aw1: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw1.deinit();
    const i: decoder.Instruction = .{ .op = .addi, .rd = 0, .rs1 = 0, .imm = 0, .raw = 0x00000013 };
    try formatInstr(&aw1.writer, .S, 0x80000000, i, 0, 0, 0x80000004);
    try std.testing.expect(std.mem.indexOf(u8, aw1.written(), "[S]") != null);

    var aw2: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw2.deinit();
    try formatInstr(&aw2.writer, .U, 0x80000000, i, 0, 0, 0x80000004);
    try std.testing.expect(std.mem.indexOf(u8, aw2.written(), "[U]") != null);
}
