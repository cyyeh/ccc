# filesystem-internals: In-Depth Analysis

## Introduction

A filesystem is a way to find named blocks of bytes on a disk. The job decomposes into layers:

1. **Block I/O.** Read sector N from disk; write sector N to disk.
2. **Buffer cache.** Don't re-read what's in memory; serialize concurrent access.
3. **Block allocator.** Track which sectors are free; hand out new ones.
4. **Inode layer.** Each file is metadata + a list of block numbers.
5. **Directory layer.** Files have names, looked up via dirents stored in directory inodes.
6. **Path layer.** Walk slash-separated names through dirents to land on an inode.

`ccc`'s FS in `src/kernel/fs/{layout,bufcache,balloc,inode,dir,path,fsops}.zig` follows this stack exactly. Plus a host-side `mkfs.zig` that lays out a fresh image.

The whole thing is ~1000 lines. By Plan 3.E, it stores files, lets you write them, has subdirectories, persists across emulator restarts.

---

## Part 1: On-disk layout (`layout.zig`)

A 4 MB disk image is laid out as 1024 blocks of 4 KB each:

```
block 0     boot sector (unused; mkfs leaves zeros here)
block 1     superblock                      (NBLOCKS, NINODES, magic, ptrs)
block 2     bitmap                          (1 bit per data block)
block 3..6  inode table                     (NINODES = 64 inodes; 16 per block)
block 7..   data blocks                     (the actual file contents)
```

Constants in `layout.zig`:
- `BLOCK_SIZE = 4096` (4 KB).
- `NBLOCKS = 1024` (4 MB image).
- `NINODES = 64` (max 64 files in this filesystem).
- `INODES_PER_BLOCK = 16` (each `DiskInode` is 256 bytes; 4096 / 256 = 16).
- `NDIRECT = 12` direct block pointers per inode.
- `NINDIRECT = 1024` (one indirect block holds 1024 u32 block numbers).
- `MAX_FILE_BLOCKS = 12 + 1024 = 1036` → max file size = 1036 * 4096 = ~4.2 MB.

The `DiskInode` struct:

```zig
pub const DiskInode = extern struct {
    type: u16,           // FileType: Free=0, File=1, Dir=2
    nlink: u16,          // hard link count (most files = 1; Dir always >= 2)
    size: u32,           // bytes
    addrs: [13]u32,      // [0..11] direct, [12] indirect
};
```

256 bytes, including padding. `addrs[0..NDIRECT]` are direct block numbers (0 means "unallocated"). `addrs[NDIRECT]` (`= addrs[12]`) is the block number of an *indirect block* — a 4 KB block holding 1024 more u32 block numbers.

The `DirEntry`:

```zig
pub const DirEntry = extern struct {
    inum: u16,
    name: [14]u8,        // null-padded (not necessarily null-terminated if 14 bytes used)
};
```

16 bytes per entry; 256 entries per 4 KB block. A directory is just a regular file whose contents are an array of these.

---

## Part 2: Buffer cache (`bufcache.zig`)

Disk I/O is slow. The bufcache keeps the most-recently-used blocks in RAM. It's a fixed-size LRU:

```zig
pub const NBUF: u32 = 16;

pub const Buf = struct {
    block_id: u32,       // which sector
    valid: bool,         // contains real data
    refcnt: u32,         // who's using it right now
    flags: u32,          // BUF_LOCKED bit
    data: [BLOCK_SIZE]u8, // the actual 4096 bytes
    next, prev,          // LRU links
};
```

The two main APIs:

- **`bget(blk: u32) !*Buf`** — find or allocate a Buf for sector `blk`. If already cached, refcnt++; if not, evict LRU. Returns *with the Buf locked* (no other caller can read/write its data concurrently).
- **`brelse(b: *Buf)` / `bwrite(b)`** — release lock, decrement refcnt. `bwrite` also issues the write to disk.

Concurrency is "sleep on busy": if `bget` finds the requested block already cached but `BUF_LOCKED`, it sleeps on `&b.flags` until the holder calls `brelse`. The single-hart `ccc` doesn't actually have parallelism, but the locking pattern matches xv6's, so the code stays compatible with future SMP.

`bread(blk)` is the convenience: bget + (if !valid) issue a block-device read + sleep on `&block.req` until ISR wakes us + mark valid.

---

## Part 3: Block bitmap (`balloc.zig`)

Block 2 is a 4 KB bitmap. Bit `n` set means data block `n` is allocated.

```zig
pub fn balloc() !u32 {
    var b = bufcache.bread(BITMAP_BLK);
    defer bufcache.brelse(b);
    for (data_block_n in 0..NBLOCKS) {
        if (bit not set) {
            set bit;
            bwrite(b);
            return data_block_n;
        }
    }
    return error.OutOfBlocks;
}

pub fn bfree(blk: u32) void {
    var b = bread(BITMAP_BLK);
    defer brelse(b);
    clear bit;
    bwrite(b);
}
```

