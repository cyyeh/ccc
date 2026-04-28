# console-and-editor: A Beginner's Guide

## Why Doesn't Pressing 'a' Just Send 'a'?

You'd think it would. You press 'a', the kernel sees 0x61, the program reading stdin gets 0x61. Done.

The real story is more complicated, for good reason.

When you're typing at a shell prompt, the kernel is doing a lot of work for you:

- **Echoing each keystroke** so you see what you typed.
- **Buffering** so the shell only sees a complete line at a time.
- **Handling backspace** to fix typos before pressing Enter.
- **Catching `^C`** to kill the running program.
- **Catching `^D`** to mean "no more input."
- **Catching `^U`** to delete the whole line.

This is called **cooked mode** (or "line discipline"). It's the kernel pretending to be a smart input method.

But when you're editing a file in a text editor, you don't want any of that. The editor wants:
- Every keystroke immediately (no buffering).
- No echo (the editor decides what to draw).
- No line discipline (Enter is just '\n', not "commit the line").
- No backspace handling (the editor draws the cursor moving).

So there's a **raw mode** the editor switches into.

---

## What Cooked Mode Does, Step by Step

You're in `bash`. You type:

```
hello[backspace][backspace]p Mom\n
```

(That is: "hello", two backspaces, " Mom\n".)

Kernel's view, byte by byte:

1. **'h' (0x68).** Append to line buffer. Echo 'h' (write 'h' to UART → screen).
2. **'e' (0x65).** Same.
3. **'l', 'l', 'o'.** Same.
4. **Backspace (0x7F).** Pop one char from buffer. Echo "\b \b" (move left, overwrite with space, move left).
5. **Backspace.** Same. Now line buffer has "hel". Screen shows "hel".
6. **'p'.** Append. Echo 'p'. Screen: "help".
7. **' ' (space).** Append. Echo ' '.
8. **'M', 'o', 'm'.** Append. Echo. Screen: "help Mom".
9. **'\n' (0x0A).** Append '\n'. Echo '\n'. **Commit the line** — wake any sleeping `read()`.

The shell, blocked in `read(0, buf, 256)`, now returns with `buf = "help Mom\n"`. The shell tokenizes, runs `help` with arg `Mom`.

This pattern is so universal that it's been in Unix since 1971. Every Unix-like OS implements it.

---

## What's `^C` Doing?

You ran `cat`. It's reading from stdin, blocking. You press `^C`.

`^C` is byte 0x03 (Control + C in ASCII). The kernel's cooked mode sees it and:

1. Echoes "^C\n" (so you see that ^C was acknowledged).
2. Calls `proc.kill(fg_pid)` where `fg_pid` is the foreground process (cat).

