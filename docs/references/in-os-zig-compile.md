# Enabling in-OS Zig: write, compile, run inside `ccc`

Reference notes on what it would take to deliver this experience:

```
$ ccc --disk shell-fs.img kernel-fs.elf
...
$ edit hello.zig
$ zigc hello.zig -o hello
$ ./hello
hello world
```

— i.e. the entire dev loop (edit → compile → run) happens **inside** the
running ccc OS, not on the host.

The kernel side already supports the run step. The hard part is the
compile step, because today there is no compiler in the guest.

## What already works

The OS layer needed to host a toolchain mostly exists at the end of
Phase 3:

| Capability                 | Where                                                                          |
|----------------------------|--------------------------------------------------------------------------------|
| Edit a text file in-place  | `/bin/edit` (raw mode + ANSI redraw + `^S` save)                               |
| Persist writes to disk     | `block.zig` write path + `e2e-persist`                                         |
| Resolve a path & load ELF  | `proc.exec` → `namei` + `readi` + `elfload.load`                               |
| Spawn / wait on processes  | `fork` / `execve` / `wait4` / `exit`                                           |
| Shell with redirect / pipe | `/bin/sh` (line, token, `< > >>`, builtins, fork+exec)                         |
| File I/O syscalls          | `openat`, `close`, `read`, `lseek`, `fstat`, `chdir`, `getcwd`, `mkdirat`, `unlinkat` |
| User stdlib                | `src/kernel/user/lib/` — `start.S`, `usys.S` (19 stubs), `ulib.zig`, `uprintf.zig` |

So once any binary lands at, say, `/bin/hello` on the disk image, the
shell can `./hello` it. The missing piece is **getting the binary
there** in response to source the user just typed.

## The gap

There are two honest ways to fill it. They differ in scope by an order
of magnitude.

| Path                | Compiler runs on | Realistic? | Effort                       |
|---------------------|------------------|------------|------------------------------|
| A. In-guest compiler | RV32 ccc userland | Heroic     | Phase-sized, multi-month     |
| B. Host bridge       | Host machine      | Pragmatic  | Days, scoped to a few files  |

Path B gives the same UX. Path A is the "real" answer if the project's
goal includes self-hosting.

## Path A — real compiler running inside ccc

To make `zigc hello.zig` actually compile inside the guest, every one
of these has to land:

### A1. A compiler binary that fits

Stock `zig` is tens of MB and depends on LLVM, threads, mmap, and
dynamic linking. None of that exists in ccc. Even Zig's self-hosted
RISC-V backend ships inside the larger driver that assumes a real host
OS. Realistic options for the guest:

- A **Zig-subset compiler written from scratch** in Zig, targeting the
  ccc user ABI directly — comparable in scope to a learning compiler
  like `chibicc` (~10 KLOC of C → x86_64). For Zig this would be
  larger because of comptime, generics, error unions, etc.
- A **C subset compiler** (e.g. port `chibicc`) — gives `cc`, not
  `zigc`, but is the smallest viable toolchain.

Either way it must be a **single binary** that emits ELFs directly
(no separate assembler / linker pass), so it can run end-to-end in one
`fork+exec`.

### A2. ELF emission without a host linker

Today every user ELF is produced by host `ld` against
`src/kernel/user/user_linker.ld`, which fixes the load address and
section layout. An in-guest compile has to:

- Emit RV32 machine code directly.
- Resolve all relocations itself (no `R_RISCV_*` left over).
- Write a valid ELF32 with the `PT_LOAD` segments `elfload.zig`
  expects.
- Bake in the same load address `user_linker.ld` uses today, or have
  the kernel grow PIE support.

### A3. Kernel scratch buffer expansion

`proc.exec` loads the on-disk ELF into a fixed **64 KB** kernel scratch
buffer (see `src/kernel/proc.zig`). Compiler binaries are MBs. Either
bump the buffer (cheap, but eats kernel RAM), or stream `PT_LOAD`
segments straight from the FS into user pages (correct but more code
in `elfload.zig`).

### A4. Disk capacity

`shell-fs.img` is 4 MB total — superblock + bitmap + inode table +
data blocks (`src/kernel/fs/layout.zig`). A toolchain plus its own
sources won't fit. Needs:

- Larger image (`NBLOCKS`, `NINODES` bump in `layout.zig`, matching
  changes in `mkfs.zig`).
- `--disk` size becomes a parameter, not the hard-coded 4 MB.

### A5. Userland memory model