Linear scan. With 1024 blocks, fast enough. The bitmap fits in one block, so the bufcache never has to evict it under normal load.

Phase 3.D had read-only FS (no `balloc`); Phase 3.E added the write path, which needed the allocator.

---

## Part 4: Inode cache (`inode.zig`)

In-memory inodes are cached separately from blocks. The cache:

```zig
pub const NINODE: u32 = 32;  // max in-memory inodes

pub const Inode = struct {
    inum: u32,           // 1-based
    refcnt: u32,         // open-fd refs
    valid: bool,         // dinode loaded?
    flags: u32,          // ILOCKED
    type: u16, nlink: u16, size: u32, addrs: [13]u32,
};
```

The flow:
- **`iget(inum)` → *Inode**: find or alloc cache entry; refcnt++. Doesn't load the on-disk data.
- **`ilock(ip)`**: acquire the inode lock; if !valid, load from disk (via bufcache).
- **`iunlock(ip)`**: release lock.
- **`iput(ip)`**: refcnt--. If refcnt == 0 and nlink == 0 (no on-disk references either), call `itrunc` and free the on-disk inode + all its data blocks.

Why two lookup steps (`iget` then `ilock`)? Because `iget` is fast (no disk I/O); a caller that just wants to bump the refcount (e.g., `dup` of an fd) doesn't need to read the disk inode. `ilock` is the slow path that touches disk.

### `bmap` — file offset to disk block

`bmap(ip, blk_no, for_write)` translates an in-file block index (0..MAX_FILE_BLOCKS-1) to a disk block number:

```zig
fn bmap(ip: *Inode, blk_no: u32, for_write: bool) !u32 {
    if (blk_no < NDIRECT) {
        if (ip.addrs[blk_no] == 0) {
            if (!for_write) return 0;          // sparse hole
            ip.addrs[blk_no] = balloc();
            iupdate(ip);                        // flush new addr to disk
        }
        return ip.addrs[blk_no];
    }
    // Indirect
    if (ip.addrs[NDIRECT] == 0) {
        if (!for_write) return 0;
        ip.addrs[NDIRECT] = balloc();
        // zero the new indirect block
        iupdate(ip);
    }
    var ib = bread(ip.addrs[NDIRECT]);
    defer brelse(ib);
    const indirect = @ptrCast(*[NINDIRECT]u32, &ib.data);
    const idx = blk_no - NDIRECT;
    if (indirect[idx] == 0) {
        if (!for_write) return 0;
        indirect[idx] = balloc();
        bwrite(ib);
    }
    return indirect[idx];
}
```

The **lazy allocation on `for_write`** is the magic. Reads of unallocated blocks return zero (sparse files). Writes allocate on demand. This matches Unix semantics.

### `readi` and `writei`

```zig
pub fn readi(ip: *Inode, dst: [*]u8, off: u32, n: u32) !u32 {
    var copied: u32 = 0;
    while (copied < n) {
        const blk_no = (off + copied) / BLOCK_SIZE;
        const blk = try bmap(ip, blk_no, false);
        if (blk == 0) {
            // sparse hole: copy zeros
            ...
        } else {
            var b = bread(blk);
            defer brelse(b);
            const within_blk_off = (off + copied) % BLOCK_SIZE;
            const chunk = min(BLOCK_SIZE - within_blk_off, n - copied);
            memcpy(dst + copied, b.data + within_blk_off, chunk);
            copied += chunk;
        }
    }
    return copied;
}
```

`writei` is the mirror, with `bmap(... for_write=true)` and `bwrite` at the end.

`itrunc` walks every direct + indirect block of an inode, calls `bfree` on each, then zeros the addrs. Called when ref+nlink hits zero — the inode is fully unreferenced.

---

## Part 5: Directories (`dir.zig`)

A directory is a regular file whose contents are an array of `DirEntry` records.

```zig
pub fn dirlookup(dp: *Inode, name: []const u8, off_out: ?*u32) ?u32 {
    var off: u32 = 0;
    while (off < dp.size) {
        var de: DirEntry = undefined;
        readi(dp, @ptrCast(&de), off, @sizeOf(DirEntry));
        if (de.inum != 0 and namesEq(de.name, name)) {
            if (off_out) |o| o.* = off;
            return de.inum;
        }
        off += @sizeOf(DirEntry);
    }
    return null;
}
```

Linear scan. Returns the inum if found. With small directories (few hundred entries), this is fine.

`dirlink(dp, name, inum)` is the "add an entry" operation. It scans for an empty slot (`inum == 0`), or appends if no slot is free. `dirunlink(dp, name)` zeros the matching entry's inum (leaves the slot for reuse).

Special entries: every directory contains `.` (self) and `..` (parent). These are created by `mkdir` and respected by `namei`.

---

## Part 6: Path resolution (`path.zig`)

`namei("/etc/motd")` walks the path component-by-component:

