//! Freestanding wasm entry point. Replaces the original blocking
//! run() with chunked runStart / runStep so the JS Worker can
//! turn the simulation crank itself, draining output and forwarding
//! input between turns. See
//! docs/superpowers/specs/2026-04-25-snake-demo-design.md
//! "Wasm loop architecture (chunked execution)" for rationale.
//!
//! ELFs are loaded at runtime via fetch() — JS copies the bytes into
//! the 2 MB elf_buffer (via elfBufferPtr/elfBufferCap) then calls
//! runStart(elf_len, trace). No ELFs are embedded at compile time,
//! keeping ccc.wasm at ~50 KB (just the emulator core).
//!
//! Exports:
//!   elfBufferPtr()              [*]u8 — base of the 2 MB ELF receive buffer
//!   elfBufferCap()              u32   — capacity of the ELF buffer (2 MB)
//!   runStart(elf_len, trace)    i32   — initialise state, 0 on success
//!   runStep(maxInstructions)    i32   — -1 still running, ≥0 exit code
//!   consumeOutput()             u32   — bytes available since last drain
//!   outputPtr()                 [*]u8 — base of output buffer (drain offset)
//!   tracePtr()                  [*]u8 — base of trace buffer
//!   traceLen()                  u32   — bytes written to trace buffer
//!   setMtimeNs(ns)              void  — push real-time clock from JS

const std = @import("std");
const ccc = @import("ccc");
const cpu_mod = ccc.cpu;
const mem_mod = ccc.memory;
const halt_dev = ccc.halt;
const uart_dev = ccc.uart;
const clint_dev = ccc.clint;
const plic_dev = ccc.plic;
const block_dev = ccc.block;
const elf_mod = ccc.elf;

// 2 MB ELF receive buffer. JS fetches the selected program, copies
// its bytes here via elfBufferPtr/elfBufferCap, then calls
// runStart(elf_len, trace). snake.elf in Debug is ~1.4 MB.
const ELF_BUFFER_CAP: u32 = 2 * 1024 * 1024;
var elf_buffer: [ELF_BUFFER_CAP]u8 = undefined;

export fn elfBufferPtr() [*]u8 {
    return &elf_buffer;
}

export fn elfBufferCap() u32 {
    return ELF_BUFFER_CAP;
}

// 16 KB is comfortable headroom for a "hello world" run.
const OUTPUT_BUF_SIZE: usize = 16 * 1024;
var output_buf: [OUTPUT_BUF_SIZE]u8 = undefined;
var output_writer: std.Io.Writer = .fixed(&output_buf);
// Drain offset: bytes already consumed by JS via consumeOutput().
var output_consumed: usize = 0;

// Trace buffer: per-instruction CPU log when runStart(trace=1). Hello.elf
// runs ~5-50K instructions and each line is ~100 bytes; 8 MiB is
// comfortable headroom. Trace writes silently no-op once the buffer
// fills (cpu.zig catches the WriteFailed), so the CPU run never
// aborts — you just see a truncated trace.
const TRACE_BUF_SIZE: usize = 8 * 1024 * 1024;
var trace_buf: [TRACE_BUF_SIZE]u8 = undefined;
var trace_writer: std.Io.Writer = .fixed(&trace_buf);

// Module-level mtime source — JS sets it via setMtimeNs().
var mtime_ns: i128 = 0;
fn jsClock() i128 {
    return mtime_ns;
}

// 16 MiB of guest RAM is plenty for hello.elf.
const RAM_SIZE: usize = 16 * 1024 * 1024;

// Module-level emulator state that survives across runStep calls.
// The arena, devices, memory, and cpu all live here so no heap pointer
// escapes between calls. Only valid when state != null.
const RunState = struct {
    arena: std.heap.ArenaAllocator,
    halt: halt_dev.Halt,
    uart: uart_dev.Uart,
    clint: clint_dev.Clint,
    plic: plic_dev.Plic,
    block: block_dev.Block,
    mem: mem_mod.Memory,
    cpu: cpu_mod.Cpu,
};

var state_storage: RunState = undefined;
var state: ?*RunState = null;

// --- Exports ------------------------------------------------------------------

/// Base of the output buffer, offset by the current drain position.
/// JS reads [outputPtr()..outputPtr()+consumeOutput()) after each runStep.
export fn outputPtr() [*]const u8 {
    return @ptrCast(&output_buf[output_consumed]);
}

