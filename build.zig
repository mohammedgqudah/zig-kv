const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("zig_simple_kv", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });

    const translate_c_module = translate_c.createModule();
    translate_c_module.optimize = optimize;

    const exe = b.addExecutable(.{
        .name = "zig_simple_kv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_simple_kv", .module = mod },
                .{ .name = "c", .module = translate_c_module },
            },
        }),
    });

    const options = b.addOptions();
    options.addOption(bool, "disable_page_cache", false);

    exe.root_module.addOptions("config", options);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    // tests

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &[0][]const u8{};
    const test_step = b.step("test", "Run tests");

    // page cache enabled
    const options_enabled = b.addOptions();
    options_enabled.addOption(bool, "disable_page_cache", false);
    addTestStep(
        b,
        target,
        optimize,
        test_step,
        "test-cache-enabled",
        "Run tests with page cache enabled",
        test_filters,
        options_enabled,
    );

    // page cache disabled
    const options_disabled = b.addOptions();
    options_disabled.addOption(bool, "disable_page_cache", true);
    addTestStep(
        b,
        target,
        optimize,
        test_step,
        "test-cache-disabled",
        "Run tests with page cache disabled",
        test_filters,
        options_disabled,
    );
}

/// Add tests with `options` as its `config` module.
fn addTestStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    name: []const u8,
    description: []const u8,
    filters: []const []const u8,
    options: *std.Build.Step.Options,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("config", options);
    const tests = b.addTest(.{
        .root_module = mod,
        .filters = filters,
    });
    const run_tests_step = b.addRunArtifact(tests);
    const step = b.step(name, description);
    step.dependOn(&run_tests_step.step);

    test_step.dependOn(step);
}
