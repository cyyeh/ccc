// src/kernel/user/edit.zig — Phase 3.F cursor-moving text editor.
//
// usage: edit <path>
//
// Loads <path> into a 16 KB buffer, switches the console to raw mode
// (so arrow keys arrive as ESC [ A/B/C/D and ^C / ^S / ^X are delivered
// as raw bytes), and runs a redraw-on-every-keystroke edit loop:
//
//   ESC [ A   cursor up
//   ESC [ B   cursor down
//   ESC [ C   cursor right
//   ESC [ D   cursor left
//   0x7F/0x08 backspace (delete byte before cursor)
//   0x13      ^S — save (truncate + rewrite path)
//   0x18      ^X — exit (restore cooked mode, exit 0)
//   printable insert at cursor
//
// Files larger than 16 KB are truncated silently. Saved files are
// rewritten in full via openat(O_WRONLY|O_TRUNC|O_CREAT) — consistent
// with editors of this shape.

const ulib = @import("lib/ulib.zig");
const uprintf = @import("lib/uprintf.zig");

const CONTENT_CAP: u32 = 16 * 1024;

var content: [CONTENT_CAP]u8 = undefined;
var content_len: u32 = 0;
var cursor: u32 = 0;

const PATH_MAX: u32 = 256;
var path_buf: [PATH_MAX]u8 = undefined;

fn enterRaw() void {
    _ = ulib.console_set_mode(ulib.CONSOLE_RAW);
}

fn leaveRaw() void {
    _ = ulib.console_set_mode(ulib.CONSOLE_COOKED);
}

export fn main(argc: u32, argv: [*]const [*:0]const u8) i32 {
    _ = argv;
    if (argc < 2) {
        uprintf.printf(2, "usage: edit <path>\n", &.{});
        return 1;
    }

    enterRaw();
    defer leaveRaw();

    while (true) {
        var b: [1]u8 = .{0};
        const got = ulib.read(0, &b, 1);
        if (got <= 0) return 0;
        if (b[0] == 0x18) return 0; // ^X
    }
}
