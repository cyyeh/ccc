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

fn paintGameOver() void {
    // Centered 5×14 panel. (W=32, H=15) → top-left at (col 9, row 5).
    const PW: u8 = 14;
    const PH: u8 = 5;
    const col0: u8 = (game_mod.W - PW) / 2;       // 9
    const row0: u8 = (game_mod.H - PH) / 2;       // 5
    var dy: u8 = 0;
    while (dy < PH) : (dy += 1) {
        var dx: u8 = 0;
        while (dx < PW) : (dx += 1) {
            const top    = (dy == 0);
            const bot    = (dy == PH - 1);
            const left   = (dx == 0);
            const right  = (dx == PW - 1);
            const c: u8 = if ((top or bot) and (left or right)) '+'
                else if (top or bot) '-'
                else if (left or right) '|'
                else ' ';
            frame[row0 + dy][col0 + dx] = c;
        }
    }
    const msg1 = "GAME OVER";
    const msg2_prefix = "score: ";
    const msg3 = "SPC retry";

    // row0+1: "GAME OVER" centered in inner 12 cols.
    {
        const inner = PW - 2; // 12
        const start = col0 + 1 + (inner - @as(u8, @intCast(msg1.len))) / 2;
        for (msg1, 0..) |c, i| frame[row0 + 1][start + @as(u8, @intCast(i))] = c;
    }
    // row0+2: "score: N" left-aligned with 2-space indent.
    {
        var col = col0 + 2;
        for (msg2_prefix) |c| {
            frame[row0 + 2][col] = c;
            col += 1;
        }
        var n = game.score;
        var digits: [5]u8 = undefined;
        var ndigits: usize = 0;
        if (n == 0) {
            digits[0] = '0';
            ndigits = 1;
        } else while (n > 0) : (n /= 10) {
            digits[ndigits] = @intCast('0' + (n % 10));
            ndigits += 1;
        }
        var di = ndigits;
        while (di > 0) {
            di -= 1;
            frame[row0 + 2][col] = digits[di];
            col += 1;
        }
    }
    // row0+3: "SPC retry" centered.
    {
        const inner = PW - 2;
        const start = col0 + 1 + (inner - @as(u8, @intCast(msg3.len))) / 2;
        for (msg3, 0..) |c, i| frame[row0 + 3][start + @as(u8, @intCast(i))] = c;
    }
}

fn render() void {
    paint();
    if (game.state == .GameOver) paintGameOver();
    uartPutSlice("\x1b[2J\x1b[H");
    uartPutSlice("SNAKE  score: ");
    uartPutDecimal(game.score);
    uartPutSlice("  (q quit)\r\n");
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
