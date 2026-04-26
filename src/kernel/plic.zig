// src/kernel/plic.zig — Phase 3.D PLIC driver.
//
// Wraps the emulator-side PLIC at 0x0c00_0000 with four operations the
// kernel needs:
//   - setPriority(src, prio): per-source priority (0..7).
//   - enable(src):           set the S-context enable bit for src.
//   - setThreshold(t):       S-context threshold; sources must be > t.
//   - claim():               returns highest pending+enabled+>thresh src
//                            (1..31) or 0; clears its pending bit.
//   - complete(src):         signals "done with src" so the device can
//                            re-assert when the next edge fires.
//
// MMIO addresses match programs/plic_block_test/boot.S, which is
// the integration-test reference for Plan 3.A.

pub const PLIC_BASE: u32 = 0x0c00_0000;
pub const PLIC_PRIORITY_BASE: u32 = 0x0c00_0000; // src N at +4*N
pub const PLIC_ENABLE_S: u32 = 0x0c00_2080; // S-context enable bits
pub const PLIC_THRESHOLD_S: u32 = 0x0c20_1000; // S-context threshold
pub const PLIC_CLAIM_S: u32 = 0x0c20_1004; // read = claim, write = complete

pub const IRQ_BLOCK: u32 = 1;
// IRQ_UART_RX = 10  (3.E)

pub fn setPriority(src: u32, prio: u32) void {
    const reg: *volatile u32 = @ptrFromInt(PLIC_PRIORITY_BASE + src * 4);
    reg.* = prio;
}

pub fn enable(src: u32) void {
    const reg: *volatile u32 = @ptrFromInt(PLIC_ENABLE_S);
    reg.* = reg.* | (@as(u32, 1) << @intCast(src));
}

pub fn setThreshold(t: u32) void {
    const reg: *volatile u32 = @ptrFromInt(PLIC_THRESHOLD_S);
    reg.* = t;
}

pub fn claim() u32 {
    const reg: *volatile u32 = @ptrFromInt(PLIC_CLAIM_S);
    return reg.*;
}

pub fn complete(src: u32) void {
    const reg: *volatile u32 = @ptrFromInt(PLIC_CLAIM_S);
    reg.* = src;
}
