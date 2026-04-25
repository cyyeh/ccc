const std = @import("std");

pub const PLIC_BASE: u32 = 0x0c00_0000;
pub const PLIC_SIZE: u32 = 0x0040_0000; // 4 MB legacy aperture

pub const PlicError = error{UnexpectedRegister};

pub const NSOURCES: u32 = 32;

pub const Plic = struct {
    /// Per-source priority. Index 0 hardwired 0 (source 0 reserved by spec).
    /// Indices 1..31 hold u3 (0..7).
    priority: [NSOURCES]u3 = [_]u3{0} ** NSOURCES,

    pub fn init() Plic {
        return .{};
    }

    pub fn readByte(self: *const Plic, offset: u32) PlicError!u8 {
        // Priority registers: 0x0000..0x007F (u32 per source, src 0..31).
        if (offset < 0x0080) {
            const src: u5 = @intCast(offset / 4);
            const byte_in_word: u2 = @intCast(offset % 4);
            // Priority is u3, lives in byte 0 of the u32; bytes 1..3 are 0.
            if (byte_in_word == 0) return @as(u8, self.priority[src]);
            return 0;
        }
        // Out-of-range (the rest of the 4 MB aperture): lenient zero.
        return 0;
    }

    pub fn writeByte(self: *Plic, offset: u32, value: u8) PlicError!void {
        if (offset < 0x0080) {
            const src: u5 = @intCast(offset / 4);
            const byte_in_word: u2 = @intCast(offset % 4);
            // Source 0 is reserved — writes silently dropped.
            if (src == 0) return;
            // Only byte 0 stores; mask to u3.
            if (byte_in_word == 0) {
                self.priority[src] = @intCast(value & 0x07);
            }
            // Bytes 1..3 are write-ignored (priority is u3).
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
