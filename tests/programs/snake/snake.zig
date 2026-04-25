// tests/programs/snake/snake.zig
//
// Freestanding M-mode snake. Skeleton for now — game logic and trap
// dispatch arrive in later tasks. monitor.S currently halts before
// reaching any Zig code, so this file just needs to exist as a
// linkable object.

comptime {
    // Force a non-empty .bss so the linker emits the section
    // and our `_bss_start`/`_bss_end` symbols resolve.
    @export(&_placeholder, .{ .name = "_snake_placeholder" });
}

var _placeholder: u8 = 0;
