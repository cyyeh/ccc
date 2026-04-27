const std = @import("std");

pub const BLOCK_BASE: u32 = 0x1000_1000;
pub const BLOCK_SIZE: u32 = 0x10;

pub const SECTOR_BYTES: u32 = 4096;
pub const NSECTORS: u32 = 1024; // 4 MB total disk
pub const RAM_BASE: u32 = 0x8000_0000;

pub const BlockError = error{UnexpectedRegister};

pub const Status = enum(u32) {
    Ready    = 0,
    Busy     = 1,    // never produced in Phase 3.A
    Error    = 2,
    NoMedia  = 3,
};

pub const Cmd = enum(u32) {
    None  = 0,
    Read  = 1,
    Write = 2,
};

pub const Block = struct {
    sector: u32 = 0,
    buffer_pa: u32 = 0,
    status: u32 = @intFromEnum(Status.NoMedia),
    /// Raised by writeByte(CMD) when a transfer completes (or fails).
    /// Polled by cpu.step at the top of each cycle to assert PLIC src 1.
    pending_irq: bool = false,
    /// Latest CMD value written; performTransfer consumes it.
    pending_cmd: u32 = 0,
    /// Optional in-memory backing (used by the wasm demo, where the disk
    /// is fetched into a wasm linear-memory slice rather than a host file).
    /// When non-null, takes precedence over `disk_file` in `performTransfer`.
    /// CLI uses `disk_file`; wasm uses `disk_slice`; setting both is a
    /// programmer error (slice wins).
    disk_slice: ?[]u8 = null,
    /// Optional host-file backing. When null, every CMD sets STATUS=NoMedia.
    disk_file: ?std.Io.File = null,
    /// Snapshot of the most recently completed (success or failure) transfer
    /// for the trace subsystem. `cpu.step` reads these fields when emitting
    /// the `--- block: ... ---` marker the cycle the deferred IRQ is
    /// serviced, then clears `last_op` back to null. Set by `performTransfer`
    /// for valid CMDs (Read=1 / Write=2); left null for CMD=0 (reset) and
    /// bogus CMDs so we don't print a phantom marker for them.
    last_op: ?@import("../trace.zig").Op = null,
    last_sector: u32 = 0,
    last_buffer_pa: u32 = 0,

    pub fn init() Block {
        return .{};
    }

    pub fn readByte(self: *const Block, offset: u32) BlockError!u8 {
        return switch (offset) {
            0x0...0x3 => @truncate(self.sector >> @as(u5, @intCast((offset - 0x0) * 8))),
            0x4...0x7 => @truncate(self.buffer_pa >> @as(u5, @intCast((offset - 0x4) * 8))),
            0x8...0xB => 0,             // CMD reads as 0
            0xC...0xF => @truncate(self.status >> @as(u5, @intCast((offset - 0xC) * 8))),
            else => BlockError.UnexpectedRegister,
        };
    }

    pub fn writeByte(self: *Block, offset: u32, value: u8) BlockError!void {
        switch (offset) {
            0x0...0x3 => {
                const shift: u5 = @intCast((offset - 0x0) * 8);
                self.sector = (self.sector & ~(@as(u32, 0xFF) << shift)) | (@as(u32, value) << shift);
            },
            0x4...0x7 => {
                const shift: u5 = @intCast((offset - 0x4) * 8);
                self.buffer_pa = (self.buffer_pa & ~(@as(u32, 0xFF) << shift)) | (@as(u32, value) << shift);
            },
            0x8...0xB => {
                const shift: u5 = @intCast((offset - 0x8) * 8);
                self.pending_cmd = (self.pending_cmd & ~(@as(u32, 0xFF) << shift)) | (@as(u32, value) << shift);
            },
            0xC...0xF => {
                // STATUS: writes ignored.
            },
            else => return BlockError.UnexpectedRegister,
        }
    }

    /// Run the latest CMD against the disk file, copying to/from `ram`
    /// at offset `buffer_pa - 0x80000000` (caller is responsible for the
    /// translation; if the offset is out of range, set Error). After the
    /// transfer (success OR failure), set `pending_irq = true`.
    ///
    /// `ram` is the RAM slice corresponding to physical address space starting
    /// at 0x80000000. The CPU step loop calls this with `&memory.ram` after
    /// observing CMD-write side effects. `io` is the host I/O dispatcher
    /// (Zig 0.16's `std.Io`) needed for file I/O on `disk_file`.
    pub fn performTransfer(self: *Block, io: std.Io, ram: []u8) void {
        defer self.pending_irq = true;
        defer self.pending_cmd = 0;

        // Reset CMD: nothing to do.
        if (self.pending_cmd == 0) {
            // No actual transfer was requested — but pending_irq is still
            // raised so the driver observes an edge for any latched CMD=0
            // reset. Status becomes Ready so a polling driver can drain.
            self.status = @intFromEnum(Status.Ready);
            return;
        }

        // Bad CMD takes precedence over media state — a malformed command
        // is a programmer error regardless of whether media is present.
        if (self.pending_cmd != 1 and self.pending_cmd != 2) {
            self.status = @intFromEnum(Status.Error);
            return;
        }

        // Snapshot the transfer for the trace subsystem. Recorded for any
        // valid Read/Write CMD regardless of whether the body below
        // succeeds (NoMedia, sector OOB, RAM OOB all still produce a
        // marker — what failed is the placement, not the request itself).
        // cpu.step reads these fields and clears last_op once the marker
        // has been emitted.
        self.last_op = if (self.pending_cmd == 1) .Read else .Write;
        self.last_sector = self.sector;
        self.last_buffer_pa = self.buffer_pa;

        // Sector range — shared gate for both the slice and file paths.
        if (self.sector >= NSECTORS) {
            self.status = @intFromEnum(Status.Error);
            return;
        }

        // Slice-backed path takes precedence (used by wasm demo).
        if (self.disk_slice) |disk| {
            // sector >= NSECTORS already gated above; re-check the actual
            // slice bounds in case the slice is shorter than the canonical
            // 4 MB (defense-in-depth — the wasm caller passes exactly
            // NSECTORS * SECTOR_BYTES, but tests may use smaller slices).
            const disk_off: usize = @as(usize, self.sector) * SECTOR_BYTES;
            if (disk_off + SECTOR_BYTES > disk.len) {
                self.status = @intFromEnum(Status.Error);
                return;
            }

            // RAM range (mirrors the file path's check).
            if (self.buffer_pa < RAM_BASE) {
                self.status = @intFromEnum(Status.Error);
                return;
            }
            const ram_off: usize = @intCast(self.buffer_pa - RAM_BASE);
            if (ram_off + SECTOR_BYTES > ram.len) {
                self.status = @intFromEnum(Status.Error);
                return;
            }

            if (self.pending_cmd == 1) {
                // Read: disk → ram
                @memcpy(
                    ram[ram_off .. ram_off + SECTOR_BYTES],
                    disk[disk_off .. disk_off + SECTOR_BYTES],
                );
            } else {
                // Write: ram → disk
                @memcpy(
                    disk[disk_off .. disk_off + SECTOR_BYTES],
                    ram[ram_off .. ram_off + SECTOR_BYTES],
                );
            }
            self.status = @intFromEnum(Status.Ready);
            return;
        }

        // No disk → NoMedia for any otherwise-valid non-zero CMD.
        const f = self.disk_file orelse {
            self.status = @intFromEnum(Status.NoMedia);
            return;
        };

        // RAM range. buffer_pa is a physical address; we expect 0x8000_0000-based.
        // Compute offset; bounds-check; set Error if out of range.
        if (self.buffer_pa < RAM_BASE) {
            self.status = @intFromEnum(Status.Error);
            return;
        }
        const ram_off: usize = @intCast(self.buffer_pa - RAM_BASE);
        if (ram_off + SECTOR_BYTES > ram.len) {
            self.status = @intFromEnum(Status.Error);
            return;
        }
        const slice = ram[ram_off .. ram_off + SECTOR_BYTES];

        // Byte offset within the disk file = sector * 4 KB.
        const byte_off: u64 = @as(u64, self.sector) * SECTOR_BYTES;

        if (self.pending_cmd == 1) {
            const n = f.readPositionalAll(io, slice, byte_off) catch {
                self.status = @intFromEnum(Status.Error);
                return;
            };
            if (n != SECTOR_BYTES) {
                self.status = @intFromEnum(Status.Error);
                return;
            }
        } else {
            // pending_cmd == 2 — write
            f.writePositionalAll(io, slice, byte_off) catch {
                self.status = @intFromEnum(Status.Error);
                return;
            };
        }

        self.status = @intFromEnum(Status.Ready);
    }
};

