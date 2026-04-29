# Phase 6 — Port CPython 3.12 (Design)

**Project:** From-Scratch Computer (directory `ccc/`).
**Phase:** 6 — see `2026-04-23-from-scratch-computer-roadmap.md` (this spec
extends that roadmap; the original document lists five phases plus the
Phase 7 graphics addendum, and this is a second post-roadmap addition —
see the §Why section below).
**Status:** Draft 2026-04-29 — open for review. Depends on Phase 3.F
completion (filesystem, shell, line-discipline console, kill-flag).
Independent of Phase 4 / 5 / 7 — can land before, after, or in parallel.

## Goal

Port real CPython 3.12 to ccc as the userland binary `/bin/python`. The
interpreter runs entirely on Phase 1–3 primitives — RV32IMA, the existing
S-mode kernel, the existing on-disk filesystem, the existing line-discipline
console, the existing 19-syscall surface plus a small set of additions.
A curated frozen stdlib (~30 modules) is baked into the binary; no C
extensions outside the CPython core; no networking, no `mmap`, no
threading. Soft-float math via compiler-rt; heap via dlmalloc on top of
Phase 3's `sbrk`; libc via picolibc with a small ccc-specific shim.

After Phase 6, ccc's shell (`/bin/sh`) can launch Python programs the
same way it launches `cat` and `ls`, scripts in `/usr/lib/demo/` exercise
the full path from REPL bytes through `ecall` into the kernel and back,
and `^C` raises `KeyboardInterrupt` cleanly without killing the
interpreter.

## Why

**The original roadmap stops at Phase 5** (HTTP/1.0 client + text
browser). Phase 7 added an optional graphics addendum reversing the "no
graphics" non-goal. Phase 6 is the project's first **port** rather than
its eighth from-scratch build. Three reasons it earns the slot:

1. **The kernel is honestly tested by foreign code.** Phases 1–6 are
   self-consistent — every syscall, every page-table flip, every block
   read was specified by us *for* the programs we also wrote. CPython
   was written without any knowledge of ccc; getting it to run exercises
   the kernel against ~600 KLoC of code that doesn't share our
   assumptions. A bug that survived all of Phase 3's e2e tests will
   often surface within an hour of hitting CPython's startup path.
2. **It opens userland to non-Zig contributors.** Today, adding a new
   ccc demo means a Zig recompile cycle. After Phase 6, a 30-line
   `.py` file in `/usr/lib/demo/` is a runnable program. The deck and
   the learning companion gain a "write your own ccc program in
   Python" section that's accessible to readers who don't know Zig.
3. **It's a famous milestone.** Linux 0.01 booted bash; SerenityOS
   ran Python within a year; ToaruOS makes a deal of "yes, that's
   a real CPython REPL." Reaching this milestone on top of a
   from-scratch RV32 emulator is a strong narrative beat — and one
   the wasm web demo can show off in a browser the moment the binary
   is small enough.

**Cost honesty.** Phase 6 is the first phase whose code volume comes
mostly from outside the repo. The CPython submodule is ~600 KLoC;
picolibc is ~50 KLoC; dlmalloc is ~3 KLoC. New code we author is
~5–8 KLoC (`build.zig` glue, libc shim, signal model, demos, e2e
harness). The narrative shifts from "every byte by hand" to "every
byte either by hand or in a pinned, audited submodule with explicit
shim layer." That's a deliberate trade and should be acknowledged in
the README + roadmap when this spec is approved.

## Definition of done

- `zig build python` produces `python.elf` (the cross-compiled CPython
  binary, ~10–15 MB stripped). `zig build fs-img-py` bakes an `fs.img`
  containing `/bin/python`, `/usr/lib/demo/{pi,life,wc,exc,json_demo}.py`,
  plus the existing Phase 3 `/bin/{sh,ls,cat,echo,mkdir,rm,edit,init}`.
- `ccc --disk fs.img --memory 256 kernel-fs.elf` boots, reaches `$ `,
  and the eight-line scripted demo passes interactively:
  1. `python -c "print('hello, ccc')"` → prints `hello, ccc`, exits 0.
  2. `python` → REPL: `>>> 2 ** 200` (prints
     `1606938044258990275541962092341162602522202993782792835301376`)
     → `>>> import sys; print(sys.version)` (prints
     `3.12.X (ccc/0.7) [Zig 0.16.x]`) → `>>> exit()` → back to `$ `.
  3. `python /usr/lib/demo/pi.py 50` → 50 digits of π via the pure-Python
     `_pydecimal` implementation: `3.1415926535897932384626433832795028841971693993751`.
  4. `python /usr/lib/demo/life.py 8` → 8 generations of Conway's Game
     of Life on a 40×16 ASCII grid printed back-to-back.
  5. `python /usr/lib/demo/wc.py /etc/motd` → byte/word/line counts of
     the file (` 19  4  1 /etc/motd`).
  6. `python /usr/lib/demo/exc.py` (a 4-line file: `try:` / `  1/0` /
     `except ZeroDivisionError:` / `  print('ok')`) → prints `ok`. (We
     run from a file rather than from a multi-line `-c`, since Phase
     3.E's shell tokenizer doesn't handle embedded newlines in
     double-quoted strings.)
  7. `python /usr/lib/demo/json_demo.py` → encodes `{"ccc": [1, 2, 3]}`,
     pretty-prints it, decodes the result back, and asserts equality.
  8. `python` → REPL → `>>> while True: pass` → `^C` → `KeyboardInterrupt`
     traceback, prompt returns. (`^C` at the idle prompt exits the binary
     — same shape as `sh` — proving the kill-flag → EINTR → CPython
     interrupt path lands.)
- All Phase 1 e2e tests (`e2e`, `e2e-mul`, `e2e-trap`, `e2e-hello-elf`),
  Phase 2 (`e2e-kernel`), and Phase 3 (`e2e-multiproc-stub`, `e2e-fork`,
  `e2e-fs`, `e2e-shell`, `e2e-editor`, `e2e-persist`, `e2e-cancel`) still
  pass. **The kernel changes in 6.F (signal mode opt-in) are additive —
  Phase 3.F's `e2e-cancel` continues to assert the default exit-on-^C
  behavior unchanged.**
- New e2e tests pass: `e2e-c-hello` (6.A), `e2e-c-alloc` (6.B),
  `e2e-py-eval` (6.C), `e2e-py-repl` (6.D), `e2e-py-stdlib-smoke` (6.D),
  `e2e-py-pi` (6.E), `e2e-py-life` (6.E), `e2e-py-wc` (6.E),
  `e2e-py-json` (6.E), `e2e-py-exception` (6.E), `e2e-py-interrupt` (6.F),
  `e2e-py-demo` (6.G — the full eight-line scripted session above).
- `riscv-tests` (rv32{ui,um,ua,mi,si} all `-p-*`) still pass.
- `--trace` works across the new picolibc syscall surface; the new
  `--trace-py-opcodes` flag (6.G) emits one line per CPython bytecode
  dispatched (off by default; would flood otherwise).
- `mkfs` image size lifts from 4 MB to **64 MB** (knob, not hard-coded);
  Phase 3's `e2e-fs` regression continues to work against a 4 MB image
  and a 64 MB image.

## Scope

### In scope

- **Submodules and external code (pinned, audited):**
  - `third_party/cpython/` — CPython 3.12.x (exact patch pinned at plan
    start; expected 3.12.4 or later). Vendored as a git submodule; we
    don't fork the upstream tree, only patch it via a directory of
    `*.patch` files applied at build time (≤30 small patches expected).
  - `third_party/picolibc/` — picolibc release tag pinned at plan start
    (expected 1.8.x). Same submodule + patch shape.
  - `third_party/dlmalloc/` — dlmalloc 2.8.6 (single C file, ~6000
    lines, public domain). Vendored verbatim.
