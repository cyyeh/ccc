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

function runDemo() {
  if (!instance) return;
  clearOutput();
  clearTrace();
  const traceEnabled = traceCb.checked;
  setStatus(traceEnabled ? "running ccc /hello.elf (with trace)…" : "running ccc /hello.elf…");
  runBtn.disabled = true;

  let exitCode = -100;
  try {
    exitCode = instance.exports.run(traceEnabled ? 1 : 0);
  } catch (e) {
    appendOutput(`runtime error: ${e}\n`, "stderr");
  }

  // Output region
  const outPtr = instance.exports.outputPtr();
  const outLen = instance.exports.outputLen();
  const outBytes = new Uint8Array(instance.exports.memory.buffer, outPtr, outLen);
  appendOutput(new TextDecoder().decode(outBytes));
  appendOutput(`\n[exit ${exitCode}]\n`, "meta");

  // Trace region (only if requested)
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
