// src/kernel/kprintf.zig — minimal formatter + panic.
//
// Supports the subset of std.fmt we need for Phase 2 panic messages:
//   {s} — []const u8 slice
//   {x} — u32 printed as 8 hex nibbles, no "0x" prefix (caller prints it)
//   {d} — u32 printed in decimal, no padding
// That's all. No width specifiers, no padding, no float, no negatives.
// Arguments are matched positionally; extras or mismatches trigger a
// kprintf.panic.

const uart = @import("uart.zig");

const HEX_DIGITS: []const u8 = "0123456789abcdef";

fn writeHexU32(v: u32) void {
    var i: u5 = 8;
    while (i > 0) {
        i -= 1;
        const nibble = @as(usize, @intCast((v >> (@as(u5, i) * 4)) & 0xF));
        uart.writeByte(HEX_DIGITS[nibble]);
    }
}

fn writeDecU32(v: u32) void {
    if (v == 0) {
        uart.writeByte('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var n: u32 = v;
    var i: usize = 0;
    while (n > 0) : (i += 1) {
        buf[i] = @as(u8, @intCast(n % 10)) + '0';
        n /= 10;
    }
    while (i > 0) : (i -= 1) uart.writeByte(buf[i - 1]);
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    comptime var arg_i: usize = 0;
    comptime var i: usize = 0;
    inline while (i < fmt.len) {
        if (fmt[i] == '{' and i + 2 < fmt.len and fmt[i + 2] == '}') {
            const spec = fmt[i + 1];
            const arg = args[arg_i];
            switch (spec) {
                's' => uart.writeBytes(arg),
                'x' => writeHexU32(arg),
                'd' => writeDecU32(arg),
                else => @compileError("kprintf: unsupported spec " ++ [_]u8{spec}),
            }
            arg_i += 1;
            i += 3;
        } else {
            uart.writeByte(fmt[i]);
            i += 1;
        }
    }
    if (arg_i != args.len) @compileError("kprintf: argument count mismatch");
}

pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    uart.writeBytes("panic: ");
    print(fmt, args);
    uart.writeByte('\n');
    const halt: *volatile u8 = @ptrFromInt(0x00100000);
    halt.* = 0xFF;
    while (true) asm volatile ("wfi");
}
