// src/kernel/user/mkdir.zig — Phase 3.E mkdir utility.

const ulib = @import("lib/ulib.zig");
const uprintf = @import("lib/uprintf.zig");

export fn main(argc: u32, argv: [*]const [*:0]const u8) i32 {
    if (argc < 2) {
        uprintf.printf(2, "usage: mkdir <path>\n", &.{});
        return 1;
    }
    if (ulib.mkdirat(0, argv[1]) < 0) {
        uprintf.printf(2, "mkdir: cannot create %s\n", &.{.{ .s = argv[1] }});
        return 1;
    }
    return 0;
}
