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

// Stubs for Tasks 3 + 4. Return safe defaults so the module compiles
// with no callers exercising them.
pub fn feedByte(b: u8) void {
    _ = b;
}

pub fn read(dst_va: u32, n: u32) i32 {
    _ = dst_va;
    _ = n;
    return 0;
}
