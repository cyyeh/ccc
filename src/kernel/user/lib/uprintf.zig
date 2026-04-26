// src/kernel/user/lib/uprintf.zig — minimal printf for fd.
//
// Supports %d (i32), %u (u32 decimal), %x (u32 hex lowercase),
// %s (NUL-terminated string), %c (u8), %% (literal '%').
//
// Args is a slice of the Arg union — caller passes e.g.:
//   printf(1, "hello %s, pid %d\n", &.{ .{ .s = "world" }, .{ .i = pid } });

const ulib = @import("ulib.zig");

fn putc(fd: u32, c: u8) void {
    var b: [1]u8 = .{c};
    _ = ulib.write(fd, &b, 1);
}

fn putStr(fd: u32, s: [*:0]const u8) void {
    var i: u32 = 0;
    while (s[i] != 0) : (i += 1) putc(fd, s[i]);
}

fn putUint(fd: u32, n: u32, base: u32) void {
    var buf: [16]u8 = undefined;
    var i: u32 = 0;
    var v = n;
    if (v == 0) {
        putc(fd, '0');
        return;
    }
    while (v > 0) {
        const d = v % base;
        buf[i] = if (d < 10) @intCast('0' + d) else @intCast('a' + d - 10);
        i += 1;
        v /= base;
    }
    while (i > 0) {
        i -= 1;
        putc(fd, buf[i]);
    }
}

fn putInt(fd: u32, n: i32, base: u32) void {
    if (n < 0) {
        putc(fd, '-');
        putUint(fd, @intCast(-n), base);
    } else {
        putUint(fd, @intCast(n), base);
    }
}

pub const Arg = union(enum) {
    i: i32,
    u: u32,
    s: [*:0]const u8,
    c: u8,
};

pub fn printf(fd: u32, fmt: [*:0]const u8, args: []const Arg) void {
    var i: u32 = 0;
    var ai: u32 = 0;
    while (fmt[i] != 0) : (i += 1) {
        if (fmt[i] != '%') {
            putc(fd, fmt[i]);
            continue;
        }
        i += 1;
        if (fmt[i] == 0) return;
        switch (fmt[i]) {
            'd' => {
                putInt(fd, args[ai].i, 10);
                ai += 1;
            },
            'u' => {
                putUint(fd, args[ai].u, 10);
                ai += 1;
            },
            'x' => {
                putUint(fd, args[ai].u, 16);
                ai += 1;
            },
            's' => {
                putStr(fd, args[ai].s);
                ai += 1;
            },
            'c' => {
                putc(fd, args[ai].c);
                ai += 1;
            },
            '%' => putc(fd, '%'),
            else => {
                putc(fd, '%');
                putc(fd, fmt[i]);
            },
        }
    }
}
