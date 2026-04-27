// tests/e2e/editor.zig — Phase 3.F editor + persistence verifier (e2e-editor).
//
// Spawns ccc --input editor_input.txt --disk <copy-of-shell-fs.img> kernel-fs.elf,
// captures stdout, asserts:
//   - exit code 0
//   - stdout contains "$ cat /etc/motd\nheYllo from phase 3\n" (the
//     edit-existing-file landmark)
//   - stdout contains "$ cat /tmp/new.txt\nnew\n" (the
//     edit-missing-file-creates-new-file landmark)
//
// Why a copy: the block device opens --disk O_RDWR, so the editor's
// save would mutate the staged shell-fs.img on disk. Copying to a tmp
// file keeps the build-output image clean across CI runs.
//
// Fixture byte sequence (84 bytes total):
//   "edit /etc/motd\n"      15 bytes — edit existing file
//   "\x1b[C\x1b[C"           6 bytes — 2× right-arrow (cursor 0 → 2)
//   "Y"                      1 byte  — insert at offset 2
//   "\x13"                   1 byte  — ^S save
//   "\x18"                   1 byte  — ^X exit
//   "cat /etc/motd\n"       14 bytes — verify the change
//   "edit /tmp/new.txt\n"   18 bytes — edit missing file (creates new)
//   "new\n"                  4 bytes — insert "new\n"
//   "\x13"                   1 byte  — ^S save (creates the file)
//   "\x18"                   1 byte  — ^X exit
//   "cat /tmp/new.txt\n"    17 bytes — verify the new file
//   "exit\n"                 5 bytes — clean shell exit

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
            "usage: {s} <ccc-binary> <shell-fs.img> <kernel-fs.elf> <editor_input.txt>\n",
            .{argv[0]},
        ) catch {};
        stderr.flush() catch {};
        return USAGE_EXIT;
    }

    // Copy shell-fs.img to a tmp path so the editor's writes don't
    // mutate the build artifact.
    const tmp_path = "zig-out/editor-test.img";
    {
        var src = try Io.Dir.cwd().openFile(io, argv[2], .{});
        defer src.close(io);
        const sz = try src.length(io);
        const buf = try gpa.alloc(u8, sz);
        defer gpa.free(buf);
        _ = try src.readPositionalAll(io, buf, 0);
        var dst = try Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
        defer dst.close(io);
        try dst.writePositionalAll(io, buf, 0);
    }

    const child_argv = &[_][]const u8{
        argv[1],
        "--input",
        argv[4],
        "--disk",
        tmp_path,
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
            stderr.print("editor_verify_e2e: output exceeded {d} bytes\n", .{MAX_BYTES}) catch {};
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
                "editor_verify_e2e: expected exit 0, got {d}\nstdout was:\n{s}\n",
                .{ code, out },
            ) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
        else => {
            stderr.print(
                "editor_verify_e2e: child terminated abnormally: {any}\nstdout was:\n{s}\n",
                .{ term, out },
            ) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
    }

    // Each discriminating landmark is the prompt + cat output sandwich:
    // the editor's redraws will contain the buffer text too, but only
    // the post-editor cat output is preceded by the literal "$ cat …\n"
    // prompt string.
    const landmarks = [_][]const u8{
        // edit existing file → "heYllo from phase 3\n"
        "$ cat /etc/motd\nheYllo from phase 3\n",
        // edit missing file → save creates it with "new\n"
        "$ cat /tmp/new.txt\nnew\n",
    };
    for (landmarks) |landmark| {
        if (std.mem.indexOf(u8, out, landmark) == null) {
            stderr.print("editor_verify_e2e: missing landmark {s}\nstdout was:\n{s}\n", .{ landmark, out }) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        }
    }

    return 0;
}