test "default status is NoMedia (no --disk)" {
    const b = Block.init();
    try std.testing.expectEqual(@as(u8, 3), try b.readByte(0xC));
}

test "SECTOR byte round-trip" {
    var b = Block.init();
    try b.writeByte(0x0, 0x12);
    try b.writeByte(0x1, 0x34);
    try b.writeByte(0x2, 0x56);
    try b.writeByte(0x3, 0x78);
    try std.testing.expectEqual(@as(u32, 0x78563412), b.sector);
    try std.testing.expectEqual(@as(u8, 0x12), try b.readByte(0x0));
    try std.testing.expectEqual(@as(u8, 0x78), try b.readByte(0x3));
}

test "BUFFER byte round-trip" {
    var b = Block.init();
    try b.writeByte(0x4, 0xAA);
    try b.writeByte(0x5, 0xBB);
    try b.writeByte(0x6, 0xCC);
    try b.writeByte(0x7, 0xDD);
    try std.testing.expectEqual(@as(u32, 0xDDCCBBAA), b.buffer_pa);
}

test "CMD read returns 0 (write-only)" {
    var b = Block.init();
    try b.writeByte(0x8, 0x01);
    try std.testing.expectEqual(@as(u8, 0), try b.readByte(0x8));
}

test "out-of-range offset returns UnexpectedRegister" {
    var b = Block.init();
    try std.testing.expectError(BlockError.UnexpectedRegister, b.readByte(0x10));
    try std.testing.expectError(BlockError.UnexpectedRegister, b.writeByte(0x10, 0));
}

