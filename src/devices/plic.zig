const std = @import("std");

pub const PLIC_BASE: u32 = 0x0c00_0000;
pub const PLIC_SIZE: u32 = 0x0040_0000; // 4 MB legacy aperture

pub const PlicError = error{UnexpectedRegister};

pub const NSOURCES: u32 = 32;

pub const Plic = struct {
    priority: [NSOURCES]u3 = [_]u3{0} ** NSOURCES,
    /// Pending bits. Bit N pending for source N. Bit 0 hardwired 0.
    /// Mutated via assertSource/deassertSource and (later) cleared on claim.
    pending: u32 = 0,
    /// S-mode hart context enable bits. Bit N permits source N to drive
    /// the S-context's claim/threshold gate. Bit 0 hardwired 0.
    enable_s: u32 = 0,

    pub fn init() Plic {
        return .{};
    }

    pub fn assertSource(self: *Plic, irq: u5) void {
        if (irq == 0) return;
        self.pending |= @as(u32, 1) << irq;
    }

    pub fn deassertSource(self: *Plic, irq: u5) void {
        if (irq == 0) return;
        self.pending &= ~(@as(u32, 1) << irq);
    }

    pub fn readByte(self: *const Plic, offset: u32) PlicError!u8 {
        if (offset < 0x0080) {
            const src: u5 = @intCast(offset / 4);
            const byte_in_word: u2 = @intCast(offset % 4);
            if (byte_in_word == 0) return @as(u8, self.priority[src]);
            return 0;
        }
        // Pending register: u32 at 0x1000..0x1003.
        if (offset >= 0x1000 and offset < 0x1004) {
            const shift: u5 = @intCast((offset - 0x1000) * 8);
            return @truncate(self.pending >> shift);
        }
        // S-context enables: 0x2080..0x2083.
        if (offset >= 0x2080 and offset < 0x2084) {
            const shift: u5 = @intCast((offset - 0x2080) * 8);
            return @truncate(self.enable_s >> shift);
        }
        return 0;
    }

    pub fn writeByte(self: *Plic, offset: u32, value: u8) PlicError!void {
        if (offset < 0x0080) {
            const src: u5 = @intCast(offset / 4);
            const byte_in_word: u2 = @intCast(offset % 4);
            if (src == 0) return;
            if (byte_in_word == 0) {
                self.priority[src] = @intCast(value & 0x07);
            }
            return;
        }
        // Pending register is read-only.
        if (offset >= 0x1000 and offset < 0x1004) return;
        // S-context enables.
        if (offset >= 0x2080 and offset < 0x2084) {
            const off: u5 = @intCast((offset - 0x2080) * 8);
            const mask: u32 = @as(u32, 0xFF) << off;
            const new_byte: u32 = @as(u32, value) << off;
            self.enable_s = (self.enable_s & ~mask) | new_byte;
            // Bit 0 hardwired zero.
            self.enable_s &= ~@as(u32, 1);
            return;
        }
        // Out-of-range writes silently dropped.
    }
};

test "Plic.init constructs a default Plic" {
    const p = Plic.init();
    _ = p;
}

test "priority source 1 byte round-trip" {
    var p = Plic.init();
    try p.writeByte(0x0004, 0x05); // src 1 priority byte 0
    try std.testing.expectEqual(@as(u8, 0x05), try p.readByte(0x0004));
}

test "priority source 0 is hardwired zero (writes dropped)" {
    var p = Plic.init();
    try p.writeByte(0x0000, 0x07);
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x0000));
}

test "priority writes mask to 0..7 (drops upper bits)" {
    var p = Plic.init();
    try p.writeByte(0x0004, 0xFF); // 0xFF -> masked to 0x07
    try std.testing.expectEqual(@as(u8, 0x07), try p.readByte(0x0004));
    // Upper bytes of the priority u32 always read 0 (priority is u3).
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x0005));
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x0006));
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x0007));
}

test "priority source 31 is the last writable priority slot" {
    var p = Plic.init();
    try p.writeByte(0x007C, 0x03);
    try std.testing.expectEqual(@as(u8, 0x03), try p.readByte(0x007C));
}

test "assertSource(5) sets pending bit 5" {
    var p = Plic.init();
    p.assertSource(5);
    // Pending u32 lives at offset 0x1000.
    try std.testing.expectEqual(@as(u8, 0b0010_0000), try p.readByte(0x1000)); // byte 0, bit 5
}

test "deassertSource(5) clears pending bit 5" {
    var p = Plic.init();
    p.assertSource(5);
    p.deassertSource(5);
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x1000));
}

test "assertSource(0) is a no-op (source 0 reserved)" {
    var p = Plic.init();
    p.assertSource(0);
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x1000));
}

test "assertSource is idempotent" {
    var p = Plic.init();
    p.assertSource(10);
    p.assertSource(10);
    p.assertSource(10);
    // Bit 10 sits in byte 1 (bit 2 of byte 1).
    try std.testing.expectEqual(@as(u8, 0b0000_0100), try p.readByte(0x1001));
}

test "MMIO writes to pending register are dropped (read-only)" {
    var p = Plic.init();
    try p.writeByte(0x1000, 0xFF);
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x1000));
}

test "assertSource(31) reaches byte 3" {
    var p = Plic.init();
    p.assertSource(31);
    try std.testing.expectEqual(@as(u8, 0x80), try p.readByte(0x1003)); // bit 7 of byte 3
}

test "S-context enable register byte round-trip" {
    var p = Plic.init();
    try p.writeByte(0x2080, 0xFE); // enable srcs 1..7
    try std.testing.expectEqual(@as(u8, 0xFE), try p.readByte(0x2080));
}

test "S-context enable bit 0 is hardwired zero (writes dropped)" {
    var p = Plic.init();
    try p.writeByte(0x2080, 0xFF);
    // Bit 0 stays 0; bits 1..7 honored.
    try std.testing.expectEqual(@as(u8, 0xFE), try p.readByte(0x2080));
}

test "S-context enable spans all 4 bytes (sources 0..31)" {
    var p = Plic.init();
    try p.writeByte(0x2080, 0x02); // src 1
    try p.writeByte(0x2081, 0x04); // src 10
    try p.writeByte(0x2082, 0x00);
    try p.writeByte(0x2083, 0x80); // src 31
    try std.testing.expectEqual(@as(u8, 0x02), try p.readByte(0x2080));
    try std.testing.expectEqual(@as(u8, 0x04), try p.readByte(0x2081));
    try std.testing.expectEqual(@as(u8, 0x80), try p.readByte(0x2083));
}
