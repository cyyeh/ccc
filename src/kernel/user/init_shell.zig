// src/kernel/user/init_shell.zig — Phase 3.E /bin/init replacement.
//
// Loops forever: fork, exec /bin/sh, wait. If sh exits cleanly, restart
// it with a banner so the user knows. If exec fails (no /bin/sh), exit
// with status 127 — the kernel's halt path will catch it via the e2e
// harness.

const ulib = @import("lib/ulib.zig");
const uprintf = @import("lib/uprintf.zig");

export fn main(argc: u32, argv: [*]const [*:0]const u8) i32 {
    _ = argc;
    _ = argv;

    while (true) {
        const pid = ulib.fork();
        if (pid < 0) {
            uprintf.printf(2, "init: fork failed\n", &.{});
            ulib.exit(127);
        }
        if (pid == 0) {
            // Child: exec /bin/sh.
            const sh_path: [*:0]const u8 = "/bin/sh";
            const sh_argv: [2]?[*:0]const u8 = .{ sh_path, null };
            _ = ulib.exec(sh_path, &sh_argv);
            // exec returned — failure.
            uprintf.printf(2, "init: exec /bin/sh failed\n", &.{});
            ulib.exit(127);
        }
        // Parent: wait for child.
        var status: i32 = 0;
        const reaped = ulib.wait(&status);
        uprintf.printf(1, "[init] sh (pid %d) exited %d; restarting\n", &.{
            .{ .i = reaped },
            .{ .i = status },
        });
    }
}
