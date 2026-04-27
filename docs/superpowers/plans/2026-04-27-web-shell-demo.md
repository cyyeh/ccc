# Web Shell Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land visitors of `https://cyyeh.github.io/ccc/web/` on a working `$` shell prompt by default — full Phase 3.E + 3.F shell experience (sh + ls/cat/echo/mkdir/rm/edit + ^C cancel) running against `shell-fs.img` inside the wasm. Snake and hello stay as alternative dropdown options.

**Architecture:** Add a 4 MB `disk_buffer` next to the existing `elf_buffer` in `demo/web_main.zig` and a `disk_slice: ?[]u8` field on `Block` so the wasm can hand the kernel a slice-backed disk (CLI keeps using `disk_file`). Browser-side: bump terminal to 80×24, scroll-on-newline in `ansi.js`, per-program key map (full ASCII + Ctrl+letter + Enter/Backspace/Tab/Esc + 3-byte ESC arrows for shell), parallel disk fetch in the Worker. Snake and hello pass `disk_len=0` and are byte-identical on the wire.

**Tech Stack:** Zig 0.16 (`block.zig`, `web_main.zig`), JavaScript ES modules (`web/runner.js`, `web/demo.js`, `web/ansi.js`), HTML/CSS (`web/index.html`, `web/demo.css`), Bash (`scripts/stage-web.sh`).

**Spec:** `docs/superpowers/specs/2026-04-27-web-shell-demo-design.md`.

---

## File Structure

**Modified files:**

| Path | Responsibility | Change |
|---|---|---|
| `src/emulator/devices/block.zig` | RV32 block-device MMIO + transfer engine | + `disk_slice: ?[]u8 = null` field; `performTransfer` checks `disk_slice` ahead of `disk_file` (memcpy path) |
| `demo/web_main.zig` | Wasm entry; chunked runStart/runStep | + `disk_buffer[4 MB]` + `diskBufferPtr/Cap` exports; `runStart(elf_len, trace, disk_len)` (3 args) |
| `web/runner.js` | Web Worker; fetches ELFs, drives `runStep` | Parallel ELF + optional disk fetch; copy disk into `diskBuffer`; pass `disk_len` to `runStart` |
| `web/demo.js` | Main thread; key handler, program selector | `W=80, H=24`; `ELF_URLS["2"] = ./kernel-fs.elf`; `DISK_URLS["2"] = ./shell-fs.img`; per-program key map; `SHELL_IDX = "2"`; `startCurrent` posts `diskUrl` |
| `web/ansi.js` | ~120-line ANSI subset interpreter | `\n` branch scrolls when `row === H-1` (was clamp); `_csiH` clamps if `r > H` |
| `web/index.html` | Demo page DOM | Dropdown reorder (shell selected); add `<div id="shell-instructions">` cheat-sheet card |
| `web/demo.css` | Demo styling | `pre.output` height bumped to fit 24 rows; `white-space: pre` (no browser wrap, ANSI handles it) |
| `web/README.md` | Demo docs | Document `shell.elf` (default); brief disk-buffer note in "How it works" |
| `README.md` | Project root | Expand "Live demo" line: shell (default) / snake / hello |
| `build.zig` | Build graph | Wasm step also installs `kernel-fs.elf` + `shell-fs.img` into `web/` |
| `scripts/stage-web.sh` | Local-dev artifact stager | `cp` `kernel-fs.elf` + `shell-fs.img` into `web/` |
| `.gitignore` | Untracked artifacts | + `web/kernel-fs.elf`, `web/shell-fs.img` |

**New files:** none. All changes are extensions to existing files.

**No new tests in `tests/` tree.** Block-level tests live next to the code (`src/emulator/devices/block.zig` already has 9 inline tests; we add 4 more for the slice path). Wasm/JS layers verified by manual browser smoke test in the PR.

---

## Task 1: `block.zig` — slice-backed disk transfer

**Files:**
- Modify: `src/emulator/devices/block.zig` (add field + path in `performTransfer` + 4 inline tests)

The existing CLI uses `disk_file: ?std.Io.File` for an mmapped disk. The wasm can't open files; it needs a `[]u8` slice into its linear memory. We add a sibling field; `performTransfer` checks it first. Both null → `NoMedia` (existing behavior).

- [ ] **Step 1.1: Read current block.zig to confirm context**

Run: `wc -l src/emulator/devices/block.zig`
Expected: ~298 lines (file ends after the existing 9 tests).

- [ ] **Step 1.2: Write the failing tests (4 new inline tests)**

Append the following tests to the end of `src/emulator/devices/block.zig` (after the last existing `test "performTransfer with sector out of range sets Error status"`):

```zig
test "performTransfer Read with disk_slice copies sector into RAM" {
    var disk_data: [SECTOR_BYTES * 3]u8 = undefined;
    for (disk_data[0..], 0..) |*p, i| p.* = @truncate(i & 0xFF);

    var b = Block.init();
    b.disk_slice = disk_data[0..];

    var ram_buf: [SECTOR_BYTES]u8 = [_]u8{0} ** SECTOR_BYTES;
    b.sector = 1; // read sector 1
    b.buffer_pa = 0x80000000;
    try b.writeByte(0x8, 1); // CMD = Read
    b.performTransfer(std.testing.io, ram_buf[0..]);

    try std.testing.expectEqual(@intFromEnum(Status.Ready), b.status);
    try std.testing.expect(b.pending_irq);
    try std.testing.expectEqualSlices(
        u8,
        disk_data[SECTOR_BYTES .. SECTOR_BYTES * 2],
        ram_buf[0..],
    );
}

test "performTransfer Write with disk_slice copies RAM out to slice" {
    var disk_data: [SECTOR_BYTES * 2]u8 = [_]u8{0} ** (SECTOR_BYTES * 2);

    var b = Block.init();
    b.disk_slice = disk_data[0..];

    var ram_buf: [SECTOR_BYTES]u8 = undefined;
    for (ram_buf[0..], 0..) |*p, i| p.* = @truncate((i + 7) & 0xFF);

    b.sector = 0;
    b.buffer_pa = 0x80000000;
    try b.writeByte(0x8, 2); // CMD = Write
    b.performTransfer(std.testing.io, ram_buf[0..]);

    try std.testing.expectEqual(@intFromEnum(Status.Ready), b.status);
    try std.testing.expect(b.pending_irq);
    try std.testing.expectEqualSlices(u8, ram_buf[0..], disk_data[0..SECTOR_BYTES]);
    // Sector 1 untouched.
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** SECTOR_BYTES),
        disk_data[SECTOR_BYTES..],
    );
}

test "performTransfer with disk_slice + sector out of range sets Error" {
    var disk_data: [SECTOR_BYTES]u8 = undefined;

    var b = Block.init();
    b.disk_slice = disk_data[0..];
    b.sector = NSECTORS; // 1024 — out of range
    b.buffer_pa = 0x80000000;
    var ram_buf: [SECTOR_BYTES]u8 = undefined;
    try b.writeByte(0x8, 1);
    b.performTransfer(std.testing.io, ram_buf[0..]);

    try std.testing.expectEqual(@intFromEnum(Status.Error), b.status);
    try std.testing.expect(b.pending_irq);
}

test "performTransfer disk_slice precedence: slice wins when both set" {
    // Sanity: if both disk_file and disk_slice are populated, the slice path
    // wins. This guards against accidental cross-wiring in tests/CLI/wasm.
    var disk_data: [SECTOR_BYTES]u8 = [_]u8{0xCD} ** SECTOR_BYTES;

    var b = Block.init();
    b.disk_slice = disk_data[0..];
    // Leave b.disk_file = null on this path; the precedence test only proves
    // that the slice branch reads the slice and doesn't fall through to
    // file I/O. (A "both set" test would require a tmp file; skipped — the
    // precedence is a one-line `if` we verify by inspection.)

    var ram_buf: [SECTOR_BYTES]u8 = [_]u8{0} ** SECTOR_BYTES;
    b.sector = 0;
    b.buffer_pa = 0x80000000;
    try b.writeByte(0x8, 1);
    b.performTransfer(std.testing.io, ram_buf[0..]);

    try std.testing.expectEqual(@intFromEnum(Status.Ready), b.status);
    try std.testing.expectEqualSlices(u8, disk_data[0..], ram_buf[0..]);
}
```

