// tests/e2e/snake.zig — snake e2e verifier.
//
// Host-compiled helper for `zig build e2e-snake`. Spawns the emulator
// with the snake ELF and a deterministic input file, captures stdout,
// and asserts the final frame contains "GAME OVER" and "score: 0".
//
// Usage: verify_e2e <ccc-binary> <snake.elf> <snake_input.txt>

const std = @import("std");
const Io = std.Io;

const FAIL_EXIT: u8 = 1;
const USAGE_EXIT: u8 = 2;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    // stderr writer for our diagnostics.
    var stderr_buf: [512]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_fw.interface;

    const argv = try init.minimal.args.toSlice(gpa);
    defer gpa.free(argv);

    if (argv.len != 4) {
        stderr.print("usage: {s} <ccc-binary> <snake.elf> <snake_input.txt>\n", .{argv[0]}) catch {};
        stderr.flush() catch {};
        return USAGE_EXIT;
    }

    const ccc_path = argv[1];
    const snake_path = argv[2];
    const input_path = argv[3];

    // Spawn ccc with --input and the snake ELF; pipe stdout, inherit stderr
    // so emulator diagnostics are visible to the operator.
    const child_argv = &[_][]const u8{ ccc_path, "--input", input_path, snake_path };
    var child = try std.process.spawn(io, .{
        .argv = child_argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    // Read all of stdout. Cap at 1 MiB — snake produces ~35 bytes/frame × ~30
    // frames ≈ 1 KiB; 1 MiB gives ample headroom while catching runaways.
    const MAX_BYTES: usize = 1024 * 1024;
    var read_buf: [4096]u8 = undefined;
    var reader = child.stdout.?.reader(io, &read_buf);
    const out = reader.interface.allocRemaining(gpa, .limited(MAX_BYTES)) catch |err| switch (err) {
        error.StreamTooLong => {
            stderr.print(
                "verify_e2e: snake output exceeded {d} bytes\n",
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

    if (std.mem.indexOf(u8, out, "GAME OVER") == null) {
        const tail_start = if (out.len > 500) out.len - 500 else 0;
        stderr.print(
            "verify_e2e: expected 'GAME OVER' in stdout. last 500 bytes:\n{s}\n",
            .{out[tail_start..]},
        ) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    if (std.mem.indexOf(u8, out, "score: 0") == null) {
        stderr.print("verify_e2e: expected 'score: 0' in stdout\n", .{}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    // PASS: emit a single line so the build step can confirm success.
    var stdout_buf: [256]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_fw.interface;
    try stdout.print("e2e-snake: PASS ({d} bytes captured)\n", .{out.len});
    try stdout.flush();

    return 0;
}
