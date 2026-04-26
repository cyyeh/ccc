// src/kernel/user/echo.zig — Phase 3.E echo utility.
//
// Writes argv[1..] joined by spaces, then a newline.

const ulib = @import("lib/ulib.zig");

export fn main(argc: u32, argv: [*]const [*:0]const u8) i32 {
    var i: u32 = 1;
    while (i < argc) : (i += 1) {
        const arg = argv[i];
        const len = ulib.strlen(arg);
        _ = ulib.write(1, @ptrCast(arg), len);
        if (i + 1 < argc) {
            const sp: [1]u8 = .{' '};
            _ = ulib.write(1, &sp, 1);
        }
    }
    const nl: [1]u8 = .{'\n'};
    _ = ulib.write(1, &nl, 1);
    return 0;
}
