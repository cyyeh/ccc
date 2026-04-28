# shell-and-userland: A Beginner's Guide

## What's a Shell?

A shell is "a forever-loop that asks for a line, splits it into words, and runs the first word as a program."

That's the whole thing. Almost everything else is decoration:

- **Tab completion**: nice but optional.
- **Command history**: nice but optional.
- **Job control** (`Ctrl+Z`, `bg`, `fg`): nice but optional.
- **Pipes** (`|`): a shell feature; not in `ccc`'s shell yet.
- **Globbing** (`*.txt`): a shell feature.
- **Variables** (`$HOME`): a shell feature.

`ccc`'s shell skips all of these. What it has:
- **The forever-loop.**
- **Whitespace tokenization.**
- **Redirects (`<`, `>`, `>>`).**
- **Three builtins (`cd`, `pwd`, `exit`).**
- **Fork+exec for everything else.**

That's enough to be useful. You can `cat`, `echo`, `ls`, `mkdir`, `rm`, redirect output. You can edit files (`edit /etc/motd`). For Phase 3, that's all the API you need.

---

## How Does the Shell Run a Program?

You type `cat /etc/motd`. The shell:

1. **Reads the line.** `read(0, buf, 256)` — kernel returns the buffered line via cooked-mode read.
2. **Tokenizes.** Splits on whitespace: `["cat", "/etc/motd"]`.
3. **Checks for builtins.** "cat" isn't `cd`/`pwd`/`exit`. Skip.
4. **Forks.** Now there are two shells.
5. **Child:** `execve("/bin/cat", argv, envp)`. The child's image is replaced with cat. cat runs.
6. **Parent:** `wait4(child)`. Block until cat exits.
7. **Print the prompt.** Loop.

The "fork then exec" pattern is the universal way to launch any Unix program. The kernel doesn't have a "spawn" syscall — instead, it has fork (clone the process) and exec (replace the image), and the user-side glue does the right combination.

Why? Because the *gap* between fork and exec is where the shell does interesting things:
- Set up file descriptor redirects.
- Change directory (with `cd`-then-exec idioms in advanced shells).
- Modify environment variables.
- Set up process groups for job control.

If "spawn" were the only API, none of these would be possible without lots of extra flags.

---

## Redirects: How `>` Works

You type `echo hi > /tmp/x`. The shell:

1. Tokenizes: `["echo", "hi", ">", "/tmp/x"]`.
2. Recognizes `>` as a redirect. Splices `[">", "/tmp/x"]` out: `["echo", "hi"]`. Notes: stdout (fd 1) should be redirected to `/tmp/x`.
3. Forks.
4. **Child** (the interesting part):
   - `int f = open("/tmp/x", O_WRONLY | O_CREAT | O_TRUNC);` — opens (or creates) the file. Returns fd 3.
   - `dup2(f, 1);` — copies fd 3 onto fd 1. Now fd 1 also points at the same `File` struct as fd 3.
   - `close(f);` — closes fd 3. fd 1 is the only reference now.
   - `execve("/bin/echo", ...);` — exec.
5. **echo runs.** `write(1, "hi", 2);` — but fd 1 is `/tmp/x`! The bytes go to the file.
6. echo exits. fd 1 (and the file) is closed.

That's the entire mechanism. **fd preservation across exec** is the magic. Without it, when echo's image replaced the child's, fd 1 would re-point at whatever default... but exec doesn't touch the fd table. So fd 1 stays "the file" through the exec.

This is *the* feature that makes Unix's everything-is-a-file philosophy work.

---

## What's a Builtin?

A few commands can't be external programs:

- **`cd /tmp`** — changes the *shell's* current directory. If we forked + execed a `cd` program, the cd would change the child's cwd, then the child would exit. The shell's cwd would be unchanged. Pointless.
- **`exit`** — terminates the *shell*. Same logic.
- **`pwd`** — prints the cwd. Could be external (and is, on real Unix), but `ccc`'s shell builds it in for simplicity.

The shell handles these inline, before forking:

```c
if (tokens[0] == "cd") {
    chdir(tokens[1]);
    continue;
}
if (tokens[0] == "exit") {
    exit(0);
}
// ... fork+exec for everything else
```

