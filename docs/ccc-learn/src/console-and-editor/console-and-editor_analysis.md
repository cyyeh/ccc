# console-and-editor: In-Depth Analysis

## Introduction

You press `'h'` on the keyboard. Some long chain of events later, the byte 'h' shows up in `read()`'s buffer in a user program. This topic is about that chain — and about its inverse, where bytes from `printf` reach the user's eyes.

The first half of the journey is hardware (UART RX FIFO → PLIC → ISR), covered in [devices-uart-clint-plic-block](#devices-uart-clint-plic-block). This topic picks up from there: what does the kernel *do* with the byte once it has it? How does it turn raw keystrokes into lines? How does `^C` kill a process? How does the editor escape this whole machinery to draw with ANSI escape sequences?

Source: `src/kernel/console.zig` and `src/kernel/user/edit.zig`.

---

## Part 1: Cooked mode — line discipline

When you type at a normal shell prompt, you're in **cooked mode**. The kernel:

- Echoes each keystroke (so you see what you typed).
- Buffers bytes into a line.
- Handles backspace, `^U` (kill line), `^C` (kill foreground process), `^D` (EOF).
- Only delivers a complete line on `\n` (Enter).

`console.zig`'s state:

```zig
pub var mode: ConsoleMode = .Cooked;
pub var input_buf: [INPUT_BUF_SIZE = 128]u8 = ...;
var w: u32 = 0;     // write index (where next byte goes)
var r: u32 = 0;     // read index (where read() consumes from)
var e: u32 = 0;     // edit index (where current line is being typed)
```

The three indices form a circular buffer:

- Bytes from `[r, w)` are committed lines, available to `read()`.
- Bytes from `[w, e)` are being typed but not yet committed.

When you type 'h':

1. UART RX FIFO has 'h'. PLIC source 10 fires.
2. Kernel ISR drains FIFO, calls `feedByte('h')`.
3. `feedByte` switches on the byte:
   - Most printable bytes: append to `input_buf[e++]`, echo via `uart.putByte('h')`.
   - `\n` or `\r`: append, echo `\n`, advance `w = e` (commit the line), `wakeup(&input_buf)` (wake any sleeping `read()`).
   - Backspace (0x7F or 0x08): if `e > w`, decrement `e`, echo `\b \b` (move left, overwrite with space, move left again).
   - `^U` (0x15): kill line. Reset `e = w`. Echo `\b \b` for each char that was buffered.
   - `^C` (0x03): call `proc.kill(fg_pid)`. Echo `^C\n`. Don't change buffer.
   - `^D` (0x04): if `e > w`, commit (treat as `\n`); if `e == w`, signal EOF (set a flag that makes `read` return 0).

`read(dst, n)`:

- If the buffer is empty (`r == w`), sleep on `&input_buf`. `feedByte`'s commit will wake us.
- Copy bytes from `input_buf[r..w]` to `dst`, up to n. Advance `r`.
- Return bytes copied.
- A `read` of a partial line *is allowed* (xv6 doesn't, but `ccc` does — by reading what's committed even if `\n` hasn't arrived; though in practice cooked mode never returns until `\n`).

Notice: cooked mode is what makes a shell *feel* like a shell. Without it, the kernel would deliver each byte to `read()` as it arrived, and the user program would have to handle backspace itself. With cooked mode, the user program calls `read(0, ...)` and gets a clean line.

### `^C` chain end-to-end

The `^C` byte (0x03) hits cooked mode. `feedByte` does:

```zig
0x03 => {
    uart.writeStr("^C\n");
    if (fg_pid != 0) proc.kill(fg_pid);
    // Buffer left as-is — the killed process won't be reading anymore
},
```

`proc.kill(pid)` sets `target.killed = true` and (if Sleeping) makes Runnable. The next time the target returns from a syscall, `syscall.dispatch` sees `killed=true` and calls `proc.exit(p, 1)`.

If the target is currently inside `read()` of fd 0, `console.read` checks for `p.killed` after each iteration and returns -1 if set. So the read returns; syscall handler returns; dispatch sees killed; exit. The `^C\n` echo is the visible signal that the kill was acknowledged.

`tests/e2e/cancel.zig` is the regression for this.

---

## Part 2: Raw mode — for editors

The editor wants every keystroke immediately, no echo, no line buffering. That's **raw mode**.

When `edit.zig`'s `_start` runs, it calls a magic syscall (or writes to a special control fd) to set `console.mode = Raw`. Now `feedByte` skips all the cooked logic:

```zig
pub fn feedByte(b: u8) void {
    if (mode == .Raw) {
        input_buf[e] = b;
        e = (e + 1) % INPUT_BUF_SIZE;
        w = e;  // immediately committed
        wakeup(&input_buf);
        return;
    }
    // ... cooked-mode handling ...
}
```

In raw mode, `\n` is just a byte. `^C` is just a byte. The editor handles them itself. Echo is the editor's job (it does it via the redraw loop).

Switching back to cooked mode at exit is critical — otherwise the shell would see raw bytes and break. `edit.zig`'s `leaveRaw` runs at exit (via `defer` in `main`).

---

## Part 3: ANSI escape sequences

To "redraw the screen" the editor uses ANSI control sequences. These are byte sequences sent to the UART (which in `ccc` is the same as standard output). When a real terminal (or `ccc`'s web demo's ANSI interpreter in `web/ansi.js`) sees them, it interprets them as control commands instead of printing.

The minimal set `edit.zig` uses:

| Sequence | Effect |
|----------|--------|
| `\x1b[2J` | Clear entire screen. |
| `\x1b[H` | Move cursor to (1, 1). |
| `\x1b[<row>;<col>H` | Move cursor to (row, col). |
| `\x1b[A`, `[B`, `[C`, `[D` | Cursor up / down / right / left. |

`\x1b` is the ESC character (0x1B). `[` introduces a CSI ("Control Sequence Introducer"). The remaining bytes encode the command.

The editor reads ESC sequences too: when the user presses an arrow key, the terminal sends `ESC [ A` (up), `ESC [ B` (down), etc. The editor's input loop accumulates bytes after ESC and matches the resulting sequence.

`web/ansi.js` is `ccc`'s ~120-line ANSI interpreter for the wasm demo. It handles a small subset (CSI 2J, CSI H, CSI A/B/C/D, CSI ?25, plus UTF-8 reassembly) — enough for the editor to work in the browser tab.

---

## Part 4: The editor's redraw loop (`edit.zig`)

`edit.zig` is a cursor-moving text editor. ~250 lines.

The state:
- `buffer: [16384]u8` — the file's contents.
- `len: u32` — current byte length.
- `cursor: u32` — current byte offset within buffer.
- `path: [*:0]const u8` — the file being edited.

Main loop:

```zig
fn main() i32 {
    // 1. Open file, read into buffer (up to 16 KB). Allow file to not exist (empty buffer).
    // 2. enterRaw() — switch console to raw mode.
    // 3. Loop:
    while (true) {
        redraw();
        const b = read_one_byte();
        switch (b) {
            0x1B => { // ESC sequence (arrow keys)
                const b2 = read_one_byte();
                if (b2 != '[') continue;
                const b3 = read_one_byte();
                switch (b3) {
                    'A' => moveUp(),
                    'B' => moveDown(),
                    'C' => moveRight(),
                    'D' => moveLeft(),
                    else => {},
                }
            },
            0x7F => backspace(),
            0x13 => save(path),       // ^S
            0x18 => break,            // ^X — exit
            else => insertByte(b),
        }
    }
    // 4. leaveRaw() — back to cooked.
    // 5. exit(0).
}
```

`redraw()`:

```zig
fn redraw() void {
    write("\x1b[2J\x1b[H");           // clear screen + home
    write(buffer[0..len]);             // dump the buffer
    const rc = rowCol(cursor);
    write("\x1b[{rc.row};{rc.col}H");  // move cursor to its position
}
```

`rowCol(offset)` walks `buffer[0..offset]` counting newlines and column position.

The redraw is **full** — every keystroke the entire screen is cleared and rewritten. Inefficient for huge files, but correct and simple. For 16 KB max, fast enough.

`insertByte(b)`:

```zig
// shift buffer[cursor..len] right by 1
@memmove(buffer[cursor+1..len+1], buffer[cursor..len]);
buffer[cursor] = b;
len += 1;
cursor += 1;
```

`backspace()`:

```zig
if (cursor == 0) return;
@memmove(buffer[cursor-1..len-1], buffer[cursor..len]);
len -= 1;
cursor -= 1;
```

`save(path_z)`:

```zig
const fd = openat(AT_FDCWD, path_z, O_WRONLY | O_TRUNC);
write(fd, buffer, len);
close(fd);
```

`O_TRUNC` truncates the file to 0 first; then we write the full new content. Simple, correct, and inefficient for large files.

---

## Part 5: How input is paced (the SIE-window connection)

In Plan 3.E's e2e tests, the shell is fed keystrokes via `--input`. The `RxPump` in `uart.zig` drains one byte per `idleSpin` iteration. The kernel's ISR runs, calls `console.feedByte`, echoes (via `uart.putByte`), and the byte goes back out the UART.

For this to work end-to-end, several things must align:

1. The kernel must `wfi` (so `idleSpin` runs).
2. `idleSpin` must service device IRQs and pump bytes.
3. The SIE window must be open during `wfi` (so the device IRQ from the byte's pushRx can land).
4. After the trap, the kernel returns to the scheduler, which runs the shell, which calls `read(0, ...)`, which sees the buffered byte and returns.

If any link breaks, the test hangs. The Plan 3.E case in [csrs-traps-and-privilege](#csrs-traps-and-privilege) covers the SIE-window debugging.

---

## Part 6: The fd 0/1/2 = Console mapping

When a process is created, its fd table starts with three Console-type Files (refcounted, shared if forked).

```zig
// In proc.alloc or kmain init:
file_0 = file.alloc(.Console, readable=true, writable=false);
file_1 = file.alloc(.Console, readable=false, writable=true);
file_2 = file.alloc(.Console, readable=false, writable=true);
p.ofile[0] = file_0;
p.ofile[1] = file_1;
p.ofile[2] = file_2;
```

(This is the conceptual setup; the actual code may share a single Console File across all three with both R+W.)

When `read(0, buf, n)` runs, the kernel:

1. Looks up fd 0 → File of type Console.
2. Calls `console.read(buf, n)`.
3. `console.read` waits/copies/returns.

When `write(1, buf, n)`:

1. Looks up fd 1 → File of type Console.
2. Calls `console.write(buf, n)`.
3. `console.write` writes each byte to UART.

This means stdout printing is just a UART write under the hood. The "console" abstraction is thin.

`fstat(1, &st)` returns `st.type = T_Console`, which lets user programs detect "am I writing to a TTY?" and make formatting decisions.

---

## Summary & Key Takeaways

1. **Two console modes: Cooked and Raw.** Cooked echoes + buffers + handles control chars. Raw is per-byte unfiltered.

2. **`feedByte` is the entry point** from the UART RX ISR into the console layer.

3. **Cooked mode handles `\n`, backspace, `^C`, `^U`, `^D`** specially. Each control byte triggers a different action.

4. **`^C` calls `proc.kill(fg_pid)`** which sets the kill flag. Next syscall return → `proc.exit`.

5. **Raw mode is for editors.** Every byte arrives unmangled; the user program (e.g., `edit.zig`) is responsible for echo + line editing.

6. **ANSI escape sequences are byte sequences starting with `\x1b[`.** `\x1b[2J` clears, `\x1b[H` homes the cursor, `\x1b[A/B/C/D` are arrow keys.

7. **`edit.zig` redraws the entire screen on every keystroke.** Inefficient but simple. 16 KB buffer max.

8. **Saving uses `O_TRUNC + write`** — truncate to 0, then write full new content.

9. **fd 0/1/2 are Console-type Files.** Their `read`/`write` go through `console.zig`, not through inodes.

10. **`fstat(1)` reports `T_Console`** — user programs can detect TTY-ness.