- **New userland code (`src/userland/`):**
  - `libc-shim/syscall.c` (~400 LoC). Maps picolibc's syscall hooks
    (`_read`, `_write`, `_open`, `_close`, `_lseek`, `_fstat`,
    `_stat`, `_isatty`, `_sbrk`, `_kill`, `_getpid`, `_exit`, `_link`,
    `_unlink`, `_times`, `_gettimeofday`) to ccc's `ecall` stubs.
    Stubs that ccc doesn't support return `-ENOSYS`.
  - `libc-shim/errno.c` (~30 LoC). A single `int errno;` global plus
    a `__errno_location()` accessor — picolibc and CPython both go
    through this.
  - `libc-shim/environ.c` (~10 LoC). An empty `char *environ[] = { 0 };`.
    CPython's `os.environ` will be empty; we don't model env vars in
    Phase 6.
  - `libc-shim/heap.c` (~50 LoC). Zero-init the dlmalloc footprint
    state; expose `malloc`/`free`/`realloc`/`calloc` symbols that
    forward to dlmalloc's `dlmalloc`/`dlfree`/etc.
  - `libc-shim/stubs.c` (~150 LoC). Catch-all for symbols CPython
    references that we deliberately stub: `mmap`/`munmap`,
    `pthread_*`, `fork`/`execve` aliases for `os.spawn*` paths,
    `select`, `poll`, `dlopen`/`dlsym`/`dlclose`. All return
    `-ENOSYS` or sensible neutral values.
  - `libc-shim/signal.c` (~80 LoC). The `<signal.h>` API surface
    CPython needs: `signal(SIGINT, handler)` opts the proc into
    EINTR-on-^C mode (via the new kernel syscall — see "Signal &
    ^C" under Architecture). Other signals are stubbed to no-op.
- **CPython build glue (`build.zig` additions, ~600 LoC):**
  - File enumeration of `Python/`, `Objects/`, `Parser/`, and the
    selected `Modules/` subset.
  - Hand-authored `pyconfig.h` committed to `src/userland/cpython-port/`
    (modeled on Pyodide's `pyconfig.h.wasm32-emscripten` with all
    `HAVE_*` macros for unsupported features explicitly set to 0).
  - `freeze_modules.py` invocation as a build-graph step (host-side
    Python 3 required at build time; macOS ships it; CI installs it).
  - Generated artifact paths: `zig-out/python-frozen/_freeze_module_*.c`
    fed back into the `addCSourceFiles` call.
- **`mkfs` updates:**
  - `--image-size MB` flag (default 4 MB for Phase 3; tests pass 64
    MB for `fs-img-py`).
  - Bump `NBLOCKS` and `NINODES` derivation: both become functions of
    `--image-size` rather than constants. The bump table:
    `NBLOCKS = image_bytes / BLOCK_SIZE`,
    `NINODES = NBLOCKS / 16` (one inode per ~64 KB).
- **Demo programs (`programs/python-demo/`):**
  - `pi.py` (~40 LoC). N-digit π via Machin-shape series in
    `_pydecimal`. CLI arg = digit count; default 50.
  - `life.py` (~80 LoC). Conway's Game of Life class: `Grid(w, h)`,
    `step()`, `__str__` rendering with `█`/`·`. CLI arg = generations;
    default 8.
  - `wc.py` (~30 LoC). `argv[1]` → file path. Streams 4 KB at a time;
    counts newlines, whitespace-runs, and bytes; prints them
    POSIX-style.
  - `json_demo.py` (~25 LoC). Builds a nested dict, encodes via
    `json.dumps(indent=2)`, decodes via `json.loads`, asserts
    round-trip equality, prints the pretty-printed encoding.
  - `exc.py` (4 LoC). `try: 1/0` / `except ZeroDivisionError:
    print('ok')`. Exists because Phase 3.E `sh`'s tokenizer can't
    pass embedded newlines through a `-c` argument; running from a
    file is the simplest path.
- **Kernel additions (minimal):**
  - **One new syscall: `sigaction_int_mode(mode: u32) -> i32` (#220).**
    `mode = 0` → kill-flag delivers `proc.exit` (Phase 3 default,
    unchanged). `mode = 1` → kill-flag delivers EINTR on next
    syscall return; `proc.killed` is auto-cleared after delivery.
    Per-process state in `Process` struct: `sig_int_mode: u8`
    (default 0). ~30 LoC kernel side. **No other kernel changes.**
  - `e2e-cancel` (Phase 3.F's regression test) is unaffected — it
    runs `cat`, which never opts into mode 1; default behavior
    preserved.
- **e2e harness (`tests/e2e/`):**
  - `c_hello.zig`, `c_alloc.zig` — sanity for picolibc + dlmalloc,
    no Python yet.
  - `py_eval.zig`, `py_repl.zig`, `py_stdlib_smoke.zig`, `py_pi.zig`,
    `py_life.zig`, `py_wc.zig`, `py_json.zig`, `py_exception.zig`,
    `py_interrupt.zig`, `py_demo.zig` — Python-focused tests.
  - All run `ccc --disk fs.img --input <fixture> kernel-fs.elf` and
    assert against stdout + (for the interrupt test) the test peer's
    fixture-driven input timing.

### Out of scope (deferred to a follow-up plan or phase)

- **`socket` / `select` / `_socket` / `_ssl`.** All require Phase 4's
  socket layer. Imported as `ImportError`. A Phase 6.5 plan can wire
  them up after Phase 4 lands.
- **`mmap` module / `os.mmap`.** Requires Phase 7's `mmap` syscall.
  Same shape — Phase 6.5 plan after Phase 7.
- **`threading` / `_thread` / `multiprocessing` / `concurrent.futures` /
  `asyncio`.** Single hart, no pthread; CPython's GIL machinery is
  stubbed. `import threading` raises `ImportError`. Adding threads is
  a Phase 8-class undertaking, not a polish item.
- **C extensions outside the CPython core.** No `_sqlite3`, no
  `_ctypes`, no `cython`-generated wheels, no `pip`. CPython core's
  built-in C modules (`_collections`, `_io`, `_sre`, `_random`,
  `_sha2`, etc.) are in scope; everything else is out.
- **`_decimal` (C-accelerated decimal).** We use `_pydecimal` (the
  pure-Python fallback) instead. ~10× slower but no `libmpdec`
  dependency. A 6.5 plan can pull in `libmpdec` if perf matters.
- **GNU readline / `libedit`.** No arrow-key history, no Tab completion.
  CPython's plain `input()` REPL: backspace works (via Phase 3 cooked
  mode), arrow keys produce literal escape bytes that show up at the
  prompt. A 6.5 plan adds a small in-process line editor mapped to
  CPython's `PyOS_Readline` hook.
- **Web (wasm) integration.** A 10–15 MB ELF + the existing RV32
  emulator + wasm overhead = ~100 MB of in-browser memory and
  multi-second cold start. A 6.8 polish plan revisits once we know
  whether the binary can shrink to ~6 MB with `-Oz` + LTO + module
  curation.
- **`os.spawn*` / `subprocess`.** Phase 3 has `fork`/`execve`/`wait4`,
  but `subprocess.Popen` references file descriptors via `pipe(2)`
  (deferred to Phase 4). Stubbed; raises `OSError` with
  `errno=ENOSYS`. A 6.5 plan adds `pipe` standalone if the perf cost
  of doing so before Phase 4 is justified.
- **Full unicode normalization tables.** CPython embeds the full
  Unicode database (`unicodedata.c`'s ~1.5 MB of tables). We include
  it but mark `unicodedata.normalize` as a perf hot path; soft-float
  doesn't impact it but binary size does. A 6.G binary-size pass
  evaluates whether to ship a reduced table.
- **`pip` and any package install path.** No package manager.
  `/usr/lib/demo/` is curated; new modules ship through ccc's `mkfs`
  pipeline.
- **`argparse`.** Removed from frozen stdlib (~3000 LoC, every demo
  uses `sys.argv` directly anyway). `getopt` (much smaller) stays.
- **`unittest` / `pytest`.** Test runner support is a Phase 6.5
  polish item; for now, demo programs `assert` and exit non-zero
  on failure.

### Out of scope (never)

- Linux ABI / syscall compatibility layer. We map CPython to ccc
  syscalls, not the other way around.
- TLS / SSL / DNSSEC.
- Loadable kernel modules / dynamic linking. Static-only ELFs forever.
- Embedded scripting languages other than CPython (Lua, MicroPython,
  Ruby). One language is enough.
- Kernel-side `epoll` / `kqueue`.
- `os.exec*` family (the Linux `execve` variants); we have ccc's
  single `execve` and that's it.
- DRM / Wayland / X11 protocol bridging (Phase 7 territory at most).

## Architecture

### Layered overview

```
┌──────────────────────────────────────────────────────────────┐
│ /bin/python (single static ELF, ~10–15 MB)                   │
│                                                              │
│   CPython 3.12 core                                          │
│   ├── Python/      (interpreter, ceval, initconfig, errors) │
│   ├── Objects/     (object types: int, str, list, dict, …) │
│   ├── Parser/      (tokenizer + grammar)                     │
│   ├── Modules/     (curated subset — see "Frozen stdlib")    │
│   └── frozen .py   (stdlib marshalled into _frozen.h)        │
│                          │                                   │
│   pymalloc                                                   │
│   ├── arena allocator on top of …                            │
│   dlmalloc 2.8.6                                             │
│   ├── chunked allocator on top of …                          │
│   picolibc (libc.a)                                          │
│   ├── printf, qsort, strtod, math, locale stubs              │
│   ├── stdio buffering on top of low-level I/O                │
│   └── _read/_write/_open/… hooks                             │
│                          │                                   │
│   libc-shim (src/userland/libc-shim/)                       │
│   ├── syscall.c    picolibc hooks → ccc ecall stubs          │
│   ├── errno.c      single global errno                       │
│   ├── environ.c    empty environ[]                           │
│   ├── heap.c       dlmalloc init                             │
│   ├── stubs.c      mmap, pthread, dlopen → -ENOSYS          │
│   └── signal.c     SIGINT → kernel sig_int_mode opt-in       │
│                          │                                   │
│   compiler-rt-builtins (Zig-supplied)                        │
│   └── __divdf3, __addsf3, __floatsidf, …                     │
│                          │                                   │
│   ulib + usys.S (existing Phase 3 user runtime)              │
│   └── _start, ecall stubs (write/read/open/exec/fork/…)      │
└──────────────────────┬───────────────────────────────────────┘
                       │ ecall (a7=syscall, a0..a5=args)
┌──────────────────────▼───────────────────────────────────────┐
│ S-mode kernel (Phase 3, with one additive syscall)           │
│                                                              │
│   syscall dispatch                                           │
│   ├── existing 19 syscalls (write, read, open, fork, …)      │
│   └── #220 sigaction_int_mode  ← NEW in 6.F                  │
│                                                              │
│   killed-flag check on syscall return:                       │
│   if (proc.killed) {                                         │
│     if (proc.sig_int_mode == 0) proc.exit(-1);  ← Phase 3    │
│     else { proc.killed = 0; return -EINTR; }    ← NEW        │
│   }                                                          │
└──────────────────────────────────────────────────────────────┘
```

The kernel changes are surgical: one new syscall, one branch on the
existing kill-flag check. Everything else lives in userland: picolibc
provides libc, dlmalloc provides `malloc`, the libc-shim translates,
and CPython is the consumer.

### libc shim

picolibc expects each port to provide a small set of "syscall hooks"
named `_read`, `_write`, `_open`, etc. These are functions of the form:

```c
int _write(int fd, const void *buf, size_t n) {
    long ret = ecall_write(fd, buf, n);  // SYS_WRITE = 64
    if (ret < 0) { errno = (int)-ret; return -1; }
    return (int)ret;
}
```

The full hook set with their ccc syscall mappings:

| picolibc hook | ccc syscall | Notes |
|---|---|---|
| `_read(fd, buf, n)` | `SYS_READ=63` | Direct map. EINTR surfaces from kill-flag mode 1. |
| `_write(fd, buf, n)` | `SYS_WRITE=64` | Direct map. Stdout/stderr go through Phase 3's `console.zig`. |
| `_open(path, flags, mode)` | `SYS_OPENAT=56` w/ `AT_FDCWD` | Translated. `O_*` constants identical. |
| `_close(fd)` | `SYS_CLOSE=57` | Direct map. |
| `_lseek(fd, off, whence)` | `SYS_LSEEK=62` | Direct map. |
| `_fstat(fd, st)` | `SYS_FSTAT=80` | Direct map. CPython needs `st_mode`, `st_size`, `st_mtime` — all in Phase 3.D's `Stat`. |
| `_stat(path, st)` | open + fstat + close | Phase 3 doesn't have a path-based stat; emulated in shim. |
| `_isatty(fd)` | `SYS_FSTAT=80` + check device-type | We add an `S_IFCHR` bit to Phase 3's `Stat` struct. Console fds report it; regular files don't. |
| `_sbrk(incr)` | `SYS_SBRK=214` | Direct map. dlmalloc's only growth hook. |
| `_getpid()` | `SYS_GETPID=172` | Direct map. |
| `_kill(pid, sig)` | stub | Phase 3 doesn't expose `kill(pid, sig)` to userland and Phase 6 doesn't need it: CPython only ever calls `kill(getpid(), SIGINT)` to self-interrupt, which is replaced wholesale by the sig_int_mode opt-in path (see "Signal & ^C model" below). Shim returns `-EPERM` for any non-self `pid`; for `pid == _getpid()` and `sig == SIGINT`, calls the registered SIGINT handler synchronously and returns 0. |
| `_exit(status)` | `SYS_EXIT=93` | Direct map. |
| `_link(old, new)` | stub `-ENOSYS` | Phase 3.E has `unlinkat` but not `linkat`. CPython rarely calls this. |
| `_unlink(path)` | `SYS_UNLINKAT=35` w/ `AT_FDCWD` | Direct map. |
| `_times(tms)` | derived from `mtime` MMIO read | Phase 3 exposes `mtime` via the existing CSR path; shim reads it and returns user/sys time approximations. |
| `_gettimeofday(tv, tz)` | derived from `mtime` | Same. tz ignored. |

CPython references additional functions picolibc-or-shim has to provide.
A first-pass list (chased by the link errors during 6.C bring-up):
`abort`, `assert`, `atexit`, `atoi`, `atol`, `bsearch`, `calloc`,
`ctype.h` family (`isalpha`, `isdigit`, …), `dirfd`, `dirname`, `dup`,
`exit`, `fchmod`, `fclose`, `fdopen`, `feof`, `ferror`, `fflush`,
`fgetc`, `fgets`, `fileno`, `fopen`, `fprintf`, `fputs`, `fread`,
`free`, `fseek`, `ftell`, `fwrite`, `getc`, `getcwd`, `getenv`,
`getgid`, `getgrgid`, `getpid`, `getpwuid`, `getuid`, `gmtime`,
`isatty`, `localtime`, `localtime_r`, `lstat`, `malloc`, `mblen`,
`memchr`, `memcmp`, `memcpy`, `memmove`, `memset`, `mkdir`, `mktime`,
`opendir`, `printf`, `putc`, `putenv`, `puts`, `qsort`, `rand`,
`readdir`, `realloc`, `realpath`, `rename`, `rmdir`, `setbuf`,
`setenv`, `setlocale`, `setvbuf`, `snprintf`, `srand`, `sscanf`,
`stat`, `strcasecmp`, `strchr`, `strcmp`, `strcpy`, `strcspn`,
`strdup`, `strerror`, `strerror_r`, `strftime`, `strlen`, `strncasecmp`,
`strncmp`, `strncpy`, `strpbrk`, `strrchr`, `strstr`, `strtod`,
`strtol`, `strtoll`, `strtoul`, `strtoull`, `system`, `time`, `tmpfile`,
`tzset`, `unsetenv`, `vfprintf`, `vsnprintf`, `wcrtomb`, `wcscmp`,
`wcscpy`, `wcsftime`, `wcslen`, `wcsncmp`, `write`, `writev`. picolibc
covers ~95% of these out of the box; the rest get stubbed in
`libc-shim/stubs.c` to either return a sensible neutral value
(e.g. `getuid()` → 0, `getgid()` → 0, `tmpfile()` → NULL) or set
errno=ENOSYS.

`dirent.h` (`opendir`/`readdir`) deserves special mention: Phase 3's
filesystem returns directory entries via repeated `read()` calls on the
directory fd (each read returns a single `DirEntry` record). picolibc's
`opendir` doesn't know that — we provide a custom `dirent.c` in the shim
that wraps fd reads.

### dlmalloc layer

dlmalloc 2.8.6 (Doug Lea's malloc, public domain, ~6 KLoC of C, single
`malloc.c` file) is the heap allocator. It's been the FreeBSD default
malloc, the Android default malloc, and a hundred other projects' default
because it's small, well-tested, and configurable.

We compile it with:

```
-DUSE_DL_PREFIX=0          # export plain malloc/free/realloc, not dlmalloc/dlfree
-DHAVE_MMAP=0              # we don't have mmap; sbrk-only growth
-DHAVE_MORECORE=1
-DMORECORE=ccc_sbrk        # sbrk wrapper that calls our SYS_SBRK
-DMORECORE_CONTIGUOUS=1    # ccc's sbrk is contiguous
-DUSE_LOCKS=0              # single-threaded
-DDEBUG=0
-DLACKS_UNISTD_H=1         # we don't have a real unistd.h
-DLACKS_SYS_PARAM_H=1
-DLACKS_TIME_H=1
```

`pymalloc` (CPython's small-object allocator) sits on top: it requests
256 KB arenas from `malloc()` and slices them into per-size-class pools.
This is CPython's default and we don't change it.

Heap initialization: `_start` (Phase 3's `start.S`) calls `__libc_init`
which calls `dlmalloc_init` which is a no-op (dlmalloc lazily
initializes on first `malloc`).

### Soft floating-point

RV32IMA has no F or D extensions. CPython's `float` is a C `double`;
Python bytecode `BINARY_ADD` on two floats compiles to `__adddf3`.
Zig's `riscv32-freestanding` target ships `compiler-rt-builtins` which
provides:

```
__adddf3, __addsf3, __divdf3, __divsf3, __muldf3, __mulsf3, __subdf3,
__subsf3, __floatsidf, __fixdfsi, __fixunsdfsi, __extendsfdf2,
__truncdfsf2, __cmpdf2, __ledf2, __gedf2, __ltdf2, __gtdf2, __nedf2,
__eqdf2, __unorddf2, …
```

We don't write soft-float code. We just link compiler-rt and let the
codegen call out as needed.

Performance impact: ~50× slower per double op vs. hardware FP, which
puts a `math.sin(1.0)` call at ~5 µs on our model rate vs. 100 ns
native. Acceptable for the demo (worst case `pi.py 50` finishes in
<200 ms; `life.py` is integer-only).

### CPython compilation

We do **not** invoke autoconf at build time. Instead:

1. **`pyconfig.h` is committed.** Hand-authored, located at
   `src/userland/cpython-port/pyconfig.h` (~400 lines). Modeled on
   Pyodide's `pyconfig.h.wasm32-emscripten` with `HAVE_*` macros set
   to reflect ccc's actual capabilities. Highlights:
   - `HAVE_FORK 1`, `HAVE_EXECV 1`, `HAVE_WAITPID 1` (we have these).
   - `HAVE_PTHREAD_H 0`, `HAVE_THREAD 0`, `WITH_THREAD 0`.
   - `HAVE_MMAP 0`, `HAVE_SOCKET 0`, `HAVE_SELECT 0`, `HAVE_POLL 0`.
   - `HAVE_SIGACTION 1` (via the new sig_int_mode syscall + shim).
   - `HAVE_LIBREADLINE 0`, `HAVE_LIBEDIT 0`.
   - `Py_UNICODE_SIZE 4`, `WCHAR_T_SIZE 4`.
   - `HAVE_FLOAT_H 1`, `HAVE_MATH_H 1` (picolibc provides).
2. **`build.zig` enumerates sources directly.** No `Makefile`, no
   autoconf-generated `config.status`. The new `python.zig` build
   step adds:
   ```zig
   const py = b.addExecutable(.{
       .name = "python",
       .target = riscv32_target,
       .optimize = .ReleaseSafe,
   });
   py.addCSourceFiles(.{
       .files = cpython_core_files,        // ~140 files
       .flags = py_compile_flags,
   });
   py.addIncludePath(b.path("src/userland/cpython-port"));
   py.addIncludePath(b.path("third_party/cpython/Include"));
   py.addIncludePath(b.path("third_party/cpython/Include/internal"));
   py.linkLibrary(picolibc_lib);
   py.linkLibrary(dlmalloc_lib);
   py.linkLibrary(libc_shim_lib);
   py.linkLibrary(libulib);  // existing Phase 3 user lib
   ```
   `cpython_core_files` is hand-curated. We don't `glob` because we
   want to know exactly what's compiled. Adding a module is a build
   change, not an opaque pickup.
3. **Patches are applied at build time.** A `third_party/cpython-patches/`
   directory holds `*.patch` files (each tagged with reason: `signal`,
   `time`, `freeze`, `compat`). The build runs `git apply` against the
   submodule before compiling. Patches are reviewed individually; we
   keep them minimal and prefer `#ifdef __ccc__` guards over
   destructive edits.

`pyconfig.h` lives outside `third_party/cpython/` so we never patch
upstream. CPython looks for `pyconfig.h` on the include path; ours
wins because we put it first.

### Frozen stdlib

CPython 3.12 ships `Tools/build/freeze_modules.py`, a host-side Python
script that:
1. Reads each `.py` file from `Lib/`.
2. Compiles it to a `code` object via `compile()`.
3. Marshals the code object into bytes (`marshal.dumps`).
4. Emits a generated `.c` file with the bytes as a `static const char[]`.
5. Adds an entry to `Modules/_frozen.c`'s frozen-modules array.

We invoke this as a build step that runs on the host (macOS Python 3,
or any Python 3.12+). Output goes to `zig-out/python-frozen/` and is
fed back into `addCSourceFiles`.

The curated list (~30 modules, total ~600 KB of .py source frozen as
~300 KB of marshalled bytecode after compression):

| Module | Why included |
|---|---|
| `sys`, `_sys` | Required core. |
| `os`, `os.path`, `posixpath` | File I/O dispatch. |
| `io`, `_io` | All Python file objects layer on this. |
| `errno` | Symbolic errno names. |
| `re`, `_sre`, `sre_compile`, `sre_parse` | Regex. CPU-bound; pure Python overhead acceptable. |
| `json`, `json.decoder`, `json.encoder` | Demo program 7. |
| `collections`, `collections.abc`, `_collections` | `OrderedDict`, `Counter`, `deque` etc. |
| `math` | Soft-float-backed via picolibc. |
| `random` | Demo programs use it. |
| `itertools`, `_itertools` | Iterator helpers. |
| `functools`, `_functools` | `lru_cache`, `partial`. |
| `operator`, `_operator` | Inline operator wrappers — fast path for many idioms. |
| `string` | `Template`, `ascii_letters`. |
| `decimal`, `_pydecimal` | Demo program 3 (pi.py). |
| `time` | Soft-clock via `mtime`. |
| `pathlib` | Demo programs walk FS via this. |
| `traceback` | Exception printing in REPL. |
| `warnings` | `DeprecationWarning` etc. |
| `contextlib` | `with` machinery. |
| `copy` | Deep + shallow copy. |
| `enum` | `IntEnum`, `Enum`. |
| `dataclasses` | Lightweight record types. |
| `types` | Type primitives — wide use. |
| `typing` | `List[int]` annotations etc.; runtime-only. |
| `weakref` | GC-adjacent. |
| `heapq` | Demo programs use it. |
| `bisect` | Same. |
| `struct`, `_struct` | Binary packing. |
| `codecs`, `_codecs` | UTF-8 only is enabled. |
| `encodings`, `encodings.utf_8`, `encodings.ascii` | Required by `codecs`. |

Modules **explicitly excluded** from the frozen set (would compile but
import other things we don't have, or are large + unused):
`socket`, `select`, `ssl`, `_ssl`, `_socket`, `subprocess`,
`threading`, `_thread`, `multiprocessing`, `concurrent.futures`,
`asyncio` (any submodule), `signal` (substituted by our shim's
single-handler model), `tkinter`, `turtle`, `urllib`, `http`, `email`,
`xml.*`, `tarfile`, `zipfile`, `gzip`, `bz2`, `lzma`, `sqlite3`,
`_sqlite3`, `_ctypes`, `ctypes`, `argparse`, `unittest`, `pdb`,
`profile`, `cProfile`, `pydoc`, `idlelib`, `lib2to3`, `tkinter` (dup),
`distutils`, `setuptools`, `pip`, `ensurepip`. Importing any of these
raises `ImportError: No module named 'X'`.

### REPL

CPython's REPL entry point (in `Modules/main.c` →
`pymain_run_interactive_hook`) calls `PyRun_InteractiveLoop`, which
calls `tok_underflow_interactive` → `_PyOS_Readline`, which (with
`HAVE_LIBREADLINE=0`) falls back to `fgets` reading from stdin.

Phase 3's cooked-mode console:
- Echoes each printable byte to stdout.
- Handles backspace (deletes a byte from the line buffer + writes
  `\b \b` to stdout).
- Commits the line on `\n` (returns the buffered bytes from `read`).
- Handles `^U` (line kill), `^D` (EOF), `^C` (kill-flag).

This is exactly what CPython's `fgets`-style REPL needs. Arrow keys
produce escape sequences (`ESC [ A` for up-arrow); these arrive at
the REPL as literal bytes, get parsed by the tokenizer as illegal
characters, and CPython prints `SyntaxError`. That's mildly annoying
but fully consistent — and it's exactly what plain `python` looks
like on a stripped-down Linux without readline.

We pin `HAVE_LIBREADLINE 0` and `HAVE_LIBEDIT 0` in `pyconfig.h`.
Phase 6 ships no line editor. The 6.5 polish plan adds one.

### Signal & ^C model

This is the only kernel change in Phase 6. The mechanism:

**Phase 3.F's existing model:**
1. User hits `^C`.
2. UART RX → `console.feedByte(0x03)`.
3. Console calls `proc.kill(fg_pid)`.
4. `proc.kill` sets `proc.killed = 1`, calls `wakeup(proc)` to break
   any blocking syscall.
5. The blocking syscall returns -1.
6. The S-mode trap dispatcher checks `proc.killed` on syscall return;
   if set, calls `proc.exit(-1)`.

**The CPython model needs:**
1. Same `^C` → kill-flag path through step 5.
2. **Step 6 changes:** if the proc opted into "interrupt mode," the
   kernel returns -EINTR from the syscall instead of exiting.
3. The libc shim's `_read` sees -EINTR, sets `errno=EINTR`, returns -1.
4. CPython's `read()` wrapper (in `Modules/posixmodule.c`) checks
   `PyErr_CheckSignals` on EINTR.
5. `PyErr_CheckSignals` consults a thread-local `is_tripped` flag.
6. Our libc-shim's `signal(SIGINT, handler)` registered a handler that
   sets that flag when called.
7. **But the kernel doesn't call user-space signal handlers** —
   nothing in Phase 6 supports asynchronous signal delivery in the
   POSIX sense. So we shortcut step 6: when sig_int_mode=1 and
   killed_flag was set, the libc-shim's `_read` *itself* calls the
   registered SIGINT handler before returning -1.

In other words: **our "signal handler" is invoked synchronously in the
context of the syscall return, not asynchronously from a signal frame.**
This is a deliberate simplification that works because:
- CPython only uses `signal(SIGINT, …)` for the REPL interrupt path.
- The handler does ~3 instructions: set `is_tripped = 1`.
- All actual work happens in the next bytecode dispatch via
  `PyErr_CheckSignals`.

The new kernel syscall (#220):

```zig
// src/kernel/syscall.zig — new entry
pub fn sysSigactionIntMode(args: SyscallArgs) i32 {
    const mode: u8 = @truncate(args.a0);
    if (mode > 1) return -EINVAL;
    const p = sched.curproc.?;
    p.sig_int_mode = mode;
    return 0;
}
```

The trap dispatcher's killed-flag check changes from:

```zig
if (p.killed != 0) {
    proc.exit(p, -1);
}
```

to:

```zig
if (p.killed != 0) {
    if (p.sig_int_mode == 0) {
        proc.exit(p, -1);
    } else {
        p.killed = 0;
        return -EINTR;  // surface to syscall return path
    }
}
```

`Process.sig_int_mode` defaults to 0; only programs that explicitly
opt in (via the new syscall) get EINTR semantics. Phase 3 binaries
(`sh`, `cat`, `edit`, etc.) all see the original exit-on-^C behavior.

`e2e-cancel` (Phase 3.F) uses `cat`, which never opts in → unchanged.
A new `e2e-py-interrupt` exercises the new path through CPython.

**At the idle REPL prompt (^C with no in-flight syscall):**
- The kernel's `console.feedByte(0x03)` only fires `proc.kill` on the
  foreground process. CPython, sitting in `read()`, IS the foreground
  process.
- killed-flag → EINTR (per sig_int_mode=1) → CPython sees EINTR → no
  bytes available → CPython's REPL prints `KeyboardInterrupt\n>>> `
  and reprompts.
- Two `^C`s in quick succession: REPL just prints the message twice;
  no double-kill semantics needed (Python's REPL doesn't exit on
  double-^C anyway).
- `>>> exit()` exits cleanly via `_exit(0)` → `proc.exit`. Foreground
  proc shifts back to `sh`.

### Memory budget

Per-process:
- **Text segment:** ~12 MB (CPython core + frozen stdlib).
- **rodata:** ~2 MB (interned strings, bytecode tables, Unicode DB).
- **bss + initial heap:** ~1 MB at startup; grows via dlmalloc/sbrk.
- **Stack:** **256 KB** (up from Phase 3's default 16 KB — set in
  user_linker.ld). CPython recursion limit defaults to 1000; with
  per-frame ~200 B, 1000 frames = ~200 KB.

Default ccc RAM is 128 MB. With CPython's ~15 MB of static + 256 KB
stack + headroom, a Python program can use ~80–100 MB of heap before
hitting the page allocator's free-list. Plenty for any demo.

If the user runs `ccc --memory 256 …`, Python gets ~210 MB of heap.

### `mkfs` image-size bump

Phase 3's `mkfs.zig` lays out a fixed 4 MB image: 1 boot block, 1
superblock, NBITMAP blocks, NINODES inodes, then data. CPython's
~12 MB binary doesn't fit.

Changes:
- `--image-size MB` flag (default 4 MB).
- `NBLOCKS = (MB << 20) / BLOCK_SIZE`.
- `NINODES = NBLOCKS / 16` (one inode per ~16 blocks of data).
- The on-disk superblock already has 32-bit fields for `nblocks` and
  `ninodes` — no on-disk format change.
- The kernel's `fs/layout.zig` reads these from the superblock; the
  hard-coded constants are replaced with field reads.

`fs.img` (4 MB) for Phase 3's existing demos is unchanged.
`fs-img-py` is a new build step producing a 64 MB image with
`/bin/python` and the demo .py files staged.

`e2e-fs` regression: runs against both 4 MB and 64 MB images;
asserts the on-disk init payload reads back correctly in both.

### Process model — additions

- **`Process` struct:** add `sig_int_mode: u8` (init 0).
- **`exec`:** clears `sig_int_mode` (reset to default on new program).
- **`fork`:** copies `sig_int_mode` (child inherits parent's mode).
- **`exit`:** unchanged.
- **No new fd types.** CPython opens `/dev/tty` (= console fd 0)
  through the existing console-as-fd-0 wiring from Phase 3.E.

## CLI

**No new CLI flags on `ccc`** unless we count `--memory 256` (already
exists, just commonly invoked at this scale).

The `--trace-py-opcodes` flag is added in 6.G to filter the tracer:

```
ccc [existing flags] [--trace-py-opcodes] kernel-fs.elf
```

When set, every CPython bytecode dispatch logs a one-line opcode
name + sp depth. Off by default.

`/bin/python` userland CLI:

```
python                       interactive REPL
python -c "<code>"           run inline code, exit
python <script.py> [args]    run script with sys.argv set
python -m <module>           run module (frozen-only — no -m for non-frozen)
python -V                    print version
python -h / --help           print usage
```

## Project structure (deltas from current head + Phases 4–6)

```
ccc/
├── build.zig                        + python.zig include + fs-img-py target
├── src/
│   ├── kernel/
│   │   ├── syscall.zig              + #220 sigaction_int_mode
│   │   ├── trap.zig                 + EINTR branch in killed-flag check
│   │   └── proc.zig                 + sig_int_mode field
│   └── userland/                    NEW (Phase 6 introduces this hierarchy)
│       ├── libc-shim/
│       │   ├── syscall.c            ~400 LoC — picolibc hooks
│       │   ├── errno.c              ~30 LoC
│       │   ├── environ.c            ~10 LoC
│       │   ├── heap.c               ~50 LoC
│       │   ├── stubs.c              ~150 LoC — mmap/pthread/dlopen → -ENOSYS
│       │   ├── signal.c             ~80 LoC — SIGINT shim
│       │   └── dirent.c             ~60 LoC — opendir/readdir wrap fd reads
│       └── cpython-port/
│           ├── pyconfig.h           ~400 LoC committed config
│           ├── frozen_modules.txt   list of stdlib modules to freeze
│           └── README.md            "how to bump CPython" runbook
├── third_party/                     NEW
│   ├── cpython/                     submodule, pinned tag (3.12.x)
│   ├── cpython-patches/             ~30 small *.patch files
│   ├── picolibc/                    submodule, pinned tag
│   ├── picolibc-patches/            ~5 *.patch files (RV32 freestanding fixes)
│   └── dlmalloc/
│       └── malloc.c                 vendored, ~6 KLoC, public domain
├── programs/
│   └── python-demo/                 NEW — staged into /usr/lib/demo/ via mkfs
│       ├── pi.py                    ~40 LoC
│       ├── life.py                  ~80 LoC
│       ├── wc.py                    ~30 LoC
│       ├── exc.py                   ~4 LoC
│       └── json_demo.py             ~25 LoC
├── tests/
│   ├── e2e/
│   │   ├── c_hello.zig              6.A
│   │   ├── c_alloc.zig              6.B
│   │   ├── py_eval.zig              6.C
│   │   ├── py_repl.zig              6.D
│   │   ├── py_stdlib_smoke.zig      6.D
│   │   ├── py_pi.zig                6.E
│   │   ├── py_life.zig              6.E
│   │   ├── py_wc.zig                6.E
│   │   ├── py_json.zig              6.E
│   │   ├── py_exception.zig         6.E
│   │   ├── py_interrupt.zig         6.F
│   │   ├── py_demo.zig              6.G — full 8-line scripted demo
│   │   ├── py_*.input.txt           per-test input fixtures
│   │   └── ...
│   └── fixtures/
│       └── python-demo-expected/    expected stdout snapshots per demo
└── docs/superpowers/
    └── specs/                       + this spec
```

Approximate code volumes:
- New ccc Zig: ~600 LoC (build.zig deltas + kernel syscall + e2e harnesses).
- New ccc C: ~800 LoC (libc-shim).
- New ccc Python (demo programs): ~180 LoC across 5 files.
- New ccc generated (frozen stdlib `.c`): ~5 KLoC after `freeze_modules.py`.
- Pinned external code: ~600 KLoC CPython + ~50 KLoC picolibc + 6 KLoC dlmalloc.

## Implementation plan decomposition

Seven plans, sized to land independently:

- **6.A — picolibc bring-up + image-size bump.**
  Submodule picolibc, write `libc-shim/{syscall,errno,environ,signal}.c`
  (signal.c here is just stubs; the real path lands in 6.F).
  Bump `mkfs.zig` to support `--image-size` and validate the
  superblock-derived constants. Cross-compile a tiny C program
  (`programs/c_hello/c_hello.c`: `int main() { printf("hello, libc\n"); return 0; }`)
  against picolibc, link with `libulib`, run in ccc. Milestone:
  `e2e-c-hello` passes; `e2e-fs` runs against both 4 MB and 64 MB
  images. **No CPython yet.**

- **6.B — dlmalloc + soft-float + Zig build skeleton.**
  Vendor dlmalloc 2.8.6; write `libc-shim/heap.c`. Wire compiler-rt
  soft-float via Zig's `riscv32-freestanding` target's libc inclusion.
  Write a skeletal `python.zig` build module that compiles **one**
  CPython file (`Python/initconfig.c`) end-to-end through our pipeline.
  This isn't a runnable Python — it's a "the linker resolves all
  symbols and emits an ELF" check. A separate test program `c_alloc`
  exercises malloc/free/realloc/calloc (allocate 1 MB, memset,
  free, allocate 10× 100 KB, free in reverse order, exit 0).
  Milestone: `e2e-c-alloc` passes; `python.zig` produces an ELF
  (function-stripped, will fault if run — that's fine here).

- **6.C — `pyconfig.h` + minimum CPython core.**
  Submodule CPython 3.12.x pinned. Hand-author `pyconfig.h` + first
  ~10 patches (commented `// CCC: …` for each). Add ALL of `Python/`,
  `Objects/`, `Parser/`, plus the minimum `Modules/` needed to
  initialize `_PyRuntime` and call `Py_RunMain` with `-c "pass"`.
  Expect 80% of dev time here to be chasing missing libc symbols
  (each one either landed in picolibc, added to `libc-shim/stubs.c`,
  or guarded with `HAVE_*=0`). Milestone: `python -c "pass"` runs
  and exits 0; `python -c "print('hello')"` prints `hello`. `e2e-py-eval`.
  **At this point we have a working Python; subsequent plans are
  feature additions, not bring-up.**

- **6.D — Frozen stdlib + REPL + smoke test.**
  Add `Tools/build/freeze_modules.py` invocation as a build step.
  Curate the ~30-module list in `frozen_modules.txt`. Wire the
  generated `.c` files into `python.zig`. Bring up the interactive
  REPL (`python` with no args). Write `e2e-py-stdlib-smoke` — a
  one-line script that does `import sys, os, io, errno, re, json,
  collections, math, random, itertools, functools, operator,
  string, decimal, time, pathlib, traceback, contextlib, copy,
  enum, dataclasses, types, typing, weakref, heapq, bisect, struct,
  codecs` and asserts no `ImportError`. Milestone: `e2e-py-repl`,
  `e2e-py-stdlib-smoke` pass.

- **6.E — Demo programs + JSON + Pi + Life + WC + exceptions.**
  Author the five demo `.py` files (`pi`, `life`, `wc`, `exc`,
  `json_demo`). Stage them into `fs-img-py` via `mkfs --root` walking
  `programs/python-demo/`. The exception test runs from a file
  (`exc.py`), bypassing Phase 3.E `sh`'s lack of multi-line `-c`
  quoting. Milestones: `e2e-py-pi`, `e2e-py-life`, `e2e-py-wc`,
  `e2e-py-json`, `e2e-py-exception` pass.

- **6.F — Signal model + ^C interrupt path.**
  Land kernel syscall #220 + `sig_int_mode` field + EINTR branch in
  the trap dispatcher. Update `libc-shim/signal.c` to opt in at startup
  + invoke registered handlers synchronously on EINTR delivery. Debug
  via direct printf in the libc shim's signal path; the deeper
  `--trace-py-opcodes` plumbing waits for 6.G. Milestone:
  `e2e-py-interrupt` passes — boot, `python`, REPL, `>>> while True:
  pass`, scripted `^C`, see `KeyboardInterrupt`, scripted `exit()`,
  clean halt.

- **6.G — Polish: trace integration + binary size + final demo + docs.**
  Wire `--trace-py-opcodes` properly in `src/emulator/trace.zig` (a
  filter that only emits when PC is in the CPython text segment — we
  bake the segment range into the binary as a known symbol pair
  `_py_text_start` / `_py_text_end` and the emulator reads them via
  the existing ELF symbol lookup). Strip the binary
  (`-Os -fdata-sections -ffunction-sections -Wl,--gc-sections`),
  measure size; if >15 MB, drop low-value frozen modules (`xml.*`,
  bigger pieces of `email`). Update README with Phase 6 status.
  Milestone: `e2e-py-demo` (the eight-line scripted session) passes;
  binary is <15 MB; full Phase 1 + 2 + 3 + 7 e2e suite green.

Plan boundaries are designed so 6.A is shippable as "ccc can run
hand-written C programs with libc support" even if the rest of
Phase 6 stalls — it's Phase 6's analog to 6.A's "framebuffer works
without a compositor."

## Testing strategy

### 1. Unit tests (`zig build test`)

- `mkfs.zig`: verify `--image-size` produces correct superblock
  values for 4 MB, 64 MB, 256 MB.
- `libc-shim/syscall.c`: a host-side test program that links the
  shim with stub `ecall`s, exercises every hook with valid + invalid
  args, asserts errno passthrough.
- The CPython unit-test corpus (`Lib/test/test_*.py`) is **not** in
  scope — too many tests, too many require `_socket` / `threading`.
  A 6.5 plan explores a curated test_subset (`test_int.py`,
  `test_str.py`, `test_dict.py`, etc.) once the binary stabilizes.

### 2. Kernel e2e tests

| Test | What it asserts | Plan |
|---|---|---|
| `e2e-c-hello` | hand-crafted `printf("hello, libc\n")` C program runs in ccc, prints exactly that. | 6.A |
| `e2e-c-alloc` | dlmalloc `malloc(1<<20)` → `memset(0xab)` → `free` → `malloc(100KB)` × 10 → free reverse → exit 0. Asserts no kernel panic + exit code 0. | 6.B |
| `e2e-py-eval` | `python -c "print(2 + 2)"` prints `4`. Smallest possible CPython runtime smoke test. | 6.C |
| `e2e-py-repl` | scripted REPL: `>>> 2 ** 200<enter>`, expected line, `>>> exit()<enter>`, exit 0. | 6.D |
| `e2e-py-stdlib-smoke` | runs a 1-line script that imports the entire curated stdlib; asserts no `ImportError`. | 6.D |
| `e2e-py-pi` | `python /usr/lib/demo/pi.py 50` → first 50 digits of π exact. | 6.E |
| `e2e-py-life` | `python /usr/lib/demo/life.py 8` → 8 generations, frame hashes match committed goldens (line-by-line CRC). | 6.E |
| `e2e-py-wc` | `python /usr/lib/demo/wc.py /etc/motd` → ` 19  4  1 /etc/motd`. | 6.E |
| `e2e-py-json` | `json_demo.py` round-trips a structure and asserts equality. Stdout is the pretty-printed JSON. | 6.E |
| `e2e-py-exception` | `python /usr/lib/demo/exc.py` prints `ok`. | 6.E |
| `e2e-py-interrupt` | REPL → infinite loop → `^C` → `KeyboardInterrupt` traceback in stdout → `exit()` → exit 0. Timing-sensitive; harness uses `--input` with deliberate ordering. | 6.F |
| `e2e-py-demo` | the full 8-line §Definition of done scripted session. | 6.G |

### 3. Frame-hash policy (for `e2e-py-life`)

Game of Life output is deterministic given a seed. The demo seeds
from a constant (no `time` reads). Expected output is committed as a
plain `.txt` file under `tests/fixtures/python-demo-expected/`; the
test does byte-exact comparison via SHA1.

### 4. `riscv-tests` and Phase 1–3 regressions

Unchanged. The new kernel syscall #220 is additive; existing tests
don't call it. Phase 3.F's `e2e-cancel` continues to pass with default
sig_int_mode=0.

### 5. Manual smoke (not in CI)

The 8-line demo run interactively at the end of 6.G. Same policy as
Phase 4's `ping 1.1.1.1` and Phase 5's `info.cern.ch` — outside CI
because the user-visible output is what matters and we don't want to
spend CI budget rebuilding the 15 MB binary every push (the e2e
harness builds it once as a CI cache target).

### 6. Build determinism

CPython's frozen-module bytecode is sensitive to host Python version
+ marshalling endianness. We pin `Python 3.12.x` on host (CI installs
it), and emit marshalled bytes with explicit little-endian (CPython's
default on RV32 little-endian targets). The frozen `.c` files'
SHA256 are checked into `tests/fixtures/freeze-checksums.txt`; CI
verifies a freeze re-run produces the same hashes (catches host
Python version drift).

## Risks and open questions

- **Bring-up time for 6.C.** The first time CPython compiles + links
  + runs `print("hello")` is the longest single step in any phase
  spec so far. Estimated 2–4 weeks for an experienced porter; longer
  if libc gaps are deeper than expected. Mitigate by starting the
  link-error chase early in 6.B (the "compile one CPython file"
  milestone is partly a libc-completeness check).
- **picolibc gaps.** picolibc covers ~95% of CPython's libc surface,
  but the long tail (`wcsftime`, `mbrtoc16`, locale tables) might
  have subtle issues. Mitigation: keep `libc-shim/stubs.c` open for
  additions; document each stub with what it would take to make it
  real.
- **Stack size.** 256 KB might be too tight for deep regex backtracking
  or pathological recursion. Default `sys.setrecursionlimit(1000)`
  trips around frame ~250 with our frame size. Mitigate by exposing
  `--py-stack-mb` build flag in 6.G; default 256 KB, demos that need
  more bump to 1 MB.
- **`_pydecimal` performance.** Pure-Python decimal is ~10× slower
  than `_decimal`. `pi.py 50` finishes in ~150 ms; `pi.py 500` in
  ~15 s. Acceptable; documented; 6.5 plan can pull `libmpdec`.
- **Soft-float perf.** As noted under §Architecture, `math.sin(1.0)`
  is ~5 µs. `life.py` is integer-only; `pi.py` is decimal-only — no
  hot floats in the demo set. Real-world Python that uses floats
  heavily (NumPy-shape work) would feel slow; we don't benchmark
  that.
- **Binary size > 15 MB.** First builds will likely be ~25 MB
  (debug-shaped). `-Os -fdata-sections -ffunction-sections
  -Wl,--gc-sections` typically gets ~40% reduction. If we end at
  18–20 MB, 6.G drops less-essential frozen modules (`pathlib` →
  ~150 KB, `decimal` → ~250 KB, `unicodedata` → ~1.5 MB). The hard
  cap to keep `python` reasonable to load: 32 MB.
- **`mkfs` 64 MB image vs. block device.** The Phase 3 block device
  is host-file-backed — file size is a parameter, not a constraint.
  mkfs already writes whatever size the superblock says. Confirmed
  by reading `src/kernel/mkfs.zig` during this design — no actual
  block-device changes needed.
- **Frozen-module determinism across host Python versions.** A host
  Python 3.13 might marshal differently than 3.12. We pin host
  Python's major.minor in CI to 3.12.x to match the target. Build
  determinism check (#6 in testing) catches drift.
- **CPython submodule churn.** CPython 3.12.x patch versions may
  introduce backports that break our patch set. We pin a specific
  patch (e.g. 3.12.4) at plan start and don't bump within Phase 6;
  bumps are 6.5+ work.
- **The `signal()` shortcut is a known cheat.** Calling the registered
  SIGINT handler synchronously in the syscall return path (rather than
  asynchronously) means a CPython program that loops without I/O
  *won't* see ^C until its next `_read`/`_write`/etc. CPython's eval
  breaker (`_Py_atomic_load(&interrupt_occurred)` checked every N
  bytecodes) doesn't help here because we're not setting that flag —
  the libc shim is. Mitigate by ALSO setting the flag in `signal.c`'s
  registered handler: even if `read()` is the trigger, bytecode
  dispatch *will* see the flag and raise `KeyboardInterrupt`
  immediately, not on the next syscall. Implementation detail to land
  in 6.F.
- **Reentrancy of `_start`.** ccc's `_start.S` from Phase 3.E doesn't
  call `__libc_init` — it calls `main` directly with parsed argc/argv.
  We add a small `_start.c` (or extend `start.S`) that sets up libc
  state (errno = 0, dlmalloc init = no-op, environ = empty) before
  calling `main`. ~30 LoC, lands in 6.A.
- **Zig version churn.** Same as every phase. Re-pin `build.zig.zon`
  at Phase 6 start. Phase 6's compiler-rt soft-float dependency may
  shift Zig version compatibility windows — verify the pinned Zig
  version still ships the soft-float symbols in compiler-rt-builtins.
- **README + roadmap update on approval.** Phase 6 isn't in the
  current 5+1-phase roadmap. The roadmap doc and README's phase
  table both need a row added. The roadmap's "decomposition rule"
  ("never write more than one phase's spec at a time") still holds —
  Phase 6 is its own spec. Note in the spec's status that approval
  triggers a roadmap PR.

## Roughly what success looks like at the end of Phase 6

```
$ zig build test                 # all unit tests pass (Phase 1+2+3+7)
$ zig build riscv-tests          # rv32{ui,um,ua,mi,si}-p-* all pass
$ zig build e2e                  # all prior e2e + e2e-c-hello + e2e-c-alloc
                                 #  + e2e-py-eval + e2e-py-repl
                                 #  + e2e-py-stdlib-smoke + e2e-py-pi
                                 #  + e2e-py-life + e2e-py-wc + e2e-py-json
                                 #  + e2e-py-exception + e2e-py-interrupt
                                 #  + e2e-py-demo all pass

$ zig build python && zig build fs-img-py
$ zig build run -- --memory 256 --disk zig-out/fs-py.img zig-out/bin/kernel-fs.elf

ccc booting kernel-fs.elf (256 MB RAM)
hello from phase 3
$ python -c "print('hello, ccc')"
hello, ccc

$ python
Python 3.12.4 (ccc/0.7) [Zig 0.16.x]
Type "help", "copyright", "credits" or "license" for more information.
>>> 2 ** 200
1606938044258990275541962092341162602522202993782792835301376
>>> import sys; print(sys.version)
3.12.4 (ccc/0.7) [Zig 0.16.x]
>>> exit()

$ python /usr/lib/demo/pi.py 50
3.1415926535897932384626433832795028841971693993751

$ python /usr/lib/demo/life.py 8
gen 0:
  ████··········
  ·····█·········
  ······█·········
  ·······█········
  ········████····
gen 1:
  ··············
  ····███·······
  ····███·······
  ········█·····
  ········████··
... (8 generations)

$ python /usr/lib/demo/wc.py /etc/motd
   19      4      1 /etc/motd

$ python
>>> while True: pass
^C
Traceback (most recent call last):
  File "<stdin>", line 1, in <module>
KeyboardInterrupt
>>> exit()

$ exit
ticks observed: 247
```

…and you understand every byte: from the M-mode boot shim through the
S-mode kernel into a CPython REPL prompt. Through the REPL byte coming
back through `read()` from console.zig, the cooked-mode line buffer,
the syscall return path, picolibc's stdio buffering, `tok_underflow`,
the parser, the bytecode compiler, `ceval.c`'s dispatch loop, every
bytecode walking through dlmalloc-allocated `PyObject`s, soft-float
`__divdf3` calls, pymalloc arena recycling, all the way back through
`PyOS_Readline` → `_write()` → `console.zig` → UART out — every layer
written by you (or pinned + reviewed in a submodule with an explicit
shim layer) over seven phases.
