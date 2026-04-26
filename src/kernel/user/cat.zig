// src/kernel/user/cat.zig — Phase 3.E cat utility.
//
// With no args: copy fd 0 → fd 1 until EOF.
// With args: open each, copy contents to fd 1, close.

const ulib = @import("lib/ulib.zig");
const uprintf = @import("lib/uprintf.zig");

const BUF_SIZE: u32 = 512;
var buf: [BUF_SIZE]u8 = undefined;

fn copyFd(fd: u32) void {
    while (true) {
        const got = ulib.read(fd, &buf, BUF_SIZE);
        if (got <= 0) break;
        var written: u32 = 0;
        while (written < @as(u32, @intCast(got))) {
            const w = ulib.write(1, buf[written..].ptr, @as(u32, @intCast(got)) - written);
            if (w <= 0) break;
            written += @intCast(w);
        }
    }
}

export fn main(argc: u32, argv: [*]const [*:0]const u8) i32 {
    if (argc < 2) {
        copyFd(0);
        return 0;
    }

    var i: u32 = 1;
    while (i < argc) : (i += 1) {
        const fd = ulib.openat(0, argv[i], ulib.O_RDONLY);
        if (fd < 0) {
            uprintf.printf(2, "cat: cannot open %s\n", &.{.{ .s = argv[i] }});
            continue;
        }
        copyFd(@intCast(fd));
        _ = ulib.close(@intCast(fd));
    }
    return 0;
}