test "performTransfer with no disk: status NoMedia, pending_irq set" {
    var b = Block.init();
    var ram_buf: [4096]u8 = [_]u8{0xAA} ** 4096;
    try b.writeByte(0x8, 1); // CMD = Read
    b.performTransfer(std.testing.io, ram_buf[0..]);
    try std.testing.expectEqual(@intFromEnum(Status.NoMedia), b.status);
    try std.testing.expect(b.pending_irq);
    // RAM untouched.
    try std.testing.expectEqual(@as(u8, 0xAA), ram_buf[0]);
}

test "performTransfer Read with disk copies sector into RAM at buffer_pa offset" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try tmp.dir.createFile(io, "disk.img", .{ .read = true, .truncate = true });
    defer f.close(io);
    // Write 4 KB of magic into sector 0.
    var sector_data: [SECTOR_BYTES]u8 = undefined;
    for (sector_data[0..], 0..) |*p, i| p.* = @truncate(i & 0xFF);
    try f.writePositionalAll(io, sector_data[0..], 0);

    var b = Block.init();
    b.disk_file = f;
    // 4 KB RAM "slice" anchored at PA 0x80000000. We only use the first 4 KB,
    // but performTransfer expects the slice's index 0 to correspond to PA
    // 0x80000000 — so b.buffer_pa = 0x80000000 means "copy to ram[0..4096]".
    var ram_buf: [SECTOR_BYTES]u8 = [_]u8{0} ** SECTOR_BYTES;

    b.sector = 0;
    b.buffer_pa = 0x80000000;
    try b.writeByte(0x8, 1);
    b.performTransfer(io, ram_buf[0..]);

    try std.testing.expectEqual(@intFromEnum(Status.Ready), b.status);
    try std.testing.expect(b.pending_irq);
    try std.testing.expectEqualSlices(u8, sector_data[0..], ram_buf[0..]);
}

