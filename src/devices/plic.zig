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
    /// S-context threshold (u3 0..7). A source's priority must be strictly
    /// greater than this to be deliverable.
    threshold_s: u3 = 0,
    /// Latch for byte-wise reads of the claim register: byte 0 triggers
    /// the claim and stores the result here; bytes 1..3 return slices of it.
    /// Reset after byte 3 so the next byte-0 read performs a fresh claim.
    claim_latch: u32 = 0,
    claim_latch_valid: bool = false,

    pub fn init() Plic {
        return .{};
    }

    /// Claim the highest-priority pending+enabled source whose priority is
    /// strictly greater than the S-context threshold. Returns the source ID
    /// (1..31) or 0 if no source qualifies. Atomically clears the chosen
    /// source's pending bit. Ties broken by lowest source ID.
    pub fn claim(self: *Plic) u32 {
        var best_id: u32 = 0;
        var best_prio: u3 = 0;
        var i: u5 = 1;
        while (true) : (i += 1) {
            if ((self.pending & (@as(u32, 1) << i)) != 0 and
                (self.enable_s & (@as(u32, 1) << i)) != 0)
            {
                const prio = self.priority[i];
                if (prio > self.threshold_s and prio > best_prio) {
                    best_prio = prio;
                    best_id = i;
                }
            }
            if (i == 31) break;
        }
        if (best_id != 0) {
            self.pending &= ~(@as(u32, 1) << @intCast(best_id));
        }
        return best_id;
    }

    /// Byte-wise read protocol for the 32-bit claim register. Byte 0 triggers
    /// the destructive claim and latches the resulting source ID; bytes 1..3
    /// return slices of the latched value. After byte 3 is consumed the
    /// latch is invalidated so the next byte-0 read performs a fresh claim.
    fn byteOfClaimLatch(self: *Plic, byte: u2) u8 {
        if (byte == 0) {
            self.claim_latch = self.claim();
            self.claim_latch_valid = true;
            return @truncate(self.claim_latch);
        }
        if (!self.claim_latch_valid) return 0;
        const b: u8 = @truncate(self.claim_latch >> (@as(u5, byte) * 8));
        if (byte == 3) self.claim_latch_valid = false;
        return b;
    }

    pub fn assertSource(self: *Plic, irq: u5) void {
        if (irq == 0) return;
        self.pending |= @as(u32, 1) << irq;
    }

    pub fn deassertSource(self: *Plic, irq: u5) void {
        if (irq == 0) return;
        self.pending &= ~(@as(u32, 1) << irq);
    }

    /// Note: signature is *Plic (mutable) because byte 0 of the claim
    /// register (0x20_1004) triggers a destructive claim that clears the
    /// chosen source's pending bit. Memory.zig's dispatcher already holds
    /// a mutable *Plic, so this poses no friction at the call site.
    pub fn readByte(self: *Plic, offset: u32) PlicError!u8 {
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
        // S-context threshold: 0x20_1000..0x20_1003.
        if (offset >= 0x20_1000 and offset < 0x20_1004) {
            const byte_in_word: u2 = @intCast(offset - 0x20_1000);
            if (byte_in_word == 0) return @as(u8, self.threshold_s);
            return 0;
        }
        // S-context claim/complete: 0x20_1004..0x20_1007. Reading byte 0
        // is destructive — performs the claim and latches the result.
        if (offset >= 0x20_1004 and offset < 0x20_1008) {
            return self.byteOfClaimLatch(@intCast(offset - 0x20_1004));
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
        // S-context threshold.
        if (offset >= 0x20_1000 and offset < 0x20_1004) {
            const byte_in_word: u2 = @intCast(offset - 0x20_1000);
            if (byte_in_word == 0) self.threshold_s = @intCast(value & 0x07);
            return;
        }
        // S-context complete: 0x20_1004..0x20_1007. Writes are accepted
        // and ignored — completion is a no-op in our model.
        if (offset >= 0x20_1004 and offset < 0x20_1008) return;
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

test "S-context threshold byte round-trip with masking" {
    var p = Plic.init();
    try p.writeByte(0x20_1000, 0x07);
    try std.testing.expectEqual(@as(u8, 0x07), try p.readByte(0x20_1000));
    // Upper bytes of the threshold u32 are always 0 (threshold is u3).
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x20_1001));
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x20_1002));
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x20_1003));
}

