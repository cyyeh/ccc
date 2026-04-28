# shell-and-userland: In-Depth Analysis

## Introduction

The shell is the user-facing top of the stack. By Phase 3.E, `ccc` has a working shell that lets you type `ls /bin`, `cat /etc/motd`, `echo hi > /tmp/x`, etc. This topic covers the shell itself (`sh.zig`), the `init_shell` loop that keeps it alive, the user-side stdlib (`start.S`, `usys.S`, `ulib.zig`, `uprintf.zig`), and the family of utilities (`ls`, `cat`, `echo`, `mkdir`, `rm`).

Source files: `src/kernel/user/{sh,init_shell,ls,cat,echo,mkdir,rm}.zig` and `src/kernel/user/lib/{start.S, usys.S, ulib.zig, uprintf.zig}`.

A shell is *not* a kernel feature. It's a U-mode program that uses the kernel's syscalls (fork, exec, wait, openat, dup2, etc.) to do its job. By writing it as user code, the kernel stays small and focused.

---

## Part 1: The user stdlib (`lib/`)

Every user program in `ccc` links against a tiny "stdlib" in `src/kernel/user/lib/`:

- **`start.S`** — the very first instructions any user program runs. Parses argc/argv from the stack tail, calls `main`, then `ecall`s exit with `main`'s return value.
- **`usys.S`** — 19 syscall stubs. Each is two instructions (`li a7, NN; ecall`).
- **`ulib.zig`** — `mem*`/`str*` helpers, syscall externs, `O_*` flag constants, `Stat` struct.
- **`uprintf.zig`** — a minimal `printf(fd, fmt, args)`.

There's no malloc, no libc, no setjmp. Programs are tens to hundreds of lines.

### `start.S`

```
.global _start
_start:
    lw a0, 0(sp)        # argc
    addi a1, sp, 4      # argv = sp + 4 (pointer to argv0_ptr)
    call main
    li a7, 93           # exit syscall
    ecall
1:  j 1b                # never reached, but defensive
```

This is the System-V-ABI-compliant entry. `main(argc, argv)` is the user's Zig function. After it returns, exit with the return value as the status.

### `usys.S`

19 stubs, one per syscall. Pattern:

```
.global write
write:
    li a7, 64
    ecall
    ret
```

Whatever was in `a0..a5` going in stays there. `a7` gets overwritten with the syscall number. `ecall` traps. Kernel runs the syscall, puts return in `a0`, `sret`s back. `ret` returns to the caller.

### `uprintf.zig`

A small `printf` that does `%d`, `%s`, `%c`, `%x`, `%p`. Writes to a given fd via `write` syscall. ~100 lines. No buffering — every byte hits the syscall directly. Slow but simple.

---

## Part 2: `init_shell.zig` — the relauncher

`init_shell.zig` is what `mkfs --init init_shell.elf shell-fs.img` puts at `/bin/init`. It's the first user process the kernel runs.

```zig
fn main() noreturn {
    while (true) {
        const child = fork();
        if (child == 0) {
            const argv = [_]?[*:0]const u8{ "sh", null };
            _ = execve("/bin/sh", &argv, null);
            _ = exit(127);
        }
        var status: i32 = 0;
        _ = wait4(child, &status, 0, null);
        if (status == 0) exit(0);
    }
}
```

Loop:
1. Fork.
2. Child execs `/bin/sh`. If exec fails, exits 127.
3. Parent waits for child. If sh exited cleanly (status 0), init exits too — this is the "user typed `exit`" case.
4. Otherwise (sh died, was killed, etc.), loop. Fork a new sh.

This pattern is universal: the OS's "init" must always be available, even if its child shell crashes. Real `init` (System V, systemd) does the same on a much larger scale (services + targets + restart policies).

When `init` finally exits 0, the kernel halts (because PID 1 exiting is the signal "we're done").

---

## Part 3: `sh.zig` — the shell

`sh.zig` is ~250 lines. It implements:

- **Read-eval-print loop.**
- **Tokenization** (split on whitespace).
- **Builtins** (`cd`, `pwd`, `exit`).
- **Redirects** (`< > >>`).
- **Fork+exec** for non-builtins.
- **Wait** for the child.

