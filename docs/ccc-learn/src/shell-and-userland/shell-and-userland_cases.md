# shell-and-userland: Code Cases

> Real artifacts that exercise the shell + utilities.

---

### Case 1: `e2e-shell` — the canonical session (Plan 3.E, 2026-04)

**Background**

Plan 3.E's deliverable was a working shell session. `tests/e2e/shell.zig` is the regression test that pipes a 51-byte scripted session through `--input` and asserts the output.

**What happened**

`tests/e2e/shell_input.txt`:

```
ls /bin
echo hi > /tmp/x
cat /tmp/x
rm /tmp/x
exit
```

The verifier runs `ccc kernel-fs.elf --disk shell-fs.img --input shell_input.txt` and asserts that key output strings appear: `cat\necho\nls\nrm\nsh\nmkdir\ninit`, `hi`, etc.

For this to pass:
- `init_shell` forks `sh`, which prints `$ `.
- `--input` paces bytes. Shell reads `ls /bin\n`, fork+execs `/bin/ls`, ls reads dir, prints names.
- `echo hi > /tmp/x`: tokenize, redirect, fork, child opens file, dups, execs, echo writes "hi\n".
- `cat /tmp/x`: tokenize, fork, exec cat, cat opens, reads "hi\n", writes to stdout.
- `rm /tmp/x`: unlinkat.
- `exit`: builtin, shell exits 0. init reaps, sees status 0, exits 0. Kernel halts.

If any utility is broken, the assertion fails. If redirect doesn't work, "hi" never lands in the file. If `init_shell`'s loop is wrong, sh wouldn't even start.

**References**

- `src/kernel/user/{init_shell,sh,ls,cat,echo,rm,mkdir}.zig`
- `tests/e2e/shell.zig`, `shell_input.txt`
- `build.zig` target `e2e-shell`

---

### Case 2: The `init_shell` fork-exec-sh-wait loop (Plan 3.E, 2026-04)

**Background**

`init_shell.elf` is what `mkfs --init init_shell.elf` puts at `/bin/init`. It's the very first user program. Its only job: keep a shell running.

**What happened**

`src/kernel/user/init_shell.zig`:

```zig
fn main() noreturn {
    while (true) {
        const child = fork();
        if (child < 0) _ = exit(1);
        if (child == 0) {
            const argv = [_]?[*:0]const u8{ "sh", null };
            _ = execve("/bin/sh", &argv, null);
            _ = exit(127);  // exec failed
        }
        var status: i32 = 0;
        _ = wait4(child, &status, 0, null);
        if (status == 0) _ = exit(0);  // sh said "exit 0" — clean halt
        // status != 0: relaunch
    }
}
```

When the user types `exit` in sh, sh exits 0. init's wait4 returns. init exits 0. Kernel sees PID 1 exit and halts cleanly.

When the user types `^C` at the shell prompt (which kills the shell), sh exits with non-zero status. init relaunches.

**Relevance**

This is `ccc`'s "init" — minimal, but enough. Real init systems (System V, systemd) manage hundreds of services with dependencies, restart policies, namespaces. The pattern (loop, supervise, restart) is the same.

**References**

- `src/kernel/user/init_shell.zig`
- `build.zig` (the `kernel-init-shell` target embeds it as `/bin/init`)

---

### Case 3: `echo hi > /tmp/x` end-to-end (Plan 3.E, 2026-04)

**Background**

The redirect path is the most-syscall-dense single line of `ccc` shell behavior.

**What happened**

The shell's child process (after fork):

1. `openat(AT_FDCWD, "/tmp/x", O_WRONLY | O_CREAT | O_TRUNC, 0644)` — kernel `namei`s `/tmp`, finds entry, walks. `/tmp/x` doesn't exist → `O_CREAT` triggers `fsops.create`: ialloc a fresh inode, `dirlink` "x" into `/tmp`, return new fd. Returns fd 3.

2. `close(1)` — drop the Console reference at fd 1. File refcount on Console drops by 1.

3. `dup2(3, 1)` — `file.dup` of fd 3's File; install at fd 1. Refcount on `/tmp/x`'s File rises by 1.

4. `close(3)` — drop fd 3's reference. Refcount on `/tmp/x`'s File drops; now only fd 1.

5. `execve("/bin/echo", ["echo", "hi"], envp)` — exec replaces address space. fd table preserved.

6. echo runs. `write(1, "hi", 2)` — kernel does `file.write(fd1_file, "hi", 2)` → `inode.writei(...)` → `bmap(ip, 0, true)` → balloc → bwrite. File offset becomes 2.

7. `write(1, "\n", 1)` — same, offset becomes 3.

8. echo returns, `_start` does exit(0). Kernel closes all fds. fd 1's File: refcount drops to 0; `iput` runs. nlink is 1 (linked from /tmp), refcount is 0 → don't `itrunc`. Just write the inode back.

9. Bufcache eventually flushes the inode block + data block + bitmap to disk on next eviction or shutdown.

10. Shell's `wait4` returns. Print `$ `.

11. User then runs `cat /tmp/x` — reads `hi\n`. Confirms the redirect worked.

**References**

- `src/kernel/user/sh.zig` (the redirect parsing + dup2 dance)
- `src/kernel/user/echo.zig` (the writes)
- `src/kernel/syscall.zig` (`sys_openat`, `sys_close`, `sys_dup2`, `sys_write`)
- `src/kernel/file.zig` (`file.alloc`, `file.dup`, `file.put`)
- `src/kernel/fs/fsops.zig` (`create` for `O_CREAT`)
- `src/kernel/fs/inode.zig` (`writei`, `bmap`)
- `src/kernel/fs/balloc.zig` (`balloc`)

