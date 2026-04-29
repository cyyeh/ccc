# Phase 7 — Framebuffer + Compositor + Windowed Apps (Design)

**Project:** From-Scratch Computer (directory `ccc/`).
**Phase:** 7 of 7 — see `2026-04-23-from-scratch-computer-roadmap.md` (this
spec extends that roadmap; the original document lists five phases and an
explicit "No graphics" non-goal — see the §Why section below).
**Status:** Draft 2026-04-26 — open for review. Depends on Phase 3.F
completion (filesystem, shell, line-discipline console). Independent of
Phase 4 / 5 / 6 — can land before, after, or in parallel.

## Goal

Reverse the original "no graphics" decision and add a minimal but
end-to-end graphical stack: a linear framebuffer device in the emulator,
mouse + keyboard input devices, a kernel-side framebuffer driver and
`mmap` syscall, a userland compositor (`wm`), and a small handful of
windowed demo apps. Same Zig core, same RV32IMA emulator, same kernel —
the GUI is additive, not a replacement.

After Phase 7, the existing UART / shell / snake demos still work
byte-for-byte; the new graphical mode is selected by booting `init` to
launch `wm` instead of `sh`.

## Why

**The original goal sheet says "No graphics."** That decision was made
when the goal was a text-mode HTTP browser; graphics looked like a
distraction with no payoff for that target. Three things changed:

1. **The kernel matured.** Phase 3.C delivered fork/exec/wait, and 3.D-F
   add a real filesystem and shell. A compositor is just another userland
   process; the OS-side primitives it needs (`mmap`, IPC, shared pages)
   are reasonable next-step extensions of the kernel we already have.
2. **The emulator is honest.** A linear framebuffer mapped into RAM is
   a tiny addition (~120 lines, no new privilege story). It's a
   well-trodden device pattern from real embedded SoCs (`simple-framebuffer`
   in QEMU virt, framebuffer in early Xen).
3. **A graphical demo is its own narrative slice.** Phase 1's hello,
   Phase 2's `[U-mode] hello`, Phase 3's `$ ls /bin`, Phase 5's
   text-rendered HTTP page — each is a moment. A windowed desktop on the
   same RV32 core is a fourth such moment, and one that's instantly
   legible to non-technical viewers in a way that a terminal isn't.

**Cost honesty:** Phase 7 is the largest phase by absolute size. It
introduces the first piece of the project that has a "user-experience"
surface beyond a terminal. Plan boundaries below try to keep the cost
disciplined; the smallest viable slice (7.A) is ~2 weeks of work and
proves the emulator/kernel/host-display path before any compositor work.

## Definition of done

- `zig build kernel-gui` produces `kernel-gui.elf`. `zig build fs-img-gui`
  bakes an `fs.img` containing `/bin/init`, `/bin/wm`, `/bin/hello-gui`,
  `/bin/clock`, `/bin/calc`, plus the existing `sh` + utilities.
- `ccc --disk fs.img --display kernel-gui.elf` boots, runs `/bin/init`,
  which `exec`s `/bin/wm`. A 640×480 host window opens (SDL2 on the CLI
  build; `<canvas>` on the wasm build).
- The desktop renders: solid background fill, mouse cursor, two startup
  windows (`hello-gui` showing static text, `clock` showing live `mm:ss`
  ticking once per second).
- Pressing keys or moving the mouse causes the cursor to track and the
  topmost-under-cursor window to receive focus + the event.
- A scripted e2e session passes (frame-hash comparison against committed
  goldens):
  ```
  --display none --golden-frames tests/golden/phase7/
  → boot to wm
  → wait 5 mtime-seconds
  → assert frame[300] hash == golden/desktop_with_clock_05s.crc
  → fork+exec /bin/calc with argv=["calc"]
  → wait 1 mtime-second
  → assert frame[360] hash == golden/desktop_with_calc.crc
  → press '7' '+' '8' '=' (input event injection)
  → assert frame[363] hash == golden/calc_shows_15.crc
  → ^Q
  → assert frame[365] hash == golden/desktop_no_calc.crc
  ```
- All Phase 1 e2e tests (`e2e`, `e2e-mul`, `e2e-trap`, `e2e-hello-elf`),
  Phase 2 (`e2e-kernel`), Phase 3 (`e2e-multiproc-stub`, `e2e-fork`,
  `e2e-fs`, `e2e-shell`, `e2e-editor`, `e2e-persist`), and the snake demo
  (`e2e-snake`) still pass unchanged.
- `riscv-tests` (rv32ui/um/ua/mi/si all `-p-*`) still pass.
- New e2e tests pass: `e2e-fb-blit` (7.A), `e2e-mmap` (7.B),
  `e2e-input-event` (7.B), `e2e-wm-static` (7.D), `e2e-wm-input` (7.E),
  `e2e-gui-demo` (7.F, the scripted session above).
- `--trace` works across the new IRQ paths; vsync and input PLIC
  claim/complete show up as synthetic marker lines.
- The web demo gains a "wm" entry in the program selector. Picking it
  swaps the ANSI `<pre>` for a `<canvas>` blitting `ImageData` from the
  emulator's framebuffer at 60 Hz.

## Scope

### In scope

- **Emulator additions:**
  - **Framebuffer device** at `0x5000_0000` — linear 640×480 XRGB8888
    (1.2 MB) backed by a host pixel buffer. Treated as RAM-like by
    `memory.zig`'s dispatch (no per-pixel callback) so blit performance
    is acceptable.
  - **Framebuffer control registers** at `0x5013_0000` (4 KB) — width,
    height, pitch, format, mode (active / off), all read-only in
    Phase 7 (resolution is fixed).
  - **Input MMIO device** at `0x1000_2000` (256 B) — a 16-event ring
    buffer plus a few control registers. Combined keyboard + mouse
    events with a type discriminator.
  - **Vsync source** — synthetic, driven by `mtime` in the emulator
    main loop; raises PLIC source 14 every 16.67 ms (60 Hz).
  - **Host display backend** — SDL2 on macOS / Linux for the CLI
    build, `<canvas>` + `ImageData` on the wasm build. Optional; the
    `--display none` mode keeps the FB device active but skips the
    host window (used for headless e2e + golden-frame tests).
  - **`--display BACKEND`**, **`--golden-frames DIR`**, and
    **`--inject-input PATH`** flags on the CLI.
