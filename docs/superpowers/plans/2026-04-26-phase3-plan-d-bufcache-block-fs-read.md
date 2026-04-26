# Phase 3 Plan D — bufcache + block driver + FS read path (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the entire FS read path on top of Phase 3.C's process lifecycle. Add a kernel-side PLIC driver (`plic.zig`) that wraps the emulator's PLIC MMIO; wire S-external delegation (`mideleg.SEIP=1` in `boot.S`, `sie.SEIE=1` in `kmain`, `claim → dispatch → complete` in `trap.zig`'s S-external branch). Add a kernel-side block driver (`block.zig`) that submits one outstanding I/O at a time and sleeps the caller on `&req` until the ISR wakes them. Add the buffer cache (`fs/bufcache.zig`, `NBUF=16`) with `bget`/`brelse`/`bread`/`bwrite` and sleep-on-busy semantics. Add the FS layer: `fs/layout.zig` (on-disk constants, `SuperBlock`, `DiskInode`), `fs/balloc.zig` (block bitmap with `alloc`/`free` — write side lands in 3.E, but `init` runs from disk now), `fs/inode.zig` (in-memory inode cache `NINODE=32` with `iget`/`iput`/`ilock`/`iunlock`, `bmap`, `readi`), `fs/dir.zig` (`DirEntry` records + `dirlookup`), and `fs/path.zig` (`namei`/`nameiparent`, absolute paths from root + relative paths from `cur.cwd`). Add the file table (`file.zig`, `NFILE=64`) with `File` ref-counted entries (only `FileType.Inode` lands in 3.D — the `FileType.Console` variant is 3.E), and per-process `ofile[NOFILE=16]` + `cwd` fields on `Process`. Update `proc.fork` to `file.dup` every open fd and `inode.dup` `cwd`; update `proc.exit` to `file.close` every open fd and `inode.iput` `cwd`. Replace `proc.exec`'s embedded-blob lookup (`boot_config.lookupBlob`) with `path.namei + inode.readi` into a kernel scratch buffer, then call `elfload.load` against that buffer — embedded blobs become a 3.C-only path that the fs-mode kernel skips entirely. Wire 7 syscalls: 17 (`getcwd`), 49 (`chdir`), 56 (`openat`), 57 (`close`), 62 (`lseek`), 63 (`read`), 80 (`fstat`). Boot from disk: `kmain` gets a new `FS_DEMO` arm that initializes `bufcache + balloc + inode + boot_config`'s static state, allocates PID 1, builds a minimal user AS (just `allocRoot + mapKernelAndMmio` — no user pages, since exec replaces everything), then directly calls `proc.exec("/bin/init", &empty_argv)` from kmain context (since `cur() == &ptable[0] == pid1` before the scheduler boots). Add `mkfs.zig` (host tool): `--root <dir>`, `--bin <dir>`, `--out <path>` — walks both directory trees, lays out a 4 MB image with the spec's superblock + bitmap + inode table + data blocks. Add a new `init` binary (`src/kernel/user/fs_init.zig`) that opens `/etc/motd`, reads it into a buffer, writes the buffer to fd 1, exits 0 — installed onto fs.img as `/bin/init`. Add `src/kernel/userland/fs/etc/motd` ("hello from phase 3\n", 19 bytes) as the staged content for mkfs's `--root`. Build wires: `mkfs` target (host); `kernel-fs-init` target (RV32 init.elf for fs.img); `fs-img` target (runs mkfs against the staged dir + kernel-fs-init.elf to produce `zig-out/fs.img`); `fs_boot_config.zig` stub (`FS_DEMO=true`, no embedded blobs); `kernel-fs.elf` executable; `tests/e2e/fs.zig` host harness; `e2e-fs` step (spawns `ccc --disk fs.img kernel-fs.elf`, expects exit 0, asserts stdout *contains* `"hello from phase 3\n"` and ends with `"ticks observed: N\n"`). Plan 3.A's `e2e-plic-block`, Plan 3.B's `e2e-multiproc-stub`, and Plan 3.C's `e2e-fork` keep passing unchanged.