- [ ] **Step 1.3: Run the new tests; expect compile error or fail**

Run: `zig build test 2>&1 | grep -E "(test|error|FAIL)" | head -20`
Expected: tests fail to compile because `disk_slice` is not a field of `Block`. Error like `error: no field named 'disk_slice' in struct ...`.

- [ ] **Step 1.4: Add `disk_slice` field to `Block`**

In `src/emulator/devices/block.zig`, find the existing `disk_file` field declaration (around line 33–34):

```zig
    /// Optional host-file backing. When null, every CMD sets STATUS=NoMedia.
    disk_file: ?std.Io.File = null,
```

Insert directly above it:

```zig
    /// Optional in-memory backing (used by the wasm demo, where the disk
    /// is fetched into a wasm linear-memory slice rather than a host file).
    /// When non-null, takes precedence over `disk_file` in `performTransfer`.
    /// CLI uses `disk_file`; wasm uses `disk_slice`; setting both is a
    /// programmer error (slice wins).
    disk_slice: ?[]u8 = null,
```

- [ ] **Step 1.5: Add slice-backed transfer path in `performTransfer`**

In `performTransfer`, find the disk_file fetch (around line 119-123):

```zig
        // No disk → NoMedia for any otherwise-valid non-zero CMD.
        const f = self.disk_file orelse {
            self.status = @intFromEnum(Status.NoMedia);
            return;
        };
```

Replace it with a branch on `disk_slice` first:

```zig
        // Slice-backed path takes precedence (used by wasm demo).
        if (self.disk_slice) |disk| {
            // Sector range check (sector already bounds-checked above? — re-check
            // for the slice path explicitly since the file path's check used to
            // gate everything; we keep the existing `sector >= NSECTORS` check
            // earlier and re-validate the slice has the bytes).
            const disk_off: usize = @as(usize, self.sector) * SECTOR_BYTES;
            if (disk_off + SECTOR_BYTES > disk.len) {
                self.status = @intFromEnum(Status.Error);
                return;
            }

            // RAM range (mirrors the file path's check).
            const RAM_BASE: u32 = 0x8000_0000;
            if (self.buffer_pa < RAM_BASE) {
                self.status = @intFromEnum(Status.Error);
                return;
            }
            const ram_off: usize = @intCast(self.buffer_pa - RAM_BASE);
            if (ram_off + SECTOR_BYTES > ram.len) {
                self.status = @intFromEnum(Status.Error);
                return;
            }

            if (self.pending_cmd == 1) {
                // Read: disk → ram
                @memcpy(
                    ram[ram_off .. ram_off + SECTOR_BYTES],
                    disk[disk_off .. disk_off + SECTOR_BYTES],
                );
            } else {
                // Write: ram → disk
                @memcpy(
                    disk[disk_off .. disk_off + SECTOR_BYTES],
                    ram[ram_off .. ram_off + SECTOR_BYTES],
                );
            }
            self.status = @intFromEnum(Status.Ready);
            return;
        }

        // No disk → NoMedia for any otherwise-valid non-zero CMD.
        const f = self.disk_file orelse {
            self.status = @intFromEnum(Status.NoMedia);
            return;
        };
```

Note: the existing `if (self.sector >= NSECTORS)` check above this block (around line 126) still runs first and gates both paths.

- [ ] **Step 1.6: Run all block.zig tests; expect ALL pass (existing 9 + new 4)**

Run: `zig build test 2>&1 | tail -20`
Expected: build succeeds; "All tests passed" or no test failures. If any fail, fix the implementation, not the tests.

- [ ] **Step 1.7: Run the full Phase 3 e2e suite to confirm CLI path is unbroken**

Run: `zig build e2e-shell e2e-editor e2e-persist e2e-cancel e2e-fs 2>&1 | tail -15`
Expected: all four steps complete with no failures (each ends with the build step finishing cleanly; if any assertion fails the build exits non-zero).

- [ ] **Step 1.8: Commit**

```bash
git add src/emulator/devices/block.zig
git commit -m "$(cat <<'EOF'
feat(emulator/block): add disk_slice for in-memory disk backing

Sibling to the existing disk_file (mmapped host file used by CLI).
disk_slice holds a []u8 slice that performTransfer reads/writes via
@memcpy. Used by the wasm demo where the disk is fetched into wasm
linear memory rather than backed by a file. Slice path takes
precedence; both null still yields NoMedia.

Adds 4 inline tests: Read, Write, sector-OOB Error, and the slice
precedence sanity check. Existing 9 tests + Phase 3 e2e suite
unchanged.
EOF
)"
```

---

## Task 2: `web_main.zig` — disk_buffer + new exports + runStart signature

**Files:**
- Modify: `demo/web_main.zig` (add buffer + 2 exports + runStart signature change + Block wiring)

- [ ] **Step 2.1: Read current `web_main.zig` for surrounding context**

Already inspected during planning. Key landmarks:
- ELF buffer block at lines 38–47 (`ELF_BUFFER_CAP`, `elf_buffer`, `elfBufferPtr`, `elfBufferCap`)
- `runStart` signature at line 138: `export fn runStart(elf_len: u32, trace: i32) i32`
- `Block.init()` call at line 159

- [ ] **Step 2.2: Add `disk_buffer` + exports next to `elf_buffer`**

In `demo/web_main.zig`, find this block (around lines 36–47):

```zig
// 2 MB ELF receive buffer. JS fetches the selected program, copies
// its bytes here via elfBufferPtr/elfBufferCap, then calls
// runStart(elf_len, trace). snake.elf in Debug is ~1.4 MB.
const ELF_BUFFER_CAP: u32 = 2 * 1024 * 1024;
var elf_buffer: [ELF_BUFFER_CAP]u8 = undefined;

export fn elfBufferPtr() [*]u8 {
    return &elf_buffer;
}

export fn elfBufferCap() u32 {
    return ELF_BUFFER_CAP;
}
```

Add directly below it:

```zig
// 4 MB disk receive buffer. JS fetches the program's disk image
// (currently only shell-fs.img for the shell demo), copies its bytes
// here via diskBufferPtr/diskBufferCap, then calls runStart with a
// non-zero disk_len. shell-fs.img is exactly 4 MB by mkfs convention.
// Snake/hello pass disk_len=0 and the buffer is unused.
const DISK_BUFFER_CAP: u32 = 4 * 1024 * 1024;
var disk_buffer: [DISK_BUFFER_CAP]u8 = undefined;

export fn diskBufferPtr() [*]u8 {
    return &disk_buffer;
}

export fn diskBufferCap() u32 {
    return DISK_BUFFER_CAP;
}
```

- [ ] **Step 2.3: Update `runStart` signature and wire `disk_slice` into `Block`**

