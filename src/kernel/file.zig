// src/kernel/file.zig — Phase 3.D file table.
//
// NFILE=64 ref-counted "open file" records. Slot 0 is reserved as the
// "null" sentinel — proc.ofile[fd] == 0 means "fd is closed".
//
// 3.D supports type=.Inode only; 3.E adds type=.Console for fd 0/1/2
// when the line discipline lands.
//
// API:
//   init():       zero the table.
//   alloc():      claim the lowest free slot (refs becomes 1); ?u32 idx.
//   dup(idx):     refs += 1; return idx.
//   close(idx):   refs -= 1; on zero, iput(ip) + zero the slot.
//   read(...):    ilock + readi + iunlock + SUM-1 copy to user; bumps off.
//   lseek(...):   update off; whence 0=SET, 1=CUR, 2=END.
//   fstat(...):   write Stat { type, size } to user (8 bytes, SUM=1).

const std = @import("std");
const inode = @import("fs/inode.zig");
const proc = @import("proc.zig");
const layout = @import("fs/layout.zig");
const console = @import("console.zig");

pub const NFILE: u32 = 64;
const READ_CHUNK: u32 = 4096;

pub const FileType = enum(u32) { None = 0, Inode = 1, Console = 2 };

pub const File = struct {
    type: FileType,
    ref_count: u32,
    ip: ?*inode.InMemInode,
    off: u32,
};

pub var ftable: [NFILE]File = undefined;

pub const Stat = extern struct {
    type: u32, // FileType cast to u32
    size: u32,
};

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

pub fn init() void {
    var i: u32 = 0;
    while (i < NFILE) : (i += 1) {
        ftable[i].type = .None;
        ftable[i].ref_count = 0;
        ftable[i].ip = null;
        ftable[i].off = 0;
    }
}

/// Returns the index of the newly allocated slot (≥ 1), or null if full.
pub fn alloc() ?u32 {
    var i: u32 = 1; // slot 0 reserved as "null"
    while (i < NFILE) : (i += 1) {
        if (ftable[i].ref_count == 0) {
            ftable[i].ref_count = 1;
            return i;
        }
    }
    return null;
}

pub fn dup(idx: u32) u32 {
    ftable[idx].ref_count += 1;
    return idx;
}

pub fn close(idx: u32) void {
    if (idx == 0 or idx >= NFILE) return;
    const f = &ftable[idx];
    if (f.ref_count == 0) return;
    f.ref_count -= 1;
    if (f.ref_count == 0) {
        if (f.type == .Inode and f.ip != null) {
            inode.iput(f.ip.?);
        }
        f.* = .{ .type = .None, .ref_count = 0, .ip = null, .off = 0 };
    }
}

// Static staging buffer for file.read. Stack-allocating a 4 KB array would
// blow the per-process kernel stack (one 4 KB page) plus the trap-handler
// + syscall-dispatch + readi + bread frames. Single-threaded kernel ⇒ safe
// to share globally.
var read_kbuf: [READ_CHUNK]u8 align(4) = undefined;

/// Read up to n bytes from f into the user buffer at dst_user_va.
/// Returns bytes copied (0 on EOF, -1 on error).
pub fn read(idx: u32, dst_user_va: u32, n: u32) i32 {
    if (idx == 0 or idx >= NFILE) return -1;
    const f = &ftable[idx];

    if (f.type == .Console) {
        return console.read(dst_user_va, n);
    }

    if (f.type != .Inode or f.ip == null) return -1;

    const want = if (n > READ_CHUNK) READ_CHUNK else n;

    inode.ilock(f.ip.?);
    const got = inode.readi(f.ip.?, &read_kbuf, f.off, want);
    inode.iunlock(f.ip.?);

    if (got > 0) {
        setSum();
        var i: u32 = 0;
        while (i < got) : (i += 1) {
            const dst: *volatile u8 = @ptrFromInt(dst_user_va + i);
            dst.* = read_kbuf[i];
        }
        clearSum();
        f.off += got;
    }
    return @intCast(got);
}

// Static staging buffer for file.write inode path (Task 12 fills in writei).
var write_kbuf: [4096]u8 align(4) = undefined;

/// Write up to `n` bytes from user VA `src_user_va` to file `idx`.
/// Returns bytes written (≥ 0) or -1 on bad fd.
pub fn write(idx: u32, src_user_va: u32, n: u32) i32 {
    if (idx == 0 or idx >= NFILE) return -1;
    const f = &ftable[idx];

    if (f.type == .Console) {
        return console.write(src_user_va, n);
    }

    if (f.type != .Inode or f.ip == null) return -1;

    const want = if (n > write_kbuf.len) write_kbuf.len else n;

    // SUM-1 copy from user into kernel staging buffer.
    setSum();
    var i: u32 = 0;
    while (i < want) : (i += 1) {
        const src_p: *const volatile u8 = @ptrFromInt(src_user_va + i);
        write_kbuf[i] = src_p.*;
    }
    clearSum();

    inode.ilock(f.ip.?);
    const wrote = inode.writei(f.ip.?, &write_kbuf, f.off, @intCast(want));
    inode.iunlock(f.ip.?);

    if (wrote > 0) f.off += @intCast(wrote);
    return wrote;
}

pub fn lseek(idx: u32, off: i32, whence: u32) i32 {
    if (idx == 0 or idx >= NFILE) return -1;
    const f = &ftable[idx];
    if (f.type == .Console) return -1; // not seekable
    if (f.type != .Inode or f.ip == null) return -1;

    const new_off: i64 = switch (whence) {
        0 => off, // SEEK_SET
        1 => @as(i64, @intCast(f.off)) + off,
        2 => blk: {
            inode.ilock(f.ip.?);
            const sz = f.ip.?.dinode.size;
            inode.iunlock(f.ip.?);
            break :blk @as(i64, @intCast(sz)) + off;
        },
        else => return -1,
    };
    if (new_off < 0) return -1;
    if (new_off > 0xFFFF_FFFF) return -1;
    f.off = @intCast(new_off);
    return @intCast(f.off);
}

pub fn fstat(idx: u32, stat_user_va: u32) i32 {
    if (idx == 0 or idx >= NFILE) return -1;
    const f = &ftable[idx];
    if (f.type == .Console) {
        const stat: Stat = .{ .type = @intFromEnum(layout.FileType.File), .size = 0 };
        setSum();
        const dst: *volatile Stat = @ptrFromInt(stat_user_va);
        dst.* = stat;
        clearSum();
        return 0;
    }
    if (f.type != .Inode or f.ip == null) return -1;

    inode.ilock(f.ip.?);
    const stat: Stat = .{
        .type = @intFromEnum(f.ip.?.dinode.type),
        .size = f.ip.?.dinode.size,
    };
    inode.iunlock(f.ip.?);

    setSum();
    const dst: *volatile Stat = @ptrFromInt(stat_user_va);
    dst.* = stat;
    clearSum();
    return 0;
}
