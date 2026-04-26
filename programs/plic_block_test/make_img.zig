// programs/plic_block_test/make_img.zig — host tool that emits the
// 4 MB Phase 3.A integration-test disk image. Sector 0, byte 0 = 0xCC
// (the magic byte the test program looks for after the block read);
// every other byte is left as zero by the underlying setLength sparse
// extension.
//
// Zig 0.16 host-side I/O: createFile/setLength/writePositionalAll all
// take an `Io` parameter, mirroring the project's existing host tool
// pattern (see programs/hello/encode_hello.zig).

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.gpa;

    const argv = try init.minimal.args.toSlice(a);
    defer a.free(argv);

    var stderr_buffer: [256]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    if (argv.len != 2) {
        stderr.print("usage: {s} <output-path>\n", .{argv[0]}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    }

    const out_path = argv[1];

    var file = try Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);

    const SIZE: u64 = 4 * 1024 * 1024;
    try file.setLength(io, SIZE);

    // Write 0xCC at offset 0. The remaining 4 MB - 1 stays zero.
    try file.writePositionalAll(io, &[_]u8{0xCC}, 0);
}
