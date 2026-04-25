const std = @import("std");

var output_buf: [16 * 1024]u8 = undefined;

export fn run() i32 {
    return 0;
}

export fn outputPtr() [*]const u8 {
    return &output_buf;
}

export fn outputLen() u32 {
    return 0;
}
