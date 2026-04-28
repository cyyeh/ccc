# filesystem-internals: Practice & Self-Assessment

---

## Section 1: True or False (10 questions)

**1.** `ccc`'s disk image is exactly 4 MB.

**2.** Each block is 4 KB.

**3.** An inode holds 13 block pointers: 12 direct and 1 indirect.

**4.** A `DiskInode` is exactly 256 bytes.

**5.** Directories are stored in a special "directory area" of the disk, separate from data blocks.

**6.** The `.` and `..` entries are added by the kernel automatically when a process opens a directory.

**7.** `bmap` always allocates a new block when called.

**8.** A `dirlink` may either reuse an empty slot or append a new one.

**9.** When you `unlink` a file while it's open, the data blocks are freed immediately.

**10.** `mkfs` is a host-side program, not part of the kernel.

### Answers

1. **True.** 1024 blocks × 4 KB = 4 MB.
2. **True.** `BLOCK_SIZE = 4096` in `layout.zig`.
3. **True.** `addrs[0..11]` direct + `addrs[12]` indirect.
4. **True.** Including padding. 16 inodes per block.
5. **False.** Directories are *regular files* whose contents happen to be DirEntry records. Stored in normal data blocks.
6. **False.** They're written by `mkdir` (or `mkfs` for the root) at directory creation. The kernel just reads them like any other entry.
7. **False.** Only when `for_write=true` AND the slot is currently 0. Otherwise it returns the existing block number.
8. **True.** Reuse if there's a slot with `inum=0`; append otherwise.
9. **False.** Blocks are freed when *both* `nlink == 0` AND `refcnt == 0`. If a process still has the file open, blocks stay until close.
10. **True.** `mkfs.zig` is a host-target executable, run by `zig build fs-img` to produce the image. Not part of `kernel.elf`.

---

## Section 2: Multiple Choice (8 questions)

**1.** What's the maximum file size in `ccc`?
- A. 4 KB.
- B. 48 KB (12 direct × 4 KB).
- C. ~4.2 MB (12 direct + 1024 indirect, all × 4 KB).
- D. Limited only by disk size.

**2.** Where does the bitmap live?
- A. In the superblock.
- B. In a separate file at `/`.
- C. Block 2 of the disk (one 4 KB block).
- D. In RAM only.

**3.** What does `iget` do that `ilock` doesn't?
- A. Reads the on-disk inode into memory.
- B. Increments the in-memory inode's refcount; locks not yet acquired.
- C. Acquires the inode's lock.
- D. Allocates a new disk inode.

**4.** When does `bmap` perform `balloc`?
- A. Always, on every call.
- B. Never; `balloc` is called separately by `writei`.
- C. When `for_write=true` AND the relevant slot in `addrs` is 0.
- D. When the bufcache is full.

**5.** What's the relationship between a `File` (in `file.zig`) and an `Inode`?
- A. They're the same thing.
- B. A `File` has a `*Inode` plus per-fd state (offset, ref count).
- C. `File` is for fds; `Inode` is for `mkfs`.
- D. `File` holds the data; `Inode` is metadata only.

**6.** When `cat` reads from fd 0 (stdin), where does the byte come from?
- A. An on-disk file at /dev/stdin.
- B. A Console-type File entry, which reads from the cooked-mode line discipline.
- C. The kernel hardcodes "type whatever you want" for fd 0.
- D. Direct UART register access.

**7.** What's the role of `iupdate`?
- A. Update the on-disk superblock.
- B. Flush an in-memory inode's modified fields back to its disk slot.
- C. Update the bitmap after a `bfree`.
- D. Update the file's `size` field only.

**8.** Why does `dirlink` linear-scan instead of using a hash?
- A. It does use a hash internally.
- B. Directory churn is low enough that linear scan is fine for `ccc`'s scale.
- C. Hashes don't work on RISC-V.
- D. xv6 doesn't have hashes.

### Answers