- **Kernel additions:**
  - **`mmap` syscall** — file-backed and anonymous, no `MAP_PRIVATE`
    COW (only `MAP_SHARED`). Length must be a 4 KB multiple. Used by
    `wm` to map the framebuffer; used by apps to map per-window
    backing stores allocated by the compositor.
  - **Framebuffer device file** `/dev/fb0` — 1.2 MB, mappable, exposes
    the FB control registers via `ioctl`-equivalent (a single new
    `fbinfo()` syscall returning width / height / pitch / format).
  - **Input device file** `/dev/input` — readable; `read()` blocks
    until at least one input event is in the kernel's event queue and
    returns up to N×16 bytes of packed events.
  - **Vsync device file** `/dev/vsync` — readable; `read()` blocks
    until the next vsync IRQ and returns the current 8-byte frame
    counter.
  - **Pipes** (`pipe2`) — minimum-viable single-writer / single-reader
    kernel pipe with a 4 KB ring. Used by `wm` for the bidirectional
    command/event channel with each connected app.
  - **Service registry** — a tiny convention, not a kernel feature: a
    socket-style well-known path `/var/run/wm.sock` is just a file
    whose contents are the compositor's PID. Apps `kill(pid, SIG_USR1)`
    to nudge it; the compositor responds via the inherited pipe-pair
    convention. (See "IPC primitive" below for why we punt on real
    sockets.)
- **Userland additions:**
  - **`wm`** — compositor. Owns `/dev/fb0`, the input queue, and a
    list of windows. Drives the frame loop on `/dev/vsync`. Routes
    input by hit-testing window rects.
  - **`libgfx`** — userland library: pixel ops (set, get, fill rect,
    blit rect, blit-with-clip), a bitmap-font glyph renderer, and the
    client side of the compositor wire protocol (`gfx_connect`,
    `gfx_create_window`, `gfx_submit_damage`, `gfx_recv_event`).
  - **Bitmap font** — a public-domain 8×16 monospace set (likely
    "Spleen" or similar; final pick in 7.C). Baked into `libgfx` at
    build time as a 4 KB `.rodata` blob.
  - **Demo apps:** `hello-gui`, `clock`, `calc`, plus a windowed
    `term` (single-window, embeds the existing line-discipline
    console — proves text and graphics coexist).

### Out of scope (deferred)

- **Hardware-accelerated graphics.** The CPU has no FPU and no GPU.
  Software rasterization only. A future Phase 7.G could add a
  `simple-2d-accel` MMIO device for fill/blit DMA, but Phase 7 doesn't
  need it.
- **Anti-aliased text or fonts beyond 8×16.** Bitmap-only.
- **Image decoding** (PNG / JPEG / BMP / GIF) — apps that want images
  bake them as `.rodata` at compile time.
- **Window decorations beyond a 1-pixel border + 12 px title bar.**
  No themes, no shadows, no transparency. (Translucency would need
  alpha compositing per pixel — single-pass-blit-only is much faster.)
- **Mouse cursor themes / animations.** A static 12×12 white-on-black
  arrow, hard-coded.
- **Drag-and-drop, copy/paste, selection.** Each app draws and
  handles its own events; no system-level clipboard.
- **Multiple monitors / hot-plug / resolution changes.** Fixed 640×480.
- **Real GUI framework** (widgets, layout, accessibility). Each demo
  app uses libgfx primitives directly.
- **A graphical shell that replaces text `sh`.** `term` is just a
  window that proxies to the existing console; you launch other apps
  by typing `wm-launch /bin/calc` from inside it.
- **Sound / audio.** Same reason as in the snake demo: not worth
  introducing the dependency for what we're trying to show.

### Out of scope (never)

- TLS, SSL, GPU, kernel-side dynamic loading, hot-pluggable USB,
  Bluetooth, Wi-Fi, ACPI, power management, multi-touch, accelerometer,
  camera, DRM (Direct Rendering Manager), Wayland or X11 protocol
  compatibility.

## Architecture

### Layered overview

```
┌──────────────────────────────────────────────────────────────┐
│ Userland                                                     │
│                                                              │
│   apps:   hello-gui   clock   calc   term                   │
│           │           │       │      │                       │
│           └───────────┴───────┴──────┘                       │
│                          │                                   │
│                       libgfx                                 │
│                          │                                   │
│            ┌─────────────┴─────────────┐                     │
│            │ wm-protocol over pipes    │                     │
│            │ (cmd app→wm, evt wm→app)  │                     │
│            └─────────────┬─────────────┘                     │
│                          │                                   │
│                         wm  ◄──── mmap /dev/fb0              │
│                          │   ◄──── read /dev/input           │
│                          │   ◄──── read /dev/vsync           │
└──────────────────────────┼───────────────────────────────────┘
                           │
┌──────────────────────────┼───────────────────────────────────┐
│ Kernel                   │                                   │
│                          ▼                                   │
│   /dev/fb0    /dev/input    /dev/vsync   pipes   mmap        │
│      │            │             │                            │
│   fb_drv      input_drv      vsync_drv                       │
│      │            │             │                            │
└──────┼────────────┼─────────────┼────────────────────────────┘
       │            │             │
┌──────┼────────────┼─────────────┼────────────────────────────┐
│ Emulator                                                     │
│      │            │             │                            │
│   FB MMIO     Input MMIO    PLIC src 14                      │
│   0x5000_0000 0x1000_2000   (vsync)                          │
│                                                              │
│      │ memory-mapped        │ event ring                     │
│      ▼ as RAM-like region   ▼ + IRQ on push                  │
│  host pixel buffer    host event queue                       │
│      │                                                       │
│      ▼ blit on vsync                                         │
│   SDL2 window  /  <canvas> ImageData                         │
└──────────────────────────────────────────────────────────────┘
```

The compositor is a regular U-mode process. It sees the framebuffer as
1.2 MB of mapped memory, pulls input events through a single `read()`,
and blocks on `/dev/vsync` between frames. Apps never touch
`/dev/fb0` — they only see their per-window backing store (also
`mmap`-allocated by `wm` and shared into the app via fd-passing over a
pipe).

### Emulator modules — Phase 7 deltas