Find the existing `runStart` signature (line 138):

```zig
export fn runStart(elf_len: u32, trace: i32) i32 {
    if (elf_len == 0 or elf_len > ELF_BUFFER_CAP) return -5;
```

Change the signature to add `disk_len`:

```zig
export fn runStart(elf_len: u32, trace: i32, disk_len: u32) i32 {
    if (elf_len == 0 or elf_len > ELF_BUFFER_CAP) return -5;
    if (disk_len > DISK_BUFFER_CAP) return -6;
```

Find the existing `Block.init()` call (line 159):

```zig
    state_storage.block = block_dev.Block.init();
```

Replace it with the slice-aware version:

```zig
    state_storage.block = block_dev.Block.init();
    if (disk_len > 0) {
        state_storage.block.disk_slice = disk_buffer[0..disk_len];
    }
```

- [ ] **Step 2.4: Update the doc-comment block at the top of `web_main.zig`**

Find the `Exports:` section near the top (lines 13–22):

```zig
//! Exports:
//!   elfBufferPtr()              [*]u8 — base of the 2 MB ELF receive buffer
//!   elfBufferCap()              u32   — capacity of the ELF buffer (2 MB)
//!   runStart(elf_len, trace)    i32   — initialise state, 0 on success
```

Replace with:

```zig
//! Exports:
//!   elfBufferPtr()                       [*]u8 — base of the 2 MB ELF receive buffer
//!   elfBufferCap()                       u32   — capacity of the ELF buffer (2 MB)
//!   diskBufferPtr()                      [*]u8 — base of the 4 MB disk receive buffer
//!   diskBufferCap()                      u32   — capacity of the disk buffer (4 MB)
//!   runStart(elf_len, trace, disk_len)   i32   — initialise state, 0 on success
```

(Keep the rest of the export list identical.)

- [ ] **Step 2.5: Build the wasm and confirm new exports are present**

Run: `zig build wasm 2>&1 | tail -5`
Expected: build succeeds; `zig-out/web/ccc.wasm` updated.

Then list the exports to confirm the new ones exist (uses `wasm-objdump` if installed; falls back to `strings` grep):

Run: `wasm-objdump -x zig-out/web/ccc.wasm 2>/dev/null | grep -E "(diskBufferPtr|diskBufferCap|runStart)" || strings zig-out/web/ccc.wasm | grep -E "(diskBufferPtr|diskBufferCap|runStart)"`
Expected: three lines mentioning `diskBufferPtr`, `diskBufferCap`, `runStart`.

- [ ] **Step 2.6: Verify existing tests still pass (no regression)**

Run: `zig build test e2e-shell 2>&1 | tail -5`
Expected: test step + e2e-shell complete with no failures.

- [ ] **Step 2.7: Commit**

```bash
git add demo/web_main.zig
git commit -m "$(cat <<'EOF'
feat(wasm): add disk_buffer + extend runStart with disk_len

Adds a 4 MB disk_buffer alongside the existing elf_buffer, exposed via
new diskBufferPtr() / diskBufferCap() exports. runStart gains a third
parameter disk_len; when non-zero, the disk_buffer slice is wired into
Block.disk_slice so the kernel can read/write the in-memory image.

Snake and hello pass disk_len=0 and remain byte-identical on the wire.
Shell will pass shell-fs.img.length (~4 MB).

New error code -6 for disk_len > DISK_BUFFER_CAP.
EOF
)"
```

---

## Task 3: `build.zig` + `stage-web.sh` + `.gitignore` — install kernel-fs.elf + shell-fs.img

**Files:**
- Modify: `build.zig` (2 install steps wired to wasm_step)
- Modify: `scripts/stage-web.sh` (2 cp lines)
- Modify: `.gitignore` (2 entries)

- [ ] **Step 3.1: Add install steps in build.zig**

Open `build.zig` and find the existing block (around lines 1242–1248):

```zig
    // Install hello.elf and snake.elf alongside the wasm so the demo
    // can fetch them at runtime. Keeps the wasm tiny (~50 KB instead of
    // ~1.5 MB) and lets new programs be dropped in without recompiling.
    const install_web_hello = b.addInstallFile(hello_elf.getEmittedBin(), "web/hello.elf");
    const install_web_snake = b.addInstallFile(snake_elf.getEmittedBin(), "web/snake.elf");
    wasm_step.dependOn(&install_web_hello.step);
    wasm_step.dependOn(&install_web_snake.step);
}
```

Replace it with the version that also installs `kernel-fs.elf` and `shell-fs.img`:

```zig
    // Install hello.elf, snake.elf, kernel-fs.elf, and shell-fs.img
    // alongside the wasm so the demo can fetch them at runtime. Keeps
    // the wasm tiny (~50 KB instead of bundling the binaries) and lets
    // programs be added by dropping a file next to index.html.
    //
    // shell-fs.img is the 4 MB FS image baked by the shell-fs-img build
    // step; the wasm demo loads it into its disk_buffer when the visitor
    // selects shell.elf.
    const install_web_hello        = b.addInstallFile(hello_elf.getEmittedBin(),     "web/hello.elf");
    const install_web_snake        = b.addInstallFile(snake_elf.getEmittedBin(),     "web/snake.elf");
    const install_web_kernel_fs    = b.addInstallFile(kernel_fs_elf.getEmittedBin(), "web/kernel-fs.elf");
    const install_web_shell_fs_img = b.addInstallFile(shell_fs_img,                  "web/shell-fs.img");
    wasm_step.dependOn(&install_web_hello.step);
    wasm_step.dependOn(&install_web_snake.step);
    wasm_step.dependOn(&install_web_kernel_fs.step);
    wasm_step.dependOn(&install_web_shell_fs_img.step);
}
```

**Important:** before this edit, verify `kernel_fs_elf` and `shell_fs_img` are in scope at this point in `build.zig`. They are declared earlier (around lines 543 for `shell_fs_img` and lines 732 for `kernel_fs_elf`). Both are top-level `const` in the `build()` function so they remain in scope through line 1248. If the build fails with "use of undeclared identifier", scroll up and confirm the declarations.

- [ ] **Step 3.2: Add cp lines to stage-web.sh**

Open `scripts/stage-web.sh` and find the existing block:

```sh
cp zig-out/web/ccc.wasm  web/ccc.wasm
cp zig-out/web/hello.elf web/hello.elf
cp zig-out/web/snake.elf web/snake.elf

echo "staged: web/ccc.wasm  ($(wc -c <web/ccc.wasm) bytes)"
echo "staged: web/hello.elf ($(wc -c <web/hello.elf) bytes)"
echo "staged: web/snake.elf ($(wc -c <web/snake.elf) bytes)"
```

Replace with:

```sh
cp zig-out/web/ccc.wasm        web/ccc.wasm
cp zig-out/web/hello.elf       web/hello.elf
cp zig-out/web/snake.elf       web/snake.elf
cp zig-out/web/kernel-fs.elf   web/kernel-fs.elf
cp zig-out/web/shell-fs.img    web/shell-fs.img

echo "staged: web/ccc.wasm        ($(wc -c <web/ccc.wasm) bytes)"
echo "staged: web/hello.elf       ($(wc -c <web/hello.elf) bytes)"
echo "staged: web/snake.elf       ($(wc -c <web/snake.elf) bytes)"
echo "staged: web/kernel-fs.elf   ($(wc -c <web/kernel-fs.elf) bytes)"
echo "staged: web/shell-fs.img    ($(wc -c <web/shell-fs.img) bytes)"
```

