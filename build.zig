const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options.
    const optimize = b.standardOptimizeOption(.{});

    // Create modules with target and optimize
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create the main library
    const lib = b.addLibrary(.{
        .name = "foldb",
        .root_module = lib_module,
    });

    // Install the library
    b.installArtifact(lib);

    // Create the main executable
    const exe = b.addExecutable(.{
        .name = "foldb",
        .root_module = main_module,
    });

    exe.root_module.addImport("lib.zig", lib_module);

    // Install the executable
    b.installArtifact(exe);

    // Run the executable as a test step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the foldb application");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_module,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = main_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Create log module for tests
    const log_module = b.createModule(.{
        .root_source_file = b.path("src/log/log.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Log segment tests
    const log_segment_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/log/segment_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    log_segment_test_module.addImport("log.zig", log_module);

    const log_segment_tests = b.addTest(.{
        .root_module = log_segment_test_module,
    });

    const run_log_segment_tests = b.addRunArtifact(log_segment_tests);

    // Log manager tests
    const log_manager_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/log/manager_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    log_manager_test_module.addImport("log.zig", log_module);

    const log_manager_tests = b.addTest(.{
        .root_module = log_manager_test_module,
    });

    const run_log_manager_tests = b.addRunArtifact(log_manager_tests);

    // Log durability tests
    const log_durability_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/log/durability_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    log_durability_test_module.addImport("log.zig", log_module);

    const log_durability_tests = b.addTest(.{
        .root_module = log_durability_test_module,
    });

    const run_log_durability_tests = b.addRunArtifact(log_durability_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_log_segment_tests.step);
    test_step.dependOn(&run_log_manager_tests.step);
    test_step.dependOn(&run_log_durability_tests.step);

    // Individual test steps
    const log_test_step = b.step("log-test", "Run log module tests");
    log_test_step.dependOn(&run_log_segment_tests.step);
    log_test_step.dependOn(&run_log_manager_tests.step);
    log_test_step.dependOn(&run_log_durability_tests.step);
}
