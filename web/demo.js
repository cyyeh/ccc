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
const traceHint  = document.getElementById("trace-hint");

const ELF_URLS = {
  "0": "./hello.elf",
  "1": "./snake.elf",
};

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
  ansi._reset();
  ansi.row = 0; ansi.col = 0;
  render();

  const idx = parseInt(sel.value, 10);
  const elfUrl = ELF_URLS[String(idx)];
  if (!elfUrl) {
    out.textContent = `[unknown program idx ${idx}]`;
    return;
  }

  // Trace toggle handling — disable for snake (runs continuously).
  if (traceCb) {
    const isInteractive = idx === 1;
    if (isInteractive) {
      traceCb.checked = false;
      traceCb.disabled = true;
      if (traceBox) traceBox.hidden = true;
      if (traceHint) traceHint.hidden = false;
    } else {
      traceCb.disabled = false;
      if (traceHint) traceHint.hidden = true;
    }
  }

  const trace = traceCb && traceCb.checked ? 1 : 0;
  worker.postMessage({ type: "start", elfUrl, trace });
}

worker.onmessage = (e) => {
  const msg = e.data;
  if (msg.type === "ready") {
    startCurrent();
    return;
  }
  if (msg.type === "output") {
    ansi.feed(msg.bytes);
    render();
    return;
  }
  if (msg.type === "halt") {
    const errSuffix = msg.error ? ` (${msg.error})` : "";
    out.textContent = ansi.text() + `\n[program halted${errSuffix} — change selection or refresh to replay]`;
    return;
  }
};

worker.postMessage({ type: "init", wasmUrl: "./ccc.wasm" });

sel.addEventListener("change", () => {
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
