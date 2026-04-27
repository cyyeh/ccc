# How `shell.elf` runs end-to-end

Reference notes on the under-the-hood execution path of the Phase 3
shell demo: from a keystroke in the visitor's browser down through
the wasm emulator, the M-mode boot shim, the S-mode kernel, the
on-disk userland, and back out to the rendered terminal.

Unlike `snake.elf` (one bare-metal M-mode ELF), the shell experience
is a **full multi-process OS** running inside wasm. Two artifacts
make it work:

- **`kernel-fs.elf`** — the FS-mode kernel (M-mode boot shim → S-mode
  kernel + scheduler + filesystem + cooked-mode console + syscalls).
- **`shell-fs.img`** — a 4 MB filesystem image with `/bin/init`,
  `/bin/sh`, `/bin/ls`, `/bin/cat`, `/bin/echo`, `/bin/mkdir`,
  `/bin/rm`, `/bin/edit`, `/etc/motd`, and `/tmp/`.

Both are produced by `zig build wasm` and fetched on demand by the
demo page.

## Big picture

```
visitor's browser  ──keystroke──▶  web/demo.js  ──postMessage──▶  web/runner.js (Worker)
                                       ▲                              │
                                       │                              │ pushInput(byte)
                                       │ output bytes                 ▼
                                       │                          ccc.wasm  (emulator + RAM + devices)
                                       │                              │
                                       │                              │ executes RV32 instructions
                                       │                              ▼
                              web/ansi.js  ◀── consumeOutput ── kernel-fs.elf  (M-mode → S-mode)
                              (80×24 grid)                            │
                                                                      │ namei + readi from
                                                                      │ shell-fs.img (in disk_buffer)
                                                                      ▼
                                                              /bin/init → fork → /bin/sh
                                                                                   │
                                                                                   │ readline → tokenize → fork
                                                                                   ▼
                                                                              /bin/{ls,cat,echo,…}
```

Heartbeat: **keystroke → UART RX FIFO → PLIC src 10 → S-trap →
console.feedByte → cooked-mode echo + line buffer → sh's `read()`
returns → fork+exec the command → child writes to UART THR → bytes
flow back to the browser → ANSI render**.

## Layer 1 — browser: page, Worker, ANSI interpreter

The visitor lands on `web/index.html`. A `<select>` chooses the
program (default: shell). `web/demo.js` (main thread) is the UI host:

- Per-program key map. Shell mode: ASCII printables, `Ctrl+letter` →
  `0x01..0x1a` (covers `^C`/`^D`/`^U`/`^S`/`^X`), Enter→`\n`,
  Backspace→`\x7f`, Tab, Escape, and 3-byte ESC sequences for the four
  arrow keys (the editor needs them).
- Forwards every byte to the Worker via `postMessage({type:"input",
  byte})`.
- Renders by feeding output bytes to `web/ansi.js`'s 80×24 grid +
  positioning a CSS-animated `<span id="cursor">` overlay at
  (`ansi.row`, `ansi.col`).

`web/runner.js` is a Web Worker that hosts `ccc.wasm`:

- On `start`: fetches `kernel-fs.elf` and `shell-fs.img` in parallel,
  copies the ELF into the wasm `elf_buffer` and the disk image into
  the wasm `disk_buffer`, then calls `runStart(elfLen, trace,
  diskLen)`.
- Drives `runStep(500_000)` in a `setTimeout(0)` loop, draining the
  output buffer between chunks. 500 K instructions per chunk yields
  ~30–100 ms per tick; input latency stays under ~100 ms.
- `pushInput` calls forward each keystroke byte into the wasm UART RX
  FIFO.

`web/ansi.js` is a ~150-line ANSI subset interpreter:

- Recognized: `ESC[2J` clear, `ESC[H` and `ESC[r;cH` cursor
  positioning, `ESC[?25l/h` cursor hide/show.
- C0 controls: `\b` (cursor left), `\n` (LF + CR — matches ONLCR
  cooked-tty behavior the host TTY would do for the CLI), `\r` (CR).
