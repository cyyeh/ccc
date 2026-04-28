# console-and-editor: Practice & Self-Assessment

---

## Section 1: True or False (10 questions)

**1.** Cooked mode is the default; raw mode requires an explicit syscall to switch.

**2.** In cooked mode, `^C` (0x03) is interpreted by the user program, not the kernel.

**3.** `\n` (0x0A) commits the line buffer in cooked mode.

**4.** In raw mode, the kernel echoes each byte the way cooked mode does.

**5.** ANSI escape sequences begin with the byte 0x1B (ESC).

**6.** Arrow keys send three bytes: ESC, '[', and a letter A/B/C/D.

**7.** The editor uses 16 KB max buffer.

**8.** `^S` (0x13) saves the file using `O_APPEND`.

**9.** When the editor exits, it must restore cooked mode or the next shell session is broken.

**10.** `fstat(1, &st).type == T_Console` is how a program detects it's writing to a TTY.

### Answers

1. **True.** `console.zig` initializes `mode = .Cooked`.
2. **False.** Cooked mode kernel-side handles `^C`. Raw mode passes it through.
3. **True.** Specifically, `\n` triggers the wakeup that lets `read()` return.
4. **False.** Raw mode does NOT echo. The user program is responsible.
5. **True.** Or in some references, 0x9B (single-byte CSI), but `ccc` uses ESC + `[` (two bytes).
6. **True.** That's the standard CSI cursor encoding.
7. **True.** `BUFFER_SIZE = 16384` in `edit.zig`.
8. **False.** It uses `O_TRUNC` — truncate to 0, then write the full new content.
9. **True.** `leaveRaw()` is called on exit. Without it, the shell would see raw bytes and break.
10. **True.** `T_Console` is the Stat type for fd 0/1/2.

---

## Section 2: Multiple Choice (8 questions)

**1.** The cooked-mode line buffer in `ccc` is how big?
- A. 16 bytes.
- B. 128 bytes.
- C. 1024 bytes.
- D. Unlimited.

**2.** When you press Enter in cooked mode, what happens?
- A. The byte is dropped.
- B. The line is committed; `read()` (if blocked) wakes; `\n` echoed.
- C. The buffer is cleared.
- D. The shell is killed.

**3.** What does ^U do in cooked mode?
- A. Sends EOF.
- B. Kills the foreground process.
- C. Erases the entire line buffer.
- D. Suspends the program.

**4.** The editor's main loop reads bytes and dispatches. Which is *not* a recognized byte?
- A. `^S` (save).
- B. `^X` (exit).
- C. `^Z` (suspend).
- D. ESC `[` `A` (arrow up).

**5.** What ANSI sequence does the editor send to clear the screen?
- A. `\x1b[1J`
- B. `\x1b[2J`
- C. `\x1bC`
- D. `\x1b[!`

**6.** When `^C` is pressed, who tells the foreground process to die?
- A. The shell.
- B. `console.feedByte` calls `proc.kill(fg_pid)`.
- C. The user program polls a "killed" flag.
- D. A signal handler.

**7.** Why doesn't pressing arrow keys in cooked mode usually do anything useful?
- A. The kernel discards them.
- B. The kernel buffers them as ESC `[` `A` etc., and the shell doesn't interpret them as line-editing commands.
- C. The terminal doesn't send them in cooked mode.
- D. They get rendered as garbage.

**8.** When the editor is in raw mode and the user presses Enter, what does `feedByte` do?
- A. Buffers and waits for ^D.
- B. Echoes "\n" and commits.
- C. Just appends 0x0A to the buffer; wakes the reader; no special handling.
- D. Translates to ESC `[` H.

### Answers

1. **B.** `INPUT_BUF_SIZE = 128`.
2. **B.** That's the cooked-mode commit semantics.
3. **C.** ^U is "kill the line." Note: this is *line* erase, not process kill.
4. **C.** ^Z is the "suspend" key in real shells (sends SIGTSTP). `ccc` doesn't have signals; ^Z is just a byte the editor's main switch falls through on.
5. **B.** `\x1b[2J` is "clear entire screen."
6. **B.** Cooked-mode `feedByte` recognizes 0x03 and calls `proc.kill`.
7. **B.** Cooked mode passes the multi-byte ESC sequence into the line buffer; the shell's read sees them as part of the command line. Hence why pressing arrow at a basic shell prompt produces `^[[A` etc.
8. **C.** Raw mode is "every byte unfiltered." No echo, no special meaning.

---

## Section 3: Scenario Analysis (3 scenarios)

**Scenario 1: A program that doesn't see typed bytes**

You write a program that calls `read(0, &c, 1)` in a loop. You type 'a', 'b', 'c', press Enter. The program prints "abc\n" all at once when you press Enter. Why?

1. Why doesn't 'a' come through immediately?
2. How would you make it come through immediately?
3. What's the trade-off?

**Scenario 2: An editor that breaks the next shell prompt**

You're testing a new editor. It quits, you get the shell prompt back, but typing 'l', 's', '\n' shows nothing on screen and doesn't run `ls`. What happened?

1. What state is the console probably in?
2. What syscall did the editor forget?
3. How do you recover the shell session in `ccc`?

**Scenario 3: ^C kills the wrong process**

The shell forks+execs cat. You press ^C. cat dies, but the shell *also* exits. Why?

1. Where is `fg_pid` updated?
2. What if `fg_pid` was never updated to cat's PID?
3. How does init_shell recover from this in `ccc`?

### Analysis

**Scenario 1: Bytes only on Enter**

1. Cooked mode buffers until `\n`. The bytes 'a', 'b', 'c' sit in the line buffer; no commit; `read` is blocked.
2. Switch to raw mode. Now each byte arrives instantly.
3. Trade-off: you lose backspace handling, ^C handling, line editing. The program has to do that itself if it wants any. Most "simple" programs (cat, echo) work fine in cooked mode; only editors and games want raw.

**Scenario 2: Broken shell after editor**

1. Console is still in raw mode. The editor forgot to switch back.
2. `console.setMode(Cooked)` (or whatever the kernel-side syscall is).
3. In `ccc`, you'd need to send a byte that triggers the cooked-mode switch — but there's no such byte in raw mode (raw mode is "all bytes are data"). Practically: kill the kernel and start over. Production shells have a `stty sane` command for this; `ccc` doesn't.

**Scenario 3: ^C killing the shell**

1. The shell sets `fg_pid` when it forks a child for execution (something like `console.setFgPid(child_pid)`). When the child exits, the shell sets `fg_pid` back to its own PID.
2. If `fg_pid` was never updated (always pointed at the shell), then ^C kills the shell. Cat would still be running but receiving no signal.
3. `init_shell` in `ccc` is a `fork→exec(sh)→wait` loop. When the shell exits, init re-forks a fresh shell. So even if the user kills the shell with ^C, the loop relaunches it; the user sees a fresh prompt.

---

## Section 4: Reflection Questions

1. **Why is cooked mode the default?** What would happen if raw mode were default and programs had to opt into cooked?

2. **Echo in raw mode.** The editor draws characters via its redraw loop. Could you implement raw-mode echo at the kernel level? Why does `ccc` keep echo entirely in cooked mode?

3. **ANSI's universality.** The same `\x1b[2J` works on xterm, Terminal.app, iTerm2, GNOME Terminal, and `ccc`'s wasm demo. Why is this standard so durable?

4. **`^C` vs POSIX signals.** `ccc`'s kill flag is simpler than signals but less powerful. What can signals do that the kill flag can't?

5. **The editor's full-redraw approach.** When does this stop working (file size, terminal latency, refresh rate)? Sketch a diff-based redraw.
