// tests/programs/snake/snake.zig
//
// Freestanding M-mode snake. Zig side of the program: trap dispatch,
// I/O, and game state.

const game_mod = @import("game.zig");

export fn snakeTrap() callconv(.c) void {
    // T11 fills this in. For now, just return — the trap_vector
    // restores regs and mrets back to the wfi loop, where we'll
    // immediately wfi again until the NEXT interrupt fires (which
    // it won't, because we haven't reprogrammed mtimecmp).
}