The main loop:

```zig
fn main() i32 {
    while (true) {
        write_prompt();
        const line = read_line();
        if (line.len == 0) return 0;       // EOF
        if (handle_builtin(line)) continue;
        const child = fork();
        if (child == 0) {
            run_external(line);             // tokenize + redirects + exec
            exit(127);                      // exec failed
        }
        wait4(child, &status, 0, null);
    }
}
```

### Tokenization

```zig
fn tokenize(line: []const u8, tokens: *[16][]const u8) u32 {
    var i: u32 = 0;
    var n: u32 = 0;
    while (i < line.len) {
        while (i < line.len and is_whitespace(line[i])) i += 1;
        if (i == line.len) break;
        const start = i;
        while (i < line.len and !is_whitespace(line[i])) i += 1;
        tokens[n] = line[start..i];
        n += 1;
    }
    return n;
}
```

Splits on whitespace. No quotes. No backslash escapes. No globbing. Simple.

### Redirects

For tokens like `>`, `<`, `>>`:

```zig
for (i in 0..n_tokens) {
    if (token == ">") {
        path = tokens[i+1];
        // splice tokens[i] and tokens[i+1] out of the array
        fd_redirect(1, path, O_WRONLY | O_CREAT | O_TRUNC);
    } else if (token == "<") {
        path = tokens[i+1];
        fd_redirect(0, path, O_RDONLY);
    } else if (token == ">>") {
        path = tokens[i+1];
        fd_redirect(1, path, O_WRONLY | O_CREAT | O_APPEND);
    }
}
```

`fd_redirect(target_fd, path, flags)`:

```zig
const f = openat(AT_FDCWD, path, flags);
close(target_fd);
dup2(f, target_fd);
close(f);
```

`dup2(f, target_fd)` makes `target_fd` point to the same File as `f`. After `close(f)`, only `target_fd` references the File.

This is the magic of fork+exec for redirection: the *child* opens the file, dup2's to fd 1, closes the temp, then execs. The new program inherits fd 1 pointing at the file. Writes to "stdout" hit the file.

### `cd`, `pwd`, `exit` builtins

These can't be external programs, because they affect the shell's *own* state (cwd, exit status). The shell handles them inline:

```zig
if (tokens[0] == "cd") {
    if (n == 1) chdir("/");
    else chdir(tokens[1]);
    return true;  // handled
}
if (tokens[0] == "pwd") {
    var buf: [128]u8 = undefined;
    getcwd(&buf, 128);
    write(1, &buf, strlen(&buf));
    return true;
}
if (tokens[0] == "exit") {
    exit(if (n > 1) parse_int(tokens[1]) else 0);
}
```

If we forked first and ran `cd` in the child, the cwd would change in the *child* — pointless, since the child immediately exits.

---

## Part 4: The utilities

`ls`, `cat`, `echo`, `mkdir`, `rm`. Each is a tiny user program.

### `echo.zig` (~20 lines)

```zig
fn main(argc: u32, argv: [*]const [*:0]const u8) i32 {
    var i: u32 = 1;
    while (i < argc) : (i += 1) {
        write(1, argv[i], strlen(argv[i]));
        if (i + 1 < argc) write(1, " ", 1);
    }
    write(1, "\n", 1);
    return 0;
}
```

Just print the args separated by spaces, plus a `\n`. Smallest possible Unix utility.

### `cat.zig` (~40 lines)

```zig
fn cat(fd: i32) void {
    var buf: [512]u8 = undefined;
    while (true) {
        const n = read(fd, &buf, 512);
        if (n <= 0) break;
        write(1, &buf, n);
    }
}

fn main(argc: u32, argv: [*]const [*:0]const u8) i32 {
    if (argc <= 1) {
        cat(0);  // stdin
    } else {
        var i: u32 = 1;
        while (i < argc) : (i += 1) {
            const fd = openat(AT_FDCWD, argv[i], O_RDONLY);
            if (fd < 0) continue;
            cat(fd);
            close(fd);
        }
    }
    return 0;
}
```

