const std = @import("std");

pub const PLIC_BASE: u32 = 0x0c00_0000;
pub const PLIC_SIZE: u32 = 0x0040_0000; // 4 MB legacy aperture

pub const Plic = struct {
    pub fn init() Plic {
        return .{};
    }
};

test "Plic.init constructs a default Plic" {
    const p = Plic.init();
    _ = p;
}
