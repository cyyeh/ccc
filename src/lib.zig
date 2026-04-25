//! Single-module entry point that re-exports the emulator pieces a
//! freestanding consumer (e.g. demo/web_main.zig for the wasm build)
//! needs. Keeping every emulator file inside one module avoids the
//! "file exists in modules X and Y" error that arises when each piece
//! is declared as a separate module — the cross-imports between
//! cpu.zig / memory.zig / elf.zig / devices/* would each pull the
//! same file into multiple module trees.
//!
//! This shim is *only* used by build.zig's wasm target; the native
//! exe still uses src/main.zig as its root and reaches the same files
//! via relative @import.

pub const cpu = @import("cpu.zig");
pub const memory = @import("memory.zig");
pub const elf = @import("elf.zig");
pub const halt = @import("devices/halt.zig");
pub const uart = @import("devices/uart.zig");
pub const clint = @import("devices/clint.zig");
pub const plic = @import("devices/plic.zig");
pub const block = @import("devices/block.zig");
