// src/kernel/user/lib/ulib.zig — Phase 3.E userspace standard library.
//
// All the boilerplate every user binary needs: mem*/str* helpers, syscall
// extern declarations (defined in usys.S), Stat layout, O_* flag bits,
// and a one-byte-at-a-time getline helper.

pub fn strlen(s: [*:0]const u8) u32 {
    var n: u32 = 0;
    while (s[n] != 0) : (n += 1) {}
    return n;
}

pub fn strcmp(a: [*:0]const u8, b: [*:0]const u8) i32 {
    var i: u32 = 0;
    while (a[i] != 0 and b[i] != 0 and a[i] == b[i]) : (i += 1) {}
    return @as(i32, a[i]) - @as(i32, b[i]);
}

pub fn strncmp(a: [*]const u8, b: [*]const u8, n: u32) i32 {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return @as(i32, a[i]) - @as(i32, b[i]);
    }
    return 0;
}

pub fn memmove(dst: [*]u8, src: [*]const u8, n: u32) void {
    if (@intFromPtr(dst) < @intFromPtr(src)) {
        var i: u32 = 0;
        while (i < n) : (i += 1) dst[i] = src[i];
    } else {
        var i: u32 = n;
        while (i > 0) {
            i -= 1;
            dst[i] = src[i];
        }
    }
}

pub fn memset(dst: [*]u8, c: u8, n: u32) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) dst[i] = c;
}

pub fn memcmp(a: [*]const u8, b: [*]const u8, n: u32) i32 {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return @as(i32, a[i]) - @as(i32, b[i]);
    }
    return 0;
}

pub fn atoi(s: [*:0]const u8) i32 {
    var i: u32 = 0;
    var sign: i32 = 1;
    if (s[0] == '-') {
        sign = -1;
        i = 1;
    }
    var n: i32 = 0;
    while (s[i] >= '0' and s[i] <= '9') : (i += 1) {
        n = n * 10 + @as(i32, s[i] - '0');
    }
    return sign * n;
}

/// Read a line from `fd` into `buf`. Returns bytes read (incl. trailing `\n`
/// if present), or 0 on EOF, or -1 on error.
pub fn getline(fd: u32, buf: [*]u8, max: u32) i32 {
    var n: u32 = 0;
    while (n < max) {
        const got = read(fd, buf + n, 1);
        if (got <= 0) return if (n == 0) got else @intCast(n);
        const c = buf[n];
        n += 1;
        if (c == '\n') return @intCast(n);
    }
    return @intCast(n);
}

// Syscall stubs (defined in usys.S — link-time symbols).
pub extern fn read(fd: u32, buf: [*]u8, n: u32) i32;
pub extern fn write(fd: u32, buf: [*]const u8, n: u32) i32;
pub extern fn close(fd: u32) i32;
pub extern fn openat(dirfd: u32, path: [*:0]const u8, flags: u32) i32;
pub extern fn lseek(fd: u32, off: i32, whence: u32) i32;
pub extern fn fstat(fd: u32, st: *Stat) i32;
pub extern fn mkdirat(dirfd: u32, path: [*:0]const u8) i32;
pub extern fn unlinkat(dirfd: u32, path: [*:0]const u8, flags: u32) i32;
pub extern fn chdir(path: [*:0]const u8) i32;
pub extern fn getcwd(buf: [*]u8, sz: u32) i32;
pub extern fn fork() i32;
pub extern fn exec(path: [*:0]const u8, argv: [*]const ?[*:0]const u8) i32;
pub extern fn wait(status: ?*i32) i32;
pub extern fn exit(status: i32) noreturn;
pub extern fn getpid() u32;
pub extern fn yield() u32;
pub extern fn sbrk(incr: i32) i32;
pub extern fn set_fg_pid(pid: u32) u32;
pub extern fn console_set_mode(mode: u32) u32;

// Stat layout — must match kernel file.zig::Stat.
pub const Stat = extern struct {
    type: u32,
    size: u32,
};

pub const STAT_FILE: u32 = 1;
pub const STAT_DIR: u32 = 2;

// Flag bits — must match kernel syscall.zig.
pub const O_RDONLY: u32 = 0x000;
pub const O_WRONLY: u32 = 0x001;
pub const O_RDWR: u32 = 0x002;
pub const O_CREAT: u32 = 0x040;
pub const O_TRUNC: u32 = 0x200;
pub const O_APPEND: u32 = 0x400;

// Console modes — must match kernel console.zig.
pub const CONSOLE_COOKED: u32 = 0;
pub const CONSOLE_RAW: u32 = 1;