| Module | Phase 7 additions |
|---|---|
| `cpu.zig` | No changes — vsync IRQ uses the existing PLIC + S-external path from Phase 3. |
| `memory.zig` | New RAM-like region at `0x5000_0000` (FB), new MMIO range at `0x5013_0000` (FB ctrl) and `0x1000_2000` (input). Total memory footprint += ~1.5 MB host. |
| `devices/framebuffer.zig` | **NEW.** Backs `0x5000_0000` with a 1.2 MB byte buffer; serves loads/stores as ordinary RAM. Owns the FB control registers at `0x5013_0000`. ~120 lines. |
| `devices/input.zig` | **NEW.** 16-event ring at `0x1000_2000`. On `inject_input(event)` (called by the host display), pushes the event and asserts PLIC source 12. Drained by guest reads from offset 0 (FIFO peek+pop). ~140 lines. |
| `devices/vsync.zig` | **NEW.** A 6-line "device" that schedules `mtime + 16_667_000` cycles (16.67 ms @ 1 GHz model) for the next IRQ, asserts PLIC source 14, reschedules. No MMIO surface. ~30 lines. |
| `devices/plic.zig` | **No code change**, but two new sources are now real — 12 (input), 14 (vsync). 13 stays reserved. |
| `display/sdl.zig` | **NEW (CLI build).** Opens an SDL2 window on `--display sdl`, reads pixels from the FB on each host vsync, blits, polls the host's keyboard/mouse and pushes events into `devices/input.zig`. ~200 lines. Linked only on macOS/Linux native; not in the wasm build. |
| `display/canvas.zig` | **NEW (wasm build only).** Exports `framebufferPtr() -> [*]const u8`, `framebufferLen() -> u32`, `pushInputEvent(type: u32, code: u32, value: i32)` to JS. The browser does the blit. ~40 lines. |
| `display/none.zig` | **NEW.** No-op backend used by `--display none`. The FB MMIO is still served (so e2e harnesses can hash it), but there is no host window. ~15 lines. |
| `main.zig` | New flags `--display sdl|canvas|none` (default `none` on CLI; auto-`canvas` in wasm), `--golden-frames DIR`, `--inject-input PATH`. |

**Why FB-as-RAM not FB-as-MMIO.** A naive MMIO framebuffer would trap on
every pixel store. At 1.2 MB / frame × 60 fps that's 70 MB/s of
4-byte stores, which is ~18 M MMIO callbacks/sec — an order of magnitude
slower than the rest of the emulator. Treating the region as a
RAM-aliased dispatch hop (load/store goes straight into a host buffer
with no callback) costs zero extra trap overhead and is how real
hardware works (linear FBs are just memory).

**Vsync clock model.** The vsync device watches `mtime` (the same clock
the CLINT and snake game use) and asserts PLIC source 14 when
`mtime >= next_vsync`. `next_vsync` is initialized to `16_667_000` and
incremented on each fire. This means the compositor's frame rate is
locked to guest-perceived time, not host wall-clock time. In headless
mode, instructions retire faster than wall clock, so the compositor
runs as fast as the kernel can schedule it; in `--display sdl` mode,
the SDL backend rate-limits the emulator main loop to host vsync, so
guest time tracks wall clock and the desktop animates smoothly.

### Kernel modules — Phase 7 deltas

```
src/kernel/
├── ... (existing Phase 3 layout) ...
├── fb.zig            NEW. Framebuffer driver: maps 0x5000_0000 into S-mode page table, exposes /dev/fb0.
├── input.zig         NEW. Input driver: PLIC src 12 ISR drains MMIO ring, pushes into per-fd event queues, wakes readers.
├── vsync.zig         NEW. Vsync driver: PLIC src 14 ISR bumps frame_counter, wakes readers blocked on /dev/vsync.
├── pipe.zig          NEW. Single-writer single-reader 4 KB ring; fd-table-backed.
├── mmap.zig          NEW. mmap(fd, len, offset) syscall implementation: walks file's per-page backing, installs PTEs.
├── syscall.zig       + sys_mmap, sys_munmap, sys_pipe2, sys_kill (already exists from Phase 3.C — no-op extension).
├── trap.zig          + S-external case route to plic.claim() → input.isr / vsync.isr (block.isr stays).
├── proc.zig          + a per-process "vmas" list (vector of (vaddr, len, file, off, prot)). Used by mmap accounting and exec teardown.
└── kmain.zig         + register fb / input / vsync devfs entries; init_devfs runs after init_proc but before init runs.
```

`/dev/fb0`, `/dev/input`, and `/dev/vsync` are device-file inodes baked
into the FS at `mkfs` time, with a small "device type" field in the
on-disk inode that the kernel routes to the right driver on `open` /
`read` / `mmap`. (Phase 3's filesystem reserved space for this without
implementing it — see `fs/inode.zig::DiskInode._reserved`.)

### Userland additions

```
src/kernel/user/    (or programs/, see "Project structure" below)
├── lib/
│   ├── ulib.zig             unchanged
│   ├── usys.S               + mmap, munmap, pipe2 stubs
│   ├── libgfx/
│   │   ├── pixel.zig        rect, fill, blit, clip
│   │   ├── font.zig         8×16 monospace; draw_string(fb, x, y, s, fg, bg)
│   │   ├── font.bin         baked glyph data, 256 × 16 = 4 KB
│   │   └── wm_client.zig    gfx_connect / create_window / submit / recv_event
│   └── ...
├── wm/
│   ├── main.zig             event loop: drain input, drain app pipes, composite, wait vsync
│   ├── window.zig           window list, z-order, hit-test
│   ├── proto.zig            wire protocol (shared with libgfx/wm_client.zig)
│   ├── cursor.zig           hard-coded 12×12 arrow bitmap
│   └── linker.ld            user .text at 0x10000 — bigger than other apps since wm is large
├── hello-gui/main.zig       static text in a 200×100 window
├── clock/main.zig           single live-updating window, redraws on each vsync
├── calc/main.zig            4-function calc; keyboard input only
└── term/main.zig            wraps the existing line-discipline console in a window
```

## Memory layout

### Physical address space (Phase 7 deltas in **bold**)

| Address | Size | Purpose | Phase |
|---|---|---|---|
| `0x0000_1000` | 4 KB | Boot ROM (reserved, unused) | 1 |
| `0x0010_0000` | 8 B | Halt MMIO | 1 |
| `0x0200_0000` | 64 KB | CLINT | 1 |
| `0x0c00_0000` | 4 MB | PLIC | 3.A |
| `0x1000_0000` | 256 B | NS16550A UART | 1, extended in 3.A |
| `0x1000_1000` | 16 B | Block device | 3.A |
| **`0x1000_2000`** | **256 B** | **Input MMIO (event ring + ctrl)** | **7.A** |
| **`0x5000_0000`** | **1.2 MB** | **Framebuffer (XRGB8888, 640×480)** | **7.A** |
| **`0x5013_0000`** | **4 KB** | **FB control registers (RO)** | **7.A** |
| `0x8000_0000` | 128 MB | RAM | 1 |

