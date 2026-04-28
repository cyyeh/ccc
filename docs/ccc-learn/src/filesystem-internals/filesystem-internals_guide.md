# filesystem-internals: A Beginner's Guide

## What's a Filesystem, Really?

A *disk* is a long list of numbered slots, each holding a few KB. Disk slot #5 is just bytes; nothing inside it tells you "this is part of a file." The bytes have no inherent meaning.

A *filesystem* is the imposed structure on top: a set of conventions that say "block #2 is the bitmap; block #3 has the inode table; block #5 holds the contents of `/etc/motd` because inode 7's `addrs[0]` says so."

Filesystems are pure software conventions. The disk doesn't know or care.

`ccc`'s filesystem is one of the simplest possible designs: 4 MB total, 4 KB blocks, two-level addressing (12 direct + 1 indirect). It's modeled after V6 Unix and xv6.

---

## The Library Catalog Analogy

Think of a library:

- **Books** are *files*. They have content (the words inside) and metadata (title, author, page count).
- **Index cards** are *inodes*. Each card describes one book — type, length, where it lives.
- The **catalog cabinet** with all the cards is the *inode table*. Numbered drawers; each drawer holds 16 cards.
- **Shelves** are *data blocks*. Each shelf holds bytes of book content.
- **Directories** are *binders* of "see also" cards. To find "Moby Dick by Herman Melville," you look in the "American Literature" binder for an entry pointing at card #347.
- The "available shelves" board is the **bitmap**. A pin in slot N means shelf N is in use.
- The librarian's master log (which slots are inodes vs data, total counts) is the **superblock**.

When you say `cat /etc/motd`:

1. Look in the root directory binder for `etc`. Find inum 4. Walk to drawer 4, get card 4. It's a directory.
2. Look in directory 4's binder for `motd`. Find inum 7. Walk to drawer 7, get card 7. It's a file with size 19 bytes, addrs[0] = block 9.
3. Walk to shelf 9, read the first 19 bytes. Print them.

Three "walks" total. Each walk is a `bread` (block read) into the bufcache.

---

## What's an Inode?

An inode is a fixed-size record describing one file. In `ccc`:

```
type:    1 byte         (Free / File / Dir)
nlink:   1 byte         (how many directory entries reference this inode)
size:    4 bytes        (bytes in this file)
addrs[13]: 13 × 4 bytes (block pointers)
+ padding to round up to 256 bytes
```

The `addrs` array is special:
- `addrs[0..11]` are **direct** block pointers. Each holds the block number where part of the file's content lives.
- `addrs[12]` is an **indirect** pointer. The block it points at is *another* array — 1024 more block numbers. So one indirect block extends the file by another 1024 blocks.

Total: 12 + 1024 = 1036 blocks per file. At 4 KB each, max file size = 4.2 MB. Just shy of the whole disk — by design, no single file can fill the FS.

---

## Why Two Levels?

Why not just put 1024 block numbers in the inode directly? Because most files are small. If every inode were 4 KB just to hold all those pointers, 64 inodes would be 256 KB of metadata for files that might average 1 KB of content. The two-level scheme:

- Small file (<= 48 KB): inode + direct addrs only. No indirect block. Cheap.
- Larger file: pay one extra block read (the indirect) for files between 48 KB and 4 MB.

Real filesystems (ext4, xfs) use *more* levels — double-indirect, triple-indirect — to support multi-TB files. `ccc`'s simple two-level is enough for a 4 MB disk.

---

## How Does a Directory Work?

A directory is just a file with a special `type` and a special content format. The content is an array of records:

```
record 0: inum=1, name="."
record 1: inum=1, name=".."
record 2: inum=4, name="bin"
record 3: inum=7, name="etc"
...
```

Each record is 16 bytes (2-byte inum + 14-byte name). When you `ls /etc`, the kernel:

1. Walks the path: root → "etc" → inode for `/etc`.
2. Reads the inode. It's a directory.
3. Reads the directory's data blocks.
4. Iterates over records, prints each name.

Directory **lookup** is linear-scan: walk every record looking for a matching name. With dozens of files, this is microseconds. With millions, you'd want a hash or B-tree (which is what real filesystems use).