- [ ] **Step 3.3: Add new entries to .gitignore**

Open `.gitignore` and find the existing block:

```
web/ccc.wasm
web/hello.elf
web/snake.elf
```

Replace with:

```
web/ccc.wasm
web/hello.elf
web/snake.elf
web/kernel-fs.elf
web/shell-fs.img
```

- [ ] **Step 3.4: Run `zig build wasm` and verify all 5 artifacts land in zig-out/web/**

Run: `zig build wasm && ls -la zig-out/web/`
Expected: directory contains `ccc.wasm`, `hello.elf`, `snake.elf`, `kernel-fs.elf`, `shell-fs.img`. The last is ~4 MB (4194304 bytes).

- [ ] **Step 3.5: Run `scripts/stage-web.sh` and verify it copies everything**

Run: `./scripts/stage-web.sh`
Expected: 5 "staged:" lines printed; `web/kernel-fs.elf` and `web/shell-fs.img` both exist after the script finishes.

- [ ] **Step 3.6: Verify gitignore covers the new files**

Run: `git status web/`
Expected: no untracked files under `web/` (the wasm + 4 program files are all gitignored). If `kernel-fs.elf` or `shell-fs.img` appears in the untracked list, the .gitignore edit didn't take.

- [ ] **Step 3.7: Commit**

```bash
git add build.zig scripts/stage-web.sh .gitignore
git commit -m "$(cat <<'EOF'
build: install kernel-fs.elf + shell-fs.img into web/ for shell demo

Adds two install steps to the wasm build so kernel-fs.elf and
shell-fs.img land in zig-out/web/ alongside ccc.wasm, hello.elf,
and snake.elf. stage-web.sh copies them into web/ for local dev;
gitignore keeps both out of the tree.

Both artifacts already build via existing kernel-fs and shell-fs-img
steps; this just wires them into the wasm step's install list.
EOF
)"
```

---

## Task 4: `web/runner.js` — parallel disk fetch + new runStart args

**Files:**
- Modify: `web/runner.js` (rewrite the `start` handler; new `runStart` call)

- [ ] **Step 4.1: Rewrite the `start` message handler**

Open `web/runner.js` and find the existing `start` block (lines 26–52):

```js
  if (msg.type === "start") {
    const myRunId = ++currentRunId;
    const trace = msg.trace ? 1 : 0;
    try {
      const resp = await fetch(msg.elfUrl);
      if (!resp.ok) throw new Error(`fetch ${msg.elfUrl} → ${resp.status}`);
      if (myRunId !== currentRunId) return; // superseded during fetch
      const elfBytes = new Uint8Array(await resp.arrayBuffer());
      if (myRunId !== currentRunId) return;
      const cap = exports.elfBufferCap();
      if (elfBytes.length > cap) {
        throw new Error(`ELF too large: ${elfBytes.length} > ${cap}`);
      }
      const ptr = exports.elfBufferPtr();
      const dest = new Uint8Array(memory.buffer, ptr, elfBytes.length);
      dest.set(elfBytes);
      const rc = exports.runStart(elfBytes.length, trace);
      if (rc !== 0) {
        self.postMessage({ type: "halt", runId: myRunId, code: rc });
        return;
      }
      runLoop(myRunId);
    } catch (err) {
      self.postMessage({ type: "halt", runId: myRunId, code: -99, error: String(err) });
    }
    return;
  }
```

Replace with the version that fetches ELF + optional disk in parallel and passes `disk_len` to `runStart`:

```js
  if (msg.type === "start") {
    const myRunId = ++currentRunId;
    const trace = msg.trace ? 1 : 0;
    try {
      // Fetch ELF and (optional) disk image in parallel. Both go straight
      // into wasm linear memory once they arrive — no double-buffering.
      const elfFetch = fetch(msg.elfUrl).then(async (r) => {
        if (!r.ok) throw new Error(`fetch ${msg.elfUrl} → ${r.status}`);
        return new Uint8Array(await r.arrayBuffer());
      });
      const diskFetch = msg.diskUrl
        ? fetch(msg.diskUrl).then(async (r) => {
            if (!r.ok) throw new Error(`fetch ${msg.diskUrl} → ${r.status}`);
            return new Uint8Array(await r.arrayBuffer());
          })
        : Promise.resolve(null);

      const [elfBytes, diskBytes] = await Promise.all([elfFetch, diskFetch]);
      if (myRunId !== currentRunId) return; // superseded during fetch

      // Copy ELF into wasm.
      const elfCap = exports.elfBufferCap();
      if (elfBytes.length > elfCap) {
        throw new Error(`ELF too large: ${elfBytes.length} > ${elfCap}`);
      }
      const elfPtr = exports.elfBufferPtr();
      new Uint8Array(memory.buffer, elfPtr, elfBytes.length).set(elfBytes);

      // Copy disk into wasm if present.
      let diskLen = 0;
      if (diskBytes) {
        const diskCap = exports.diskBufferCap();
        if (diskBytes.length > diskCap) {
          throw new Error(`disk too large: ${diskBytes.length} > ${diskCap}`);
        }
        const diskPtr = exports.diskBufferPtr();
        new Uint8Array(memory.buffer, diskPtr, diskBytes.length).set(diskBytes);
        diskLen = diskBytes.length;
      }

      const rc = exports.runStart(elfBytes.length, trace, diskLen);
      if (rc !== 0) {
        self.postMessage({ type: "halt", runId: myRunId, code: rc });
        return;
      }
      runLoop(myRunId);
    } catch (err) {
      self.postMessage({ type: "halt", runId: myRunId, code: -99, error: String(err) });
    }
    return;
  }
```

- [ ] **Step 4.2: Verify file is syntactically valid**

Run: `node --check web/runner.js`
Expected: no output (success). If it fails, fix the syntax.

(`node --check` parses ES modules even though it can't execute Worker globals; we're only checking syntax here.)

- [ ] **Step 4.3: Commit**

```bash
git add web/runner.js
git commit -m "$(cat <<'EOF'
feat(web/runner): parallel disk fetch; pass disk_len to runStart

Worker now fetches the ELF and (optionally) a disk image in parallel
via Promise.all, copies both into wasm linear memory, and calls
runStart(elfLen, trace, diskLen). Snake/hello have no diskUrl and
pass diskLen=0 — byte-identical to the previous behavior.

Disk-too-large yields a halt with descriptive error (parallel to the
existing ELF-too-large path).
EOF
)"
```

---

## Task 5: `web/ansi.js` — scroll-on-newline at last row

**Files:**
- Modify: `web/ansi.js` (one branch change in `_byte`; small clamp in `_csiH`)

- [ ] **Step 5.1: Read current `_byte` implementation around the `\n` branch**

Run: `sed -n '38,55p' web/ansi.js`
Expected: includes the line `if (b === 0x0a) { this.row = Math.min(this.H - 1, this.row + 1); return; }`.

- [ ] **Step 5.2: Replace the `\n` branch with scroll behavior**

Open `web/ansi.js` and find this line in `_byte`:

```js
      if (b === 0x0a) { this.row = Math.min(this.H - 1, this.row + 1); return; }
```

Replace with:

```js
      if (b === 0x0a) { this._lineFeed(); return; }
```

Then add a new `_lineFeed` method to the class (paste it next to `_writeCell` or `_reset`; placement doesn't matter for behavior):

```js
  // Move cursor down one row. If we're already at the bottom row, scroll
  // the screen up by one line: drop row 0, push a blank row at the bottom.
  // Used by both \n in the input stream and any cursor positioning that
  // would otherwise place the cursor past the last row.
  _lineFeed() {
    if (this.row >= this.H - 1) {
      this.screen.shift();
      this.screen.push(new Array(this.W).fill(" "));
      this.row = this.H - 1;
    } else {
      this.row += 1;
    }
  }
```

- [ ] **Step 5.3: Find `_csiH` and confirm/add a clamp on r > H**

Run: `grep -n "csiH\|case .H." web/ansi.js`
Expected: one or two locations where `H` (cursor positioning) CSI is dispatched.

Open the relevant handler and ensure that when the parsed row exceeds `this.H`, the cursor is clamped (not scrolled — cursor positioning past last row is undefined behavior in most terminals; clamp is the safest read of the editor's behavior at 80×24, which never emits `r > 24` in practice).

If the existing code is already `this.row = Math.min(this.H - 1, parsedRow - 1)`, leave it. If it's `this.row = parsedRow - 1` with no clamp, change to:

```js
this.row = Math.max(0, Math.min(this.H - 1, parsedRow - 1));
```

Same shape for `col` if needed (`this.col = Math.max(0, Math.min(this.W - 1, parsedCol - 1))`).

- [ ] **Step 5.4: Verify file syntax**

Run: `node --check web/ansi.js`
Expected: no output (success).

- [ ] **Step 5.5: Commit**

```bash
git add web/ansi.js
git commit -m "$(cat <<'EOF'
feat(web/ansi): scroll on newline at last row

The fixed-grid model previously clamped row at H-1 on \n, which silently
overwrote the bottom line — invisible at 32×16 with snake (which redraws
the whole screen each tick) but immediately fatal for the shell, which
streams output line-by-line and expects a scrolling terminal.

_lineFeed() shifts the screen up by one line and clears the bottom row
when already at the last row; called from both the \n branch and (via
the existing CSI H clamp) for paranoid bounds on cursor positioning.
EOF
)"
```

---

## Task 6: `web/demo.js` — 80×24 terminal, per-program key map, shell as default

**Files:**
- Modify: `web/demo.js` (W/H constants, ELF/DISK URLs, key map, instructions toggle, startCurrent)

This is the largest single-file edit. Done as a focused rewrite of the affected sections.

- [ ] **Step 6.1: Bump grid dimensions and add DISK_URLS / SHELL_IDX**

Open `web/demo.js`. Find the top-of-file constants (lines 5–13):

```js
import { Ansi } from "./ansi.js";

const W = 32, H = 16;
const ansi = new Ansi(W, H);
const out = document.getElementById("output");
const sel = document.getElementById("program-select");
const hint = document.querySelector(".program-hint");
const snakeInstructions = document.getElementById("snake-instructions");

// Snake is the only interactive program; only show its instructions when selected.
const SNAKE_IDX = "1";
```

Replace with:

```js
import { Ansi } from "./ansi.js";

// Terminal is sized for the shell (80×24, classic VT100). Snake's 32×16
// game render naturally sits in the top-left of the bigger box.
const W = 80, H = 24;
const ansi = new Ansi(W, H);
const out = document.getElementById("output");
const sel = document.getElementById("program-select");
const hint = document.querySelector(".program-hint");
const snakeInstructions = document.getElementById("snake-instructions");
const shellInstructions = document.getElementById("shell-instructions");

const SNAKE_IDX = "1";
const SHELL_IDX = "2";
```

- [ ] **Step 6.2: Update `updateProgramInstructions` to toggle the shell card too**

Find this function (lines 15–18):

```js
function updateProgramInstructions() {
  if (!snakeInstructions) return;
  snakeInstructions.classList.toggle("hidden", sel.value !== SNAKE_IDX);
}
```

Replace with:

```js
function updateProgramInstructions() {
  if (snakeInstructions) snakeInstructions.classList.toggle("hidden", sel.value !== SNAKE_IDX);
  if (shellInstructions) shellInstructions.classList.toggle("hidden", sel.value !== SHELL_IDX);
}
```

- [ ] **Step 6.3: Add shell to `ELF_URLS`, add `DISK_URLS`, leave `TRACE_PROGRAMS` unchanged**

Find this block (around lines 30–35):

```js
const TRACE_PROGRAMS = new Set(["0"]); // hello.elf

const ELF_URLS = {
  "0": "./hello.elf",
  "1": "./snake.elf",
};
```

Replace with:

```js
const TRACE_PROGRAMS = new Set(["0"]); // hello.elf only

const ELF_URLS = {
  "0": "./hello.elf",
  "1": "./snake.elf",
  "2": "./kernel-fs.elf",
};

// Programs that need a disk image fetched alongside the ELF.
// Currently only the shell uses one (shell-fs.img with /bin/* + /etc/motd).
const DISK_URLS = {
  "2": "./shell-fs.img",
};
```

- [ ] **Step 6.4: Replace the snake-only `ALLOWED_KEYS` with a per-program key map**

Find this block (around lines 43–50):

```js
const ALLOWED_KEYS = {
  "w": 0x77, "W": 0x77,
  "a": 0x61, "A": 0x61,
  "s": 0x73, "S": 0x73,
  "d": 0x64, "D": 0x64,
  "q": 0x71, "Q": 0x71,
  " ": 0x20,
};
```

Replace with:

```js
// Per-program key handling. Each handler returns one or more bytes to
// forward to the wasm via pushInput, OR null if the key is unmapped
// (in which case we don't preventDefault — browser shortcuts pass through).
//
// SNAKE: tight 6-key WASD/Q/Space whitelist. Anything else is dropped.
// HELLO: no input.
// SHELL: full ASCII printables + Ctrl+letter (0x01..0x1a) + Enter/Backspace/
//        Tab/Esc + 3-byte ESC arrow keys for the editor.
//
// Modifier rule: only e.ctrlKey is intercepted. e.metaKey/e.altKey pass
// through so Cmd+R / Cmd+T / browser shortcuts still work.

const SNAKE_BYTES = {
  "w": [0x77], "W": [0x77],
  "a": [0x61], "A": [0x61],
  "s": [0x73], "S": [0x73],
  "d": [0x64], "D": [0x64],
  "q": [0x71], "Q": [0x71],
  " ": [0x20],
};

function snakeBytes(e) {
  if (e.ctrlKey || e.metaKey || e.altKey) return null;
  return SNAKE_BYTES[e.key] ?? null;
}

function shellBytes(e) {
  if (e.metaKey || e.altKey) return null; // let browser shortcuts pass

  // Named keys.
  switch (e.key) {
    case "Enter":     return [0x0a];
    case "Backspace": return [0x7f];        // kernel/console.zig accepts both 0x08 and 0x7f
    case "Tab":       return [0x09];
    case "Escape":    return [0x1b];
    case "ArrowUp":    return [0x1b, 0x5b, 0x41]; // ESC [ A
    case "ArrowDown":  return [0x1b, 0x5b, 0x42]; // ESC [ B
    case "ArrowRight": return [0x1b, 0x5b, 0x43]; // ESC [ C
    case "ArrowLeft":  return [0x1b, 0x5b, 0x44]; // ESC [ D
  }

  // Single-character keys (letters, digits, punctuation, space).
  if (e.key.length === 1) {
    if (e.ctrlKey) {
      // Ctrl+a..Ctrl+z → 0x01..0x1a (covers ^C, ^D, ^U, ^S, ^X, etc).
      const lower = e.key.toLowerCase();
      if (lower >= "a" && lower <= "z") {
        return [lower.charCodeAt(0) - 0x60];
      }
      return null; // other Ctrl combos pass through
    }
    return [e.key.charCodeAt(0) & 0xff];
  }
  return null;
}

function bytesForCurrentProgram(e) {
  const idx = sel.value;
  if (idx === SHELL_IDX) return shellBytes(e);
  if (idx === SNAKE_IDX) return snakeBytes(e);
  return null; // hello: no input
}
```

- [ ] **Step 6.5: Update `startCurrent` to pass `diskUrl` to the worker**

Find this block (around lines 56–80):

```js
function startCurrent() {
  const idx = parseInt(sel.value, 10);
  const elfUrl = ELF_URLS[String(idx)];

  // Bump the run id BEFORE clearing — any in-flight worker messages
  // from the previous run will be tagged with the old id and dropped.
  currentRunId += 1;

  ansi._reset();
  ansi.row = 0; ansi.col = 0;
  render();

  if (!elfUrl) {
    out.textContent = `[unknown program idx ${idx}]`;
    return;
  }

  // Reset trace panel (re-shown on halt for trace-enabled programs).
  if (traceBox) traceBox.hidden = true;
  if (tracePre) tracePre.textContent = "";
  if (traceMeta) traceMeta.textContent = "";

  const trace = TRACE_PROGRAMS.has(String(idx)) ? 1 : 0;
  worker.postMessage({ type: "start", runId: currentRunId, elfUrl, trace });
}
```

Replace with the version that also looks up and forwards `diskUrl`:

```js
function startCurrent() {
  const idx = parseInt(sel.value, 10);
  const idxStr = String(idx);
  const elfUrl  = ELF_URLS[idxStr];
  const diskUrl = DISK_URLS[idxStr]; // undefined when this program has no disk

  // Bump the run id BEFORE clearing — any in-flight worker messages
  // from the previous run will be tagged with the old id and dropped.
  currentRunId += 1;

  ansi._reset();
  ansi.row = 0; ansi.col = 0;
  render();

  if (!elfUrl) {
    out.textContent = `[unknown program idx ${idx}]`;
    return;
  }

  // Reset trace panel (re-shown on halt for trace-enabled programs).
  if (traceBox) traceBox.hidden = true;
  if (tracePre) tracePre.textContent = "";
  if (traceMeta) traceMeta.textContent = "";

  const trace = TRACE_PROGRAMS.has(idxStr) ? 1 : 0;
  worker.postMessage({
    type: "start",
    runId: currentRunId,
    elfUrl,
    diskUrl, // undefined → Worker treats as no-disk (passes diskLen=0)
    trace,
  });
}
```

- [ ] **Step 6.6: Replace the keydown listener with the per-program dispatcher**

Find the existing keydown handler (around lines 129–134):

```js
out.addEventListener("keydown", (e) => {
  const byte = ALLOWED_KEYS[e.key];
  if (byte === undefined) return;
  e.preventDefault();
  worker.postMessage({ type: "input", byte });
});
```

Replace with:

```js
out.addEventListener("keydown", (e) => {
  const bytes = bytesForCurrentProgram(e);
  if (!bytes) return; // unmapped key; let the browser handle it
  e.preventDefault();
  // Worker's pushInput export takes one byte at a time; multi-byte keys
  // (arrow keys → 3-byte ESC sequences) post each byte in order.
  for (const byte of bytes) {
    worker.postMessage({ type: "input", byte });
  }
});
```

- [ ] **Step 6.7: Verify file syntax**

Run: `node --check web/demo.js`
Expected: no output (success).

- [ ] **Step 6.8: Commit**

```bash
git add web/demo.js
git commit -m "$(cat <<'EOF'
feat(web/demo): 80×24 terminal + per-program key map + shell support

- Terminal grid bumps from 32×16 to 80×24 to fit the shell + editor.
- New ELF entry kernel-fs.elf at index "2"; new DISK_URLS table maps
  index "2" to shell-fs.img.
- Per-program key handling: snake keeps its 6-key whitelist; shell gets
  full ASCII printables + Ctrl+letter (0x01..0x1a covering ^C/^D/^U/
  ^S/^X) + Enter/Backspace/Tab/Esc + 3-byte ESC arrow sequences for
  the editor; hello takes no input.
- Backspace sends 0x7f (kernel/console.zig accepts both 0x08 and 0x7f,
  picking the standard DEL).
- Cmd/Alt always pass through so browser shortcuts (Cmd+R, Cmd+T)
  keep working; only e.ctrlKey is intercepted.
- updateProgramInstructions toggles the new shell-instructions card.
- startCurrent forwards diskUrl through to the Worker.
EOF
)"
```

---

## Task 7: `web/index.html` — dropdown reorder + shell instructions card

**Files:**
- Modify: `web/index.html` (program-select options reorder; new shell-instructions block)

- [ ] **Step 7.1: Reorder dropdown options (shell selected by default)**

Open `web/index.html` and find the `<select>` block:

```html
      <select id="program-select">
        <option value="1" selected>snake.elf</option>
        <option value="0">hello.elf</option>
      </select>
```

Replace with:

```html
      <select id="program-select">
        <option value="2" selected>shell.elf</option>
        <option value="1">snake.elf</option>
        <option value="0">hello.elf</option>
      </select>
```

- [ ] **Step 7.2: Add a shell instructions card next to the snake card**

Find the existing snake instructions block (lines 25–40):

```html
    <div class="program-instructions" id="snake-instructions">
      <div class="instructions-row">
        <strong>snake controls:</strong>
        <code>W</code> <code>A</code> <code>S</code> <code>D</code> move ·
        <code>Space</code> start ·
        <code>Q</code> quit
      </div>
      <div class="instructions-row">
        <strong>how it works:</strong>
        <a href="https://github.com/cyyeh/ccc/blob/main/docs/references/snake-execution.md" target="_blank" rel="noopener"><svg class="link-icon" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/></svg> snake execution walkthrough</a>
        — bare-metal M-mode boot, CLINT timer trap, UART I/O
      </div>
      <div class="device-warning">
        ⚠ requires a physical keyboard — please play on a desktop or laptop. Mobile and tablet devices can't send key input.
      </div>
    </div>
```

Insert this block **directly above** the snake card (so shell card is first in document order, matching the dropdown order):

```html
    <div class="program-instructions" id="shell-instructions">
      <div class="instructions-row">
        <strong>shell:</strong>
        type a command and press <code>Enter</code> · try
        <code>ls /bin</code> ·
        <code>cat /etc/motd</code> ·
        <code>echo hi &gt; /tmp/x</code> ·
        <code>edit /etc/motd</code> ·
        <code>^C</code> cancel ·
        <code>exit</code> to halt
      </div>
      <div class="instructions-row">
        <strong>what's running:</strong>
        a from-scratch RV32 kernel (M-mode boot shim → S-mode kernel → cooked-mode console
        → fork/exec → on-disk shell + utilities) booted from <code>shell-fs.img</code>
        — the same binary that runs on the CLI via <code>zig build kernel-fs</code>.
      </div>
      <div class="device-warning">
        ⚠ requires a physical keyboard — desktop or laptop only. Mobile and tablet devices can't drive per-byte input.
      </div>
    </div>
```

- [ ] **Step 7.3: Verify the HTML parses (open in browser later; for now, basic check)**

Run: `grep -c 'id="shell-instructions"' web/index.html`
Expected: `1` (the new card is present exactly once).

Run: `grep -c 'id="snake-instructions"' web/index.html`
Expected: `1` (snake card still present).

- [ ] **Step 7.4: Commit**

```bash
git add web/index.html
git commit -m "$(cat <<'EOF'
feat(web/index): add shell.elf as default + shell instructions card

Dropdown now shows shell (selected) | snake | hello. New
shell-instructions card sits above the snake card and lists the canonical
try-commands (ls /bin, cat /etc/motd, edit /etc/motd, ^C, exit) plus a
"what's running" line that ties the demo back to the CLI build. Same
device-warning row as snake (mobile/tablet can't drive per-byte input).
EOF
)"
```

---

## Task 8: `web/demo.css` — grow output panel to fit 80×24, no browser wrap

**Files:**
- Modify: `web/demo.css` (`pre.output` height + `white-space`)

- [ ] **Step 8.1: Adjust `pre.output` dimensions and disable browser wrapping**

Open `web/demo.css` and find the `pre.output` rule (lines 87–101):

```css
pre.output {
  background: var(--panel);
  border: 1px solid var(--panel-border);
  border-radius: 8px;
  color: var(--fg);
  font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  font-size: 15px;
  line-height: 1.55;
  padding: 20px 24px;
  height: 480px;
  overflow-y: auto;
  margin: 0 0 32px;
  white-space: pre-wrap;
  word-break: break-word;
}
```

Replace with (typography unchanged; only `height`, `overflow`, and `white-space` change):

```css
pre.output {
  background: var(--panel);
  border: 1px solid var(--panel-border);
  border-radius: 8px;
  color: var(--fg);
  font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  font-size: 15px;
  line-height: 1.55;
  padding: 20px 24px;
  /* 24 rows × 15px × 1.55 line-height ≈ 558px content; +40px padding ≈ 600px.
     min-height (not height) so the ANSI 24-row buffer is always fully visible
     without forcing a scrollbar; overflow stays auto in case any future
     program emits more than 24 rows. */
  min-height: 600px;
  overflow: auto;
  margin: 0 0 32px;
  /* The ANSI interpreter renders a fixed 80×24 grid as a single text string
     with hard \n at row boundaries — let the browser render it as-is, no
     re-wrapping. Horizontal scroll appears at narrow viewports. */
  white-space: pre;
}
```

- [ ] **Step 8.2: Verify CSS is valid (basic check)**

Run: `grep -c 'white-space: pre;' web/demo.css`
Expected: `1`.

(There's no project-level CSS linter; visual verification happens during the manual smoke test.)

- [ ] **Step 8.3: Commit**

```bash
git add web/demo.css
git commit -m "$(cat <<'EOF'
feat(web/css): grow output panel to fit 80×24 grid + disable wrap