**Architecture:** Phase 3.C left the kernel able to fork+exec embedded blobs but with no path to disk: no PLIC dispatch in S-mode, no block driver, no FS, no `cwd`/`ofile` on `Process`, and `proc.exec` baked in `boot_config.lookupBlob` as the only resolver. 3.D fills the entire chain from "device IRQ fires" to "user reads file bytes". The PLIC driver in `plic.zig` exposes 4 functions (`setPriority`, `enable`, `claim`, `complete`) that wrap MMIO at `0x0c000004 / 0x0c002080 / 0x0c201004` (matching `programs/plic_block_test/boot.S`'s constants). `boot.S` adds `mideleg.SEIP = 1` (bit 9) so external interrupts flow to S; `kmain` adds `sie.SEIE = 1` and calls `plic.setPriority(IRQ_BLOCK, 1) + plic.enable(IRQ_BLOCK) + plic.setThreshold(0)` after `page_alloc.init`. `trap.zig`'s `s_trap_dispatch` gains a third async branch: `if (is_interrupt and cause == 9) { const irq = plic.claim(); switch (irq) { 1 => block.isr(), else => kprintf.panic("unknown PLIC src") }; plic.complete(irq); return; }`. The block driver (`block.zig`) is the spec's "single-outstanding" model: a global `req: struct { state, err, waiter }` plus `submit(blk, buf, cmd)` which writes the four MMIO registers, sets `req.state = .Pending`, calls `proc.sleep(@intFromPtr(&req))`, and on wake panics if `req.err`. `block.isr()` reads STATUS, sets `req.err`/`req.state = .Done`, and calls `proc.wakeup(@intFromPtr(&req))` — this is the first real ISR sleeper-waker pair in the kernel (3.C's wait/exit only sleeps on PIDs from process context). The buffer cache (`fs/bufcache.zig`) sits on top: `NBUF=16` `Buf` structs each holding 4 KB + metadata, doubly-linked LRU list, `bget(blk)` searches for an existing buffer with that block (incrementing refs and sleep-locking it; if `busy`, sleeps on the buffer until the holder calls `brelse`); if no match, picks the LRU evictee with `refs == 0` and reassigns it. `bread` is `bget + (if !valid) block.read(blk, &buf.data)`; `brelse` releases the lock, bumps LRU position, decrements refs, and `proc.wakeup(@intFromPtr(&buf))`. The FS layer follows xv6 closely — `fs/layout.zig` defines `BLOCK_SIZE=4096`, `NBLOCKS=1024`, `NINODES=64`, the SuperBlock + DiskInode `extern struct`s; `fs/balloc.zig` exposes `bitmap.alloc()` and `bitmap.free(blk)` reading/writing the bitmap block; `fs/inode.zig` holds the `InMemInode` cache (`NINODE=32`), `iget(inum)` (returns existing entry or claims an empty slot), `ilock(ip)` (sleeps on busy then loads `valid=false` inodes from disk), `iput(ip)` (decrements refs; in 3.D, no on-disk truncate since write is 3.E), `bmap(ip, bn)` (returns the data block# for logical block `bn`, walking the inode's 12 direct + 1 indirect addresses; returns 0 for unallocated — read-only in 3.D), `readi(ip, dst, off, n)` (loops over `bmap → bread → memcpy → brelse`, treats reads past EOF as 0 bytes returned). `fs/dir.zig` is purely about directory data: `dirlookup(dir_ip, name) → ?inum` linear-scans the directory's `DirEntry` records via `readi`. `fs/path.zig` walks the path: `namei("/foo/bar")` starts at root inum 1 (held in `boot_config.ROOT_INUM` constant), walks left-to-right calling `dirlookup` per component, returns the final `*InMemInode` (or null on missing component). `nameiparent("/foo/bar", out: *[14]u8)` returns the parent inode + writes the leaf name into `out` — used by `openat` with `O_CREAT` (deferred to 3.E) and by `chdir` indirectly. Both walk iteratively with no recursion. The file table (`file.zig`) holds `NFILE=64` `File` entries: `{ ref_count: u32, type: FileType, ip: *InMemInode, off: u32 }`. In 3.D, `type` is always `.Inode` (3.E adds `.Console`). `file.alloc()` finds a `ref_count == 0` slot and bumps it; `file.dup(f)` increments `ref_count`; `file.close(f)` decrements and on zero `iput(f.ip)`s. `file.read(f, dst, n) → bytes/-1` is `readi(f.ip, dst, f.off, n) → bumps f.off → returns`. The Process struct gets two new fields: `ofile: [NOFILE=16]u32` (file table indices, 0 = empty slot — we shift the file table so index 0 is reserved-as-null) and `cwd: u32` (the `*InMemInode` cast to u32, 0 = root which is special-cased on first dereference). `proc.fork` walks `parent.ofile`, `file.dup`s every non-zero entry into `child.ofile[i]`, then `inode.dup(parent.cwd)` (just bumps cwd's refs) into `child.cwd`. `proc.exit` walks `cur.ofile`, `file.close`s every non-zero entry, then `inode.iput(cur.cwd)`. The kicker: `proc.exec` no longer calls `boot_config.lookupBlob` — it now opens the path via `namei`, allocates a kernel scratch buffer (`page_alloc.alloc` * `(file_size + PAGE_SIZE - 1) / PAGE_SIZE` pages, ELF capped at 64 KB so we use `MAX_EXEC_BLOB = 16 * PAGE_SIZE = 64 KB` from a single `page_alloc.allocContig(16)` — except `page_alloc` doesn't do contiguous allocation, so we instead allocate one page at a time and `readi` the file in chunks straight into `elfload.load`'s expected buffer shape, OR we constrain init.elf to ≤ 16 KB (4 pages) and do a 4-allocation loop with manual contiguity check). Concrete approach in 3.D: use a single static 64 KB `.bss` scratch buffer (`exec_scratch: [16][4096]u8 align(4)` declared in `proc.zig`), `readi` the file into it, pass a slice to `elfload.load`. The single-buffer approach is fine because exec is single-threaded (only one process exec's at a time — 3.D has no preemption-safe concurrent exec model; the next plan-3.E rework can revisit if needed). The 64 KB cap matches the spec's user `.text`/`.rodata` budget (`USER_TEXT_VA + 0x10000`). The 7 new syscalls are wired in `syscall.zig`'s dispatch arm: 17 (`getcwd`) writes `cur.cwd`'s path back via SUM=1 (we keep a synthesized path string by walking parent inodes — or simpler in 3.D: store the path as a fixed-length string on Process when chdir succeeds; recompute on chdir, copy on getcwd); 49 (`chdir`) namei's the target, verifies it's a directory, iputs old cwd, idups new cwd; 56 (`openat`) namei's the path, allocates a `File`, points it at the inode, returns the lowest-free fd; 57 (`close`) `file.close`s `cur.ofile[fd]`, zeroes the slot; 62 (`lseek`) updates `cur.ofile[fd].off` per whence; 63 (`read`) calls `file.read`; 80 (`fstat`) writes `Stat { type, size }` back via SUM=1. Boot from disk: `kmain` gets an `FS_DEMO` arm that comes BEFORE the existing `FORK_DEMO` arm. It calls `bufcache.init() + inode.init()`, allocates PID 1 via `proc.alloc`, builds a minimal AS (just `vm.allocRoot + vm.mapKernelAndMmio`), sets `pid1.cwd = inode.iget(ROOT_INUM)` (the in-memory root inode), then calls `proc.exec("/bin/init", &empty_argv_ptr)` — since `cur() == &ptable[0] == pid1` before the scheduler boots and exec writes to `cur()`, this fully populates PID 1's AS in-place. Then kmain installs stvec/sscratch/sstatus and jumps into the scheduler same as the other modes. **Subtle:** `proc.exec` calls `csrw satp` to install the new pgdir into the active SATP; this is done BEFORE the unmapUser of the old (just-allocated, mostly-empty) pgdir. Since the new pgdir has the kernel direct map (via `mapKernelAndMmio`), kmain's instruction fetch and stack accesses survive the swap (kernel code lives at PA == VA in the kernel direct map). After exec returns, kmain ignores the return value (argc, == 0 here) and continues to scheduler setup. mkfs (`src/kernel/mkfs.zig`, host-compiled) takes `--root <dir>`, `--bin <dir>`, `--out <path>`; walks both trees, computes inode + block counts, lays out a 4 MB image: block 0 zeros, block 1 = SuperBlock, block 2 = bitmap (one bit per data block; bits set for blocks actually allocated), blocks 3-6 = inode table, blocks 7+ = data. mkfs creates a root directory inode (inum 1) containing entries for `bin/`, `etc/`, `.`, `..`; subdirectories for `bin` and `etc`; per the `--root` walk, populates `etc/motd` (and any other files); per the `--bin` walk, populates `bin/init` (and any other binaries). Build adds 4 new objects: `kernel-fs-init.elf` (the on-disk init userland program), `mkfs` (host tool), `fs.img` (built by running mkfs), and `kernel-fs.elf` (the FS-mode kernel built against `fs_boot_config.zig`). The new `e2e-fs` step uses `tests/e2e/fs.zig` (host harness): spawn `ccc --disk fs.img kernel-fs.elf`, capture stdout, assert exit 0, assert stdout *contains* `"hello from phase 3\n"`, assert stdout ends with the canonical `"ticks observed: N\n"` PID-1 trailer. The four prior e2e tests (`e2e-kernel`, `e2e-multiproc-stub`, `e2e-fork`, `e2e-plic-block`) all keep passing — none of 3.D's changes alter their inputs.

**Tech Stack:** Zig 0.16.x (pinned in `build.zig.zon`), no new external dependencies. The userland `fs_init.zig` continues to use the Plan 3.B / 3.C naked-`_start` pattern — full `start.S` / `usys.S` / `ulib` / `uprintf` stdlib remains a 3.E deliverable. `mkfs.zig` is host-Zig with `std.fs` and `std.Io`; `tests/e2e/fs.zig` follows the `tests/e2e/multiproc.zig` and `tests/e2e/fork.zig` pattern (host-compiled, spawn ccc, regex stdout). Cross-compilation reuses the existing `rv_target` ResolvedTarget. **No emulator code changes** — every Phase 3.A device (PLIC, block, UART, halt) already ships in `src/emulator/devices/` from the merged Plan 3.A.

**Spec reference:** `docs/superpowers/specs/2026-04-25-phase3-multi-process-os-design.md` — Plan 3.D covers spec §Architecture (kernel modules `block`, `fs/bufcache`, `fs/balloc`, `fs/inode`, `fs/dir`, `fs/path`, `file`, `plic`), §Memory layout (block device register map already covered in 3.A), §Privilege & trap model (External-interrupt flow), §Process model (`Process` struct extension with `cwd` + `ofile`; `proc.fork` and `proc.exit` extension to dup/close), §Filesystem (on-disk layout, inodes, directories, path resolution, buffer cache, block I/O driver — read path only), §Syscall surface rows for **17 (getcwd)**, **49 (chdir)**, **56 (openat)**, **57 (close)**, **62 (lseek)**, **63 (read)**, **80 (fstat)**, §`mkfs.zig` (host tool), §Implementation plan decomposition entry **3.D**. The xv6 source (Cox/Kaashoek/Morris MIT) remains the authoritative reference for the bcache + inode cache + path walker; when this plan and that source disagree, the spec is right.

**Plan 3.D scope (subset of Phase 3 spec):**

- **Kernel-side `plic.zig` (NEW)** — Driver for the emulator-side PLIC at `0x0c00_0000`:
  - **`pub fn setPriority(src: u32, prio: u32) void`** — write `prio` to `0x0c000000 + src*4`.
  - **`pub fn enable(src: u32) void`** — RMW `0x0c002080`'s S-context enable bits to set bit `src`.
  - **`pub fn setThreshold(t: u32) void`** — write `t` to `0x0c201000`.
  - **`pub fn claim() u32`** — read `0x0c201004`; returns the source ID (1..31), or 0 if no source pending.
  - **`pub fn complete(src: u32) void`** — write `src` to `0x0c201004`.
  - **MMIO** — direct `*volatile u32` writes via `@ptrFromInt`. Kernel's `mapKernelAndMmio` already maps `0x0c00_0000 .. 0x0c40_0000` as `S, R+W, G=1`.
  - **Constants:** `IRQ_BLOCK = 1` (matches the emulator's wiring).

- **Boot/trap S-external delegation (boot.S, kmain.zig, trap.zig)** — Wire IRQ #1 from device → trap.zig:
  - **`boot.S`** — extend `mideleg` to include `SEIP` (bit 9). Single-line change: add `MIDELEG_SEIP = (1 << 9)` to the `mideleg` write.
  - **`kmain.zig`** — after `page_alloc.init()` and before `proc.cpuInit()`: call `plic.setPriority(plic.IRQ_BLOCK, 1)`, `plic.enable(plic.IRQ_BLOCK)`, `plic.setThreshold(0)`; later (just before scheduler swtch), set `sie.SEIE = 1` (bit 9) alongside the existing `sie.SSIE = 1` write.
  - **`trap.zig`** — extend `s_trap_dispatch` with a third branch:
    ```zig
    if (is_interrupt and cause == 9) {
        // Supervisor external interrupt — claim → dispatch → complete.
        const irq = plic.claim();
        switch (irq) {
            plic.IRQ_BLOCK => block.isr(),
            else => kprintf.panic("unknown PLIC src: {d}", .{irq}),
        }
        plic.complete(irq);
        return;
    }
    ```
  - **3.D scope:** only IRQ #1 (block) is wired. UART RX (IRQ #10) is 3.E.

- **Kernel-side `block.zig` (NEW)** — Single-outstanding I/O driver:
  - **`Req` struct (file-private):**
    ```zig
    const ReqState = enum(u32) { Idle, Pending, Done };
    var req: struct {
        state: ReqState,
        err: bool,
        waiter: u32, // process pointer (for trace; bug catch only)
    } = .{ .state = .Idle, .err = false, .waiter = 0 };
    ```
  - **`pub fn read(blk: u32, dst_pa: u32) void`** — submits CMD=1, sleeps on `&req`, panics if `req.err`. `dst_pa` must be a 4-KB-aligned RAM PA (kernel direct map allows this).
  - **`pub fn write(blk: u32, src_pa: u32) void`** — submits CMD=2, sleeps, panics on err. Used by 3.E (bwrite); 3.D includes the function for symmetry but no caller exercises it yet.
  - **`pub fn isr() void`** — called from `trap.zig`'s S-external branch when `irq == IRQ_BLOCK`. Reads STATUS register, sets `req.err = (status != 0)`, sets `req.state = .Done`, calls `proc.wakeup(@intFromPtr(&req))`.
  - **MMIO** — `BLOCK_BASE = 0x1000_1000`, `SECTOR=+0x0`, `BUFFER=+0x4`, `CMD=+0x8`, `STATUS=+0xC` (matches `src/emulator/devices/block.zig`'s register map).
  - **Why this signature:** the bufcache calls `block.read(buf.block, @intFromPtr(&buf.data))` — and `buf.data` lives in kernel `.bss`, which is in the kernel direct map (PA == VA), so passing the address as a u32 is correct.

- **Buffer cache (NEW in `fs/bufcache.zig`)** — `NBUF=16` LRU buffers backing block I/O:
  - **`Buf` struct:**
    ```zig
    pub const Buf = struct {
        block: u32,
        valid: bool,
        dirty: bool,           // set by 3.E's bwrite; unused-but-tracked in 3.D
        refs: u32,
        busy: bool,            // sleep-locked
        data: [BLOCK_SIZE]u8 align(4),
        next: ?*Buf,           // doubly-linked LRU list, more-recent at head
        prev: ?*Buf,
    };
    pub var bcache: [NBUF]Buf = undefined;  // .bss; 16 * (4096 + ~24) = ~66 KB
    ```
  - **`pub fn init() void`** — wires the LRU list as `bcache[0] <-> bcache[1] <-> ... <-> bcache[15]` with `block = 0xFFFF_FFFF` (sentinel "never matched"), `valid = false`, `refs = 0`, `busy = false`. Called from `kmain` at FS-mode boot.
  - **`pub fn bget(blk: u32) *Buf`** — sleep-locks a buffer for `blk`:
    1. Walk the LRU list head→tail; if any `b.block == blk`, increment `b.refs`, then while `b.busy`, `proc.sleep(@intFromPtr(b))`. When the loop exits (`!b.busy`), set `b.busy = true`, return `b`.
    2. If no match, walk tail→head looking for `b.refs == 0 and !b.busy`. The first one found is the evictee: set `b.block = blk`, `b.valid = false`, `b.dirty = false`, `b.refs = 1`, `b.busy = true`, return `b`.
    3. If no evictable buffer, panic ("bcache: no buffers" — at NBUF=16 with ≤3 buffers per syscall, this should never trigger; xv6 makes the same call).
  - **`pub fn bread(blk: u32) *Buf`** — `bget(blk)` + (if `!valid`) `block.read(blk, @intFromPtr(&buf.data))` + `valid = true`.
  - **`pub fn bwrite(b: *Buf) void`** — `block.write(b.block, @intFromPtr(&b.data))` + `b.dirty = false`. (Not exercised by 3.D's read path — landed for 3.E.)
  - **`pub fn brelse(b: *Buf) void`** — release lock + bump LRU + decrement refs + wake waiters:
    1. `proc.wakeup(@intFromPtr(b))`.
    2. `b.busy = false`, `b.refs -= 1`.
    3. Move `b` to the head of the LRU list (it's "most recently released").

- **FS layout constants (NEW in `fs/layout.zig`)** — Pure data, no runtime:
  ```zig
  pub const BLOCK_SIZE: u32 = 4096;
  pub const NBLOCKS: u32 = 1024;            // 4 MB total
  pub const NINODES: u32 = 64;
  pub const INODES_PER_BLOCK: u32 = BLOCK_SIZE / @sizeOf(DiskInode);

  pub const SUPERBLOCK_BLK: u32 = 1;
  pub const BITMAP_BLK: u32 = 2;
  pub const INODE_START_BLK: u32 = 3;
  pub const DATA_START_BLK: u32 = 7;

  pub const ROOT_INUM: u32 = 1;
  pub const SUPER_MAGIC: u32 = 0xC3CC_F500;

  pub const NDIRECT: u32 = 12;
  pub const NINDIRECT: u32 = BLOCK_SIZE / 4;     // 1024
  pub const MAX_FILE_BLOCKS: u32 = NDIRECT + NINDIRECT;

  pub const FileType = enum(u16) { Free = 0, File = 1, Dir = 2 };

  pub const SuperBlock = extern struct {
      magic: u32,
      nblocks: u32,
      ninodes: u32,
      bitmap_blk: u32,
      inode_start: u32,
      data_start: u32,
      dirty: u32,
  };

  pub const DiskInode = extern struct {
      type: FileType,            // u16
      nlink: u16,
      size: u32,
      addrs: [NDIRECT + 1]u32,   // 12 direct + 1 indirect; 4 * 13 = 52
      _reserved: [4]u8,          // pad to 64 B (2 + 2 + 4 + 52 + 4 = 64)
  };

  comptime {
      std.debug.assert(@sizeOf(DiskInode) == 64);
  }

  pub const DIR_NAME_LEN: u32 = 14;
  pub const DirEntry = extern struct {
      inum: u16,
      name: [DIR_NAME_LEN]u8,    // 16-byte total
  };
  comptime { std.debug.assert(@sizeOf(DirEntry) == 16); }
  ```
  - Used by `mkfs.zig` (host) and every kernel `fs/` module.

- **Block bitmap (NEW in `fs/balloc.zig`)** — Read + alloc for the data-block bitmap:
  - **`pub fn alloc() u32`** — find the first 0 bit ≥ `DATA_START_BLK`, set it, write the bitmap block back, return the block number. Returns 0 (invalid block) on full disk.
  - **`pub fn free(blk: u32) void`** — clear the bit at `blk`, write the bitmap block back. Used by 3.E's `unlink`.
  - **`pub fn isFree(blk: u32) bool`** — read the bit (no write). Defensive helper.
  - **3.D:** mkfs has already set the bitmap bits for any file present at build time; 3.D's read path doesn't allocate new blocks (no write). `alloc`/`free` are landed for 3.E completeness.

- **Inode cache (NEW in `fs/inode.zig`)** — `NINODE=32` in-memory inode cache:
  - **`InMemInode` struct:**
    ```zig
    pub const InMemInode = struct {
        inum: u32,
        refs: u32,
        valid: bool,
        busy: bool,                // sleep-locked
        dinode: layout.DiskInode,  // cached on-disk copy (loaded by ilock)
    };
    pub var icache: [NINODE]InMemInode = undefined; // .bss
    ```
  - **`pub fn init() void`** — `for (icache) |*ip| { ip.* = .{ .inum = 0, .refs = 0, .valid = false, .busy = false, .dinode = undefined }; }`.
  - **`pub fn iget(inum: u32) *InMemInode`** — find an existing entry with matching `inum` (bump refs, return), else claim an empty slot (`refs == 0`), set `inum`, `refs = 1`, `valid = false`. Panics if no empty slot.
  - **`pub fn idup(ip: *InMemInode) *InMemInode`** — `ip.refs += 1; return ip;`. Used by `proc.fork` for `cwd` and by `openat` for shared opens.
  - **`pub fn ilock(ip: *InMemInode) void`** — sleep until `!ip.busy`, then `ip.busy = true`; if `!ip.valid`, `bread` the inode block, copy the slot into `ip.dinode`, `brelse`, `ip.valid = true`.
  - **`pub fn iunlock(ip: *InMemInode) void`** — `proc.wakeup(@intFromPtr(ip)); ip.busy = false;`.
  - **`pub fn iput(ip: *InMemInode) void`** — `ip.refs -= 1`. (3.E adds the on-zero on-disk truncate path.)
  - **`pub fn bmap(ip: *InMemInode, bn: u32) u32`** — translate logical block `bn` to on-disk block#. For `bn < NDIRECT`, return `ip.dinode.addrs[bn]`. For `bn < NDIRECT + NINDIRECT`, `bread` the indirect block (`ip.dinode.addrs[NDIRECT]`), read the `(bn - NDIRECT)`th u32, `brelse`. For `bn ≥ MAX_FILE_BLOCKS`, panic. **3.D: read-only**, returns 0 for unallocated entries (read-as-EOF). 3.E will lazy-allocate on write.
  - **`pub fn readi(ip: *InMemInode, dst: [*]u8, off: u32, n: u32) u32`** — copy `n` bytes from inode at `off` into `dst`. Handles boundary cases: clamps `off + n` to `ip.dinode.size`; for each 4 KB chunk, `bmap → bread → memcpy → brelse`. Returns bytes actually copied (0 if `off >= size`).

- **Directories (NEW in `fs/dir.zig`)** — Linear-scan flat 16-byte records:
  - **`pub fn dirlookup(dir: *InMemInode, name: []const u8) ?u32`** — scan `dir`'s data via `readi` 16 bytes at a time; for each `DirEntry` with `inum != 0` and `name` matches (NUL-padded comparison), return `inum`. Returns null if not found.
  - **`pub fn dirlink(dir: *InMemInode, name: []const u8, inum: u16) bool`** — find the first free slot (`inum == 0`) or append at `dir.size`; write the `DirEntry`. Used by 3.E's `mkdirat`. Landed in 3.D as a stub returning false (unused; the symbol exists so 3.E's syscall arm references compile).

- **Path resolution (NEW in `fs/path.zig`)** — Iterative left-to-right walker:
  - **`pub fn namei(path: []const u8) ?*InMemInode`** — split path on `/`; absolute paths start at `iget(ROOT_INUM)`; relative paths start at `idup(cur.cwd)`. For each component, `ilock(current); current = iget(dirlookup(current, component) orelse return null); iunlock(current); iput(prev_current);`. Returns the final inode (refs incremented), or null on missing component.
  - **`pub fn nameiparent(path: []const u8, name_out: *[DIR_NAME_LEN]u8) ?*InMemInode`** — same walk but stops one component short, writes the leaf component into `name_out` (NUL-padded). Used by 3.E (`mkdirat`, `unlinkat`, `openat` with O_CREAT). Landed in 3.D for symmetry.
  - **MAX_PATH=256, max component 13 bytes (DIR_NAME_LEN-1).** Both bounds enforced; over-long path or component returns null.

- **File table (NEW in `file.zig`)** — `NFILE=64` ref-counted `File` entries:
  - **`File` struct:**
    ```zig
    pub const FileType = enum(u32) { None = 0, Inode = 1, Console = 2 };
    pub const File = struct {
        type: FileType,
        ref_count: u32,
        ip: ?*inode.InMemInode,  // null for Console
        off: u32,
    };
    pub var ftable: [NFILE]File = undefined;  // .bss; slot 0 reserved as "null"
    ```
  - **`pub fn init() void`** — zeroes the table; slot 0 is permanently `ref_count = 0, type = None`.
  - **`pub fn alloc() ?u32`** — finds the first slot index ≥ 1 with `ref_count == 0`; sets `ref_count = 1`; returns the index. Returns null if no slot.
  - **`pub fn dup(idx: u32) u32`** — `ftable[idx].ref_count += 1; return idx;`.
  - **`pub fn close(idx: u32) void`** — `ftable[idx].ref_count -= 1`; if zero, `iput(f.ip)`, `f.* = std.mem.zeroes(File)`.
  - **`pub fn read(idx: u32, dst_user_va: u32, n: u32) i32`** — calls `inode.ilock(f.ip)` then `inode.readi(f.ip, kbuf, f.off, n)` into a kernel scratch buffer (`MAX_READ_CHUNK = 4096` bytes), `iunlock`s, then SUM-1 copies to user. Bumps `f.off` by bytes returned. Returns bytes (0 on EOF, -1 on error).
  - **`pub fn lseek(idx: u32, off: i32, whence: u32) i32`** — updates `f.off`; whence: 0=SET, 1=CUR, 2=END (END requires reading inode size via `ilock`).
  - **`pub fn fstat(idx: u32, stat_user_va: u32) i32`** — copies `Stat { type: u32, size: u32 }` from `f.ip.dinode` (with `ilock`/`iunlock`) into the user buffer (SUM=1). 8 bytes total.

- **Process struct extension (Process in `proc.zig`)** — Add `cwd` + `ofile` fields, update fork/exit:
  - **New fields** (appended to the existing Process; `extern struct` field order matters for the trampoline asm offsets but new fields are AFTER `parent`, so no asm impact):
    ```zig
    cwd: u32,                    // *InMemInode cast to u32; 0 = "use root inum 1"
    ofile: [NOFILE]u32,          // file table indices; 0 = empty
    ```
  - **`NOFILE = 16`** (matches spec).
  - **`proc.alloc` extension:** existing zeros-the-slot path covers `cwd = 0` and `ofile = .{0} ** NOFILE`. No further change.
  - **`proc.fork` extension:** after the existing `child.state = .Runnable` setup, but BEFORE `return @as(i32, @intCast(child.pid))`:
    ```zig
    // Dup every open fd into the child.
    var fi: u32 = 0;
    while (fi < NOFILE) : (fi += 1) {
        if (parent.ofile[fi] != 0) {
            child.ofile[fi] = file.dup(parent.ofile[fi]);
        }
    }
    // Dup parent's cwd (or default to root if parent hasn't chdir'd yet).
    if (parent.cwd != 0) {
        const ip: *inode.InMemInode = @ptrFromInt(parent.cwd);
        child.cwd = @intFromPtr(inode.idup(ip));
    } else {
        // parent was using lazy-root — child also lazy-roots; no idup needed.
        child.cwd = 0;
    }
    ```
  - **`proc.exit` extension:** before the reparent loop:
    ```zig
    // Close every open fd.
    var fi: u32 = 0;
    while (fi < NOFILE) : (fi += 1) {
        if (p.ofile[fi] != 0) {
            file.close(p.ofile[fi]);
            p.ofile[fi] = 0;
        }
    }
    // Iput cwd if held.
    if (p.cwd != 0) {
        const ip: *inode.InMemInode = @ptrFromInt(p.cwd);
        inode.iput(ip);
        p.cwd = 0;
    }
    ```

- **`proc.exec` rewrite for FS path (in `proc.zig`)** — Replace embedded blob lookup with `namei + readi`:
  - **Old (3.C):** `const blob = boot_config.lookupBlob(path) orelse return -1;`
  - **New (3.D):** if `boot_config.FS_DEMO`, use `path.namei + readi` into a kernel scratch buffer; else (3.C fork-mode kernels), keep `boot_config.lookupBlob` unchanged. The conditional is comptime-resolved per kernel build.
  - **Scratch buffer:** declare `var exec_scratch: [16][4096]u8 align(4) = undefined;` at file scope in `proc.zig`. Total 64 KB. Single-threaded so no contention. (3.E may revisit if exec re-entrancy becomes a concern.)
  - **Body change:**
    ```zig
    const blob = if (boot_config.FS_DEMO) blk: {
        const ip = path.namei(path) orelse return -1;
        defer inode.iput(ip);
        inode.ilock(ip);
        defer inode.iunlock(ip);
        if (ip.dinode.type != .File) return -1;
        const sz = ip.dinode.size;
        if (sz > 64 * 1024) return -1;
        const dst: [*]u8 = @ptrCast(&exec_scratch[0][0]);
        const got = inode.readi(ip, dst, 0, sz);
        if (got != sz) return -1;
        break :blk dst[0..sz];
    } else boot_config.lookupBlob(path) orelse return -1;
    ```
  - **Why a static scratch buffer:** the spec keeps the kernel heap-free. 64 KB matches the user `.text` budget (the spec's user VA layout caps user-text at `0x0000_1000 .. 0x000F_FFFF` = ~1 MB but per Plan 3.B the kernel's `mapUserStack`-aware `kmain` uses `USER_TEXT_VA + 0x10000` = 64 KB as the high-water for `sz`).

- **Syscall surface additions (in `syscall.zig`)** — Wire 7 new syscalls:
  - **17 (getcwd):** copy `cur.cwd`'s path into the user buffer. 3.D simplification: store the path string on `Process` directly (max 64 bytes, `cwd_path: [64]u8`); chdir writes it; getcwd copies it via SUM=1. If path overflow, return `-ERANGE` (`-34`). For lazy-root (cwd_path[0] == 0), copy `"/"` (1 byte + NUL). Returns bytes copied (excluding NUL) or `-1`.
  - **49 (chdir):** namei the path; verify `ip.dinode.type == .Dir`; iput old cwd; set `cur.cwd = @intFromPtr(ip)`; recompute `cur.cwd_path` (in 3.D: append the new component to the old path; if absolute path, replace; bounded to 64 bytes; on overflow, restore old cwd and return -1). Returns 0 / -1.
  - **56 (openat):** copy path from user (SUM=1, MAX_PATH=256); ignore `dirfd` (3.D treats it as if AT_FDCWD); namei the path (returns -1 if missing); allocate a `File` slot; set `f.type = .Inode, f.ip = ip, f.off = 0`; allocate the lowest-free `cur.ofile[]` slot (≥ 0); return the fd. On any failure path that already namei'd, `iput` the inode.
  - **57 (close):** if `cur.ofile[fd] == 0`, return -1. Else `file.close(cur.ofile[fd]); cur.ofile[fd] = 0; return 0;`.
  - **62 (lseek):** `file.lseek(cur.ofile[fd], off, whence)`. Returns new offset / -1.
  - **63 (read):** `file.read(cur.ofile[fd], buf_va, n)`. Returns bytes / 0 / -1.
  - **80 (fstat):** `file.fstat(cur.ofile[fd], statbuf_va)`. Returns 0 / -1.
  - **34 (mkdirat) / 35 (unlinkat):** NOT in 3.D. 3.E adds.
  - **64 (write):** UNCHANGED in 3.D. Continues to write to UART for fd 1/2; returns -EBADF for any other fd. (3.E extends to file fds via `file.write`.)

- **`mkfs.zig` (NEW host tool)** — Lays out a 4 MB FS image:
  - **CLI:** `mkfs --root <dir> --bin <dir> --out <path>`.
  - **Algorithm:**
    1. Allocate a 4 MB buffer (in-memory `[NBLOCKS * BLOCK_SIZE]u8`).
    2. Lay out SuperBlock at block 1.
    3. Initialize `inode_table` (in-memory) with `NINODES` empty `DiskInode`s.
    4. Initialize `bitmap` (in-memory `[NBLOCKS / 8]u8`) with bits 0..6 set (boot + superblock + bitmap + inodes blocks reserved).
    5. Walk `--root` directory tree recursively; for each file, allocate an inode, allocate enough data blocks for the file (set bitmap bits), copy file bytes into the data blocks. For each subdirectory, allocate a Dir inode, recurse, write the resulting `DirEntry` records (`.`, `..`, plus children) into the directory's data blocks.
    6. Walk `--bin` directory; for each file, install at `/bin/<filename>` (similar to step 5 but rooted at the `bin/` subdirectory).
    7. Root inode (inum 1) gets the top-level entries: `.`, `..` (both → root), plus subdirs `bin` and `etc`.
    8. Serialize SuperBlock + bitmap + inode_table + data into the 4 MB buffer.
    9. Write the buffer to `--out`.
  - **Bound:** total file count + dir count ≤ 64 (NINODES); total data blocks ≤ 1017 (NBLOCKS - DATA_START_BLK).

- **`src/kernel/userland/fs/etc/motd` (NEW content file)** — `"hello from phase 3\n"` (19 bytes). Source for mkfs's `--root`.

- **`src/kernel/user/fs_init.zig` (NEW userland program)** — On-disk `/bin/init` for the FS-mode kernel:
  - **Behavior:** open `/etc/motd` → read up to 256 bytes into a buffer → write the bytes to fd 1 → exit 0.
  - **Naked `_start` pattern** (matches 3.C's `init.zig` and `hello.zig`). 3.E will rewrite against the user stdlib.
  - **`.rodata`:** `path = "/etc/motd\0"` (10 bytes).
  - **`.bss`:** `buf: [256]u8`, `fd: i32`, `n: i32`.

- **`fs_boot_config.zig` build-time stub (NEW shape, 4th variant)** — Selects FS-mode kernel:
  ```zig
  const std = @import("std");
  pub const MULTI_PROC: bool = false;
  pub const FORK_DEMO: bool = false;
  pub const FS_DEMO: bool = true;
  pub const USERPROG_ELF: []const u8 = "";
  pub const USERPROG2_ELF: []const u8 = "";
  pub const INIT_ELF: []const u8 = "";
  pub const HELLO_ELF: []const u8 = "";
  pub fn lookupBlob(path: []const u8) ?[]const u8 {
      _ = path;
      return null;
  }
  ```
  - **Existing single + multi + fork stubs** add `pub const FS_DEMO: bool = false;`.

- **`kmain.zig` extension** — Existing FORK_DEMO + single + multi paths unchanged. NEW FS_DEMO arm placed BEFORE FORK_DEMO:
  ```zig
  if (boot_config.FS_DEMO) {
      // FS-mode boot: mount fs.img, then exec /bin/init from disk.
      bufcache.init();
      inode.init();

      // Wire PLIC for IRQ #1 (block).
      plic.setPriority(plic.IRQ_BLOCK, 1);
      plic.enable(plic.IRQ_BLOCK);
      plic.setThreshold(0);

      // Allocate PID 1 with a minimal AS — exec replaces it.
      const init_p = proc.alloc() orelse kprintf.panic("kmain: alloc init", .{});
      @memcpy(init_p.name[0..4], "init");
      const init_root = vm.allocRoot() orelse kprintf.panic("kmain: allocRoot init", .{});
      init_p.pgdir = init_root;
      init_p.satp = SATP_MODE_SV32 | (init_root >> 12);
      vm.mapKernelAndMmio(init_root);
      init_p.sz = 0;
      init_p.cwd = 0;  // lazy-root; first chdir or namei sets it

      // Install S-mode trap setup BEFORE exec so any block-device wait
      // during readi can take the IRQ.
      const stvec_val: u32 = @intCast(@intFromPtr(&s_trap_entry));
      const sscratch_val: u32 = @intCast(@intFromPtr(init_p));
      asm volatile ("csrw stvec, %[stv]; csrw sscratch, %[ss]"
          : : [stv] "r" (stvec_val), [ss] "r" (sscratch_val) : .{ .memory = true });
      const SIE_BITS: u32 = (1 << 1) | (1 << 9); // SSIE | SEIE
      asm volatile ("csrs sie, %[b]" : : [b] "r" (SIE_BITS) : .{ .memory = true });

      // Make cur() return PID 1 so exec writes to its trapframe.
      proc.cpu.cur = init_p;

      // Exec /bin/init from disk.
      const empty_path = "/bin/init\x00";
      const path_va = @as(u32, @intCast(@intFromPtr(&empty_path[0])));
      _ = proc.exec(path_va, 0); // argv = NULL — fs_init.zig ignores argc/argv

      // Mark Runnable and switch to scheduler.
      init_p.state = .Runnable;
      proc.cpu.cur = null;

      // sstatus.SPP=0, SPIE=1.
      const SSTATUS_SPP: u32 = 1 << 8;
      const SSTATUS_SPIE: u32 = 1 << 5;
      asm volatile ("csrc sstatus, %[spp]; csrs sstatus, %[spie]"
          : : [spp] "r" (SSTATUS_SPP), [spie] "r" (SSTATUS_SPIE) : .{ .memory = true });

      var bootstrap: proc.Context = std.mem.zeroes(proc.Context);
      proc.cpu.sched_context.ra = @intCast(@intFromPtr(&sched.scheduler));
      proc.cpu.sched_context.sp = proc.cpu.sched_stack_top;
      proc.swtch(&bootstrap, &proc.cpu.sched_context);
      unreachable;
  }
  ```
  - **Subtle:** `proc.exec` reads the path from a USER VA — but here we're passing a kernel direct-mapped VA. exec's `copyStrFromUser` uses SUM=1 which permits S-mode loads from any address (SUM=0 traps S-load-from-U; SUM=1 lifts that trap). Kernel-direct VAs bypass user/kernel checks since they're flagged `G=1, !PTE_U`, and SUM=1 doesn't matter for non-U pages. So passing the kernel VA works without modification.

- **Build wiring (`build.zig`)** — Add 4 new objects + 2 new e2e steps:
  - **`kernel-fs-init.elf`** — RV32 cross-compile of `src/kernel/user/fs_init.zig`, linked with `user_linker.ld`.
  - **`mkfs`** — host-compile of `src/kernel/mkfs.zig`.
  - **`fs.img`** — `b.addRunArtifact(mkfs)` with `--root src/kernel/userland/fs/`, `--bin <dir-containing-kernel-fs-init.elf-renamed-to-init>`, `--out <generated-path>`. Use `b.addWriteFiles()` to stage the bin dir with `kernel-fs-init.elf` → `init`.
  - **`fs_boot_config.zig` stub** — `b.addWriteFiles().add("boot_config.zig", ...)` (4th variant alongside single/multi/fork).
  - **Extend single/multi/fork stubs** with `pub const FS_DEMO: bool = false;`.
  - **`kernel-fs.elf`** — same shape as `kernel-fork.elf` (assemble boot/trampoline/mtimer/swtch/kmain), but wire `kernel_kmain_fs_obj` against `fs_boot_config_zig`.
  - **`fs_verify` host executable** — host-compile of `tests/e2e/fs.zig` (artifact name `fs_verify_e2e` for symmetry with the existing `verify_e2e` / `multiproc_verify_e2e` / `fork_verify_e2e` artifacts).
  - **`e2e-fs` step** — `b.addRunArtifact(fs_verify).addFileArg(exe.getEmittedBin()).addFileArg(fs_img).addFileArg(kernel_fs_elf.getEmittedBin()).expectExitCode(0)`.
  - **`fs-img` step** — alias for the `mkfs` run.

- **`tests/e2e/fs.zig` (NEW)** — Host-side harness, same skeleton as `tests/e2e/multiproc.zig` and `tests/e2e/fork.zig`:
  1. Spawn `ccc --disk fs.img kernel-fs.elf`, capture stdout, expect exit 0.
  2. Assert stdout *contains* `"hello from phase 3\n"`.
  3. Assert stdout ends with the canonical `"ticks observed: N\n"` trailer (PID 1 = init exits last, syscall.sysExit hits the PID-1 special case via proc.exit).

**Not in Plan 3.D (explicitly):**

- **Write path (file write, mkdirat, unlinkat, balloc on first write, bmap auto-allocate, bwrite from bufcache, dirty buffer write-back)** — Plan 3.E. 3.D's `block.write` and `bufcache.bwrite` and `balloc.alloc` and `dir.dirlink` are all landed-but-unused-by-3.D, so 3.E can call them without a new round of plumbing.
- **Console as fd 0/1/2** — Plan 3.E. 3.D's `write` syscall still routes fd 1/2 directly to UART via `uart.writeByte` (the existing 3.B/C path). The `FileType.Console` variant of `File` is declared but not constructed by any 3.D code path.
- **Console RX line discipline (^C, ^H, ^U, line-complete on \n) and `proc.kill(fg_pid)` wiring** — Plan 3.E. 3.D doesn't touch `set_fg_pid` or `console_set_mode` (still accept-and-discard from 3.C).
- **UART RX (IRQ #10)** — Plan 3.E. 3.D enables only IRQ #1 on the PLIC.
- **User stdlib (`start.S`, `usys.S`, `ulib.zig`, `uprintf.zig`)** — Plan 3.E. `fs_init.zig` uses naked `_start` with inline ecalls (3.C pattern).
- **Per-segment ELF permissions** — Plan 3.E. `elfload.load` continues to map every PT_LOAD with `USER_RWX`.
- **Real `sbrk` shrink + `USER_TEXT_VA` shift to `0x0000_1000`** — Plan 3.E.
- **fsck-style consistency check on boot, dirty-bit handling, journaling** — never (kill -9 mid-write is accepted to corrupt the disk; spec §Buffer cache).
- **Multiple file systems / mount points** — never. Single root mounted from `--disk`.
- **`open` with `O_CREAT` / `O_TRUNC` / `O_APPEND`** — Plan 3.E (creation requires balloc + bmap-on-write + dirlink). 3.D's `openat` is read-only-existing-file.
- **Path resolution for `..` past root, symlinks, `.` / `..` cycle detection** — `..` on root resolves to root (per spec §Path resolution); symlinks not in scope at all; `.` and `..` are real `DirEntry` records that mkfs writes.
- **Inode reference cycle on full inode cache** — at NINODE=32 with the spec's static workload, this should never trigger; 3.D panics via `iget` if it does (matches xv6).
- **Bufcache contention deadlock** — at NBUF=16 with ≤3 buffers per syscall, this should never trigger; `bget` panics if no evictable buffer.
- **The `getcwd` recursion-via-namei trick** — 3.D stores the path string directly on Process (chdir computes it; getcwd copies it). 3.E may revisit if a more dynamic cwd model is needed.
- **`exec` ELF size > 64 KB** — `proc.exec` returns -1 for any blob > 64 KB. (3.E can grow if any utility outgrows it.)
- **Further folder restructuring** — none. The folder restructure (commits `4607b16` + `f6fb81b`) already landed in main before this plan. 3.D writes against the post-restructure layout (`src/kernel/`, `src/emulator/`, `programs/`, `tests/e2e/`).

**Deviation from Plan 3.C's closing note:** none. 3.C delivered the process lifecycle (fork, exec, wait, exit, kill, sleep, wakeup) and the embedded-blob exec resolver. 3.D extends `proc.exec` with a FS-aware blob source, adds the kernel-side block + PLIC drivers, the bufcache, the FS layer, the file table, the `cwd` + `ofile` Process fields, 7 new syscalls, the mkfs host tool, and a new fs-mode boot path. No emulator code lands.

---

## File structure (final state at end of Plan 3.D)

> **Layout note:** the folder restructure (commits `4607b16` + `f6fb81b`) merged into `main` between Plan 3.C and Plan 3.D. The kernel now lives under `src/kernel/`, the emulator under `src/emulator/`, guest demo programs under `programs/`, and host-side e2e verifiers under `tests/e2e/`. Plan 3.D writes against the new layout throughout.

```
ccc/
├── .gitignore                                       ← MODIFIED (+ zig-out/fs.img already covered by zig-out/ pattern; verify)
├── .gitmodules                                      ← UNCHANGED
├── build.zig                                        ← MODIFIED (+kernel-fs-init.elf; +mkfs; +fs.img; +fs_boot_config; +kernel-fs.elf; +e2e-fs; extends 4 stub variants with FS_DEMO)
├── build.zig.zon                                    ← UNCHANGED
├── README.md                                        ← MODIFIED (status; Phase 3.D note; new e2e step; updated Layout block)
├── demo/                                            ← UNCHANGED (wasm host wrapper)
├── programs/                                        ← UNCHANGED (guest demos: hello, snake, mul_demo, trap_demo, plic_block_test)
├── src/
│   ├── emulator/                                    ← UNCHANGED (no emulator changes in 3.D)
│   │   ├── main.zig  lib.zig  cpu.zig  …            ← UNCHANGED
│   │   └── devices/
│   │       └── plic.zig  block.zig  uart.zig  …    ← UNCHANGED (3.A delivered)
│   └── kernel/
│       ├── boot.S                                   ← MODIFIED (+ MIDELEG_SEIP)
│       ├── linker.ld                                ← UNCHANGED
│       ├── mtimer.S                                 ← UNCHANGED
│       ├── trampoline.S                             ← UNCHANGED
│       ├── swtch.S                                  ← UNCHANGED
│       ├── kmain.zig                                ← MODIFIED (+ FS_DEMO arm before FORK_DEMO)
│       ├── kprintf.zig                              ← UNCHANGED
│       ├── page_alloc.zig                           ← UNCHANGED
│       ├── plic.zig                                 ← NEW (kernel-side PLIC driver)
│       ├── block.zig                                ← NEW (kernel-side block driver)
│       ├── proc.zig                                 ← MODIFIED (+ cwd, ofile fields; +fork dup; +exit close; +exec FS path)
│       ├── sched.zig                                ← UNCHANGED
│       ├── elfload.zig                              ← UNCHANGED (re-used by exec)
│       ├── file.zig                                 ← NEW (file table + read/lseek/fstat)
│       ├── syscall.zig                              ← MODIFIED (+17 getcwd +49 chdir +56 openat +57 close +62 lseek +63 read +80 fstat)
│       ├── trap.zig                                 ← MODIFIED (+ S-external dispatch)
│       ├── uart.zig                                 ← UNCHANGED
│       ├── vm.zig                                   ← UNCHANGED
│       ├── mkfs.zig                                 ← NEW (host tool, builds fs.img)
│       ├── fs/
│       │   ├── layout.zig                           ← NEW (constants, SuperBlock, DiskInode, DirEntry)
│       │   ├── bufcache.zig                         ← NEW
│       │   ├── balloc.zig                           ← NEW (read + alloc/free for bitmap)
│       │   ├── inode.zig                            ← NEW (icache + iget/idup/ilock/iunlock/iput/bmap/readi)
│       │   ├── dir.zig                              ← NEW (dirlookup; dirlink stub for 3.E)
│       │   └── path.zig                             ← NEW (namei, nameiparent)
│       ├── user/
│       │   ├── userprog.zig                         ← UNCHANGED
│       │   ├── userprog2.zig                        ← UNCHANGED
│       │   ├── init.zig                             ← UNCHANGED (3.C fork-mode init)
│       │   ├── hello.zig                            ← UNCHANGED (3.C exec target)
│       │   ├── fs_init.zig                          ← NEW (open + read + write + exit; installed as /bin/init in fs.img)
│       │   └── user_linker.ld                       ← UNCHANGED
│       └── userland/
│           └── fs/
│               └── etc/
│                   └── motd                         ← NEW ("hello from phase 3\n", 19 bytes)
└── tests/
    ├── e2e/
    │   ├── kernel.zig                               ← UNCHANGED (Phase 2 verifier)
    │   ├── multiproc.zig                            ← UNCHANGED (Phase 3.B verifier)
    │   ├── fork.zig                                 ← UNCHANGED (Phase 3.C verifier)
    │   ├── snake.zig                                ← UNCHANGED
    │   ├── snake_input.txt                          ← UNCHANGED
    │   └── fs.zig                                   ← NEW (e2e-fs verifier)
    ├── fixtures/                                    ← UNCHANGED
    ├── riscv-tests/                                 ← UNCHANGED
    ├── riscv-tests-p.ld                             ← UNCHANGED
    ├── riscv-tests-s.ld                             ← UNCHANGED
    └── riscv-tests-shim/                            ← UNCHANGED
```

**Files removed in this plan:** none.

**Files renamed in this plan:** none.

---

## Conventions used in this plan

- All Zig code targets Zig 0.16.x. Same API surface as Plans 2.D, 3.A, 3.B, 3.C.
- Tests live as inline `test "name" { ... }` blocks alongside the code under test. `zig build test` runs every test reachable from `src/emulator/main.zig`. Kernel-side modules (those in `src/kernel/`) are RV32 cross-compiled and **not run as host tests**; we cover them via the e2e harnesses (which exercise the same code under the emulator) and by host-runnable unit tests for any *pure-data* logic that has a host equivalent. 3.D adds host tests for `fs/layout.zig` (struct sizes), `fs/balloc.zig` (bitmap arithmetic on a synthetic block), `mkfs.zig` (image layout sanity), and `tests/e2e/fs.zig` (hostside; runs as part of `e2e-fs`).
- Each task ends with a TDD cycle: write failing test, see it fail, implement minimally, verify pass, commit. Commit messages follow Conventional Commits. The commit footer used elsewhere in the repo is preserved unchanged.
- When extending a grouped switch (syscall.zig dispatch arms, build.zig kernel object list), we show the full block so diffs are unambiguous.
- Kernel asm offsets and Zig `pub const`s that name the same byte position must always be paired with a comptime assert tying them together (Phase 2 set this convention; 3.D preserves it — but 3.D does not introduce any new asm-visible offsets, so no new asserts land beyond `@sizeOf(DiskInode) == 64` and `@sizeOf(DirEntry) == 16`).
- Whenever a test needs a real `Memory`, it uses a local `setupRig()` helper. Per Plan 2.A/B/3.A convention, we don't extract a shared rig module — each file gets its own copy.
- Task order respects strict dependencies: layout constants before any FS module; PLIC + block driver before bufcache (which sleeps on a real device IRQ); bufcache before balloc/inode (which call bread/brelse); inode before dir/path/file (which call readi); file + cwd-on-Process before the syscalls; syscalls + exec rewrite before kmain's fs-mode boot; userland binary + mkfs + build wiring before e2e.
- All references to "Plan 3.C" mean the implementation plan at `docs/superpowers/plans/2026-04-26-phase3-plan-c-fork-exec-wait-exit.md`. References to "Phase 3 spec" mean `docs/superpowers/specs/2026-04-25-phase3-multi-process-os-design.md`.

---

## Tasks

### Task 1: Add kernel-side `plic.zig` driver

**Files:**
- Create: `src/kernel/plic.zig`

**Why this task first:** every later task that touches block I/O depends on the PLIC driver being available. Lands as a self-contained module — nothing references it yet, so this commit is regression-safe.

- [ ] **Step 1: Create `src/kernel/plic.zig`**

```zig
// src/kernel/plic.zig — Phase 3.D PLIC driver.
//
// Wraps the emulator-side PLIC at 0x0c00_0000 with four operations the
// kernel needs:
//   - setPriority(src, prio): per-source priority (0..7).
//   - enable(src):           set the S-context enable bit for src.
//   - setThreshold(t):       S-context threshold; sources must be > t.
//   - claim():               returns highest pending+enabled+>thresh src
//                            (1..31) or 0; clears its pending bit.
//   - complete(src):         signals "done with src" so the device can
//                            re-assert when the next edge fires.
//
// MMIO addresses match programs/plic_block_test/boot.S, which is
// the integration-test reference for Plan 3.A.

pub const PLIC_BASE: u32 = 0x0c00_0000;
pub const PLIC_PRIORITY_BASE: u32 = 0x0c00_0000;     // src N at +4*N
pub const PLIC_ENABLE_S: u32 = 0x0c00_2080;          // S-context enable bits
pub const PLIC_THRESHOLD_S: u32 = 0x0c20_1000;       // S-context threshold
pub const PLIC_CLAIM_S: u32 = 0x0c20_1004;           // read = claim, write = complete

pub const IRQ_BLOCK: u32 = 1;
// IRQ_UART_RX = 10  (3.E)

pub fn setPriority(src: u32, prio: u32) void {
    const reg: *volatile u32 = @ptrFromInt(PLIC_PRIORITY_BASE + src * 4);
    reg.* = prio;
}

pub fn enable(src: u32) void {
    const reg: *volatile u32 = @ptrFromInt(PLIC_ENABLE_S);
    reg.* = reg.* | (@as(u32, 1) << @intCast(src));
}

pub fn setThreshold(t: u32) void {
    const reg: *volatile u32 = @ptrFromInt(PLIC_THRESHOLD_S);
    reg.* = t;
}

pub fn claim() u32 {
    const reg: *volatile u32 = @ptrFromInt(PLIC_CLAIM_S);
    return reg.*;
}

pub fn complete(src: u32) void {
    const reg: *volatile u32 = @ptrFromInt(PLIC_CLAIM_S);
    reg.* = src;
}
```

- [ ] **Step 2: Build the kernel to verify the addition compiles**

Run: `zig build kernel-elf`
Expected: PASS — `plic.zig` is a leaf module with no callers yet, so the build is unchanged but the file is now reachable from the obj graph (no — it isn't reachable yet; this just verifies the file parses. Run `zig fmt --check src/kernel/plic.zig` as a fallback.)

Run: `zig fmt --check src/kernel/plic.zig`
Expected: PASS (no output).

- [ ] **Step 3: Run e2e-kernel and e2e-multiproc-stub to confirm regression intact**

Run: `zig build e2e-kernel`
Expected: PASS.

Run: `zig build e2e-multiproc-stub`
Expected: PASS.

Run: `zig build e2e-fork`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/kernel/plic.zig
git commit -m "feat(plic): add kernel-side PLIC driver (set/enable/claim/complete)"
```

---

### Task 2: Wire `boot.S` mideleg.SEIP + `kmain` sie.SEIE

**Files:**
- Modify: `src/kernel/boot.S` (add `MIDELEG_SEIP` + extend `mideleg` write)
- Modify: `src/kernel/kmain.zig` (extend `sie` write to also set `SEIE`)

**Why this task here:** S-external delegation is a one-way switch — once delegated, M-mode never sees the IRQ. Landing it before any device IRQ wiring (Tasks 3–4) means we can't accidentally take an IRQ in M-mode and panic. The companion `sie.SEIE = 1` in kmain has to follow medeleg, and we land them together for atomic config.

- [ ] **Step 1: Extend `mideleg` in `boot.S`**

In `src/kernel/boot.S`, find:

```asm
.equ MIDELEG_SSIP, (1 << 1)
```

Change to:

```asm
.equ MIDELEG_SSIP, (1 << 1)
.equ MIDELEG_SEIP, (1 << 9)
```

Then find:

```asm
    # mideleg: SSIP.
    li      t0, MIDELEG_SSIP
    csrw    mideleg, t0
```

Replace with:

```asm
    # mideleg: SSIP (timer-forwarded) + SEIP (PLIC external). Phase 3.D
    # delegates external interrupts to S so trap.zig's s_trap_dispatch
    # handles PLIC claim/dispatch/complete without an M-mode round-trip.
    li      t0, (MIDELEG_SSIP | MIDELEG_SEIP)
    csrw    mideleg, t0
```

- [ ] **Step 2: Extend the existing `sie` write in `kmain.zig` to also set SEIE**

In `src/kernel/kmain.zig`, find every block matching:

```zig
    const SIE_SSIE: u32 = 1 << 1;
    asm volatile ("csrs sie, %[b]"
        :
        : [b] "r" (SIE_SSIE),
        : .{ .memory = true }
    );
```

(There are two: the FORK_DEMO block and the main path. The FORK_DEMO uses `SIE_SSIE_F`.)

Replace each with the matching version below.

For the main (single + multi) path:

```zig
    // sie.SSIE for forwarded timer ticks; sie.SEIE for PLIC externals (3.D).
    const SIE_BITS: u32 = (1 << 1) | (1 << 9); // SSIE | SEIE
    asm volatile ("csrs sie, %[b]"
        :
        : [b] "r" (SIE_BITS),
        : .{ .memory = true }
    );
```

For the FORK_DEMO path (replace `SIE_SSIE_F` block):

```zig
        const SIE_BITS_F: u32 = (1 << 1) | (1 << 9); // SSIE | SEIE
        asm volatile ("csrs sie, %[b]"
            :
            : [b] "r" (SIE_BITS_F),
            : .{ .memory = true }
        );
```

- [ ] **Step 3: Build the kernel**

Run: `zig build kernel-elf`
Expected: PASS.

Run: `zig build kernel-multi`
Expected: PASS.

Run: `zig build kernel-fork`
Expected: PASS.

- [ ] **Step 4: Run all four regression e2e tests**

Run: `zig build e2e-kernel`
Expected: PASS — sie.SEIE = 1 but no device asserts IRQ #1, no PLIC source enabled, so SEIP never pends.

Run: `zig build e2e-multiproc-stub`
Expected: PASS — same reason.

Run: `zig build e2e-fork`
Expected: PASS — same reason.

Run: `zig build e2e-plic-block`
Expected: PASS — Plan 3.A integration test runs in its own kernel.

- [ ] **Step 5: Commit**

```bash
git add src/kernel/boot.S src/kernel/kmain.zig
git commit -m "feat(boot): delegate SEIP to S; enable sie.SEIE in kmain"
```

---

### Task 3: Add kernel-side `block.zig` driver

**Files:**
- Create: `src/kernel/block.zig`

**Why this task here:** the bufcache (Task 6) calls `block.read`. Landing the driver before its caller keeps task diffs focused. The driver depends on `proc.sleep` / `proc.wakeup` (already in 3.C) and on the PLIC enable bit being set (Task 2 done) — but the actual wake fires from `trap.zig`'s S-external dispatch (Task 4), which we do next.

- [ ] **Step 1: Create `src/kernel/block.zig`**

```zig
// src/kernel/block.zig — Phase 3.D block-device driver.
//
// Single-outstanding-request model (per Phase 3 spec §Block I/O driver):
// - read(blk, dst_pa) writes the four MMIO regs (SECTOR/BUFFER/CMD),
//   sets req.state = .Pending, then sleeps on @intFromPtr(&req).
// - The PLIC raises IRQ #1 after the transfer; trap.zig's S-external
//   branch claims the source, dispatches into block.isr(), then
//   completes the source.
// - block.isr() reads STATUS, sets req.err and req.state = .Done, then
//   wakes everything sleeping on @intFromPtr(&req) (just the one waiter).
// - The waiter resumes inside read(), checks req.err, panics on error,
//   resets state to .Idle, returns.
//
// dst_pa / src_pa must be the kernel-direct-mapped PA of a 4-KB-aligned
// buffer in RAM. For the bufcache, that's @intFromPtr(&buf.data) — buf
// lives in .bss which is identity-mapped under mapKernelAndMmio.

const proc = @import("proc.zig");
const kprintf = @import("kprintf.zig");

pub const BLOCK_BASE: u32 = 0x1000_1000;
pub const REG_SECTOR: u32 = 0x0;
pub const REG_BUFFER: u32 = 0x4;
pub const REG_CMD: u32 = 0x8;
pub const REG_STATUS: u32 = 0xC;

pub const CMD_READ: u32 = 1;
pub const CMD_WRITE: u32 = 2;

const ReqState = enum(u32) { Idle, Pending, Done };

const Req = struct {
    state: ReqState,
    err: bool,
    waiter: u32, // process pointer (debug aid)
};

var req: Req = .{ .state = .Idle, .err = false, .waiter = 0 };

inline fn mmio(off: u32) *volatile u32 {
    return @ptrFromInt(BLOCK_BASE + off);
}

fn submit(blk: u32, buf_pa: u32, cmd: u32) void {
    if (req.state != .Idle) {
        kprintf.panic("block.submit: req not idle (state={d})", .{@intFromEnum(req.state)});
    }
    req.state = .Pending;
    req.err = false;
    req.waiter = @intFromPtr(proc.cur());

    mmio(REG_SECTOR).* = blk;
    mmio(REG_BUFFER).* = buf_pa;
    mmio(REG_CMD).* = cmd;

    // Wait for ISR to mark req.state = .Done.
    while (req.state != .Done) {
        proc.sleep(@intFromPtr(&req));
    }

    if (req.err) kprintf.panic("block I/O error (blk={d}, cmd={d})", .{ blk, cmd });

    req.state = .Idle;
    req.waiter = 0;
}

pub fn read(blk: u32, dst_pa: u32) void {
    submit(blk, dst_pa, CMD_READ);
}

pub fn write(blk: u32, src_pa: u32) void {
    submit(blk, src_pa, CMD_WRITE);
}

/// Called from trap.zig's S-external branch when claim() returns IRQ #1.
/// Reads STATUS, marks the request done, wakes the sleeper.
pub fn isr() void {
    const status = mmio(REG_STATUS).*;
    req.err = (status != 0);
    req.state = .Done;
    proc.wakeup(@intFromPtr(&req));
}
```

- [ ] **Step 2: Build the kernel**

Run: `zig build kernel-elf`
Expected: PASS — file parses but `block.isr` and `block.read` are not called yet.

Run: `zig fmt --check src/kernel/block.zig`
Expected: PASS.

- [ ] **Step 3: Run all e2e regression tests**

Run: `zig build e2e-kernel`
Expected: PASS.

Run: `zig build e2e-multiproc-stub`
Expected: PASS.

Run: `zig build e2e-fork`
Expected: PASS.

Run: `zig build e2e-plic-block`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/kernel/block.zig
git commit -m "feat(block): add kernel-side block driver (sleep/wake on req)"
```

---

### Task 4: Wire `trap.zig` S-external dispatch (claim → switch → complete)

**Files:**
- Modify: `src/kernel/trap.zig` (add `is_interrupt and cause == 9` branch)

**Why this task here:** with PLIC + block driver landed (Tasks 1, 3) and SEIP delegated (Task 2), the only missing piece for IRQ-driven I/O is the S-mode dispatcher. We land it now so block.read becomes end-to-end functional — even though no caller exercises it yet, future tasks (bufcache → readi → exec from disk) all depend on this branch firing on IRQ #1.

- [ ] **Step 1: Add the S-external branch in `trap.zig`**

In `src/kernel/trap.zig`, find:

```zig
const kprintf = @import("kprintf.zig");
const syscall = @import("syscall.zig");
const proc = @import("proc.zig");
```

Add below those:

```zig
const plic = @import("plic.zig");
const block = @import("block.zig");
```

Then find the existing `if (is_interrupt and cause == 1) { ... }` SSI branch. Insert this block AFTER it (and before the synchronous-fault panic):

```zig
    if (is_interrupt and cause == 9) {
        // Supervisor external interrupt (PLIC). Claim the source, dispatch
        // to its ISR, then complete so the device can re-assert when the
        // next edge fires.
        //
        // 3.D wires only IRQ #1 (block); 3.E will add IRQ #10 (UART RX).
        // An unknown/0 source means a spurious interrupt — the spec
        // permits 0 here when claim races a clear; we panic to surface
        // any kernel bug that wires a source we can't service.
        const irq = plic.claim();
        switch (irq) {
            plic.IRQ_BLOCK => block.isr(),
            else => kprintf.panic("unhandled PLIC src: {d}", .{irq}),
        }
        plic.complete(irq);
        return;
    }
```

- [ ] **Step 2: Build the kernel (all variants)**

Run: `zig build kernel-elf`
Expected: PASS.

Run: `zig build kernel-multi`
Expected: PASS.

Run: `zig build kernel-fork`
Expected: PASS.

- [ ] **Step 3: Run all e2e regression tests**

Run: `zig build e2e-kernel`
Expected: PASS — no PLIC source enabled, so no IRQ #1 fires; the new branch is dead code in 3.A/B/C kernels.

Run: `zig build e2e-multiproc-stub`
Expected: PASS.

Run: `zig build e2e-fork`
Expected: PASS.

Run: `zig build e2e-plic-block`
Expected: PASS — Plan 3.A's integration test runs in a stand-alone S-mode test program with its own trap vector, untouched by these changes.

- [ ] **Step 4: Commit**

```bash
git add src/kernel/trap.zig
git commit -m "feat(trap): dispatch S-external (PLIC) — claim→isr→complete"
```

---

### Task 5: Add FS layout constants (`fs/layout.zig`)

**Files:**
- Create: `src/kernel/fs/layout.zig`

**Why this task here:** every later FS module imports `layout.zig`. mkfs.zig (host) also imports it. Landing it as the first FS module sets the on-disk constants in stone before any code reads or writes them.

- [ ] **Step 1: Create `src/kernel/fs/layout.zig`**

```zig
// src/kernel/fs/layout.zig — Phase 3.D on-disk FS constants.
//
// 4 MB total = 1024 × 4 KB blocks:
//   block 0       boot sector (zeros, reserved)
//   block 1       superblock
//   block 2       block bitmap (one bit per data block)
//   blocks 3..6   inode table (4 blocks; 64 inodes × 64 B = 1 block in use)
//   blocks 7..1023  data blocks (1017 of them)
//
// Inode is 64 bytes; directory entry is 16 bytes. Both are extern struct
// — same layout on disk as in memory — so mkfs (host Zig) and the kernel
// can share this file as-is.

const std = @import("std");

pub const BLOCK_SIZE: u32 = 4096;
pub const NBLOCKS: u32 = 1024;
pub const NINODES: u32 = 64;
pub const INODES_PER_BLOCK: u32 = BLOCK_SIZE / @sizeOf(DiskInode);

pub const SUPERBLOCK_BLK: u32 = 1;
pub const BITMAP_BLK: u32 = 2;
pub const INODE_START_BLK: u32 = 3;
pub const DATA_START_BLK: u32 = 7;

pub const ROOT_INUM: u32 = 1;
pub const SUPER_MAGIC: u32 = 0xC3CC_F500;

pub const NDIRECT: u32 = 12;
pub const NINDIRECT: u32 = BLOCK_SIZE / 4;
pub const MAX_FILE_BLOCKS: u32 = NDIRECT + NINDIRECT;

pub const FileType = enum(u16) { Free = 0, File = 1, Dir = 2 };

pub const SuperBlock = extern struct {
    magic: u32,
    nblocks: u32,
    ninodes: u32,
    bitmap_blk: u32,
    inode_start: u32,
    data_start: u32,
    dirty: u32,
};

pub const DiskInode = extern struct {
    type: FileType, // u16
    nlink: u16,
    size: u32,
    addrs: [NDIRECT + 1]u32, // 12 direct + 1 indirect = 13 * 4 = 52 B
    _reserved: [4]u8, // pad to 64 B (2 + 2 + 4 + 52 + 4 = 64)
};

comptime {
    std.debug.assert(@sizeOf(DiskInode) == 64);
    std.debug.assert(@sizeOf(SuperBlock) == 28);
}

pub const DIR_NAME_LEN: u32 = 14;
pub const DirEntry = extern struct {
    inum: u16,
    name: [DIR_NAME_LEN]u8,
};

comptime {
    std.debug.assert(@sizeOf(DirEntry) == 16);
}

test "DiskInode is exactly 64 bytes" {
    if (@import("builtin").os.tag != .freestanding) {
        try std.testing.expectEqual(@as(usize, 64), @sizeOf(DiskInode));
    }
}

test "DirEntry is exactly 16 bytes" {
    if (@import("builtin").os.tag != .freestanding) {
        try std.testing.expectEqual(@as(usize, 16), @sizeOf(DirEntry));
    }
}

test "INODES_PER_BLOCK is 64" {
    if (@import("builtin").os.tag != .freestanding) {
        try std.testing.expectEqual(@as(u32, 64), INODES_PER_BLOCK);
    }
}
```

- [ ] **Step 2: Run host tests to verify the comptime asserts hold**

Run: `zig build test`
Expected: PASS — three new tests in `fs/layout.zig` pass.

- [ ] **Step 3: Build the kernel to confirm no regression**

Run: `zig build kernel-elf`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/kernel/fs/layout.zig
git commit -m "feat(fs): add layout constants — SuperBlock, DiskInode, DirEntry"
```

---

### Task 6: Add buffer cache (`fs/bufcache.zig`)

**Files:**
- Create: `src/kernel/fs/bufcache.zig`

**Why this task here:** every FS module above this (balloc, inode, dir, path) calls `bread`/`brelse`. Bufcache depends on `block.read` (Task 3) and `proc.sleep`/`proc.wakeup` (3.C). With Task 4 wiring the IRQ → block.isr → wakeup chain, the bufcache becomes the first real consumer of the IRQ-driven I/O path. Landing it here also exercises the LRU + sleep-on-busy primitives before any caller depends on them.

- [ ] **Step 1: Create `src/kernel/fs/bufcache.zig`**

```zig
// src/kernel/fs/bufcache.zig — Phase 3.D buffer cache.
//
// NBUF=16 fixed-size buffer cache. Each buffer is 4 KB + ~32 B of
// metadata. Doubly-linked LRU list with the most-recently-released
// buffer at the head. Sleep-locked on `busy`; reference-counted via
// `refs`.
//
// API:
//   init():       set up the LRU list, mark every buffer invalid.
//   bget(blk):    sleep-lock + return a buffer for blk; loads from disk
//                 lazily (caller must use bread for content).
//   bread(blk):   bget + (if invalid) block.read into buf.data + valid=true.
//   bwrite(buf):  block.write from buf.data + dirty=false. Unused by 3.D.
//   brelse(buf):  release lock, bump LRU, decrement refs, wake waiters.

const std = @import("std");
const layout = @import("layout.zig");
const proc = @import("../proc.zig");
const block = @import("../block.zig");
const kprintf = @import("../kprintf.zig");

pub const NBUF: u32 = 16;
const SENTINEL_BLOCK: u32 = 0xFFFF_FFFF;

pub const Buf = struct {
    block: u32,
    valid: bool,
    dirty: bool,
    refs: u32,
    busy: bool,
    data: [layout.BLOCK_SIZE]u8 align(4),
    next: ?*Buf,
    prev: ?*Buf,
};

pub var bcache: [NBUF]Buf = undefined;
var head: ?*Buf = null;
var tail: ?*Buf = null;

pub fn init() void {
    var i: u32 = 0;
    while (i < NBUF) : (i += 1) {
        bcache[i].block = SENTINEL_BLOCK;
        bcache[i].valid = false;
        bcache[i].dirty = false;
        bcache[i].refs = 0;
        bcache[i].busy = false;
        bcache[i].next = null;
        bcache[i].prev = null;
    }

    // Wire LRU list: head <-> bcache[0] <-> bcache[1] <-> ... <-> bcache[NBUF-1] <-> tail
    head = &bcache[0];
    tail = &bcache[NBUF - 1];
    var k: u32 = 0;
    while (k < NBUF) : (k += 1) {
        bcache[k].prev = if (k == 0) null else &bcache[k - 1];
        bcache[k].next = if (k == NBUF - 1) null else &bcache[k + 1];
    }
}

fn detach(b: *Buf) void {
    if (b.prev) |p| p.next = b.next else head = b.next;
    if (b.next) |n| n.prev = b.prev else tail = b.prev;
    b.prev = null;
    b.next = null;
}

fn attachFront(b: *Buf) void {
    b.next = head;
    b.prev = null;
    if (head) |h| h.prev = b;
    head = b;
    if (tail == null) tail = b;
}

pub fn bget(blk: u32) *Buf {
    // Pass 1: search for an existing buffer for blk.
    var cur: ?*Buf = head;
    while (cur) |b| : (cur = b.next) {
        if (b.block == blk) {
            b.refs += 1;
            while (b.busy) proc.sleep(@intFromPtr(b));
            b.busy = true;
            return b;
        }
    }

    // Pass 2: pick LRU evictee — search tail→head for refs==0 && !busy.
    cur = tail;
    while (cur) |b| : (cur = b.prev) {
        if (b.refs == 0 and !b.busy) {
            b.block = blk;
            b.valid = false;
            b.dirty = false;
            b.refs = 1;
            b.busy = true;
            return b;
        }
    }

    kprintf.panic("bcache: no evictable buffer", .{});
}

pub fn bread(blk: u32) *Buf {
    const b = bget(blk);
    if (!b.valid) {
        block.read(blk, @as(u32, @intCast(@intFromPtr(&b.data[0]))));
        b.valid = true;
    }
    return b;
}

pub fn bwrite(b: *Buf) void {
    block.write(b.block, @as(u32, @intCast(@intFromPtr(&b.data[0]))));
    b.dirty = false;
}

pub fn brelse(b: *Buf) void {
    proc.wakeup(@intFromPtr(b));
    b.busy = false;
    b.refs -= 1;

    // Move b to the head of the LRU list (most recently released).
    detach(b);
    attachFront(b);
}

test "init wires a 16-element doubly-linked list" {
    if (@import("builtin").os.tag != .freestanding) {
        init();
        // Walk head→tail counting nodes.
        var cur: ?*Buf = head;
        var n: u32 = 0;
        var prev: ?*Buf = null;
        while (cur) |b| : ({
            prev = b;
            cur = b.next;
        }) {
            try std.testing.expectEqual(prev, b.prev);
            n += 1;
        }
        try std.testing.expectEqual(@as(u32, NBUF), n);
        try std.testing.expectEqual(prev, tail);
    }
}

test "detach + attachFront moves a buffer to the head" {
    if (@import("builtin").os.tag != .freestanding) {
        init();
        const target = &bcache[5];
        detach(target);
        attachFront(target);
        try std.testing.expectEqual(@as(?*Buf, target), head);
        try std.testing.expectEqual(@as(?*Buf, null), target.prev);
    }
}
```

- [ ] **Step 2: Run host tests to verify list manipulation**

Run: `zig build test`
Expected: PASS — both new bufcache tests pass.

- [ ] **Step 3: Build the kernel**

Run: `zig build kernel-elf`
Expected: PASS — bufcache compiles; not yet referenced from kmain so no behavior change.

- [ ] **Step 4: Run all e2e regression tests**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-fork && zig build e2e-plic-block`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/kernel/fs/bufcache.zig
git commit -m "feat(fs): add bufcache — LRU buffers with sleep-on-busy"
```

---

### Task 7: Add `fs/balloc.zig` (block bitmap allocator)

**Files:**
- Create: `src/kernel/fs/balloc.zig`

**Why this task here:** the spec calls for a complete bitmap module (alloc, free, isFree). 3.D's read path doesn't allocate (mkfs sets bitmap bits at build time), but landing the full module here lets 3.E plug in `bwrite`/`bmap-on-write` without re-touching this file. Depends on bufcache (Task 6) for `bread`/`brelse`.

- [ ] **Step 1: Create `src/kernel/fs/balloc.zig`**

```zig
// src/kernel/fs/balloc.zig — Phase 3.D block bitmap allocator.
//
// One bit per block in NBLOCKS. Blocks 0..6 (boot/super/bitmap/inodes)
// are reserved-set by mkfs. blocks 7..1023 are the data region.
//
// 3.D read path doesn't call alloc/free — the bitmap is consulted only
// indirectly via mkfs-set bits, and bmap reads inode.dinode.addrs.
// We land the full API here so 3.E (write path) can call it without
// revisiting this file.

const std = @import("std");
const layout = @import("layout.zig");
const bufcache = @import("bufcache.zig");
const kprintf = @import("../kprintf.zig");

inline fn bitOf(b: *bufcache.Buf, blk: u32) u8 {
    return (b.data[blk / 8] >> @intCast(blk % 8)) & 1;
}

inline fn setBit(b: *bufcache.Buf, blk: u32) void {
    b.data[blk / 8] |= (@as(u8, 1) << @intCast(blk % 8));
}

inline fn clearBit(b: *bufcache.Buf, blk: u32) void {
    b.data[blk / 8] &= ~(@as(u8, 1) << @intCast(blk % 8));
}

/// Returns true if blk is currently free (bit cleared).
pub fn isFree(blk: u32) bool {
    if (blk >= layout.NBLOCKS) return false;
    const b = bufcache.bread(layout.BITMAP_BLK);
    defer bufcache.brelse(b);
    return bitOf(b, blk) == 0;
}

/// Allocate the first free block ≥ DATA_START_BLK; mark it allocated;
/// write the bitmap back. Returns 0 (invalid block) on full disk.
pub fn alloc() u32 {
    const b = bufcache.bread(layout.BITMAP_BLK);
    defer bufcache.brelse(b);
    var blk: u32 = layout.DATA_START_BLK;
    while (blk < layout.NBLOCKS) : (blk += 1) {
        if (bitOf(b, blk) == 0) {
            setBit(b, blk);
            bufcache.bwrite(b);
            return blk;
        }
    }
    return 0;
}

/// Free a previously-allocated data block. Panics if blk is reserved.
pub fn free(blk: u32) void {
    if (blk < layout.DATA_START_BLK or blk >= layout.NBLOCKS) {
        kprintf.panic("balloc.free: invalid blk {d}", .{blk});
    }
    const b = bufcache.bread(layout.BITMAP_BLK);
    defer bufcache.brelse(b);
    clearBit(b, blk);
    bufcache.bwrite(b);
}

test "bitOf / setBit / clearBit on a synthetic buffer" {
    if (@import("builtin").os.tag != .freestanding) {
        var b: bufcache.Buf = undefined;
        b.data = std.mem.zeroes([layout.BLOCK_SIZE]u8);
        try std.testing.expectEqual(@as(u8, 0), bitOf(&b, 100));
        setBit(&b, 100);
        try std.testing.expectEqual(@as(u8, 1), bitOf(&b, 100));
        try std.testing.expectEqual(@as(u8, 0), bitOf(&b, 99));
        try std.testing.expectEqual(@as(u8, 0), bitOf(&b, 101));
        clearBit(&b, 100);
        try std.testing.expectEqual(@as(u8, 0), bitOf(&b, 100));
    }
}
```

- [ ] **Step 2: Run host tests**

Run: `zig build test`
Expected: PASS — bit-manipulation test passes.

- [ ] **Step 3: Build the kernel**

Run: `zig build kernel-elf`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/kernel/fs/balloc.zig
git commit -m "feat(fs): add block bitmap allocator (alloc/free/isFree)"
```

---

### Task 8: Add `fs/inode.zig` (in-memory inode cache + readi + bmap)

**Files:**
- Create: `src/kernel/fs/inode.zig`

**Why this task here:** every file operation goes through `readi` → `bmap` → `bread` → `brelse`. With bufcache (Task 6) and balloc (Task 7) in place, inode is the next layer up. Path resolution (Task 10) and the file table (Task 11) both depend on `iget`/`ilock`/`iunlock`/`iput` and `readi`. We land bmap and readi together because they're inseparable in any caller (you bmap to know which block to bread, then memcpy out of buf.data).

- [ ] **Step 1: Create `src/kernel/fs/inode.zig`**

```zig
// src/kernel/fs/inode.zig — Phase 3.D in-memory inode cache.
//
// NINODE=32 in-memory inode entries. Each entry caches a DiskInode plus
// metadata: refs (held by namei walkers + open files), valid (whether
// dinode has been read from disk), busy (sleep-locked).
//
// API:
//   init():                  zero the icache.
//   iget(inum):              return existing entry or claim a free slot;
//                            increments refs; valid=false until ilock'd.
//   idup(ip):                bump refs; return ip.
//   ilock(ip):               sleep until !busy, then busy=true; if !valid,
//                            bread the inode block, copy the slot into
//                            ip.dinode, brelse, valid=true.
//   iunlock(ip):             busy=false; wakeup waiters.
//   iput(ip):                refs -= 1. (3.E adds the on-zero on-disk
//                            truncate when nlink == 0.)
//   bmap(ip, bn):            translate logical block bn to disk block#.
//                            Returns 0 for unallocated entries (read-as-EOF).
//   readi(ip, dst, off, n):  copy n bytes into dst. Returns bytes copied
//                            (clamped to ip.dinode.size).

const std = @import("std");
const layout = @import("layout.zig");
const bufcache = @import("bufcache.zig");
const proc = @import("../proc.zig");
const kprintf = @import("../kprintf.zig");

pub const NINODE: u32 = 32;

pub const InMemInode = struct {
    inum: u32,
    refs: u32,
    valid: bool,
    busy: bool,
    dinode: layout.DiskInode,
};

pub var icache: [NINODE]InMemInode = undefined;

pub fn init() void {
    var i: u32 = 0;
    while (i < NINODE) : (i += 1) {
        icache[i].inum = 0;
        icache[i].refs = 0;
        icache[i].valid = false;
        icache[i].busy = false;
        icache[i].dinode = std.mem.zeroes(layout.DiskInode);
    }
}

pub fn iget(inum: u32) *InMemInode {
    var empty: ?*InMemInode = null;
    var i: u32 = 0;
    while (i < NINODE) : (i += 1) {
        const ip = &icache[i];
        if (ip.refs > 0 and ip.inum == inum) {
            ip.refs += 1;
            return ip;
        }
        if (empty == null and ip.refs == 0) empty = ip;
    }
    const slot = empty orelse kprintf.panic("iget: icache full", .{});
    slot.inum = inum;
    slot.refs = 1;
    slot.valid = false;
    return slot;
}

pub fn idup(ip: *InMemInode) *InMemInode {
    ip.refs += 1;
    return ip;
}

pub fn ilock(ip: *InMemInode) void {
    while (ip.busy) proc.sleep(@intFromPtr(ip));
    ip.busy = true;

    if (!ip.valid) {
        // Inode (inum) lives in inode block (inum / INODES_PER_BLOCK + INODE_START_BLK).
        const blk = layout.INODE_START_BLK + ip.inum / layout.INODES_PER_BLOCK;
        const slot = ip.inum % layout.INODES_PER_BLOCK;
        const b = bufcache.bread(blk);
        defer bufcache.brelse(b);

        const inodes_ptr: [*]const layout.DiskInode = @ptrCast(@alignCast(&b.data[0]));
        ip.dinode = inodes_ptr[slot];
        ip.valid = true;
    }
}

pub fn iunlock(ip: *InMemInode) void {
    proc.wakeup(@intFromPtr(ip));
    ip.busy = false;
}

pub fn iput(ip: *InMemInode) void {
    if (ip.refs == 0) kprintf.panic("iput: refs == 0 (inum {d})", .{ip.inum});
    ip.refs -= 1;
    // 3.E: if refs == 0 and dinode.nlink == 0, ilock + truncate + zero
    // the dinode + bwrite the inode block. 3.D never reaches this branch.
}

/// Map logical block index `bn` (0-based) within the file to its on-disk
/// block number. Returns 0 for blocks past the file's allocated extent
/// (caller's readi treats 0 as a hole / EOF).
///
/// Caller MUST hold ip locked (busy=true, valid=true).
pub fn bmap(ip: *InMemInode, bn: u32) u32 {
    if (bn < layout.NDIRECT) {
        return ip.dinode.addrs[bn];
    }
    if (bn < layout.NDIRECT + layout.NINDIRECT) {
        const ind_blk = ip.dinode.addrs[layout.NDIRECT];
        if (ind_blk == 0) return 0;
        const b = bufcache.bread(ind_blk);
        defer bufcache.brelse(b);
        const ptrs: [*]const u32 = @ptrCast(@alignCast(&b.data[0]));
        return ptrs[bn - layout.NDIRECT];
    }
    kprintf.panic("bmap: bn {d} > MAX_FILE_BLOCKS", .{bn});
}

/// Copy up to n bytes from inode at offset off into dst. Reads past
/// ip.dinode.size return 0. Reads of unallocated blocks return zeros.
///
/// Caller MUST hold ip locked.
pub fn readi(ip: *InMemInode, dst: [*]u8, off: u32, n: u32) u32 {
    if (off >= ip.dinode.size) return 0;
    const real_n = if (off + n > ip.dinode.size) ip.dinode.size - off else n;

    var copied: u32 = 0;
    while (copied < real_n) {
        const cur_off = off + copied;
        const bn = cur_off / layout.BLOCK_SIZE;
        const blk_off = cur_off % layout.BLOCK_SIZE;
        const remain = real_n - copied;
        const chunk = if (blk_off + remain > layout.BLOCK_SIZE)
            layout.BLOCK_SIZE - blk_off
        else
            remain;

        const dblk = bmap(ip, bn);
        if (dblk == 0) {
            // Hole — readi returns zeros without touching disk.
            var i: u32 = 0;
            while (i < chunk) : (i += 1) dst[copied + i] = 0;
        } else {
            const b = bufcache.bread(dblk);
            defer bufcache.brelse(b);
            var i: u32 = 0;
            while (i < chunk) : (i += 1) dst[copied + i] = b.data[blk_off + i];
        }
        copied += chunk;
    }
    return copied;
}
```

- [ ] **Step 2: Build the kernel**

Run: `zig build kernel-elf`
Expected: PASS — inode compiles; not yet referenced from kmain.

- [ ] **Step 3: Run all e2e regression tests**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-fork && zig build e2e-plic-block`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add src/kernel/fs/inode.zig
git commit -m "feat(fs): add inode cache + bmap + readi (read path only)"
```

---

### Task 9: Add `fs/dir.zig` (dirlookup + dirlink stub)

**Files:**
- Create: `src/kernel/fs/dir.zig`

**Why this task here:** path resolution (Task 10) calls `dirlookup`. We land `dirlink` as a stub returning false so 3.E can drop in the real body without changing any caller. dir.zig depends on inode (Task 8) for `readi`.

- [ ] **Step 1: Create `src/kernel/fs/dir.zig`**

```zig
// src/kernel/fs/dir.zig — Phase 3.D directory operations.
//
// Directories store an array of 16-byte DirEntry records back-to-back
// inside their inode's data blocks. inum == 0 means a free slot.
//
// API:
//   dirlookup(dir, name): linear-scan dir's data via readi; return
//                         the matching entry's inum or null.
//   dirlink(dir, name, inum): NOT implemented in 3.D (write path is
//                             3.E). Returns false unconditionally so
//                             3.D's syscalls compile against a stable
//                             API surface.

const std = @import("std");
const layout = @import("layout.zig");
const inode = @import("inode.zig");

pub fn dirlookup(dir: *inode.InMemInode, name: []const u8) ?u32 {
    if (dir.dinode.type != .Dir) return null;
    if (name.len == 0 or name.len > layout.DIR_NAME_LEN - 1) return null;

    var off: u32 = 0;
    var de: layout.DirEntry = undefined;
    while (off < dir.dinode.size) : (off += @sizeOf(layout.DirEntry)) {
        const got = inode.readi(dir, @ptrCast(&de), off, @sizeOf(layout.DirEntry));
        if (got != @sizeOf(layout.DirEntry)) return null;
        if (de.inum == 0) continue;

        // Compare name (NUL-terminated within the 14-byte field).
        var i: u32 = 0;
        var match = true;
        while (i < name.len) : (i += 1) {
            if (de.name[i] != name[i]) {
                match = false;
                break;
            }
        }
        // The byte after the name (if any) must be NUL or the end.
        if (match and (name.len == layout.DIR_NAME_LEN or de.name[name.len] == 0)) {
            return de.inum;
        }
    }
    return null;
}

/// 3.D stub. 3.E implements the real write-path body that finds an
/// inum==0 slot (or appends), constructs a DirEntry, and writes it
/// via writei.
pub fn dirlink(dir: *inode.InMemInode, name: []const u8, inum: u16) bool {
    _ = dir;
    _ = name;
    _ = inum;
    return false;
}
```

- [ ] **Step 2: Build the kernel**

Run: `zig build kernel-elf`
Expected: PASS.

- [ ] **Step 3: Run all e2e regression tests**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-fork && zig build e2e-plic-block`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add src/kernel/fs/dir.zig
git commit -m "feat(fs): add dirlookup; dirlink stub for 3.E"
```

---

### Task 10: Add `fs/path.zig` (namei + nameiparent)

**Files:**
- Create: `src/kernel/fs/path.zig`

**Why this task here:** `proc.exec` (Task 15) and the syscall arms (Tasks 16–19) all walk paths. namei depends on inode + dir; nameiparent shares the same walker so we land them in one task. The `cur.cwd` field (Task 12) hasn't been added yet, so namei lazily falls back to root inum 1 when `cur.cwd == 0` — which is the boot state.

- [ ] **Step 1: Create `src/kernel/fs/path.zig`**

```zig
// src/kernel/fs/path.zig — Phase 3.D path resolution.
//
// Iterative left-to-right walker. Absolute paths start at root inum 1;
// relative paths start at cur.cwd (or root if cur.cwd is 0 / lazy).
//
// API:
//   namei(path):                  return final inode, or null on missing.
//   nameiparent(path, name_out):  return parent inode + write leaf name
//                                 into name_out. Used by 3.E mkdirat /
//                                 unlinkat / openat-O_CREAT.
//
// Bounds: path ≤ MAX_PATH (256 bytes); component ≤ DIR_NAME_LEN-1 (13).
// Both bounds enforced with null returns.

const std = @import("std");
const layout = @import("layout.zig");
const inode = @import("inode.zig");
const dir = @import("dir.zig");
const proc = @import("../proc.zig");

pub const MAX_PATH: u32 = 256;

const PathError = error{
    Empty,
    TooLong,
    BadComponent,
};

/// Skip slashes; return the start of the next component or null at end.
fn skipSlashes(p: []const u8, off: u32) ?u32 {
    var i = off;
    while (i < p.len and p[i] == '/') i += 1;
    if (i >= p.len) return null;
    return i;
}

/// Find the end of the component starting at off (up to next '/' or end).
/// Returns (start_of_next, component_slice).
fn nextComponent(p: []const u8, off: u32) ?struct { next: u32, comp: []const u8 } {
    const start = skipSlashes(p, off) orelse return null;
    var end = start;
    while (end < p.len and p[end] != '/') end += 1;
    if (end - start > layout.DIR_NAME_LEN - 1) return null;
    return .{ .next = end, .comp = p[start..end] };
}

/// Returns the starting inode for path resolution: root for absolute,
/// cwd for relative. Caller owns one ref on the returned inode.
fn startInode(path: []const u8) *inode.InMemInode {
    if (path.len > 0 and path[0] == '/') {
        return inode.iget(layout.ROOT_INUM);
    }
    const me = proc.cur();
    if (me.cwd != 0) {
        const ip: *inode.InMemInode = @ptrFromInt(me.cwd);
        return inode.idup(ip);
    }
    return inode.iget(layout.ROOT_INUM);
}

/// Walk path. If name_parent_out is non-null, stop one component short
/// and write the leaf component into it (NUL-padded). Returns the final
/// inode (refs incremented) or null on failure.
fn nameix(path: []const u8, name_parent_out: ?*[layout.DIR_NAME_LEN]u8) ?*inode.InMemInode {
    if (path.len == 0 or path.len > MAX_PATH) return null;

    // Special case: absolute root "/" alone.
    if (name_parent_out == null and path.len == 1 and path[0] == '/') {
        return inode.iget(layout.ROOT_INUM);
    }

    var cur = startInode(path);
    var off: u32 = 0;

    while (true) {
        const step = nextComponent(path, off) orelse {
            // No more components — cur is the answer.
            return cur;
        };
        const comp = step.comp;
        const next = step.next;

        // Look ahead: is comp the LAST component?
        const is_last = (skipSlashes(path, next) == null);

        if (is_last and name_parent_out != null) {
            // Caller wants the parent. Copy the leaf name and return cur.
            var i: u32 = 0;
            while (i < layout.DIR_NAME_LEN) : (i += 1) {
                name_parent_out.?[i] = if (i < comp.len) comp[i] else 0;
            }
            return cur;
        }

        // Walk into comp.
        inode.ilock(cur);
        if (cur.dinode.type != .Dir) {
            inode.iunlock(cur);
            inode.iput(cur);
            return null;
        }
        const child_inum = dir.dirlookup(cur, comp) orelse {
            inode.iunlock(cur);
            inode.iput(cur);
            return null;
        };
        inode.iunlock(cur);
        const next_ip = inode.iget(child_inum);
        inode.iput(cur);
        cur = next_ip;
        off = next;
    }
}

pub fn namei(path: []const u8) ?*inode.InMemInode {
    return nameix(path, null);
}

pub fn nameiparent(path: []const u8, name_out: *[layout.DIR_NAME_LEN]u8) ?*inode.InMemInode {
    return nameix(path, name_out);
}
```

- [ ] **Step 2: Build the kernel**

Run: `zig build kernel-elf`
Expected: PASS — path compiles. Note: `proc.cur().cwd` is not yet a field on Process; that's added in Task 12. **Build will fail at this step until Task 12 lands.** To preserve the per-task green-build invariant, defer Task 10 until after Task 12, OR add a temporary bypass. We choose the latter: temporarily replace `me.cwd` with `0` (forcing always-root) until Task 12 adds the field. Edit `startInode`:

```zig
fn startInode(path: []const u8) *inode.InMemInode {
    if (path.len > 0 and path[0] == '/') {
        return inode.iget(layout.ROOT_INUM);
    }
    // TODO(Task 12): use proc.cur().cwd once the field exists.
    return inode.iget(layout.ROOT_INUM);
}
```

Re-run: `zig build kernel-elf`
Expected: PASS.

- [ ] **Step 3: Run all e2e regression tests**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-fork && zig build e2e-plic-block`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add src/kernel/fs/path.zig
git commit -m "feat(fs): add namei / nameiparent (cwd lookup is TODO Task 12)"
```

---

### Task 11: Add `file.zig` (file table + read/lseek/fstat)

**Files:**
- Create: `src/kernel/file.zig`

**Why this task here:** the `cur.ofile[]` extension on Process (Task 12) and every syscall arm (Tasks 16–19) call into this module. We land it before the Process-struct change so the field type (file-table index) is well-defined when we add it. Depends on inode (Task 8).

- [ ] **Step 1: Create `src/kernel/file.zig`**

```zig
// src/kernel/file.zig — Phase 3.D file table.
//
// NFILE=64 ref-counted "open file" records. Slot 0 is reserved as the
// "null" sentinel — proc.ofile[fd] == 0 means "fd is closed".
//
// 3.D supports type=.Inode only; 3.E adds type=.Console for fd 0/1/2
// when the line discipline lands.
//
// API:
//   init():       zero the table.
//   alloc():      claim the lowest free slot (refs becomes 1); ?u32 idx.
//   dup(idx):     refs += 1; return idx.
//   close(idx):   refs -= 1; on zero, iput(ip) + zero the slot.
//   read(...):    ilock + readi + iunlock + SUM-1 copy to user; bumps off.
//   lseek(...):   update off; whence 0=SET, 1=CUR, 2=END.
//   fstat(...):   write Stat { type, size } to user (8 bytes, SUM=1).

const std = @import("std");
const inode = @import("fs/inode.zig");
const proc = @import("proc.zig");
const layout = @import("fs/layout.zig");

pub const NFILE: u32 = 64;
const READ_CHUNK: u32 = 4096;

pub const FileType = enum(u32) { None = 0, Inode = 1, Console = 2 };

pub const File = struct {
    type: FileType,
    ref_count: u32,
    ip: ?*inode.InMemInode,
    off: u32,
};

pub var ftable: [NFILE]File = undefined;

pub const Stat = extern struct {
    type: u32, // FileType cast to u32
    size: u32,
};

const SSTATUS_SUM: u32 = 1 << 18;

inline fn setSum() void {
    asm volatile ("csrs sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SUM),
        : .{ .memory = true }
    );
}

inline fn clearSum() void {
    asm volatile ("csrc sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SUM),
        : .{ .memory = true }
    );
}

pub fn init() void {
    var i: u32 = 0;
    while (i < NFILE) : (i += 1) {
        ftable[i].type = .None;
        ftable[i].ref_count = 0;
        ftable[i].ip = null;
        ftable[i].off = 0;
    }
}

/// Returns the index of the newly allocated slot (≥ 1), or null if full.
pub fn alloc() ?u32 {
    var i: u32 = 1; // slot 0 reserved as "null"
    while (i < NFILE) : (i += 1) {
        if (ftable[i].ref_count == 0) {
            ftable[i].ref_count = 1;
            return i;
        }
    }
    return null;
}

pub fn dup(idx: u32) u32 {
    ftable[idx].ref_count += 1;
    return idx;
}

pub fn close(idx: u32) void {
    if (idx == 0 or idx >= NFILE) return;
    const f = &ftable[idx];
    if (f.ref_count == 0) return;
    f.ref_count -= 1;
    if (f.ref_count == 0) {
        if (f.type == .Inode and f.ip != null) {
            inode.iput(f.ip.?);
        }
        f.* = .{ .type = .None, .ref_count = 0, .ip = null, .off = 0 };
    }
}

/// Read up to n bytes from f into the user buffer at dst_user_va.
/// Returns bytes copied (0 on EOF, -1 on error).
pub fn read(idx: u32, dst_user_va: u32, n: u32) i32 {
    if (idx == 0 or idx >= NFILE) return -1;
    const f = &ftable[idx];
    if (f.type != .Inode or f.ip == null) return -1;

    var kbuf: [READ_CHUNK]u8 = undefined;
    const want = if (n > READ_CHUNK) READ_CHUNK else n;

    inode.ilock(f.ip.?);
    const got = inode.readi(f.ip.?, &kbuf, f.off, want);
    inode.iunlock(f.ip.?);

    if (got > 0) {
        setSum();
        var i: u32 = 0;
        while (i < got) : (i += 1) {
            const dst: *volatile u8 = @ptrFromInt(dst_user_va + i);
            dst.* = kbuf[i];
        }
        clearSum();
        f.off += got;
    }
    return @intCast(got);
}

pub fn lseek(idx: u32, off: i32, whence: u32) i32 {
    if (idx == 0 or idx >= NFILE) return -1;
    const f = &ftable[idx];
    if (f.type != .Inode or f.ip == null) return -1;

    const new_off: i64 = switch (whence) {
        0 => off, // SEEK_SET
        1 => @as(i64, @intCast(f.off)) + off,
        2 => blk: {
            inode.ilock(f.ip.?);
            const sz = f.ip.?.dinode.size;
            inode.iunlock(f.ip.?);
            break :blk @as(i64, @intCast(sz)) + off;
        },
        else => return -1,
    };
    if (new_off < 0) return -1;
    if (new_off > 0xFFFF_FFFF) return -1;
    f.off = @intCast(new_off);
    return @intCast(f.off);
}

pub fn fstat(idx: u32, stat_user_va: u32) i32 {
    if (idx == 0 or idx >= NFILE) return -1;
    const f = &ftable[idx];
    if (f.type != .Inode or f.ip == null) return -1;

    inode.ilock(f.ip.?);
    const stat: Stat = .{
        .type = @intFromEnum(f.ip.?.dinode.type),
        .size = f.ip.?.dinode.size,
    };
    inode.iunlock(f.ip.?);

    setSum();
    const dst: *volatile Stat = @ptrFromInt(stat_user_va);
    dst.* = stat;
    clearSum();
    return 0;
}
```

- [ ] **Step 2: Build the kernel**

Run: `zig build kernel-elf`
Expected: PASS.

- [ ] **Step 3: Run all e2e regression tests**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-fork && zig build e2e-plic-block`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add src/kernel/file.zig
git commit -m "feat(file): add file table — alloc/dup/close/read/lseek/fstat"
```

---

### Task 12: Extend `Process` struct with `cwd`, `ofile`, `cwd_path` fields

**Files:**
- Modify: `src/kernel/proc.zig` (extend `Process` struct, update `cur().cwd` reference in `path.zig`)
- Modify: `src/kernel/fs/path.zig` (un-stub `startInode` to use `cur.cwd`)

**Why this task here:** these fields are referenced by `proc.fork` (Task 13), `proc.exit` (Task 14), all four open-file syscalls (Tasks 16–19), `chdir` / `getcwd` (Task 19), and `path.startInode`'s lazy-root fallback (Task 10's TODO). We add them now in a single cohesive change so dependent tasks reference real fields, not synthetic placeholders.

**ABI safety:** the new fields go AFTER `parent: ?*Process` (the current last field). `trampoline.S` references `tf` (offset 0) and `kstack_top` (offset 144); both are unchanged. `Cpu.cur` and `cpu.sched_context` references in `swtch.S` see fixed `Context` offsets, also unchanged.

- [ ] **Step 1: Add `cwd`, `ofile`, `cwd_path` fields to the Process struct in `proc.zig`**

In `src/kernel/proc.zig`, find the existing `Process` struct:

```zig
pub const Process = extern struct {
    tf: trap.TrapFrame,    // offset 0 — trampoline.S depends on this
    satp: u32,             // offset 128
    pgdir: u32,            // offset 132
    sz: u32,               // offset 136
    kstack: u32,           // offset 140
    kstack_top: u32,       // offset 144 — referenced by trampoline.S
    state: State,
    pid: u32,
    chan: u32,
    killed: u32,
    xstate: i32,
    ticks_observed: u32,
    context: Context,
    name: [16]u8,
    parent: ?*Process,
};
```

Replace with:

```zig
pub const NOFILE: u32 = 16;
pub const CWD_PATH_MAX: u32 = 64;

pub const Process = extern struct {
    tf: trap.TrapFrame,    // offset 0 — trampoline.S depends on this
    satp: u32,             // offset 128
    pgdir: u32,            // offset 132
    sz: u32,               // offset 136
    kstack: u32,           // offset 140
    kstack_top: u32,       // offset 144 — referenced by trampoline.S
    state: State,
    pid: u32,
    chan: u32,
    killed: u32,
    xstate: i32,
    ticks_observed: u32,
    context: Context,
    name: [16]u8,
    parent: ?*Process,
    // Phase 3.D additions — placed after `parent` so existing offsets
    // pinned by trampoline.S / swtch.S / comptime asserts stay intact.
    cwd: u32,                     // *fs.inode.InMemInode cast to u32; 0 = lazy-root
    cwd_path: [CWD_PATH_MAX]u8,   // NUL-terminated; "" = "/"
    ofile: [NOFILE]u32,           // file table indices; 0 = empty
};
```

- [ ] **Step 2: Verify the existing comptime asserts still hold**

The existing block:

```zig
comptime {
    std.debug.assert(@offsetOf(Process, "tf") == 0);
    std.debug.assert(@offsetOf(Process, "satp") == trap.TF_SIZE);
    std.debug.assert(@offsetOf(Process, "kstack_top") == KSTACK_TOP_OFFSET);
    std.debug.assert(@offsetOf(Process, "pgdir") == 132);
    std.debug.assert(@offsetOf(Process, "sz") == 136);
    std.debug.assert(@offsetOf(Process, "kstack") == 140);
}
```

is untouched — all referenced fields are at the same offsets. The new fields appended at the tail don't shift anything.

- [ ] **Step 3: Un-stub `startInode` in `fs/path.zig`**

In `src/kernel/fs/path.zig`, find:

```zig
fn startInode(path: []const u8) *inode.InMemInode {
    if (path.len > 0 and path[0] == '/') {
        return inode.iget(layout.ROOT_INUM);
    }
    // TODO(Task 12): use proc.cur().cwd once the field exists.
    return inode.iget(layout.ROOT_INUM);
}
```

Replace with:

```zig
fn startInode(path: []const u8) *inode.InMemInode {
    if (path.len > 0 and path[0] == '/') {
        return inode.iget(layout.ROOT_INUM);
    }
    const me = proc.cur();
    if (me.cwd != 0) {
        const ip: *inode.InMemInode = @ptrFromInt(me.cwd);
        return inode.idup(ip);
    }
    return inode.iget(layout.ROOT_INUM);
}
```

- [ ] **Step 4: Build the kernel**

Run: `zig build kernel-elf`
Expected: PASS.

Run: `zig build kernel-multi`
Expected: PASS.

Run: `zig build kernel-fork`
Expected: PASS.

- [ ] **Step 5: Run all e2e regression tests**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-fork && zig build e2e-plic-block`
Expected: all PASS — `proc.alloc`'s zero-the-slot path covers the new fields with `cwd = 0`, `cwd_path = "" `, `ofile = .{0} ** NOFILE`. Single-mode and fork-mode kernels never construct an open file or chdir, so the new fields are dormant.

- [ ] **Step 6: Commit**

```bash
git add src/kernel/proc.zig src/kernel/fs/path.zig
git commit -m "feat(proc): add cwd, cwd_path, ofile fields; finish startInode"
```

---

### Task 13: Extend `proc.fork` to dup `ofile` + `idup` `cwd`

**Files:**
- Modify: `src/kernel/proc.zig` (append fork extension before `child.state = .Runnable`)

**Why this task here:** with the new Process fields in place (Task 12) and the `file.dup` / `inode.idup` APIs available (Tasks 8, 11), fork's child needs to inherit the parent's open files and cwd. We land it now so 3.E's shell-style fork+exec'd children automatically get fd inheritance. 3.D's `init` doesn't fork, but the change is regression-safe.

- [ ] **Step 1: Add file/inode imports + extend `proc.fork` body**

In `src/kernel/proc.zig`, find the existing imports near the top:

```zig
const std = @import("std");
const trap = @import("trap.zig");
const page_alloc = @import("page_alloc.zig");
const kprintf = @import("kprintf.zig");
const vm = @import("vm.zig");
```

Add below them:

```zig
const file = @import("file.zig");
const inode = @import("fs/inode.zig");
const path = @import("fs/path.zig");
const bufcache = @import("fs/bufcache.zig");
```

(`path` and `bufcache` aren't needed by fork specifically but land alongside the other FS imports for use by exec in Task 15.)

Then in `proc.fork`, find the existing block:

```zig
    child.pgdir = new_root;
    child.satp = SATP_MODE_SV32 | (new_root >> 12);
    child.sz = parent.sz;
    child.tf = parent.tf;
    child.tf.a0 = 0;
    child.parent = parent;
    @memcpy(&child.name, &parent.name);
    child.state = .Runnable;

    return @as(i32, @intCast(child.pid));
```

Replace with:

```zig
    child.pgdir = new_root;
    child.satp = SATP_MODE_SV32 | (new_root >> 12);
    child.sz = parent.sz;
    child.tf = parent.tf;
    child.tf.a0 = 0;
    child.parent = parent;
    @memcpy(&child.name, &parent.name);

    // Inherit parent's open fds.
    var fi: u32 = 0;
    while (fi < NOFILE) : (fi += 1) {
        if (parent.ofile[fi] != 0) {
            child.ofile[fi] = file.dup(parent.ofile[fi]);
        }
    }

    // Inherit parent's cwd. If parent never chdir'd (cwd == 0), child
    // inherits the same lazy-root and copies the empty cwd_path.
    if (parent.cwd != 0) {
        const ip: *inode.InMemInode = @ptrFromInt(parent.cwd);
        child.cwd = @intFromPtr(inode.idup(ip));
    } else {
        child.cwd = 0;
    }
    @memcpy(&child.cwd_path, &parent.cwd_path);

    child.state = .Runnable;

    return @as(i32, @intCast(child.pid));
```

- [ ] **Step 2: Build the kernel (all variants)**

Run: `zig build kernel-elf`
Expected: PASS.

Run: `zig build kernel-multi`
Expected: PASS.

Run: `zig build kernel-fork`
Expected: PASS.

- [ ] **Step 3: Run all e2e regression tests**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-fork && zig build e2e-plic-block`
Expected: all PASS — Plan 3.C's `e2e-fork` kernel-fork.elf forks but neither parent nor child has open fds or a non-zero cwd, so the new loop is a no-op.

- [ ] **Step 4: Commit**

```bash
git add src/kernel/proc.zig
git commit -m "feat(proc): fork dup's parent's ofile + cwd into child"
```

---

### Task 14: Extend `proc.exit` to close `ofile` + `iput` `cwd`

**Files:**
- Modify: `src/kernel/proc.zig` (insert close-loop and iput at the start of `exit`)

**Why this task here:** the symmetric counterpart to Task 13. Without it, Plan 3.E's reaped processes leak file table entries and inode refcounts. We land it now so 3.E doesn't have to revisit `proc.zig`.

- [ ] **Step 1: Insert ofile-close + cwd-iput in `proc.exit`**

In `src/kernel/proc.zig`, find the existing `proc.exit` body opening:

```zig
pub fn exit(status: i32) noreturn {
    const p = cur();

    // Reparent every child of `p` to PID 1 (init). PID 1 is hard-wired
    // to slot 0; if 3.D ever changes that, this lookup needs to scan
    // ptable for pid==1.
```

Insert between `const p = cur();` and the reparent comment:

```zig
pub fn exit(status: i32) noreturn {
    const p = cur();

    // Phase 3.D: close every open fd and release cwd.
    var fi: u32 = 0;
    while (fi < NOFILE) : (fi += 1) {
        if (p.ofile[fi] != 0) {
            file.close(p.ofile[fi]);
            p.ofile[fi] = 0;
        }
    }
    if (p.cwd != 0) {
        const ip: *inode.InMemInode = @ptrFromInt(p.cwd);
        inode.iput(ip);
        p.cwd = 0;
    }

    // Reparent every child of `p` to PID 1 (init). PID 1 is hard-wired
    // to slot 0; if 3.D ever changes that, this lookup needs to scan
    // ptable for pid==1.
```

(The rest of `proc.exit` is unchanged.)

- [ ] **Step 2: Build the kernel (all variants)**

Run: `zig build kernel-elf`
Expected: PASS.

Run: `zig build kernel-multi`
Expected: PASS.

Run: `zig build kernel-fork`
Expected: PASS.

- [ ] **Step 3: Run all e2e regression tests**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-fork && zig build e2e-plic-block`
Expected: all PASS — no proc has open fds or held cwd in pre-3.D kernels, so both new loops are no-ops.

- [ ] **Step 4: Commit**

```bash
git add src/kernel/proc.zig
git commit -m "feat(proc): exit closes ofile + iputs cwd"
```

---

### Task 15: Add `exec_scratch` + extend `proc.exec` for FS_DEMO mode

**Files:**
- Modify: `src/kernel/proc.zig` (add `exec_scratch` global; add `boot_config.FS_DEMO`-conditional path in `exec`)

**Why this task here:** the FS-mode kmain (Task 20) calls `proc.exec("/bin/init", ...)`. exec is currently hard-wired to `boot_config.lookupBlob`. We land the FS-aware branch here so kmain can call exec with a path that's resolved via namei + readi. Depends on path (Task 10), inode (Task 8), and `boot_config.FS_DEMO` (the new stub field, added in Task 26 — but referenced here through `boot_config.FS_DEMO` which is `false` in single/multi/fork stubs and `true` in fs).

**Build-order note:** `boot_config.FS_DEMO` must exist in single + multi + fork stubs as `false` BEFORE this task lands (else the conditional branch panics at comptime). Task 26 adds the field across all stub variants. To unblock this task, we ALSO add the field in single + multi + fork stubs as part of this task (the additions are 1 line each — minimal scope creep).

- [ ] **Step 1: Add `FS_DEMO: bool = false;` to single + multi + fork boot_config stubs in `build.zig`**

In `build.zig`, find the existing `boot_config_zig` (single) write:

```zig
        \\const std = @import("std");
        \\pub const MULTI_PROC: bool = false;
        \\pub const FORK_DEMO: bool = false;
        \\pub const USERPROG_ELF: []const u8 = @embedFile("userprog.elf");
        \\pub const USERPROG2_ELF: []const u8 = "";
        \\pub const INIT_ELF: []const u8 = "";
        \\pub const HELLO_ELF: []const u8 = "";
        \\pub fn lookupBlob(path: []const u8) ?[]const u8 {
        \\    _ = path;
        \\    return null;
        \\}
```

(Note — verify exact strings; the actual `build.zig` may reorder. Match the existing field order; add `FS_DEMO` between `FORK_DEMO` and `USERPROG_ELF`.)

Insert `\\pub const FS_DEMO: bool = false;` between `FORK_DEMO` and `USERPROG_ELF` in EACH of the three existing stubs (single, multi, fork). Do not yet add the FS stub — Task 26.

- [ ] **Step 2: Add `exec_scratch` + extend `proc.exec` for FS_DEMO**

In `src/kernel/proc.zig`, find the existing imports section. Add (if not added by Task 13):

```zig
const path_mod = @import("fs/path.zig");
```

(We name it `path_mod` because the function `proc.exec` already has a parameter named `path_user_va`. Renaming the existing import in Task 13 from `path` to `path_mod` is fine — adjust both Task 13's import block and references.)

Note: in Task 13, change the import line to `const path_mod = @import("fs/path.zig");` (rename for clarity).

Then at file scope in `proc.zig`, after the `boot_config` import line, declare:

```zig
const MAX_EXEC_BYTES: u32 = 64 * 1024;
const EXEC_SCRATCH_PAGES: u32 = MAX_EXEC_BYTES / vm.PAGE_SIZE;

// Static scratch buffer for FS-mode exec — readi reads the on-disk ELF
// into here before elfload.load consumes it. Single-threaded kernel so
// no contention; sized at the spec's 64 KB user-text budget.
var exec_scratch: [EXEC_SCRATCH_PAGES][vm.PAGE_SIZE]u8 align(4) = undefined;
```

Then in `proc.exec`, find the existing line:

```zig
    // 3. Look up the embedded blob.
    const blob = boot_config.lookupBlob(path) orelse return -1;
```

Replace with:

```zig
    // 3. Resolve the blob — embedded (single/multi/fork) or on-disk (fs).
    const blob = if (boot_config.FS_DEMO) blk: {
        const ip = path_mod.namei(path) orelse return -1;
        // iput on every error path that owns ip.
        errdefer inode.iput(ip);

        inode.ilock(ip);
        if (ip.dinode.type != .File) {
            inode.iunlock(ip);
            inode.iput(ip);
            return -1;
        }
        const sz = ip.dinode.size;
        if (sz > MAX_EXEC_BYTES) {
            inode.iunlock(ip);
            inode.iput(ip);
            return -1;
        }
        const dst: [*]u8 = @ptrCast(&exec_scratch[0][0]);
        const got = inode.readi(ip, dst, 0, sz);
        inode.iunlock(ip);
        inode.iput(ip);
        if (got != sz) return -1;
        break :blk dst[0..sz];
    } else (boot_config.lookupBlob(path) orelse return -1);
```

(The remainder of `proc.exec` — pgdir build, elfload.load, mapUserStack, argv tail, commit — is unchanged.)

- [ ] **Step 3: Build the kernel (all variants)**

Run: `zig build kernel-elf`
Expected: PASS — single-mode `boot_config.FS_DEMO == false` so the comptime branch picks the existing embedded path.

Run: `zig build kernel-multi`
Expected: PASS.

Run: `zig build kernel-fork`
Expected: PASS — fork-mode also uses the embedded branch.

- [ ] **Step 4: Run all e2e regression tests**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-fork && zig build e2e-plic-block`
Expected: all PASS — no behavior change for non-FS kernels.

- [ ] **Step 5: Commit**

```bash
git add src/kernel/proc.zig build.zig
git commit -m "feat(exec): add FS-mode blob source (namei + readi + scratch)"
```

---

### Task 16: Wire syscalls 56 (`openat`) + 57 (`close`)

**Files:**
- Modify: `src/kernel/syscall.zig` (add `sysOpenat`, `sysClose`, dispatch arms)

**Why this task here:** `openat` is the entry point — once the kernel can hand a fd back to user space, the rest of the read syscalls (Tasks 17–18) are just thin shims into `file.zig`. We bundle openat + close in one task because they're symmetric and exercise the same `cur.ofile[]` slot allocation path.

- [ ] **Step 1: Add imports + `sysOpenat` + `sysClose` to `syscall.zig`**

In `src/kernel/syscall.zig`, find the existing imports:

```zig
const trap = @import("trap.zig");
const uart = @import("uart.zig");
const proc = @import("proc.zig");
const page_alloc = @import("page_alloc.zig");
const vm = @import("vm.zig");
```

Add below:

```zig
const file = @import("file.zig");
const inode = @import("fs/inode.zig");
const path_mod = @import("fs/path.zig");
const layout = @import("fs/layout.zig");
```

Find the existing `setSum` / `clearSum` helpers and `copyStrFromUser`-shape function (in syscall.zig, the inline copy lives in sysWrite — promote a helper). Add a new helper just below `clearSum`:

```zig
/// Copy a NUL-terminated user string into `buf`. Returns the slice up
/// to (but not including) the NUL, or null on overflow / no NUL within
/// buf.len bytes.
fn copyStrFromUser(user_va: u32, buf: []u8) ?[]u8 {
    setSum();
    defer clearSum();
    var i: u32 = 0;
    while (i < buf.len) : (i += 1) {
        const p: *const volatile u8 = @ptrFromInt(user_va + i);
        const c = p.*;
        buf[i] = c;
        if (c == 0) return buf[0..i];
    }
    return null;
}
```

Then add after `sysSbrk` (right above `sysSetFgPid`):

```zig
/// 56 openat(dirfd, path, flags) — 3.D ignores dirfd and flags
/// (read-only existing file). Returns fd ≥ 0 or -1.
fn sysOpenat(dirfd: u32, path_user_va: u32, flags: u32) i32 {
    _ = dirfd;
    _ = flags;

    var pbuf: [path_mod.MAX_PATH]u8 = undefined;
    const p = copyStrFromUser(path_user_va, &pbuf) orelse return -1;

    const ip = path_mod.namei(p) orelse return -1;

    const fidx = file.alloc() orelse {
        inode.iput(ip);
        return -1;
    };
    file.ftable[fidx].type = .Inode;
    file.ftable[fidx].ip = ip;
    file.ftable[fidx].off = 0;

    // Allocate the lowest free fd in cur.ofile.
    const cur_p = proc.cur();
    var fd: u32 = 0;
    while (fd < proc.NOFILE) : (fd += 1) {
        if (cur_p.ofile[fd] == 0) {
            cur_p.ofile[fd] = fidx;
            return @intCast(fd);
        }
    }

    // No free fd — release the file table entry + inode.
    file.close(fidx);
    return -1;
}

/// 57 close(fd) — release the fd. Returns 0 / -1.
fn sysClose(fd: u32) i32 {
    if (fd >= proc.NOFILE) return -1;
    const cur_p = proc.cur();
    if (cur_p.ofile[fd] == 0) return -1;
    file.close(cur_p.ofile[fd]);
    cur_p.ofile[fd] = 0;
    return 0;
}
```

Then extend the `dispatch` switch — find:

```zig
pub fn dispatch(tf: *trap.TrapFrame) void {
    switch (tf.a7) {
        64 => tf.a0 = sysWrite(tf.a0, tf.a1, tf.a2),
        93 => sysExit(tf.a0),
        124 => tf.a0 = sysYield(),
        172 => tf.a0 = sysGetpid(),
        214 => tf.a0 = sysSbrk(tf.a0),
        220 => tf.a0 = @bitCast(proc.fork()),
        221 => tf.a0 = @bitCast(proc.exec(tf.a0, tf.a1)),
        260 => tf.a0 = @bitCast(proc.wait(tf.a1)),
        5000 => tf.a0 = sysSetFgPid(tf.a0),
        5001 => tf.a0 = sysConsoleSetMode(tf.a0),
        else => tf.a0 = @bitCast(@as(i32, -38)), // -ENOSYS
    }
}
```

Replace with:

```zig
pub fn dispatch(tf: *trap.TrapFrame) void {
    switch (tf.a7) {
        56 => tf.a0 = @bitCast(sysOpenat(tf.a0, tf.a1, tf.a2)),
        57 => tf.a0 = @bitCast(sysClose(tf.a0)),
        64 => tf.a0 = sysWrite(tf.a0, tf.a1, tf.a2),
        93 => sysExit(tf.a0),
        124 => tf.a0 = sysYield(),
        172 => tf.a0 = sysGetpid(),
        214 => tf.a0 = sysSbrk(tf.a0),
        220 => tf.a0 = @bitCast(proc.fork()),
        221 => tf.a0 = @bitCast(proc.exec(tf.a0, tf.a1)),
        260 => tf.a0 = @bitCast(proc.wait(tf.a1)),
        5000 => tf.a0 = sysSetFgPid(tf.a0),
        5001 => tf.a0 = sysConsoleSetMode(tf.a0),
        else => tf.a0 = @bitCast(@as(i32, -38)), // -ENOSYS
    }
}
```

- [ ] **Step 2: Build the kernel (all variants)**

Run: `zig build kernel-elf`
Expected: PASS.

Run: `zig build kernel-multi`
Expected: PASS.

Run: `zig build kernel-fork`
Expected: PASS.

- [ ] **Step 3: Run all e2e regression tests**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-fork && zig build e2e-plic-block`
Expected: all PASS — no userland in 3.A/B/C uses syscalls 56 or 57.

- [ ] **Step 4: Commit**

```bash
git add src/kernel/syscall.zig
git commit -m "feat(syscall): wire 56 openat + 57 close"
```

---

### Task 17: Wire syscalls 63 (`read`) + 62 (`lseek`)

**Files:**
- Modify: `src/kernel/syscall.zig` (add `sysRead`, `sysLseek`, dispatch arms)

**Why this task here:** with openat returning fds (Task 16), read is the next thing init wants to do. lseek lands alongside since it's a one-line shim into `file.lseek` and saves 3.E from re-touching syscall.zig.

- [ ] **Step 1: Add `sysRead` + `sysLseek` to `syscall.zig`**

In `src/kernel/syscall.zig`, find `sysClose` (just added in Task 16). Insert below it:

```zig
/// 63 read(fd, buf, n). Returns bytes / 0 (EOF) / -1.
fn sysRead(fd: u32, buf_user_va: u32, n: u32) i32 {
    if (fd >= proc.NOFILE) return -1;
    const idx = proc.cur().ofile[fd];
    if (idx == 0) return -1;
    return file.read(idx, buf_user_va, n);
}

/// 62 lseek(fd, off, whence). Returns new offset / -1.
fn sysLseek(fd: u32, off_signed: u32, whence: u32) i32 {
    if (fd >= proc.NOFILE) return -1;
    const idx = proc.cur().ofile[fd];
    if (idx == 0) return -1;
    const off: i32 = @bitCast(off_signed);
    return file.lseek(idx, off, whence);
}
```

Then extend the dispatch switch — find the line `57 => tf.a0 = @bitCast(sysClose(tf.a0)),` and add ABOVE the existing `64 =>` arm:

```zig
        56 => tf.a0 = @bitCast(sysOpenat(tf.a0, tf.a1, tf.a2)),
        57 => tf.a0 = @bitCast(sysClose(tf.a0)),
        62 => tf.a0 = @bitCast(sysLseek(tf.a0, tf.a1, tf.a2)),
        63 => tf.a0 = @bitCast(sysRead(tf.a0, tf.a1, tf.a2)),
        64 => tf.a0 = sysWrite(tf.a0, tf.a1, tf.a2),
```

- [ ] **Step 2: Build the kernel (all variants)**

Run: `zig build kernel-elf && zig build kernel-multi && zig build kernel-fork`
Expected: all PASS.

- [ ] **Step 3: Run all e2e regression tests**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-fork && zig build e2e-plic-block`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add src/kernel/syscall.zig
git commit -m "feat(syscall): wire 62 lseek + 63 read"
```

---

### Task 18: Wire syscall 80 (`fstat`)

**Files:**
- Modify: `src/kernel/syscall.zig` (add `sysFstat`, dispatch arm)

**Why this task here:** fstat completes the file-introspection set. 3.D's init doesn't call fstat (it just reads up to a fixed buffer size), but landing it now lets 3.E's `cat` and `ls` use it without revisiting syscall.zig.

- [ ] **Step 1: Add `sysFstat` to `syscall.zig`**

In `src/kernel/syscall.zig`, just below `sysLseek` (added in Task 17):

```zig
/// 80 fstat(fd, statbuf). Writes Stat { type, size } (8 bytes) via SUM=1.
/// Returns 0 / -1.
fn sysFstat(fd: u32, stat_user_va: u32) i32 {
    if (fd >= proc.NOFILE) return -1;
    const idx = proc.cur().ofile[fd];
    if (idx == 0) return -1;
    return file.fstat(idx, stat_user_va);
}
```

Then add to the dispatch switch — find `64 => tf.a0 = sysWrite(...)` and insert ABOVE the `93 =>` exit arm:

```zig
        64 => tf.a0 = sysWrite(tf.a0, tf.a1, tf.a2),
        80 => tf.a0 = @bitCast(sysFstat(tf.a0, tf.a1)),
        93 => sysExit(tf.a0),
```

- [ ] **Step 2: Build the kernel (all variants)**

Run: `zig build kernel-elf && zig build kernel-multi && zig build kernel-fork`
Expected: all PASS.

- [ ] **Step 3: Run all e2e regression tests**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-fork && zig build e2e-plic-block`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add src/kernel/syscall.zig
git commit -m "feat(syscall): wire 80 fstat"
```

---

### Task 19: Wire syscalls 49 (`chdir`) + 17 (`getcwd`)

**Files:**
- Modify: `src/kernel/syscall.zig` (add `sysChdir`, `sysGetcwd`, helpers, dispatch arms)

**Why this task here:** chdir is the only path that mutates `cur.cwd` and `cur.cwd_path`. getcwd reads `cur.cwd_path` straight out. Both are landed for 3.E's shell `cd`/`pwd` builtins; 3.D's init doesn't call either, but the change is regression-safe.

- [ ] **Step 1: Add `sysChdir` + `sysGetcwd` to `syscall.zig`**

In `src/kernel/syscall.zig`, below `sysFstat` (added in Task 18):

```zig
/// Compose a new cwd_path given the current cwd_path and a relative or
/// absolute target. Writes into `out` (NUL-terminated). Returns the
/// length of the resulting path (excluding NUL) or null on overflow.
///
/// 3.D simplification: no cycle / `..` resolution beyond the spec
/// (`..` past root resolves to root, handled by the FS layer; the
/// path-string composition here just normalizes "/" boundaries).
fn composeCwdPath(old: []const u8, target: []const u8, out: *[proc.CWD_PATH_MAX]u8) ?u32 {
    var len: u32 = 0;
    if (target.len > 0 and target[0] == '/') {
        // Absolute: ignore old.
        // Copy target verbatim (caller guarantees ≤ CWD_PATH_MAX-1 via path bounds).
        if (target.len + 1 > proc.CWD_PATH_MAX) return null;
        var i: u32 = 0;
        while (i < target.len) : (i += 1) out[i] = target[i];
        out[target.len] = 0;
        return @intCast(target.len);
    }

    // Relative: append target to old, with a separator.
    var i: u32 = 0;
    while (i < old.len) : (i += 1) {
        if (len >= proc.CWD_PATH_MAX) return null;
        out[len] = old[i];
        len += 1;
    }
    if (len > 0 and out[len - 1] != '/') {
        if (len >= proc.CWD_PATH_MAX) return null;
        out[len] = '/';
        len += 1;
    }
    var j: u32 = 0;
    while (j < target.len) : (j += 1) {
        if (len >= proc.CWD_PATH_MAX) return null;
        out[len] = target[j];
        len += 1;
    }
    if (len >= proc.CWD_PATH_MAX) return null;
    out[len] = 0;
    return len;
}

/// 49 chdir(path). namei → verify Dir → swap cwd. Returns 0 / -1.
fn sysChdir(path_user_va: u32) i32 {
    var pbuf: [path_mod.MAX_PATH]u8 = undefined;
    const p = copyStrFromUser(path_user_va, &pbuf) orelse return -1;

    const ip = path_mod.namei(p) orelse return -1;
    inode.ilock(ip);
    if (ip.dinode.type != .Dir) {
        inode.iunlock(ip);
        inode.iput(ip);
        return -1;
    }
    inode.iunlock(ip);

    // Compose new cwd_path; on overflow, restore old cwd.
    const cur_p = proc.cur();
    var new_path: [proc.CWD_PATH_MAX]u8 = undefined;
    const old_path_len: u32 = blk: {
        var k: u32 = 0;
        while (k < proc.CWD_PATH_MAX and cur_p.cwd_path[k] != 0) : (k += 1) {}
        break :blk k;
    };
    _ = composeCwdPath(cur_p.cwd_path[0..old_path_len], p, &new_path) orelse {
        inode.iput(ip);
        return -1;
    };

    // Commit: iput old cwd, install new.
    if (cur_p.cwd != 0) {
        const old_ip: *inode.InMemInode = @ptrFromInt(cur_p.cwd);
        inode.iput(old_ip);
    }
    cur_p.cwd = @intFromPtr(ip);
    @memcpy(&cur_p.cwd_path, &new_path);
    return 0;
}

/// 17 getcwd(buf, sz). Copies cwd_path into the user buffer (with NUL).
/// Returns bytes copied (excluding NUL) or -1 on size-too-small.
fn sysGetcwd(buf_user_va: u32, sz: u32) i32 {
    const cur_p = proc.cur();

    // Determine length of cwd_path (NUL-terminated).
    var len: u32 = 0;
    while (len < proc.CWD_PATH_MAX and cur_p.cwd_path[len] != 0) : (len += 1) {}

    // Lazy-root: empty cwd_path means "/".
    const src: []const u8 = if (len == 0) "/" else cur_p.cwd_path[0..len];

    if (sz < src.len + 1) return -1; // need room for NUL

    setSum();
    var i: u32 = 0;
    while (i < src.len) : (i += 1) {
        const dst: *volatile u8 = @ptrFromInt(buf_user_va + i);
        dst.* = src[i];
    }
    const dst_nul: *volatile u8 = @ptrFromInt(buf_user_va + src.len);
    dst_nul.* = 0;
    clearSum();
    return @intCast(src.len);
}
```

Then add to the dispatch switch — insert ABOVE the existing `56 =>` arm:

```zig
        17 => tf.a0 = @bitCast(sysGetcwd(tf.a0, tf.a1)),
        49 => tf.a0 = @bitCast(sysChdir(tf.a0)),
        56 => tf.a0 = @bitCast(sysOpenat(tf.a0, tf.a1, tf.a2)),
```

- [ ] **Step 2: Build the kernel (all variants)**

Run: `zig build kernel-elf && zig build kernel-multi && zig build kernel-fork`
Expected: all PASS.

- [ ] **Step 3: Run all e2e regression tests**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-fork && zig build e2e-plic-block`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add src/kernel/syscall.zig
git commit -m "feat(syscall): wire 17 getcwd + 49 chdir"
```

---

### Task 20: Add `kmain` FS_DEMO arm (mount FS + exec /bin/init)

**Files:**
- Modify: `src/kernel/kmain.zig` (add new FS_DEMO arm BEFORE the FORK_DEMO arm)

**Why this task here:** the FS-mode boot path is the consumer of every preceding piece — bufcache, inode cache, PLIC enable, exec FS path. We land it before mkfs/build wiring (Tasks 23–26) so the kernel side is fully functional ahead of the disk image being available; the kernel will simply fault when run without `--disk` until Task 27 wires the e2e step. The unit-test signal is "kernel-fs.elf compiles with FS_DEMO_TRUE stub", which we exercise indirectly in Task 26.

- [ ] **Step 1: Add the FS_DEMO arm in `kmain.zig`**

In `src/kernel/kmain.zig`, find the existing imports section. Add:

```zig
const plic = @import("plic.zig");
const block = @import("block.zig");
const bufcache = @import("fs/bufcache.zig");
const inode = @import("fs/inode.zig");
```

(`block` is added even though we don't call it directly — `trap.zig` does — to ensure the symbol is reachable from this object's import graph in case the linker prunes too aggressively. If the build is fine without it, the line can be removed.)

Then find the existing line:

```zig
    if (boot_config.FORK_DEMO) {
```

Insert ABOVE it:

```zig
    if (boot_config.FS_DEMO) {
        // FS-mode boot: bufcache + inode cache up; PLIC ready for IRQ #1
        // (block); exec /bin/init from disk into PID 1's AS.
        bufcache.init();
        inode.init();

        plic.setPriority(plic.IRQ_BLOCK, 1);
        plic.enable(plic.IRQ_BLOCK);
        plic.setThreshold(0);

        const init_p = proc.alloc() orelse kprintf.panic("kmain: alloc init", .{});
        @memcpy(init_p.name[0..4], "init");
        const init_root = vm.allocRoot() orelse kprintf.panic("kmain: allocRoot init", .{});
        init_p.pgdir = init_root;
        init_p.satp = SATP_MODE_SV32 | (init_root >> 12);
        vm.mapKernelAndMmio(init_root);
        init_p.sz = 0;
        init_p.cwd = 0; // lazy-root

        // Install S-mode trap setup BEFORE exec — exec calls block.read
        // which sleeps, which transitively requires the IRQ + trap path
        // to be ready.
        const stvec_val_fs: u32 = @intCast(@intFromPtr(&s_trap_entry));
        const sscratch_val_fs: u32 = @intCast(@intFromPtr(init_p));
        asm volatile (
            \\ csrw stvec, %[stv]
            \\ csrw sscratch, %[ss]
            :
            : [stv] "r" (stvec_val_fs),
              [ss] "r" (sscratch_val_fs),
            : .{ .memory = true }
        );
        const SIE_BITS_FS: u32 = (1 << 1) | (1 << 9); // SSIE | SEIE
        asm volatile ("csrs sie, %[b]"
            :
            : [b] "r" (SIE_BITS_FS),
            : .{ .memory = true }
        );
        const SSTATUS_SPP_FS: u32 = 1 << 8;
        const SSTATUS_SPIE_FS: u32 = 1 << 5;
        asm volatile (
            \\ csrc sstatus, %[spp]
            \\ csrs sstatus, %[spie]
            :
            : [spp] "r" (SSTATUS_SPP_FS),
              [spie] "r" (SSTATUS_SPIE_FS),
            : .{ .memory = true }
        );

        // Make cur() return PID 1 so exec writes into its trapframe.
        proc.cpu.cur = init_p;

        // exec("/bin/init", NULL).
        const init_path = "/bin/init\x00";
        const path_va = @as(u32, @intCast(@intFromPtr(&init_path[0])));
        const rc = proc.exec(path_va, 0);
        if (rc < 0) kprintf.panic("kmain: exec /bin/init failed", .{});

        init_p.state = .Runnable;
        proc.cpu.cur = null;

        var bootstrap_fs: proc.Context = std.mem.zeroes(proc.Context);
        proc.cpu.sched_context.ra = @intCast(@intFromPtr(&sched.scheduler));
        proc.cpu.sched_context.sp = proc.cpu.sched_stack_top;
        proc.swtch(&bootstrap_fs, &proc.cpu.sched_context);
        unreachable;
    }

    if (boot_config.FORK_DEMO) {
```

(The original `if (boot_config.FORK_DEMO) {` line stays — the new arm just wraps before it.)

- [ ] **Step 2: Build the kernel (all variants — kernel-fs builds in Task 26)**

Run: `zig build kernel-elf`
Expected: PASS — single-mode `boot_config.FS_DEMO == false`, the new arm is comptime-pruned.

Run: `zig build kernel-multi`
Expected: PASS.

Run: `zig build kernel-fork`
Expected: PASS.

- [ ] **Step 3: Run all e2e regression tests**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-fork && zig build e2e-plic-block`
Expected: all PASS — no behavior change for non-FS kernels.

- [ ] **Step 4: Commit**

```bash
git add src/kernel/kmain.zig
git commit -m "feat(kmain): add FS_DEMO arm — mount + exec /bin/init"
```

---

### Task 21: Add `src/kernel/user/fs_init.zig`

**Files:**
- Create: `src/kernel/user/fs_init.zig`

**Why this task here:** the userland binary is what the e2e harness ultimately verifies. We land it before the build wiring (Task 25) so mkfs has something to install onto fs.img.

- [ ] **Step 1: Create `src/kernel/user/fs_init.zig`**

```zig
// src/kernel/user/fs_init.zig — Phase 3.D /bin/init.
//
// Behavior:
//   1. fd = openat(0, "/etc/motd", 0)
//   2. n  = read(fd, buf, 256)
//   3. write(1, buf, n)   // fd 1 = UART
//   4. close(fd)
//   5. exit(0)
//
// Naked _start with inline ecalls (matches Plan 3.B / 3.C user binaries).
// 3.E will rewrite this against the userland stdlib.

export const path linksection(".rodata") = [_]u8{
    '/', 'e', 't', 'c', '/', 'm', 'o', 't', 'd', 0,
};

export var buf linksection(".bss") = [_]u8{0} ** 256;

export fn _start() linksection(".text.init") callconv(.naked) noreturn {
    asm volatile (
        \\ // openat(0, &path, 0)
        \\ li   a7, 56
        \\ li   a0, 0
        \\ la   a1, path
        \\ li   a2, 0
        \\ ecall
        \\ // a0 = fd; bail out on -1
        \\ bltz a0, fail
        \\ mv   s1, a0       // save fd in s1 (callee-saved)
        \\
        \\ // read(fd, buf, 256)
        \\ li   a7, 63
        \\ mv   a0, s1
        \\ la   a1, buf
        \\ li   a2, 256
        \\ ecall
        \\ // a0 = bytes; on -1 or 0, still try to write 0 + exit cleanly
        \\ bltz a0, fail
        \\ mv   s2, a0       // save n in s2
        \\
        \\ // write(1, buf, s2)
        \\ li   a7, 64
        \\ li   a0, 1
        \\ la   a1, buf
        \\ mv   a2, s2
        \\ ecall
        \\
        \\ // close(s1)
        \\ li   a7, 57
        \\ mv   a0, s1
        \\ ecall
        \\
        \\ // exit(0)
        \\ li   a7, 93
        \\ li   a0, 0
        \\ ecall
        \\1: j 1b
        \\
        \\fail:
        \\ // exit(1)
        \\ li   a7, 93
        \\ li   a0, 1
        \\ ecall
        \\2: j 2b
    );
}
```

- [ ] **Step 2: Validate the file parses + formats**

Run: `zig fmt --check src/kernel/user/fs_init.zig`
Expected: PASS.

- [ ] **Step 3: Run all e2e regression tests (build wiring lands in Task 25)**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-fork && zig build e2e-plic-block`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add src/kernel/user/fs_init.zig
git commit -m "feat(user): add fs_init.zig (open/read/write/exit)"
```

---

### Task 22: Add `src/kernel/userland/fs/etc/motd`

**Files:**
- Create: `src/kernel/userland/fs/etc/motd` (19 bytes: `"hello from phase 3\n"`)

**Why this task here:** mkfs's `--root` walk needs a target directory tree. We land the directory + the single content file before mkfs wiring (Task 25) so the build can stage it.

- [ ] **Step 1: Verify the parent directories don't exist; create them**

Run: `ls src/kernel/userland 2>/dev/null && echo EXISTS || echo MISSING`
Expected: MISSING.

Create the file (and parent dirs) by writing it directly:

- [ ] **Step 2: Write `src/kernel/userland/fs/etc/motd`**

File content (19 bytes including the trailing newline):

```
hello from phase 3
```

- [ ] **Step 3: Verify content + size**

Run: `wc -c src/kernel/userland/fs/etc/motd`
Expected: `19 src/kernel/userland/fs/etc/motd`

Run: `cat src/kernel/userland/fs/etc/motd`
Expected: `hello from phase 3` (followed by newline).

- [ ] **Step 4: Commit**

```bash
git add src/kernel/userland/fs/etc/motd
git commit -m "feat(userland): add /etc/motd content for fs.img staging"
```

---

### Task 23: Add `mkfs.zig` (host tool)

**Files:**
- Create: `src/kernel/mkfs.zig`

**Why this task here:** mkfs is the bridge between the staged source tree and the on-disk image. We land it as a host-runnable Zig program before wiring the build target (Task 25); it imports `fs/layout.zig` (Task 5) for on-disk constants. Self-contained — no kernel-side dependencies.

- [ ] **Step 1: Create `src/kernel/mkfs.zig`**

```zig
// src/kernel/mkfs.zig — Phase 3.D host-side FS image builder.
//
// Walks --root + --bin into a 4 MB image written to --out:
//   block 0       boot sector (zeros, reserved)
//   block 1       superblock
//   block 2       block bitmap
//   blocks 3..6   inode table
//   blocks 7..1023  data blocks
//
// Inode 1 is hard-wired as root (/). Subdirectories `bin` and `etc` are
// created by walking --bin (each file → /bin/<name>) and --root (every
// non-/bin file → /<rel-path>) respectively.
//
// Bound: NINODES=64, NBLOCKS=1024 (data: 1017). Errors out cleanly if
// the staged tree exceeds either bound.
//
// Usage:
//   zig-out/bin/mkfs --root <dir> --bin <dir> --out <path>

const std = @import("std");
const layout = @import("fs/layout.zig");
const Io = std.Io;

const FAIL_EXIT: u8 = 1;
const USAGE_EXIT: u8 = 2;

const ImageBuilder = struct {
    image: [layout.NBLOCKS * layout.BLOCK_SIZE]u8,
    inodes: [layout.NINODES]layout.DiskInode,
    next_inum: u32, // next free inum (1-based)
    next_blk: u32, // next free data block (≥ DATA_START_BLK)
    bitmap: [layout.NBLOCKS / 8]u8,

    fn init(self: *ImageBuilder) void {
        self.image = std.mem.zeroes([layout.NBLOCKS * layout.BLOCK_SIZE]u8);
        self.inodes = std.mem.zeroes([layout.NINODES]layout.DiskInode);
        self.bitmap = std.mem.zeroes([layout.NBLOCKS / 8]u8);
        // Reserve blocks 0..6 (boot/super/bitmap/inode-table).
        var b: u32 = 0;
        while (b < layout.DATA_START_BLK) : (b += 1) self.setBitmap(b);
        self.next_inum = 1; // inum 0 == "free"
        self.next_blk = layout.DATA_START_BLK;
    }

    fn setBitmap(self: *ImageBuilder, blk: u32) void {
        self.bitmap[blk / 8] |= (@as(u8, 1) << @intCast(blk % 8));
    }

    fn allocInum(self: *ImageBuilder) ?u32 {
        if (self.next_inum >= layout.NINODES) return null;
        const i = self.next_inum;
        self.next_inum += 1;
        return i;
    }

    fn allocBlock(self: *ImageBuilder) ?u32 {
        if (self.next_blk >= layout.NBLOCKS) return null;
        const b = self.next_blk;
        self.next_blk += 1;
        self.setBitmap(b);
        return b;
    }

    /// Write `data` into the inode `inum`'s data blocks. Allocates direct
    /// blocks for the first NDIRECT logical blocks; allocates an indirect
    /// block + per-leaf data blocks for any blocks past NDIRECT. Updates
    /// inode size + addrs.
    fn writeFile(self: *ImageBuilder, inum: u32, data: []const u8) !void {
        const ip = &self.inodes[inum - 1]; // 1-based
        ip.size = @intCast(data.len);

        var off: u32 = 0;
        var bn: u32 = 0;
        while (off < data.len) : ({
            bn += 1;
            off += layout.BLOCK_SIZE;
        }) {
            const remain = data.len - off;
            const chunk = if (remain > layout.BLOCK_SIZE) layout.BLOCK_SIZE else remain;
            const blk = self.allocBlock() orelse return error.OutOfBlocks;

            const start = blk * layout.BLOCK_SIZE;
            @memcpy(self.image[start .. start + chunk], data[off .. off + chunk]);

            if (bn < layout.NDIRECT) {
                ip.addrs[bn] = blk;
            } else {
                // Need indirect block.
                if (ip.addrs[layout.NDIRECT] == 0) {
                    ip.addrs[layout.NDIRECT] = self.allocBlock() orelse return error.OutOfBlocks;
                }
                const ind_off = ip.addrs[layout.NDIRECT] * layout.BLOCK_SIZE;
                const ind_idx = bn - layout.NDIRECT;
                if (ind_idx >= layout.NINDIRECT) return error.FileTooBig;
                const ptrs: [*]u32 = @ptrCast(@alignCast(&self.image[ind_off]));
                ptrs[ind_idx] = blk;
            }
        }
    }

    /// Append a DirEntry to dir's data blocks (creating blocks as needed).
    fn appendDirEntry(self: *ImageBuilder, dir_inum: u32, name: []const u8, entry_inum: u32) !void {
        if (name.len > layout.DIR_NAME_LEN - 1) return error.NameTooLong;
        const dir = &self.inodes[dir_inum - 1];
        const off = dir.size;
        const bn = off / layout.BLOCK_SIZE;
        const blk_off = off % layout.BLOCK_SIZE;

        // Allocate a new block if we'd straddle the boundary or this is
        // the first DirEntry in a fresh block.
        if (blk_off == 0) {
            if (bn >= layout.NDIRECT) return error.DirTooBig; // 3.D: dirs ≤ 12 blocks
            const blk = self.allocBlock() orelse return error.OutOfBlocks;
            dir.addrs[bn] = blk;
        }

        const dst_blk = dir.addrs[bn];
        const dst_off = dst_blk * layout.BLOCK_SIZE + blk_off;
        var de: layout.DirEntry = .{ .inum = @intCast(entry_inum), .name = std.mem.zeroes([layout.DIR_NAME_LEN]u8) };
        var i: u32 = 0;
        while (i < name.len) : (i += 1) de.name[i] = name[i];

        const de_bytes = std.mem.asBytes(&de);
        @memcpy(self.image[dst_off .. dst_off + 16], de_bytes);
        dir.size += 16;
    }

    fn createDir(self: *ImageBuilder, parent_inum: u32) !u32 {
        const inum = self.allocInum() orelse return error.OutOfInodes;
        const ip = &self.inodes[inum - 1];
        ip.type = .Dir;
        ip.nlink = 1;
        ip.size = 0;
        try self.appendDirEntry(inum, ".", inum);
        try self.appendDirEntry(inum, "..", parent_inum);
        return inum;
    }

    fn createFile(self: *ImageBuilder, dir_inum: u32, name: []const u8, data: []const u8) !void {
        const inum = self.allocInum() orelse return error.OutOfInodes;
        self.inodes[inum - 1].type = .File;
        self.inodes[inum - 1].nlink = 1;
        try self.writeFile(inum, data);
        try self.appendDirEntry(dir_inum, name, inum);
    }

    fn finalize(self: *ImageBuilder) void {
        // Superblock at block 1.
        const sb: *layout.SuperBlock = @ptrCast(@alignCast(&self.image[layout.SUPERBLOCK_BLK * layout.BLOCK_SIZE]));
        sb.* = .{
            .magic = layout.SUPER_MAGIC,
            .nblocks = layout.NBLOCKS,
            .ninodes = layout.NINODES,
            .bitmap_blk = layout.BITMAP_BLK,
            .inode_start = layout.INODE_START_BLK,
            .data_start = layout.DATA_START_BLK,
            .dirty = 0,
        };

        // Bitmap at block 2.
        const bmp_off = layout.BITMAP_BLK * layout.BLOCK_SIZE;
        @memcpy(self.image[bmp_off .. bmp_off + self.bitmap.len], &self.bitmap);

        // Inode table at blocks 3..6 (we only fill block 3 — 64 inodes × 64 B = 4 KB).
        const inodes_off = layout.INODE_START_BLK * layout.BLOCK_SIZE;
        const inodes_bytes = std.mem.asBytes(&self.inodes);
        @memcpy(self.image[inodes_off .. inodes_off + inodes_bytes.len], inodes_bytes);
    }
};

fn populateFromDir(io: Io, builder: *ImageBuilder, dir_inum: u32, dir: std.fs.Dir, gpa: std.mem.Allocator) !void {
    var it = dir.iterate(io);
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .file => {
                var f = try dir.openFile(io, entry.name, .{});
                defer f.close(io);
                const sz = try f.getEndPos(io);
                const buf = try gpa.alloc(u8, sz);
                defer gpa.free(buf);
                _ = try f.readPositionalAll(io, buf, 0);
                try builder.createFile(dir_inum, entry.name, buf);
            },
            .directory => {
                const sub_inum = try builder.createDir(dir_inum);
                try builder.appendDirEntry(dir_inum, entry.name, sub_inum);
                var sub_dir = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer sub_dir.close();
                try populateFromDir(io, builder, sub_inum, sub_dir, gpa);
            },
            else => {},
        }
    }
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var stderr_buf: [512]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_fw.interface;

    const argv = try init.minimal.args.toSlice(gpa);
    defer gpa.free(argv);

    var root_path: ?[]const u8 = null;
    var bin_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) {
        if (std.mem.eql(u8, argv[i], "--root") and i + 1 < argv.len) {
            root_path = argv[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, argv[i], "--bin") and i + 1 < argv.len) {
            bin_path = argv[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, argv[i], "--out") and i + 1 < argv.len) {
            out_path = argv[i + 1];
            i += 2;
        } else {
            stderr.print("mkfs: unexpected arg {s}\n", .{argv[i]}) catch {};
            stderr.flush() catch {};
            return USAGE_EXIT;
        }
    }
    if (root_path == null or bin_path == null or out_path == null) {
        stderr.print("usage: mkfs --root <dir> --bin <dir> --out <path>\n", .{}) catch {};
        stderr.flush() catch {};
        return USAGE_EXIT;
    }

    var builder = try gpa.create(ImageBuilder);
    defer gpa.destroy(builder);
    builder.init();

    // Create root inode (inum 1) with `.` and `..` (both → root).
    const root_inum = try builder.createDir(0); // parent_inum 0 placeholder
    if (root_inum != layout.ROOT_INUM) return error.RootInumMismatch;
    // Patch `..` to point at root itself.
    builder.inodes[root_inum - 1].size = 0;
    try builder.appendDirEntry(root_inum, ".", root_inum);
    try builder.appendDirEntry(root_inum, "..", root_inum);

    // /etc + /bin subdirectories.
    const etc_inum = try builder.createDir(root_inum);
    try builder.appendDirEntry(root_inum, "etc", etc_inum);
    const bin_inum = try builder.createDir(root_inum);
    try builder.appendDirEntry(root_inum, "bin", bin_inum);

    // Walk --root: every file goes into /etc (3.D simplification — only
    // /etc is supported; the spec eventually expands to /var, /tmp, etc.,
    // but 3.D's e2e only needs /etc/motd).
    var root_dir = std.fs.cwd().openDir(io, root_path.?, .{ .iterate = true }) catch |err| {
        stderr.print("mkfs: cannot open --root {s}: {s}\n", .{ root_path.?, @errorName(err) }) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    };
    defer root_dir.close();
    var etc_dir = root_dir.openDir(io, "etc", .{ .iterate = true }) catch null;
    if (etc_dir) |*d| {
        defer d.close();
        try populateFromDir(io, builder, etc_inum, d.*, gpa);
    }

    // Walk --bin: every file goes into /bin.
    var bin_dir = std.fs.cwd().openDir(io, bin_path.?, .{ .iterate = true }) catch |err| {
        stderr.print("mkfs: cannot open --bin {s}: {s}\n", .{ bin_path.?, @errorName(err) }) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    };
    defer bin_dir.close();
    try populateFromDir(io, builder, bin_inum, bin_dir, gpa);

    builder.finalize();

    // Write the image.
    var f = try std.fs.cwd().createFile(io, out_path.?, .{ .truncate = true });
    defer f.close(io);
    try f.writePositionalAll(io, &builder.image, 0);

    return 0;
}
```

- [ ] **Step 2: Validate the file parses + formats**

Run: `zig fmt --check src/kernel/mkfs.zig`
Expected: PASS.

- [ ] **Step 3: Run `zig build test` (host tests in fs/layout.zig still pass)**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/kernel/mkfs.zig
git commit -m "feat(mkfs): add host tool for building 4 MB FS image"
```

---

### Task 24: Wire `kernel-fs-init.elf` build target

**Files:**
- Modify: `build.zig` (add `kernel_fs_init_obj`, `kernel_fs_init_elf`, install + step)

**Why this task here:** the FS image needs an `init.elf` to install at `/bin/init`. We land the build target before mkfs wiring (Task 25) so the binary's emitted file path can feed mkfs's `--bin` argument.

- [ ] **Step 1: Add `kernel-fs-init` build object + elf + step**

In `build.zig`, find the existing `kernel_init_elf` block (Task-9-of-Plan-3.C, around line 365–390):

```zig
    const kernel_init_obj = b.addObject(.{
        .name = "kernel-init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/user/init.zig"),
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });

    const kernel_init_elf = b.addExecutable(.{
        .name = "init.elf",
        ...
```

After the `kernel_init` and `kernel_hello` blocks (and before the `boot_config_zig` write-files), add a parallel `kernel_fs_init` block:

```zig
    const kernel_fs_init_obj = b.addObject(.{
        .name = "kernel-fs-init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/user/fs_init.zig"),
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });

    const kernel_fs_init_elf = b.addExecutable(.{
        .name = "fs_init.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    kernel_fs_init_elf.root_module.addObject(kernel_fs_init_obj);
    kernel_fs_init_elf.setLinkerScript(b.path("src/kernel/user/user_linker.ld"));
    kernel_fs_init_elf.entry = .{ .symbol_name = "_start" };

    const kernel_fs_init_elf_bin = kernel_fs_init_elf.getEmittedBin();
    const install_kernel_fs_init_elf = b.addInstallFile(kernel_fs_init_elf_bin, "fs_init.elf");
    const kernel_fs_init_step = b.step("kernel-fs-init", "Build the Phase 3.D fs_init.elf");
    kernel_fs_init_step.dependOn(&install_kernel_fs_init_elf.step);
```

- [ ] **Step 2: Build the new target**

Run: `zig build kernel-fs-init`
Expected: PASS — produces `zig-out/fs_init.elf`.

Run: `ls -la zig-out/fs_init.elf`
Expected: file exists, size > 0.

- [ ] **Step 3: Run all e2e regression tests**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-fork && zig build e2e-plic-block`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add build.zig
git commit -m "build: add kernel-fs-init target (fs_init.elf for fs.img)"
```

---

### Task 25: Wire `mkfs` build target + `fs.img` generation

**Files:**
- Modify: `build.zig` (add `mkfs_exe`, `fs_bin_stage`, `fs_img_run`, `fs_img_step`)

**Why this task here:** with mkfs (Task 23), fs_init (Task 24), and motd (Task 22) all in place, we can finally produce the FS image. We stage `fs_init.elf` into a temp dir (renamed to `init` so mkfs installs it as `/bin/init`), then invoke mkfs against it.

- [ ] **Step 1: Add `mkfs_exe` host build + `fs_img` run + `fs-img` step**

In `build.zig`, after the new `kernel_fs_init` block from Task 24, add:

```zig
    // Phase 3.D: mkfs host tool.
    const mkfs_exe = b.addExecutable(.{
        .name = "mkfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/mkfs.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const install_mkfs = b.addInstallArtifact(mkfs_exe, .{});
    const mkfs_step = b.step("mkfs", "Build the host-side mkfs tool");
    mkfs_step.dependOn(&install_mkfs.step);

    // Stage --bin: copy fs_init.elf into a temp dir as `init`.
    const fs_bin_stage = b.addWriteFiles();
    _ = fs_bin_stage.addCopyFile(kernel_fs_init_elf_bin, "init");

    // Run mkfs to produce fs.img.
    const fs_img_run = b.addRunArtifact(mkfs_exe);
    fs_img_run.addArg("--root");
    fs_img_run.addDirectoryArg(b.path("src/kernel/userland/fs"));
    fs_img_run.addArg("--bin");
    fs_img_run.addDirectoryArg(fs_bin_stage.getDirectory());
    fs_img_run.addArg("--out");
    const fs_img = fs_img_run.addOutputFileArg("fs.img");

    const install_fs_img = b.addInstallFile(fs_img, "fs.img");
    const fs_img_step = b.step("fs-img", "Build fs.img from staged userland + mkfs");
    fs_img_step.dependOn(&install_fs_img.step);
```

- [ ] **Step 2: Build the new targets**

Run: `zig build mkfs`
Expected: PASS — `zig-out/bin/mkfs` produced.

Run: `zig build fs-img`
Expected: PASS — `zig-out/fs.img` produced.

Run: `ls -la zig-out/fs.img`
Expected: file exists, exactly 4194304 bytes (4 MB).

Run: `od -An -tu4 -N 16 -j 4096 zig-out/fs.img`
Expected: first u32 (magic) = `3284563200` (0xC3CC_F500 in decimal). Or use `xxd -s 4096 -l 16 zig-out/fs.img` to see the bytes.

- [ ] **Step 3: Run all e2e regression tests**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-fork && zig build e2e-plic-block`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add build.zig
git commit -m "build: add mkfs + fs-img targets (4 MB image with /bin/init + /etc/motd)"
```

---

### Task 26: Wire `fs_boot_config.zig` stub + `kernel-fs.elf` executable

**Files:**
- Modify: `build.zig` (add `fs_boot_config_zig` write-files, `kernel_kmain_fs_obj`, `kernel_fs_elf`, install + step)

**Why this task here:** with the kernel side fully wired (Tasks 1–20) and the disk image producible (Task 25), we can finally build the FS-mode kernel. This is the last piece before the e2e test (Task 27).

- [ ] **Step 1: Add `fs_boot_config_zig` stub**

In `build.zig`, find the existing `fork_boot_config_stub_dir` block. After it, add:

```zig
    const fs_boot_config_stub_dir = b.addWriteFiles();
    const fs_boot_config_zig = fs_boot_config_stub_dir.add(
        "boot_config.zig",
        \\const std = @import("std");
        \\pub const MULTI_PROC: bool = false;
        \\pub const FORK_DEMO: bool = false;
        \\pub const FS_DEMO: bool = true;
        \\pub const USERPROG_ELF: []const u8 = "";
        \\pub const USERPROG2_ELF: []const u8 = "";
        \\pub const INIT_ELF: []const u8 = "";
        \\pub const HELLO_ELF: []const u8 = "";
        \\pub fn lookupBlob(path: []const u8) ?[]const u8 {
        \\    _ = path;
        \\    return null;
        \\}
        ,
    );
```

(No `addCopyFile` calls here — fs-mode embeds nothing.)

- [ ] **Step 2: Add `kernel_kmain_fs_obj` + `kernel_fs_elf` + install + step**

In `build.zig`, find the existing `kernel_kmain_fork_obj` block. After it, add:

```zig
    const kernel_kmain_fs_obj = b.addObject(.{
        .name = "kernel-kmain-fs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/kmain.zig"),
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    kernel_kmain_fs_obj.root_module.addAnonymousImport("boot_config", .{
        .root_source_file = fs_boot_config_zig,
    });
```

Then find the existing `kernel_fork_elf` block. After it, add:

```zig
    const kernel_fs_elf = b.addExecutable(.{
        .name = "kernel-fs.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    kernel_fs_elf.root_module.addObject(kernel_boot_obj);
    kernel_fs_elf.root_module.addObject(kernel_trampoline_obj);
    kernel_fs_elf.root_module.addObject(kernel_mtimer_obj);
    kernel_fs_elf.root_module.addObject(kernel_swtch_obj);
    kernel_fs_elf.root_module.addObject(kernel_kmain_fs_obj);
    kernel_fs_elf.setLinkerScript(b.path("src/kernel/linker.ld"));
    kernel_fs_elf.entry = .{ .symbol_name = "_M_start" };

    const install_kernel_fs_elf = b.addInstallArtifact(kernel_fs_elf, .{});
    const kernel_fs_step = b.step("kernel-fs", "Build the Phase 3.D fs-mode kernel.elf");
    kernel_fs_step.dependOn(&install_kernel_fs_elf.step);
```

- [ ] **Step 3: Build the new kernel**

Run: `zig build kernel-fs`
Expected: PASS — `zig-out/kernel-fs.elf` produced.

Run: `ls -la zig-out/kernel-fs.elf`
Expected: file exists, size > 0.

- [ ] **Step 4: Smoke-test the FS-mode kernel manually**

Run: `zig build fs-img && zig build kernel-fs`
Then: `./zig-out/bin/ccc --disk zig-out/fs.img zig-out/kernel-fs.elf`
Expected: stdout contains `"hello from phase 3"` followed by `"ticks observed: N\n"`; exit code 0.

- [ ] **Step 5: Run all four prior e2e regression tests**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub && zig build e2e-fork && zig build e2e-plic-block`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add build.zig
git commit -m "build: add fs_boot_config + kernel-fs.elf (FS-mode kernel)"
```

---

### Task 27: Add `tests/e2e/fs.zig` + `e2e-fs` step

**Files:**
- Create: `tests/e2e/fs.zig`
- Modify: `build.zig` (add `fs_verify` host build + `e2e-fs` step)

**Why this task here:** the headline acceptance gate. Mirror the structure of `tests/e2e/fork.zig` (Plan 3.C) — spawn the kernel, capture stdout, assert the milestone strings are present.

- [ ] **Step 1: Create `tests/e2e/fs.zig`**

```zig
// tests/e2e/fs.zig — Phase 3.D verifier.
//
// Spawns ccc --disk fs.img kernel-fs.elf, captures stdout, asserts:
//   - exit code 0
//   - stdout contains "hello from phase 3\n" (motd content)
//   - stdout contains "ticks observed: " followed by a decimal number + \n
//     (PID 1 = init exits via syscall.sysExit → proc.exit's PID-1 trailer).

const std = @import("std");
const Io = std.Io;

const FAIL_EXIT: u8 = 1;
const USAGE_EXIT: u8 = 2;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var stderr_buf: [512]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_fw.interface;

    const argv = try init.minimal.args.toSlice(gpa);
    defer gpa.free(argv);

    if (argv.len != 4) {
        stderr.print("usage: {s} <ccc-binary> <fs.img> <kernel-fs.elf>\n", .{argv[0]}) catch {};
        stderr.flush() catch {};
        return USAGE_EXIT;
    }

    const child_argv = &[_][]const u8{ argv[1], "--disk", argv[2], argv[3] };
    var child = try std.process.spawn(io, .{
        .argv = child_argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    const MAX_BYTES: usize = 65536;
    var read_buf: [4096]u8 = undefined;
    var reader = child.stdout.?.reader(io, &read_buf);
    const out = reader.interface.allocRemaining(gpa, .limited(MAX_BYTES)) catch |err| switch (err) {
        error.StreamTooLong => {
            stderr.print("fs_verify_e2e: output exceeded {d} bytes\n", .{MAX_BYTES}) catch {};
            stderr.flush() catch {};
            child.kill(io);
            return FAIL_EXIT;
        },
        else => return err,
    };
    defer gpa.free(out);

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            stderr.print("fs_verify_e2e: expected exit 0, got {d}\nstdout was:\n{s}\n", .{ code, out }) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
        else => {
            stderr.print("fs_verify_e2e: child terminated abnormally: {any}\nstdout was:\n{s}\n", .{ term, out }) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
    }

    if (std.mem.indexOf(u8, out, "hello from phase 3\n") == null) {
        stderr.print("fs_verify_e2e: missing motd content\n  stdout: {s}\n", .{out}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    const ticks_marker = "ticks observed: ";
    const ticks_idx = std.mem.indexOf(u8, out, ticks_marker) orelse {
        stderr.print("fs_verify_e2e: missing ticks-observed trailer\n  stdout: {s}\n", .{out}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    };
    const after_ticks = out[ticks_idx + ticks_marker.len ..];
    var nl: usize = 0;
    while (nl < after_ticks.len and after_ticks[nl] != '\n') : (nl += 1) {}
    if (nl == 0 or nl == after_ticks.len) {
        stderr.print("fs_verify_e2e: malformed ticks line\n  stdout: {s}\n", .{out}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }
    _ = std.fmt.parseInt(u32, after_ticks[0..nl], 10) catch {
        stderr.print("fs_verify_e2e: ticks N not a number: {s}\n", .{after_ticks[0..nl]}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    };

    return 0;
}
```

- [ ] **Step 2: Add `fs_verify` host build + `e2e-fs` step in `build.zig`**

In `build.zig`, find the existing `fork_verify` block. After it, add:

```zig
    const fs_verify = b.addExecutable(.{
        .name = "fs_verify_e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e/fs.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const e2e_fs_run = b.addRunArtifact(fs_verify);
    e2e_fs_run.addFileArg(exe.getEmittedBin());
    e2e_fs_run.addFileArg(fs_img);
    e2e_fs_run.addFileArg(kernel_fs_elf.getEmittedBin());
    e2e_fs_run.expectExitCode(0);

    const e2e_fs_step = b.step("e2e-fs", "Run the Phase 3.D fs-read e2e test (init opens /etc/motd)");
    e2e_fs_step.dependOn(&e2e_fs_run.step);
```

- [ ] **Step 3: Build + run e2e-fs**

Run: `zig build e2e-fs`
Expected: PASS — verifier exit 0, output silent.

- [ ] **Step 4: Run ALL e2e regression tests**

Run: `zig build e2e-kernel`
Expected: PASS.

Run: `zig build e2e-multiproc-stub`
Expected: PASS.

Run: `zig build e2e-fork`
Expected: PASS.

Run: `zig build e2e-plic-block`
Expected: PASS.

Run: `zig build e2e-snake`
Expected: PASS.

Run: `zig build e2e-hello-elf && zig build e2e && zig build e2e-mul && zig build e2e-trap`
Expected: all PASS.

Run: `zig build riscv-tests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/fs.zig build.zig
git commit -m "feat(e2e): add e2e-fs (init reads /etc/motd from disk)"
```

---

### Task 28: README + final regression sweep

**Files:**
- Modify: `README.md` (add Phase 3.D entry to Status / Layout / Building)

**Why this task here:** the closing task. We update the headline doc to advertise the new milestone, run the entire test suite one more time, and tag the work as ready for PR.

- [ ] **Step 1: Update `README.md` Status block**

In `README.md`, find the existing Phase 3.C status line (likely `**Phase 3.C — fork/exec/wait/exit/kill-flag.** ...`). Add a parallel line below:

```markdown
**Phase 3.D — Bufcache + block driver + FS read path.** Kernel-side PLIC + block drivers; buffer cache with sleep-on-busy; complete FS read layer (layout, balloc, inode + bmap + readi, dir, path); 7 new syscalls (`getcwd`, `chdir`, `openat`, `close`, `lseek`, `read`, `fstat`); `mkfs.zig` host tool builds a 4 MB `fs.img`. `init` is loaded from disk: it opens `/etc/motd`, reads the contents, writes them to fd 1, exits. New e2e: `e2e-fs`.
```

- [ ] **Step 2: Update Layout table**

Find the existing Layout block. Add new rows for `fs/`, `block.zig`, `plic.zig`, `file.zig`, `mkfs.zig`, `userland/fs/etc/motd`, `user/fs_init.zig`, `tests/e2e/fs.zig`. Keep the table sorted by path.

- [ ] **Step 3: Update Building table**

Find the existing Building block (which lists `zig build kernel-fork`, `zig build e2e-fork`, etc.). Add rows:

```
zig build kernel-fs        — build the Phase 3.D fs-mode kernel.elf
zig build kernel-fs-init   — build fs_init.elf (the on-disk /bin/init)
zig build mkfs             — build the host-side mkfs tool
zig build fs-img           — build fs.img from staged userland + mkfs
zig build e2e-fs           — run the Phase 3.D e2e test
```

- [ ] **Step 4: Run the full test sweep**

Run: `zig build test`
Expected: PASS.

Run: `zig build e2e-fs`
Expected: PASS.

Run: `zig build e2e-kernel`
Expected: PASS.

Run: `zig build e2e-multiproc-stub`
Expected: PASS.

Run: `zig build e2e-fork`
Expected: PASS.

Run: `zig build e2e-plic-block`
Expected: PASS.

Run: `zig build e2e-snake`
Expected: PASS.

Run: `zig build e2e-hello-elf && zig build e2e && zig build e2e-mul && zig build e2e-trap`
Expected: all PASS.

Run: `zig build riscv-tests`
Expected: PASS.

Run: `zig build wasm`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: README — add Phase 3.D status, layout, build targets"
```

---

## Self-review summary

This plan covers every spec requirement for Plan 3.D:

- **Block driver in kernel** — Task 3 (`block.zig`) + Task 4 (S-external dispatch in `trap.zig`).
- **Bufcache** — Task 6 (`fs/bufcache.zig`).
- **Rest of fs/*.zig** — Tasks 5 (layout), 7 (balloc), 8 (inode), 9 (dir), 10 (path).
- **mkfs.zig** — Task 23.
- **fs-img build target** — Task 25.
- **New syscalls (`openat`, `close`, `read`, `lseek`, `fstat`, `chdir`, `getcwd`)** — Tasks 16–19.
- **`init` loaded from `fs.img` instead of embedded** — Tasks 20, 21, 26.
- **Milestone: `e2e-fs` runs an `init` that opens `/etc/motd`, reads it, writes it to fd 1, exits** — Tasks 21 (init), 22 (motd), 27 (e2e step).

Every other spec sub-section deferred to 3.E or never (per "Not in Plan 3.D" list above) is explicitly named.

No placeholders remain. Every code-mutating step shows the actual code. Every verification step lists the exact command + expected outcome.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-26-phase3-plan-d-bufcache-block-fs-read.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