The **`.` and `..`** entries are present in every directory. `.` is the directory itself; `..` is its parent. The root directory has `..` pointing back at itself (it's its own parent).

---

## What's a Bitmap For?

When you create a new file, you need to allocate one or more new data blocks. The bitmap tells you which blocks are free.

`ccc`'s bitmap is one 4 KB block (block #2). 4096 bytes × 8 bits/byte = 32768 bits — vastly more than the 1024 blocks we have, so the bitmap has tons of spare capacity. Bit `n` set = data block `n` is allocated.

Allocate: scan from the start, find the first clear bit, set it, return its index. Free: clear the bit.

This is O(NBLOCKS) per allocation. With 1024 blocks, fast. Real filesystems use more sophisticated allocators (extent trees, free-space btrees) to handle terabyte disks.

---

## What's the Buffer Cache For?

Every disk I/O is "slow" (in `ccc`, ~µs since it's just memcpy from a host-file pread; on real hardware, ms for spinning rust). The kernel keeps recently-read blocks in RAM so subsequent reads are free.

`ccc`'s bufcache is a fixed array of 16 buffers. When you ask for block 9:
- If it's already in the cache: bump refcount, return it.
- If not: pick the LRU buffer, write its contents back to disk if dirty, replace with block 9's contents.

The bufcache is the layer that makes the FS fast enough to feel real. Without it, every `readi` would issue a fresh disk request.

---

## A Concrete Walk: `cat /etc/motd`

You type `cat /etc/motd` in the shell. Eventually the shell forks+execs `/bin/cat` with argv=`["cat", "/etc/motd"]`. cat does:

```c
int fd = open("/etc/motd", O_RDONLY);
char buf[256];
int n = read(fd, buf, 256);
write(1, buf, n);
close(fd);
exit(0);
```

The kernel side:

1. **`openat(AT_FDCWD, "/etc/motd", O_RDONLY)`**:
   - `namei("/etc/motd", cwd)`:
     - Start at root (inum 1, since path begins with `/`).
     - Read root's directory. Find "etc" → inum 4.
     - Read inode 4. It's a Dir.
     - Read inode 4's directory. Find "motd" → inum 7.
     - Read inode 7. It's a File. Return it.
   - Allocate a new fd, pointing at a new `File` struct of type Inode, ip=inode-7, off=0.
   - Return fd 3.

2. **`read(3, buf, 256)`**:
   - Look up fd 3 → File → ip=inode 7.
   - Call `readi(ip, buf, off=0, 256)`.
   - `bmap(ip, 0, false)` → returns block 9 (whatever was allocated).
   - `bread(9)` → loads block 9 into a Buf in the cache.
   - Copy 19 bytes (size of file) into `buf`. Update File.off.
   - Return 19.

3. **`write(1, buf, 19)`**:
   - Look up fd 1 → File of type Console.
   - Call `console.write(buf, 19)`.
   - For each byte: `uart.putByte(byte)`.

4. **`close(3)`**: `file.put` decrements refcount; if 0, `iput` decrements inode refcount.

5. **`exit(0)`**: Cat exits.

That's the full filesystem path for reading a small file. Three layers (`namei`, `readi`, `bread`) and a bufcache underneath.

---

## Quick Reference

| Concept | One-liner |
|---------|-----------|
| Block | 4 KB unit. Disk has 1024 of them. |
| Inode | File metadata + 13 block pointers. 256 bytes. |
| `addrs[0..11]` | Direct block pointers. |
| `addrs[12]` | Indirect: points at a block of 1024 more pointers. |
| Bitmap | One bit per data block. 1 = allocated. |
| Superblock | Block 1. Holds layout constants + magic. |
| Directory | A regular file whose content is DirEntry records. |
| DirEntry | 2-byte inum + 14-byte name = 16 bytes. |
| `.` and `..` | Self and parent. Every directory has them. |
| `namei` | Walk a path string component-by-component. |
| Bufcache | 16-buf LRU of recently-accessed blocks. |
| `bmap` | inode block index → disk block number. |
| `bread` | Load a block from disk via bufcache. |
| Inode cache | 32-entry parallel cache of in-memory `Inode` structs. |
| `iget` / `ilock` / `iput` | Refcount, lock, unrefcount in-memory inodes. |
| File / fd | Per-process open file: ref-counted, has its own offset. |
| Console fd | fd 0/1/2 backed by line discipline + UART, not by an inode. |