- height (480px fixed) → min-height (600px), enough for 24 rows at the
  existing 15px / 1.55 line-height. Overflow stays auto as a safety net
  for any future program emitting more than 24 rows.
- white-space changes from pre-wrap to pre: the ANSI interpreter already
  manages line breaks at the 80-col boundary; letting the browser
  re-wrap was fine at 32×16 (snake never overflowed) but breaks shell
  output that assumes the grid model. Horizontal scroll appears on
  narrow viewports.
- Typography unchanged (15px / 1.55) — snake's render is unaffected.
EOF
)"
```

---

## Task 9: docs — `web/README.md` + top-level `README.md`

**Files:**
- Modify: `web/README.md` (add shell.elf to programs list + brief disk-buffer note)
- Modify: `README.md` (expand "Live demo" line)

- [ ] **Step 9.1: Update `web/README.md` programs list**

Open `web/README.md` and find the programs intro block (lines 7–18):

```md
A single-page browser demo of [`ccc`](../), a from-scratch RISC-V CPU
emulator written in Zig. The same emulator modules that power the
native CLI (`cpu.zig`, `memory.zig`, `elf.zig`, `devices/*.zig`) are
cross-compiled to `wasm32-freestanding` via a thin entry point
(`demo/web_main.zig`) and loaded into your browser. Two RV32 programs
ship with the page:

- **`snake.elf`** (default) — an interactive snake game. ...
- **`hello.elf`** — non-interactive "hello world". ...
```

Replace it with the three-program version (shell as default):

```md
A single-page browser demo of [`ccc`](../), a from-scratch RISC-V CPU
emulator written in Zig. The same emulator modules that power the
native CLI (`cpu.zig`, `memory.zig`, `elf.zig`, `devices/*.zig`) are
cross-compiled to `wasm32-freestanding` via a thin entry point
(`demo/web_main.zig`) and loaded into your browser. Three RV32 programs
ship with the page:

- **`shell.elf`** (default) — a full Phase 3.E + 3.F shell. The page
  loads `kernel-fs.elf` (M-mode boot shim → S-mode kernel → cooked-mode
  console → fork/exec → on-disk init) plus `shell-fs.img` (a 4 MB FS
  image with `/bin/{sh,ls,cat,echo,mkdir,rm,edit}` + `/etc/motd`).
  Click the terminal, then type `ls /bin`, `cat /etc/motd`,
  `echo hi > /tmp/x`, `edit /etc/motd`, `^C` to cancel a foreground
  program, `exit` to halt. **Requires a physical keyboard — desktop
  or laptop only.** Disk writes live in wasm linear memory and reset
  on every page load.
