const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that don't match the filter") orelse &.{};

    buildUnitTests(b, test_filters);
    buildExamples(b, test_filters);
}

pub fn buildUnitTests(b: *std.Build, test_filters: []const []const u8) void {
    const unit_test_mod = b.createModule(.{
        .root_source_file = b.path("src/unit_tests.zig"),
        .target = b.resolveTargetQuery(.{ .os_tag = .linux, .cpu_arch = .x86_64 }),
        .optimize = .Debug,
    });

    const unit_test = b.addTest(.{ .root_module = unit_test_mod, .filters = test_filters });
    const run_unit_test = b.addRunArtifact(unit_test);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_test.step);
}

const examples = [_][]const u8{
    "single_threaded",
    "thread_per_request",
    "thread_pool",
    "unix_domain_socket",
};

pub fn buildExamples(b: *std.Build, test_filters: []const []const u8) void {
    const gibe_module = b.createModule(.{
        .root_source_file = b.path("src/gibe.zig"),
        .target = b.resolveTargetQuery(.{ .os_tag = .linux, .cpu_arch = .x86_64 }),
        .optimize = .Debug,
    });

    const test_step = b.step("test-examples", "Run unit tests in examples");

    inline for (examples) |example| {
        // build
        const exe_mod = b.createModule(.{
            .root_source_file = b.path("examples/" ++ example ++ ".zig"),
            .target = b.resolveTargetQuery(.{ .os_tag = .linux, .cpu_arch = .x86_64 }),
            .optimize = .Debug,
        });
        exe_mod.addImport("gibe", gibe_module);

        const exe = b.addExecutable(.{ .name = example, .root_module = exe_mod });

        b.installArtifact(exe);

        // run
        const run_exe = b.addRunArtifact(exe);

        const run_step = b.step("run-" ++ comptime camelToKebabCase(example), "Run examples/" ++ example ++ ".zig");
        run_step.dependOn(&run_exe.step);

        // test
        const unit_test_mod = b.createModule(.{
            .root_source_file = b.path("examples/" ++ example ++ ".zig"),
            .target = b.resolveTargetQuery(.{ .os_tag = .linux, .cpu_arch = .x86_64 }),
            .optimize = .Debug,
        });
        unit_test_mod.addImport("gibe", gibe_module);

        const unit_test = b.addTest(.{ .root_module = unit_test_mod, .filters = test_filters });
        const run_unit_test = b.addRunArtifact(unit_test);

        test_step.dependOn(&run_unit_test.step);
    }
}

fn camelToKebabCase(comptime string: []const u8) []const u8 {
    comptime var result: [string.len]u8 = undefined;

    for (string, 0..) |c, i| {
        result[i] = if (c == '_') '-' else c;
    }

    return &result;
}