- UTF-8 lead bytes reassembled into a single screen cell.
- `_lineFeed()` scrolls the screen up by one line at the bottom row.

## Layer 2 — wasm: chunked emulator

`demo/web_main.zig` is the freestanding wasm entry. It exports a
chunked-step API instead of a blocking `run()`:

```
elfBufferPtr() / elfBufferCap()        # 2 MB receive buffer for the ELF
diskBufferPtr() / diskBufferCap()      # 4 MB receive buffer for shell-fs.img
runStart(elf_len, trace, disk_len) i32
runStep(max_instructions) i32          # -1 still running, ≥0 exit code
pushInput(byte)
outputPtr() / consumeOutput()
setMtimeNs(ns)                         # JS-driven wall clock
```

Each `runStart` reinitialises the emulator state from scratch
(`Block.init()` + a conditional `disk_slice = disk_buffer[0..disk_len]`
when the program needs a disk). All other emulator modules
(`cpu.zig`, `memory.zig`, `devices/*.zig`, `trap.zig`, `csr.zig`) are
the same code that powers the CLI — cross-compiled to
`wasm32-freestanding` via the `ccc` module shim at `src/emulator/lib.zig`.

Differences from the CLI driver:

| Concern | CLI | wasm |
|---|---|---|
| Disk backing | `disk_file: ?std.Io.File` (mmapped) | `disk_slice: ?[]u8` (in-wasm buffer) |
| RAM size | `--memory 128` (default 128 MB) | hardcoded 128 MB |
| Keystroke source | `--input` file → `rx_pump` paces bytes during `idleSpin` | JS `pushInput` → direct `Uart.pushRx` |
| `wfi` semantics | `idleSpin` blocks on host clock until next interrupt | `idleSpin` returns immediately (`step_mode = true`); JS Worker drives the next chunk |
| Output sink | host stdout via `std.fs.File.Writer` | fixed-size `output_buf` drained by `consumeOutput` |
| ONLCR | host TTY translates `\n`→`\r\n` | `web/ansi.js` does the equivalent in `_lineFeed` |

## Layer 3 — boot: M-mode shim → S-mode kernel

`kernel-fs.elf` boots in M-mode at `_M_start` (`src/kernel/boot.S`):

1. Set up a tiny stack at the top of physical RAM (just below
   trampoline/trap area).
2. Configure CLINT timer + delegation:
   - `medeleg` = all sync exceptions delegated to S-mode.
   - `mideleg` = STI/SEI/SSI delegated to S-mode.
   - `mie.MTIE` set; M-mode handles every MTI by forwarding to S-mode
     via `mip.SSIP` (timer ticks become software interrupts in S-mode).
3. `mret` to S-mode at `kmain` with paging off (`satp = 0`).

`kmain` (`src/kernel/kmain.zig`) S-mode bootstrap:

1. Initialize the **free-list page allocator**
   (`src/kernel/page_alloc.zig`): every 4 KB page from `kernel_end` to
   the trampoline area becomes a free-list node.
2. Build the **kernel page table**: identity-map RAM for kernel use,
   map the trampoline + trap page at `0x87FFF000` and `0x87FFE000`.
3. Initialize the **process table** (`NPROC=16` `Process` records,
   each with a kernel stack + saved `Context`).
4. Initialize the **inode cache** + **buffer cache**
   (`fs/inode.zig`, `fs/bufcache.zig`).
5. Allocate **PID 1** with a fresh address space, then call
   `proc.exec("/bin/init", null)` — the FS layer reads the on-disk
   `init_shell` ELF from `shell-fs.img`, the kernel ELF loader walks
   `PT_LOAD` segments and installs user PTEs, the entry point becomes
   PID 1's saved PC.
6. Switch to the round-robin **scheduler**
   (`src/kernel/sched.zig`) and `swtch` into PID 1.

The S-mode trap dispatcher (`src/kernel/trap.zig`) handles every
sync exception, syscall, and external interrupt thereafter.

