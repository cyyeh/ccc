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

const UART_THR: u32 = 0x1000_0000;

fn uartPut(b: u8) void {
    const thr: *volatile u8 = @ptrFromInt(UART_THR);
    thr.* = b;
}

fn uartPutSlice(s: []const u8) void {
    for (s) |b| uartPut(b);
}

fn uartPutDecimal(n: u32) void {
    if (n == 0) {
        uartPut('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var i: usize = 0;
    var v = n;
    while (v > 0) : (v /= 10) {
        buf[i] = @intCast('0' + (v % 10));
        i += 1;
    }
    while (i > 0) {
        i -= 1;
        uartPut(buf[i]);
    }
}

const UART_RBR: u32 = 0x1000_0000;
const UART_LSR: u32 = 0x1000_0005;

fn drainOneInputByte() void {
    const lsr: *volatile u8 = @ptrFromInt(UART_LSR);
    if ((lsr.* & 0x01) == 0) return; // DR clear → no byte
    const rbr: *volatile u8 = @ptrFromInt(UART_RBR);
    const b = rbr.*;
    handleInput(b);
}

fn readMtimeLow() u32 {
    const p: *volatile u32 = @ptrFromInt(MTIME_LOW);
    return p.*;
}

fn handleInput(b: u8) void {
    if (b == 'q') {
        quit_requested = true;
        return;
    }
    if (b == ' ') {
        // T16 implements restart. For now, ignore SPACE.
        return;
    }
    const new_dir: ?game_mod.Dir = switch (b) {
        'w', 'W' => .Up,
        's', 'S' => .Down,
        'a', 'A' => .Left,
        'd', 'D' => .Right,
        else => null,
    };
    if (new_dir) |d| {
        if (game.state == .Playing) {
            if (!game.game_started) {
                // First key of a fresh game: seed RNG from mtime, place food, start.
                var seed = readMtimeLow();
                if (seed == 0) seed = 1; // xorshift32 degenerate from 0
                game.rng = seed;
                game.placeFood();
                game.game_started = true;
            }
            game.pending_dir = d;
        }
    }
}

// Frame buffer: 15 rows × 32 cols. Filled by `paint`, written to UART
// by `render`. Lives in .bss (zeroed by monitor.S).
var frame: [game_mod.H][game_mod.W]u8 = undefined;

fn paint() void {
    // Borders + interior.
    var y: u8 = 0;
    while (y < game_mod.H) : (y += 1) {
        var x: u8 = 0;
        while (x < game_mod.W) : (x += 1) {
            const top_or_bot = (y == 0 or y == game_mod.H - 1);
            const left_or_right = (x == 0 or x == game_mod.W - 1);
            if (top_or_bot and left_or_right) {
                frame[y][x] = '+';
            } else if (top_or_bot) {
                frame[y][x] = '-';
            } else if (left_or_right) {
                frame[y][x] = '|';
            } else {
                frame[y][x] = ' ';
            }
        }
    }
    // Snake body.
    var i: u16 = 0;
    var idx: u16 = game.tail;
    while (i < game.len) : (i += 1) {
        const sx = game.snake_x[idx];
        const sy = game.snake_y[idx];
        if (sx < game_mod.W and sy < game_mod.H) {
            frame[sy][sx] = if (idx == game.head) 'O' else '#';
        }
        idx = (idx + 1) % game_mod.MAX_SNAKE;
    }
    // Food.
    if (game.food) |f| {
        if (f.x < game_mod.W and f.y < game_mod.H) frame[f.y][f.x] = '*';
    }
}

fn render() void {
    paint();
    // Clear screen + home cursor.
    uartPutSlice("\x1b[2J\x1b[H");
    // HUD row.
    uartPutSlice("SNAKE  score: ");
    uartPutDecimal(game.score);
    uartPutSlice("  (q quit)\r\n");
    // Board.
    var y: u8 = 0;
    while (y < game_mod.H) : (y += 1) {
        var x: u8 = 0;
        while (x < game_mod.W) : (x += 1) uartPut(frame[y][x]);
        uartPutSlice("\r\n");
    }
}

export fn snakeTrap() callconv(.c) void {
    if (!initialized) {
        game = game_mod.Game.init(.{
            .x = @as(u8, game_mod.PLAY_W) / 2 + 1,
            .y = @as(u8, game_mod.PLAY_H) / 2 + 1,
        });
        initialized = true;
        render(); // initial frame so the player sees the empty board
        advanceMtimecmp();
        return;
    }

    drainOneInputByte();

    if (quit_requested) halt();

    if (game.state == .Playing and game.game_started) {
        game.applyDirIfLegal();
        _ = game.advance();
    }
    render();

    advanceMtimecmp();
}
