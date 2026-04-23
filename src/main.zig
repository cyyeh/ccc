const std = @import("std");
const Io = std.Io;
const cpu_mod = @import("cpu.zig");
const mem_mod = @import("memory.zig");
const halt_dev = @import("devices/halt.zig");
const uart_dev = @import("devices/uart.zig");
const clint_dev = @import("devices/clint.zig");

comptime {
    _ = @import("cpu.zig");
    _ = @import("memory.zig");
    _ = @import("devices/halt.zig");
    _ = @import("devices/uart.zig");
    _ = @import("devices/clint.zig");
    _ = @import("decoder.zig");
    _ = @import("execute.zig");
    _ = @import("csr.zig");
    _ = @import("trap.zig");
    _ = @import("elf.zig");
}

const Args = struct {
    raw_addr: ?u32 = null,
    file: ?[]const u8 = null,
};

const ArgsError = error{
    MissingArg,
    UnknownOption,
    TooManyPositional,
    MissingFile,
    RawAddrRequired,
    InvalidAddress,
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
    if (args.raw_addr == null) return error.RawAddrRequired;
    return args;
}

fn printUsage(stderr: *Io.Writer) !void {
    try stderr.print(
        \\usage: ccc --raw <hex-addr> <program.bin>
        \\
        \\Plan 1.A only supports raw-binary loading (--raw is required).
        \\ELF support arrives in Plan 1.C.
        \\
    , .{});
    try stderr.flush();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // stderr writer for usage / diagnostics.
    var stderr_buffer: [256]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    // Convert argv into a slice we can index over.
    const argv = init.minimal.args.toSlice(a) catch |err| {
        stderr.print("failed to read argv: {s}\n", .{@errorName(err)}) catch {};
        stderr.flush() catch {};
        std.process.exit(2);
    };

    const args = parseArgs(argv, stderr) catch {
        printUsage(stderr) catch {};
        std.process.exit(2);
    };

    // Load program bytes. 16 MiB cap keeps us well under RAM_SIZE_DEFAULT (128 MiB).
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

    var mem = try mem_mod.Memory.init(a, &halt, &uart, &clint, null, mem_mod.RAM_SIZE_DEFAULT);
    defer mem.deinit();

    // Load program bytes into RAM at raw_addr.
    const load_addr = args.raw_addr.?;
    for (file_data, 0..) |b, idx| {
        mem.storeByte(load_addr + @as(u32, @intCast(idx)), b) catch |err| {
            stdout.flush() catch {};
            stderr.print("failed to load byte {d} at 0x{X:0>8}: {s}\n", .{ idx, load_addr + @as(u32, @intCast(idx)), @errorName(err) }) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        };
    }

    var cpu = cpu_mod.Cpu.init(&mem, load_addr);
    cpu.run() catch |err| {
        stdout.flush() catch {};
        stderr.print("\nemulator stopped: {s} (PC=0x{X:0>8})\n", .{ @errorName(err), cpu.pc }) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };
    stdout.flush() catch {};
    std.process.exit(halt.exit_code orelse 0);
}

test "trivial" {
    try std.testing.expect(true);
}
