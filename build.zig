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
    const module_enabled = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = exe.root_module.resolved_target,
        .optimize = exe.root_module.optimize,
    });
    module_enabled.addOptions("config", options_enabled);
    const tests_cache_enabled = b.addTest(.{
        .root_module = module_enabled,
        .filters = test_filters,
    });
    const run_tests_cache_enabled = b.addRunArtifact(tests_cache_enabled);
    const enabled_step = b.step(
        "test-cache-enabled",
        "Run tests with page cache enabled",
    );
    enabled_step.dependOn(&run_tests_cache_enabled.step);

    // page cache disabled
    const options_disabled = b.addOptions();
    options_disabled.addOption(bool, "disable_page_cache", true);
    const module_disabled = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = exe.root_module.resolved_target,
        .optimize = exe.root_module.optimize,
    });
    module_disabled.addOptions("config", options_disabled);
    const tests_cache_disabled = b.addTest(.{
        .root_module = module_disabled,
        .filters = test_filters,
    });
    const run_tests_cache_disabled = b.addRunArtifact(tests_cache_disabled);
    const disabled_step = b.step(
        "test-cache-disabled",
        "Run tests with page cache disabled",
    );
    disabled_step.dependOn(&run_tests_cache_disabled.step);

    test_step.dependOn(enabled_step);
    test_step.dependOn(disabled_step);
}
