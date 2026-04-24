// tests/programs/kernel/kmain.zig — Phase 2 Plan 2.C kernel S-mode entry.
//
// Task 1 leaves this as an unreachable stub so build.zig (Task 2) can depend
// on a real Zig file. Task 2 wires boot.S to jump here; Tasks 8, 17, 20 flesh
// out the full paging + user-entry flow.

export fn kmain() callconv(.c) noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}