1. **C.** ~4.2 MB. Specifically (12 + 1024) × 4096 = 4,243,456 bytes.
2. **C.** Block 2. The whole bitmap (1024 bits = 128 bytes used, rest unused) fits in one 4 KB block.
3. **B.** `iget` finds-or-allocates a cache slot, increments refcount. `ilock` is the slow path that acquires the lock and (if !valid) loads from disk.
4. **C.** Lazy alloc on write to a hole.
5. **B.** Multiple `File`s can share the same `Inode` (e.g., the same file opened twice gets two `File`s with the same `*Inode`, two offsets).
6. **B.** fd 0/1/2 are Console-type Files. Read goes through `console.read` (cooked-mode line buffer); write through `console.write` (UART TX).
7. **B.** Specifically, the part of the disk inode that the in-memory copy might have changed (size, addrs, type, nlink).
8. **B.** Small directories, low churn. Both xv6 and `ccc` accept the O(N) cost. ext4 et al. use hashes/btrees for huge directories.

---

## Section 3: Scenario Analysis (3 scenarios)

**Scenario 1: A file you can't delete**

You write 100 MB of data to `/tmp/big`. The file is created, blocks are allocated. You `unlink /tmp/big`. The bitmap shows the blocks are still allocated. Why?

1. What state is the inode in?
2. What needs to happen to actually free the blocks?
3. What command on a real Unix would let you confirm this?

**Scenario 2: A directory that grows**

A test creates 10000 files in `/tmp/`. The directory grows. You then `unlink` 9999 of them. The directory is now mostly empty slots.

1. What's `dp.size` after the 10000 creates?
2. What's `dp.size` after the 9999 unlinks?
3. Does the directory ever shrink?

**Scenario 3: A bufcache eviction race**

Process A is reading block 9. Process B asks for block 11, the bufcache is full, the LRU buffer happens to hold block 9. What happens?

1. Can process B evict A's buffer?
2. What happens to A's read in progress?
3. How is this prevented?

### Analysis

**Scenario 1: A file you can't delete (yet)**

1. The inode's `nlink` is now 0 (no directory entry references it). But `refcnt > 0` because the file is still open. The Inode struct in cache has type unchanged, addrs unchanged.
2. The last open fd must be closed. When `iput` runs and sees `refcnt == 0 and nlink == 0`, it calls `itrunc` which `bfree`s every block, then sets `type = 0` and `iupdate`s.
3. On real Unix: `lsof | grep big` shows which process holds the open fd. `df` shows the blocks are still in use until that process closes.

**Scenario 2: A growing directory**

1. After 10000 creates: every dirent is 16 bytes; plus `.` and `..`. Size = (10000 + 2) × 16 = 160,032 bytes.
2. After 9999 unlinks: the *zeroed* dirents are still there (slots reused on next create, not reclaimed). Size unchanged at 160,032 bytes.
3. `ccc` doesn't compact directories. The size stays. Real production FSes vary — ext4 has online directory compaction; some require an offline tool.

**Scenario 3: A bufcache eviction race**

1. No. Process A holds `BUF_LOCKED` on block 9's buffer. Process B's eviction code looks for an unlocked, refcnt-zero buffer. A's buffer fails both checks (locked, refcnt ≥ 1).
2. A's read continues. B blocks: it's in `bget` for block 11 and can't find a victim. It sleeps on `&buf_pool`. When A calls `brelse`, refcnt drops, `wakeup(&buf_pool)` fires, B retries and finds a now-unlocked buffer (maybe A's, maybe a different LRU one).
3. The locking + sleep-on-busy protocol prevents it. B sleeps until *some* buffer becomes evictable.

---

## Section 4: Reflection Questions

1. **Why one indirect, not two?** What's the cost of supporting double-indirect (max file size becomes ~4 GB)? When is it worth it?

2. **The `nlink == 0 && refcnt == 0` rule.** Why both, not either? Sketch a scenario where checking only one would corrupt.

3. **Linear-scan directories.** When does this become unacceptable? What's the ext4 alternative (htree)? What's the conceptual cost (complexity vs read locality)?

4. **The bufcache's sleep-on-busy.** Without locking, what's the worst-case race? Concrete example.

5. **`mkfs` as a host-side tool.** Could the kernel format an in-memory disk on first boot? What would it cost?
