// src/kernel/syscall.zig — Phase 3.B syscall table.
//
// Syscalls dispatched in Phase 3.B:
//   - 64  (write): copies user bytes to UART via SSTATUS.SUM.
//   - 93  (exit):  delegates to proc.exit (reparent + zombie + wake parent;
//                  PID 1 also prints "ticks observed: N\n" and halts).
//   - 124 (yield): calls proc.yield() to voluntarily relinquish the CPU.
//
// proc.cur() is used for any per-process state reads (currently always
// &ptable[0] until Task 9 wires in a real CPU-local picker). Future
// tasks add syscall 172 (getpid) and 214 (sbrk).
//
// ABI unchanged: a7 = syscall number, a0..a5 = args, a0 = return.

const trap = @import("trap.zig");
const proc = @import("proc.zig");
const page_alloc = @import("page_alloc.zig");
const vm = @import("vm.zig");
const file = @import("file.zig");
const console = @import("console.zig");
const inode = @import("fs/inode.zig");
const path_mod = @import("fs/path.zig");
const fsops = @import("fs/fsops.zig");
const layout = @import("fs/layout.zig");

pub const O_RDONLY: u32 = 0x000;
pub const O_WRONLY: u32 = 0x001;
pub const O_RDWR:   u32 = 0x002;
pub const O_CREAT:  u32 = 0x040;
pub const O_TRUNC:  u32 = 0x200;
pub const O_APPEND: u32 = 0x400;

const SSTATUS_SUM: u32 = 1 << 18;

fn setSum() void {
    asm volatile ("csrs sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SUM),
        : .{ .memory = true });
}

fn clearSum() void {
    asm volatile ("csrc sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SUM),
        : .{ .memory = true });
}

/// Copy a NUL-terminated user string into `buf`. Returns the slice up
/// to (but not including) the NUL, or null on overflow / no NUL within
/// buf.len bytes.
fn copyStrFromUser(user_va: u32, buf: []u8) ?[]u8 {
    setSum();
    defer clearSum();
    var i: u32 = 0;
    while (i < buf.len) : (i += 1) {
        const p: *const volatile u8 = @ptrFromInt(user_va + i);
        const c = p.*;
        buf[i] = c;
        if (c == 0) return buf[0..i];
    }
    return null;
}

fn sysWrite(fd: u32, buf_va: u32, len: u32) i32 {
    if (fd >= proc.NOFILE) return -1;
    const idx = proc.cur().ofile[fd];
    if (idx == 0) return -1;
    return file.write(idx, buf_va, len);
}

pub fn sysExit(status: u32) noreturn {
    proc.exit(@bitCast(status));
}

fn sysYield() u32 {
    proc.yield();
    return 0;
}

fn sysGetpid() u32 {
    return proc.cur().pid;
}

fn sysSbrk(incr_signed: u32) u32 {
    const incr: i32 = @bitCast(incr_signed);
    const p = proc.cur();
    const old_sz = p.sz;

    if (incr > 0) {
        const new_sz = old_sz + @as(u32, @intCast(incr));
        const PAGE_SIZE: u32 = 4096;
        const old_top = (old_sz + PAGE_SIZE - 1) & ~@as(u32, PAGE_SIZE - 1);
        const new_top = (new_sz + PAGE_SIZE - 1) & ~@as(u32, PAGE_SIZE - 1);
        var va: u32 = old_top;
        while (va < new_top) : (va += PAGE_SIZE) {
            const pa = page_alloc.alloc() orelse return @bitCast(@as(i32, -12)); // -ENOMEM
            vm.mapPage(p.pgdir, va, pa, vm.USER_RW);
        }
        p.sz = new_sz;
    } else if (incr < 0) {
        // 3.B accepts but doesn't unmap. 3.E will properly unmap and free.
        const dec: u32 = @intCast(-incr);
        if (dec > old_sz) return @bitCast(@as(i32, -22)); // -EINVAL
        p.sz = old_sz - dec;
    }
    return old_sz;
}

