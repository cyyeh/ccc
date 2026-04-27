// src/kernel/user/rm.zig — Phase 3.E rm utility.

const ulib = @import("lib/ulib.zig");
const uprintf = @import("lib/uprintf.zig");

export fn main(argc: u32, argv: [*]const [*:0]const u8) i32 {
    if (argc < 2) {
        uprintf.printf(2, "usage: rm <path>\n", &.{});
        return 1;
    }
    if (ulib.unlinkat(0, argv[1], 0) < 0) {
        uprintf.printf(2, "rm: cannot remove %s\n", &.{.{ .s = argv[1] }});
        return 1;
    }
    return 0;
}
