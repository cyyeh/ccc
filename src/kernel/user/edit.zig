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

const EscState = enum { Normal, GotEsc, GotCsi };
var esc_state: EscState = .Normal;

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

fn moveRight() void {
    if (cursor < content_len) cursor += 1;
}

fn moveLeft() void {
    if (cursor > 0) cursor -= 1;
}

/// Compute (row, col) for `offset` within content. Both are 1-based
/// (matches ANSI `\x1b[<row>;<col>H` semantics). Walks newlines from
/// the start.
fn rowCol(offset: u32) struct { row: u32, col: u32 } {
    var row: u32 = 1;
    var col: u32 = 1;
    var i: u32 = 0;
    while (i < offset) : (i += 1) {
        if (content[i] == '\n') {
            row += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .row = row, .col = col };
}

fn writeStr(s: []const u8) void {
    _ = ulib.write(1, s.ptr, @intCast(s.len));
}

/// Decimal-print n into a small fixed buffer; emit via writeStr.
fn writeUint(n: u32) void {
    var buf: [11]u8 = undefined;
    var i: u32 = 0;
    var v: u32 = n;
    if (v == 0) {
        buf[0] = '0';
        i = 1;
    } else {
        while (v > 0) {
            buf[i] = @intCast('0' + (v % 10));
            i += 1;
            v /= 10;
        }
        // reverse in place
        var lo: u32 = 0;
        var hi: u32 = i - 1;
        while (lo < hi) {
            const t = buf[lo];
            buf[lo] = buf[hi];
            buf[hi] = t;
            lo += 1;
            hi -= 1;
        }
    }
    writeStr(buf[0..i]);
}

fn redraw() void {
    // Clear screen + home cursor.
    writeStr("\x1b[2J\x1b[H");
    // Render the buffer.
    if (content_len > 0) writeStr(content[0..content_len]);
    // Position cursor at the byte-offset's (row, col).
    const rc = rowCol(cursor);
    writeStr("\x1b[");
    writeUint(rc.row);
    writeStr(";");
    writeUint(rc.col);
    writeStr("H");
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

    redraw();

    while (true) {
        var b: [1]u8 = .{0};
        const got = ulib.read(0, &b, 1);
        if (got <= 0) return 0;
        switch (esc_state) {
            .Normal => switch (b[0]) {
                0x1B => esc_state = .GotEsc,
                0x13 => save(path_z),                         // ^S
                0x18 => return 0,                             // ^X
                0x08, 0x7F => { backspace(); redraw(); },     // backspace / DEL
                '\n', '\r' => { insertByte('\n'); redraw(); },
                else => {
                    if (b[0] >= 0x20 and b[0] <= 0x7E) {
                        insertByte(b[0]);
                        redraw();
                    }
                },
            },
            .GotEsc => {
                if (b[0] == '[') {
                    esc_state = .GotCsi;
                } else {
                    esc_state = .Normal;
                }
            },
            .GotCsi => {
                switch (b[0]) {
                    'C' => { moveRight(); redraw(); },
                    'D' => { moveLeft(); redraw(); },
                    'A', 'B' => {}, // up/down — Task 5 wires these
                    else => {},
                }
                esc_state = .Normal;
            },
        }
    }
}
