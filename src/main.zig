const std = @import("std");
const Io = std.Io;
const cpu_mod = @import("cpu.zig");
const csr_mod = @import("csr.zig");
const mem_mod = @import("memory.zig");
const halt_dev = @import("devices/halt.zig");
const uart_dev = @import("devices/uart.zig");
const clint_dev = @import("devices/clint.zig");
const plic_dev = @import("devices/plic.zig");
const elf_mod = @import("elf.zig");

comptime {
    _ = @import("cpu.zig");
    _ = @import("memory.zig");
    _ = @import("devices/halt.zig");
    _ = @import("devices/uart.zig");
    _ = @import("devices/clint.zig");
    _ = @import("devices/plic.zig");
    _ = @import("decoder.zig");
    _ = @import("execute.zig");
    _ = @import("csr.zig");
    _ = @import("trap.zig");
    _ = @import("elf.zig");
    _ = @import("trace.zig");
}

const Args = struct {
    raw_addr: ?u32 = null,
    file: ?[]const u8 = null,
    trace: bool = false,
    halt_on_trap: bool = false,
    memory_mb: u32 = 128,
};

const ArgsError = error{
    MissingArg,
    UnknownOption,
    TooManyPositional,
    MissingFile,
    InvalidAddress,
    InvalidMemory,
};

fn parseArgs(argv: []const [:0]const u8, stderr: *Io.Writer) ArgsError!Args {
    var args: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--raw")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            args.raw_addr = std.fmt.parseInt(u32, argv[i], 0) catch return error.InvalidAddress;
        } else if (std.mem.eql(u8, a, "--trace")) {
            args.trace = true;
        } else if (std.mem.eql(u8, a, "--halt-on-trap")) {
            args.halt_on_trap = true;
        } else if (std.mem.eql(u8, a, "--memory")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            const mb = std.fmt.parseInt(u32, argv[i], 0) catch return error.InvalidMemory;
            if (mb == 0 or mb > 4096) return error.InvalidMemory;
            args.memory_mb = mb;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            printUsage(stderr) catch {};
            std.process.exit(0);
        } else if (a.len > 0 and a[0] == '-') {
            stderr.print("unknown option: {s}\n", .{a}) catch {};
            stderr.flush() catch {};
            return error.UnknownOption;
        } else {
            if (args.file != null) return error.TooManyPositional;
            args.file = a;
        }
    }
    if (args.file == null) return error.MissingFile;
    return args;
}

fn printUsage(stderr: *Io.Writer) !void {
    try stderr.print(
        \\usage: ccc [options] <program>
        \\
        \\Run a RISC-V program in the emulator.
        \\
        \\Arguments:
        \\  <program>           Path to ELF file (default) or raw binary (with --raw).
        \\
        \\Options:
        \\  --raw <addr>        Treat <program> as a raw binary loaded at <addr> (hex).
        \\  --trace             Print one line per executed instruction to stderr.
        \\  --memory <MB>       Override RAM size (default: 128).
        \\  --halt-on-trap      Stop on first unhandled trap (default: enter trap handler).
        \\  -h, --help          Show this help.
        \\
    , .{});
    try stderr.flush();
}

fn dumpTrapDiagnostic(w: *Io.Writer, cpu: *const cpu_mod.Cpu) !void {
    try w.print("\n=== UNHANDLED TRAP (--halt-on-trap) ===\n", .{});
    try w.print("mcause=0x{X:0>8}  mepc=0x{X:0>8}  mtval=0x{X:0>8}\n", .{
        cpu.csr.mcause, cpu.csr.mepc, cpu.csr.mtval,
    });
    const mstatus_view = csr_mod.csrRead(cpu, csr_mod.CSR_MSTATUS) catch 0;
    try w.print("mstatus=0x{X:0>8}  mtvec=0x{X:0>8}  privilege={s}\n", .{
        mstatus_view, cpu.csr.mtvec, @tagName(cpu.privilege),
    });
    try w.print("PC=0x{X:0>8}\n", .{cpu.pc});
    var i: u5 = 0;
    while (true) : (i += 1) {
        if (i % 4 == 0) try w.print("\n", .{});
        try w.print("x{d:0>2}=0x{X:0>8}  ", .{ i, cpu.regs[i] });
        if (i == 31) break;
    }
    try w.print("\n========================================\n", .{});
    try w.flush();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var stderr_buffer: [256]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const argv = init.minimal.args.toSlice(a) catch |err| {
        stderr.print("failed to read argv: {s}\n", .{@errorName(err)}) catch {};
        stderr.flush() catch {};
        std.process.exit(2);
    };

    const args = parseArgs(argv, stderr) catch {
        printUsage(stderr) catch {};
        std.process.exit(2);
    };

    // Load program bytes (16 MiB cap).
    const file_data = Io.Dir.cwd().readFileAlloc(io, args.file.?, a, .limited(16 * 1024 * 1024)) catch |err| {
        stderr.print("failed to read {s}: {s}\n", .{ args.file.?, @errorName(err) }) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };

    // stdout writer for UART output.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var halt = halt_dev.Halt.init();
    var uart = uart_dev.Uart.init(stdout);
    var clint = clint_dev.Clint.initDefault();
    var plic = plic_dev.Plic.init();

    const ram_size: usize = @as(usize, args.memory_mb) * 1024 * 1024;

    // Default boot: ELF. Fallback: --raw <addr>.
    // Construct Memory with tohost_addr=null initially; the ELF path will
    // set mem.tohost_addr post-hoc after parseAndLoad resolves the symbol.
    var mem = try mem_mod.Memory.init(a, &halt, &uart, &clint, &plic, null, ram_size);
    defer mem.deinit();

    var entry: u32 = 0;
    if (args.raw_addr) |addr| {
        for (file_data, 0..) |b, idx| {
            mem.storeBytePhysical(addr + @as(u32, @intCast(idx)), b) catch |err| {
                stdout.flush() catch {};
                stderr.print("failed to load byte {d} at 0x{X:0>8}: {s}\n", .{ idx, addr + @as(u32, @intCast(idx)), @errorName(err) }) catch {};
                stderr.flush() catch {};
                std.process.exit(1);
            };
        }
        entry = addr;
    } else {
        const result = elf_mod.parseAndLoad(file_data, &mem) catch |err| {
            stderr.print("ELF load failed: {s}\n", .{@errorName(err)}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        };
        entry = result.entry;
        mem.tohost_addr = result.tohost_addr;
    }

    var cpu = cpu_mod.Cpu.init(&mem, entry);
    cpu.halt_on_trap = args.halt_on_trap;

    if (args.trace) {
        cpu.trace_writer = stderr;
    }

    cpu.run() catch |err| switch (err) {
        error.FatalTrap => {
            stdout.flush() catch {};
            dumpTrapDiagnostic(stderr, &cpu) catch {};
            std.process.exit(3);
        },
        else => {
            stdout.flush() catch {};
            stderr.print("\nemulator stopped: {s} (PC=0x{X:0>8})\n", .{ @errorName(err), cpu.pc }) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        },
    };
    stdout.flush() catch {};
    std.process.exit(halt.exit_code orelse 0);
}

test "trivial" {
    try std.testing.expect(true);
}