Real shells have many more builtins (`echo`, `read`, `set`, `unset`, `kill`, ...) but `ccc`'s minimal three are enough.

---

## What's a User Program, Structurally?

Every utility (`cat`, `ls`, `echo`, `mkdir`, `rm`) is a Zig file under `src/kernel/user/`. Compiled to a separate ELF, baked into `shell-fs.img` at `/bin/<name>`.

Structure:

```zig
// src/kernel/user/echo.zig
const lib = @import("lib/ulib.zig");

export fn main(argc: u32, argv: [*]const [*:0]const u8) i32 {
    var i: u32 = 1;
    while (i < argc) : (i += 1) {
        _ = lib.write(1, argv[i], lib.strlen(argv[i]));
        if (i + 1 < argc) _ = lib.write(1, " ", 1);
    }
    _ = lib.write(1, "\n", 1);
    return 0;
}
```

The `_start` symbol (in `lib/start.S`) is the actual entry point, but it just parses argc/argv from the stack and calls `main`. Each program's `main` is a normal Zig function returning an exit code.

The `_ =` discards the syscall's return value (Zig errors on unused return values). For the rare case where you do care about the return — `cat`'s `read` — you store it in a variable.

---

## A Worked Example: `ls /bin`

You type `ls /bin\n`. Step by step:

1. Shell reads the line.
2. Tokenizes: `["ls", "/bin"]`.
3. Forks. Child PID 4.
4. Child:
   - No redirects.
   - `execve("/bin/ls", ["ls", "/bin"], envp)`.
5. Kernel resolves `/bin/ls`: namei walks `/`, `bin`, `ls` → inode 6 (a File).
6. Kernel `readi`s the ELF (~4 KB) into a kernel scratch buffer.
7. Kernel parses the ELF: PT_LOAD segment at VA 0, ~3 KB code+data.
8. Kernel allocates a fresh page table, copies bytes in, sets entry = ELF entry, sets up argv tail (`argc=2, argv0_ptr → "ls\0", argv1_ptr → "/bin\0", NULL`).
9. Kernel returns to S-trap exit. `sret` lands in U-mode at `_start`.
10. `_start` reads argc=2, argv from stack. Calls `main(2, argv)`.
11. `main`:
    - path = "/bin".
    - `fd = openat(AT_FDCWD, "/bin", O_RDONLY)`. Returns fd 3.
    - `fstat(3, &st)`. Returns. st.type = T_Dir.
    - Loop: `read(3, &buf, 16 * 16)` — reads up to 16 dirents at a time.
    - For each: print name + "\n".
    - Eventually read returns 0 (no more dirents).
    - `close(3)`.
    - `return 0` from main.
12. `_start`'s `ecall` for exit(0). Kernel runs `proc.exit(p, 0)`. Child Zombie.
13. Shell's `wait4` returns. Shell prints `$ `.

You see:

```
$ ls /bin
.
..
cat
ls
echo
sh
mkdir
rm
$
```

That's eight syscalls (`fork`, `exec`, `openat`, `fstat`, `read` (multiple), `close`, `exit`, `wait4`) plus an internal kernel walk through namei + readi + bufcache + block. All to print 8 filenames.

---

## Quick Reference

| Concept | One-liner |
|---------|-----------|
| Shell | A loop: read line → tokenize → run. ~250 lines in `sh.zig`. |
| Tokenize | Split on whitespace. No quotes, no escapes in `ccc`. |
| Builtin | Command handled by the shell directly (cd, pwd, exit). |
| Fork+exec | Clone process; replace child's image with new program. |
| Redirect | Open file → dup2 onto target fd → close temp → exec. |
| `init_shell` | The PID 1 program; forks sh, waits, relaunches if needed. |
| `_start` | First user instr; parses argc/argv off sp; calls main. |
| `usys.S` | 19 syscall stubs. Each: li a7, N; ecall; ret. |
| `uprintf` | Minimal printf for fd. No buffering. |
| `argv` tail | argc + argv ptrs + NULL + envp ptrs + NULL on stack. |
| fd preservation | Across exec, fd table stays. Why redirects work. |
| `dup2(old, new)` | Make `new` fd point at the same File as `old`. |
