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
const uart = @import("uart.zig");
const proc = @import("proc.zig");
const page_alloc = @import("page_alloc.zig");
const vm = @import("vm.zig");
const file = @import("file.zig");
const inode = @import("fs/inode.zig");
const path_mod = @import("fs/path.zig");
const layout = @import("fs/layout.zig");

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

fn sysWrite(fd: u32, buf_va: u32, len: u32) u32 {
    if (fd != 1 and fd != 2) {
        return @bitCast(@as(i32, -9)); // -EBADF
    }
    setSum();
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const p: *const volatile u8 = @ptrFromInt(buf_va + i);
        uart.writeByte(p.*);
    }
    clearSum();
    return len;
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

/// 56 openat(dirfd, path, flags) — 3.D ignores dirfd and flags
/// (read-only existing file). Returns fd ≥ 0 or -1.
fn sysOpenat(dirfd: u32, path_user_va: u32, flags: u32) i32 {
    _ = dirfd;
    _ = flags;

    var pbuf: [path_mod.MAX_PATH]u8 = undefined;
    const p = copyStrFromUser(path_user_va, &pbuf) orelse return -1;

    const ip = path_mod.namei(p) orelse return -1;

    const fidx = file.alloc() orelse {
        inode.iput(ip);
        return -1;
    };
    file.ftable[fidx].type = .Inode;
    file.ftable[fidx].ip = ip;
    file.ftable[fidx].off = 0;

    // Allocate the lowest free fd in cur.ofile.
    const cur_p = proc.cur();
    var fd: u32 = 0;
    while (fd < proc.NOFILE) : (fd += 1) {
        if (cur_p.ofile[fd] == 0) {
            cur_p.ofile[fd] = fidx;
            return @intCast(fd);
        }
    }

    // No free fd — release the file table entry + inode.
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

/// 5000 set_fg_pid: shell-only API for telling the console what process
/// `^C` should target. 3.C accepts and discards; 3.E (when the console
/// line discipline lands) wires this to the actual fg_pid global.
fn sysSetFgPid(pid: u32) u32 {
    _ = pid;
    return 0;
}

/// 5001 console_set_mode: editor-only API for switching cooked vs raw
/// line discipline. 3.C accepts and discards; 3.E wires this to the
/// console state machine.
fn sysConsoleSetMode(mode: u32) u32 {
    _ = mode;
    return 0;
}

pub fn dispatch(tf: *trap.TrapFrame) void {
    switch (tf.a7) {
        56 => tf.a0 = @bitCast(sysOpenat(tf.a0, tf.a1, tf.a2)),
        57 => tf.a0 = @bitCast(sysClose(tf.a0)),
        62 => tf.a0 = @bitCast(sysLseek(tf.a0, tf.a1, tf.a2)),
        63 => tf.a0 = @bitCast(sysRead(tf.a0, tf.a1, tf.a2)),
        64 => tf.a0 = sysWrite(tf.a0, tf.a1, tf.a2),
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
}