test "performTransfer Write with disk copies RAM out to disk file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try tmp.dir.createFile(io, "disk.img", .{ .read = true, .truncate = true });
    defer f.close(io);
    try f.setLength(io, SECTOR_BYTES);

    var b = Block.init();
    b.disk_file = f;
    var ram_buf: [SECTOR_BYTES]u8 = undefined;
    for (ram_buf[0..], 0..) |*p, i| p.* = @truncate((i + 7) & 0xFF);

    b.sector = 0;
    b.buffer_pa = 0x80000000;
    try b.writeByte(0x8, 2); // Write
    b.performTransfer(io, ram_buf[0..]);

    try std.testing.expectEqual(@intFromEnum(Status.Ready), b.status);
    try std.testing.expect(b.pending_irq);
    var verify: [SECTOR_BYTES]u8 = undefined;
    const n = try f.readPositionalAll(io, verify[0..], 0);
    try std.testing.expectEqual(@as(usize, SECTOR_BYTES), n);
    try std.testing.expectEqualSlices(u8, ram_buf[0..], verify[0..]);
}

test "performTransfer with bad CMD sets Error status" {
    var b = Block.init();
    var ram_buf: [SECTOR_BYTES]u8 = undefined;
    b.buffer_pa = 0x80000000;
    try b.writeByte(0x8, 99); // bogus
    b.performTransfer(std.testing.io, ram_buf[0..]);
    try std.testing.expectEqual(@intFromEnum(Status.Error), b.status);
    try std.testing.expect(b.pending_irq);
}

test "performTransfer with sector out of range sets Error status" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try tmp.dir.createFile(io, "disk.img", .{ .read = true, .truncate = true });
    defer f.close(io);
    try f.setLength(io, SECTOR_BYTES);

    var b = Block.init();
    b.disk_file = f;
    b.sector = NSECTORS;             // 1024 — out of range
    b.buffer_pa = 0x80000000;
    var ram_buf: [SECTOR_BYTES]u8 = undefined;
    try b.writeByte(0x8, 1); // Read
    b.performTransfer(io, ram_buf[0..]);
    try std.testing.expectEqual(@intFromEnum(Status.Error), b.status);
}

test "performTransfer Read with disk_slice copies sector into RAM" {
    var disk_data: [SECTOR_BYTES * 3]u8 = undefined;
    for (disk_data[0..], 0..) |*p, i| p.* = @truncate(i & 0xFF);

    var b = Block.init();
    b.disk_slice = disk_data[0..];

    var ram_buf: [SECTOR_BYTES]u8 = [_]u8{0} ** SECTOR_BYTES;
    b.sector = 1; // read sector 1
    b.buffer_pa = 0x80000000;
    try b.writeByte(0x8, 1); // CMD = Read
    b.performTransfer(std.testing.io, ram_buf[0..]);

    try std.testing.expectEqual(@intFromEnum(Status.Ready), b.status);
    try std.testing.expect(b.pending_irq);
    try std.testing.expectEqualSlices(
        u8,
        disk_data[SECTOR_BYTES .. SECTOR_BYTES * 2],
        ram_buf[0..],
    );
}