/// 56 openat(dirfd, path, flags) — handles O_CREAT, O_TRUNC, O_APPEND.
/// Returns fd ≥ 0 or -1.
fn sysOpenat(dirfd: u32, path_user_va: u32, flags: u32) i32 {
    _ = dirfd;

    var pbuf: [path_mod.MAX_PATH]u8 = undefined;
    const p = copyStrFromUser(path_user_va, &pbuf) orelse return -1;

    // Resolve, or O_CREAT a new file.
    const ip = path_mod.namei(p) orelse blk: {
        if ((flags & O_CREAT) == 0) return -1;
        break :blk fsops.create(p, .File) orelse return -1;
    };

    // O_TRUNC on a regular file: free all data blocks, reset size to 0.
    if ((flags & O_TRUNC) != 0) {
        inode.ilock(ip);
        if (ip.dinode.type == .File) inode.itrunc(ip);
        inode.iunlock(ip);
    }

    const fidx = file.alloc() orelse {
        inode.iput(ip);
        return -1;
    };
    file.ftable[fidx].type = .Inode;
    file.ftable[fidx].ip = ip;

    // O_APPEND: seek to EOF.
    if ((flags & O_APPEND) != 0) {
        inode.ilock(ip);
        file.ftable[fidx].off = ip.dinode.size;
        inode.iunlock(ip);
    } else {
        file.ftable[fidx].off = 0;
    }

    const cur_p = proc.cur();
    var fd: u32 = 0;
    while (fd < proc.NOFILE) : (fd += 1) {
        if (cur_p.ofile[fd] == 0) {
            cur_p.ofile[fd] = fidx;
            return @intCast(fd);
        }
    }
    file.close(fidx);
    return -1;
}

/// 57 close(fd) — release the fd. Returns 0 / -1.
fn sysClose(fd: u32) i32 {
    if (fd >= proc.NOFILE) return -1;
    const cur_p = proc.cur();
    if (cur_p.ofile[fd] == 0) return -1;
    file.close(cur_p.ofile[fd]);
    cur_p.ofile[fd] = 0;
    return 0;
}

/// 63 read(fd, buf, n). Returns bytes / 0 (EOF) / -1.
fn sysRead(fd: u32, buf_user_va: u32, n: u32) i32 {
    if (fd >= proc.NOFILE) return -1;
    const idx = proc.cur().ofile[fd];
    if (idx == 0) return -1;
    return file.read(idx, buf_user_va, n);
}

/// 62 lseek(fd, off, whence). Returns new offset / -1.
fn sysLseek(fd: u32, off_signed: u32, whence: u32) i32 {
    if (fd >= proc.NOFILE) return -1;
    const idx = proc.cur().ofile[fd];
    if (idx == 0) return -1;
    const off: i32 = @bitCast(off_signed);
    return file.lseek(idx, off, whence);
}

/// 80 fstat(fd, statbuf). Writes Stat { type, size } (8 bytes) via SUM=1.
/// Returns 0 / -1.
fn sysFstat(fd: u32, stat_user_va: u32) i32 {
    if (fd >= proc.NOFILE) return -1;
    const idx = proc.cur().ofile[fd];
    if (idx == 0) return -1;
    return file.fstat(idx, stat_user_va);
}

/// Compose a new cwd_path given the current cwd_path and a relative or
/// absolute target. Writes into `out` (NUL-terminated). Returns the
/// length of the resulting path (excluding NUL) or null on overflow.
///
/// 3.D simplification: no cycle / `..` resolution beyond the spec
/// (`..` past root resolves to root, handled by the FS layer; the
/// path-string composition here just normalizes "/" boundaries).
fn composeCwdPath(old: []const u8, target: []const u8, out: *[proc.CWD_PATH_MAX]u8) ?u32 {
    var len: u32 = 0;
    if (target.len > 0 and target[0] == '/') {
        // Absolute: ignore old.
        // Copy target verbatim (caller guarantees ≤ CWD_PATH_MAX-1 via path bounds).
        if (target.len + 1 > proc.CWD_PATH_MAX) return null;
        var i: u32 = 0;
        while (i < target.len) : (i += 1) out[i] = target[i];
        out[target.len] = 0;
        return @intCast(target.len);
    }

    // Relative: append target to old, with a separator.
    var i: u32 = 0;
    while (i < old.len) : (i += 1) {
        if (len >= proc.CWD_PATH_MAX) return null;
        out[len] = old[i];
        len += 1;
    }
    if (len > 0 and out[len - 1] != '/') {
        if (len >= proc.CWD_PATH_MAX) return null;
        out[len] = '/';
        len += 1;
    }
    var j: u32 = 0;
    while (j < target.len) : (j += 1) {
        if (len >= proc.CWD_PATH_MAX) return null;
        out[len] = target[j];
        len += 1;
    }
    if (len >= proc.CWD_PATH_MAX) return null;
    out[len] = 0;
    return len;
}

