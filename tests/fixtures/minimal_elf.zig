/// Thin wrapper that `@embedFile`s `minimal.elf` — used so src/elf.zig
/// can import the fixture without its @embedFile escaping src/'s package
/// root.  Wired as an anonymous module in build.zig under the name
/// "minimal_elf_fixture".  See tests/fixtures/README.md.
pub const bytes = @embedFile("minimal.elf");