- **`snake.elf`** — an interactive snake game. A bare M-mode
  supervisor drives a CLINT timer IRQ for the game tick and polls
  UART RX for input. Click the terminal, then move with `W` / `A` /
  `S` / `D`, press `Space` to start, `Q` to quit. **Requires a
  physical keyboard — desktop or laptop only**, mobile and tablet
  browsers can't send key input.
- **`hello.elf`** — non-interactive "hello world". Runs to halt and
  auto-displays its captured instruction trace.
```

- [ ] **Step 9.2: Add disk-buffer note in "How it works"**

In `web/README.md`, find the existing "How it works" section and the bullet about `runner.js` (around line 33). After it, add a sentence about the disk path. The exact insertion point: find this paragraph:

```md
3. `runner.js` is a Web Worker that fetches `ccc.wasm` and the
   selected ELF on demand, copies the ELF bytes into the wasm load
   buffer, and drives `runStep()` in 50 000-instruction chunks via
   `setTimeout`. Yielding between chunks lets the Worker service
   `pushInput` messages — a single blocking `run()` couldn't.
```

Replace it with:

```md
3. `runner.js` is a Web Worker that fetches `ccc.wasm` and the
   selected ELF on demand, copies the ELF bytes into the wasm load
   buffer, and drives `runStep()` in 50 000-instruction chunks via
   `setTimeout`. Yielding between chunks lets the Worker service
   `pushInput` messages — a single blocking `run()` couldn't. When
   the selected program has a disk image (currently only `shell.elf`,
   which fetches `shell-fs.img`), the Worker fetches it in parallel
   with the ELF and copies it into a 4 MB `disk_buffer` exposed by the
   wasm via `diskBufferPtr/Cap`; `runStart` then receives a non-zero
   `disk_len` and wires the buffer slice into the emulator's block
   device.