```zig
pub fn namei(path: []const u8, cwd: *Inode) ?*Inode {
    var ip = if (path[0] == '/') iget(ROOT_INUM) else idup(cwd);
    var i: u32 = 0;
    while (i < path.len) {
        // skip slashes
        while (i < path.len and path[i] == '/') i += 1;
        if (i == path.len) return ip;  // trailing slash
        // extract next component
        const start = i;
        while (i < path.len and path[i] != '/') i += 1;
        const name = path[start..i];

        ilock(ip);
        if (ip.type != .Dir) { iunlockput(ip); return null; }
        const next_inum = dirlookup(ip, name, null) orelse {
            iunlockput(ip); return null;
        };
        iunlockput(ip);
        ip = iget(next_inum);
    }
    return ip;
}
```

Start at root or cwd, walk each component, dirlookup. The careful lock dance (`ilock` → check type → `dirlookup` → `iunlockput`) is what xv6 does to avoid holding multiple inode locks at once (which could deadlock with another caller in opposite order).

`nameiparent` is a variant that returns the *parent* inode and copies the last component into a buffer — used by `create`/`unlink` which need to modify the parent.

---

## Part 7: The `mkfs` host tool

To boot from a filesystem, we need an image. `src/kernel/mkfs.zig` is a host-side Zig program that creates one. Inputs: a `--root` directory and a `--bin` directory; output: a 4 MB image.

The algorithm:
1. Lay out the superblock (block 1).
2. Initialize the bitmap (block 2): mark blocks 0..6 (boot + super + bitmap + inode table) as allocated.
3. Initialize the inode table (blocks 3..6): all DiskInodes start as type=Free.
4. Allocate inode 1 as root directory. Add `.` and `..` entries (both pointing at inum 1).
5. For each top-level subdir of `--root`: recursively walk, creating Dir inodes + dirents + linking files.
6. For each file under `--bin`: create File inode, write contents into data blocks, link from `/bin/`.
7. Write the image to disk.

The `--init` flag overrides which file ends up at `/bin/init`. Used to swap `init_shell.elf` for the shell-fs image.

`zig build fs-img` produces `zig-out/fs.img`; `zig build shell-fs-img` produces `zig-out/shell-fs.img`.

---

## Part 8: Files, fds, and Console-typed entries (`file.zig`)

`file.zig` (kernel-side, not strictly fs/) holds the open-file table:

```zig
pub const FileType = enum { None, Inode, Console };

pub const File = struct {
    type: FileType,
    refcnt: u32,
    readable: bool,
    writable: bool,
    ip: ?*Inode,         // for Inode-type
    off: u32,            // current file position
    // (Console-type uses no extra fields; reads from console.read)
};

pub var files: [NFILE = 64]File = ...;
```

Each open `File` is shared (ref-counted) across processes that fork from a common parent (the shared-fd semantics from the previous topic).

`Console` type is the trick that makes fd 0/1/2 work: when a new process is created, fd 0/1/2 all point to a shared Console-type File, whose read goes to `console.read` (line discipline) and write goes to `console.write` (UART TX). This means `cat` reading "stdin" really reads keystrokes; `printf` writing "stdout" really sends UART bytes.

When the shell does `echo hi > /tmp/x`:
1. Open `/tmp/x` (creating if missing) → returns fd 3, an Inode-type File.
2. Fork.
3. In child: `dup2(3, 1)` — make fd 1 also point at the file.
4. exec("echo", ["hi"]).
5. echo's writes to fd 1 hit the file (via writei).

This is why fd preservation across exec matters so deeply.

---

## Summary & Key Takeaways

1. **6 layers stacked.** Block I/O → bufcache → balloc → inode → dir → path. Plus mkfs to create the image.

2. **4 MB image, 4 KB blocks, 1024 blocks total.** Superblock at 1, bitmap at 2, inodes at 3..6, data at 7..

3. **Inode = type + nlink + size + 13 block pointers.** 12 direct + 1 indirect → max ~4.2 MB file.

4. **Bufcache is a 16-buf LRU with sleep-on-busy locking.** Even single-hart, the lock dance matches xv6 for SMP-readiness.

5. **`bmap` does lazy allocation.** Reads of holes return zero; writes allocate on demand via balloc.

6. **Directories are inodes with DirEntry records as content.** Linear-scan lookup; `.` and `..` always present.

7. **`namei` walks path components.** Lock parent → dirlookup → iunlockput → iget child. Careful order avoids deadlock.

8. **`mkfs` is a host-side Zig program.** Lays out a fresh image from a `--root` + `--bin` tree; supports `--init` override.

9. **`itrunc` runs on `iput` when ref+nlink hits zero.** Frees direct + indirect blocks, then the inode itself.

10. **fd 0/1/2 are Console-type Files.** read → console.read (cooked-mode); write → console.write (UART TX). Shared across fork, preserved across exec.

11. **`file.zig`'s File struct is what `dup`/`dup2`/redirect manipulate.** Per-fd offset; ref-counted across processes.
