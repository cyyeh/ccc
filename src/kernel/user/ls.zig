// src/kernel/user/ls.zig — Phase 3.E ls utility.
//
// With no args: list current directory.
// With args: for each path, fstat to determine type:
//   - Dir: read DirEntry records, print each non-zero name.
//   - File: print the path itself + size.

const ulib = @import("lib/ulib.zig");
const uprintf = @import("lib/uprintf.zig");

// Must match kernel fs/layout.zig: u16 inum + 14-byte name = 16 B total.
const DIR_NAME_LEN: u32 = 14;
const DirEntry = extern struct {
    inum: u16,
    name: [DIR_NAME_LEN]u8,
};

fn printName(name: *const [DIR_NAME_LEN]u8) void {
    var n: u32 = 0;
    while (n < DIR_NAME_LEN and name[n] != 0) : (n += 1) {}
    _ = ulib.write(1, name, n);
    const nl: [1]u8 = .{'\n'};
    _ = ulib.write(1, &nl, 1);
}

fn lsPath(path: [*:0]const u8) void {
    const fd = ulib.openat(0, path, ulib.O_RDONLY);
    if (fd < 0) {
        uprintf.printf(2, "ls: cannot open %s\n", &.{.{ .s = path }});
        return;
    }
    defer _ = ulib.close(@intCast(fd));

    var st: ulib.Stat = .{ .type = 0, .size = 0 };
    if (ulib.fstat(@intCast(fd), &st) < 0) {
        uprintf.printf(2, "ls: cannot stat %s\n", &.{.{ .s = path }});
        return;
    }

    if (st.type == ulib.STAT_FILE) {
        // Print the path itself; ls(1) on Linux prints just the basename
        // when given a file, but our 1-arg ls just echoes whatever the
        // user passed.
        uprintf.printf(1, "%s %u\n", &.{ .{ .s = path }, .{ .u = st.size } });
        return;
    }

    if (st.type != ulib.STAT_DIR) {
        uprintf.printf(2, "ls: %s: unknown type\n", &.{.{ .s = path }});
        return;
    }

    var de: DirEntry = .{ .inum = 0, .name = [_]u8{0} ** DIR_NAME_LEN };
    while (true) {
        const got = ulib.read(@intCast(fd), @ptrCast(&de), @sizeOf(DirEntry));
        if (got != @sizeOf(DirEntry)) break;
        if (de.inum == 0) continue;
        printName(&de.name);
    }
}

export fn main(argc: u32, argv: [*]const [*:0]const u8) i32 {
    if (argc < 2) {
        const dot: [*:0]const u8 = ".";
        lsPath(dot);
        return 0;
    }
    var i: u32 = 1;
    while (i < argc) : (i += 1) {
        lsPath(argv[i]);
    }
    return 0;
}
