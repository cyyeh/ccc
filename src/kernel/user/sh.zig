// src/kernel/user/sh.zig — Phase 3.E shell.
//
// Loop:
//   - Print "$ " prompt to fd 1.
//   - Read a line from fd 0 (terminated by \n thanks to the kernel
//     console line discipline).
//   - Tokenize on whitespace; recognize `<`, `>`, `>>` as redirect tokens.
//   - If first token is `cd` / `pwd` / `exit`, handle inline.
//   - Else: fork; in child, apply redirects (close target fd, open file at
//     same fd via openat which returns lowest free fd — we close-then-open
//     to land at the target fd); exec the binary. In parent, set_fg_pid
//     (child), wait, set_fg_pid(0).
//
// Exec path resolution: if argv[0] starts with "/", use as-is. Else prepend
// "/bin/" so `ls` becomes `/bin/ls`.

const ulib = @import("lib/ulib.zig");
const uprintf = @import("lib/uprintf.zig");

const LINE_MAX: u32 = 256;
const MAX_TOKENS: u32 = 32;
const PATH_MAX: u32 = 256;

var line_buf: [LINE_MAX]u8 = undefined;
var argv_storage: [MAX_TOKENS][PATH_MAX]u8 = undefined;
var argv_ptrs: [MAX_TOKENS + 1]?[*:0]const u8 = undefined;
var path_buf: [PATH_MAX]u8 = undefined;

const RedirectKind = enum { None, In, Out, Append };