/// Return the number of bytes available since the last drain and advance
/// the drain offset. When the buffer is fully drained, both pointers
/// rewind to 0 so the buffer can be reused without copying.
export fn consumeOutput() u32 {
    const available: u32 = @intCast(output_writer.end - output_consumed);
    output_consumed += available;
    if (output_consumed == output_writer.end) {
        // Fully drained — rewind so the fixed buffer can be reused.
        output_writer.end = 0;
        output_consumed = 0;
    }
    return available;
}

export fn tracePtr() [*]const u8 {
    return &trace_buf;
}

export fn traceLen() u32 {
    return @intCast(trace_writer.end);
}

/// Push a real-time nanosecond timestamp from JS into the wasm so the
/// CLINT mtime register tracks wall-clock time (needed for snake's tick ISR).
export fn setMtimeNs(ns: i64) void {
    mtime_ns = @intCast(ns);
}

export fn pushInput(byte: u32) void {
    if (state) |s| {
        _ = s.uart.pushRx(@intCast(byte));
    }
}

/// Initialise emulator state from the ELF bytes already written into
/// elf_buffer[0..elf_len] by JS (via elfBufferPtr/elfBufferCap + fetch).
/// trace: non-zero enables per-instruction trace output.
/// Returns 0 on success, negative on error:
///   -1 mem init failed, -2 ELF parse/load failed, -5 bad elf_len.
export fn runStart(elf_len: u32, trace: i32) i32 {
    if (elf_len == 0 or elf_len > ELF_BUFFER_CAP) return -5;

    // Tear down any in-progress run before reinitialising.
    if (state != null) {
        state_storage.mem.deinit();
        state_storage.arena.deinit();
        state = null;
    }
    output_writer.end = 0;
    output_consumed = 0;
    trace_writer.end = 0;
    mtime_ns = 0;

    state_storage.arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    const a = state_storage.arena.allocator();

    state_storage.halt = halt_dev.Halt.init();
    state_storage.uart = uart_dev.Uart.init(&output_writer);
    state_storage.clint = clint_dev.Clint.init(&jsClock);
    state_storage.plic = plic_dev.Plic.init();
    state_storage.block = block_dev.Block.init();

    const io: std.Io = std.Io.failing;

    state_storage.mem = mem_mod.Memory.init(
        a,
        &state_storage.halt,
        &state_storage.uart,
        &state_storage.clint,
        &state_storage.plic,
        &state_storage.block,
        io,
        null,
        RAM_SIZE,
    ) catch return -1;

    const elf_bytes = elf_buffer[0..elf_len];
    const result = elf_mod.parseAndLoad(elf_bytes, &state_storage.mem) catch return -2;
    state_storage.mem.tohost_addr = result.tohost_addr;

    state_storage.cpu = cpu_mod.Cpu.init(&state_storage.mem, result.entry);
    if (trace != 0) state_storage.cpu.trace_writer = &trace_writer;

    state = &state_storage;
    return 0;
}

/// Advance the emulator by up to maxInstructions single steps.
/// Returns −1 if the program is still running, or the program's exit code
/// (≥ 0) when it halts. Cleans up state on halt so runStart can be called
/// again for a fresh run.
export fn runStep(max_instructions: u32) i32 {
    const s = state orelse return -1;

    var i: u32 = 0;
    while (i < max_instructions) : (i += 1) {
        // Check halt BEFORE executing the next instruction so the final
        // halt (set by the previous step's sb to the halt MMIO) is caught
        // on the first call after it fires rather than after an extra step.
        if (s.halt.exit_code) |code| {
            output_writer.flush() catch {};
            if (s.cpu.trace_writer) |tw| tw.flush() catch {};
            s.mem.deinit();
            s.arena.deinit();
            state = null;
            return @intCast(code);
        }
        // stepOne() executes exactly one instruction. When wfi is encountered,
        // idleSpin returns immediately (step_mode=true) rather than blocking —
        // the JS Worker will retry on the next runStep call after pushing
        // any pending input/events via the forthcoming T22 exports.
        s.cpu.stepOne() catch |err| switch (err) {
            error.Halt => {
                // Halt error from step: exit_code should now be set.
                output_writer.flush() catch {};
                if (s.cpu.trace_writer) |tw| tw.flush() catch {};
                s.mem.deinit();
                s.arena.deinit();
                state = null;
                const code = s.halt.exit_code orelse 0;
                return @intCast(code);
            },
            error.FatalTrap => {
                s.mem.deinit();
                s.arena.deinit();
                state = null;
                return -3;
            },
        };
    }
    return -1; // still running
}
