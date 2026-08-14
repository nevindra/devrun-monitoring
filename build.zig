const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Release by default, because a plain `zig build` is what the README tells
    // people to run and what they then judge devrun by. Debug is not a slower
    // build of the same program here: it poisons every allocation with 0xaa,
    // which makes each Worker's Window resident from the first second whether
    // or not anything was ever logged to it. `-Doptimize=Debug` still works.
    //
    // Spelled out rather than `standardOptimizeOption(.{ .preferred_optimize_mode
    // = .ReleaseFast })`, which does not do this: that form leaves the default
    // at Debug and only decides what `-Drelease` resolves to.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseFast)",
    ) orelse .ReleaseFast;
    const strip = b.option(bool, "strip", "Strip debug info from the binary") orelse
        (optimize != .Debug);

    // Vendored rather than fetched: zig-yaml's own build.zig does not compile
    // on Zig 0.16. See src/vendor/yaml/PROVENANCE.md.
    const yaml = b.createModule(.{
        .root_source_file = b.path("src/vendor/yaml/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    mod.addImport("yaml", yaml);

    const exe = b.addExecutable(.{
        .name = "devrun",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Build and run devrun").dependOn(&run.step);

    // Tests are built at Debug regardless of what the exe is built at: the
    // bounds, overflow and alignment checks are most of what a test run is
    // for, and ReleaseFast drops all of them.
    const test_yaml = b.createModule(.{
        .root_source_file = b.path("src/vendor/yaml/lib.zig"),
        .target = target,
        .optimize = .Debug,
    });
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .Debug,
    });
    test_mod.addImport("yaml", test_yaml);

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
