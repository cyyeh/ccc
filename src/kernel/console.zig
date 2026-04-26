// src/kernel/console.zig — Phase 3.E console line discipline.
//
// Backing for fd 0/1/2 in every process. Holds a 128-byte circular input
// buffer (xv6-style: `r`, `w`, `e` indices), a `mode` (Cooked vs Raw),
// and an `fg_pid` (the foreground process that ^C kills).
//
// API:
//   init():            zero indices; mode = Cooked; fg_pid = 0.
//   setMode(mode):     0 = Cooked, anything else = Raw.
//   setFgPid(pid):     who ^C kills.
//   write(src_va, n):  SUM-1 copy bytes through uart.writeByte. Returns n.
//   feedByte(b):       line discipline (Task 3).
//   read(dst_va, n):   sleep until r != w, copy bytes (Task 4).
//
// Single-hart: all state is global and uninstanced.

const uart = @import("uart.zig");
const proc = @import("proc.zig");

pub const ConsoleMode = enum(u32) { Cooked = 0, Raw = 1 };
pub const INPUT_BUF_SIZE: u32 = 128;

pub var input: struct {
    buf: [INPUT_BUF_SIZE]u8 = undefined,
    r: u32 = 0,
    w: u32 = 0,
    e: u32 = 0,
} = .{};

pub var mode: ConsoleMode = .Cooked;
pub var fg_pid: u32 = 0;

pub fn init() void {
    input.r = 0;
    input.w = 0;
    input.e = 0;
    mode = .Cooked;
    fg_pid = 0;
}

pub fn setMode(new_mode: u32) void {
    mode = if (new_mode == 0) .Cooked else .Raw;
}

pub fn setFgPid(pid: u32) void {
    fg_pid = pid;
}

const SSTATUS_SUM: u32 = 1 << 18;

inline fn setSum() void {
    asm volatile ("csrs sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SUM),
        : .{ .memory = true });
}

inline fn clearSum() void {
    asm volatile ("csrc sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SUM),
        : .{ .memory = true });
}

/// SUM-1 copy `n` bytes from user VA `src_va` to the UART. Returns `n`.
pub fn write(src_va: u32, n: u32) i32 {
    setSum();
    defer clearSum();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const p: *const volatile u8 = @ptrFromInt(src_va + i);
        uart.writeByte(p.*);
    }
    return @intCast(n);
}

pub fn feedByte(b: u8) void {
    if (mode == .Raw) {
        // Raw: append, wake, no echo, no special handling.
        if (input.e -% input.r >= INPUT_BUF_SIZE) return; // buf full — drop
        input.buf[input.e % INPUT_BUF_SIZE] = b;
        input.e += 1;
        input.w = input.e;
        proc.wakeup(@intFromPtr(&input.r));
        return;
    }

    // Cooked.
    switch (b) {
        0x03 => { // ^C
            // Erase any in-progress line (between w and e).
            while (input.e != input.w) : (input.e -%= 1) {
                uart.writeByte(0x08);
                uart.writeByte(' ');
                uart.writeByte(0x08);
            }
            uart.writeByte('^');
            uart.writeByte('C');
            uart.writeByte('\n');
            // Discard any committed-but-not-yet-read bytes too — clean slate.
            input.r = input.w;
            // Kill foreground.
            if (fg_pid != 0) _ = proc.kill(fg_pid);
            proc.wakeup(@intFromPtr(&input.r));
        },
        0x15 => { // ^U — kill current line
            while (input.e != input.w) : (input.e -%= 1) {
                uart.writeByte(0x08);
                uart.writeByte(' ');
                uart.writeByte(0x08);
            }
        },
        0x08, 0x7F => { // backspace / DEL
            if (input.e != input.w) {
                input.e -%= 1;
                uart.writeByte(0x08);
                uart.writeByte(' ');
                uart.writeByte(0x08);
            }
        },
        0x04 => { // ^D EOF
            // Commit whatever's typed; reader will see r == w after consuming.
            input.w = input.e;
            proc.wakeup(@intFromPtr(&input.r));
        },
        else => {
            const c: u8 = if (b == '\r') '\n' else b;
            // Drop unprintable control bytes other than \n.
            if (c != '\n' and (c < 0x20 or c == 0x7F)) return;
            // Drop if buf is full.
            if (input.e -% input.r >= INPUT_BUF_SIZE) return;
            input.buf[input.e % INPUT_BUF_SIZE] = c;
            input.e += 1;
            uart.writeByte(c);
            if (c == '\n') {
                input.w = input.e;
                proc.wakeup(@intFromPtr(&input.r));
            }
        },
    }
}

/// SUM-1 copy `n` bytes from input buffer to user VA `dst_va`.
/// Sleep on input.r until a byte is available. Handle ^D EOF marker.
/// Return bytes delivered (0 if immediate EOF).
pub fn read(dst_va: u32, n: u32) i32 {
    var got: u32 = 0;
    while (got < n) {
        // Wait for at least one byte to be deliverable.
        while (input.r == input.w) {
            if (proc.cur().killed != 0) return -1;
            proc.sleep(@intFromPtr(&input.r));
        }
        const c = input.buf[input.r % INPUT_BUF_SIZE];
        input.r += 1;

        // ^D in the buffer: an EOF marker. Consume but don't deliver.
        if (c == 0x04) {
            // If we already delivered something, return it; else 0 = EOF.
            break;
        }

        setSum();
        const dst: *volatile u8 = @ptrFromInt(dst_va + got);
        dst.* = c;
        clearSum();
        got += 1;

        if (c == '\n') break;
    }
    return @intCast(got);
}