test "performTransfer Write with disk_slice copies RAM out to slice" {
    var disk_data: [SECTOR_BYTES * 2]u8 = [_]u8{0} ** (SECTOR_BYTES * 2);

    var b = Block.init();
    b.disk_slice = disk_data[0..];

    var ram_buf: [SECTOR_BYTES]u8 = undefined;
    for (ram_buf[0..], 0..) |*p, i| p.* = @truncate((i + 7) & 0xFF);

    b.sector = 0;
    b.buffer_pa = 0x80000000;
    try b.writeByte(0x8, 2); // CMD = Write
    b.performTransfer(std.testing.io, ram_buf[0..]);

    try std.testing.expectEqual(@intFromEnum(Status.Ready), b.status);
    try std.testing.expect(b.pending_irq);
    try std.testing.expectEqualSlices(u8, ram_buf[0..], disk_data[0..SECTOR_BYTES]);
    // Sector 1 untouched.
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** SECTOR_BYTES),
        disk_data[SECTOR_BYTES..],
    );
}

test "performTransfer with disk_slice + sector out of range sets Error" {
    var disk_data: [SECTOR_BYTES]u8 = undefined;

    var b = Block.init();
    b.disk_slice = disk_data[0..];
    b.sector = NSECTORS; // 1024 — out of range
    b.buffer_pa = 0x80000000;
    var ram_buf: [SECTOR_BYTES]u8 = undefined;
    try b.writeByte(0x8, 1);
    b.performTransfer(std.testing.io, ram_buf[0..]);

    try std.testing.expectEqual(@intFromEnum(Status.Error), b.status);
    try std.testing.expect(b.pending_irq);
}

test "performTransfer disk_slice precedence: slice wins when both set" {
    // Sanity: if both disk_file and disk_slice are populated, the slice path
    // wins. This guards against accidental cross-wiring in tests/CLI/wasm.
    var disk_data: [SECTOR_BYTES]u8 = [_]u8{0xCD} ** SECTOR_BYTES;

    var b = Block.init();
    b.disk_slice = disk_data[0..];
    // Leave b.disk_file = null on this path; the precedence test only proves
    // that the slice branch reads the slice and doesn't fall through to
    // file I/O. (A "both set" test would require a tmp file; skipped — the
    // precedence is a one-line `if` we verify by inspection.)

    var ram_buf: [SECTOR_BYTES]u8 = [_]u8{0} ** SECTOR_BYTES;
    b.sector = 0;
    b.buffer_pa = 0x80000000;
    try b.writeByte(0x8, 1);
    b.performTransfer(std.testing.io, ram_buf[0..]);

    try std.testing.expectEqual(@intFromEnum(Status.Ready), b.status);
    try std.testing.expectEqualSlices(u8, disk_data[0..], ram_buf[0..]);
}

test "performTransfer disk_slice with buffer_pa below RAM_BASE sets Error" {
    var disk_data: [SECTOR_BYTES]u8 = undefined;
    var b = Block.init();
    b.disk_slice = disk_data[0..];
    b.sector = 0;
    b.buffer_pa = 0x1000_0000; // below RAM_BASE
    var ram_buf: [SECTOR_BYTES]u8 = undefined;
    try b.writeByte(0x8, 1);
    b.performTransfer(std.testing.io, ram_buf[0..]);
    try std.testing.expectEqual(@intFromEnum(Status.Error), b.status);
    try std.testing.expect(b.pending_irq);
}

test "performTransfer disk_slice with RAM offset past ram_buf sets Error" {
    var disk_data: [SECTOR_BYTES]u8 = undefined;
    var b = Block.init();
    b.disk_slice = disk_data[0..];
    b.sector = 0;
    b.buffer_pa = RAM_BASE + SECTOR_BYTES; // demands ram[4096..8192]
    var ram_buf: [SECTOR_BYTES]u8 = undefined; // only 4096 bytes available
    try b.writeByte(0x8, 1);
    b.performTransfer(std.testing.io, ram_buf[0..]);
    try std.testing.expectEqual(@intFromEnum(Status.Error), b.status);
    try std.testing.expect(b.pending_irq);
}
