const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption(bool, "debug_scanner", b.option(bool, "debug-scanner", "Enable scanner debug output") orelse false);
    options.addOption(bool, "debug_compiler", b.option(bool, "debug-compiler", "Enable compiler debug output") orelse false);
    options.addOption(bool, "debug_vm", b.option(bool, "debug-vm", "Enable VM debug output") orelse false);

    // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addOptions("config", options);

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "zlox",
        .root_module = exe_mod,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    // Lox print statements write to stdout, which the test server uses for its
    // protocol. Run the default runner directly without server mode instead.
    const run_exe_unit_tests = std.Build.Step.Run.create(b, "run tests");
    run_exe_unit_tests.addArtifactArg(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // A `bench` step that runs the Lox programs in bench/lox against an
    // optimized zlox build. Pass benchmark names to run a subset:
    // `zig build bench -- fib loop`
    const bench_options = b.addOptions();
    bench_options.addOption(bool, "debug_scanner", false);
    bench_options.addOption(bool, "debug_compiler", false);
    bench_options.addOption(bool, "debug_vm", false);

    const bench_zlox_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_zlox_mod.addOptions("config", bench_options);

    const bench_zlox = b.addExecutable(.{
        .name = "zlox-bench",
        .root_module = bench_zlox_mod,
    });

    const gen_compile_large = b.addExecutable(.{
        .name = "gen-compile-large",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/gen_compile_large.zig"),
            .target = b.graph.host,
        }),
    });
    const gen_compile_large_run = b.addRunArtifact(gen_compile_large);
    const compile_large_lox = gen_compile_large_run.addOutputFileArg("compile_large.lox");

    const bench_programs = b.addWriteFiles();
    _ = bench_programs.addCopyDirectory(b.path("bench/lox"), "", .{});
    _ = bench_programs.addCopyFile(compile_large_lox, "compile_large.lox");

    const bench_runner = b.addExecutable(.{
        .name = "bench-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/runner.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });

    const bench_cmd = b.addRunArtifact(bench_runner);
    bench_cmd.addArtifactArg(bench_zlox);
    bench_cmd.addDirectoryArg(bench_programs.getDirectory());
    bench_cmd.addDirectoryArg(b.path("bench/expected"));
    bench_cmd.has_side_effects = true;
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    const bench_step = b.step("bench", "Run benchmarks (optionally filtered by name)");
    bench_step.dependOn(&bench_cmd.step);

    // A `check` step for ZLS build-on-save diagnostics. These artifacts are not
    // installed, so Zig skips emitting binaries and only runs semantic analysis.
    const exe_check = b.addExecutable(.{
        .name = "zlox",
        .root_module = exe_mod,
    });

    const check_step = b.step("check", "Check if zlox compiles");
    check_step.dependOn(&exe_check.step);
}