## Layer 4 — filesystem: how `/bin/init` is loaded

The block device (`src/emulator/devices/block.zig`) is MMIO at
`0x1000_1000` with four registers (`SECTOR`, `BUFFER_PA`, `CMD`,
`STATUS`). On a `Read` CMD, `performTransfer` copies 4 KB from
`disk_slice` (wasm) or `disk_file` (CLI) into the requested RAM
offset, sets `STATUS=Ready`, and asserts PLIC src 1. The S-mode
trap dispatcher claims the IRQ, calls `block.isr` → wakes any sleeper
on `&req` → completes the deferred transfer.

Above that lives the FS stack:

- **`fs/bufcache.zig`** — `NBUF=16` LRU buffer cache. `bget` returns
  a locked buffer; if it's not present, `bread` issues a Read and
  sleeps until the IRQ wakes the caller.
- **`fs/balloc.zig`** — block bitmap (alloc/free).
- **`fs/inode.zig`** — `NINODE=32` in-memory inode cache + `bmap`
  (lazy-alloc on `for_write`) + `readi` / `writei` / `iupdate` /
  `ialloc` / `itrunc`.
- **`fs/dir.zig`** — `dirlookup`, `dirlink`, `dirunlink`.
- **`fs/path.zig`** — `namei` / `nameiparent` (root for absolute,
  `cur.cwd` for relative).
- **`fs/fsops.zig`** — `create` + `unlink` glue used by `sysOpenat`,
  `sysMkdirat`, `sysUnlinkat`.

So `proc.exec("/bin/init", null)` from `kmain` does:

```
namei("/bin/init")
  → dirlookup("bin") on root → inode 2
  → dirlookup("init") on inode 2 → inode N
readi(inode N, scratch_buf, 0, file_size)
  → calls bmap to walk direct + indirect blocks
  → calls bread which goes through bufcache
elfload.load(scratch_buf, &user_pt, &entry)
  → walks PT_LOAD segments
  → page_alloc.alloc per page
  → vm.mappages installs user PTEs
proc[0].pc = entry; proc[0].state = Runnable
```

PID 1 starts running at the entry point of `init_shell.elf`.

## Layer 5 — userspace: `init_shell` → `sh` → `ls`

`init_shell` (`src/kernel/user/init_shell.zig`) is the on-disk
`/bin/init` for shell-fs.img. It loops:

```
loop:
    pid = fork()
    if pid == 0: exec("/bin/sh", argv)
    wait4(pid, &status)
    if status == 0: exit(0)   # sh exited cleanly → halt
    # otherwise loop and re-spawn sh
```

`sh` (`src/kernel/user/sh.zig`) is the line-read shell:

```
print "$ "
read a line from fd 0     (cooked-mode console wakes us when \n commits)
tokenize on whitespace
handle redirects (<, >, >>) by replacing fd 0/1 in a child
handle builtins (cd / pwd / exit) inline
otherwise: fork → exec(argv[0], argv) → parent wait4
```

`ls` (`src/kernel/user/ls.zig`):

- `openat(0, path, O_RDONLY)` → kernel resolves via `namei`, returns
  an fd backed by an inode-typed `File` (`src/kernel/file.zig`).
- `fstat` → check if dir.
- For dir: `read` 16-byte `DirEntry` records in a loop.
- Print non-empty entries space-separated on one line, terminated by `\n`.

When `ls` exits, the shell's `wait4` returns; sh prints the next
prompt. The whole round-trip is dozens of context switches, several
disk reads (to load `/bin/ls` itself), and many trap entries —
all inside the wasm.

## Layer 6 — interactive features

**Cooked-mode console** (`src/kernel/console.zig`) is the line
discipline that backs fd 0/1/2:

- Each byte from `Uart.pushRx` reaches `console.feedByte` via the
  PLIC src 10 IRQ → `uart.isr` chain.
- Echo: every byte writes to UART (so the user sees what they type).
- Backspace (`0x08` or `0x7f`): erase last byte, emit `\b \b` to
  visually clear it.
