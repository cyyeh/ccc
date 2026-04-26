// tests/e2e/kernel.zig — Phase 2 Plan 2.D e2e verifier.
//
// Host-compiled helper for `zig build e2e-kernel`. Spawns the emulator
// with the kernel ELF and asserts the Phase 2 §Definition of done:
//   - exit code 0
//   - stdout exactly:  "hello from u-mode\n"
//                      "ticks observed: N\n"
//     where N is a decimal integer > 0
//
// Usage: verify_e2e <ccc-binary> <kernel.elf>
//
// Uses Zig 0.16's std.process.spawn / Io.File.reader / Io.Reader.allocRemaining
// APIs (the stdlib was restructured in 0.16 — older patterns like
// std.process.Child.init().spawn() no longer compile).

const std = @import("std");
const Io = std.Io;

const FAIL_EXIT: u8 = 1;
const USAGE_EXIT: u8 = 2;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    // stderr writer for our diagnostics; inherits in the child separately.
    var stderr_buf: [512]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_fw.interface;

    const argv = try init.minimal.args.toSlice(gpa);
    defer gpa.free(argv);

    if (argv.len != 3) {
        stderr.print("usage: {s} <ccc-binary> <kernel.elf>\n", .{argv[0]}) catch {};
        stderr.flush() catch {};
        return USAGE_EXIT;
    }

    // Spawn ccc with the kernel ELF as its sole argument; pipe stdout, let
    // stderr inherit so emulator diagnostics (if any) are visible to the
    // operator.
    const child_argv = &[_][]const u8{ argv[1], argv[2] };
    var child = try std.process.spawn(io, .{
        .argv = child_argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    // Read all of stdout. Cap at 64 KiB — Phase 2's kernel output is
    // ~35 bytes; anything larger is a runaway bug we want to fail on.
    const MAX_BYTES: usize = 65536;
    var read_buf: [4096]u8 = undefined;
    var reader = child.stdout.?.reader(io, &read_buf);
    const out = reader.interface.allocRemaining(gpa, .limited(MAX_BYTES)) catch |err| switch (err) {
        error.StreamTooLong => {
            stderr.print(
                "verify_e2e: kernel output exceeded {d} bytes\n",
                .{MAX_BYTES},
            ) catch {};
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
            stderr.print(
                "verify_e2e: expected exit 0, got {d}\nstdout was:\n{s}\n",
                .{ code, out },
            ) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
        else => {
            stderr.print(
                "verify_e2e: child terminated abnormally: {any}\nstdout was:\n{s}\n",
                .{ term, out },
            ) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
    }

    // Assert structure: "hello from u-mode\nticks observed: <N>\n".
    const expected_prefix = "hello from u-mode\nticks observed: ";
    if (!std.mem.startsWith(u8, out, expected_prefix)) {
        stderr.print(
            "verify_e2e: stdout prefix mismatch\n  expected prefix: {s}\n  got: {s}\n",
            .{ expected_prefix, out },
        ) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    const rest = out[expected_prefix.len..];
    // Find the terminating '\n' that ends the ticks-observed line.
    var end: usize = 0;
    while (end < rest.len and rest[end] != '\n') : (end += 1) {}
    if (end == 0) {
        stderr.print(
            "verify_e2e: empty number after 'ticks observed: '\n  stdout: {s}\n",
            .{out},
        ) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }
    if (end == rest.len) {
        stderr.print(
            "verify_e2e: no newline after 'ticks observed: N'\n  stdout: {s}\n",
            .{out},
        ) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    const n_str = rest[0..end];
    const n = std.fmt.parseInt(u32, n_str, 10) catch {
        stderr.print(
            "verify_e2e: could not parse ticks: {s}\n  stdout: {s}\n",
            .{ n_str, out },
        ) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    };

    if (n == 0) {
        stderr.print(
            "verify_e2e: expected ticks > 0, got 0 (TIMESLICE too large or user program too short?)\n  stdout: {s}\n",
            .{out},
        ) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    // The '\n' at `end` must be the last byte. Anything after it is garbage.
    if (end + 1 != rest.len) {
        stderr.print(
            "verify_e2e: trailing bytes after final newline\n  stdout: {s}\n",
            .{out},
        ) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    return 0;
}