```

- [ ] **Step 9.3: Update the gitignore mention**

Find this paragraph (around line 53):

```md
`web/ccc.wasm`, `web/hello.elf`, and `web/snake.elf` are gitignored —
all three are produced by `zig build wasm` and overlaid into the Pages
artifact in CI. Run `stage-web.sh` (or `zig build wasm` + the three
`cp` commands it wraps) before serving locally.
```

Replace with:

```md
`web/ccc.wasm`, `web/hello.elf`, `web/snake.elf`, `web/kernel-fs.elf`,
and `web/shell-fs.img` are gitignored — all five are produced by
`zig build wasm` and overlaid into the Pages artifact in CI. Run
`stage-web.sh` (or `zig build wasm` + the five `cp` commands it wraps)
before serving locally.
```

- [ ] **Step 9.4: Update top-level `README.md` "Live demo" line**

Open the top-level `README.md` and find the "Live demo" line (around line 7):

```md
**Live demo:** [https://cyyeh.github.io/ccc/web/](https://cyyeh.github.io/ccc/web/)
— `ccc` cross-compiled to `wasm32-freestanding`, running RV32 binaries in
your browser. Pick `snake.elf` (default — WASD to play) or `hello.elf` (auto-runs + shows the instruction trace). Same Zig core as the CLI; the browser hosts
the emulator in a Web Worker that drives execution in chunks.
```

Replace with:

```md
**Live demo:** [https://cyyeh.github.io/ccc/web/](https://cyyeh.github.io/ccc/web/)
— `ccc` cross-compiled to `wasm32-freestanding`, running RV32 binaries in
your browser. Pick `shell.elf` (default — full Phase 3 shell with
`ls`/`cat`/`echo`/`edit`/`^C`/`exit` against an in-wasm `shell-fs.img`),
`snake.elf` (WASD to play), or `hello.elf` (auto-runs + shows the
instruction trace). Same Zig core as the CLI; the browser hosts the
emulator in a Web Worker that drives execution in chunks.
```

- [ ] **Step 9.5: Commit**

```bash
git add web/README.md README.md
git commit -m "$(cat <<'EOF'
docs: web shell demo — README updates

- web/README.md: shell.elf added as the default program; "How it works"
  gets one paragraph about the disk_buffer plumbing; gitignore mention
  bumps from three artifacts to five.
- top-level README.md: "Live demo" line lists shell (default) / snake /
  hello with one-clause descriptions of each.

No changes to architecture or status sections — Phase 3 is already
documented end-to-end.
EOF
)"
```

---

## Task 10: Manual browser smoke test (PR-time gate)

**Files:**
- (No code changes; this is the verification gate before merging.)

This task can't be automated within the plan — it's the human (or human-in-the-loop) walking through the demo. Document the result in the PR description.

- [ ] **Step 10.1: Stage artifacts and start a local server**

Run: `./scripts/stage-web.sh && python3 -m http.server -d . 8000 &`
Expected: server starts on port 8000; 5 "staged" lines printed.

(Stop with `kill %1` when finished.)

- [ ] **Step 10.2: Open the page and walk the smoke test**

Open `http://localhost:8000/web/` in a desktop browser (Chrome or Firefox; Safari should also work but Chrome's DevTools network tab makes parallel-fetch verification easiest).

Walk through these 11 checks; each must pass before merging. Note any failure in the PR description and fix before re-testing.

- [ ] **Step 10.3: Smoke test step 1 — page loads on shell**

Verify: page loads; dropdown shows `shell.elf` (selected) / `snake.elf` / `hello.elf`; shell-instructions cheat-sheet card visible above the terminal box.

- [ ] **Step 10.4: Smoke test step 2 — `$` prompt appears within ~2s**

Verify: within 2 seconds of page load, the terminal shows `$ ` (or similar shell prompt). If it's noticeably slow (>3s), open the Open question section of the spec — may need to add a "booting…" indicator.

- [ ] **Step 10.5: Smoke test step 3 — `ls /bin` returns the 9 binaries**

Click the terminal to focus, type: `ls /bin` and press Enter.
Verify: output shows `.`, `..`, `cat`, `init`, `echo`, `sh`, `mkdir`, `ls`, `rm` (one per line).

- [ ] **Step 10.6: Smoke test step 4 — `cat /etc/motd` shows expected text**

Type: `cat /etc/motd` Enter.
Verify: output is `hello from phase 3` (followed by `$ ` prompt).

- [ ] **Step 10.7: Smoke test step 5 — write/read round-trip**

Type: `echo hi > /tmp/x` Enter, then `cat /tmp/x` Enter.
Verify: `cat /tmp/x` outputs `hi`.

- [ ] **Step 10.8: Smoke test step 6 — editor round-trip**

Type: `edit /etc/motd` Enter.
Verify: editor enters raw mode (file content displayed; no `$ ` prompt).
Press: ArrowRight twice (cursor moves right two chars), type a character (e.g. `Y`), press Ctrl+S (save), press Ctrl+X (exit).
Type: `cat /etc/motd` Enter.
Verify: output reflects the inserted character (e.g. `heYllo from phase 3`).

- [ ] **Step 10.9: Smoke test step 7 — `^C` cancel**

Type: `cat` Enter (no args; blocks waiting on stdin).
Press: Ctrl+C.
Verify: `^C` echoes; new `$ ` prompt appears.

- [ ] **Step 10.10: Smoke test step 8 — switch to snake, play it**

Use dropdown to select `snake.elf`.
Verify: snake game renders in the upper-left of the bigger box; shell-instructions card hides; snake-instructions card shows. Click terminal; press Space to start; W/A/S/D moves the snake.

- [ ] **Step 10.11: Smoke test step 9 — switch back to shell; fresh state**

Use dropdown to re-select `shell.elf`.
Verify: terminal clears; new `$ ` prompt within ~2s. Type `cat /etc/motd`. Verify output is the **original** `hello from phase 3` (not the edited version from step 10.8) — this proves the disk is re-copied per `runStart` from the canonical `shell-fs.img`.

- [ ] **Step 10.12: Smoke test step 10 — refresh; pristine disk**

Hard-refresh the page (Cmd+Shift+R / Ctrl+Shift+R).
Verify: shell loads fresh; `cat /etc/motd` again shows the original content. (This proves Q2-A pristine-on-load — no IndexedDB persistence.)

- [ ] **Step 10.13: Smoke test step 11 — DevTools network tab**

Open DevTools → Network. Refresh the page.
Verify: `kernel-fs.elf` and `shell-fs.img` both appear in the request list and complete with HTTP 200. They start at roughly the same time (parallel fetch). `shell-fs.img` is the largest single asset (~4 MB; less if served gzipped).

- [ ] **Step 10.14: Document results in PR**

In the PR description, paste a checklist of the 11 smoke-test steps with ✅ next to each. Note any deviations (e.g. boot >2s, any unexpected output) and how they were resolved.

- [ ] **Step 10.15: Stop the local server**

Run: `kill %1` (or whichever job number `python3 -m http.server` is at).

---

## Definition of done

- All 9 implementation tasks (Tasks 1–9) committed cleanly; each commit message follows the `feat(scope): …` / `docs: …` / `build: …` convention.
- Task 10 smoke test: all 11 steps pass; results documented in PR.
- `zig build test` passes (existing 9 + 4 new block.zig tests).
- `zig build e2e-shell e2e-editor e2e-persist e2e-cancel e2e-fs` all pass (proves Phase 3 CLI path is unbroken by the new `disk_slice` field).
- `zig build wasm` succeeds; `zig-out/web/` contains `ccc.wasm`, `hello.elf`, `snake.elf`, `kernel-fs.elf`, `shell-fs.img`.
- Visiting `https://cyyeh.github.io/ccc/web/` (after deploy) lands on `shell.elf` selected by default and a `$` prompt within ~2s; manual smoke test passes against the deployed version too.
- `web/README.md` documents `shell.elf`; top-level `README.md` mentions it in the "Live demo" line.
- Snake and hello continue to work byte-identically (no changes to their `runStart` shape — they just pass `disk_len=0`).