`sbrk` (#214) is wired but only used by the editor's bump allocator.
A real compiler needs:

- A working **heap allocator** in user space (free, not just bump).
- `mmap` or equivalent for large transient allocations (parse trees,
  IR buffers, codegen output).
- Plenty of headroom in the user address space (Sv32 gives 4 GB
  virtual; physical is 128 MB by default).

### A6. Missing syscalls the compiler will reach for

A toolchain typically needs at least:

- `getdents` — directory iteration. ccc has no equivalent today.
- `mmap` / `munmap`.
- `dup` / `dup2` / `pipe` — for any kind of preprocessor / driver
  pipeline.
- `clock_gettime` or similar — for cache invalidation, build stamps.
- Environment variables — `getenv` / `environ`.
- `getrandom` — Zig's stdlib hashing/`HashMap` seeds use it.
- Real `wait4` flag handling beyond the current "any zombie child".

ccc currently exposes 19 syscalls (`usys.S`). A self-hosting toolchain
would roughly double that.

### A7. A non-trivial user `std`

`ulib.zig` + `uprintf.zig` cover `mem*` / `str*` + a 19-stub syscall
layer + `printf`. Zig's real stdlib expects a working OS interface
layer (`std.os.linux`-style). Either:

- Port enough of `std` to ccc's syscall surface (large), or
- Write a hand-rolled compiler that uses only `ulib` (tractable but
  cuts you off from `std`).

### A8. Build glue inside the guest

To match `zigc hello.zig -o hello`:

- A `/bin/zigc` binary at the end of all the above.
- Possibly `/bin/as` and `/bin/ld` if the compiler isn't single-binary.
- A way to set executable mode (today inodes are typed `T_FILE` /
  `T_DIR` / `T_DEV` only — no permission bits; the kernel happily
  execs anything readable, so this is actually free).

### Path A — minimum viable shape

The smallest thing that delivers the experience without faking it:

1. Hand-write a **Zig-subset compiler** in Zig that targets ccc's
   user ABI, emits ELF32 directly, runs in <2 MB RAM.
2. Bump `proc.exec` scratch buffer to 2 MB and grow `shell-fs.img`
   to 16 MB.
3. Add `getdents`, `mmap`, env-vars, `getrandom` syscalls.
4. Ship a `/bin/zigc` and a `programs/userland-template/` so the
   user has a starting point.

Estimated scope: comparable to one full Phase. Not in the current
roadmap (Phase 4 is the network stack, Phase 5 is the browser).

## Path B — host bridge that feels the same

The pragmatic version: keep the compile on the host, but make the
guest experience identical.

### B1. Add a "host service" MMIO device

Sibling of `block.zig` and `uart.zig` under `src/emulator/devices/`.
Memory-mapped registers:

```
0x1000_2000  cmd_ptr       guest physical address of a command struct
0x1000_2004  cmd_len       length in bytes
0x1000_2008  status        0 = idle, 1 = busy, 2 = ok, 3 = err
0x1000_200c  result_len    bytes the host wrote back
```

Command payload (TLV or simple struct):

```zig
const HostCmd = extern struct {
    op: u32,         // 1 = compile_zig
    src_path: [128]u8,
    out_path: [128]u8,
};
```

The host implementation shells out to `zig build-exe` with the user
template + linker script + `ReleaseSmall`, then writes the resulting
ELF bytes into the disk image's `out_path` via the same FS code paths
`mkfs` already uses.

This is **not** a syscall — it's a device the kernel exposes. Could
also be a real syscall if you want guest-side path resolution.

### B2. A `/bin/zigc` userland binary

Tiny program: arg-parses `zigc <src> -o <out>`, fills the `HostCmd`,
writes to the device, polls `status`, prints any error string the
host wrote back.

### B3. In-place FS write from host

The host can't safely scribble into the disk image while the guest is
running unless we either:

- Quiesce the block device, mutate, then resume (simplest), or
- Have the host call back through the kernel's `ialloc` / `writei`
  via a privileged path (cleaner; reuses the FS write path that
  Phase 3.E already shipped).

The second option keeps the FS layout invariants intact.

### B4. Optional — make compilation hermetic

To make the bridge feel honest, also expose:

- Read of the source file the user just edited (host opens the disk
  image read-only at the same offset; or guest reads the file and
  passes the bytes in the command).
- A way to surface compile errors as a string back to `/bin/zigc`'s
  stderr.

### Path B — minimum viable shape

1. Add `devices/hostsvc.zig` (one MMIO device, ~150 lines).
2. Add `/bin/zigc` userland binary (~80 lines).
3. Wire host-side compile in `src/emulator/main.zig`: shell out to
   `zig build-exe` against `src/kernel/user/user_linker.ld` + `lib/`,
   splice the resulting ELF into the running disk image.
4. Bonus: an `mkfs install <img> <host-file> <guest-path>` mode for
   ad-hoc non-bridge use.

Estimated scope: ~1 spec + 1 plan + a few hundred lines of code. Days,
not months.

## Out of scope either way

These would be needed for a "real Unix" feel but are independent of
the compile-in-guest question:

- Permissions / ownership / users.
- A real `/proc` or `/sys`.
- Networking inside the guest (Phase 4).
- Multiple harts.

## Recommendation

If the goal is the **experience**, do Path B. It delivers the exact
loop the user sees (`edit hello.zig` → `zigc hello.zig` → `./hello`),
honestly cheats on what's running where, and unlocks a host-bridge
device that can later carry other host services (clock, random,
clipboard).

If the goal is **self-hosting** as a project milestone — the same
spirit as "no Linux, no TLS, no graphics" in the README — Path A is
the answer, but it should be its own phase, sized like Phase 3.
