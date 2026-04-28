# filesystem-internals: Code Cases

> Real artifacts that exercise each FS layer.

---

### Case 1: `e2e-persist` — proving writes survive emulator restart (Plan 3.F, 2026-04)

**Background**

The Phase 3 §Definition of Done requires that file writes persist. `tests/e2e/persist.zig` is the proof: run `ccc` twice on the same disk image; the second run sees the first's writes.

**What happened**

The test:

1. Copy `shell-fs.img` to `/tmp/persist.img`.
2. Run pass 1: `ccc --input persist_input1.txt --disk /tmp/persist.img kernel-fs.elf`.
   - `persist_input1.txt` contains: `echo replaced > /etc/motd\nexit\n`
   - The shell forks+execs echo, which opens `/etc/motd` with `O_TRUNC | O_WRONLY`, writes "replaced\n", closes.
   - At close time, the inode's write count is flushed via `iupdate` (writes the in-memory inode back to its disk slot).
   - Shell exits, kernel halts.
3. Run pass 2: `ccc --input persist_input2.txt --disk /tmp/persist.img kernel-fs.elf`.
   - `persist_input2.txt`: `cat /etc/motd\nexit\n`
   - cat opens motd, reads, prints to UART.
   - Output should contain `replaced\n`.
4. Verifier asserts the string appears in pass 2's stdout.

If `iupdate` doesn't flush, pass 2 sees the old "hello from phase 3" content. If `bwrite` is broken, same. If `itrunc` doesn't reclaim blocks correctly, pass 2 might see garbage.

**Relevance**

The persistence test is the *only* test that proves the FS write path actually hits disk (not just cache). All other tests run within one emulator session.

**References**

- `tests/e2e/persist.zig`
- `tests/e2e/persist_input1.txt`, `persist_input2.txt`
- `src/kernel/fs/inode.zig` (`iupdate`, `writei`)
- `src/kernel/fs/bufcache.zig` (`bwrite`)

---

### Case 2: `itrunc` on `nlink == 0` (Plan 3.E, 2026-04)

**Background**

Unix semantics say: when a file's last name is removed (`unlink`) AND no process has it open, free its data blocks.

**What happened**

`fs/inode.zig`'s `iput`:

```zig
pub fn iput(ip: *Inode) void {
    ip.refcnt -= 1;
    if (ip.refcnt == 0 and ip.valid and ip.nlink == 0) {
        ilock(ip);
        itrunc(ip);
        ip.type = 0;  // mark inode free
        iupdate(ip);  // flush type=0 to disk
        iunlock(ip);
    }
}

fn itrunc(ip: *Inode) void {
    for (i = 0; i < NDIRECT; i++) {
        if (ip.addrs[i] != 0) {
            bfree(ip.addrs[i]);
            ip.addrs[i] = 0;
        }
    }
    if (ip.addrs[NDIRECT] != 0) {
        var b = bread(ip.addrs[NDIRECT]);
        const indirect = @ptrCast(*[NINDIRECT]u32, b.data);
        for (j = 0; j < NINDIRECT; j++) if (indirect[j] != 0) bfree(indirect[j]);
        brelse(b);
        bfree(ip.addrs[NDIRECT]);
        ip.addrs[NDIRECT] = 0;
    }
    ip.size = 0;
    iupdate(ip);
}
```

The two conditions for freeing:
- `refcnt == 0` (no in-memory inode references — i.e., no fds open).
- `nlink == 0` (no directory entries reference this inum).

If you `unlink` a file while another process has it open, `nlink` drops to 0 but `refcnt > 0`. The file's blocks aren't freed yet. When the last fd closes, `iput` runs again, sees both conditions, calls `itrunc`. The blocks come back to the bitmap.

**Relevance**

This is the classic "deleted but still open" Unix behavior. Tools like `lsof` find files in this state on real Unix. `ccc` faithfully implements it.

**References**

- `src/kernel/fs/inode.zig` (`iput`, `itrunc`, `iupdate`)
- `src/kernel/fs/balloc.zig` (`bfree`)
- `src/kernel/fs/fsops.zig` (`unlink` calls dirunlink, then iput)

---

### Case 3: The lazy-alloc story for `bmap` (Plan 3.E, 2026-04)

**Background**

Unix has *sparse files*: writing at offset 1 GB without writing the bytes in between produces a 1-GB-large file that occupies only one block. The "holes" read as zero.

**What happened**

`bmap(ip, blk_no, for_write)` is the implementation. For a read (`for_write=false`):
- If `addrs[blk_no] == 0`, return 0 (the caller knows: zero block).
- Otherwise return the actual block number.

For a write (`for_write=true`):
- If `addrs[blk_no] == 0`, allocate via `balloc()`, store, `iupdate` (flush addrs change to disk), return new block.
- Otherwise return the actual block number.

