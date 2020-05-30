const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const lib = b.addStaticLibrary("art", "src/art.zig");
    lib.setBuildMode(mode);
    lib.linkLibC();
    lib.install();

    var main_tests = b.addTest("src/test_art.zig");
    main_tests.setBuildMode(mode);
    main_tests.linkLibC();

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
