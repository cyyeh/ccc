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
    kernel_elf.root_module.addObject(kernel_kmain_obj);
    kernel_elf.setLinkerScript(b.path("tests/programs/kernel/linker.ld"));
    kernel_elf.entry = .{ .symbol_name = "_M_start" };

    const install_kernel_elf = b.addInstallArtifact(kernel_elf, .{});
    const kernel_elf_step = b.step("kernel-elf", "Build the Plan 2.C kernel.elf");
    kernel_elf_step.dependOn(&install_kernel_elf.step);

    const kernel_step = b.step("kernel", "Alias for kernel-elf");
    kernel_step.dependOn(&install_kernel_elf.step);

    // End-to-end: run the Plan 2.C kernel.elf through the emulator and
    // assert the observable stdout. The expected output grows across
    // Tasks 2, 8, 17 before settling at "hello from u-mode\n" in Task 17.
    const e2e_kernel_run = b.addRunArtifact(exe);
    e2e_kernel_run.addFileArg(kernel_elf.getEmittedBin());
    e2e_kernel_run.expectStdOutEqual("ok\n");
    e2e_kernel_run.expectExitCode(0);

    const e2e_kernel_step = b.step("e2e-kernel", "Run the Plan 2.C kernel e2e test");
    e2e_kernel_step.dependOn(&e2e_kernel_run.step);

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
}