test "S-context threshold writes mask to 0..7" {
    var p = Plic.init();
    try p.writeByte(0x20_1000, 0xFF);
    try std.testing.expectEqual(@as(u8, 0x07), try p.readByte(0x20_1000));
}

test "S-context threshold defaults to 0" {
    var p = Plic.init();
    try std.testing.expectEqual(@as(u8, 0), try p.readByte(0x20_1000));
}

test "claim returns 0 when no source pending" {
    var p = Plic.init();
    try std.testing.expectEqual(@as(u32, 0), p.claim());
}

test "claim returns sole pending source and clears its bit" {
    var p = Plic.init();
    try p.writeByte(0x0004, 1);   // src 1 priority 1
    try p.writeByte(0x2080, 0x02); // enable src 1
    p.assertSource(1);
    try std.testing.expectEqual(@as(u32, 1), p.claim());
    // pending bit cleared after claim.
    try std.testing.expectEqual(@as(u32, 0), p.pending);
    // Subsequent claim returns 0.
    try std.testing.expectEqual(@as(u32, 0), p.claim());
}

test "claim picks highest priority among pending+enabled" {
    var p = Plic.init();
    try p.writeByte(0x0004, 2); // src 1 priority 2
    try p.writeByte(0x000C, 5); // src 3 priority 5
    try p.writeByte(0x0028, 3); // src 10 priority 3
    try p.writeByte(0x2080, 0xFE); // enable srcs 1..7
    try p.writeByte(0x2081, 0x04); // enable src 10
    p.assertSource(1);
    p.assertSource(3);
    p.assertSource(10);
    // src 3 wins (priority 5 > 3 > 2).
    try std.testing.expectEqual(@as(u32, 3), p.claim());
    // src 1 and 10 still pending.
    try std.testing.expect((p.pending & (1 << 1)) != 0);
    try std.testing.expect((p.pending & (1 << 10)) != 0);
}

test "claim breaks priority ties by lowest source ID" {
    var p = Plic.init();
    try p.writeByte(0x0004, 4); // src 1 priority 4
    try p.writeByte(0x0008, 4); // src 2 priority 4
    try p.writeByte(0x2080, 0x06); // enable srcs 1, 2
    p.assertSource(2);
    p.assertSource(1);
    try std.testing.expectEqual(@as(u32, 1), p.claim());
}

test "claim ignores sources whose priority <= threshold" {
    var p = Plic.init();
    try p.writeByte(0x0004, 3);     // src 1 priority 3
    try p.writeByte(0x2080, 0x02);  // enable src 1
    try p.writeByte(0x20_1000, 3);  // threshold = 3
    p.assertSource(1);
    // priority 3 is NOT > 3 → not deliverable.
    try std.testing.expectEqual(@as(u32, 0), p.claim());
    // Pending bit still set (claim didn't fire).
    try std.testing.expect((p.pending & (1 << 1)) != 0);
}

test "claim ignores disabled sources" {
    var p = Plic.init();
    try p.writeByte(0x0004, 4);
    // enable_s zero — src 1 not enabled.
    p.assertSource(1);
    try std.testing.expectEqual(@as(u32, 0), p.claim());
}

test "claim register MMIO read is the same as claim() function" {
    var p = Plic.init();
    try p.writeByte(0x0004, 1);
    try p.writeByte(0x2080, 0x02);
    p.assertSource(1);
    // Word read at 0x20_1004 should yield 1, byte-by-byte.
    const b0 = try p.readByte(0x20_1004);
    const b1 = try p.readByte(0x20_1005);
    const b2 = try p.readByte(0x20_1006);
    const b3 = try p.readByte(0x20_1007);
    const v: u32 = @as(u32, b0) | (@as(u32, b1) << 8) | (@as(u32, b2) << 16) | (@as(u32, b3) << 24);
    try std.testing.expectEqual(@as(u32, 1), v);
}

test "complete (write to claim register) is a no-op" {
    var p = Plic.init();
    try p.writeByte(0x20_1004, 1);
    try p.writeByte(0x20_1005, 0);
    try p.writeByte(0x20_1006, 0);
    try p.writeByte(0x20_1007, 0);
    // No state observed; just doesn't crash.
}
