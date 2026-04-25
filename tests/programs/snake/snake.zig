// tests/programs/snake/snake.zig
//
// Freestanding M-mode snake. Zig side of the program: trap dispatch,
// I/O, and game state.

const game_mod = @import("game.zig");

// Module-level state (lives in .bss, zeroed by monitor.S).
var game: game_mod.Game = undefined;
var initialized: bool = false;
var quit_requested: bool = false;

// MMIO addresses (must match src/memory.zig + src/devices/*.zig).
const MTIME_LOW: u32 = 0x0200_BFF8;
const MTIMECMP_LOW: u32 = 0x0200_4000;
const TICK_PERIOD: u32 = 1_250_000;  // 125 ms @ 10 MHz

// `tohost` is a linker-resolved symbol; the ELF loader resolves writes
// to its address into the halt MMIO. Match the riscv-tests convention:
// store value 1 → exit code 0.
extern var tohost: u32;

fn halt() noreturn {
    tohost = 1;
    while (true) {}
}

fn advanceMtimecmp() void {
    // Read current mtime, add period, write to mtimecmp.
    const mt_low_ptr: *volatile u32 = @ptrFromInt(MTIME_LOW);
    const mt_high_ptr: *volatile u32 = @ptrFromInt(MTIME_LOW + 4);
    const mtcmp_low_ptr: *volatile u32 = @ptrFromInt(MTIMECMP_LOW);
    const mtcmp_high_ptr: *volatile u32 = @ptrFromInt(MTIMECMP_LOW + 4);

    const lo = mt_low_ptr.*;
    const hi = mt_high_ptr.*;
    const new_lo = lo +% TICK_PERIOD;
    const carry: u32 = if (new_lo < TICK_PERIOD) 1 else 0;
    mtcmp_low_ptr.* = new_lo;
    mtcmp_high_ptr.* = hi + carry;
}

export fn snakeTrap() callconv(.c) void {
    if (!initialized) {
        game = game_mod.Game.init(.{
            .x = @as(u8, game_mod.PLAY_W) / 2 + 1, // ~16
            .y = @as(u8, game_mod.PLAY_H) / 2 + 1, // ~7
        });
        initialized = true;
    }

    // T13 will replace this with real tick logic. For now: just halt
    // on the first tick to prove the trap path works.
    halt();

    // Unreachable in this task; T13+ uses:
    // advanceMtimecmp();
}
