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

/// Human-readable name for an async interrupt cause code. RISC-V priv spec
/// §3.1.9 Table "Machine and Supervisor Interrupts".
fn interruptName(cause_code: u32) []const u8 {
    return switch (cause_code) {
        1 => "supervisor software",
        3 => "machine software",
        5 => "supervisor timer",
        7 => "machine timer",
        9 => "supervisor external",
        11 => "machine external",
        else => "unknown",
    };
}

fn privStr(p: PrivilegeMode) []const u8 {
    return switch (p) {
        .M => "M",
        .S => "S",
        .U => "U",
        .reserved_h => "?",
    };
}

/// Emit one line denoting an async interrupt entry:
///   --- interrupt N (<name>) taken in <old>, now <new> ---
///
/// Called by trap.enter_interrupt BEFORE the privilege switch so `from`
/// captures the pre-interrupt state. Synchronous traps do NOT emit this
/// marker — they appear in trace as the target-vector instruction.
pub fn formatInterruptMarker(
    writer: *std.Io.Writer,
    cause_code: u32,
    from: PrivilegeMode,
    to: PrivilegeMode,
) !void {
    try writer.print(
        "--- interrupt {d} ({s}) taken in {s}, now {s} ---\n",
        .{ cause_code, interruptName(cause_code), privStr(from), privStr(to) },
    );
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

test "formatInterruptMarker: machine timer (cause 7), taken in U, now M" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try formatInterruptMarker(&aw.writer, 7, .U, .M);
    try std.testing.expectEqualStrings(
        "--- interrupt 7 (machine timer) taken in U, now M ---\n",
        aw.written(),
    );
}

test "formatInterruptMarker: supervisor software (cause 1), taken in S, now S" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try formatInterruptMarker(&aw.writer, 1, .S, .S);
    try std.testing.expectEqualStrings(
        "--- interrupt 1 (supervisor software) taken in S, now S ---\n",
        aw.written(),
    );
}

test "formatInterruptMarker: unknown cause → \"unknown\"" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try formatInterruptMarker(&aw.writer, 42, .M, .M);
    try std.testing.expectEqualStrings(
        "--- interrupt 42 (unknown) taken in M, now M ---\n",
        aw.written(),
    );
}
