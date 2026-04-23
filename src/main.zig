const std = @import("std");
const Io = std.Io;

comptime {
    _ = @import("cpu.zig");
    _ = @import("memory.zig");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [64]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.print("ccc stub — toolchain works\n", .{});
    try stdout.flush();
}

test "trivial" {
    try std.testing.expect(true);
}
