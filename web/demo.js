// web/demo.js — main thread: Worker host + terminal renderer.

import { Ansi } from "./ansi.js";

const W = 32, H = 16;
const ansi = new Ansi(W, H);
const out = document.getElementById("output");
const sel = document.getElementById("program-select");
const hint = document.querySelector(".program-hint");

// Trace controls — element IDs as defined in index.html.
const traceCb    = document.getElementById("trace-toggle");
const traceBox   = document.getElementById("trace-details");

const worker = new Worker("./runner.js", { type: "module" });

const ALLOWED_KEYS = {
  "w": 0x77, "W": 0x77,
  "a": 0x61, "A": 0x61,
  "s": 0x73, "S": 0x73,
  "d": 0x64, "D": 0x64,
  "q": 0x71, "Q": 0x71,
  " ": 0x20,
};

function render() {
  out.textContent = ansi.text();
}

function startCurrent() {
  // Reset display + ANSI state.
  ansi._reset();
  ansi.row = 0; ansi.col = 0;
  render();

  const idx = parseInt(sel.value, 10);

  // Snake (idx === 1) runs continuously — hide trace toggle to avoid
  // flooding MBs/sec of trace data. For hello.elf (idx === 0) keep it.
  if (traceCb) {
    const isInteractive = idx === 1; // snake
    if (isInteractive) {
      traceCb.checked = false;
      traceCb.disabled = true;
      if (traceBox) traceBox.hidden = true;
    } else {
      traceCb.disabled = false;
    }
  }

  const trace = traceCb && traceCb.checked ? 1 : 0;
  worker.postMessage({ type: "start", idx, trace });
}

worker.onmessage = (e) => {
  const msg = e.data;
  if (msg.type === "ready") {
    worker.postMessage({ type: "select", idx: parseInt(sel.value, 10) });
    startCurrent();
    return;
  }
  if (msg.type === "output") {
    ansi.feed(msg.bytes);
    render();
    return;
  }
  if (msg.type === "halt") {
    out.textContent = ansi.text() + "\n[program halted — change selection or refresh to replay]";
    return;
  }
};

worker.postMessage({ type: "init", wasmUrl: "./ccc.wasm" });

sel.addEventListener("change", () => {
  worker.postMessage({ type: "select", idx: parseInt(sel.value, 10) });
  startCurrent();
});

out.addEventListener("focus", () => {
  if (hint) hint.classList.add("hidden");
});

out.addEventListener("blur", () => {
  if (hint) hint.classList.remove("hidden");
});

out.addEventListener("keydown", (e) => {
  const byte = ALLOWED_KEYS[e.key];
  if (byte === undefined) return;
  e.preventDefault();
  worker.postMessage({ type: "input", byte });
});

out.addEventListener("click", () => out.focus());