- `^U` (`0x15`): kill the whole in-progress line.
- `^C` (`0x03`): erase line + emit `^C\n` + call `proc.kill(fg_pid)`
  (sets the `killed` flag; checked on every syscall return → process
  exits).
- `^D` (`0x04`): commit current line as EOF.
- `\n` or `\r`: commit the line + `proc.wakeup` the sleeper waiting
  on `&input.r` (the shell, blocked in `read`).

**Editor** (`src/kernel/user/edit.zig`) uses **raw mode**
(`console_set_mode(CONSOLE_RAW)`). Bytes arrive un-echoed, no line
discipline; the editor handles arrows (3-byte ESC sequences),
Backspace, `^S` (save), `^X` (exit). On exit it emits `ESC[2J ESC[H`
to clear the screen so the shell's next prompt lands on a fresh
terminal.

## Layer 7 — termination

The visitor closes the tab, or:

- `exit` shell builtin → `sysExit(0)` → reaper marks PID 2 zombie →
  `init_shell`'s `wait4` returns 0 → `init_shell` itself calls
  `sysExit(0)` → all userspace gone → kernel idle.
- The wasm doesn't actually halt at this point; the kernel just
  spins in `wfi` forever (in wasm `idleSpin` is a single-step nop).
  The visitor refreshes or picks a different program; `runStart`
  tears down state and rebuilds.

There's no `tohost` halt path during normal operation — that's the
opposite of how snake exits. The shell is designed to run
indefinitely.

## File map

| File                                              | Role |
|---------------------------------------------------|------|
| `web/index.html`                                  | `<select>` dropdown + shell-instructions card |
| `web/demo.js`                                     | Main thread: per-program key map, ANSI render, cursor overlay, `waiting…` placeholder |
| `web/runner.js`                                   | Web Worker: parallel ELF + disk fetch, copy into wasm, drive `runStep` |
| `web/ansi.js`                                     | 80×24 ANSI grid: clear, cursor positioning, `\b`, `\n` (with ONLCR), scroll on bottom |
| `web/demo.css`                                    | Terminal styling + blinking cursor `@keyframes` |
| `demo/web_main.zig`                               | Wasm entry: 2 MB elf_buffer + 4 MB disk_buffer + `runStart`/`runStep` exports |
| `src/emulator/lib.zig`                            | Module shim re-exporting cpu/memory/elf/devices for the wasm build |
| `src/emulator/devices/block.zig`                  | Block device MMIO; `disk_slice` (wasm) and `disk_file` (CLI) backings |
| `src/emulator/devices/uart.zig`                   | NS16550A UART; `pushRx` raises PLIC src 10 when the FIFO transitions empty→non-empty |
| `src/emulator/devices/plic.zig`                   | PLIC: 32 sources × 1 S-mode context, `claim`/`complete` |
| `src/kernel/boot.S`                               | M-mode boot shim: delegation, CLINT, mret to S-mode |
| `src/kernel/kmain.zig`                            | S-mode bootstrap: page allocator, ptable, FS init, exec /bin/init |
| `src/kernel/sched.zig`                            | Round-robin scheduler + `swtch` |
| `src/kernel/proc.zig`                             | Process struct, `fork` / `exec` / `wait4` / `exit` / `kill` |
| `src/kernel/syscall.zig`                          | Syscall dispatch (write/read/openat/close/lseek/fstat/chdir/getcwd/mkdirat/unlinkat/console_set_mode/...) |
| `src/kernel/trap.zig`                             | S-mode trap dispatcher; PLIC claim + `block.isr` + `uart.isr` branch |
| `src/kernel/console.zig`                          | Cooked-mode line discipline + Raw mode arm; backs fd 0/1/2 |
| `src/kernel/uart.zig`                             | Kernel-side UART driver (ISR drains FIFO into console) |
| `src/kernel/plic.zig`                             | Kernel-side PLIC driver (setPriority/enable/setThreshold/claim/complete) |
| `src/kernel/block.zig`                            | Single-outstanding block driver (submit + sleep on `&req`; ISR wakes) |
| `src/kernel/file.zig`                             | `NFILE=64` file table; inode-typed and console-typed entries |
| `src/kernel/fs/{layout,bufcache,balloc,inode,dir,path,fsops}.zig` | Filesystem stack |
| `src/kernel/elfload.zig`                          | In-kernel ELF32 loader; walks `PT_LOAD`, installs user PTEs via callback |
| `src/kernel/vm.zig`                               | Sv32 page table + `copyUvm` / `unmapUser` |
| `src/kernel/user/init_shell.zig`                  | On-disk `/bin/init`: loops fork-exec-sh-wait |
| `src/kernel/user/sh.zig`                          | Shell: line read, tokenize, redirect, fork+exec |
| `src/kernel/user/ls.zig`                          | `ls` utility (space-separated single-line listing) |
| `src/kernel/user/{cat,echo,mkdir,rm,edit}.zig`    | Other on-disk userland binaries |
| `src/kernel/user/lib/{start.S,usys.S,ulib.zig,uprintf.zig}` | User stdlib: `_start`, syscall stubs, mem/str helpers, printf |
| `src/kernel/mkfs.zig`                             | Host tool: walks `--root` + `--bin` directory trees → 4 MB image |

