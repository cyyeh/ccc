// web/demo.js — main thread: Worker host + terminal renderer.

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

function updateProgramInstructions() {
  if (snakeInstructions) snakeInstructions.classList.toggle("hidden", sel.value !== SNAKE_IDX);
  if (shellInstructions) shellInstructions.classList.toggle("hidden", sel.value !== SHELL_IDX);
}

// Trace panel — auto-shown for non-interactive programs (e.g. hello.elf)
// after the program halts. Snake never halts (until the player presses q),
// and a continuous trace at 8 Hz × full-redraw would be MBs/sec, so we
// don't capture trace for it.
const traceBox  = document.getElementById("trace-details");
const tracePre  = document.getElementById("trace");
const traceMeta = document.getElementById("trace-meta");

// Programs that want an instruction trace captured + auto-displayed
// after halt. snake.elf intentionally absent.
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

const worker = new Worker("./runner.js", { type: "module" });

// Generation counter shared with the worker so stale messages from a
// superseded run are dropped instead of repainting the cleared screen.
let currentRunId = 0;

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

function render() {
  out.textContent = ansi.text();
}

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

worker.onmessage = (e) => {
  const msg = e.data;
  if (msg.type === "ready") {
    startCurrent();
    return;
  }
  // Drop replies from a superseded run so stale output can't repaint
  // the freshly cleared screen.
  if (msg.runId !== undefined && msg.runId !== currentRunId) return;
  if (msg.type === "output") {
    ansi.feed(msg.bytes);
    render();
    return;
  }
  if (msg.type === "trace") {
    if (tracePre) tracePre.textContent = new TextDecoder().decode(msg.bytes);
    if (traceMeta) traceMeta.textContent = `(${msg.bytes.length.toLocaleString()} bytes)`;
    if (traceBox) {
      traceBox.hidden = false;
      traceBox.open = true;
    }
    return;
  }
  if (msg.type === "halt") {
    const errSuffix = msg.error ? ` (${msg.error})` : "";
    out.textContent = ansi.text() + `\n[program halted${errSuffix} — change selection or refresh to replay]`;
    return;
  }
};

worker.postMessage({ type: "init", wasmUrl: "./ccc.wasm" });

updateProgramInstructions();

sel.addEventListener("change", () => {
  updateProgramInstructions();
  startCurrent();
});

out.addEventListener("focus", () => {
  if (hint) hint.classList.add("hidden");
});

out.addEventListener("blur", () => {
  if (hint) hint.classList.remove("hidden");
});

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

out.addEventListener("click", () => out.focus());