Addresses chosen to:
- Stay clear of the existing PLIC, UART, and block ranges.
- Sit in the `0x5000_0000` "free" space that QEMU virt also uses for
  `simple-framebuffer` (so future `qemu-diff` extensions remain
  feasible).
- Leave `0x1000_2000`+ open for additional input devices later
  (`0x1000_3000` reserved for a future second input channel).

### Framebuffer layout

```
0x5000_0000 ── 0x5012_BFFF   pixel bytes, row-major, no padding
                              pitch = 640 × 4 = 2560 bytes
                              pixel(x, y) = base + y * pitch + x * 4
                              byte order: B G R X (little-endian → 0x00RRGGBB)
0x5013_0000  width        u32  read-only, == 640
0x5013_0004  height       u32  read-only, == 480
0x5013_0008  pitch        u32  read-only, == 2560
0x5013_000C  format       u32  read-only, == 1 (XRGB8888)
0x5013_0010  mode         u32  RW: 0 = blanked, 1 = active. Reset value = 1.
0x5013_0014  cursor_hint  u32  W: emulator hint to refresh now (0=skip vsync wait). Optional, no-op in headless.
```

Format `1 = XRGB8888` is the only format Phase 7 supports. Format `2 =
RGB565` is reserved for a possible future plan; the field is there so
the protocol can be extended without a guest re-flash.

### Input event ring (`0x1000_2000`)

```
0x1000_2000  head     u32  RO   write index (advances on push from emulator)
0x1000_2004  tail     u32  RW   read index (guest advances on consume)
0x1000_2008  mask     u32  RO   ring-size mask (== 15 for a 16-slot ring)
0x1000_200C  status   u32  RO   bit 0 = ring full (events were dropped)
0x1000_2010  events   16 × 16 bytes
              event[i] = { u32 type, u32 code, i32 value, u32 timestamp_lo }
```

Event encoding:

| `type` | `code`              | `value`                | Source |
|--------|---------------------|------------------------|--------|
| 1      | scancode (0..255)   | 1=press, 0=release     | keyboard |
| 2      | 1=X, 2=Y            | absolute pixel pos     | mouse motion |
| 3      | 1=left, 2=right     | 1=press, 0=release     | mouse button |

Scancodes follow the USB HID usage-page-7 keyboard table (subset:
0x04..0x39 = letters/numbers, 0x4F..0x52 = arrows, 0x29 = ESC, 0x2C =
space, 0x2A = backspace, 0x28 = enter — pinned in 7.A). Mouse
coordinates are absolute to the FB resolution; the emulator clamps to
[0, w-1] × [0, h-1] before pushing.

When the guest reads `events[tail % 16]` and increments `tail`, the
emulator clears that slot. When `head == tail`, the ring is empty (no
event ready). The kernel's input ISR drains all available events into
its per-fd event queue on each IRQ.

### Per-process virtual address space — Phase 7 additions

The Phase 3 layout remains. Phase 7 adds dynamic VMAs that may be
installed by `mmap`:

| VA range | Purpose | Perm | Notes |
|---|---|---|---|
| `0x2000_0000 – 0x3FFF_FFFF` | mmap region (compositor + apps) | per-call | per-proc; first available 4 KB-aligned chunk picked greedily |

The `wm` process maps `/dev/fb0` once, somewhere in this range. App
processes mmap their per-window backing store (allocated by `wm` via
`mmap(fd=anon, len=w*h*4)` with the resulting fd dup'd into the app's
fd table over the wm pipe — see "IPC primitive" below).

The kernel does not use anonymous swap — anonymous `mmap` simply
allocates physical pages from the free list and maps them. They're
freed on `munmap` or process exit.

## Devices

- **Framebuffer (`0x5000_0000`)** — described above. Pure RAM-like
  region (no MMIO callback per access); register page at `0x5013_0000`
  is read-mostly.
- **Input MMIO (`0x1000_2000`)** — described above. Single combined
  device for keyboard + mouse; PLIC source 12.
- **Vsync** — synthetic, no MMIO surface; raises PLIC source 14 every
  16.67 ms of guest time.
- **CLINT, UART, block, PLIC, halt** — all unchanged from Phase 3.

## Privilege & trap model

No new privilege story. The vsync and input IRQ paths reuse the
external-interrupt route Phase 3 added (mideleg bit 9 = SEIP).

```
mideleg = (1<<1)   // SSIP — timer-forwarded     (Phase 2)
        | (1<<9)   // SEIP — supervisor external (Phase 3)
```

Boot shim additions:
- PLIC: enable bits for sources 12 (input) and 14 (vsync) at the
  S-mode hart context. `mie.MEIE` stays disabled.

`s_trap_dispatch` extends its PLIC source switch:

```
case 1:  block.isr();         // Phase 3.D
case 10: uart.drain_to_console(); // Phase 3.A
case 12: input.isr();         // NEW: Phase 7
case 14: vsync.isr();         // NEW: Phase 7
```

`input.isr()` reads up to 16 events from the MMIO ring, pushes them
onto a per-fd event queue (one queue total in Phase 7 — `/dev/input`
is single-reader and the compositor is the only reader), and wakes
any sleeper on `&input.queue`.

`vsync.isr()` increments `frame_counter`, wakes any sleeper on
`&vsync.queue`. There is at most one sleeper (the compositor); we use
`wakeup` for symmetry with the rest of the kernel.

### Trace deltas

`--trace` gains:
- `--- interrupt 9 (S-external, PLIC src 12) taken in <old>, now <new> ---`
  for input.
- `--- interrupt 9 (S-external, PLIC src 14) taken in <old>, now <new> ---`
  for vsync.
- `--- input: kbd press 0x16 ('s') ---` (similar synthetic line for
  mouse motion / button).

Frame-related traces are off by default (1 line per vsync would flood
the trace); a `--trace-vsync` flag opts in.

## Process model

### `mmap` syscall

```
sys_mmap(fd: i32, len: usize, prot: u32, flags: u32, offset: usize) -> usize
sys_munmap(addr: usize, len: usize) -> i32
```

Phase 7 supports a deliberately small subset:

- `flags & MAP_ANONYMOUS` (0x20) with `fd == -1`: allocate `len / 4096`
  fresh physical pages, install with `prot`, return start VA.
- `flags & MAP_SHARED` (0x01) with `fd >= 0`: ask the file's driver
  (only `/dev/fb0` and anonymous-fd-from-wm in Phase 7) for the page
  list, install pages.
- `MAP_PRIVATE`, `MAP_FIXED`, file-offset != 0 for non-FB files,
  `mremap`: return `-ENOSYS`.

Each successful mmap appends a VMA to the process's `vmas` list.
`fork` walks the list and reinstalls each mapping in the child (which
is how the compositor's apps inherit nothing accidentally — the
compositor never `fork`s; `init` does, and `exec` clears the parent's
mmaps the same way it clears the user pgdir).

`exit` walks the vmas list and `munmap`s each in order. Anonymous
pages go back to the free list; device-backed pages just get unmapped.

### Pipes (`pipe2`)

```
sys_pipe2(fds: [*]i32, flags: u32) -> i32
```

Allocates one `Pipe` struct (4 KB ring + read/write counters + waiter
list). Returns two fds: `fds[0]` = read end, `fds[1]` = write end. The
underlying file is a new `FileType.Pipe` variant; ordinary `read` /
`write` / `close` work on it. `flags` is reserved (must be 0).

Pipes close with reference counting; when both ends are closed, the
ring is freed back to the page allocator.

### IPC primitive (compositor protocol substrate)

The compositor and apps need a bidirectional, ordered, message-framed
channel plus a way to share fds (so apps can mmap their backing store).
We don't have Unix-domain sockets and don't want to spec them in
Phase 7.

**The minimum-viable substrate, used everywhere `wm` talks to a
client:**

1. App opens `/var/run/wm.sock` and reads it as a normal file. Its
   contents are a single decimal number: the compositor's PID.
2. App calls `pipe2(cmd_fds)` and `pipe2(evt_fds)`, then sends a
   message to the compositor saying "here are my fds":
   - The "send fds" primitive is a new syscall `sys_pin_fds(target_pid,
     fds: [*]i32, n: u32) -> i32` that puts `n` fds into a per-pid
     "inbox" slot. The compositor calls `sys_take_pinned_fds(buf, n)`
     to consume them.
   - This is ugly; it's also enough. A future phase could replace it
     with proper socketpair semantics.
3. App + compositor now have two pipes between them: `cmd` (app
   writes, wm reads) and `evt` (wm writes, app reads).
4. When the app needs a backing store, it asks `wm` to create one.
   `wm` calls `sys_mmap(MAP_ANONYMOUS, w*h*4, ...)`, gets an anonymous
   region, packages the same physical pages behind a new fd of
   `FileType.SharedMem`, and `pin_fds`-passes that fd to the app. The
   app `mmap`s it at the same size and now both sides see the same
   pixels.

`pin_fds` and `take_pinned_fds` are not Linux-syscall-shaped; they
live at numbers `5010` and `5011` for the same reason `set_fg_pid` and
`console_set_mode` did in Phase 3.

We will revisit this in a later phase (or a 7.G addendum) if the ergonomics
get too painful. For now: ~80 lines of kernel code and we move on.

### Service registry (`/var/run/wm.sock`)

Just a plain file. Contents: the compositor's PID as decimal ASCII +
`\n`. `init` writes it after `exec`-ing `/bin/wm` (it knows the PID
because `fork` returned it). `wm` removes the file on clean shutdown.

If `init` re-spawns `wm` after a crash, it overwrites the file with
the new PID. Apps that connected to the old PID see EOF on their
pipes and exit (or attempt to reconnect — `term` and `clock` are
fine to die; `calc` user state is not preserved — explicit non-goal).

## Compositor (`wm`)

### Window list

```zig
pub const Window = struct {
    id: u32,                       // monotonic, never reused within a wm instance
    owner_pid: u32,
    rect: Rect,                    // x, y, w, h in screen pixels
    backing: []align(4) u8,        // mmap'd into wm at SharedMem fd
    cmd_fd: i32,                   // wm reads, app writes
    evt_fd: i32,                   // wm writes, app reads
    title: [32]u8,
    z: i16,                        // higher = closer to user
    flags: WindowFlags,            // visible, focused, dirty
};

pub var windows: [NWIN]?Window = .{null} ** NWIN;  // NWIN = 32
```

### Frame loop

```
while true:
    // 1. drain input (non-blocking, kernel queue is bounded)
    while read(/dev/input, &ev, 16) > 0:
        update_cursor_pos(&ev)
        target = hit_test(cursor_pos, focused_window)
        send_evt_to_app(target, &ev)
    // 2. drain app cmds (non-blocking)
    for each window w:
        while read(w.cmd_fd, &msg, ...) > 0:
            apply_cmd(w, &msg)   // create / move / damage / destroy
            mark_dirty(w.rect)
    // 3. composite (skip if no dirty rects)
    if dirty_region_nonempty():
        fill_background(dirty_region)
        for w in z_order(low to high):
            blit_clip(w.backing, w.rect, dirty_region)
        draw_cursor(cursor_pos)
        clear_dirty()
    // 4. wait for next vsync
    read(/dev/vsync, &frame_no, 8)
```

The compositor never busy-waits. Steps 1–2 are non-blocking because
the kernel returns 0 when nothing's pending; step 4 blocks. Total
sleep budget per frame is ≤ 16.67 ms.

### Drawing protocol (wire format)

App → compositor (`cmd` pipe):

```
struct CmdHeader { u32 op; u32 len; }
op 1  CREATE_WINDOW    { u32 w; u32 h; u8 title[32]; }    → reply via evt: { fd, win_id }
op 2  DAMAGE           { u32 win_id; Rect rect; }
op 3  DESTROY          { u32 win_id; }
op 4  MOVE             { u32 win_id; i32 dx, dy; }
op 5  SET_TITLE        { u32 win_id; u8 title[32]; }
```

Compositor → app (`evt` pipe):

```
struct EvtHeader { u32 op; u32 len; }
op 100 WINDOW_CREATED  { u32 win_id; u32 backing_w, backing_h; }   (backing fd arrives via pin_fds)
op 101 INPUT_KEY       { u32 scancode; u32 pressed; }
op 102 INPUT_MOUSE_MOVE{ i32 x, y; }   (window-local coordinates)
op 103 INPUT_MOUSE_BTN { u32 button; u32 pressed; }
op 104 FOCUS_GAINED    { u32 win_id; }
op 105 FOCUS_LOST      { u32 win_id; }
op 106 CLOSE_REQUEST   { u32 win_id; }    (e.g. user pressed window-close)
```

