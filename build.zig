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

    // Raft module
    const raft_module = b.createModule(.{
        .root_source_file = b.path("src/raft/raft.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_module.addImport("log.zig", log_module);

    // Raft sub-modules need log.zig too
    // (raft.zig imports types/rpc/node/transport/cluster/persistent which import log.zig)
    // We satisfy this by adding the import at the raft module level — Zig propagates it.

    // Raft RPC tests
    const raft_rpc_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/raft/rpc_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_rpc_test_module.addImport("raft.zig", raft_module);
    raft_rpc_test_module.addImport("log.zig", log_module);
    const raft_rpc_tests = b.addTest(.{ .root_module = raft_rpc_test_module });
    const run_raft_rpc_tests = b.addRunArtifact(raft_rpc_tests);

    // Raft node (pure state machine) tests
    const raft_node_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/raft/node_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_node_test_module.addImport("raft.zig", raft_module);
    raft_node_test_module.addImport("log.zig", log_module);
    const raft_node_tests = b.addTest(.{ .root_module = raft_node_test_module });
    const run_raft_node_tests = b.addRunArtifact(raft_node_tests);

    // Raft cluster (simulation) tests
    const raft_cluster_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/raft/cluster_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_cluster_test_module.addImport("raft.zig", raft_module);
    raft_cluster_test_module.addImport("log.zig", log_module);
    const raft_cluster_tests = b.addTest(.{ .root_module = raft_cluster_test_module });
    const run_raft_cluster_tests = b.addRunArtifact(raft_cluster_tests);

    // Linearizability tests
    const raft_linear_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/raft/linearizability_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_linear_test_module.addImport("raft.zig", raft_module);
    raft_linear_test_module.addImport("log.zig", log_module);
    const raft_linear_tests = b.addTest(.{ .root_module = raft_linear_test_module });
    const run_raft_linear_tests = b.addRunArtifact(raft_linear_tests);

    // Storage module (all storage files belong to this single module)
    const storage_module = b.createModule(.{
        .root_source_file = b.path("src/storage/storage.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Storage codec tests
    const storage_codec_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/storage/codec_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    storage_codec_test_module.addImport("storage.zig", storage_module);
    const storage_codec_tests = b.addTest(.{ .root_module = storage_codec_test_module });
    const run_storage_codec_tests = b.addRunArtifact(storage_codec_tests);

    // Storage block tests
    const storage_block_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/storage/block_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    storage_block_test_module.addImport("storage.zig", storage_module);
    const storage_block_tests = b.addTest(.{ .root_module = storage_block_test_module });
    const run_storage_block_tests = b.addRunArtifact(storage_block_tests);

    // Storage SSTable tests
    const storage_sstable_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/storage/sstable_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    storage_sstable_test_module.addImport("storage.zig", storage_module);
    const storage_sstable_tests = b.addTest(.{ .root_module = storage_sstable_test_module });
    const run_storage_sstable_tests = b.addRunArtifact(storage_sstable_tests);

    // Storage LSM tests
    const storage_lsm_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/storage/lsm_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    storage_lsm_test_module.addImport("storage.zig", storage_module);
    const storage_lsm_tests = b.addTest(.{ .root_module = storage_lsm_test_module });
    const run_storage_lsm_tests = b.addRunArtifact(storage_lsm_tests);

    // Storage replay (DST) tests
    const storage_replay_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/storage/replay_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    storage_replay_test_module.addImport("storage.zig", storage_module);
    const storage_replay_tests = b.addTest(.{ .root_module = storage_replay_test_module });
    const run_storage_replay_tests = b.addRunArtifact(storage_replay_tests);

    // Executor module
    const executor_module = b.createModule(.{
        .root_source_file = b.path("src/executor/executor.zig"),
        .target = target,
        .optimize = optimize,
    });
    executor_module.addImport("storage.zig", storage_module);
    executor_module.addImport("log.zig", log_module);

    // Executor unit tests
    const executor_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/executor/executor_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    executor_test_module.addImport("executor.zig", executor_module);
    executor_test_module.addImport("storage.zig", storage_module);
    executor_test_module.addImport("log.zig", log_module);
    const executor_tests = b.addTest(.{ .root_module = executor_test_module });
    const run_executor_tests = b.addRunArtifact(executor_tests);

    // Executor replay (DST)
    const executor_replay_module = b.createModule(.{
        .root_source_file = b.path("src/tests/executor/replay_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    executor_replay_module.addImport("executor.zig", executor_module);
    executor_replay_module.addImport("storage.zig", storage_module);
    executor_replay_module.addImport("log.zig", log_module);
    const executor_replay_tests = b.addTest(.{ .root_module = executor_replay_module });
    const run_executor_replay_tests = b.addRunArtifact(executor_replay_tests);

    // SQL module
    const sql_module = b.createModule(.{
        .root_source_file = b.path("src/sql/sql.zig"),
        .target = target,
        .optimize = optimize,
    });
    sql_module.addImport("storage.zig", storage_module);
    sql_module.addImport("executor.zig", executor_module);
    sql_module.addImport("log.zig", log_module);

    // SQL lexer tests
    const sql_lexer_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sql/lexer_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sql_lexer_test_module.addImport("sql.zig", sql_module);
    const sql_lexer_tests = b.addTest(.{ .root_module = sql_lexer_test_module });
    const run_sql_lexer_tests = b.addRunArtifact(sql_lexer_tests);

    // SQL parser tests
    const sql_parser_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sql/parser_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sql_parser_test_module.addImport("sql.zig", sql_module);
    const sql_parser_tests = b.addTest(.{ .root_module = sql_parser_test_module });
    const run_sql_parser_tests = b.addRunArtifact(sql_parser_tests);

    // SQL registry tests
    const sql_registry_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sql/registry_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sql_registry_test_module.addImport("sql.zig", sql_module);
    const sql_registry_tests = b.addTest(.{ .root_module = sql_registry_test_module });
    const run_sql_registry_tests = b.addRunArtifact(sql_registry_tests);

    // SQL integration tests
    const sql_integration_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sql/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sql_integration_test_module.addImport("sql.zig", sql_module);
    const sql_integration_tests = b.addTest(.{ .root_module = sql_integration_test_module });
    const run_sql_integration_tests = b.addRunArtifact(sql_integration_tests);

    // SQL type checker tests
    const sql_tc_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sql/type_checker_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sql_tc_test_module.addImport("sql.zig", sql_module);
    const sql_tc_tests = b.addTest(.{ .root_module = sql_tc_test_module });
    const run_sql_tc_tests = b.addRunArtifact(sql_tc_tests);

    // SQL schema tests
    const sql_schema_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sql/schema_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sql_schema_test_module.addImport("sql.zig", sql_module);
    const sql_schema_tests = b.addTest(.{ .root_module = sql_schema_test_module });
    const run_sql_schema_tests = b.addRunArtifact(sql_schema_tests);

    // SQL executor expression tests
    const sql_executor_expr_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sql/executor_expr_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sql_executor_expr_test_module.addImport("sql.zig", sql_module);
    const sql_executor_expr_tests = b.addTest(.{ .root_module = sql_executor_expr_test_module });
    const run_sql_executor_expr_tests = b.addRunArtifact(sql_executor_expr_tests);

    // SQL replay (DST) tests
    const sql_replay_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sql/replay_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sql_replay_test_module.addImport("sql.zig", sql_module);
    sql_replay_test_module.addImport("executor.zig", executor_module);
    sql_replay_test_module.addImport("storage.zig", storage_module);
    const sql_replay_tests = b.addTest(.{ .root_module = sql_replay_test_module });
    const run_sql_replay_tests = b.addRunArtifact(sql_replay_tests);

    // SQL planner tests
    const sql_planner_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sql/planner_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sql_planner_test_module.addImport("sql.zig", sql_module);
    const sql_planner_tests = b.addTest(.{ .root_module = sql_planner_test_module });
    const run_sql_planner_tests = b.addRunArtifact(sql_planner_tests);

    // Gateway module
    const gateway_module = b.createModule(.{
        .root_source_file = b.path("src/gateway/gateway.zig"),
        .target = target,
        .optimize = optimize,
    });
    gateway_module.addImport("sql.zig", sql_module);
    gateway_module.addImport("storage.zig", storage_module);
    gateway_module.addImport("executor.zig", executor_module);
    gateway_module.addImport("log.zig", log_module);
    gateway_module.addImport("registry.zig", sql_module);
    gateway_module.addImport("executor_bridge.zig", sql_module);
    gateway_module.addImport("schema.zig", sql_module);
    gateway_module.addImport("parser.zig", sql_module);
    gateway_module.addImport("ast.zig", sql_module);
    gateway_module.addImport("types.zig", executor_module);

    // Gateway unit tests
    const gateway_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/gateway/gateway_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    gateway_test_module.addImport("gateway.zig", gateway_module);
    gateway_test_module.addImport("sql.zig", sql_module);
    gateway_test_module.addImport("storage.zig", storage_module);
    gateway_test_module.addImport("executor.zig", executor_module);
    const gateway_tests = b.addTest(.{ .root_module = gateway_test_module });
    const run_gateway_tests = b.addRunArtifact(gateway_tests);

    // Unit tests: pure logic, no simulation harness
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_log_segment_tests.step);
    test_step.dependOn(&run_log_manager_tests.step);
    test_step.dependOn(&run_log_durability_tests.step);
    test_step.dependOn(&run_raft_rpc_tests.step);
    test_step.dependOn(&run_raft_node_tests.step);
    test_step.dependOn(&run_storage_codec_tests.step);
    test_step.dependOn(&run_storage_block_tests.step);
    test_step.dependOn(&run_storage_sstable_tests.step);
    test_step.dependOn(&run_storage_lsm_tests.step);
    test_step.dependOn(&run_executor_tests.step);
    test_step.dependOn(&run_sql_lexer_tests.step);
    test_step.dependOn(&run_sql_parser_tests.step);
    test_step.dependOn(&run_sql_registry_tests.step);
    test_step.dependOn(&run_sql_integration_tests.step);
    test_step.dependOn(&run_sql_tc_tests.step);
    test_step.dependOn(&run_sql_schema_tests.step);
    test_step.dependOn(&run_sql_planner_tests.step);
    test_step.dependOn(&run_sql_executor_expr_tests.step);
    test_step.dependOn(&run_gateway_tests.step);

    // Deterministic simulation tests
    const dst_step = b.step("dst-test", "Run deterministic simulation tests");
    dst_step.dependOn(&run_raft_cluster_tests.step);
    dst_step.dependOn(&run_raft_linear_tests.step);
    dst_step.dependOn(&run_storage_replay_tests.step);
    dst_step.dependOn(&run_executor_replay_tests.step);
    dst_step.dependOn(&run_sql_replay_tests.step);
}
