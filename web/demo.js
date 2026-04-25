const outputEl = document.getElementById("output");
const statusEl = document.getElementById("status");
const runBtn   = document.getElementById("run-btn");

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

let instance = null;
let wasmSizeKB = 0;

async function load() {
  setStatus("fetching ccc.wasm…");
  const resp = await fetch("ccc.wasm");
  if (!resp.ok) throw new Error(`ccc.wasm: HTTP ${resp.status}`);
  const bytes = await resp.arrayBuffer();
  wasmSizeKB = (bytes.byteLength / 1024).toFixed(1);
  const result = await WebAssembly.instantiate(bytes, {});
  instance = result.instance;
  setStatus(`loaded · wasm ${wasmSizeKB} KB`);
  runBtn.disabled = false;
  runBtn.textContent = "▶ run ccc hello.elf";
}

function runDemo() {
  if (!instance) return;
  clearOutput();
  setStatus("running ccc /hello.elf…");
  runBtn.disabled = true;

  let exitCode = -100;
  try {
    exitCode = instance.exports.run();
  } catch (e) {
    appendOutput(`runtime error: ${e}\n`, "stderr");
  }

  const ptr = instance.exports.outputPtr();
  const len = instance.exports.outputLen();
  const bytes = new Uint8Array(instance.exports.memory.buffer, ptr, len);
  appendOutput(new TextDecoder().decode(bytes));
  appendOutput(`\n[exit ${exitCode}]\n`, "meta");

  setStatus(`done · exit ${exitCode}`);
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
