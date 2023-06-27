const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    const mod = b.addModule("art", .{
        .source_file = .{ .path = "src/art.zig" },
    });

    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const exe = b.addExecutable(.{
        .name = "art",
        .root_source_file = .{ .path = "src/main.zig" },
        .optimize = optimize,
        .target = target,
    });
    exe.linkLibC();
    exe.addModule("art", mod);
    const install = b.addInstallArtifact(exe);
    b.getInstallStep().dependOn(&install.step);

    var tests = b.addTest(.{
        .root_source_file = .{ .path = "src/test_art.zig" },
        .optimize = optimize,
        .target = target,
    });
    tests.linkLibC();
    tests.addModule("art", mod);
    const test_step = b.step("test", "Run library tests");
    const main_tests_run = b.addRunArtifact(tests);
    main_tests_run.has_side_effects = true;
    test_step.dependOn(&main_tests_run.step);

    const bench = b.addExecutable(.{
        .name = "bench",
        .root_source_file = .{ .path = "src/bench2.zig" },
        .optimize = .ReleaseFast,
        .target = target,
    });
    bench.linkLibC();
    bench.addModule("art", mod);
    const bench_run = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Bench against std.StringHashMap()");
    bench_step.dependOn(&bench_run.step);
}