All fields little-endian. No optional fields. Length is redundant
with the op (fixed for each op) — checked by the receiver as a
defensive sanity check.

### Focus + input routing

- **Mouse motion:** cursor follows; the window under the cursor is
  the "hover" target but doesn't change focus (focus only changes
  on click).
- **Mouse click:** focus moves to the window under the cursor (or
  to "no focus" if it's the background). Click event is delivered to
  the new focus.
- **Keyboard:** delivered to the focused window, full stop. ESC, F-keys,
  modifiers — all forwarded raw. The compositor reserves nothing in
  Phase 7 (no `Alt+Tab` shortcut, no `Ctrl+Q` to kill — apps do their
  own).
- **No-focus state:** keyboard events drop on the floor when no window
  is focused. Mouse clicks on background do nothing.

### Damage rectangles

Apps post damage to the compositor. The compositor accumulates the
union of all damage between vsyncs, then composites only that region
on the next frame. Bounding-rect-only (no per-pixel masks). This keeps
60 fps achievable for the demo apps even though we're CPU-only.

The cursor's old + new bounding box is added to the damage region on
every cursor move so cursor trails don't ghost.

## Rasterizer (`libgfx`)

```zig
pub const Pixel = u32;                       // 0x00RRGGBB
pub const Surface = struct { ptr: [*]u8, w: u32, h: u32, pitch: u32 };

pub fn fill(s: Surface, rect: Rect, color: Pixel) void;
pub fn blit(dst: Surface, dst_rect: Rect, src: Surface, src_xy: Point) void;
pub fn blit_clip(dst: Surface, dst_rect: Rect, clip: Rect, src: Surface, src_xy: Point) void;
pub fn draw_string(s: Surface, x: u32, y: u32, str: []const u8, fg: Pixel, bg: Pixel) void;
pub fn draw_rect(s: Surface, rect: Rect, color: Pixel) void;       // 1px outline
pub fn draw_filled_rect(s: Surface, rect: Rect, color: Pixel) void;
```

All colors are XRGB8888. No alpha blending in Phase 7 — alpha math
costs ~3× the per-pixel work and the demo apps don't need it. Every
operation is bounds-clipped to the destination surface.

`draw_string` walks one byte per glyph (256-glyph table), looks up
its 16-row × 8-col bitmap (16 bytes, MSB = leftmost pixel), and writes
fg/bg per bit. ~50 cycles per glyph at our model rate; a 80-column
line refresh is ~4 ms — fits comfortably in a vsync budget.

The font is a public-domain 8×16 bitmap. Final pick in 7.C; a strong
candidate is "Spleen 8x16" (BSD-licensed, Latin-1 coverage) or the IBM
PC BIOS code page 437 set (effectively public domain). 4 KB total.

## Demo apps

### `hello-gui` (~80 LoC)

1. `gfx_connect()` — attaches to `wm`.
2. `gfx_create_window(200, 100, "hello")` — gets a backing store.
3. Fills it with a background color, draws "hello, ccc!" centered.
4. `gfx_submit_damage(full_rect)`.
5. Loop: `gfx_recv_event()` waits for a `CLOSE_REQUEST` and exits.

No animation, no input handling. Proves the create→draw→submit path.

### `clock` (~140 LoC)

1. Same connect + create_window.
2. Each iteration:
   - `gfx_recv_event()` (blocks until something comes in or wm posts a
     periodic "frame ready" — actually the loop polls `mtime` directly
     from the snake demo's pattern: read CLINT mtime via the existing
     /dev/clint? — no, easier: clock just redraws on every tick the
     compositor sends, and the compositor sends a redraw event once
     per second. See "Open questions" below.)
   - Compute `mm:ss` from the last second's tick count.
   - Clear the digits area, draw new digits.
   - `gfx_submit_damage(digits_rect)`.

Demonstrates per-frame partial redraws.

### `calc` (~280 LoC)

A 4-function calculator with an LCD-style readout. Keyboard-only:
digits, `+ - * /`, `=`, `c` to clear, ESC to quit. Layout is two
frames: a top "display" rect + a 4×4 grid of button labels (visual
only — input is keyboard, not click). Demonstrates focused keyboard
input and small-rect damage.

### `term` (~200 LoC, plus shared console code)

Embeds the existing line-discipline console (the same code path
`/dev/console` uses). The window's backing is a 80×30 character grid
of 8×16 glyphs = 640×480 — the whole screen. Exists as a sanity check:
text apps still work in graphical mode, just inside a window.

## Testing strategy

### 1. Emulator unit tests (in 7.A)

- Framebuffer device: write at offset `(y*pitch + x*4)`, read back via
  `framebufferPtr()`; control regs return correct values; `mode = 0`
  blanks the host buffer (output becomes all-zero) without affecting
  guest reads.
- Input MMIO: push 16 events, read all 16 from the tail; ring-full
  status bit; IRQ assertion on push.
- Vsync: PLIC source 14 fires every 16,667 µs of mtime.
- `--display none` regression: existing snake e2e and FB e2e both pass
  with the same emulator binary.

### 2. Kernel unit tests (in 7.B and 7.C)

- `mmap(MAP_ANONYMOUS, 8192)` — VA returned, two pages installed,
  reads/writes hit the right physical pages.
- `mmap` of `/dev/fb0` — VA returned, write at VA `+ y*pitch + x*4`
  shows up in the FB device buffer.
- `pipe2`: 4 KB ring; write blocks when full; read blocks when empty;
  close-on-write-side returns 0 from read.
- `pin_fds` / `take_pinned_fds`: round-trip an fd between two procs.
- `input.isr`: drains all pending events and only marks
  ring-empty after consuming them.

### 3. Frame-hash e2e (in 7.D and onward)

`zig build e2e-gui-demo` runs the kernel headless (`--display none`)
with `--inject-input tests/golden/phase7/inputs.txt` and
`--golden-frames tests/golden/phase7/`. The harness checkpoints the
framebuffer at specific guest-time offsets and compares CRC32 of the
1.2 MB pixel buffer against committed `.crc` files.

Goldens are regenerated only when the test fails AND the user runs
`zig build update-goldens-phase7` (which writes the freshly captured
hashes back to `tests/golden/phase7/`). Regenerating the actual
goldens is a deliberate human action — never automatic.

We commit the CRC32, not the PNGs (PNGs are reproducible from the
emulator at any time and would clutter the repo with 1 MB blobs).

### 4. `riscv-tests` and Phase 1–5 regressions

Unchanged. The new emulator devices are additive; the existing test
ELFs don't touch them.

### 5. Web demo

A new `wm-demo.elf` is added to the `<select>` dropdown. The web
worker exports `framebufferPtr()` / `framebufferLen()` and the main
thread, on receiving a `vsync` post-message, copies the FB into an
`ImageData` and `putImageData`s it onto a `<canvas>`. Input goes the
other way: `keydown` / `mousemove` / `mousedown` post-message into the
worker, which calls `pushInputEvent(...)`.

## Project structure

```
ccc/
├── build.zig                       + kernel-gui targets, fs-img-gui, libgfx, wm, demo apps
├── src/
│   ├── emulator/
│   │   ├── devices/
│   │   │   ├── framebuffer.zig     NEW (7.A)
│   │   │   ├── input.zig           NEW (7.A)
│   │   │   └── vsync.zig           NEW (7.A)
│   │   ├── display/
│   │   │   ├── sdl.zig             NEW (7.A, native only)
│   │   │   ├── canvas.zig          NEW (7.A, wasm only)
│   │   │   └── none.zig            NEW (7.A)
│   │   ├── memory.zig              + FB region + input MMIO range + ctrl-reg dispatch
│   │   └── main.zig                + --display, --golden-frames, --inject-input
│   └── kernel/
│       ├── fb.zig                  NEW (7.B)
│       ├── input.zig               NEW (7.B)
│       ├── vsync.zig               NEW (7.B)
│       ├── pipe.zig                NEW (7.B)
│       ├── mmap.zig                NEW (7.B)
│       ├── trap.zig                + S-external switch for src 12 / 14
│       ├── kmain.zig               + devfs registration for fb0/input/vsync
│       └── user/                   stays — Phase 7 userland lives in programs/
├── programs/
│   ├── libgfx/                     NEW (7.C); shared library, linked into all gui programs
│   │   ├── pixel.zig
│   │   ├── font.zig
│   │   ├── font.bin
│   │   └── wm_client.zig
│   ├── wm/                         NEW (7.D)
│   │   ├── main.zig
│   │   ├── window.zig
│   │   ├── proto.zig
│   │   ├── cursor.zig
│   │   └── linker.ld
│   ├── hello-gui/                  NEW (7.F)
│   ├── clock/                      NEW (7.F)
│   ├── calc/                       NEW (7.F)
│   └── term/                       NEW (7.F)
├── tests/
│   ├── e2e/
│   │   ├── fb_blit.zig             NEW (7.A)
│   │   ├── mmap.zig                NEW (7.B)
│   │   ├── input_event.zig         NEW (7.B)
│   │   ├── wm_static.zig           NEW (7.D)
│   │   ├── wm_input.zig            NEW (7.E)
│   │   └── gui_demo.zig            NEW (7.F)
│   └── golden/
│       └── phase7/
│           ├── desktop_with_clock_05s.crc
│           ├── desktop_with_calc.crc
│           ├── calc_shows_15.crc
│           ├── desktop_no_calc.crc
│           └── inputs.txt
├── web/
│   ├── canvas.css                  NEW: styling for canvas mode
│   ├── canvas.js                   NEW: canvas blit + input forwarding
│   └── ... (existing files updated)
└── docs/superpowers/specs/         + this spec
```

## CLI

```
ccc [--trace] [--halt-on-trap] [--memory MB] [--disk PATH]
    [--input PATH] [--display sdl|canvas|none] [--golden-frames DIR]
    [--inject-input PATH] [--disk-latency CYC] <elf>
```

- `--display sdl`: opens an SDL2 window. macOS / Linux only. Becomes
  the default if a TTY is detected and SDL2 is linked at build time.
- `--display canvas`: wasm-only; auto-selected by the wasm entry point.
- `--display none`: no host window; the FB device still backs reads
  for headless e2e harnesses. Default for CLI builds without SDL2.
- `--golden-frames DIR`: enables frame-hash mode. After every vsync,
  if a `frame_<frame_no>.crc` file exists in DIR, hash the FB and
  compare; on mismatch, write `frame_<frame_no>.actual.png` and
  exit 1.
- `--inject-input PATH`: streams a sequence of input events from a
  text file (one event per line: `KEY 0x16 1`, `MOUSE_MOVE 320 240`,
  `MOUSE_BTN 1 1`, …). EOF is fine. Used by the e2e harness instead of
  driving SDL.

## Implementation plan decomposition

Six plans, each a separate `docs/superpowers/plans/` document:

- **7.A — Emulator: framebuffer + input + vsync + display backends.**
  `devices/framebuffer.zig`, `devices/input.zig`, `devices/vsync.zig`,
  `display/{sdl,canvas,none}.zig`. New CLI flags. Unit + integration
  tests. **No kernel changes.** Milestone: a tiny S-mode test program
  (lives in `programs/fb_test/` — same shape as Phase 3.A's
  `plic_block_test/`) writes a checkerboard pattern into the FB region,
  pushes a few synthetic input events, sleeps in `wfi` for vsync,
  takes the IRQs, claims, completes. Frame-hash matches a committed
  golden.
- **7.B — Kernel: mmap + pipes + fb/input/vsync drivers + pin_fds.**
  `mmap.zig`, `pipe.zig`, `fb.zig`, `input.zig`, `vsync.zig`. New
  syscalls. `init` is extended to register `/dev/fb0`, `/dev/input`,
  `/dev/vsync`. Milestone: `e2e-mmap` (kernel program mmaps fb0,
  writes a gradient, exits; verifier hashes the FB),
  `e2e-input-event` (kernel program reads /dev/input, asserts 4
  injected events arrive in order).
- **7.C — Userland: libgfx + bitmap font + wm_client stub.**
  `programs/libgfx/`. Pure userland — no kernel changes. Milestone:
  a tiny `gfx_test.elf` that mmaps `/dev/fb0` directly (no compositor
  yet), draws "hello, gfx!" via `draw_string`, exits. Frame-hash test.
- **7.D — Compositor: static desktop, no input routing yet.**
  `programs/wm/`. Owns FB. Single hard-coded window list (`hello-gui`
  pinned at startup). Vsync-paced frame loop. No app-side IPC yet —
  `wm` `fork`s `hello-gui` directly and shares a backing-store fd.
  Milestone: `e2e-wm-static` boots, `init` execs `wm`, frame at 1 s
  matches golden.
- **7.E — Compositor: input routing + multi-window + connect protocol.**
  `pin_fds`/`take_pinned_fds` syscalls; `wm` accepts new connections
  via `/var/run/wm.sock`. `gfx_connect`/`gfx_create_window` work end
  to end. Cursor follows mouse; click changes focus; keys go to focus.
  Milestone: `e2e-wm-input`.
- **7.F — Demo apps + web canvas + final demo.**
  `hello-gui`, `clock`, `calc`, `term`. Web demo gains a `<canvas>`
  path and wm-demo entry. Documentation pass. Milestone:
  `e2e-gui-demo` (the full Definition-of-done scripted session).

Plan boundaries are designed so 7.A is shippable as a stand-alone
"emulator can render a framebuffer" feature even if the rest of
Phase 7 stalls — same pattern as 3.A shipping before the kernel
multi-process work.

## Risks and open questions

- **"No graphics" reversal.** The original roadmap is explicit:
  no graphics. This phase contradicts that. Two ways to resolve in
  doc form: (a) replace the goal sheet line, or (b) leave it and treat
  Phase 7 as a clearly-marked addendum. Recommendation: (b), so the
  original framing stays intact and Phase 7 reads as "a deliberate
  later choice, not a goalpost slip." Open: confirm with user before
  the spec is approved.
- **Compositor IPC ergonomics.** `pin_fds` is a hack. It works for
  Phase 7 but it'll feel wrong as soon as a second app starts wanting
  to talk to a non-`wm` service. A future phase could spec a real
  Unix-domain-socket equivalent (datagram + `SCM_RIGHTS`) and
  retrofit; the cost is ~200 lines of kernel code. Open: revisit at
  the brainstorm for that follow-on phase.
- **`clock` redraw cadence.** The compositor doesn't natively
  broadcast vsync to apps (apps would have to subscribe). Two
  workable approaches: (i) every app blocks on its `evt` pipe and
  `wm` posts a `TICK` event 60 ×/s — wasteful for apps that don't
  redraw; (ii) apps poll `mtime` directly from a shared fd of
  `/dev/clint`. (ii) is more flexible but exposes a low-level clock
  to userland that we've kept hidden so far. Provisional pick:
  (i) but post `TICK` only at 1 Hz (clock's needs); high-frequency
  redraw apps can `gfx_subscribe(60Hz)` to opt in. Resolve in 7.E
  brainstorm.
- **Frame-hash flakiness.** RV32IMA execution is deterministic given
  the same input + clock. But the input ring's ISR-vs-poll race
  could in principle change which mtime tick a key arrives in. Mitigate
  by gating goldens on guest-mtime checkpoints, not host time, and
  injecting input at exact mtime values. If it still flakes, fall
  back to "structural" hashes (e.g. only hash text glyph regions, not
  the whole frame). Investigate as 7.D first issue.
- **SDL2 dependency.** Phase 1–5 are dependency-free. Adding SDL2 to
  the CLI build changes the install story on macOS (`brew install
  sdl2`). Mitigation: SDL2 is a build-time conditional (link only if
  `--display sdl` is desired); `--display none` works everywhere; the
  wasm build never sees SDL2. The `e2e-gui-demo` CI runs in `--display
  none` mode and never installs SDL2.
- **Memory budget.** FB is 1.2 MB host, 1.2 MB guest (mapped at
  `0x5000_0000`). Per-window backings: at NWIN = 32, average
  300 × 200 × 4 = 240 KB each → 7.5 MB worst case. Plus the input
  ring (256 B) and pipes (128 KB at 32 connections × 2 pipes × 4 KB
  / 2). Total under 10 MB — comfortable inside our 128 MB.
- **Mouse cursor jitter at 60 fps over UART-pump bandwidth.** The
  emulator pushes mouse events as fast as SDL polls (typically 1000+
  Hz). The kernel's input queue is bounded; events that don't fit get
  dropped (status bit set). Cursor will visibly stutter if the queue
  fills. Mitigation: input ring of 16 is enough at human speeds; if a
  burst of 30+ events drops, we lose a few cursor pixels but recover
  next frame. Acceptable.
- **Snake demo coexistence.** Snake runs as a bare M-mode program
  with no kernel — completely separate from the GUI stack. It's
  unaffected. The `<select>` dropdown gains a `wm-demo.elf` entry
  that's a different ELF entirely.
- **Build time.** Adding ~12 new Zig modules + a font blob + 4 demo
  apps roughly doubles the build graph. CI time goes from ~2 min
  to ~3.5 min per push. Tolerable.
- **Zig version churn.** Same risk as every phase. Re-pin
  `build.zig.zon` at Phase 7 start.

## Roughly what success looks like at the end of Phase 7

```
$ zig build test                           # unit tests pass (Phase 1 + 2 + 3 + 6)
$ zig build riscv-tests                    # rv32{ui,um,ua,mi,si}-p-* all pass
$ zig build e2e                            # all e2e tests pass, including:
                                           #   e2e-fb-blit, e2e-mmap, e2e-input-event,
                                           #   e2e-wm-static, e2e-wm-input, e2e-gui-demo
$ zig build kernel-gui && zig build fs-img-gui
$ zig build run -- --disk zig-out/fs.img --display sdl zig-out/bin/kernel-gui.elf

→ A 640×480 host window opens.
→ A solid background fills.
→ A "hello, ccc!" window appears in the upper-left.
→ A live clock window appears showing mm:ss, ticking once per second.
→ Mouse cursor follows the pointer.
→ Click on the clock window — it gains a 1-pixel focus border.
→ Run "wm-launch /bin/calc" from inside `term`:
    a calculator window appears, focus moves to it,
    typing "7 + 8 ="  shows "15" in its display.
→ Press ^Q in calc:
    calc window disappears,
    desktop background re-fills its rectangle,
    focus returns to clock.
→ Close the host window: SDL backend exits, ccc shuts down,
   init reaps wm, kernel halts at the next idle.

$ open https://cyyeh.github.io/ccc/web/    # in a browser
→ Pick "wm-demo" from the dropdown.
→ The same desktop renders inside a <canvas>.
→ Click into it; mouse and keyboard work.
```

…and you understand every byte from the M-mode boot shim through the
compositor's blit loop and the framebuffer's pixel format.
