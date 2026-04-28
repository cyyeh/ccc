# console-and-editor: Code Cases

> Real artifacts that exercise the console + editor stack.

---

### Case 1: `e2e-cancel` — proving the `^C` chain (Plan 3.F, 2026-04)

**Background**

The Phase 3 §Definition of Done requires "^C cancels foreground program." This is the proof.

**What happened**

`tests/e2e/cancel.zig` pipes 10 bytes via `--input`: `cat\n\x03exit\n`.

1. Shell reads "cat\n", forks+execs `/bin/cat`. Cat reads stdin (no input yet), blocks.
2. Next `--input` byte: `\x03`. Pumped into UART RX FIFO; PLIC source 10; trap; UART ISR; `console.feedByte(0x03)`.
3. `feedByte` is in cooked mode. Sees 0x03. Echoes `^C\n` (writes to UART). Calls `proc.kill(fg_pid)`.
4. `fg_pid` was set by the shell when it forked cat. So `cat.killed = true`. `cat` was Sleeping → flipped to Runnable.
5. cat wakes. Its `read(0, ...)` returns -1 (because `console.read` checks `p.killed`).
6. cat's syscall returns. Dispatch checks `p.killed`. Calls `proc.exit(cat, 1)`.
7. cat is Zombie. Wakes shell.
8. Shell's `wait4` returns cat's pid. Shell prints `$ ` prompt.
9. Next `--input` bytes: `exit\n`. Shell tokenizes, executes builtin, exits.

The asserted output:

```
$ cat
^C
$ exit
```

If `feedByte` doesn't recognize 0x03, no kill — cat hangs forever. If `proc.kill` doesn't flip Sleeping → Runnable, cat never wakes. If `console.read` doesn't check killed, cat doesn't return. If dispatch doesn't check killed, cat returns to user space normally. *Every link* in the chain must work.

**References**

