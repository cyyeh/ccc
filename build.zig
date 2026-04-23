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
    const rv_target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv32,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = blk: {
            const features = std.Target.riscv.Feature;
            var set = std.Target.Cpu.Feature.Set.empty;
            set.addFeature(@intFromEnum(features.m));
            set.addFeature(@intFromEnum(features.a));
            break :blk set;
        },
    });

    const RiscvTest = struct {
        family: []const u8,
        name: []const u8,
    };

    const rv_link_script = b.path("tests/riscv-tests-p.ld");

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
                    .optimize = .ReleaseSmall,
                }),
            });
            obj.root_module.addAssemblyFile(bb.path(src_path));
            obj.root_module.addIncludePath(bb.path("tests/riscv-tests/env/p"));
            obj.root_module.addIncludePath(bb.path("tests/riscv-tests/env"));
            obj.root_module.addIncludePath(bb.path("tests/riscv-tests/isa/macros/scalar"));

            const exe_tst = bb.addExecutable(.{
                .name = bb.fmt("{s}-{s}-elf", .{ test_def.family, test_def.name }),
                .root_module = bb.createModule(.{
                    .root_source_file = null,
                    .target = rtarget,
                    .optimize = .ReleaseSmall,
                }),
            });
            exe_tst.root_module.addObject(obj);
            exe_tst.setLinkerScript(link_script);
            exe_tst.root_module.single_threaded = true;

            const installed = bb.addInstallArtifact(exe_tst, .{
                .dest_dir = .{ .override = .{ .custom = bb.fmt("riscv-tests/{s}", .{test_def.family}) } },
            });
            return .{ .bin = exe_tst.getEmittedBin(), .install = installed };
        }
    }.call;

    const smoke = riscvTestStep(b, rv_target, rv_link_script, .{
        .family = "rv32ui",
        .name = "add",
    });
    const smoke_step = b.step("riscv-tests-smoke", "Build a single riscv-test as a smoke check");
    smoke_step.dependOn(&smoke.install.step);
    _ = smoke.bin;
}