`proc.kill` sets `cat.killed = true`. The next time cat returns from a syscall (specifically, the `read` it's currently in), the kernel sees the kill flag and replaces the normal return with `proc.exit(cat, 1)`.

cat dies. Shell's `wait` returns. Prompt comes back.

That's the entire `^C` mechanism. Two states (the kill flag and "fg_pid"), one byte (0x03), and a check on every syscall return. Simple, robust, and enough for "kill the running program."

---

## What's `^D` Doing?

`^D` (0x04) is "end of file" in cooked mode.

When cat is reading from stdin and you press `^D`:
- If there are unread bytes in the buffer (you typed some text and hit ^D without ^M), commit them as if you had pressed Enter.
- If the buffer is empty, signal EOF — `read` returns 0.

cat's read returns 0 (EOF), so cat's main loop ends, cat calls exit. Done.

This is why "^D" is the way to gracefully end a `cat`-like program. You're not killing it; you're saying "no more input."

---

## What's `^U` Doing?

`^U` (0x15) is "kill the current line." If you're typing a long command and realize it's wrong, ^U erases the whole line.

Mechanism: pop every char back to the start of the line, echoing "\b \b" for each. The buffer's edit index resets to where the committed bytes end.

---

## Raw Mode: For Editors

`edit.zig` doesn't want any of this. It wants every byte. It wants to draw a cursor that moves.

When `edit.zig` starts:

1. It does some syscall to set `console.mode = Raw`.
2. From now on, `feedByte` just appends to the input buffer and wakes the reader. No echo. No line discipline.
3. The editor reads bytes one at a time. For each:
   - Printable byte → insert into the in-memory buffer, redraw screen.
   - Backspace → delete char before cursor, redraw.
   - `^X` → exit (after restoring cooked mode).
   - `^S` → save file.
   - ESC → start of an "arrow key" sequence; read 2 more bytes to determine which arrow.

When the editor exits, it sets `console.mode = Cooked` again. Otherwise the next shell prompt would be unusable.

---

## ANSI Escape Sequences: How the Editor Draws

How does the editor "move the cursor"? It writes a sequence of bytes that the terminal interprets as a control command.

The sequence starts with the ESC character (0x1B), then `[`, then arguments, then a final letter.

Examples:

| Bytes | Effect |
|-------|--------|
| `\x1b[2J` | Clear entire screen |
| `\x1b[H` | Move cursor to row 1, column 1 |
| `\x1b[5;10H` | Move cursor to row 5, column 10 |
| `\x1b[A` | Cursor up one row (also: what arrow-up sends *to* the program) |

The interpretation happens at the *terminal* (the thing rendering bytes onto the screen). In a real terminal emulator (Terminal.app, iTerm2, xterm), these sequences are decoded and acted on.

In `ccc`'s wasm demo, `web/ansi.js` is a ~120-line JS interpreter that handles the same subset. The wasm guest emits ANSI bytes; ansi.js sees them and updates the JS-side terminal grid; the result is rendered as DOM.

When `edit.zig` redraws after every keystroke:
1. `write("\x1b[2J")` — clear screen.
2. `write("\x1b[H")` — home cursor.
3. `write(buffer)` — dump the file's bytes (this writes them into the terminal grid at the home cursor and onward, line by line).
4. Compute `(row, col)` of the cursor's byte offset.
5. `write("\x1b[{row};{col}H")` — move terminal cursor to where the editor's cursor is.

Now the terminal shows the file contents with a cursor blinking at the right place.

---

## A Full Round-Trip: ^C in the Web Demo

You're in the web demo, at the shell prompt. You start typing `cat /`. You change your mind and want to abort.

You press Control+C in the browser:

1. JS keyhandler captures `Ctrl+C`. Sends `byte: 0x03` to the wasm worker.
2. wasm `pushInput(0x03)` calls `uart.pushRx(0x03)`.
3. `pushRx` notes empty→non-empty (well, maybe non-empty already), but PLIC source 10 is asserted regardless if level-triggered.
4. CPU is in `wfi` or running shell. `check_interrupt` fires; SEI trap.
5. Kernel's UART ISR runs. Calls `console.feedByte(0x03)`.
6. `feedByte` is in cooked mode. Sees 0x03. Echoes "^C\n". Looks up `fg_pid`. Calls `proc.kill(fg_pid)`.
7. `fg_pid` was the shell (because the shell is blocked in `read(0, ...)` waiting for the rest of the line). Wait — actually no, the shell is the *foreground* process, but in this scenario you haven't pressed Enter, so the shell hasn't forked anyone yet. `fg_pid` *is* the shell.
8. Shell.killed = true. Shell wakes from sleep. Read returns -1.
9. Shell's syscall handler returns. Dispatch sees killed. Calls `proc.exit(shell, 1)`.
10. Shell dies. PID 1 (init_shell) reaps it. init_shell's loop: re-fork sh, exec sh. New shell prompt.

So `^C` at the *shell prompt* kills the shell, but init reborn it. Effectively: prompt resets. Same UX as `bash` ^C.

If a command (`cat`) had been running, `fg_pid` would have been cat's pid; ^C would kill cat, shell's wait4 returns, shell prints prompt.

---

## Quick Reference

| Concept | One-liner |
|---------|-----------|
| Cooked mode | Default. Kernel echoes + buffers + handles control chars. |
| Raw mode | Editor mode. Every byte raw to the program; no echo, no buffering. |
| Line buffer | The 128-byte ring buffer where cooked bytes accumulate. |
| `feedByte` | Console's entry from the UART ISR. |
| `\x1b[2J` | ANSI: clear screen. |
| `\x1b[H` | ANSI: home cursor. |
| `\x1b[r;cH` | ANSI: move cursor to (r, c). |
| `\x1b[A/B/C/D` | ANSI arrow keys (sent by terminal on arrow-key press). |
| `^C` (0x03) | In cooked: kill foreground process. In raw: just a byte. |
| `^D` (0x04) | In cooked: EOF (or commit if buffer non-empty). |
| `^U` (0x15) | In cooked: kill the current line buffer. |
| Backspace (0x7F) | In cooked: erase char before cursor. |
| `\n` (0x0A) | In cooked: commit line, wake reader. |
| TTY detection | `fstat(fd).type == T_Console` lets a program know it's on a terminal. |
