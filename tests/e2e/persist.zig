// tests/e2e/persist.zig — Phase 3.F disk-persistence verifier (e2e-persist).
//
// Runs ccc twice on the SAME --disk image. Pass 1 writes:
//
//   echo replaced > /etc/motd
//   exit
//
// Pass 2 reads:
//
//   cat /etc/motd
//   exit
//
// Asserts pass 2's stdout contains "replaced\n" — proving the kernel's
// bwrite path actually persisted bytes to the host file backing the
// block device, and that pass 2 reads them back via a fresh kernel/proc/
// bufcache instance (no in-memory state survives between invocations —
// only the disk does).
//
// Why a tmp copy: shell-fs.img is a build artifact that downstream tests
// (e2e-shell, e2e-editor) expect to be in a known-pristine state. Copying
// to zig-out/persist-test.img keeps this test self-contained.

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

    if (argv.len != 6) {
        stderr.print(
            "usage: {s} <ccc-binary> <shell-fs.img> <kernel-fs.elf> <pass1_input> <pass2_input>\n",
            .{argv[0]},
        ) catch {};
        stderr.flush() catch {};
        return USAGE_EXIT;
    }

    // Copy shell-fs.img to a fresh tmp image.
    const tmp_path = "zig-out/persist-test.img";
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

    // Pass 1: write phase. Just check exit 0.
    {
        const child_argv = &[_][]const u8{
            argv[1], "--input", argv[4], "--disk", tmp_path, argv[3],
        };
        var child = try std.process.spawn(io, .{
            .argv = child_argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
        });
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| if (code != 0) {
                stderr.print("persist_verify_e2e: pass 1 expected exit 0, got {d}\n", .{code}) catch {};
                stderr.flush() catch {};
                return FAIL_EXIT;
            },
            else => {
                stderr.print("persist_verify_e2e: pass 1 terminated abnormally: {any}\n", .{term}) catch {};
                stderr.flush() catch {};
                return FAIL_EXIT;
            },
        }
    }

    // Pass 2: read phase. Capture stdout, assert "replaced\n" appears
    // after the prompt.
    const out = blk: {
        const child_argv = &[_][]const u8{
            argv[1], "--input", argv[5], "--disk", tmp_path, argv[3],
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
        const captured = reader.interface.allocRemaining(gpa, .limited(MAX_BYTES)) catch |err| switch (err) {
            error.StreamTooLong => {
                stderr.print("persist_verify_e2e: pass 2 output exceeded {d} bytes\n", .{MAX_BYTES}) catch {};
                stderr.flush() catch {};
                child.kill(io);
                return FAIL_EXIT;
            },
            else => return err,
        };

        const term = try child.wait(io);
        switch (term) {
            .exited => |code| if (code != 0) {
                stderr.print(
                    "persist_verify_e2e: pass 2 expected exit 0, got {d}\nstdout was:\n{s}\n",
                    .{ code, captured },
                ) catch {};
                stderr.flush() catch {};
                gpa.free(captured);
                return FAIL_EXIT;
            },
            else => {
                stderr.print("persist_verify_e2e: pass 2 terminated abnormally: {any}\n", .{term}) catch {};
                stderr.flush() catch {};
                gpa.free(captured);
                return FAIL_EXIT;
            },
        }

        break :blk captured;
    };
    defer gpa.free(out);

    // The discriminating landmark: prompt + cat output sandwich.
    const landmark = "$ cat /etc/motd\nreplaced\n";
    if (std.mem.indexOf(u8, out, landmark) == null) {
        stderr.print("persist_verify_e2e: missing landmark {s}\nstdout was:\n{s}\n", .{ landmark, out }) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    return 0;
}
