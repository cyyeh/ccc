# Phase 3 Plan F — Editor + persistence + final demo (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the cursor-moving `edit` userland binary that exercises the raw-mode console arm 3.E left wired-but-unexercised, add the two e2e tests Phase 3's Definition of Done still owes (`e2e-editor` and `e2e-persist`), do a trace-formatting eyeball pass over the now-complete async-IRQ path, and update README + deck so Phase 3 reads as **complete**. After this plan lands, the entire spec §Definition of Done holds end-to-end.

**Architecture:** The `edit` binary is a flat-buffer line editor in the xv6 mold: it loads the file under edit into a 16 KB static buffer, tracks a single byte-offset cursor, and on every keystroke does a full ANSI redraw (clear-screen + home + print buffer + position cursor at the byte-offset's row/col). Six keystroke classes are dispatched: ESC `[` `A`/`B`/`C`/`D` (arrow keys — up/down/left/right), printable bytes (insert at cursor, shift right), `0x08`/`0x7F` (backspace — shift left from cursor), `0x13` (`^S` save — close fd, re-open with `O_WRONLY|O_TRUNC|O_CREAT`, write buffer, close), and `0x18` (`^X` exit — `console_set_mode(0)` then `exit(0)`). Read uses `getline`-shaped one-byte-at-a-time `read(0, &b, 1)` loops; in raw mode the kernel's `console.feedByte` (already shipped in 3.E lines 78-86) appends each byte to `input.buf` and immediately wakes the reader, so the loop sees one byte per emulator idle-spin tick — perfectly paced for ESC sequences. ANSI redraw renders into fd 1 via a tiny printf-free helper that emits the escapes byte-by-byte; row/col arithmetic walks `content[0..content_len]` counting `\n`s up to the cursor offset. The two new e2e tests (`tests/e2e/editor.zig`, `tests/e2e/persist.zig`) follow the existing `tests/e2e/shell.zig` pattern: they spawn `ccc --input <fixture> --disk <image> kernel-fs.elf` and assert specific landmark substrings in the captured stdout. **Critical persistence detail:** the block device opens `--disk` `O_RDWR` (Plan 3.A), so any `bwrite` from the kernel mutates the host file in place; that's exactly the property `e2e-persist` validates by running ccc twice on a copied-to-tmp image and asserting that pass-2's `cat /etc/motd` returns whatever pass-1 wrote. Pass-1 uses the existing `echo X > /etc/motd` shell path (no editor dependency), so persistence and editor are tested independently. The `editor_input.txt` fixture is a binary file (~43 bytes) — committed verbatim despite containing `\x1b`/`\x13`/`\x18` because the rx_pump streams arbitrary bytes — that drives the canonical session: shell prompt → `edit /etc/motd` → 2× right-arrow → `Y` → `^S` → `^X` → `cat /etc/motd` (asserts `heYllo from phase 3\n`) → `exit`. The editor's full-buffer ANSI redraws will pollute stdout with intermediate buffer states, but `cat`'s post-editor output is uniquely sandwiched between the shell-echoed prompt `$ cat /etc/motd\n` and the next prompt — that's the discriminating landmark. Trace polish is a verification pass: the markers (`--- interrupt N (...) ---`, `--- block: ... ---`) are already wired across 3.A and 3.D; this plan runs `--trace` over the new editor session, eyeballs the output, and corrects any inconsistencies discovered. README and the slide deck (`index.html`) get bumped from "Plan 3.E merged, 3.F next" to "Phase 3 complete", with a new "Ch 3.F · editor + persistence" deck slide that mirrors the existing 3.A-3.E chapter structure.

**Tech Stack:** Zig 0.16.x (pinned in `build.zig.zon`); RV32 (`ReleaseSmall`) for `edit.elf`, native (`Debug`) for the e2e harnesses; pure Zig — no `std` imports inside `edit.zig` (matches the `freestanding` user-binary convention). The two e2e harnesses are full-Zig host programs that consume `std.process.Init` and use the existing `Io.File`/`std.process.spawn` APIs (same shape as `tests/e2e/shell.zig` and `tests/e2e/fs.zig`). No emulator code changes; no kernel code changes; no new syscalls (the 19 stubs in `usys.S` already cover everything `edit` needs). `mkfs.zig` is unchanged; we add `edit.elf` to the existing `shell_fs_bin_stage` so it lands at `/bin/edit` in `shell-fs.img`.

**Spec reference:** `docs/superpowers/specs/2026-04-25-phase3-multi-process-os-design.md` — Plan 3.F covers spec §Definition of done (the editor session + the `replaced again` reboot persistence demo + `^C` cancellation already proved by 3.E + new e2e tests `e2e-editor` and `e2e-persist`), §Architecture row for `edit.zig` ("cursor-moving editor (~450 lines)") and the userland LoC budget ("`edit` ~450"), §Process model "kill flag (`^C` path)" sub-section ("In raw mode, the line discipline is bypassed: every byte (including `0x03`) is delivered straight to the reader's buffer with no echo, no line-buffering, and no kill-call. The editor reads `ESC [ A/B/C/D` (arrow keys) and other control bytes this way."), §Userland row (`edit | ~450 | console_set_mode(1) on entry, console_set_mode(0) on exit; load file into a 16 KB buffer (cap); main loop reads one keystroke; arrow keys via ESC [ A/B/C/D; printable inserts at cursor; backspace deletes; ^S rewrites file; ^X exits. ANSI cursor positioning for redraws.`), §Testing strategy rows for `e2e-editor` and `e2e-persist`, §Implementation plan decomposition entry **3.F**, and §Risks "Editor's 16 KB file cap. Sized for the demo (`/etc/motd` is one line). Trivial to lift if we want to edit larger files." Plan 3.E left a small list of items deferred to 3.F (its own §"Spec items deferred to Plan 3.F"); this plan picks each one up.

**Plan 3.F scope (subset of Phase 3 spec):**

- **`edit.zig` userland binary (NEW)** — Loads file argv[1] into a 16 KB static buffer; tracks a single byte-offset cursor; switches to raw mode on entry and back to cooked on exit; dispatches arrow keys, printables, backspace, `^S`, `^X`; redraws via ANSI escapes after each keystroke. ~280 LoC (well under spec's 450-LoC budget — the spec's number assumed mode-line / status messages / multi-keystroke commands which we omit; the 3.F demo only needs the core edit-save-quit loop).

- **`tests/e2e/editor.zig` + `tests/e2e/editor_input.txt` (NEW)** — Host harness spawns `ccc --input editor_input.txt --disk <tmp-copy-of-shell-fs.img> kernel-fs.elf`, captures stdout, asserts the landmark `$ cat /etc/motd\nheYllo from phase 3\n` appears (proves editor wrote the file and `cat` read it back). Also asserts exit code 0. The fixture is committed binary; the byte sequence is documented in a comment at the top of the harness `.zig` file.

- **`tests/e2e/persist.zig` + `tests/e2e/persist_input1.txt` + `tests/e2e/persist_input2.txt` (NEW)** — Host harness copies `shell-fs.img` to a temp path, runs ccc twice (pass 1 input modifies `/etc/motd` via `echo replaced > /etc/motd`; pass 2 input runs `cat /etc/motd`), asserts pass 2's stdout contains `replaced\n` after the `$ cat /etc/motd` prompt — proving pass 1's writes survived emulator restart. Both passes are full clean shell sessions ending in `exit\n`.

- **`build.zig` (MODIFIED)** — Five additions: (1) `addUserBinary(b, "edit", ...)` plus `kernel-edit` step + install. (2) `_ = shell_fs_bin_stage.addCopyFile(edit_exe.getEmittedBin(), "edit");` so `edit.elf` lands at `/bin/edit`. (3) `editor_e2e_exe` + `editor_e2e_run` + `e2e-editor` step. (4) `persist_e2e_exe` + `persist_e2e_run` + `e2e-persist` step. (5) The plan does not change any existing kernel-build, mkfs, or e2e-*-shell wiring.

- **Trace polish (verification only)** — Run `zig build run -- --trace --input tests/e2e/editor_input.txt --disk shell-fs.img kernel-fs.elf 2>trace.log` against a built tree; eyeball trace.log for: external-interrupt markers fire on every PLIC source; block-transfer markers print sector + PA correctly; no marker is missing or duplicated. If any inconsistency is found, fix it as part of this task; otherwise the task is verification + a brief notes update in the README.

- **README.md (MODIFIED)** — Status section bumped from "Phase 3 Plan E done" to "Phase 3 — complete" with a Plan 3.F summary block (mirrors the 3.E block); build-commands table grows two rows (`kernel-edit`, `e2e-editor`, `e2e-persist`); the "Layout" section's `src/kernel/user/` listing gains `edit.zig` row.

- **index.html (MODIFIED — slide deck)** — The "Next · plan 3.f" panel (line ~1633) is replaced with a "✓ 3.F · editor + persistence" status row matching the 3.A-3.E chapter cards (line 1620-1630). A new chapter slide ("Ch 3.F · editor + persistence") sits before the "Phase 1 done · Phase 2 done · Phase 3 underway" closing slide; the closing slide's "Phase 3 · underway" tag flips to "Phase 3 · complete" and its body text gets a Plan 3.F sentence.

**Items explicitly NOT in scope for Plan 3.F:**

- No emulator code changes (Plan 3.A's PLIC + block + UART RX + rx_pump are stable).
- No new syscalls (existing 19 in `usys.S` cover everything `edit` needs — `openat`, `read`, `write`, `close`, `console_set_mode`, `exit`, plus `getpid`/`fstat` if we ever add a status line, which we don't).
- No FS journaling / crash-safe writes — accept that `kill -9 ccc` mid-`bwrite` may corrupt the image (per spec §Out of scope).
- No multi-line cursor up/down beyond the basic "scan back/forward to find row boundary, clamp column" — the demo edits a one-line file, so the up/down arms are just defensive plumbing.
- No undo / multi-buffer / search / mode-line — single buffer, no UI chrome.
- No editor support for files > 16 KB — `edit foo` on a larger file truncates silently to the cap; this is documented in the editor's top-of-file comment.
- No trace-marker additions (e.g., per-syscall markers) — the existing markers already satisfy the spec's "PLIC claim/complete shows up as synthetic marker lines" requirement.

---

## Task structure

Each task is a single bite-sized commit that leaves the tree in a working state. Within each task, steps follow the canonical TDD-ish flow: write the failing test (or stub), run it, implement, run, commit. Where a unit test is impossible (RV32 user binaries can't be unit-tested in the host harness), the task uses a `zig build` + manual `zig build run -- ...` smoke test as its verification step.

The plan is sequenced for incremental verification: after Task 1, `edit /etc/motd` boots into raw mode and exits cleanly on `^X`; after Task 2, `^S` round-trips the unchanged file; after Task 3, edits persist; after Task 4, horizontal cursor movement works; after Task 5, vertical cursor movement works; after Task 6, the e2e-editor harness asserts the canonical session; after Task 7, e2e-persist proves disk writes survive reboot; after Task 8, all unit + e2e tests + the spec's full Definition-of-Done demo pass.

---

### Task 1: Editor skeleton + build wiring (raw mode in/out, ^X exit)

**Files:**
- Create: `src/kernel/user/edit.zig`
- Modify: `build.zig` (insert `addUserBinary` for `edit`, install step, add to `shell_fs_bin_stage`)

**Goal of this task:** A binary that compiles, installs at `/bin/edit` in `shell-fs.img`, and on `edit /etc/motd` switches the console to raw mode, reads bytes one-at-a-time until it sees `^X` (0x18), then switches back to cooked mode and exits 0. No file load, no save, no rendering.

- [ ] **Step 1: Create the editor stub**

Create `src/kernel/user/edit.zig` with the entry point + raw-mode dance:

```zig
// src/kernel/user/edit.zig — Phase 3.F cursor-moving text editor.
//
// usage: edit <path>
//
// Loads <path> into a 16 KB buffer, switches the console to raw mode
// (so arrow keys arrive as ESC [ A/B/C/D and ^C / ^S / ^X are delivered
// as raw bytes), and runs a redraw-on-every-keystroke edit loop:
//
//   ESC [ A   cursor up
//   ESC [ B   cursor down
//   ESC [ C   cursor right
//   ESC [ D   cursor left
//   0x7F/0x08 backspace (delete byte before cursor)
//   0x13      ^S — save (truncate + rewrite path)
//   0x18      ^X — exit (restore cooked mode, exit 0)
//   printable insert at cursor
//
// Files larger than 16 KB are truncated silently. Saved files are
// rewritten in full via openat(O_WRONLY|O_TRUNC|O_CREAT) — consistent
// with editors of this shape.

const ulib = @import("lib/ulib.zig");
const uprintf = @import("lib/uprintf.zig");

const CONTENT_CAP: u32 = 16 * 1024;

var content: [CONTENT_CAP]u8 = undefined;
var content_len: u32 = 0;
var cursor: u32 = 0;

const PATH_MAX: u32 = 256;
var path_buf: [PATH_MAX]u8 = undefined;

fn enterRaw() void {
    _ = ulib.console_set_mode(ulib.CONSOLE_RAW);
}

fn leaveRaw() void {
    _ = ulib.console_set_mode(ulib.CONSOLE_COOKED);
}

export fn main(argc: u32, argv: [*]const [*:0]const u8) i32 {
    if (argc < 2) {
        uprintf.printf(2, "usage: edit <path>\n", &.{});
        return 1;
    }

    enterRaw();
    defer leaveRaw();

    while (true) {
        var b: [1]u8 = .{0};
        const got = ulib.read(0, &b, 1);
        if (got <= 0) return 0;
        if (b[0] == 0x18) return 0; // ^X
    }
}
```

- [ ] **Step 2: Wire `addUserBinary` for edit in `build.zig`**

Find the block of `addUserBinary` calls (roughly `build.zig:459-487`, just before the `mkfs_exe` block at line 490). Insert the `edit` block immediately after the `sh_exe` block:

```zig
    const edit_exe = addUserBinary(b, "edit", "src/kernel/user/edit.zig", rv_target, .ReleaseSmall);
    const install_edit = b.addInstallFile(edit_exe.getEmittedBin(), "edit.elf");
    const kernel_edit_step = b.step("kernel-edit", "Build edit.elf (Phase 3.F)");
    kernel_edit_step.dependOn(&install_edit.step);
```

- [ ] **Step 3: Add `edit.elf` to `shell_fs_bin_stage`**

Find the `shell_fs_bin_stage` block (`build.zig:522-529`). Add one line after the `rm` entry:

```zig
    _ = shell_fs_bin_stage.addCopyFile(edit_exe.getEmittedBin(), "edit");
```

- [ ] **Step 4: Build the editor binary and confirm install**

Run: `zig build kernel-edit`
Expected: `zig-out/bin/edit.elf` exists, no compile errors.
Verify: `ls -la zig-out/bin/edit.elf`

- [ ] **Step 5: Build `shell-fs-img` and confirm `edit.elf` was staged**

Run: `zig build shell-fs-img`
Expected: completes without error; `zig-out/shell-fs.img` exists.

- [ ] **Step 6: Smoke-test edit /etc/motd in interactive shell**

Run: `zig build && zig build kernel-fs && printf 'edit /etc/motd\n\x18exit\n' > /tmp/edit_smoke_in && zig build run -- --input /tmp/edit_smoke_in --disk zig-out/shell-fs.img zig-out/bin/kernel-fs.elf 2>&1 | head -30`

Expected: shell prompts, runs `edit /etc/motd`, returns to shell prompt (because `^X` exits the editor cleanly and console is back in cooked mode so `exit\n` works), prints `ticks observed: N`, exits 0.

If the second prompt doesn't appear, the cooked-mode restore failed — re-check `defer leaveRaw()`.

- [ ] **Step 7: Confirm e2e-shell still passes**

Run: `zig build e2e-shell`
Expected: PASS (Plan 3.E test unchanged).

- [ ] **Step 8: Confirm unit tests still pass**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 9: Commit**

```bash
git add src/kernel/user/edit.zig build.zig
git commit -m "$(cat <<'EOF'
Phase 3.F Task 1: edit binary skeleton + build wiring

edit.zig is a stub today: enter raw mode, read bytes, exit on ^X,
restore cooked mode. No file load, no save, no rendering yet — but
it proves the raw-mode in/out dance works end-to-end against the
3.E console line discipline.
EOF
)"
```

---

### Task 2: File load + ^S save (no edits yet)

**Files:**
- Modify: `src/kernel/user/edit.zig`

**Goal:** `edit /etc/motd` loads the file's contents into `content[0..content_len]` (silently truncating if > 16 KB), and `^S` writes the buffer back to the same path via `openat(path, O_WRONLY|O_TRUNC|O_CREAT)`. With no insert/delete logic yet, save is a no-op round-trip.

- [ ] **Step 1: Add file load on entry**

In `src/kernel/user/edit.zig`, after the `enterRaw();` call inside `main`, insert a load block. Replace the body of `main` after the argc check:

```zig
    // Save path for ^S.
    const path = argv[1];
    var i: u32 = 0;
    while (path[i] != 0 and i + 1 < PATH_MAX) : (i += 1) path_buf[i] = path[i];
    path_buf[i] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf[0]);

    // Load file (silently truncate if > CONTENT_CAP).
    const fd = ulib.openat(0, path_z, ulib.O_RDONLY);
    if (fd < 0) {
        uprintf.printf(2, "edit: cannot open %s\n", &.{.{ .s = path_z }});
        return 1;
    }
    var off: u32 = 0;
    while (off < CONTENT_CAP) {
        const n = ulib.read(@intCast(fd), content[off..].ptr, CONTENT_CAP - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
    _ = ulib.close(@intCast(fd));
    content_len = off;
    cursor = 0;

    enterRaw();
    defer leaveRaw();

    while (true) {
        var b: [1]u8 = .{0};
        const got = ulib.read(0, &b, 1);
        if (got <= 0) return 0;
        switch (b[0]) {
            0x13 => save(path_z), // ^S
            0x18 => return 0,     // ^X
            else => {},
        }
    }
```

(Move `enterRaw();` to *after* the load — we want load + open errors in cooked mode so `printf` to stderr isn't garbled.)

- [ ] **Step 2: Add the `save` function**

Add above `main`:

```zig
fn save(path_z: [*:0]const u8) void {
    const fd = ulib.openat(0, path_z, ulib.O_WRONLY | ulib.O_CREAT | ulib.O_TRUNC);
    if (fd < 0) return; // silent failure — editor stays open
    var written: u32 = 0;
    while (written < content_len) {
        const w = ulib.write(@intCast(fd), content[written..].ptr, content_len - written);
        if (w <= 0) break;
        written += @intCast(w);
    }
    _ = ulib.close(@intCast(fd));
}
```

- [ ] **Step 3: Build the binary**

Run: `zig build kernel-edit`
Expected: clean build.

- [ ] **Step 4: Smoke-test load + save round-trip preserves file**

Run:

```bash
zig build && zig build kernel-fs shell-fs-img && \
  cp zig-out/shell-fs.img /tmp/test-roundtrip.img && \
  printf 'edit /etc/motd\n\x13\x18cat /etc/motd\nexit\n' > /tmp/roundtrip_in && \
  zig build run -- --input /tmp/roundtrip_in --disk /tmp/test-roundtrip.img zig-out/bin/kernel-fs.elf 2>&1 | tail -20
```

Expected: stdout shows `$ cat /etc/motd\nhello from phase 3\n` (the file is unchanged because no edits happened between load and save).

- [ ] **Step 5: Confirm e2e-shell still passes**

Run: `zig build e2e-shell`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/kernel/user/edit.zig
git commit -m "$(cat <<'EOF'
Phase 3.F Task 2: file load + ^S save (no edits yet)

edit /etc/motd now loads the file into content[0..content_len] before
entering raw mode, and ^S re-opens the path with O_WRONLY|O_TRUNC|
O_CREAT and writes the buffer back. With no insert/delete logic yet,
^S^X is a no-op round-trip that leaves the file byte-identical.
EOF
)"
```

---

### Task 3: Insert + backspace at cursor

**Files:**
- Modify: `src/kernel/user/edit.zig`

**Goal:** Printable bytes (0x20-0x7E plus `\n`) insert at `cursor`, shifting the tail right and incrementing `cursor`. Backspace (0x08 / 0x7F) deletes the byte before `cursor`, shifting the tail left and decrementing `cursor`. Buffer-full inserts are silently dropped (no overflow). Cursor remains a byte offset; row/col arithmetic comes in Tasks 4-5.

- [ ] **Step 1: Add `insertByte` and `backspace` helpers**

Add above `main` in `src/kernel/user/edit.zig`:

```zig
fn insertByte(b: u8) void {
    if (content_len >= CONTENT_CAP) return; // silently drop on full
    // Shift tail right one byte.
    var i: u32 = content_len;
    while (i > cursor) : (i -= 1) content[i] = content[i - 1];
    content[cursor] = b;
    content_len += 1;
    cursor += 1;
}

fn backspace() void {
    if (cursor == 0) return;
    // Shift tail left one byte (overwriting the byte before cursor).
    var i: u32 = cursor - 1;
    while (i + 1 < content_len) : (i += 1) content[i] = content[i + 1];
    content_len -= 1;
    cursor -= 1;
}
```

- [ ] **Step 2: Extend the keystroke switch in `main`**

Replace the keystroke switch with:

```zig
        switch (b[0]) {
            0x13 => save(path_z),                         // ^S
            0x18 => return 0,                             // ^X
            0x08, 0x7F => backspace(),                    // backspace / DEL
            '\n', '\r' => insertByte('\n'),               // newline (normalize \r → \n)
            else => {
                if (b[0] >= 0x20 and b[0] <= 0x7E) insertByte(b[0]);
                // else: drop unknown control byte
            },
        }
```

- [ ] **Step 3: Build**

Run: `zig build kernel-edit`
Expected: clean build.

- [ ] **Step 4: Smoke-test insert + save persists**

Run:

```bash
zig build && zig build kernel-fs shell-fs-img && \
  cp zig-out/shell-fs.img /tmp/test-insert.img && \
  printf 'edit /etc/motd\nX\x13\x18cat /etc/motd\nexit\n' > /tmp/insert_in && \
  zig build run -- --input /tmp/insert_in --disk /tmp/test-insert.img zig-out/bin/kernel-fs.elf 2>&1 | tail -10
```

Expected: stdout shows `$ cat /etc/motd\nXhello from phase 3\n` — `X` was inserted at cursor 0, then saved, then cat read the new content. (Note: cursor starts at 0 so X lands at the start.)

- [ ] **Step 5: Smoke-test backspace + save persists**

Run:

```bash
cp zig-out/shell-fs.img /tmp/test-bs.img && \
  printf 'edit /etc/motd\nXX\x7f\x13\x18cat /etc/motd\nexit\n' > /tmp/bs_in && \
  zig build run -- --input /tmp/bs_in --disk /tmp/test-bs.img zig-out/bin/kernel-fs.elf 2>&1 | tail -10
```

Expected: stdout shows `$ cat /etc/motd\nXhello from phase 3\n` — typed `XX`, deleted one with backspace, ended up with one `X` at the start.

- [ ] **Step 6: Confirm e2e-shell still passes**

Run: `zig build e2e-shell`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/kernel/user/edit.zig
git commit -m "$(cat <<'EOF'
Phase 3.F Task 3: insert + backspace at cursor

Printable bytes (and \n / \r normalized to \n) insert at the cursor
offset, shifting the tail right and bumping cursor. Backspace shifts
the tail left, decrementing cursor. Buffer-full inserts drop silently;
backspace at offset 0 is a no-op. Cursor still moves only via insert
(no arrow keys yet — Tasks 4-5).
EOF
)"
```

---

### Task 4: ANSI cursor parsing + horizontal movement (← / →) + redraw

**Files:**
- Modify: `src/kernel/user/edit.zig`

**Goal:** A 2-state ESC parser ingests ESC `[` `A`/`B`/`C`/`D` sequences. This task wires only `C` (right) and `D` (left), bounded by `cursor < content_len` and `cursor > 0`. Adds the full ANSI redraw — clear screen + cursor home + render `content[0..content_len]` + reposition cursor at the byte-offset's row/col — called after every keystroke that mutates either content or cursor. Up/down arrows are accepted by the parser but do nothing this task (Task 5 wires them).

- [ ] **Step 1: Add the ESC parser state**

At module scope in `edit.zig`, after the existing `var cursor: u32 = 0;` line, add:

```zig
const EscState = enum { Normal, GotEsc, GotCsi };
var esc_state: EscState = .Normal;
```

- [ ] **Step 2: Add row/col arithmetic and cursor-movement helpers**

Add above `main`:

```zig
fn moveRight() void {
    if (cursor < content_len) cursor += 1;
}

fn moveLeft() void {
    if (cursor > 0) cursor -= 1;
}

/// Compute (row, col) for `offset` within content. Both are 1-based
/// (matches ANSI `\x1b[<row>;<col>H` semantics). Walks newlines from
/// the start.
fn rowCol(offset: u32) struct { row: u32, col: u32 } {
    var row: u32 = 1;
    var col: u32 = 1;
    var i: u32 = 0;
    while (i < offset) : (i += 1) {
        if (content[i] == '\n') {
            row += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .row = row, .col = col };
}
```

- [ ] **Step 3: Add the ANSI redraw function**

Add above `main`:

```zig
fn writeStr(s: []const u8) void {
    _ = ulib.write(1, s.ptr, @intCast(s.len));
}

/// Decimal-print n into a small fixed buffer; emit via writeStr.
fn writeUint(n: u32) void {
    var buf: [11]u8 = undefined;
    var i: u32 = 0;
    var v: u32 = n;
    if (v == 0) {
        buf[0] = '0';
        i = 1;
    } else {
        while (v > 0) {
            buf[i] = @intCast('0' + (v % 10));
            i += 1;
            v /= 10;
        }
        // reverse in place
        var lo: u32 = 0;
        var hi: u32 = i - 1;
        while (lo < hi) {
            const t = buf[lo];
            buf[lo] = buf[hi];
            buf[hi] = t;
            lo += 1;
            hi -= 1;
        }
    }
    writeStr(buf[0..i]);
}

fn redraw() void {
    // Clear screen + home cursor.
    writeStr("\x1b[2J\x1b[H");
    // Render the buffer.
    if (content_len > 0) writeStr(content[0..content_len]);
    // Position cursor at the byte-offset's (row, col).
    const rc = rowCol(cursor);
    writeStr("\x1b[");
    writeUint(rc.row);
    writeStr(";");
    writeUint(rc.col);
    writeStr("H");
}
```

- [ ] **Step 4: Wire the ESC parser into the main loop**

Replace the keystroke loop's body (the `switch (b[0])` block) with the parser-aware version:

```zig
        switch (esc_state) {
            .Normal => switch (b[0]) {
                0x1B => esc_state = .GotEsc,
                0x13 => save(path_z),                         // ^S
                0x18 => return 0,                             // ^X
                0x08, 0x7F => { backspace(); redraw(); },     // backspace / DEL
                '\n', '\r' => { insertByte('\n'); redraw(); },
                else => {
                    if (b[0] >= 0x20 and b[0] <= 0x7E) {
                        insertByte(b[0]);
                        redraw();
                    }
                },
            },
            .GotEsc => {
                if (b[0] == '[') {
                    esc_state = .GotCsi;
                } else {
                    esc_state = .Normal;
                }
            },
            .GotCsi => {
                switch (b[0]) {
                    'C' => { moveRight(); redraw(); },
                    'D' => { moveLeft(); redraw(); },
                    'A', 'B' => {}, // up/down — Task 5 wires these
                    else => {},
                }
                esc_state = .Normal;
            },
        }
```

- [ ] **Step 5: Initial-state redraw**

Just before the `while (true)` keystroke loop in `main`, add one line so the editor draws the file once on entry:

```zig
    redraw();
```

- [ ] **Step 6: Build**

Run: `zig build kernel-edit`
Expected: clean build.

- [ ] **Step 7: Smoke-test horizontal cursor movement + insert**

Run:

```bash
zig build && zig build kernel-fs shell-fs-img && \
  cp zig-out/shell-fs.img /tmp/test-right.img && \
  printf 'edit /etc/motd\n\x1b[C\x1b[CY\x13\x18cat /etc/motd\nexit\n' > /tmp/right_in && \
  zig build run -- --input /tmp/right_in --disk /tmp/test-right.img zig-out/bin/kernel-fs.elf 2>&1 | tail -10
```

Expected: stdout shows `$ cat /etc/motd\nheYllo from phase 3\n` — cursor moved right twice (0 → 1 → 2), Y inserted at offset 2 (between 'e' and 'l'), saved, cat reads the result.

- [ ] **Step 8: Confirm e2e-shell still passes**

Run: `zig build e2e-shell`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add src/kernel/user/edit.zig
git commit -m "$(cat <<'EOF'
Phase 3.F Task 4: ANSI cursor parsing + horizontal arrows + redraw

A 2-state ESC parser ingests ESC [ A/B/C/D. This task wires C (right)
and D (left); A/B are accepted but no-op until Task 5. After every
content/cursor mutation, redraw() emits \x1b[2J\x1b[H to clear, prints
the full buffer, then \x1b[<row>;<col>H to land the terminal cursor
at the byte-offset's row/col — both 1-based per ANSI semantics. Row/col
arithmetic walks newlines from the start of the buffer.
EOF
)"
```

---

### Task 5: Vertical cursor movement (↑ / ↓)

**Files:**
- Modify: `src/kernel/user/edit.zig`

**Goal:** ESC `[` `A` (up) and `[` `B` (down) move the cursor to the same column on the previous/next row, clamping to the line length. Demo file (`/etc/motd`) is one line, so the up/down arms are mostly defensive plumbing — but they're testable on any multi-line file.

Algorithm (Up):
1. Compute current `(row, col)` via `rowCol(cursor)`.
2. If `row == 1`, no-op.
3. Walk back from `cursor` to find the start of the current line (one past the previous `\n`, or 0).
4. Walk back from there to find the start of the previous line (one past the `\n` before that, or 0).
5. Compute the previous line's length (distance to the next `\n` or `content_len`).
6. New cursor = prev_line_start + min(col - 1, prev_line_len).

Algorithm (Down):
1. Compute current `(row, col)`.
2. Walk forward from `cursor` to the next `\n` (or `content_len`).
3. If we hit `content_len` without a `\n`, no-op (no next line).
4. Skip the `\n` to land at next-line start.
5. Compute the next line's length.
6. New cursor = next_line_start + min(col - 1, next_line_len).

- [ ] **Step 1: Add `moveUp` and `moveDown`**

Add above `main`:

```zig
fn lineStart(off: u32) u32 {
    // Return the offset of the first byte of the line containing `off`.
    var i: u32 = off;
    while (i > 0 and content[i - 1] != '\n') : (i -= 1) {}
    return i;
}

fn lineEnd(off: u32) u32 {
    // Return the offset of the \n that ends the line containing `off`,
    // or content_len if the line is unterminated.
    var i: u32 = off;
    while (i < content_len and content[i] != '\n') : (i += 1) {}
    return i;
}

fn moveUp() void {
    const cur_start = lineStart(cursor);
    if (cur_start == 0) return; // already on row 1
    const col = cursor - cur_start;
    const prev_end = cur_start - 1; // the \n just before cur_start
    const prev_start = lineStart(prev_end);
    const prev_len = prev_end - prev_start;
    const target_col = if (col < prev_len) col else prev_len;
    cursor = prev_start + target_col;
}

fn moveDown() void {
    const cur_start = lineStart(cursor);
    const cur_end = lineEnd(cursor);
    if (cur_end == content_len) return; // no next line
    const col = cursor - cur_start;
    const next_start = cur_end + 1; // skip the \n
    const next_end = lineEnd(next_start);
    const next_len = next_end - next_start;
    const target_col = if (col < next_len) col else next_len;
    cursor = next_start + target_col;
}
```

- [ ] **Step 2: Wire up/down into the ESC parser**

In the `.GotCsi` arm of the switch, replace the `'A', 'B' => {}` no-op with:

```zig
                    'A' => { moveUp(); redraw(); },
                    'B' => { moveDown(); redraw(); },
```

(Keep `'C'` and `'D'` arms unchanged.)

- [ ] **Step 3: Build**

Run: `zig build kernel-edit`
Expected: clean build.

- [ ] **Step 4: Smoke-test up/down on a multi-line file**

Stage a test multi-line file via shell, then edit it:

```bash
zig build && zig build kernel-fs shell-fs-img && \
  cp zig-out/shell-fs.img /tmp/test-vert.img && \
  printf 'echo line1 > /tmp/multi\necho line2 >> /tmp/multi\necho line3 >> /tmp/multi\nedit /tmp/multi\n\x1b[B\x1b[CZ\x13\x18cat /tmp/multi\nexit\n' > /tmp/vert_in && \
  zig build run -- --input /tmp/vert_in --disk /tmp/test-vert.img zig-out/bin/kernel-fs.elf 2>&1 | tail -15
```

Expected: stdout shows `$ cat /tmp/multi\nline1\nlZine2\nline3\n` — cursor was at (1,1) after load, ↓ moved it to (2,1), → moved to (2,2), insert Z, save, cat shows the modified file.

- [ ] **Step 5: Confirm e2e-shell still passes**

Run: `zig build e2e-shell`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/kernel/user/edit.zig
git commit -m "$(cat <<'EOF'
Phase 3.F Task 5: vertical cursor movement (up/down arrows)

ESC [ A and ESC [ B move the cursor to the same column on the
previous/next row, clamping to the target line's length. lineStart
and lineEnd walk newlines forward/backward from a given offset.
The motd demo is one line so this is defensive plumbing, but it
makes edit usable on multi-line files.
EOF
)"
```

---

### Task 6: e2e-editor harness + binary input fixture + build step

**Files:**
- Create: `tests/e2e/editor.zig`
- Create: `tests/e2e/editor_input.txt` (binary; ~43 bytes — see Step 1 for byte sequence)
- Modify: `build.zig` (add `editor_e2e_exe` + `e2e-editor` step)

**Goal:** A host harness that scripts the canonical editor demo session and asserts disk persistence. The fixture drives: shell → `edit /etc/motd` → 2× right-arrow → `Y` → `^S` → `^X` → `cat /etc/motd` → `exit`. Asserts stdout contains the post-editor `$ cat /etc/motd\nheYllo from phase 3\n` landmark and exit code 0.

- [ ] **Step 1: Create the binary input fixture**

Use `printf` (which interprets `\xNN`) so the file is committed exactly:

```bash
printf 'edit /etc/motd\n\x1b[C\x1b[CY\x13\x18cat /etc/motd\nexit\n' > tests/e2e/editor_input.txt
```

Verify byte count: should be 43 bytes total.
Run: `wc -c tests/e2e/editor_input.txt`
Expected: `43 tests/e2e/editor_input.txt`

Verify content (hex dump first 10 bytes):
Run: `od -c tests/e2e/editor_input.txt | head -3`
Expected: shows `e d i t   / e t c / m o t d \n 033 [ C 033 [ C Y 023 030 c a t   / e t c / m o t d \n e x i t \n` (or similar — `033` is ESC, `023` is ^S, `030` is ^X).

- [ ] **Step 2: Create the harness**

Create `tests/e2e/editor.zig`:

```zig
// tests/e2e/editor.zig — Phase 3.F editor + persistence verifier (e2e-editor).
//
// Spawns ccc --input editor_input.txt --disk <copy-of-shell-fs.img> kernel-fs.elf,
// captures stdout, asserts:
//   - exit code 0
//   - stdout contains "$ cat /etc/motd\nheYllo from phase 3\n" (the
//     scripted edit-then-cat landmark)
//
// Why a copy: the block device opens --disk O_RDWR, so the editor's
// save would mutate the staged shell-fs.img on disk. Copying to a tmp
// file keeps the build-output image clean across CI runs.
//
// Fixture byte sequence (43 bytes total):
//   "edit /etc/motd\n"      15 bytes — shell command
//   "\x1b[C\x1b[C"           6 bytes — 2× right-arrow (cursor 0 → 2)
//   "Y"                      1 byte  — insert at offset 2
//   "\x13"                   1 byte  — ^S save
//   "\x18"                   1 byte  — ^X exit
//   "cat /etc/motd\n"       14 bytes — verify the change
//   "exit\n"                 5 bytes — clean shell exit

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

    if (argv.len != 5) {
        stderr.print(
            "usage: {s} <ccc-binary> <shell-fs.img> <kernel-fs.elf> <editor_input.txt>\n",
            .{argv[0]},
        ) catch {};
        stderr.flush() catch {};
        return USAGE_EXIT;
    }

    // Copy shell-fs.img to a tmp path so the editor's writes don't
    // mutate the build artifact.
    const tmp_path = "zig-out/editor-test.img";
    {
        var src = try Io.Dir.cwd().openFile(io, argv[2], .{});
        defer src.close(io);
        const sz = try src.length(io);
        const buf = try gpa.alloc(u8, sz);
        defer gpa.free(buf);
        _ = try src.readPositionalAll(io, buf, 0);
        var dst = try Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
        defer dst.close(io);
        try dst.writePositionalAll(io, buf, 0);
    }

    const child_argv = &[_][]const u8{
        argv[1],
        "--input",
        argv[4],
        "--disk",
        tmp_path,
        argv[3],
    };
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
            stderr.print("editor_verify_e2e: output exceeded {d} bytes\n", .{MAX_BYTES}) catch {};
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
            stderr.print(
                "editor_verify_e2e: expected exit 0, got {d}\nstdout was:\n{s}\n",
                .{ code, out },
            ) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
        else => {
            stderr.print(
                "editor_verify_e2e: child terminated abnormally: {any}\nstdout was:\n{s}\n",
                .{ term, out },
            ) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
    }

    // The discriminating landmark is the prompt + cat output sandwich:
    // "$ cat /etc/motd\nheYllo from phase 3\n". The editor's redraws will
    // contain "heYllo from phase 3" too (as the final buffer state), but
    // only the post-editor cat output is preceded by the literal prompt
    // string "$ cat /etc/motd\n".
    const landmark = "$ cat /etc/motd\nheYllo from phase 3\n";
    if (std.mem.indexOf(u8, out, landmark) == null) {
        stderr.print("editor_verify_e2e: missing landmark {s}\nstdout was:\n{s}\n", .{ landmark, out }) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    return 0;
}
```

- [ ] **Step 3: Wire the `e2e-editor` build step**

In `build.zig`, immediately after the `e2e-shell` block (currently `build.zig:822-838`), add:

```zig
    const editor_e2e_exe = b.addExecutable(.{
        .name = "e2e-editor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e/editor.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const editor_e2e_run = b.addRunArtifact(editor_e2e_exe);
    editor_e2e_run.step.dependOn(b.getInstallStep());
    editor_e2e_run.step.dependOn(shell_fs_img_step);
    editor_e2e_run.addFileArg(exe.getEmittedBin());
    editor_e2e_run.addFileArg(shell_fs_img);
    editor_e2e_run.addFileArg(kernel_fs_elf.getEmittedBin());
    editor_e2e_run.addFileArg(b.path("tests/e2e/editor_input.txt"));
    const e2e_editor_step = b.step("e2e-editor", "Run the Phase 3.F editor e2e test");
    e2e_editor_step.dependOn(&editor_e2e_run.step);
```

- [ ] **Step 4: Build the harness**

Run: `zig build e2e-editor`
Expected: PASS — "Run \[e2e-editor\] success".

If it fails:
- Inspect the captured stdout in the failure message. The full output stream including ANSI escapes and editor redraws will be printed.
- Common failures:
  - Editor never writes the file → check `save()` in `edit.zig`.
  - Cursor lands at wrong offset → check the ESC parser state machine in Task 4.
  - Cooked mode not restored → second `cat` command is never received → check `defer leaveRaw()` in `edit.zig`.

- [ ] **Step 5: Confirm e2e-shell still passes**

Run: `zig build e2e-shell`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add tests/e2e/editor.zig tests/e2e/editor_input.txt build.zig
git commit -m "$(cat <<'EOF'
Phase 3.F Task 6: e2e-editor harness + fixture + build step

editor_input.txt is a 43-byte binary fixture that drives the canonical
demo session: edit /etc/motd → 2× right-arrow → Y → ^S → ^X → cat
/etc/motd → exit. The harness copies shell-fs.img to zig-out/
editor-test.img so the editor's save doesn't mutate the build artifact,
spawns ccc with --input + --disk, captures stdout, and asserts the
discriminating landmark "$ cat /etc/motd\nheYllo from phase 3\n"
appears (proves the editor wrote the file and cat read it back through
a fully-restored cooked-mode shell).
EOF
)"
```

---

### Task 7: e2e-persist harness + 2 input fixtures + build step

**Files:**
- Create: `tests/e2e/persist.zig`
- Create: `tests/e2e/persist_input1.txt` (~28 bytes, plain ASCII)
- Create: `tests/e2e/persist_input2.txt` (~20 bytes, plain ASCII)
- Modify: `build.zig` (add `persist_e2e_exe` + `e2e-persist` step)

**Goal:** A two-pass test that proves on-disk writes survive emulator restart. Pass 1 runs `echo replaced > /etc/motd\nexit\n`; pass 2 runs `cat /etc/motd\nexit\n` and asserts stdout contains `replaced\n`. The harness copies `shell-fs.img` once to a tmp path, spawns ccc on that tmp twice in sequence (separate process invocations), then asserts pass 2's output. Uses `echo` (cooked-mode write path from 3.E) — independent of the editor — so a regression in `edit.zig` doesn't mask a regression in disk persistence.

- [ ] **Step 1: Create the two input fixtures**

```bash
printf 'echo replaced > /etc/motd\nexit\n' > tests/e2e/persist_input1.txt
printf 'cat /etc/motd\nexit\n' > tests/e2e/persist_input2.txt
```

Verify byte counts:
Run: `wc -c tests/e2e/persist_input1.txt tests/e2e/persist_input2.txt`
Expected: `31` and `20` (one for each).

- [ ] **Step 2: Create the harness**

Create `tests/e2e/persist.zig`:

```zig
// tests/e2e/persist.zig — Phase 3.F disk-persistence verifier (e2e-persist).
//
// Runs ccc twice on the SAME --disk image. Pass 1 writes:
//
//   echo replaced > /etc/motd
//   exit
//
// Pass 2 reads:
//
//   cat /etc/motd
//   exit
//
// Asserts pass 2's stdout contains "replaced\n" — proving the kernel's
// bwrite path actually persisted bytes to the host file backing the
// block device, and that pass 2 reads them back via a fresh kernel/proc/
// bufcache instance (no in-memory state survives between invocations —
// only the disk does).
//
// Why a tmp copy: shell-fs.img is a build artifact that downstream tests
// (e2e-shell, e2e-editor) expect to be in a known-pristine state. Copying
// to zig-out/persist-test.img keeps this test self-contained.

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

    if (argv.len != 6) {
        stderr.print(
            "usage: {s} <ccc-binary> <shell-fs.img> <kernel-fs.elf> <pass1_input> <pass2_input>\n",
            .{argv[0]},
        ) catch {};
        stderr.flush() catch {};
        return USAGE_EXIT;
    }

    // Copy shell-fs.img to a fresh tmp image.
    const tmp_path = "zig-out/persist-test.img";
    {
        var src = try Io.Dir.cwd().openFile(io, argv[2], .{});
        defer src.close(io);
        const sz = try src.length(io);
        const buf = try gpa.alloc(u8, sz);
        defer gpa.free(buf);
        _ = try src.readPositionalAll(io, buf, 0);
        var dst = try Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
        defer dst.close(io);
        try dst.writePositionalAll(io, buf, 0);
    }

    // Pass 1: write phase. Just check exit 0.
    {
        const child_argv = &[_][]const u8{
            argv[1], "--input", argv[4], "--disk", tmp_path, argv[3],
        };
        var child = try std.process.spawn(io, .{
            .argv = child_argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
        });
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| if (code != 0) {
                stderr.print("persist_verify_e2e: pass 1 expected exit 0, got {d}\n", .{code}) catch {};
                stderr.flush() catch {};
                return FAIL_EXIT;
            },
            else => {
                stderr.print("persist_verify_e2e: pass 1 terminated abnormally: {any}\n", .{term}) catch {};
                stderr.flush() catch {};
                return FAIL_EXIT;
            },
        }
    }

    // Pass 2: read phase. Capture stdout, assert "replaced\n" appears
    // after the prompt.
    const out = blk: {
        const child_argv = &[_][]const u8{
            argv[1], "--input", argv[5], "--disk", tmp_path, argv[3],
        };
        var child = try std.process.spawn(io, .{
            .argv = child_argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .inherit,
        });

        const MAX_BYTES: usize = 65536;
        var read_buf: [4096]u8 = undefined;
        var reader = child.stdout.?.reader(io, &read_buf);
        const captured = reader.interface.allocRemaining(gpa, .limited(MAX_BYTES)) catch |err| switch (err) {
            error.StreamTooLong => {
                stderr.print("persist_verify_e2e: pass 2 output exceeded {d} bytes\n", .{MAX_BYTES}) catch {};
                stderr.flush() catch {};
                child.kill(io);
                return FAIL_EXIT;
            },
            else => return err,
        };

        const term = try child.wait(io);
        switch (term) {
            .exited => |code| if (code != 0) {
                stderr.print(
                    "persist_verify_e2e: pass 2 expected exit 0, got {d}\nstdout was:\n{s}\n",
                    .{ code, captured },
                ) catch {};
                stderr.flush() catch {};
                gpa.free(captured);
                return FAIL_EXIT;
            },
            else => {
                stderr.print("persist_verify_e2e: pass 2 terminated abnormally: {any}\n", .{term}) catch {};
                stderr.flush() catch {};
                gpa.free(captured);
                return FAIL_EXIT;
            },
        }

        break :blk captured;
    };
    defer gpa.free(out);

    // The discriminating landmark: prompt + cat output sandwich.
    const landmark = "$ cat /etc/motd\nreplaced\n";
    if (std.mem.indexOf(u8, out, landmark) == null) {
        stderr.print("persist_verify_e2e: missing landmark {s}\nstdout was:\n{s}\n", .{ landmark, out }) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    return 0;
}
```

- [ ] **Step 3: Wire the `e2e-persist` build step**

In `build.zig`, immediately after the `e2e-editor` block from Task 6, add:

```zig
    const persist_e2e_exe = b.addExecutable(.{
        .name = "e2e-persist",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e/persist.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const persist_e2e_run = b.addRunArtifact(persist_e2e_exe);
    persist_e2e_run.step.dependOn(b.getInstallStep());
    persist_e2e_run.step.dependOn(shell_fs_img_step);
    persist_e2e_run.addFileArg(exe.getEmittedBin());
    persist_e2e_run.addFileArg(shell_fs_img);
    persist_e2e_run.addFileArg(kernel_fs_elf.getEmittedBin());
    persist_e2e_run.addFileArg(b.path("tests/e2e/persist_input1.txt"));
    persist_e2e_run.addFileArg(b.path("tests/e2e/persist_input2.txt"));
    const e2e_persist_step = b.step("e2e-persist", "Run the Phase 3.F disk-persistence e2e test");
    e2e_persist_step.dependOn(&persist_e2e_run.step);
```

- [ ] **Step 4: Run e2e-persist**

Run: `zig build e2e-persist`
Expected: PASS.

If it fails:
- Pass 1 fails → check that `echo replaced > /etc/motd\nexit\n` works in an interactive session (this was already tested by `e2e-shell`'s `echo hi > /tmp/x`).
- Pass 2 missing landmark → either pass 1 didn't actually persist (kernel `bwrite` issue) or pass 2 reads stale data (bufcache issue). Inspect `zig-out/persist-test.img` between passes by hex-dumping the data block region.

- [ ] **Step 5: Confirm e2e-editor still passes**

Run: `zig build e2e-editor`
Expected: PASS.

- [ ] **Step 6: Confirm e2e-shell still passes**

Run: `zig build e2e-shell`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add tests/e2e/persist.zig tests/e2e/persist_input1.txt tests/e2e/persist_input2.txt build.zig
git commit -m "$(cat <<'EOF'
Phase 3.F Task 7: e2e-persist harness + fixtures + build step

Two-pass test: pass 1 writes /etc/motd via "echo replaced > /etc/motd";
pass 2 (a fresh ccc invocation on the SAME --disk image) cats
/etc/motd and the harness asserts "replaced\n" appears after the
prompt. Proves the kernel's bwrite path actually mutates the
host-backed block device file and that pass 2 reads it via a fresh
kernel + bufcache instance — the only state surviving between passes
is the on-disk image. Uses cooked-mode echo (independent of edit.zig)
so persistence regressions can't be masked by editor regressions.
EOF
)"
```

---

### Task 8: Trace verification + README + deck updates

**Files:**
- Modify: `README.md` (status section + build commands table + layout)
- Modify: `index.html` (deck — replace "Next: 3.F" panel + add Ch 3.F slide + flip "Phase 3 underway" to "Phase 3 complete")

**Goal:** Verify the trace markers are consistent over the now-complete async-IRQ surface; bump README and the deck so they read "Phase 3 complete". This is also where we run the full Phase 3 §Definition-of-Done verification at the end.

- [ ] **Step 1: Run --trace over the editor session and eyeball**

Run:

```bash
zig build && zig build kernel-fs shell-fs-img && \
  cp zig-out/shell-fs.img /tmp/trace-test.img && \
  zig build run -- --trace --input tests/e2e/editor_input.txt --disk /tmp/trace-test.img zig-out/bin/kernel-fs.elf 2>/tmp/trace.log >/dev/null
grep -c "^---" /tmp/trace.log
grep "^--- block" /tmp/trace.log | head -5
grep "^--- interrupt 9" /tmp/trace.log | head -5  # S external (PLIC src 1 = block, src 10 = UART RX)
grep "^--- interrupt 1 " /tmp/trace.log | head -5  # S software (timer, forwarded by M-mode mtimer.S)
grep "^--- interrupt 7 " /tmp/trace.log | head -5  # M timer (CLINT, before being forwarded down to S)
```

Expected: many trace markers; block markers print `read` and `write` ops with sector + PA; interrupt-9 markers carry the PLIC source ID (src 1 for block I/O, src 10 for UART RX); interrupt-7 (M timer) and interrupt-1 (S software, the SSIP-forwarded timer) markers fire periodically. Cause codes 3, 5, 11 should NOT appear (not enabled by our M-mode boot shim).

If any marker is malformed or missing, file a fix and add a `formatXxx` test to `src/emulator/trace.zig`. Most likely no fix is needed — the trace path was exercised by all of 3.A + 3.D already.

- [ ] **Step 2: Update `README.md` status section**

In `README.md`, find the status block (currently `## Status` opening line ~138 with `**Phase 3 Plan E done — FS write path...**`). Add the Plan 3.F summary and bump the headline. Replace the existing line:

```
**Phase 3 Plan E done — FS write path + console fd + shell + utilities.**
```

with:

```
**Phase 3 complete — multi-process OS + filesystem + shell.**
```

Then, immediately after the existing Plan 3.E summary paragraph (ends around line 329 with `Next: Plan 3.F — \`edit\` userland + raw-mode editor + \`e2e-persist\`.`), replace that "Next:" line with a Plan 3.F summary block:

```
Plan 3.F (editor + persistence + final demo) is merged. `edit.zig` is
the cursor-moving text editor that finally exercises 3.E's raw-mode
console arm: load a file into a 16 KB buffer, switch to raw mode, run
a redraw-on-every-keystroke loop dispatching ESC [ A/B/C/D arrow
sequences, printable inserts at cursor, backspace, ^S save (close +
re-open with O_TRUNC + write), and ^X exit (cooked mode + exit 0).
ANSI redraw clears the screen, prints the buffer, and lands the cursor
at the byte-offset's row/col. `e2e-editor` scripts a 43-byte session
through `--input` (edit /etc/motd → 2× right-arrow → Y → ^S → ^X → cat)
and asserts the on-disk file matches "heYllo from phase 3\n".
`e2e-persist` proves block-device writes survive: copy shell-fs.img to
a tmp path, run ccc once with `echo replaced > /etc/motd\nexit\n`, run
ccc again on the same image with `cat /etc/motd\nexit\n`, assert
"replaced\n" appears in pass 2's stdout. The full Phase 3 §Definition
of Done holds: boot to a shell, run our own programs, edit a file
interactively, observe the change persist across emulator restarts.
```

Also update the "Phases" table row 3 if it carries a status; and the trailing "Phase 3 — multi-process OS + filesystem + shell — in progress." section header (around line 216) to "**Phase 3 — multi-process OS + filesystem + shell — complete.**". (The existing per-plan paragraphs from 3.A through 3.E stay verbatim — they're history.)

- [ ] **Step 3: Add `kernel-edit`, `e2e-editor`, `e2e-persist` to the build commands table**

In `README.md`'s build-commands table, after the `kernel-rm` row (currently `build.zig` line ~80 in the rendered table), insert one row:

```
| `zig build kernel-edit` | Build the Phase 3.F `edit.elf` (cursor-moving raw-mode editor with ANSI redraw) |
```

After the `e2e-shell` row (currently around line 88), insert two rows:

```
| `zig build e2e-editor` | Boot `kernel-fs.elf` against a tmp copy of `shell-fs.img` with `--input tests/e2e/editor_input.txt`; assert post-editor `cat /etc/motd` shows the inserted-Y change `heYllo from phase 3\n` (Plan 3.F milestone) |
| `zig build e2e-persist` | Run `ccc` twice on a tmp copy of `shell-fs.img`: pass 1 echos `replaced > /etc/motd`, pass 2 cats it; assert pass 2 sees `replaced\n` (Plan 3.F: writes survive emulator restart) |
```

- [ ] **Step 4: Update the layout section's `src/kernel/user/` listing**

In `README.md`'s layout block (around line 380-398), find the `user/` subdir listing. After the `rm.zig` line (around line 393), add:

```
      edit.zig        # 3.F: cursor-moving editor — load 16 KB buffer, raw mode in/out, ESC arrow keys, ^S save, ^X exit, ANSI redraw
```

In the `tests/e2e/` listing (around line 419-426), after the `shell_input.txt` line, add:

```
    editor.zig        # Plan 3.F verifier (edit /etc/motd → 2× right → Y → ^S^X → cat asserts)
    editor_input.txt  # 43-byte binary fixture (ESC sequences + control bytes for the editor session)
    persist.zig       # Plan 3.F verifier (ccc twice on same disk; second sees first's writes)
    persist_input1.txt # pass-1 input: echo replaced > /etc/motd; exit
    persist_input2.txt # pass-2 input: cat /etc/motd; exit
```

- [ ] **Step 5: Update the deck's "Next · plan 3.f" panel**

In `index.html`, find lines 1632-1638 (the panel inside the closing chapter slide). Replace:

```html
      <div class="panel" style="align-self: center;">
        <h4>Next · plan 3.f</h4>
        <p style="font-size: 28px; line-height: 1.5;">
          Editor + persistence.<br><br>
          A cursor-moving <code class="inline">edit</code> binary that exercises <strong>raw-mode</strong> console (already wired in 3.E) with ANSI escapes, <code class="inline">^S</code> save / <code class="inline">^X</code> exit through the new write path. Plus <code class="inline">e2e-persist</code> — re-run against the same <code class="inline">fs.img</code> and observe writes survived.
        </p>
      </div>
```

with a row-style status entry consistent with the 3.A-3.E rows above (lines 1620-1630):

```html
        <div class="row">
          <div class="head">✓ 3.F · editor + persistence</div>
          <div class="sub">cursor-moving <code class="inline">edit.zig</code> · raw-mode console exercised · 16 KB content buffer · ESC [ A/B/C/D arrow parser · ANSI redraw (clear + home + buffer + position) · <code class="inline">^S</code> save (close + O_TRUNC re-open) · <code class="inline">^X</code> exit + cooked restore · <code class="inline">e2e-editor</code> (43-byte fixture: edit → 2× right → Y → ^S^X → cat asserts <code class="inline">heYllo from phase 3</code>) · <code class="inline">e2e-persist</code> (two ccc passes on copied image; pass 2 sees pass 1's writes)</div>
        </div>
      </div>
```

(Drop the entire `<div class="panel">` wrapper since the closing chapter no longer needs a "next" callout — the panel is moved into the row list with the other ✓ rows.)

- [ ] **Step 6: Flip the "Phase 3 · underway" tag to "complete"**

In `index.html` around line 1575, find:

```html
    <h2 class="slide-title">Phase 1 · <span class="accent">complete</span>. Phase 2 · <span class="accent">complete</span>. Phase 3 · <span class="accent">underway</span>.</h2>
```

Replace with:

```html
    <h2 class="slide-title">Phase 1 · <span class="accent">complete</span>. Phase 2 · <span class="accent">complete</span>. Phase 3 · <span class="accent">complete</span>.</h2>
```

In the same closing chapter's `<p class="plain">` body (around line 1576), append a sentence after the `Plan 3.E` clause (after `The OS finally has an interactive prompt.`):

```
<strong>Plan 3.F</strong> wrapped Phase 3 — a cursor-moving <code>edit</code> binary that exercises the raw-mode console arm 3.E left wired-but-unexercised, plus an <code>e2e-persist</code> test that proves on-disk writes survive emulator restart. Phase 3 §Definition of Done holds: boot to a shell, run our own programs, edit files interactively, observe changes persist across reboots.
```

Also update the deck's table-of-contents entry for Phase 3 (line ~349) — replace the trailing "Plans 3.A + 3.B + 3.C + 3.D + 3.E landed" segment with "Plans 3.A + 3.B + 3.C + 3.D + 3.E + 3.F landed (Phase 3 done)".

- [ ] **Step 7: Add a Ch 3.F slide before the closing chapter**

This is optional polish; if time permits, mirror the existing chapter slides' shape (e.g., the Ch 3.E · console + WFI structure at line 1491). At minimum, ensure the slide deck doesn't promise content it doesn't show — if you skip the new slide, the row-status update in Step 5 is sufficient.

If you do add a slide, place it just before the closing `<section ...>` at line 1574. Use this shape:

```html
  <!-- 38: Chapter 3.F · editor + persistence -->
  <section data-label="Ch 3.F · editor + persistence">
    <span class="slide-num">38</span>
    <h2 class="slide-title"><span class="accent">Chapter 3.F</span> — editor + persistence (final demo)</h2>
    <p class="plain">Plan 3.E wired raw-mode in the kernel but never exercised it. Plan 3.F finally does, with a cursor-moving <code>edit</code> binary: <code>console_set_mode(1)</code> on entry, <code>console_set_mode(0)</code> on exit, a 16 KB content buffer with a single byte-offset cursor, and a redraw-on-every-keystroke ANSI loop dispatching ESC [ A/B/C/D arrows + printables + backspace + <code>^S</code> save + <code>^X</code> exit. <code>e2e-editor</code> drives the canonical session via a 43-byte binary fixture. <code>e2e-persist</code> proves the kernel's <code>bwrite</code> path actually persists by running ccc twice on the same disk image and asserting pass 2 sees pass 1's writes.</p>
    <div class="caption">Phase 3 §Definition of Done holds end-to-end. <code>kernel.elf</code> + <code>shell-fs.img</code> boot to a shell, run our own programs, edit files interactively, observe changes survive emulator restarts. Next: Phase 4 (network stack) or Phase 6 (framebuffer + compositor — already specced as optional).</div>
  </section>
```

- [ ] **Step 8: Verify deck loads in a browser (manual sanity check)**

Open `index.html` in a browser (or run `python3 -m http.server` from the repo root and visit `http://localhost:8000`). Page through to the closing chapter slide; confirm the "✓ 3.F" row shows up alongside 3.A-3.E and the closing line reads "Phase 3 · complete". This is a manual eyeball — not blocking.

- [ ] **Step 9: Run the full Phase 3 §Definition-of-Done test suite**

Run each of these in sequence; all must pass:

```bash
zig build test                  # all unit tests
zig build riscv-tests           # rv32{ui,um,ua,mi,si}-p-* (67 tests)
zig build e2e                   # Phase 1 e2e
zig build e2e-mul
zig build e2e-trap
zig build e2e-hello-elf
zig build e2e-kernel            # Phase 2 e2e
zig build e2e-multiproc-stub    # 3.B
zig build e2e-fork              # 3.C
zig build e2e-fs                # 3.D
zig build e2e-shell             # 3.E
zig build e2e-editor            # 3.F (NEW)
zig build e2e-persist           # 3.F (NEW)
zig build e2e-snake             # snake demo
zig build e2e-plic-block        # 3.A
```

Expected: every step exits 0.

- [ ] **Step 10: Manual interactive demo (Definition of Done milestone)**

Run the canonical interactive session. This isn't a test gate — just the human-verification of "yes, Phase 3 is done."

```bash
zig build && zig build kernel-fs shell-fs-img && \
  cp zig-out/shell-fs.img /tmp/dod.img && \
  zig build run -- --disk /tmp/dod.img zig-out/bin/kernel-fs.elf
```

Type into the running shell (host stdin is forwarded via the rx_pump's stdin path):

```
ls /bin
cat /etc/motd
echo replaced > /etc/motd
cat /etc/motd
edit /etc/motd
[arrow keys, type "again", ^S, ^X]
cat /etc/motd
exit
```

Then re-run on the same `/tmp/dod.img`:

```bash
zig build run -- --disk /tmp/dod.img zig-out/bin/kernel-fs.elf
```

```
cat /etc/motd
exit
```

Expected: the second run's `cat /etc/motd` shows whatever was edited in the first run. (The exact content depends on what was typed, but the persistence is the point.)

- [ ] **Step 11: Commit**

```bash
git add README.md index.html
git commit -m "$(cat <<'EOF'
Phase 3.F Task 8: trace verification + README + deck updates

Bumped README to "Phase 3 complete" with a Plan 3.F summary block;
added kernel-edit / e2e-editor / e2e-persist rows to the build
commands table; added edit.zig + the new e2e fixtures to the layout.
Deck: replaced the "Next · plan 3.f" panel with a ✓ 3.F status row
matching the 3.A-3.E rows above; flipped "Phase 3 · underway" to
"Phase 3 · complete" on the closing chapter; added a Ch 3.F slide.
Trace eyeball pass over the editor session showed the existing
markers are consistent end-to-end — no formatter changes needed.
EOF
)"
```

---

## Rollup verification

After all eight tasks land, the working tree must satisfy:

- `zig build test` passes (all unit tests across emulator + kernel + trace formatters).
- `zig build riscv-tests` passes (rv32ui/um/ua/mi/si-p-* — 67 tests).
- All Phase 1 e2e: `e2e`, `e2e-mul`, `e2e-trap`, `e2e-hello-elf`.
- All Phase 2 e2e: `e2e-kernel`.
- All Phase 3 e2e: `e2e-multiproc-stub`, `e2e-fork`, `e2e-fs`, `e2e-shell`, **`e2e-editor`**, **`e2e-persist`**, `e2e-plic-block`, `e2e-snake`.
- `zig build run -- --disk shell-fs.img kernel-fs.elf` boots, runs `init`, which forks `sh`, which prompts. `edit /etc/motd` works interactively (the host typing is forwarded via the rx_pump's stdin path); `^S`/`^X` save and exit; the next prompt accepts cooked input again.
- A second `ccc` invocation on the same `shell-fs.img` shows the previous run's edits.

If any of these fail, the failing task is incomplete — don't merge.

---

## Risks and notes

- **Editor's full-buffer redraw on every keystroke is wasteful** — fine for our 19-byte demo file but linear in file size. If we ever care, switch to a rope or gap buffer. Out of scope for 3.F.

- **Save-on-^S has no error reporting to user** — if `openat(O_WRONLY|O_TRUNC|O_CREAT)` fails (e.g., disk full, no permissions — neither possible in our system), the save silently no-ops and the editor stays open. We don't paint a status bar, so the user has no indication. Acceptable for a demo editor.

- **No file-locking semantics** — if the user runs `edit /etc/motd` while another process holds the file open, both processes happily walk over each other. Single-shell scope makes this academic in our system.

- **The 16 KB cap silently truncates large files** — same trade-off as the spec calls out. A simple guard would be: at load time, if `read` reports `len > CAP`, print a warning to fd 2 ("edit: file truncated to 16 KB") before entering raw mode. Adds 4 lines if we want it; not in scope.

- **ANSI redraw assumes a 25-line × 80-column terminal** — we don't query the terminal size; we just position cursor by row/col and assume the host terminal handles wrap. For the demo motd this is trivially fine.

- **`editor_input.txt` is committed binary** — git treats it as text-with-binary-chars by default. Add a `.gitattributes` rule if line-ending noise becomes a problem; not anticipated for our 43-byte fixture on macOS / Linux developer machines.

- **`e2e-persist` writes to `zig-out/persist-test.img` and `e2e-editor` writes to `zig-out/editor-test.img`** — both are inside `zig-out/` which `.gitignore` already covers. No cleanup needed between CI runs.

- **The deck slide for Ch 3.F is optional** — if the row-status update is sufficient and adding a slide adds visual clutter, skip it. The spec calls for "doc updates", not "deck slide for every plan".

- **Trace markers are well-tested in `src/emulator/trace.zig`'s unit tests** — Task 8 Step 1 is verification, not new code. If you find a real inconsistency, fix it inline + add a regression test under the existing `test "..."` block; don't punt.

- **No new syscalls means no new ABI risk** — the userland-kernel boundary is identical to 3.E. The only kernel-side code path that changes behavior between 3.E and 3.F is "raw mode is now exercised by a real binary" — which 3.E unit-tested via `console.zig`'s state machine but never end-to-end through a real reader.

- **Phase 3 closes here.** The next phase (4: networking, or 6: framebuffer + compositor — independent) is a separate brainstorm → spec → plan cycle. This plan's only forward-looking responsibility is leaving the deck and README accurate so the next phase can start from a known-good baseline.
