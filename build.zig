const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that don't match the filter") orelse &.{};

    const lib_path = b.path("lib");

    const gibe_module = b.addModule("gibe", .{
        .root_source_file = b.path("src/gibe.zig"),
        .target = target,
        .optimize = optimize,
    });
    gibe_module.addCSourceFile(.{
        .file = b.path("lib/multipart_parser.c"),
        .flags = &[_][]const u8{"-std=c89"},
    });
    gibe_module.addIncludePath(lib_path);
    gibe_module.link_libc = true;

    buildUnitTests(b, target, optimize, test_filters, lib_path);
    buildExamples(b, gibe_module, target, optimize, test_filters);
}

pub fn buildUnitTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, test_filters: []const []const u8, lib_path: std.Build.LazyPath) void {
    const unit_test_mod = b.createModule(.{
        .root_source_file = b.path("src/unit_tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_test = b.addTest(.{ .root_module = unit_test_mod, .filters = test_filters });
    unit_test.addCSourceFile(.{
        .file = b.path("lib/multipart_parser.c"),
        .flags = &[_][]const u8{"-std=c89"},
    });
    unit_test.addIncludePath(lib_path);
    unit_test.linkLibC();

    const run_unit_test = b.addRunArtifact(unit_test);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_test.step);
}

const examples = [_][]const u8{
    "single_threaded",
    "thread_per_request",
    "thread_pool",
    "unix_domain_socket",
    "routing",
    "multipart_form",
};

pub fn buildExamples(b: *std.Build, gibe_module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, test_filters: []const []const u8) void {
    const test_step = b.step("test-examples", "Run unit tests in examples");

    inline for (examples) |example| {
        const example_module = b.createModule(.{
            .root_source_file = b.path("examples/" ++ example ++ ".zig"),
            .target = target,
            .optimize = optimize,
        });
        example_module.addImport("gibe", gibe_module);

        // build
        const exe = b.addExecutable(.{ .name = example, .root_module = example_module });

        b.installArtifact(exe);

        // run
        const run_exe = b.addRunArtifact(exe);

        const run_step = b.step("run-" ++ comptime camelToKebabCase(example), "Run examples/" ++ example ++ ".zig");
        run_step.dependOn(&run_exe.step);

        // test
        const unit_test = b.addTest(.{ .root_module = example_module, .filters = test_filters });
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
