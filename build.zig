const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const qoi = b.addModule("qoi", .{
        .root_source_file = b.path("src/qoi.zig"),
        .target = target,
        .optimize = optimize,
    });

    //const libqoi = b.addSharedLibrary(.{
    //    .name = "qoi",
    //    .root_source_file = b.path("src/qoi.zig"),
    //    .target = target,
    //    .optimize = optimize,
    //    .version = .{ .major = 0, .minor = 0, .patch = 0 },
    //});

    //b.installArtifact(libqoi);

    const exe = b.addExecutable(.{
        .name = "example_cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "qoi", .module = qoi },
            },
        }),
    });

    //exe.linkLibrary(libqoi);

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

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    //const bench_cmd = b.addSystemCommand(&.{
    //    "hyperfine", b.path("zig-out/bin/example_cli").,
    //});
    //bench_cmd.step.dependOn(b.getInstallStep());

    //const bench_step = b.step("bench", "Benchmark");
    //bench_step.dependOn(&bench_cmd.step);


    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
        //bench_cmd.addArgs(args);
    }

    const exe_unit_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