## Build steps that produce these artifacts

| Step                  | Output |
|-----------------------|--------|
| `zig build kernel-fs` | `zig-out/bin/kernel-fs.elf` (FS-mode kernel) |
| `zig build shell-fs-img` | `zig-out/shell-fs.img` (4 MB image with `/bin/*` + `/etc/motd`) |
| `zig build wasm`      | `zig-out/web/{ccc.wasm, kernel-fs.elf, shell-fs.img, hello.elf, snake.elf}` |
| `./scripts/stage-web.sh` | Copies all five into `web/` for local serving |

## Why this layering matters

Each layer enforces a clean interface:

- The **wasm** never knows it's in a browser — it's the same code as
  the CLI, with the slice-backed disk and chunked-step API the only
  concessions.
- The **kernel** never knows it's in wasm — it sees a normal RV32
  hart with PLIC, CLINT, UART, and a block device. The CLI runs the
  exact same kernel against an mmapped disk file.
- The **shell** never knows about either — it's a vanilla
  fork+exec+wait Unix-style shell talking to fds 0/1/2.

That layering is the whole point of the project: building from
scratch means owning each abstraction, but a clean interface at each
boundary lets the same kernel run on the CLI, in your browser, or
anywhere else a wasm host can sit.

## Compare with snake

| Concern               | snake.elf                          | shell.elf (kernel-fs.elf + shell-fs.img) |
|-----------------------|-------------------------------------|------------------------------------------|
| Privilege levels       | M-mode only                         | M boot shim → S kernel → U processes      |
| Paging                 | Off                                 | Sv32 (4 KB pages)                        |
| Filesystem             | None                                | mkfs-laid 4 MB image, bufcache + inode    |
| Multiprocess           | Single hart, one program            | NPROC=16 ptable, fork/exec/wait/exit      |
| Input path             | UART RX polled in timer ISR         | UART RX → PLIC → S-trap → cooked console  |
| Output path            | Direct UART writes from M-mode      | `write` syscall → kernel → UART           |
| Termination            | `tohost = 1` writes halt MMIO      | Lives forever; refresh page to reset      |
| Disk in wasm           | None                                | 4 MB `disk_buffer` overwritten per run    |
| Browser-side controls  | WASD/Space/Q (6 keys)               | Full ASCII + Ctrl + arrows (raw + cooked) |
| Memory                 | 16 KB stack inside guest RAM        | 128 MB guest RAM, kernel + N user spaces  |

Snake is the smallest interactive RV32 program ccc can run; the
shell is the biggest. Both use the same `cpu.zig` / `memory.zig` /
`devices/*.zig` core.
