const outputEl   = document.getElementById("output");
const statusEl   = document.getElementById("status");
const runBtn     = document.getElementById("run-btn");
const traceCb    = document.getElementById("trace-toggle");
const traceBox   = document.getElementById("trace-details");
const traceEl    = document.getElementById("trace");
const traceMeta  = document.getElementById("trace-meta");
const wasmSizeEl = document.getElementById("wasm-size");

function appendOutput(text, cls) {
  if (!text) return;
  const span = document.createElement("span");
  if (cls) span.className = cls;
  span.textContent = text;
  outputEl.appendChild(span);
  outputEl.scrollTop = outputEl.scrollHeight;
}

function setStatus(text) { statusEl.textContent = text; }
function clearOutput() { outputEl.textContent = ""; }
function clearTrace()  { traceEl.textContent = ""; traceMeta.textContent = ""; traceBox.hidden = true; }

function fmtBytes(n) {
  if (n >= 1024 * 1024) return `${(n / 1024 / 1024).toFixed(1)} MB`;
  if (n >= 1024)        return `${(n / 1024).toFixed(1)} KB`;
  return `${n} B`;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let instance = null;

async function load() {
  setStatus("fetching ccc.wasm…");
  const resp = await fetch("ccc.wasm");
  if (!resp.ok) throw new Error(`ccc.wasm: HTTP ${resp.status}`);
  const bytes = await resp.arrayBuffer();
  const sizeStr = fmtBytes(bytes.byteLength);
  wasmSizeEl.textContent = sizeStr;
  const result = await WebAssembly.instantiate(bytes, {});
  instance = result.instance;
  setStatus(`loaded · wasm ${sizeStr}`);
  runBtn.disabled = false;
  runBtn.textContent = "▶ run ccc hello.elf";
}

async function runDemo() {
  if (!instance) return;
  clearOutput();
  clearTrace();
  runBtn.disabled = true;

  const traceEnabled = traceCb.checked;
  const cmd = traceEnabled ? "./ccc --trace hello.elf" : "./ccc hello.elf";

  // 1. Prompt + animated typing of the command.
  setStatus("typing…");
  appendOutput("$ ", "prompt");
  for (const ch of cmd) {
    appendOutput(ch, "cmd");
    await sleep(45 + Math.random() * 55); // 45-100ms per char, gentle jitter
  }
  appendOutput("\n");

  // 2. Run the wasm.
  setStatus(traceEnabled ? "running ccc /hello.elf (with trace)…" : "running ccc /hello.elf…");
  // Yield once so the "running" status paints before the (sub-millisecond) wasm call.
  await sleep(0);

  let exitCode = -100;
  try {
    exitCode = instance.exports.run(traceEnabled ? 1 : 0);
  } catch (e) {
    appendOutput(`runtime error: ${e}\n`, "stderr");
  }

  // 3. Output region (existing behavior).
  const outPtr = instance.exports.outputPtr();
  const outLen = instance.exports.outputLen();
  const outBytes = new Uint8Array(instance.exports.memory.buffer, outPtr, outLen);
  appendOutput(new TextDecoder().decode(outBytes));
  appendOutput(`\n[exit ${exitCode}]\n`, "meta");

  // 4. Trailing prompt — implies the shell is ready for another command.
  appendOutput("$ ", "prompt");

  // 5. Trace region (existing behavior, unchanged).
  if (traceEnabled) {
    const tPtr = instance.exports.tracePtr();
    const tLen = instance.exports.traceLen();
    const tBytes = new Uint8Array(instance.exports.memory.buffer, tPtr, tLen);
    const tText = new TextDecoder().decode(tBytes);
    traceEl.textContent = tText;
    const lineCount = tText ? tText.split("\n").length - (tText.endsWith("\n") ? 1 : 0) : 0;
    traceMeta.textContent = `(${fmtBytes(tLen)} · ${lineCount.toLocaleString()} instructions)`;
    traceBox.hidden = false;
    traceBox.open = true;
  }

  setStatus(`done · exit ${exitCode}${traceEnabled ? " · trace captured" : ""}`);
  runBtn.disabled = false;
  runBtn.textContent = "▶ run again";
}

runBtn.addEventListener("click", runDemo);

load()
  .then(runDemo)
  .catch((e) => {
    setStatus(`error: ${e.message}`);
    appendOutput(`failed to load demo: ${e.message}\n`, "stderr");
  });