`readi` checks the return:
- If `bmap` returned 0, copy zeros into the user buffer (don't read from disk).
- Otherwise, `bread` the block and copy bytes.

`writei` always passes `for_write=true`, so a write to a hole always allocates.

This pattern is called **lazy allocation**. The file's `size` advances on writes, but blocks are only added when bytes need to be stored. If you `lseek` to offset 1 MB and write 1 byte, the file is 1-MB-and-1-byte large but uses only 2 blocks (the new one for the byte, plus indirect if needed).

**References**

- `src/kernel/fs/inode.zig` (`bmap` with the `for_write` branch)
- `tests/e2e/persist.zig` (writes that exercise the path)

---

### Case 4: `mkfs` laying out an empty `/tmp/` (Plan 3.E, 2026-04)

**Background**

The shell uses `/tmp/` for things like `echo hi > /tmp/x`. For `/tmp/` to exist on the fresh image, mkfs must create it.

**What happened**

The staging directory `src/kernel/userland/shell-fs/tmp/` contains a single file: `.gitkeep`. This is git's "carry an empty dir" trick — git doesn't track empty dirs.

`mkfs.zig`'s root-walking logic:

```zig
fn walkRoot(root: []const u8) !void {
    var it = try std.fs.cwd().openDir(root, .{ .iterate = true });
    var iter = it.iterate();
    while (try iter.next()) |entry| {
        if (entry.name.len > 0 and entry.name[0] == '.') continue;  // skip dot-files
        ...
    }
}
```

The `if (entry.name[0] == '.') continue;` line skips `.gitkeep`. So `/tmp/` is created as a directory (because the staging dir exists), but its only entry (`.gitkeep`) is skipped. Result: an empty `/tmp/` (only `.` and `..`) on the image.

This pattern lets git carry empty directories that the FS image needs.

**Relevance**

A small detail, but illustrative: `mkfs` is straightforward except for these "what should and shouldn't end up in the image" choices.

**References**

- `src/kernel/mkfs.zig` (the `walkRoot`, dot-file skip)
- `src/kernel/userland/shell-fs/tmp/.gitkeep`

---

### Case 5: `dirlink` finding an empty slot vs appending (Plan 3.E, 2026-04)

**Background**

Adding a new entry to a directory could append to the end. But after `unlink` zeros entries, those slots can be reused.

**What happened**

`dir.zig`'s `dirlink`:

```zig
pub fn dirlink(dp: *Inode, name: []const u8, inum: u16) !void {
    var off: u32 = 0;
    while (off < dp.size) {
        var de: DirEntry = undefined;
        readi(dp, @ptrCast(&de), off, @sizeOf(DirEntry));
        if (de.inum == 0) {
            // empty slot, reuse
            de.inum = inum;
            copy_name(de.name, name);
            writei(dp, @ptrCast(&de), off, @sizeOf(DirEntry));
            return;
        }
        off += @sizeOf(DirEntry);
    }
    // No empty slot; append. dp.size will grow.
    de.inum = inum;
    copy_name(de.name, name);
    writei(dp, @ptrCast(&de), off, @sizeOf(DirEntry));
}
```

Two cases:
- **Empty slot found**: reuse. `dp.size` doesn't grow.
- **No empty slot**: append at the end. `writei` extends `dp.size` by 16.

Without slot reuse, a directory with high churn (lots of create/unlink) would grow forever. `mkfs` doesn't compact; the kernel relies on slot reuse.

**Relevance**

Most production filesystems (ext4, xfs) handle directory churn more aggressively (htree, btree). `ccc`'s approach is V6-Unix-style: simple, slow on huge directories, but correct.

**References**

- `src/kernel/fs/dir.zig` (`dirlink`, `dirunlink`)
- `src/kernel/fs/fsops.zig` (uses `dirlink` for create)

---

### Case 6: `bget` sleeping on a busy buffer (Plan 3.D, 2026-04)

**Background**

The bufcache uses sleep-on-busy locking. Concurrent `bread`s on the same block would otherwise corrupt the cache.

**What happened**

`bget(blk)` in `fs/bufcache.zig`:

```zig
pub fn bget(blk_id: u32) *Buf {
    while (true) {
        // search cache
        for (&buf_pool) |*b| {
            if (b.block_id == blk_id) {
                if ((b.flags & BUF_LOCKED) != 0) {
                    // someone else holds it; sleep
                    proc.sleep(@ptrCast(&b.flags));
                    break;  // restart search after wakeup
                }
                b.refcnt += 1;
                b.flags |= BUF_LOCKED;
                return b;
            }
        }
        // not in cache; alloc LRU
        for (&buf_pool) |*b| {
            if (b.refcnt == 0 and (b.flags & BUF_LOCKED) == 0) {
                b.block_id = blk_id;
                b.valid = false;
                b.refcnt = 1;
                b.flags |= BUF_LOCKED;
                return b;
            }
        }
        // no free buf; sleep on cache change
        proc.sleep(&buf_pool);
    }
}
```

Two sleep points:
- Block is already cached but locked: sleep on `&b.flags`. `brelse` calls `wakeup(&b.flags)`.
- All bufs are in use: sleep on `&buf_pool`. `brelse` also wakes this channel when refcnt drops to 0.

The pattern matches xv6's `bget` exactly.

**Relevance**

Even single-hart `ccc` benefits from this pattern because *kernel paths* can preempt each other (e.g., a syscall sleeps on disk I/O; another process's syscall wakes up; same path runs concurrently). The locking discipline keeps the cache consistent under those interleavings.

**References**

- `src/kernel/fs/bufcache.zig` (`bget`, `brelse`, `bread`, `bwrite`)
- xv6's `kernel/bio.c` for direct comparison
