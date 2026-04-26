// tests/e2e/fs.zig — Phase 3.D verifier.
//
// Spawns ccc --disk fs.img kernel-fs.elf, captures stdout, asserts:
//   - exit code 0
//   - stdout contains "hello from phase 3\n" (motd content)
//   - stdout contains "ticks observed: " followed by a decimal number + \n
//     (PID 1 = init exits via syscall.sysExit → proc.exit's PID-1 trailer).

const std = @import("std");
const Io = std.Io;

const FAIL_EXIT: u8 = 1;
const USAGE_EXIT: u8 = 2;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var stderr_buf: [512]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_fw.interface;

    const argv = try init.minimal.args.toSlice(gpa);
    defer gpa.free(argv);

    if (argv.len != 4) {
        stderr.print("usage: {s} <ccc-binary> <fs.img> <kernel-fs.elf>\n", .{argv[0]}) catch {};
        stderr.flush() catch {};
        return USAGE_EXIT;
    }

    const child_argv = &[_][]const u8{ argv[1], "--disk", argv[2], argv[3] };
    var child = try std.process.spawn(io, .{
        .argv = child_argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    const MAX_BYTES: usize = 65536;
    var read_buf: [4096]u8 = undefined;
    var reader = child.stdout.?.reader(io, &read_buf);
    const out = reader.interface.allocRemaining(gpa, .limited(MAX_BYTES)) catch |err| switch (err) {
        error.StreamTooLong => {
            stderr.print("fs_verify_e2e: output exceeded {d} bytes\n", .{MAX_BYTES}) catch {};
            stderr.flush() catch {};
            child.kill(io);
            return FAIL_EXIT;
        },
        else => return err,
    };
    defer gpa.free(out);

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            stderr.print("fs_verify_e2e: expected exit 0, got {d}\nstdout was:\n{s}\n", .{ code, out }) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
        else => {
            stderr.print("fs_verify_e2e: child terminated abnormally: {any}\nstdout was:\n{s}\n", .{ term, out }) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
    }

    if (std.mem.indexOf(u8, out, "hello from phase 3\n") == null) {
        stderr.print("fs_verify_e2e: missing motd content\n  stdout: {s}\n", .{out}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    const ticks_marker = "ticks observed: ";
    const ticks_idx = std.mem.indexOf(u8, out, ticks_marker) orelse {
        stderr.print("fs_verify_e2e: missing ticks-observed trailer\n  stdout: {s}\n", .{out}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    };
    const after_ticks = out[ticks_idx + ticks_marker.len ..];
    var nl: usize = 0;
    while (nl < after_ticks.len and after_ticks[nl] != '\n') : (nl += 1) {}
    if (nl == 0 or nl == after_ticks.len) {
        stderr.print("fs_verify_e2e: malformed ticks line\n  stdout: {s}\n", .{out}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }
    _ = std.fmt.parseInt(u32, after_ticks[0..nl], 10) catch {
        stderr.print("fs_verify_e2e: ticks N not a number: {s}\n", .{after_ticks[0..nl]}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    };

    return 0;
}