---

### Case 4: `ls` calling `Stat` on every entry (Plan 3.E, 2026-04)

**Background**

When `ls /` runs, it should distinguish files from directories. xv6's `ls` does this by calling `fstat` on each entry to read the type.

**What happened**

`src/kernel/user/ls.zig`:

```zig
fn ls(path: [*:0]const u8) void {
    const fd = openat(AT_FDCWD, path, O_RDONLY);
    var st: Stat = undefined;
    fstat(fd, &st);

    if (st.type == T_File) {
        printf(1, "{s} {} bytes\n", path, st.size);
        close(fd);
        return;
    }

    // Directory: read dirents
    var de: DirEntry = undefined;
    while (read(fd, &de, sizeof(DirEntry)) == sizeof(DirEntry)) {
        if (de.inum == 0) continue;  // empty slot
        // Build full path: path + "/" + de.name
        var full: [128]u8 = undefined;
        join_path(&full, path, &de.name);
        var sub_st: Stat = undefined;
        const sub_fd = openat(AT_FDCWD, &full, O_RDONLY);
        fstat(sub_fd, &sub_st);
        const t = if (sub_st.type == T_File) "file" else if (sub_st.type == T_Dir) "dir" else "console";
        printf(1, "{s} {} {} bytes\n", &de.name, t, sub_st.size);
        close(sub_fd);
    }
    close(fd);
}
```

So `ls /` on `shell-fs.img` results in something like:

```
.       dir   2 entries
..      dir   2 entries
bin     dir   8 entries
etc     dir   3 entries
tmp     dir   2 entries
```

(Actual format varies; check `ls.zig` for the precise output.)

The Stat dispatch lets `ls` print sensible output for any inode type — file, dir, or console (fd 0/1/2 fstat returns T_Console).

**References**

- `src/kernel/user/ls.zig`
- `src/kernel/syscall.zig` (`sys_fstat`)
- `src/kernel/file.zig` (`file.stat` filling Stat fields)

---

### Case 5: `rm /tmp/x` and the `unlinkat` flow (Plan 3.E, 2026-04)

**Background**

`rm` is one of the simplest utilities. ~16 lines.

**What happened**

`src/kernel/user/rm.zig`:

```zig
fn main(argc: u32, argv: [*]const [*:0]const u8) i32 {
    var i: u32 = 1;
    while (i < argc) : (i += 1) {
        if (unlinkat(AT_FDCWD, argv[i], 0) < 0) {
            // print error to stderr
        }
    }
    return 0;
}
```

The kernel's `sys_unlinkat`:

1. `nameiparent(path)` returns the parent inode + the last component name.
2. `dirunlink(parent, name)` zeros the matching dirent's inum. Decrements the target inode's `nlink`.
3. If the target's `nlink` drops to 0:
   - Mark the in-memory inode for itrunc.
   - On `iput` (when refcount drops to 0), `itrunc` frees data blocks, sets type=Free, `iupdate`s.
4. Return 0.

If a process has the file open (refcount > 0), the inode lives until the last close. Then the data is reclaimed. Classic Unix "deleted but still open" semantics.

**References**

- `src/kernel/user/rm.zig`
- `src/kernel/syscall.zig` (`sys_unlinkat`)
- `src/kernel/fs/fsops.zig` (`unlink`)
- `src/kernel/fs/dir.zig` (`dirunlink`)
- `src/kernel/fs/inode.zig` (`iput` → `itrunc` on nlink=0)

---

### Case 6: The empty argv quirk in `_start` (Plan 3.E, 2026-04)

**Background**

`_start` reads `argc = *sp`. If exec was called with an empty argv array (just `["program_name", NULL]`), argc = 1 and that's fine. But what if an ELF is `_start`'d *without* having gone through exec? E.g., the very first PID 1 launch via `proc.exec` — does it set up the argv tail correctly?

**What happened**

In `proc.exec`'s setup of PID 1 at boot:

```zig
fn exec(p: *Process, path: []const u8, argv: ?[*]const ?[*:0]const u8) !void {
    // ... load ELF, build new pt ...

    // Copy argv strings + ptrs into the new user stack.
    var argc: u32 = 0;
    if (argv != null) {
        while (argv[argc] != null) argc += 1;
    }
    // Layout: argc, argv[0..argc], NULL, env[0]=NULL, then strings up top
    // Build via copyUserStack helper.
    p.trapframe.sp = built_sp;
    p.trapframe.a0 = argc;  // optional: kernel stuffs argc directly for some fast-path cases
}
```

For PID 1, the kernel passes `argv = ["init", null]`. So argc = 1, argv has one valid pointer. `_start` reads sp, sees argc=1, argv[0] = "init". Calls `main(1, argv)`. init's main ignores argc/argv and just runs.

If the kernel forgot to set up the layout (left sp pointing at garbage), `_start` would read random memory as argc, then iterate to a bogus argv[0], potentially page-faulting.

**Relevance**

The argv tail layout has to be perfect. Real Unix uses extensive testing here because subtle bugs (off-by-one, alignment, missing NULL terminator) cause programs to mysteriously crash or get random argv values.

**References**

- `src/kernel/proc.zig` (`exec` → `copyUserStack`)
- `src/kernel/user/lib/start.S` (the `_start` that reads sp)
- The RISC-V psABI's "Initial Process Stack" section