const ParsedCmd = struct {
    argc: u32,
    redir_kind: RedirectKind,
    redir_target: ?[*:0]const u8,
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

fn isRedirChar(c: u8) bool {
    return c == '<' or c == '>';
}

/// Tokenize `line` (NUL-terminated, length n) into argv_storage + parse a
/// single redirect (if any). Returns the parsed result. argc is the count
/// of "real" argv tokens (not including the redirect file).
fn parseLine(line: [*]const u8, n: u32) ParsedCmd {
    var i: u32 = 0;
    var argc: u32 = 0;
    var result: ParsedCmd = .{ .argc = 0, .redir_kind = .None, .redir_target = null };

    while (i < n) {
        // Skip whitespace.
        while (i < n and isSpace(line[i])) : (i += 1) {}
        if (i >= n) break;

        // Redirect?
        if (isRedirChar(line[i])) {
            var kind: RedirectKind = .Out;
            if (line[i] == '<') kind = .In;
            i += 1;
            if (kind == .Out and i < n and line[i] == '>') {
                kind = .Append;
                i += 1;
            }
            // Skip whitespace, then capture target.
            while (i < n and isSpace(line[i])) : (i += 1) {}
            const target_start = i;
            while (i < n and !isSpace(line[i]) and !isRedirChar(line[i])) : (i += 1) {}
            const target_len = i - target_start;
            if (target_len == 0 or target_len >= PATH_MAX) {
                uprintf.printf(2, "sh: missing redirect target\n", &.{});
                return .{ .argc = 0, .redir_kind = .None, .redir_target = null };
            }
            // Stash target into the last argv slot (we won't pass it to exec).
            const slot = MAX_TOKENS - 1;
            var k: u32 = 0;
            while (k < target_len) : (k += 1) argv_storage[slot][k] = line[target_start + k];
            argv_storage[slot][target_len] = 0;
            result.redir_kind = kind;
            result.redir_target = @ptrCast(&argv_storage[slot][0]);
            continue;
        }

        // Plain token.
        if (argc >= MAX_TOKENS - 1) {
            uprintf.printf(2, "sh: too many args\n", &.{});
            return .{ .argc = 0, .redir_kind = .None, .redir_target = null };
        }
        const start = i;
        while (i < n and !isSpace(line[i]) and !isRedirChar(line[i])) : (i += 1) {}
        const tok_len = i - start;
        if (tok_len >= PATH_MAX) {
            uprintf.printf(2, "sh: token too long\n", &.{});
            return .{ .argc = 0, .redir_kind = .None, .redir_target = null };
        }
        var k: u32 = 0;
        while (k < tok_len) : (k += 1) argv_storage[argc][k] = line[start + k];
        argv_storage[argc][tok_len] = 0;
        argv_ptrs[argc] = @ptrCast(&argv_storage[argc][0]);
        argc += 1;
    }

    argv_ptrs[argc] = null;
    result.argc = argc;
    return result;
}

/// Resolve the binary path: if argv[0] starts with "/", use as-is; else
/// prepend "/bin/". Writes the result into `path_buf` (NUL-terminated).
fn resolveBin(name: [*:0]const u8) [*:0]const u8 {
    if (name[0] == '/') return name;
    var i: u32 = 0;
    const prefix = "/bin/";
    while (i < prefix.len) : (i += 1) path_buf[i] = prefix[i];
    var j: u32 = 0;
    while (name[j] != 0 and i + j + 1 < PATH_MAX) : (j += 1) path_buf[i + j] = name[j];
    path_buf[i + j] = 0;
    return @ptrCast(&path_buf[0]);
}

fn doRedirect(kind: RedirectKind, target: [*:0]const u8) bool {
    // dirfd=0 in the openat calls below is a sentinel: sysOpenat ignores
    // dirfd entirely in Phase 3.E (paths resolve from cwd unconditionally).
    // If dirfd ever becomes meaningful, pass an explicit AT_FDCWD instead.
    switch (kind) {
        .None => return true,
        .In => {
            _ = ulib.close(0);
            const fd = ulib.openat(0, target, ulib.O_RDONLY);
            if (fd != 0) {
                uprintf.printf(2, "sh: redir < %s failed\n", &.{.{ .s = target }});
                return false;
            }
            return true;
        },
        .Out => {
            _ = ulib.close(1);
            const fd = ulib.openat(0, target, ulib.O_WRONLY | ulib.O_CREAT | ulib.O_TRUNC);
            if (fd != 1) {
                uprintf.printf(2, "sh: redir > %s failed\n", &.{.{ .s = target }});
                return false;
            }
            return true;
        },
        .Append => {
            _ = ulib.close(1);
            const fd = ulib.openat(0, target, ulib.O_WRONLY | ulib.O_CREAT | ulib.O_APPEND);
            if (fd != 1) {
                uprintf.printf(2, "sh: redir >> %s failed\n", &.{.{ .s = target }});
                return false;
            }
            return true;
        },
    }
}

fn handleBuiltin(parsed: *const ParsedCmd) bool {
    if (parsed.argc == 0) return false;
    const cmd = argv_ptrs[0].?;

    if (ulib.strcmp(cmd, "exit") == 0) {
        ulib.exit(0);
    }
    if (ulib.strcmp(cmd, "cd") == 0) {
        if (parsed.argc < 2) {
            uprintf.printf(2, "cd: missing arg\n", &.{});
            return true;
        }
        if (ulib.chdir(argv_ptrs[1].?) < 0) {
            uprintf.printf(2, "cd: %s: no such directory\n", &.{.{ .s = argv_ptrs[1].? }});
        }
        return true;
    }
    if (ulib.strcmp(cmd, "pwd") == 0) {
        var cwd_buf: [PATH_MAX]u8 = undefined;
        const len = ulib.getcwd(&cwd_buf, PATH_MAX);
        if (len < 0) {
            uprintf.printf(2, "pwd: getcwd failed\n", &.{});
            return true;
        }
        _ = ulib.write(1, &cwd_buf, @intCast(len));
        const nl: [1]u8 = .{'\n'};
        _ = ulib.write(1, &nl, 1);
        return true;
    }
    return false;
}

fn runCommand(parsed: *const ParsedCmd) void {
    if (parsed.argc == 0) return;
    if (handleBuiltin(parsed)) return;

    const pid = ulib.fork();
    if (pid < 0) {
        uprintf.printf(2, "sh: fork failed\n", &.{});
        return;
    }
    if (pid == 0) {
        // Child.
        if (parsed.redir_kind != .None) {
            if (!doRedirect(parsed.redir_kind, parsed.redir_target.?)) ulib.exit(1);
        }
        const path = resolveBin(argv_ptrs[0].?);
        _ = ulib.exec(path, @ptrCast(&argv_ptrs));
        uprintf.printf(2, "sh: exec %s failed\n", &.{.{ .s = path }});
        ulib.exit(127);
    }
    // Parent.
    _ = ulib.set_fg_pid(@intCast(pid));
    var status: i32 = 0;
    const waited = ulib.wait(&status);
    _ = waited;
    _ = ulib.set_fg_pid(0);
}

export fn main(argc: u32, argv: [*]const [*:0]const u8) i32 {
    _ = argc;
    _ = argv;

    while (true) {
        // Prompt.
        const prompt: [2]u8 = .{ '$', ' ' };
        _ = ulib.write(1, &prompt, 2);

        // Read a line.
        const got = ulib.getline(0, &line_buf, LINE_MAX);
        if (got <= 0) {
            // EOF on stdin: bail.
            const nl: [1]u8 = .{'\n'};
            _ = ulib.write(1, &nl, 1);
            return 0;
        }

        const n: u32 = @intCast(got);
        // Skip blank lines.
        var blank = true;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (!isSpace(line_buf[i])) {
                blank = false;
                break;
            }
        }
        if (blank) continue;

        const parsed = parseLine(&line_buf, n);
        runCommand(&parsed);
    }
}
