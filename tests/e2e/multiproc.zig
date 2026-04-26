// tests/programs/kernel/multiproc_verify_e2e.zig — Phase 3.B verifier.
//
// Spawns ccc on kernel-multi.elf, captures stdout, asserts:
//   - exit code 0
//   - stdout contains "hello from u-mode\n" (PID 1)
//   - stdout contains "[2] hello from u-mode\n" (PID 2)
//   - stdout contains "ticks observed: " followed by a decimal number
//     and a newline (PID 1's exit trailer; PID 1 is last to exit so
//     this line is preserved).
//
// Interleaving order is non-deterministic (round-robin + timer ticks).
// We check substrings rather than byte-exact prefixes.

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

    if (argv.len != 3) {
        stderr.print("usage: {s} <ccc-binary> <kernel-multi.elf>\n", .{argv[0]}) catch {};
        stderr.flush() catch {};
        return USAGE_EXIT;
    }

    const child_argv = &[_][]const u8{ argv[1], argv[2] };
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
            stderr.print("multiproc_verify_e2e: output exceeded {d} bytes\n", .{MAX_BYTES}) catch {};
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
            stderr.print("multiproc_verify_e2e: expected exit 0, got {d}\nstdout was:\n{s}\n", .{ code, out }) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
        else => {
            stderr.print("multiproc_verify_e2e: child terminated abnormally: {any}\nstdout was:\n{s}\n", .{ term, out }) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
    }

    if (std.mem.indexOf(u8, out, "hello from u-mode\n") == null) {
        stderr.print("multiproc_verify_e2e: missing PID 1 message\n  stdout: {s}\n", .{out}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    if (std.mem.indexOf(u8, out, "[2] hello from u-mode\n") == null) {
        stderr.print("multiproc_verify_e2e: missing PID 2 message\n  stdout: {s}\n", .{out}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    const ticks_marker = "ticks observed: ";
    const ticks_idx = std.mem.indexOf(u8, out, ticks_marker) orelse {
        stderr.print("multiproc_verify_e2e: missing ticks-observed trailer\n  stdout: {s}\n", .{out}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    };
    const after_ticks = out[ticks_idx + ticks_marker.len ..];
    var nl: usize = 0;
    while (nl < after_ticks.len and after_ticks[nl] != '\n') : (nl += 1) {}
    if (nl == 0 or nl == after_ticks.len) {
        stderr.print("multiproc_verify_e2e: malformed ticks line\n  stdout: {s}\n", .{out}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }
    _ = std.fmt.parseInt(u32, after_ticks[0..nl], 10) catch {
        stderr.print("multiproc_verify_e2e: ticks N not a number: {s}\n", .{after_ticks[0..nl]}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    };

    return 0;
}
