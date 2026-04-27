// tests/e2e/cancel.zig — Phase 3 ^C kill-flag verifier (e2e-cancel).
//
// Spawns ccc --input cancel_input.txt --disk shell-fs.img kernel-fs.elf,
// captures stdout, asserts:
//   - exit code 0
//   - stdout contains the kill-flag landmark "cat\n^C\n$ exit"
//
// The fixture is 10 bytes: "cat\n\x03exit\n" — start cat (which blocks
// reading fd 0), ^C the foreground process (kills it via proc.kill →
// killed flag → console.read returns -1 → syscall dispatch calls
// proc.exit(-1)), then exit the shell cleanly.
//
// Closes Phase 3 §Definition of Done's "^C in the shell cancels a
// foreground program (proves kill-flag)" bullet.

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

    if (argv.len != 5) {
        stderr.print(
            "usage: {s} <ccc-binary> <shell-fs.img> <kernel-fs.elf> <cancel_input.txt>\n",
            .{argv[0]},
        ) catch {};
        stderr.flush() catch {};
        return USAGE_EXIT;
    }

    const child_argv = &[_][]const u8{
        argv[1],
        "--input",
        argv[4],
        "--disk",
        argv[2],
        argv[3],
    };
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
            stderr.print("cancel_verify_e2e: output exceeded {d} bytes\n", .{MAX_BYTES}) catch {};
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
                "cancel_verify_e2e: expected exit 0, got {d}\nstdout was:\n{s}\n",
                .{ code, out },
            ) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
        else => {
            stderr.print(
                "cancel_verify_e2e: child terminated abnormally: {any}\nstdout was:\n{s}\n",
                .{ term, out },
            ) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
    }

    // The discriminating landmark: cat command echoed, then ^C echoed,
    // then a fresh prompt with exit. This sequence can only appear if
    // the kill-flag actually unstuck cat from its read syscall and the
    // shell got back to its prompt loop.
    const landmark = "cat\n^C\n$ exit";
    if (std.mem.indexOf(u8, out, landmark) == null) {
        stderr.print("cancel_verify_e2e: missing landmark {s}\nstdout was:\n{s}\n", .{ landmark, out }) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    return 0;
}