- `src/kernel/console.zig` (`feedByte` 0x03 arm, `console.read`'s killed check)
- `src/kernel/proc.zig` (`kill`)
- `src/kernel/syscall.zig` (the `if (p.killed)` after dispatch)
- `tests/e2e/cancel.zig`, `cancel_input.txt`

---

### Case 2: `e2e-editor` — the inserted-Y demo (Plan 3.F, 2026-04)

**Background**

The Phase 3 demo of the editor: edit `/etc/motd` (which contains `hello from phase 3\n`), move two right, insert `Y`, save, exit, cat the file. Expect `heYllo from phase 3\n`.

**What happened**

`tests/e2e/editor_input.txt` is 43 bytes:

```
edit /etc/motd\n          (15 bytes; shell command)
\x1b[C\x1b[C               (6 bytes; two right-arrow ESC sequences)
Y                          (1 byte; the inserted character)
\x13                       (1 byte; ^S — save)
\x18                       (1 byte; ^X — exit)
cat /etc/motd\n           (14 bytes; verify the change)
exit\n                     (5 bytes; clean shutdown)
```

The verifier asserts the post-edit output contains `heYllo from phase 3\n`.

For this to work:
- Shell reads "edit /etc/motd\n", fork+execs `edit.zig`.
- `edit.zig` opens `/etc/motd`, reads into `buffer`, switches to raw mode.
- Reads `\x1b` `[` `C` → `moveRight()`. Cursor 0 → 1.
- Reads `\x1b` `[` `C` → `moveRight()`. Cursor 1 → 2.
- Reads `Y` → `insertByte(0x59)`. Buffer becomes `heYllo from phase 3\n`. Cursor 3.
- Reads `\x13` (^S) → `save(path)`. Open `/etc/motd` with `O_TRUNC | O_WRONLY`, write 20 bytes, close.
- Reads `\x18` (^X) → `leaveRaw()`, `exit(0)`.
- Shell reaps. Reads `cat /etc/motd\n`. Forks+execs cat. Cat reads, prints `heYllo from phase 3\n`.

**References**

- `src/kernel/user/edit.zig`
- `tests/e2e/editor.zig`, `editor_input.txt`

---

### Case 3: How `--input` interleaves with cooked-mode echo (Plan 3.E, 2026-04)

**Background**

In Plan 3.E, the e2e shell test pipes `ls /bin\n echo hi > /tmp/x\n cat /tmp/x\n rm /tmp/x\n exit\n` through `--input`. For the asserted output to be correct, each byte must be echoed *before* the next arrives.

**What happened**

The pacing is byte-per-iteration in `cpu.idleSpin`:

```zig
pub fn idleSpin(self: *Cpu) void {
    while (true) {
        if (check_interrupt(self)) return;
        if (self.memory.uart.rx_pump) |pump| {
            pump.drainOne(...);  // push exactly ONE byte from --input
        }
        if (check_interrupt(self)) return;
        // sleep 1ms
    }
}
```

Each iteration pumps one byte. The byte fires SEI; trap; `feedByte` echoes; `feedByte` returns; trap returns; the shell hasn't woken yet (`feedByte` only `wakeup`s on `\n`). Loop iterates: next byte pushed; echoed.

When `\n` arrives, `feedByte` commits the line and `wakeup`s the shell. Now the shell runs, reads the line, processes.

If `--input` were drained all-at-once into the FIFO, every echo would happen in one trap-storm before the shell got control. The output ordering would be wrong (all 51 echoed bytes, then no shell processing visible until later).

**Relevance**

The byte-per-iteration design is what makes the e2e tests' golden output match what a human would see at a real terminal. Without it, the tests would still pass *functionally* (the kernel behavior is correct) but the byte-stream order would be different.

**References**

- `src/emulator/cpu.zig` (`idleSpin` → `pump.drainOne` once per iteration)
- `src/emulator/devices/uart.zig` (`RxPump`)
- `tests/e2e/shell.zig` (the test that depends on this ordering)

---

### Case 4: The `wfi`/SIE-window bug story (Plan 3.E, 2026-04)

**Background**

In Plan 3.E, the very first run of `kernel-fs.elf` against `shell-fs.img` hung. Tracing showed: shell forked, child execed sh, sh read from stdin, kernel went to wfi, ... and never returned.

**Diagnosis**

Inspection: `wfi` was called with `mstatus.SIE = 0`. That's because the scheduler's `swtch` sequence had cleared SIE for safety. Now `idleSpin` was running but `check_interrupt` always returned false (because SEI's deliverable check fails when current=S and SIE=0).

`--input` byte arrives, PLIC asserts source 10, but `check_interrupt` says no. The 1ms sleep ticks. Next iteration, same thing. Never makes progress.

**Fix**

Two-part:
1. Add `s_kernel_trap_entry` — a separate trap entry for traps taken on the scheduler's stack.
2. Open the SIE window for one instruction across `wfi`. The scheduler:

```
csrr t0, sscratch          ; save current stvec
csrw stvec, s_kernel_trap_entry
csrsi sstatus, 0x2         ; SIE = 1 — open the window
wfi
csrci sstatus, 0x2         ; SIE = 0 — close the window
csrw stvec, t0             ; restore stvec
```

If a trap fires during `wfi`, it lands at `s_kernel_trap_entry` with the right invariants. After return, the window closes.

There was a second subtle bug: `wfi`'s execution arm needed to advance `sepc` (the trap-saved PC) past the wfi after the trap returned, otherwise the post-trap return would re-enter wfi. The fix was a comment-and-check in `execute.zig`'s `wfi` arm.

**References**

- `src/kernel/sched.zig` (the SIE-window setup)
- `src/kernel/trampoline.S` (`s_kernel_trap_entry`)
- `src/emulator/execute.zig` (the `wfi` arm)
- `src/emulator/cpu.zig` test `"WFI returns promptly..."`

---

### Case 5: Why `console.read` checks `p.killed` (Plan 3.E → 3.F, 2026-04)

**Background**

`console.read` is the cooked-mode line reader. It blocks until a `\n` commits a line. But what if `^C` arrives mid-wait?

**What happened**

```zig
pub fn read(dst_va: u32, n: u32) i32 {
    while (r == w) {
        const p = proc.cur();
        if (p.killed) return -1;     // ← the kill check
        proc.sleep(@ptrCast(&input_buf));
    }
    // ... copy bytes ...
}
```

The check after `sleep`'s wake is critical. `^C`:
1. Sets `p.killed = true`.
2. `proc.kill` flips Sleeping → Runnable.
3. The sleeping `read` wakes. The `while` re-enters.
4. Sees `p.killed = true`. Returns -1.

Without the check, the read would loop again, try to sleep, but immediately get woken (because state is Runnable). It'd spin until the buffer fills — which would never happen if the killer has muted further input.

The pattern (check killed after every sleep) is repeated throughout the kernel. Anywhere `proc.sleep` is called, the post-wake code should re-check `p.killed`.

**References**

- `src/kernel/console.zig` (`read`)
- `src/kernel/proc.zig` (`sleep`, `kill`)
- The same pattern in `src/kernel/fs/bufcache.zig`, `block.zig`, etc.

---

### Case 6: `\x1b[2J\x1b[H` — the editor's "clean slate" sequence (Plan 3.F, 2026-04)

**Background**

Every keystroke in the editor triggers a full redraw. The redraw starts with two ANSI sequences: clear screen, home cursor.

**Why two, not one**

`\x1b[2J` clears all visible characters but does NOT move the cursor. So after `\x1b[2J`, the cursor is at wherever it was — which, depending on what came before, could be anywhere.

`\x1b[H` then moves the cursor to (1, 1) — top-left.

After both, you have a blank screen with the cursor at home, ready to draw.

**The full redraw**:
1. Send `\x1b[2J` — terminal blanks.
2. Send `\x1b[H` — terminal moves cursor to top.
3. Send the buffer's bytes — they print left-to-right, top-to-bottom from the home position.
4. Compute (row, col) for the *editor's* cursor offset.
5. Send `\x1b[r;cH` — terminal cursor moves to that position.

Now the screen shows the file content with the cursor at the right spot.

**The cost**

This is full redraw on every keystroke. For a 16 KB file at 80 cols × 24 rows = 1920 chars, you're sending ~16 KB × every keystroke. On a real serial line at 9600 baud, that's painfully slow. On `ccc`'s in-process UART, it's fine.

A real editor (vi, emacs) does diff-based redraws: only emit ANSI for the parts that changed. `ccc`'s full-redraw is a teaching simplification.

**References**

- `src/kernel/user/edit.zig` (`redraw`)
- `web/ansi.js` (the JS-side interpreter that decodes these sequences in the demo)
