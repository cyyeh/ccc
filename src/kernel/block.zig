// src/kernel/block.zig — Phase 3.D block-device driver.
//
// Single-outstanding-request model (per Phase 3 spec §Block I/O driver):
// - read(blk, dst_pa) writes the four MMIO regs (SECTOR/BUFFER/CMD),
//   sets req.state = .Pending, then sleeps on @intFromPtr(&req).
// - The PLIC raises IRQ #1 after the transfer; trap.zig's S-external
//   branch claims the source, dispatches into block.isr(), then
//   completes the source.
// - block.isr() reads STATUS, sets req.err and req.state = .Done, then
//   wakes everything sleeping on @intFromPtr(&req) (just the one waiter).
// - The waiter resumes inside read(), checks req.err, panics on error,
//   resets state to .Idle, returns.
//
// dst_pa / src_pa must be the kernel-direct-mapped PA of a 4-KB-aligned
// buffer in RAM. For the bufcache, that's @intFromPtr(&buf.data) — buf
// lives in .bss which is identity-mapped under mapKernelAndMmio.

const proc = @import("proc.zig");
const kprintf = @import("kprintf.zig");

pub const BLOCK_BASE: u32 = 0x1000_1000;
pub const REG_SECTOR: u32 = 0x0;
pub const REG_BUFFER: u32 = 0x4;
pub const REG_CMD: u32 = 0x8;
pub const REG_STATUS: u32 = 0xC;

pub const CMD_READ: u32 = 1;
pub const CMD_WRITE: u32 = 2;

const ReqState = enum(u32) { Idle, Pending, Done };

const Req = struct {
    state: ReqState,
    err: bool,
    waiter: u32, // process pointer (debug aid)
};

var req: Req = .{ .state = .Idle, .err = false, .waiter = 0 };

inline fn mmio(off: u32) *volatile u32 {
    return @ptrFromInt(BLOCK_BASE + off);
}

fn submit(blk: u32, buf_pa: u32, cmd: u32) void {
    if (req.state != .Idle) {
        kprintf.panic("block.submit: req not idle (state={d})", .{@intFromEnum(req.state)});
    }
    req.state = .Pending;
    req.err = false;
    req.waiter = @intFromPtr(proc.cur());

    mmio(REG_SECTOR).* = blk;
    mmio(REG_BUFFER).* = buf_pa;
    mmio(REG_CMD).* = cmd;

    // Wait for ISR to mark req.state = .Done.
    while (req.state != .Done) {
        proc.sleep(@intFromPtr(&req));
    }

    if (req.err) kprintf.panic("block I/O error (blk={d}, cmd={d})", .{ blk, cmd });

    req.state = .Idle;
    req.waiter = 0;
}

pub fn read(blk: u32, dst_pa: u32) void {
    submit(blk, dst_pa, CMD_READ);
}

pub fn write(blk: u32, src_pa: u32) void {
    submit(blk, src_pa, CMD_WRITE);
}

/// Called from trap.zig's S-external branch when claim() returns IRQ #1.
/// Reads STATUS, marks the request done, wakes the sleeper.
pub fn isr() void {
    const status = mmio(REG_STATUS).*;
    req.err = (status != 0);
    req.state = .Done;
    proc.wakeup(@intFromPtr(&req));
}
