// web/runner.js — Web Worker that hosts ccc.wasm and turns the
// chunked-step crank. See the spec's "Wasm loop architecture"
// section for the rationale.

let exports = null;
let memory = null;

// Generation counter — bumped on every "start". The previous run's
// tick chain checks this and retires when superseded, so switching
// programs can't leak old-program output past the screen clear.
let currentRunId = 0;

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

  if (msg.type === "start") {
    const myRunId = ++currentRunId;
    const trace = msg.trace ? 1 : 0;
    try {
      // Fetch ELF and (optional) disk image in parallel. Both go straight
      // into wasm linear memory once they arrive — no double-buffering.
      const elfFetch = fetch(msg.elfUrl).then(async (r) => {
        if (!r.ok) throw new Error(`fetch ${msg.elfUrl} → ${r.status}`);
        return new Uint8Array(await r.arrayBuffer());
      });
      const diskFetch = msg.diskUrl
        ? fetch(msg.diskUrl).then(async (r) => {
            if (!r.ok) throw new Error(`fetch ${msg.diskUrl} → ${r.status}`);
            return new Uint8Array(await r.arrayBuffer());
          })
        : Promise.resolve(null);

      const [elfBytes, diskBytes] = await Promise.all([elfFetch, diskFetch]);
      if (myRunId !== currentRunId) return; // superseded during fetch

      // Copy ELF into wasm.
      const elfCap = exports.elfBufferCap();
      if (elfBytes.length > elfCap) {
        throw new Error(`ELF too large: ${elfBytes.length} > ${elfCap}`);
      }
      const elfPtr = exports.elfBufferPtr();
      new Uint8Array(memory.buffer, elfPtr, elfBytes.length).set(elfBytes);

      // Copy disk into wasm if present.
      let diskLen = 0;
      if (diskBytes) {
        const diskCap = exports.diskBufferCap();
        if (diskBytes.length > diskCap) {
          throw new Error(`disk too large: ${diskBytes.length} > ${diskCap}`);
        }
        const diskPtr = exports.diskBufferPtr();
        new Uint8Array(memory.buffer, diskPtr, diskBytes.length).set(diskBytes);
        diskLen = diskBytes.length;
      }

      const rc = exports.runStart(elfBytes.length, trace, diskLen);
      if (rc !== 0) {
        self.postMessage({ type: "halt", runId: myRunId, code: rc });
        return;
      }
      runLoop(myRunId);
    } catch (err) {
      self.postMessage({ type: "halt", runId: myRunId, code: -99, error: String(err) });
    }
    return;
  }
  if (msg.type === "input") {
    exports.pushInput(msg.byte);
    return;
  }
};

function runLoop(runId) {
  const startMs = performance.now();
  const CHUNK = 50000;

  function tick() {
    if (runId !== currentRunId) return; // superseded — abandon this chain
    const elapsedNs = BigInt(Math.round((performance.now() - startMs) * 1e6));
    exports.setMtimeNs(elapsedNs);
    const exit = exports.runStep(CHUNK);
    drain(runId);
    if (exit !== -1) {
      drainTrace(runId);
      self.postMessage({ type: "halt", runId, code: exit });
      return;
    }
    setTimeout(tick, 0);
  }
  tick();
}

function drainTrace(runId) {
  const len = exports.traceLen();
  if (len === 0) return;
  const ptr = exports.tracePtr();
  const slice = new Uint8Array(memory.buffer, ptr, len);
  const copy = new Uint8Array(slice);
  self.postMessage({ type: "trace", runId, bytes: copy }, [copy.buffer]);
}

function drain(runId) {
  const len = exports.consumeOutput();
  if (len === 0) return;
  const ptr = exports.outputPtr();
  // Copy out — message-passing transfer requires a fresh buffer
  // since `memory` is shared with the wasm and might move (it can't,
  // but explicit copy is safe).
  const slice = new Uint8Array(memory.buffer, ptr, len);
  const copy = new Uint8Array(slice); // copies via constructor
  self.postMessage({ type: "output", runId, bytes: copy }, [copy.buffer]);
}