/// 49 chdir(path). namei → verify Dir → swap cwd. Returns 0 / -1.
fn sysChdir(path_user_va: u32) i32 {
    var pbuf: [path_mod.MAX_PATH]u8 = undefined;
    const p = copyStrFromUser(path_user_va, &pbuf) orelse return -1;

    const ip = path_mod.namei(p) orelse return -1;
    inode.ilock(ip);
    if (ip.dinode.type != .Dir) {
        inode.iunlock(ip);
        inode.iput(ip);
        return -1;
    }
    inode.iunlock(ip);

    // Compose new cwd_path; on overflow, restore old cwd.
    const cur_p = proc.cur();
    var new_path: [proc.CWD_PATH_MAX]u8 = undefined;
    const old_path_len: u32 = blk: {
        var k: u32 = 0;
        while (k < proc.CWD_PATH_MAX and cur_p.cwd_path[k] != 0) : (k += 1) {}
        break :blk k;
    };
    _ = composeCwdPath(cur_p.cwd_path[0..old_path_len], p, &new_path) orelse {
        inode.iput(ip);
        return -1;
    };

    // Commit: iput old cwd, install new.
    if (cur_p.cwd != 0) {
        const old_ip: *inode.InMemInode = @ptrFromInt(cur_p.cwd);
        inode.iput(old_ip);
    }
    cur_p.cwd = @intFromPtr(ip);
    @memcpy(&cur_p.cwd_path, &new_path);
    return 0;
}

/// 17 getcwd(buf, sz). Copies cwd_path into the user buffer (with NUL).
/// Returns bytes copied (excluding NUL) or -1 on size-too-small.
fn sysGetcwd(buf_user_va: u32, sz: u32) i32 {
    const cur_p = proc.cur();

    // Determine length of cwd_path (NUL-terminated).
    var len: u32 = 0;
    while (len < proc.CWD_PATH_MAX and cur_p.cwd_path[len] != 0) : (len += 1) {}

    // Lazy-root: empty cwd_path means "/".
    const src: []const u8 = if (len == 0) "/" else cur_p.cwd_path[0..len];

    if (sz < src.len + 1) return -1; // need room for NUL

    setSum();
    var i: u32 = 0;
    while (i < src.len) : (i += 1) {
        const dst: *volatile u8 = @ptrFromInt(buf_user_va + i);
        dst.* = src[i];
    }
    const dst_nul: *volatile u8 = @ptrFromInt(buf_user_va + src.len);
    dst_nul.* = 0;
    clearSum();
    return @intCast(src.len);
}

/// 5000 set_fg_pid: shell-only API for telling the console what process
/// `^C` should target. 3.C accepts and discards; 3.E (when the console
/// line discipline lands) wires this to the actual fg_pid global.
fn sysSetFgPid(pid: u32) u32 {
    console.setFgPid(pid);
    return 0;
}

/// 5001 console_set_mode: editor-only API for switching cooked vs raw
/// line discipline. 3.C accepts and discards; 3.E wires this to the
/// console state machine.
fn sysConsoleSetMode(mode: u32) u32 {
    console.setMode(mode);
    return 0;
}

pub fn dispatch(tf: *trap.TrapFrame) void {
    switch (tf.a7) {
        17 => tf.a0 = @bitCast(sysGetcwd(tf.a0, tf.a1)),
        49 => tf.a0 = @bitCast(sysChdir(tf.a0)),
        56 => tf.a0 = @bitCast(sysOpenat(tf.a0, tf.a1, tf.a2)),
        57 => tf.a0 = @bitCast(sysClose(tf.a0)),
        62 => tf.a0 = @bitCast(sysLseek(tf.a0, tf.a1, tf.a2)),
        63 => tf.a0 = @bitCast(sysRead(tf.a0, tf.a1, tf.a2)),
        64 => tf.a0 = @bitCast(sysWrite(tf.a0, tf.a1, tf.a2)),
        80 => tf.a0 = @bitCast(sysFstat(tf.a0, tf.a1)),
        93 => sysExit(tf.a0),
        124 => tf.a0 = sysYield(),
        172 => tf.a0 = sysGetpid(),
        214 => tf.a0 = sysSbrk(tf.a0),
        220 => tf.a0 = @bitCast(proc.fork()),
        221 => tf.a0 = @bitCast(proc.exec(tf.a0, tf.a1)),
        260 => tf.a0 = @bitCast(proc.wait(tf.a1)),
        5000 => tf.a0 = sysSetFgPid(tf.a0),
        5001 => tf.a0 = sysConsoleSetMode(tf.a0),
        else => tf.a0 = @bitCast(@as(i32, -38)), // -ENOSYS
    }

    // Phase 3.E: if the process was killed (e.g. by ^C while sleeping
    // in this syscall), exit on the way back to user instead of returning.
    if (proc.cur().killed != 0) {
        proc.exit(-1);
    }
}
