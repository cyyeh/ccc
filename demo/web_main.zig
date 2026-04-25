//! Freestanding wasm entry point for the browser demo. Imports the
//! existing emulator modules (cpu / memory / elf / devices) verbatim
//! and exposes a minimal run / outputPtr / outputLen interface so
//! `web/demo.js` can instantiate the wasm with no imports, call
//! `run()`, and copy the captured output out of linear memory.

const std = @import("std");
const ccc = @import("ccc");
const cpu_mod = ccc.cpu;
const mem_mod = ccc.memory;
const halt_dev = ccc.halt;
const uart_dev = ccc.uart;
const clint_dev = ccc.clint;
const elf_mod = ccc.elf;

// hello.elf is embedded at compile time via an anonymous module that
// build.zig wires up: a co-located stub does the @embedFile so the
// path doesn't escape demo/'s package root. The build graph guarantees
// hello.elf is fresh before the wasm build runs (install_wasm depends
// on install_hello_elf).
const hello_elf = @import("hello_elf").BLOB;

// 16 KB is comfortable headroom for a "hello world" run.
const OUTPUT_BUF_SIZE: usize = 16 * 1024;
var output_buf: [OUTPUT_BUF_SIZE]u8 = undefined;
var output_writer: std.Io.Writer = .fixed(&output_buf);

// Trace buffer: per-instruction CPU log when run(trace=1). Hello.elf
// runs ~5-50K instructions and each line is ~100 bytes; 8 MiB is
// comfortable headroom. Trace writes silently no-op once the buffer
// fills (cpu.zig catches the WriteFailed), so the CPU run never
// aborts — you just see a truncated trace.
const TRACE_BUF_SIZE: usize = 8 * 1024 * 1024;
var trace_buf: [TRACE_BUF_SIZE]u8 = undefined;
var trace_writer: std.Io.Writer = .fixed(&trace_buf);

// hello.elf doesn't poll mtime, so a constant clock is sufficient.
fn zeroClock() i128 {
    return 0;
}

// 16 MiB of guest RAM is plenty for hello.elf.
const RAM_SIZE: usize = 16 * 1024 * 1024;

export fn outputPtr() [*]const u8 {
    return &output_buf;
}

export fn outputLen() u32 {
    return @intCast(output_writer.end);
}

export fn tracePtr() [*]const u8 {
    return &trace_buf;
}

export fn traceLen() u32 {
    return @intCast(trace_writer.end);
}

export fn run(trace: i32) i32 {
    output_writer.end = 0;
    trace_writer.end = 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var halt = halt_dev.Halt.init();
    var uart = uart_dev.Uart.init(&output_writer);
    var clint = clint_dev.Clint.init(zeroClock);

    var mem = mem_mod.Memory.init(a, &halt, &uart, &clint, null, RAM_SIZE) catch return -1;
    defer mem.deinit();

    const result = elf_mod.parseAndLoad(hello_elf, &mem) catch return -2;
    mem.tohost_addr = result.tohost_addr;

    var cpu = cpu_mod.Cpu.init(&mem, result.entry);
    if (trace != 0) {
        cpu.trace_writer = &trace_writer;
    }
    cpu.run() catch return -3;

    output_writer.flush() catch {};
    if (cpu.trace_writer) |tw| tw.flush() catch {};
    return @intCast(halt.exit_code orelse 0);
}
