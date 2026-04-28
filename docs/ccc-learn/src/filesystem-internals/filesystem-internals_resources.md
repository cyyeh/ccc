# filesystem-internals: Further Learning Resources

---

## Books

**[Operating Systems: Three Easy Pieces — Part 4 (Persistence)](http://pages.cs.wisc.edu/~remzi/OSTEP/)**
- Free online. Chapters 36–43 cover everything: I/O devices, hard disks, RAID, the filesystem abstraction, FFS, journaling, log-structured FS. The undisputed best beginner intro to filesystems. Difficulty: Beginner.

**[The xv6 book — Chapter 8 (File system)](https://pdos.csail.mit.edu/6.S081/2024/xv6/book-riscv-rev3.pdf)**
- Closest companion to `ccc`'s FS — same shape, same algorithms. Free PDF. Difficulty: Beginner-to-Intermediate.

**[The Design of the UNIX Operating System — Maurice Bach](https://www.amazon.com/Design-UNIX-Operating-System/dp/0132017997)**
- The canonical V7 Unix internals book. Chapter 4 (File Subsystem) describes the very same algorithms `ccc` uses, in their original form. Difficulty: Intermediate.

**[Practical File System Design — Dominic Giampaolo](http://www.nobius.org/dbg/practical-file-system-design.pdf)**
- Free PDF. The author designed BeFS. The discussion of B+ trees vs linear scan is gold. Difficulty: Intermediate.

---

## Filesystem documentation (real-world)

**[ext2 (Linux) On-Disk Format](https://www.nongnu.org/ext2-doc/ext2.html)**
- The simplest production Linux FS. Inode-based, very similar to xv6 / `ccc`'s structure but with more sophisticated indirect block schemes. Difficulty: Reference.

**[ext4 documentation](https://www.kernel.org/doc/html/latest/filesystems/ext4/index.html)**
- Modern Linux production FS. Extents, htree directories, journaling. Difficulty: Advanced.

**[ZFS on-disk format](http://www.giis.co.in/Zfs_ondiskformat.pdf)**
- Copy-on-write semantics, integrated checksumming. Vastly different from `ccc`'s approach. Difficulty: Advanced.

---

## Comparable code

**[xv6-riscv: `kernel/fs.c`](https://github.com/mit-pdos/xv6-riscv/blob/riscv/kernel/fs.c)**
- The parent of `ccc`'s FS. ~700 lines that map almost line-for-line onto `ccc/src/kernel/fs/`. Difficulty: Intermediate.

**[xv6-riscv: `kernel/bio.c`](https://github.com/mit-pdos/xv6-riscv/blob/riscv/kernel/bio.c)**
- The bufcache. Identical algorithm to `ccc`'s. Difficulty: Intermediate.

**[Linux: `fs/ext2/inode.c`](https://github.com/torvalds/linux/blob/master/fs/ext2/inode.c)**
- Production ext2 inode handling, including double- and triple-indirect blocks. Difficulty: Advanced.

**[Plan 9's fossil](https://9p.io/sys/doc/fossil.pdf)**
- A different design altogether. Read for perspective on what filesystems *can* be. Difficulty: Advanced.

---

## Lectures

**[MIT 6.S081 Lecture 14 (Filesystems)](https://pdos.csail.mit.edu/6.S081/2024/schedule.html)**
- Free video. Walks through xv6's FS in detail. Pair with the xv6 chapter.

**[Bryan Cantrill on the FS history](https://www.youtube.com/results?search_query=cantrill+filesystem)**
- Various conference talks. Cantrill's stories on the evolution of UFS, ZFS, BeFS are illuminating.

---

## Articles & papers

**[A Fast File System for UNIX — McKusick et al. (1984)](https://docs.freebsd.org/en/articles/fast-fs/article.pdf)**
- Free PDF. The paper that introduced FFS — cylinder groups, fragmentation handling. The lineage of every Unix FS since. Difficulty: Intermediate.

**["The UNIX Time-Sharing System" — Ritchie & Thompson (1974)](https://www.bell-labs.com/usr/dmr/www/cacm.html)**
- The original Unix paper. Section on the file system describes V6's design, which is what xv6 (and `ccc`) follow. Difficulty: Intermediate.

**[LWN's "An overview of Linux filesystems"](https://lwn.net/Articles/Filesystems/)**
- Various LWN articles surveying the Linux FS landscape. Difficulty: Intermediate.

---

## Tools

**`hexdump -C zig-out/shell-fs.img | head -40`**
- The literal first 1280 bytes of the image. The boot sector (zeros), the superblock magic (`0xC3CCF500`), the bitmap. Every byte is documented in `layout.zig`.

**[`xxd zig-out/shell-fs.img`](https://man7.org/linux/man-pages/man1/xxd.1.html)**
- Like `hexdump` but with editing support. Useful for surgically modifying an image to test corner cases.

**[`debugfs` (for ext2/3/4) on Linux](https://man7.org/linux/man-pages/man8/debugfs.8.html)**
- Live FS inspector. Read inodes by inum, dump bitmaps, walk directories. There's no analog for `ccc`'s FS, but the workflow inspires similar tools.

**`zig build fs-img && hexdump -C zig-out/fs.img | grep -A 1 'C3 CC F5 00'`**
- Find the superblock magic in the image to verify mkfs ran correctly.

---

## When you're ready

Next: **[console-and-editor](#console-and-editor)** — how the kernel turns keystrokes into lines (cooked mode) and how the editor escapes that to draw on the terminal (raw mode + ANSI).
