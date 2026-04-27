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

fn save(path_z: [*:0]const u8) void {
    const fd = ulib.openat(0, path_z, ulib.O_WRONLY | ulib.O_CREAT | ulib.O_TRUNC);
    if (fd < 0) return; // silent failure — editor stays open
    var written: u32 = 0;
    while (written < content_len) {
        const w = ulib.write(@intCast(fd), content[written..].ptr, content_len - written);
        if (w <= 0) break;
        written += @intCast(w);
    }
    _ = ulib.close(@intCast(fd));
}

fn insertByte(b: u8) void {
    if (content_len >= CONTENT_CAP) return; // silently drop on full
    // Shift tail right one byte.
    var i: u32 = content_len;
    while (i > cursor) : (i -= 1) content[i] = content[i - 1];
    content[cursor] = b;
    content_len += 1;
    cursor += 1;
}

fn backspace() void {
    if (cursor == 0) return;
    // Shift tail left one byte (overwriting the byte before cursor).
    var i: u32 = cursor - 1;
    while (i + 1 < content_len) : (i += 1) content[i] = content[i + 1];
    content_len -= 1;
    cursor -= 1;
}

export fn main(argc: u32, argv: [*]const [*:0]const u8) i32 {
    if (argc < 2) {
        uprintf.printf(2, "usage: edit <path>\n", &.{});
        return 1;
    }

    // Save path for ^S.
    const path = argv[1];
    var i: u32 = 0;
    while (path[i] != 0 and i + 1 < PATH_MAX) : (i += 1) path_buf[i] = path[i];
    path_buf[i] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf[0]);

    // Load file (silently truncate if > CONTENT_CAP).
    const fd = ulib.openat(0, path_z, ulib.O_RDONLY);
    if (fd < 0) {
        uprintf.printf(2, "edit: cannot open %s\n", &.{.{ .s = path_z }});
        return 1;
    }
    var off: u32 = 0;
    while (off < CONTENT_CAP) {
        const n = ulib.read(@intCast(fd), content[off..].ptr, CONTENT_CAP - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
    _ = ulib.close(@intCast(fd));
    content_len = off;
    cursor = 0;

    enterRaw();
    defer leaveRaw();

    while (true) {
        var b: [1]u8 = .{0};
        const got = ulib.read(0, &b, 1);
        if (got <= 0) return 0;
        switch (b[0]) {
            0x13 => save(path_z),                         // ^S
            0x18 => return 0,                             // ^X
            0x08, 0x7F => backspace(),                    // backspace / DEL
            '\n', '\r' => insertByte('\n'),               // newline (normalize \r → \n)
            else => {
                if (b[0] >= 0x20 and b[0] <= 0x7E) insertByte(b[0]);
                // else: drop unknown control byte
            },
        }
    }
}