Read from each file (or stdin if no args), copy bytes to fd 1.

### `ls.zig` (~85 lines)

```zig
fn main(argc, argv) i32 {
    const path = if (argc > 1) argv[1] else ".";
    const fd = openat(AT_FDCWD, path, O_RDONLY);
    var st: Stat = undefined;
    fstat(fd, &st);
    if (st.type == T_File) {
        // single file: print name
    } else if (st.type == T_Dir) {
        // read directory entries
        var buf: [1024]u8 = undefined;
        while (read(fd, &buf, sizeof(DirEntry) * 16) > 0) {
            for (each DirEntry in buf) {
                if (de.inum != 0) write(1, de.name, name_len(de));
                write(1, "\n", 1);
            }
        }
    }
}
```

For files: print the name. For directories: read the dirents, print each name. The `Stat` dispatch lets `ls` handle both cases.

### `mkdir.zig` and `rm.zig` (each ~16 lines)

```zig
// mkdir.zig
fn main(argc, argv) i32 {
    var i: u32 = 1;
    while (i < argc) : (i += 1) {
        if (mkdirat(AT_FDCWD, argv[i], 0o755) < 0) {
            // print error
        }
        i += 1;
    }
    return 0;
}

// rm.zig
fn main(argc, argv) i32 {
    var i: u32 = 1;
    while (i < argc) : (i += 1) {
        if (unlinkat(AT_FDCWD, argv[i], 0) < 0) {
            // print error
        }
        i += 1;
    }
    return 0;
}
```

Just call the matching syscall for each arg.

---

## Part 5: The whole flow — `echo hi > /tmp/x`

You type `echo hi > /tmp/x` at the prompt.

1. Shell reads the line.
2. Tokenize: `["echo", "hi", ">", "/tmp/x"]`.
3. Recognize `>` redirect. Splice it out: `["echo", "hi"]` + redirect `(1, "/tmp/x", O_WRONLY|O_CREAT|O_TRUNC)`.
4. Not a builtin. Fork.
5. Child:
   - Apply redirect: `openat("/tmp/x", O_WRONLY|O_CREAT|O_TRUNC)` returns fd 3. `close(1); dup2(3, 1); close(3);`. fd 1 now points at `/tmp/x`.
   - `execve("/bin/echo", ["echo", "hi"], envp)`.
   - In the new image, fd 1 is still `/tmp/x` (preserved).
6. echo runs. `write(1, "hi", 2)`. `write(1, "\n", 1)`. Both go to `/tmp/x` because fd 1 was redirected.
7. echo exits.
8. Shell's `wait4` returns. Shell prints prompt.
9. `/tmp/x` now contains `hi\n`. Verifiable with `cat /tmp/x`.

This entire pipeline — fork, redirect, exec — is what every Unix shell does. `ccc`'s sh.zig does it in 250 lines.

---

## Summary & Key Takeaways

1. **The shell is a user program, not a kernel feature.** sh.zig uses syscalls; the kernel doesn't know what a shell is.

2. **`init_shell` is a `fork→exec(sh)→wait` loop.** When sh exits cleanly, init exits too. Otherwise, relaunch sh.

3. **The user stdlib is tiny.** `start.S`, `usys.S`, `ulib.zig`, `uprintf.zig`. ~300 lines total.

4. **`start.S` parses argv from the stack tail.** Per System-V ABI: `argc, argv0, argv1, ..., NULL` at `sp`.

5. **`usys.S` is 19 two-instruction stubs.** `li a7, NN; ecall; ret`.

6. **The shell tokenizes, recognizes redirects, runs builtins, fork+exec for the rest.** ~250 lines.

7. **Redirects work via dup2 in the child between fork and exec.** The new program inherits the redirected fd.

8. **Builtins (`cd`, `pwd`, `exit`) run in the shell, not a child.** They modify the shell's own state.

9. **Each utility is dozens of lines.** `echo` is 20, `cat` is 40, `ls` is 85.

10. **fd preservation across exec is *the* feature.** Without it, redirection wouldn't work.
