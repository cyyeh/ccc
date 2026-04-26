const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ccc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // Link libc on the native build so devices/clint.zig's
            // std.c.clock_gettime + cpu.zig's std.c.nanosleep resolve.
            // macOS's libSystem auto-links so the omission was invisible
            // there; Linux needs the explicit opt-in. The wasm build uses
            // a separate module rooted at demo/web_main.zig and stays
            // libc-free via the comptime branches in cpu.zig + clint.zig.
            .link_libc = true,
        }),
    });
    // Expose tests/fixtures/minimal.elf as an importable module so that
    // src/elf.zig's test can embed it without escaping src/'s package root.
    exe.root_module.addAnonymousImport("minimal_elf_fixture", .{
        .root_source_file = b.path("tests/fixtures/minimal_elf.zig"),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the emulator");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const test_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&test_run.step);

    // Host-runnable tests for kernel-side modules whose algorithms can run
    // outside the cross-compiled kernel (e.g., elfload's parser).
    const kernel_host_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/elfload.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    kernel_host_tests.root_module.addAnonymousImport("minimal_elf_fixture", .{
        .root_source_file = b.path("tests/fixtures/minimal_elf.zig"),
    });
    const kernel_host_tests_run = b.addRunArtifact(kernel_host_tests);
    test_step.dependOn(&kernel_host_tests_run.step);

    // Host-runnable tests for vm.zig's pure-arithmetic helpers
    // (Plan 3.C Task 1: freeLeavesInL0 walk over a synthetic L0 table).
    // vm.zig's page_alloc + kprintf imports are lazily evaluated; tests
    // exercise only the pure helpers and never reach the freestanding-only
    // code paths, so a host-targeted compile succeeds without stubs.
    const vm_host_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/vm.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const vm_host_tests_run = b.addRunArtifact(vm_host_tests);
    test_step.dependOn(&vm_host_tests_run.step);

    // === Hand-crafted hello world demo (Task 17) ===
    // The encoder is a host tool that emits a raw RV32I binary.
    const hello_encoder = b.addExecutable(.{
        .name = "encode_hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/hello/encode_hello.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const hello_run = b.addRunArtifact(hello_encoder);
    const hello_bin = hello_run.addOutputFileArg("hello.bin");
    const install_hello = b.addInstallFile(hello_bin, "hello.bin");

    const hello_step = b.step("hello", "Build the hand-crafted hello world binary");
    hello_step.dependOn(&install_hello.step);

    // End-to-end test: run the emulator against the freshly-built hello.bin
    // and assert the UART output equals "hello world\n".
    const e2e_run = b.addRunArtifact(exe);
    e2e_run.addArgs(&.{ "--raw", "0x80000000" });
    e2e_run.addFileArg(hello_bin);
    e2e_run.expectStdOutEqual("hello world\n");

    const e2e_step = b.step("e2e", "Run the end-to-end hello world test");
    e2e_step.dependOn(&e2e_run.step);

    // === Hand-crafted RV32IMA mul/amo/div demo (Plan 1.B Task 9) ===
    const mul_demo_encoder = b.addExecutable(.{
        .name = "encode_mul_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/mul_demo/encode_mul_demo.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const mul_demo_run = b.addRunArtifact(mul_demo_encoder);
    const mul_demo_bin = mul_demo_run.addOutputFileArg("mul_demo.bin");
    const install_mul_demo = b.addInstallFile(mul_demo_bin, "mul_demo.bin");

    const mul_demo_step = b.step("mul-demo", "Build the hand-crafted RV32IMA demo binary");
    mul_demo_step.dependOn(&install_mul_demo.step);

    // End-to-end test: run the emulator against mul_demo.bin, assert output.
    const e2e_mul_run = b.addRunArtifact(exe);
    e2e_mul_run.addArgs(&.{ "--raw", "0x80000000" });
    e2e_mul_run.addFileArg(mul_demo_bin);
    e2e_mul_run.expectStdOutEqual("42\n");

    const e2e_mul_step = b.step("e2e-mul", "Run the end-to-end RV32IMA demo test");
    e2e_mul_step.dependOn(&e2e_mul_run.step);

    // === Hand-crafted trap/privilege demo (Plan 1.C Task 17) ===
    const trap_demo_encoder = b.addExecutable(.{
        .name = "encode_trap_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/trap_demo/encode_trap_demo.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const trap_demo_run = b.addRunArtifact(trap_demo_encoder);
    const trap_demo_bin = trap_demo_run.addOutputFileArg("trap_demo.bin");
    const install_trap_demo = b.addInstallFile(trap_demo_bin, "trap_demo.bin");

    const trap_demo_step = b.step("trap-demo", "Build the hand-crafted trap/privilege demo binary");
    trap_demo_step.dependOn(&install_trap_demo.step);

    const e2e_trap_run = b.addRunArtifact(exe);
    e2e_trap_run.addArgs(&.{ "--raw", "0x80000000" });
    e2e_trap_run.addFileArg(trap_demo_bin);
    e2e_trap_run.expectStdOutEqual("trap ok\n");

    const e2e_trap_step = b.step("e2e-trap", "Run the end-to-end trap/privilege demo test");
    e2e_trap_step.dependOn(&e2e_trap_run.step);

    // === Shared RV32 cross-compile target (hello.elf + riscv-tests) ===
    // Use generic_rv32 (explicit CPU model) so compressed (C) is OFF.
    // baseline_rv32 silently includes C, which breaks us: our decoder is
    // strictly 32-bit-wide. Plus M + A features.
    const rv_target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv32,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32 },
        .cpu_features_add = blk: {
            const features = std.Target.riscv.Feature;
            var set = std.Target.Cpu.Feature.Set.empty;
            set.addFeature(@intFromEnum(features.m));
            set.addFeature(@intFromEnum(features.a));
            break :blk set;
        },
    });

    // === Zig-compiled hello.elf (Plan 1.D — Phase 1 §Definition of done) ===
    // Two-object link: monitor.S provides _start + trap_vector (M-mode);
    // hello.zig provides u_entry + msg (U-mode). linker.ld places .text.init
    // at 0x80000000 and defines _stack_top.
    const hello_monitor_obj = b.addObject(.{
        .name = "hello-monitor",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
        }),
    });
    hello_monitor_obj.root_module.addAssemblyFile(b.path("tests/programs/hello/monitor.S"));

    const hello_umode_obj = b.addObject(.{
        .name = "hello-umode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/hello/hello.zig"),
            .target = rv_target,
            .optimize = .ReleaseSmall,
            // Keep the Zig compiler from stripping u_entry / msg as "unused".
            .strip = false,
            .single_threaded = true,
        }),
    });

    const hello_elf = b.addExecutable(.{
        .name = "hello.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    hello_elf.root_module.addObject(hello_monitor_obj);
    hello_elf.root_module.addObject(hello_umode_obj);
    hello_elf.setLinkerScript(b.path("tests/programs/hello/linker.ld"));
    hello_elf.entry = .{ .symbol_name = "_start" };

    const install_hello_elf = b.addInstallArtifact(hello_elf, .{});
    const hello_elf_step = b.step("hello-elf", "Build the Zig-compiled hello.elf (Phase 1 §Definition of done)");
    hello_elf_step.dependOn(&install_hello_elf.step);

    // End-to-end: run our emulator against hello.elf and assert UART output.
    const e2e_hello_elf_run = b.addRunArtifact(exe);
    e2e_hello_elf_run.addFileArg(hello_elf.getEmittedBin());
    e2e_hello_elf_run.expectStdOutEqual("hello world\n");

    const e2e_hello_elf_step = b.step("e2e-hello-elf", "Run the Phase 1 §Definition of done demo (ccc hello.elf)");
    e2e_hello_elf_step.dependOn(&e2e_hello_elf_run.step);

    // === Kernel.elf (Plan 2.C) ===
    //
    // Two-piece build:
    //   1. userprog.bin — a flat RV32 U-mode binary produced by objcopy
    //      (added in Task 14). For now (Task 2), userprog.bin does not
    //      exist yet and the kernel does not embed it.
    //   2. kernel.elf — M-mode boot.S + mtimer.S + trampoline.S + kernel
    //      Zig (kmain, vm, page_alloc, trap, syscall, uart, kprintf) all
    //      linked per kernel/linker.ld, entry _M_start.
    //
    // Task 2 state: only boot.S + kmain.zig exist; the other .zig / .S
    // files and the userprog embed arrive in later tasks.

    const kernel_boot_obj = b.addObject(.{
        .name = "kernel-boot",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
        }),
    });
    kernel_boot_obj.root_module.addAssemblyFile(b.path("tests/programs/kernel/boot.S"));

    const kernel_trampoline_obj = b.addObject(.{
        .name = "kernel-trampoline",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
        }),
    });
    kernel_trampoline_obj.root_module.addAssemblyFile(b.path("tests/programs/kernel/trampoline.S"));

    const kernel_mtimer_obj = b.addObject(.{
        .name = "kernel-mtimer",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
        }),
    });
    kernel_mtimer_obj.root_module.addAssemblyFile(b.path("tests/programs/kernel/mtimer.S"));

    const kernel_swtch_obj = b.addObject(.{
        .name = "kernel-swtch",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
        }),
    });
    kernel_swtch_obj.root_module.addAssemblyFile(b.path("tests/programs/kernel/swtch.S"));

    // === User program (Plan 2.C) ===
    const userprog_obj = b.addObject(.{
        .name = "userprog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/user/userprog.zig"),
            .target = rv_target,
            .optimize = .ReleaseSmall,
            .strip = false,
            .single_threaded = true,
        }),
    });

    const userprog_elf = b.addExecutable(.{
        .name = "userprog.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .ReleaseSmall,
            .strip = false,
            .single_threaded = true,
        }),
    });
    userprog_elf.root_module.addObject(userprog_obj);
    userprog_elf.setLinkerScript(b.path("tests/programs/kernel/user/user_linker.ld"));
    userprog_elf.entry = .{ .symbol_name = "_start" };

    const userprog_elf_bin = userprog_elf.getEmittedBin();

    const boot_config_stub_dir = b.addWriteFiles();
    const boot_config_zig = boot_config_stub_dir.add(
        "boot_config.zig",
        \\const std = @import("std");
        \\pub const MULTI_PROC: bool = false;
        \\pub const FORK_DEMO: bool = false;
        \\pub const USERPROG_ELF: []const u8 = @embedFile("userprog.elf");
        \\pub const USERPROG2_ELF: []const u8 = "";
        \\pub const INIT_ELF: []const u8 = "";
        \\pub const HELLO_ELF: []const u8 = "";
        \\pub fn lookupBlob(path: []const u8) ?[]const u8 {
        \\    _ = path;
        \\    return null;
        \\}
        ,
    );
    _ = boot_config_stub_dir.addCopyFile(userprog_elf_bin, "userprog.elf");

    const install_userprog_elf = b.addInstallFile(userprog_elf_bin, "userprog.elf");
    const kernel_user_step = b.step("kernel-user", "Build the Phase 3.B userprog.elf");
    kernel_user_step.dependOn(&install_userprog_elf.step);

    const userprog2_obj = b.addObject(.{
        .name = "userprog2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/user/userprog2.zig"),
            .target = rv_target,
            .optimize = .ReleaseSmall,
            .strip = false,
            .single_threaded = true,
        }),
    });

    const userprog2_elf = b.addExecutable(.{
        .name = "userprog2.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .ReleaseSmall,
            .strip = false,
            .single_threaded = true,
        }),
    });
    userprog2_elf.root_module.addObject(userprog2_obj);
    userprog2_elf.setLinkerScript(b.path("tests/programs/kernel/user/user_linker.ld"));
    userprog2_elf.entry = .{ .symbol_name = "_start" };

    const userprog2_elf_bin = userprog2_elf.getEmittedBin();

    const install_userprog2_elf = b.addInstallFile(userprog2_elf_bin, "userprog2.elf");
    const userprog2_step = b.step("kernel-user2", "Build the Phase 3.B userprog2.elf");
    userprog2_step.dependOn(&install_userprog2_elf.step);

    const kernel_init_obj = b.addObject(.{
        .name = "init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/user/init.zig"),
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });

    const kernel_init_elf = b.addExecutable(.{
        .name = "init.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    kernel_init_elf.root_module.addObject(kernel_init_obj);
    kernel_init_elf.setLinkerScript(b.path("tests/programs/kernel/user/user_linker.ld"));
    kernel_init_elf.entry = .{ .symbol_name = "_start" };

    const kernel_init_elf_bin = kernel_init_elf.getEmittedBin();
    const install_kernel_init_elf = b.addInstallFile(kernel_init_elf_bin, "init.elf");
    const kernel_init_step = b.step("kernel-init", "Build the Phase 3.C init.elf");
    kernel_init_step.dependOn(&install_kernel_init_elf.step);

    const kernel_hello_obj = b.addObject(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/user/hello.zig"),
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });

    const kernel_hello_elf = b.addExecutable(.{
        .name = "hello.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    kernel_hello_elf.root_module.addObject(kernel_hello_obj);
    kernel_hello_elf.setLinkerScript(b.path("tests/programs/kernel/user/user_linker.ld"));
    kernel_hello_elf.entry = .{ .symbol_name = "_start" };

    const kernel_hello_elf_bin = kernel_hello_elf.getEmittedBin();
    const install_kernel_hello_elf = b.addInstallFile(kernel_hello_elf_bin, "hello.elf");
    const kernel_hello_step = b.step("kernel-hello", "Build the Phase 3.C hello.elf");
    kernel_hello_step.dependOn(&install_kernel_hello_elf.step);

    const multi_boot_config_stub_dir = b.addWriteFiles();
    const multi_boot_config_zig = multi_boot_config_stub_dir.add(
        "boot_config.zig",
        \\const std = @import("std");
        \\pub const MULTI_PROC: bool = true;
        \\pub const FORK_DEMO: bool = false;
        \\pub const USERPROG_ELF: []const u8 = @embedFile("userprog.elf");
        \\pub const USERPROG2_ELF: []const u8 = @embedFile("userprog2.elf");
        \\pub const INIT_ELF: []const u8 = "";
        \\pub const HELLO_ELF: []const u8 = "";
        \\pub fn lookupBlob(path: []const u8) ?[]const u8 {
        \\    _ = path;
        \\    return null;
        \\}
        ,
    );
    _ = multi_boot_config_stub_dir.addCopyFile(userprog_elf_bin, "userprog.elf");
    _ = multi_boot_config_stub_dir.addCopyFile(userprog2_elf_bin, "userprog2.elf");

    const fork_boot_config_stub_dir = b.addWriteFiles();
    const fork_boot_config_zig = fork_boot_config_stub_dir.add(
        "boot_config.zig",
        \\const std = @import("std");
        \\pub const MULTI_PROC: bool = false;
        \\pub const FORK_DEMO: bool = true;
        \\pub const USERPROG_ELF: []const u8 = "";
        \\pub const USERPROG2_ELF: []const u8 = "";
        \\pub const INIT_ELF: []const u8 = @embedFile("init.elf");
        \\pub const HELLO_ELF: []const u8 = @embedFile("hello.elf");
        \\pub fn lookupBlob(path: []const u8) ?[]const u8 {
        \\    if (std.mem.eql(u8, path, "/bin/hello")) return HELLO_ELF;
        \\    return null;
        \\}
        ,
    );
    _ = fork_boot_config_stub_dir.addCopyFile(kernel_init_elf_bin, "init.elf");
    _ = fork_boot_config_stub_dir.addCopyFile(kernel_hello_elf_bin, "hello.elf");

    const kernel_kmain_obj = b.addObject(.{
        .name = "kernel-kmain",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/kmain.zig"),
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    kernel_kmain_obj.root_module.addAnonymousImport("boot_config", .{
        .root_source_file = boot_config_zig,
    });

    const kernel_kmain_multi_obj = b.addObject(.{
        .name = "kernel-kmain-multi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/kmain.zig"),
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    kernel_kmain_multi_obj.root_module.addAnonymousImport("boot_config", .{
        .root_source_file = multi_boot_config_zig,
    });

    const kernel_kmain_fork_obj = b.addObject(.{
        .name = "kernel-kmain-fork",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/kmain.zig"),
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    kernel_kmain_fork_obj.root_module.addAnonymousImport("boot_config", .{
        .root_source_file = fork_boot_config_zig,
    });

    const kernel_elf = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    kernel_elf.root_module.addObject(kernel_boot_obj);
    kernel_elf.root_module.addObject(kernel_trampoline_obj);
    kernel_elf.root_module.addObject(kernel_mtimer_obj);
    kernel_elf.root_module.addObject(kernel_swtch_obj);
    kernel_elf.root_module.addObject(kernel_kmain_obj);
    kernel_elf.setLinkerScript(b.path("tests/programs/kernel/linker.ld"));
    kernel_elf.entry = .{ .symbol_name = "_M_start" };

    const install_kernel_elf = b.addInstallArtifact(kernel_elf, .{});
    const kernel_elf_step = b.step("kernel-elf", "Build the Plan 2.C kernel.elf");
    kernel_elf_step.dependOn(&install_kernel_elf.step);

    const kernel_step = b.step("kernel", "Alias for kernel-elf");
    kernel_step.dependOn(&install_kernel_elf.step);

    const kernel_multi_elf = b.addExecutable(.{
        .name = "kernel-multi.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    kernel_multi_elf.root_module.addObject(kernel_boot_obj);
    kernel_multi_elf.root_module.addObject(kernel_trampoline_obj);
    kernel_multi_elf.root_module.addObject(kernel_mtimer_obj);
    kernel_multi_elf.root_module.addObject(kernel_swtch_obj);
    kernel_multi_elf.root_module.addObject(kernel_kmain_multi_obj);
    kernel_multi_elf.setLinkerScript(b.path("tests/programs/kernel/linker.ld"));
    kernel_multi_elf.entry = .{ .symbol_name = "_M_start" };

    const install_kernel_multi_elf = b.addInstallArtifact(kernel_multi_elf, .{});
    const kernel_multi_step = b.step("kernel-multi", "Build the Phase 3.B multi-proc kernel.elf");
    kernel_multi_step.dependOn(&install_kernel_multi_elf.step);

    const kernel_fork_elf = b.addExecutable(.{
        .name = "kernel-fork.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    kernel_fork_elf.root_module.addObject(kernel_boot_obj);
    kernel_fork_elf.root_module.addObject(kernel_trampoline_obj);
    kernel_fork_elf.root_module.addObject(kernel_mtimer_obj);
    kernel_fork_elf.root_module.addObject(kernel_swtch_obj);
    kernel_fork_elf.root_module.addObject(kernel_kmain_fork_obj);
    kernel_fork_elf.setLinkerScript(b.path("tests/programs/kernel/linker.ld"));
    kernel_fork_elf.entry = .{ .symbol_name = "_M_start" };

    const install_kernel_fork_elf = b.addInstallArtifact(kernel_fork_elf, .{});
    const kernel_fork_step = b.step("kernel-fork", "Build the Phase 3.C fork-demo kernel.elf");
    kernel_fork_step.dependOn(&install_kernel_fork_elf.step);

    // End-to-end: Plan 2.D uses a host-compiled verifier that spawns ccc
    // on kernel.elf, captures stdout, and asserts the Phase 2 §Definition
    // of done shape ("hello from u-mode\nticks observed: N\n" with N > 0
    // and exit code 0). Replaces expectStdOutEqual which couldn't express
    // a variable N.
    const verify_e2e = b.addExecutable(.{
        .name = "verify_e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/verify_e2e.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const e2e_kernel_run = b.addRunArtifact(verify_e2e);
    e2e_kernel_run.addFileArg(exe.getEmittedBin());
    e2e_kernel_run.addFileArg(kernel_elf.getEmittedBin());
    e2e_kernel_run.expectExitCode(0);

    const e2e_kernel_step = b.step("e2e-kernel", "Run the Phase 2 kernel e2e test (hello + ticks)");
    e2e_kernel_step.dependOn(&e2e_kernel_run.step);

    const multiproc_verify = b.addExecutable(.{
        .name = "multiproc_verify_e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/multiproc_verify_e2e.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const e2e_multiproc_run = b.addRunArtifact(multiproc_verify);
    e2e_multiproc_run.addFileArg(exe.getEmittedBin());
    e2e_multiproc_run.addFileArg(kernel_multi_elf.getEmittedBin());
    e2e_multiproc_run.expectExitCode(0);

    const e2e_multiproc_step = b.step("e2e-multiproc-stub", "Run the Phase 3.B multi-proc e2e test (PID 1 + PID 2)");
    e2e_multiproc_step.dependOn(&e2e_multiproc_run.step);

    // qemu-diff-kernel: debug-only trace diff against QEMU. Requires
    // qemu-system-riscv32 on PATH; not run by CI.
    const qemu_diff_kernel_cmd = b.addSystemCommand(&.{
        "bash",
        "scripts/qemu-diff-kernel.sh",
    });
    qemu_diff_kernel_cmd.step.dependOn(&install_kernel_elf.step);
    const qemu_diff_kernel_step = b.step(
        "qemu-diff-kernel",
        "Diff kernel.elf instruction trace against qemu-system-riscv32 (debug aid)",
    );
    qemu_diff_kernel_step.dependOn(&qemu_diff_kernel_cmd.step);

    // === Phase 3.A integration test ===
    const plic_block_boot = b.addObject(.{
        .name = "plic-block-boot",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
        }),
    });
    plic_block_boot.root_module.addAssemblyFile(b.path("tests/programs/plic_block_test/boot.S"));

    const plic_block_test_obj = b.addObject(.{
        .name = "plic-block-test",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
        }),
    });
    plic_block_test_obj.root_module.addAssemblyFile(b.path("tests/programs/plic_block_test/test.S"));

    const plic_block_elf = b.addExecutable(.{
        .name = "plic_block_test.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    plic_block_elf.root_module.addObject(plic_block_boot);
    plic_block_elf.root_module.addObject(plic_block_test_obj);
    plic_block_elf.setLinkerScript(b.path("tests/programs/plic_block_test/linker.ld"));
    plic_block_elf.entry = .{ .symbol_name = "_M_start" };

    const install_plic_block_elf = b.addInstallArtifact(plic_block_elf, .{});
    const plic_block_step = b.step("plic-block-test", "Build the Phase 3.A integration test ELF");
    plic_block_step.dependOn(&install_plic_block_elf.step);

    // Build the 4 MB test image (sector 0 = 0xCC, rest zero).
    const make_img = b.addExecutable(.{
        .name = "make_plic_block_img",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/plic_block_test/make_img.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const make_img_run = b.addRunArtifact(make_img);
    const test_img = make_img_run.addOutputFileArg("plic_block_test.img");

    // Run e2e-plic-block: ccc --disk <img> <elf>; expect exit 0.
    const e2e_plic_block_run = b.addRunArtifact(exe);
    e2e_plic_block_run.addArg("--disk");
    e2e_plic_block_run.addFileArg(test_img);
    e2e_plic_block_run.addFileArg(plic_block_elf.getEmittedBin());
    e2e_plic_block_run.expectExitCode(0);

    const e2e_plic_block_step = b.step("e2e-plic-block", "Run the Phase 3.A PLIC + block integration test");
    e2e_plic_block_step.dependOn(&e2e_plic_block_run.step);

    // === Minimal ELF fixture (Plan 1.C Task 11) ===
    const min_elf_encoder = b.addExecutable(.{
        .name = "encode_minimal_elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures/encode_minimal_elf.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const min_elf_run = b.addRunArtifact(min_elf_encoder);
    const min_elf_bin = min_elf_run.addOutputFileArg("minimal.elf");
    const install_min_elf = b.addInstallFile(min_elf_bin, "../tests/fixtures/minimal.elf");
    const fixture_step = b.step("fixtures", "Build test-only fixture ELF");
    fixture_step.dependOn(&install_min_elf.step);

    // === riscv-tests helpers (Plan 1.C Task 14-16) ===

    const RiscvTest = struct {
        family: []const u8,
        name: []const u8,
    };

    const riscvTestStep = struct {
        fn call(
            bb: *std.Build,
            rtarget: std.Build.ResolvedTarget,
            link_script: std.Build.LazyPath,
            test_def: RiscvTest,
        ) struct { bin: std.Build.LazyPath, install: *std.Build.Step.InstallArtifact } {
            const src_path = bb.fmt("tests/riscv-tests/isa/{s}/{s}.S", .{ test_def.family, test_def.name });
            const obj = bb.addObject(.{
                .name = bb.fmt("{s}-{s}", .{ test_def.family, test_def.name }),
                .root_module = bb.createModule(.{
                    .root_source_file = null,
                    .target = rtarget,
                    .optimize = .Debug,
                }),
            });
            obj.root_module.addAssemblyFile(bb.path(src_path));
            // Shim must come first: it overrides upstream riscv_test.h
            // to drop `.weak` handler declarations that LLVM's assembler
            // rejects when rv32mi tests later `.global` the same symbols.
            obj.root_module.addIncludePath(bb.path("tests/riscv-tests-shim"));
            obj.root_module.addIncludePath(bb.path("tests/riscv-tests/env/p"));
            obj.root_module.addIncludePath(bb.path("tests/riscv-tests/env"));
            obj.root_module.addIncludePath(bb.path("tests/riscv-tests/isa/macros/scalar"));

            // Companion object: weak refs for mtvec_handler/stvec_handler in a
            // separate assembly unit. Shim removed them from riscv_test.h to
            // keep rv32mi clean; rv32ui/um/ua still reference them via the
            // fall-through trap_vector in RVTEST_CODE_BEGIN and need a weak
            // undef so ld.lld resolves the unused symbol to 0. See
            // tests/riscv-tests-shim/weak_handlers.S for the full rationale.
            const weak_obj = bb.addObject(.{
                .name = bb.fmt("{s}-{s}-weak", .{ test_def.family, test_def.name }),
                .root_module = bb.createModule(.{
                    .root_source_file = null,
                    .target = rtarget,
                    .optimize = .Debug,
                }),
            });
            weak_obj.root_module.addAssemblyFile(bb.path("tests/riscv-tests-shim/weak_handlers.S"));

            const exe_tst = bb.addExecutable(.{
                .name = bb.fmt("{s}-{s}-elf", .{ test_def.family, test_def.name }),
                .root_module = bb.createModule(.{
                    .root_source_file = null,
                    .target = rtarget,
                    .optimize = .Debug,
                    // Keep the symbol table: src/elf.zig resolves `tohost` by
                    // symbol lookup, and the riscv-tests termination protocol
                    // depends on it. ReleaseSmall strips by default.
                    .strip = false,
                }),
            });
            exe_tst.root_module.addObject(obj);
            exe_tst.root_module.addObject(weak_obj);
            exe_tst.setLinkerScript(link_script);
            exe_tst.root_module.single_threaded = true;

            const installed = bb.addInstallArtifact(exe_tst, .{
                .dest_dir = .{ .override = .{ .custom = bb.fmt("riscv-tests/{s}", .{test_def.family}) } },
            });
            return .{ .bin = exe_tst.getEmittedBin(), .install = installed };
        }
    }.call;

    const rv32ui_tests = [_][]const u8{ "add", "addi", "and", "andi", "auipc", "beq", "bge", "bgeu", "blt", "bltu", "bne", "fence_i", "jal", "jalr", "lb", "lbu", "lh", "lhu", "lui", "lw", "or", "ori", "sb", "sh", "simple", "sll", "slli", "slt", "slti", "sltiu", "sltu", "sra", "srai", "srl", "srli", "sub", "sw", "xor", "xori" };
    const rv32um_tests = [_][]const u8{ "mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu" };
    const rv32ua_tests = [_][]const u8{ "amoadd_w", "amoand_w", "amomax_w", "amomaxu_w", "amomin_w", "amominu_w", "amoor_w", "amoswap_w", "amoxor_w", "lrsc" };
    // rv32mi-p: machine-mode CSRs, traps, illegal-instruction, misaligned-addr.
    // Works via tests/riscv-tests-shim/ (Plan 1.D Task 1): drops the upstream
    // `.weak` handler declarations that LLVM's assembler rejects when rv32mi
    // tests later `.global` the same symbols, and provides weak-absolute
    // fallbacks (value 0) so rv32ui/um/ua still link.
    //
    // Excluded from Phase 1 (behaviors not modeled):
    //   - lh-misaligned/lw-misaligned/sh-misaligned/sw-misaligned: Phase 1
    //     traps on all misaligned accesses; upstream tests assert hardware
    //     handles them transparently. Revisit in Phase 2 if a workload needs it.
    //   - instret_overflow/zicntr: require mcycle/minstret hardware performance
    //     counters (Zicntr). Phase 1 doesn't implement Zicntr.
    //   - pmpaddr: requires Physical Memory Protection. Phase 1 has flat
    //     physical addressing.
    //   - breakpoint: requires the Debug/Trigger extension (tcontrol, tselect,
    //     tdata1/2). Phase 1 has no trigger hardware; the test's escape
    //     hatches (csrr tselect → bne → pass) require tselect to exist.
    const rv32mi_tests = [_][]const u8{ "csr", "illegal", "ma_addr", "ma_fetch", "mcsr", "sbreak", "scall", "shamt" };
    // rv32si-p: S-mode CSRs, Sv32 page walks, A/D bits, S-mode WFI, plus
    // S-mode synchronous trap delegation (Plan 2.B).
    // NOTE: no illegal.S exists in the upstream submodule for this family;
    // illegal-instruction coverage lives in rv32mi.
    //
    // Excluded (permanent in Phase 2):
    //   - dirty: exercises a root-level (L1) leaf PTE — a 4 MiB Sv32
    //     superpage. Phase 2 permanently rejects superpages (spec
    //     §Sv32 translation). Revisit only if a future phase adopts them.
    const rv32si_tests = [_][]const u8{ "csr", "scall", "wfi", "sbreak", "ma_fetch" };

    const rv_step = b.step("riscv-tests", "Run the riscv-tests suite (rv32ui/um/ua/mi/si)");

    const all_families = [_]struct {
        family: []const u8,
        list: []const []const u8,
        ld: []const u8,
    }{
        .{ .family = "rv32ui", .list = &rv32ui_tests, .ld = "tests/riscv-tests-p.ld" },
        .{ .family = "rv32um", .list = &rv32um_tests, .ld = "tests/riscv-tests-p.ld" },
        .{ .family = "rv32ua", .list = &rv32ua_tests, .ld = "tests/riscv-tests-p.ld" },
        .{ .family = "rv32mi", .list = &rv32mi_tests, .ld = "tests/riscv-tests-p.ld" },
        .{ .family = "rv32si", .list = &rv32si_tests, .ld = "tests/riscv-tests-s.ld" },
    };

    for (all_families) |fam| {
        const ld_path = b.path(fam.ld);
        for (fam.list) |name| {
            const elf_path = riscvTestStep(b, rv_target, ld_path, .{
                .family = fam.family,
                .name = name,
            });
            const run_it = b.addRunArtifact(exe);
            run_it.addFileArg(elf_path.bin);
            run_it.expectExitCode(0);
            rv_step.dependOn(&run_it.step);
        }
    }

    // === Phase 1.W — Web demo: cross-compile ccc to wasm32-freestanding ===
    // Thin entry point in demo/web_main.zig that imports the existing
    // emulator modules and exports a minimal run/outputPtr/outputLen
    // interface for the browser. The web_main.zig file embeds hello.elf
    // at compile time, so this step depends on the hello-elf build.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    // Single emulator module exposed via src/lib.zig so demo/web_main.zig
    // can import the emulator without escaping its own package root.
    // One module (not six) avoids "file exists in modules X and Y": the
    // emulator files cross-import each other via relative paths, so
    // declaring memory/cpu/etc as separate modules would pull the same
    // file into multiple module trees. The shim re-exports the six
    // pieces web_main.zig needs (cpu / memory / elf / halt / uart / clint).
    const ccc_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
    });

    const wasm_exe = b.addExecutable(.{
        .name = "ccc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("demo/web_main.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "ccc", .module = ccc_module },
            },
        }),
    });
    wasm_exe.entry = .disabled;        // we call our own export, not _start
    wasm_exe.rdynamic = true;          // expose `export fn` symbols

    // Expose hello.elf as an importable module so web_main.zig can
    // @embedFile it without escaping demo/'s package root. WriteFile
    // step that co-locates a tiny Zig stub with hello.elf in a single
    // output dir; the stub `pub const BLOB = @embedFile(...)` resolves
    // relative to itself, so the .elf must be its sibling. Mirrors
    // the user_blob pattern used by kernel.elf (see above).
    const hello_blob_dir = b.addWriteFiles();
    const hello_blob_zig = hello_blob_dir.add(
        "hello_elf.zig",
        "pub const BLOB = @embedFile(\"hello.elf\");\n",
    );
    _ = hello_blob_dir.addCopyFile(hello_elf.getEmittedBin(), "hello.elf");
    wasm_exe.root_module.addAnonymousImport("hello_elf", .{
        .root_source_file = hello_blob_zig,
    });

    const install_wasm = b.addInstallArtifact(wasm_exe, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
    });
    // Make sure hello.elf is built before we try to @embedFile it.
    install_wasm.step.dependOn(&install_hello_elf.step);
    const wasm_step = b.step("wasm", "Cross-compile ccc to wasm32-freestanding");
    wasm_step.dependOn(&install_wasm.step);
}
