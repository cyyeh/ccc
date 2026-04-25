//! Pure snake game logic. Target-independent (no Io, no MMIO, no asm).
//! `snake.zig` (freestanding) imports this and adds the M-mode wrapping;
//! `zig build snake-test` runs these unit tests against the native target.

const std = @import("std");

pub const W: u8 = 32;            // total board cols including border
pub const H: u8 = 15;            // total board rows including border (HUD is row 0 of the terminal, separate)
pub const PLAY_W: u8 = W - 2;    // 30 playable cols (1..W-2)
pub const PLAY_H: u8 = H - 2;    // 13 playable rows (1..H-2)
pub const MAX_SNAKE: u16 = @as(u16, PLAY_W) * @as(u16, PLAY_H);

pub const Dir = enum(u8) { Up, Down, Left, Right };

pub const Cell = struct { x: u8, y: u8 };

pub const State = enum(u8) { Playing, GameOver };

pub const AdvanceResult = enum(u8) { Moved, Grew, CollisionWall, CollisionSelf };

pub const Game = struct {
    snake_x: [MAX_SNAKE]u8,
    snake_y: [MAX_SNAKE]u8,
    head: u16,
    tail: u16,
    len: u16,
    dir: Dir,
    pending_dir: ?Dir,
    food: ?Cell,
    score: u32,
    rng: u32,
    state: State,
    game_started: bool,

    pub fn init(spawn: Cell) Game {
        var g: Game = .{
            .snake_x = [_]u8{0} ** MAX_SNAKE,
            .snake_y = [_]u8{0} ** MAX_SNAKE,
            .head = 2,
            .tail = 0,
            .len = 3,
            .dir = .Right,
            .pending_dir = null,
            .food = null,
            .score = 0,
            .rng = 0,
            .state = .Playing,
            .game_started = false,
        };
        // Snake of length 3, head at spawn, tail extending left.
        g.snake_x[0] = spawn.x - 2; g.snake_y[0] = spawn.y;
        g.snake_x[1] = spawn.x - 1; g.snake_y[1] = spawn.y;
        g.snake_x[2] = spawn.x;     g.snake_y[2] = spawn.y;
        return g;
    }
};

test "Game.init: snake length 3, head at spawn, facing right" {
    const g = Game.init(.{ .x = 16, .y = 7 });
    try std.testing.expectEqual(@as(u16, 3), g.len);
    try std.testing.expectEqual(Dir.Right, g.dir);
    try std.testing.expectEqual(@as(u8, 16), g.snake_x[g.head]);
    try std.testing.expectEqual(@as(u8, 7),  g.snake_y[g.head]);
    try std.testing.expectEqual(@as(u8, 14), g.snake_x[g.tail]);
    try std.testing.expectEqual(State.Playing, g.state);
    try std.testing.expect(!g.game_started);
}
