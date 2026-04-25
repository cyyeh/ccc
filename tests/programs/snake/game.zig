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

    pub fn advance(self: *Game) AdvanceResult {
        const head_x = self.snake_x[self.head];
        const head_y = self.snake_y[self.head];
        var nx: i16 = head_x;
        var ny: i16 = head_y;
        switch (self.dir) {
            .Up    => ny -= 1,
            .Down  => ny += 1,
            .Left  => nx -= 1,
            .Right => nx += 1,
        }

        if (nx <= 0 or nx > PLAY_W or ny <= 0 or ny > PLAY_H) {
            self.state = .GameOver;
            return .CollisionWall;
        }

        // Self-collision: scan body cells [tail+1 .. head]. Skip the tail
        // cell because it vacates its position this same tick — head moving
        // INTO a vacating tail cell is a legal "chase-tail" move.
        if (self.len > 1) {
            var i: u16 = 0;
            var idx: u16 = (self.tail + 1) % MAX_SNAKE;
            while (i < self.len - 1) : (i += 1) {
                if (self.snake_x[idx] == @as(u8, @intCast(nx)) and
                    self.snake_y[idx] == @as(u8, @intCast(ny)))
                {
                    self.state = .GameOver;
                    return .CollisionSelf;
                }
                idx = (idx + 1) % MAX_SNAKE;
            }
        }

        // Move head into (nx, ny).
        const new_head: u16 = (self.head + 1) % MAX_SNAKE;
        self.snake_x[new_head] = @intCast(nx);
        self.snake_y[new_head] = @intCast(ny);
        self.head = new_head;

        // Food check.
        const ate = if (self.food) |f|
            (f.x == @as(u8, @intCast(nx)) and f.y == @as(u8, @intCast(ny)))
        else
            false;

        if (ate) {
            self.score += 1;
            self.len += 1;
            self.placeFood();
            return .Grew;
        }

        // No food eaten — advance tail (snake moves, doesn't grow).
        self.tail = (self.tail + 1) % MAX_SNAKE;
        return .Moved;
    }

    pub fn applyDirIfLegal(self: *Game) void {
        const p = self.pending_dir orelse return;
        const reversal = switch (self.dir) {
            .Up    => p == .Down,
            .Down  => p == .Up,
            .Left  => p == .Right,
            .Right => p == .Left,
        };
        if (!reversal) self.dir = p;
        self.pending_dir = null;
    }

    pub fn nextRng(self: *Game) u32 {
        // xorshift32. Self.rng must be nonzero before the first call.
        var x = self.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.rng = x;
        return x;
    }

    pub fn placeFood(self: *Game) void {
        var attempts: u32 = 0;
        while (attempts < MAX_SNAKE) : (attempts += 1) {
            const r = self.nextRng();
            const x: u8 = @intCast((r % PLAY_W) + 1);
            const y: u8 = @intCast(((r >> 8) % PLAY_H) + 1);
            var i: u16 = 0;
            var idx: u16 = self.tail;
            var on_snake = false;
            while (i < self.len) : (i += 1) {
                if (self.snake_x[idx] == x and self.snake_y[idx] == y) {
                    on_snake = true;
                    break;
                }
                idx = (idx + 1) % MAX_SNAKE;
            }
            if (!on_snake) {
                self.food = .{ .x = x, .y = y };
                return;
            }
        }
        self.food = null;
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

test "advance: moves head one cell right" {
    var g = Game.init(.{ .x = 16, .y = 7 });
    const r = g.advance();
    try std.testing.expectEqual(AdvanceResult.Moved, r);
    try std.testing.expectEqual(@as(u8, 17), g.snake_x[g.head]);
    try std.testing.expectEqual(@as(u8, 7),  g.snake_y[g.head]);
    try std.testing.expectEqual(@as(u16, 3), g.len);
}

test "advance: hits right wall returns CollisionWall" {
    var g = Game.init(.{ .x = PLAY_W, .y = 7 });
    const r = g.advance();
    try std.testing.expectEqual(AdvanceResult.CollisionWall, r);
    try std.testing.expectEqual(State.GameOver, g.state);
}

test "advance: hits left wall" {
    // L-shaped snake, head at (1,5) facing Left — no body in the leftward path.
    var g = Game.init(.{ .x = 5, .y = 7 });
    g.len = 3;
    g.tail = 0;
    g.head = 2;
    g.snake_x[0] = 3; g.snake_y[0] = 6; // tail
    g.snake_x[1] = 2; g.snake_y[1] = 6; // mid
    g.snake_x[2] = 1; g.snake_y[2] = 6; // head at x=1
    g.dir = .Left;
    const r = g.advance();
    try std.testing.expectEqual(AdvanceResult.CollisionWall, r);
}

test "advance: hits top wall" {
    var g = Game.init(.{ .x = 16, .y = 5 });
    g.dir = .Up;
    _ = g.advance();
    _ = g.advance();
    _ = g.advance();
    _ = g.advance();
    const r = g.advance();
    try std.testing.expectEqual(AdvanceResult.CollisionWall, r);
}

test "advance: hits bottom wall" {
    var g = Game.init(.{ .x = 16, .y = PLAY_H - 1 });
    g.dir = .Down;
    _ = g.advance();
    const r = g.advance();
    try std.testing.expectEqual(AdvanceResult.CollisionWall, r);
}

test "applyDirIfLegal: 90° turn accepted" {
    var g = Game.init(.{ .x = 16, .y = 7 });
    g.pending_dir = .Up;
    g.applyDirIfLegal();
    try std.testing.expectEqual(Dir.Up, g.dir);
    try std.testing.expectEqual(@as(?Dir, null), g.pending_dir);
}

test "applyDirIfLegal: 180° reversal rejected" {
    var g = Game.init(.{ .x = 16, .y = 7 }); // facing Right
    g.pending_dir = .Left;
    g.applyDirIfLegal();
    try std.testing.expectEqual(Dir.Right, g.dir);
    try std.testing.expectEqual(@as(?Dir, null), g.pending_dir);
}

test "applyDirIfLegal: same direction is a no-op" {
    var g = Game.init(.{ .x = 16, .y = 7 });
    g.pending_dir = .Right;
    g.applyDirIfLegal();
    try std.testing.expectEqual(Dir.Right, g.dir);
}

test "applyDirIfLegal: no pending is a no-op" {
    var g = Game.init(.{ .x = 16, .y = 7 });
    g.pending_dir = null;
    g.applyDirIfLegal();
    try std.testing.expectEqual(Dir.Right, g.dir);
}

test "advance: self-collision when head re-enters body" {
    // Length-5 snake forming a hook: turning back on itself collides next move.
    var g = Game.init(.{ .x = 6, .y = 7 });
    g.len = 5;
    g.tail = 0;
    g.head = 4;
    const path = [_]Cell{
        .{ .x = 5, .y = 5 }, // tail
        .{ .x = 6, .y = 5 },
        .{ .x = 6, .y = 6 },
        .{ .x = 5, .y = 6 },
        .{ .x = 6, .y = 7 }, // head
    };
    for (path, 0..) |c, i| {
        g.snake_x[i] = c.x;
        g.snake_y[i] = c.y;
    }
    g.dir = .Up;
    // Next move: head goes (6,7) → (6,6). (6,6) is in the body (index 2).
    const r = g.advance();
    try std.testing.expectEqual(AdvanceResult.CollisionSelf, r);
    try std.testing.expectEqual(State.GameOver, g.state);
}

test "advance: head into vacating tail cell is allowed (permissive variant)" {
    // Length-4 snake forming an upside-down U:
    //   H .          head at (1, 5) facing Down
    //   # #          body[1] at (1, 6), body[2] at (2, 6)
    //   # T          tail at (2, 5)
    // Wait — that puts head and tail both at y=5; let me redo the geometry.
    //
    // Length-4 snake forming a tight loop:
    //   H#       head at (1,5), body at (2,5)
    //   T#       tail at (1,6), body at (2,6)
    // Snake order tail→head: (1,6) → (2,6) → (2,5) → (1,5). Direction Up.
    // Next move: head goes Up to (1,4). That's empty space — moves cleanly.
    //
    // Now what we WANT to test is "head moves into vacating tail cell."
    // Length-3 in an L:
    //   H        head at (5,5)
    //   #        body at (5,6)
    //   T        tail at (5,7), facing Up
    // Head moves Up: new head at (5,4). Empty — no collision. Doesn't test it.
    //
    // The classic chase-tail setup: snake length 4 in a square turn:
    //   T#       tail (1,5) → body (2,5)
    //   #H       body (1,6) → head (2,6) facing Up? No, head at (2,6) facing Up
    //            would go to (2,5) = body[1].
    //
    // Let me build it directly: snake order tail→...→head:
    //   (5,5) (6,5) (6,6) (5,6)
    // So tail at (5,5), head at (5,6), facing Up means head moves to (5,5) = tail.
    // That's the move we want to allow.

    var g = Game.init(.{ .x = 5, .y = 6 });
    g.len = 4;
    g.tail = 0;
    g.head = 3;
    g.snake_x[0] = 5; g.snake_y[0] = 5; // tail
    g.snake_x[1] = 6; g.snake_y[1] = 5;
    g.snake_x[2] = 6; g.snake_y[2] = 6;
    g.snake_x[3] = 5; g.snake_y[3] = 6; // head
    g.dir = .Up;
    // Head (5,6) → (5,5) which IS the tail cell. Permissive rule allows.
    const r = g.advance();
    try std.testing.expectEqual(AdvanceResult.Moved, r);
    try std.testing.expectEqual(State.Playing, g.state);
}

test "nextRng: nonzero seed produces nonzero output" {
    var g = Game.init(.{ .x = 16, .y = 7 });
    g.rng = 0x1234_5678;
    const r1 = g.nextRng();
    const r2 = g.nextRng();
    try std.testing.expect(r1 != 0);
    try std.testing.expect(r2 != 0);
    try std.testing.expect(r1 != r2);
}

test "nextRng: deterministic with fixed seed" {
    var g1 = Game.init(.{ .x = 16, .y = 7 });
    var g2 = Game.init(.{ .x = 16, .y = 7 });
    g1.rng = 42;
    g2.rng = 42;
    try std.testing.expectEqual(g1.nextRng(), g2.nextRng());
    try std.testing.expectEqual(g1.nextRng(), g2.nextRng());
}

test "placeFood: lands inside the playable area" {
    var g = Game.init(.{ .x = 16, .y = 7 });
    g.rng = 1;
    g.placeFood();
    const f = g.food.?;
    try std.testing.expect(f.x >= 1 and f.x <= PLAY_W);
    try std.testing.expect(f.y >= 1 and f.y <= PLAY_H);
}

test "placeFood: never on the snake body" {
    var g = Game.init(.{ .x = 16, .y = 7 });
    g.rng = 7;
    var iter: u32 = 0;
    while (iter < 100) : (iter += 1) {
        g.placeFood();
        const f = g.food.?;
        var i: u16 = 0;
        var idx: u16 = g.tail;
        while (i < g.len) : (i += 1) {
            try std.testing.expect(!(g.snake_x[idx] == f.x and g.snake_y[idx] == f.y));
            idx = (idx + 1) % MAX_SNAKE;
        }
    }
}

test "advance onto food: score++, len++, food respawned, tail stays" {
    var g = Game.init(.{ .x = 16, .y = 7 });
    g.rng = 1;
    // Place food immediately to the right of the head: head at (16,7), food at (17,7).
    g.food = .{ .x = 17, .y = 7 };
    const tail_x_before = g.snake_x[g.tail];
    const tail_y_before = g.snake_y[g.tail];
    const r = g.advance();
    try std.testing.expectEqual(AdvanceResult.Grew, r);
    try std.testing.expectEqual(@as(u32, 1), g.score);
    try std.testing.expectEqual(@as(u16, 4), g.len);
    // Tail did NOT advance.
    try std.testing.expectEqual(tail_x_before, g.snake_x[g.tail]);
    try std.testing.expectEqual(tail_y_before, g.snake_y[g.tail]);
    // New food placed (rng was nonzero, so placeFood succeeded).
    try std.testing.expect(g.food != null);
    // New food is not at the eaten position.
    try std.testing.expect(!(g.food.?.x == 17 and g.food.?.y == 7));
}
