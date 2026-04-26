// web/runner.js — Web Worker that hosts ccc.wasm and turns the
// chunked-step crank. See the spec's "Wasm loop architecture"
// section for the rationale.

let exports = null;
let memory = null;

self.onmessage = async (e) => {
  const msg = e.data;
  if (msg.type === "init") {
    const resp = await fetch(msg.wasmUrl);
    const bytes = await resp.arrayBuffer();
    const result = await WebAssembly.instantiate(bytes, {});
    exports = result.instance.exports;
    memory = exports.memory;
    self.postMessage({ type: "ready" });
    return;
  }
  if (!exports) return;

  if (msg.type === "select") {
    exports.selectProgram(msg.idx);
    return;
  }
  if (msg.type === "start") {
    const trace = msg.trace ? 1 : 0;
    const rc = exports.runStart(msg.idx, trace);
    if (rc !== 0) {
      self.postMessage({ type: "halt", code: rc });
      return;
    }
    runLoop();
    return;
  }
  if (msg.type === "input") {
    exports.pushInput(msg.byte);
    return;
  }
};

function runLoop() {
  const startMs = performance.now();
  const CHUNK = 50000;

  function tick() {
    const elapsedNs = BigInt(Math.round((performance.now() - startMs) * 1e6));
    exports.setMtimeNs(elapsedNs);
    const exit = exports.runStep(CHUNK);
    drain();
    if (exit !== -1) {
      self.postMessage({ type: "halt", code: exit });
      return;
    }
    setTimeout(tick, 0);
  }
  tick();
}

function drain() {
  const len = exports.consumeOutput();
  if (len === 0) return;
  const ptr = exports.outputPtr();
  // Copy out — message-passing transfer requires a fresh buffer
  // since `memory` is shared with the wasm and might move (it can't,
  // but explicit copy is safe).
  const slice = new Uint8Array(memory.buffer, ptr, len);
  const copy = new Uint8Array(slice); // copies via constructor
  self.postMessage({ type: "output", bytes: copy }, [copy.buffer]);
}
