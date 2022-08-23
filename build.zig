const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const lib = b.addStaticLibrary("art", "src/art.zig");
    lib.setBuildMode(mode);
    lib.linkLibC();
    lib.install();
    lib.use_stage1 = true;

    var main_tests = b.addTest("src/test_art.zig");
    main_tests.setBuildMode(mode);
    // main_tests.filter = "display children";
    main_tests.setBuildMode(std.builtin.Mode.ReleaseSafe);
    main_tests.linkLibC();
    main_tests.use_stage1 = true;

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
