// tests/e2e/shell.zig — Phase 3.E milestone verifier.
//
// Spawns ccc --input <shell_input.txt> --disk shell-fs.img kernel-fs.elf,
// captures stdout, asserts:
//   - exit code 0
//   - stdout contains each of the scripted session landmarks:
//       "$ ls /bin"        (prompt + command echo)
//       "sh\n"             (ls output — sh binary present in /bin)
//       "$ echo hi > /tmp/x"
//       "$ cat /tmp/x"
//       "hi\n"             (cat output)
//       "$ rm /tmp/x"
//       "$ exit"

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
            "usage: {s} <ccc-binary> <shell-fs.img> <kernel-fs.elf> <shell_input.txt>\n",
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
            stderr.print("shell_verify_e2e: output exceeded {d} bytes\n", .{MAX_BYTES}) catch {};
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
                "shell_verify_e2e: expected exit 0, got {d}\nstdout was:\n{s}\n",
                .{ code, out },
            ) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
        else => {
            stderr.print(
                "shell_verify_e2e: child terminated abnormally: {any}\nstdout was:\n{s}\n",
                .{ term, out },
            ) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
    }

    const landmarks = [_][]const u8{
        "$ ls /bin",
        "sh\n",
        "$ echo hi > /tmp/x",
        "$ cat /tmp/x",
        "hi\n",
        "$ rm /tmp/x",
        "$ exit",
    };

    var all_ok = true;
    for (landmarks) |lm| {
        if (std.mem.indexOf(u8, out, lm) == null) {
            stderr.print("shell_verify_e2e: missing landmark {s}\n", .{lm}) catch {};
            all_ok = false;
        }
    }

    if (!all_ok) {
        stderr.print("shell_verify_e2e: stdout was:\n{s}\n", .{out}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    return 0;
}
