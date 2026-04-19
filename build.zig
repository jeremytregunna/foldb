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

    // Observability module
    const observability_module = b.createModule(.{
        .root_source_file = b.path("src/observability/observability.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Sim module
    const sim_module = b.createModule(.{
        .root_source_file = b.path("src/sim/sim.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Sim clock tests
    const sim_clock_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sim/clock_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sim_clock_test_module.addImport("sim.zig", sim_module);

    const sim_clock_tests = b.addTest(.{ .root_module = sim_clock_test_module });
    const run_sim_clock_tests = b.addRunArtifact(sim_clock_tests);

    // Sim scheduler tests
    const sim_scheduler_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sim/scheduler_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sim_scheduler_test_module.addImport("sim.zig", sim_module);
    const sim_scheduler_tests = b.addTest(.{ .root_module = sim_scheduler_test_module });
    const run_sim_scheduler_tests = b.addRunArtifact(sim_scheduler_tests);

    // Sim network tests
    const sim_network_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sim/network_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sim_network_test_module.addImport("sim.zig", sim_module);
    const sim_network_tests = b.addTest(.{ .root_module = sim_network_test_module });
    const run_sim_network_tests = b.addRunArtifact(sim_network_tests);

    // Observability tests
    const obs_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/observability/metrics_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    obs_test_module.addImport("observability.zig", observability_module);
    const obs_tests = b.addTest(.{ .root_module = obs_test_module });
    const run_obs_tests = b.addRunArtifact(obs_tests);

    // Create log module for tests
    const log_module = b.createModule(.{
        .root_source_file = b.path("src/log/log.zig"),
        .target = target,
        .optimize = optimize,
    });
    log_module.addImport("observability.zig", observability_module);

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

    // Log replay (DST)
    const log_replay_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/log/replay_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    log_replay_test_module.addImport("log.zig", log_module);
    const log_replay_tests = b.addTest(.{ .root_module = log_replay_test_module });
    const run_log_replay_tests = b.addRunArtifact(log_replay_tests);

    // Raft module
    const raft_module = b.createModule(.{
        .root_source_file = b.path("src/raft/raft.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_module.addImport("log.zig", log_module);
    raft_module.addImport("observability.zig", observability_module);
    raft_module.addImport("sim.zig", sim_module);

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
    storage_module.addImport("observability.zig", observability_module);

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

    // Storage tiered tests
    const storage_tiered_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/storage/tiered_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    storage_tiered_test_module.addImport("storage.zig", storage_module);
    const storage_tiered_tests = b.addTest(.{ .root_module = storage_tiered_test_module });
    const run_storage_tiered_tests = b.addRunArtifact(storage_tiered_tests);

    // Storage snapshot tests
    const storage_snapshot_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/storage/snapshot_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    storage_snapshot_test_module.addImport("storage.zig", storage_module);
    const storage_snapshot_tests = b.addTest(.{ .root_module = storage_snapshot_test_module });
    const run_storage_snapshot_tests = b.addRunArtifact(storage_snapshot_tests);

    // Vector codec tests
    const vector_codec_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/storage/vector_codec_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    vector_codec_test_module.addImport("storage.zig", storage_module);
    const vector_codec_tests = b.addTest(.{ .root_module = vector_codec_test_module });
    const run_vector_codec_tests = b.addRunArtifact(vector_codec_tests);

    // JSON path tests
    const json_path_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/storage/json_path_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    json_path_test_module.addImport("storage.zig", storage_module);
    const json_path_tests = b.addTest(.{ .root_module = json_path_test_module });
    const run_json_path_tests = b.addRunArtifact(json_path_tests);

    // JSON index tests
    const json_index_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/storage/json_index_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    json_index_test_module.addImport("storage.zig", storage_module);
    const json_index_tests = b.addTest(.{ .root_module = json_index_test_module });
    const run_json_index_tests = b.addRunArtifact(json_index_tests);

    // HNSW tests
    const hnsw_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/storage/hnsw_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    hnsw_test_module.addImport("storage.zig", storage_module);
    const hnsw_tests = b.addTest(.{ .root_module = hnsw_test_module });
    const run_hnsw_tests = b.addRunArtifact(hnsw_tests);

    // Storage replay (DST) tests
    const storage_replay_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/storage/replay_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    storage_replay_test_module.addImport("storage.zig", storage_module);
    const storage_replay_tests = b.addTest(.{ .root_module = storage_replay_test_module });
    const run_storage_replay_tests = b.addRunArtifact(storage_replay_tests);

    // CDC module
    const cdc_module = b.createModule(.{
        .root_source_file = b.path("src/cdc/cdc.zig"),
        .target = target,
        .optimize = optimize,
    });
    cdc_module.addImport("storage.zig", storage_module);
    cdc_module.addImport("log.zig", log_module);
    cdc_module.addImport("observability.zig", observability_module);

    // Executor module
    const executor_module = b.createModule(.{
        .root_source_file = b.path("src/executor/executor.zig"),
        .target = target,
        .optimize = optimize,
    });
    executor_module.addImport("storage.zig", storage_module);
    executor_module.addImport("log.zig", log_module);
    executor_module.addImport("cdc.zig", cdc_module);
    executor_module.addImport("observability.zig", observability_module);

    // Recovery module
    const recovery_module = b.createModule(.{
        .root_source_file = b.path("src/storage/recovery.zig"),
        .target = target,
        .optimize = optimize,
    });
    recovery_module.addImport("storage.zig", storage_module);
    recovery_module.addImport("executor.zig", executor_module);
    recovery_module.addImport("log.zig", log_module);

    // Recovery tests
    const recovery_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/storage/recovery_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    recovery_test_module.addImport("recovery.zig", recovery_module);
    recovery_test_module.addImport("storage.zig", storage_module);
    recovery_test_module.addImport("executor.zig", executor_module);
    recovery_test_module.addImport("log.zig", log_module);
    const recovery_tests = b.addTest(.{ .root_module = recovery_test_module });
    const run_recovery_tests = b.addRunArtifact(recovery_tests);

    // PartitionSet module (separate from executor to avoid circular imports)
    const partition_set_module = b.createModule(.{
        .root_source_file = b.path("src/executor/partition_set.zig"),
        .target = target,
        .optimize = optimize,
    });
    partition_set_module.addImport("executor.zig", executor_module);

    // Cross-partition tests (M8)
    const cross_partition_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/executor/cross_partition_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    cross_partition_test_module.addImport("executor.zig", executor_module);
    cross_partition_test_module.addImport("partition_set.zig", partition_set_module);
    cross_partition_test_module.addImport("storage.zig", storage_module);
    cross_partition_test_module.addImport("log.zig", log_module);
    const cross_partition_tests = b.addTest(.{ .root_module = cross_partition_test_module });
    const run_cross_partition_tests = b.addRunArtifact(cross_partition_tests);

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

    // ExecutorDriver tests
    const driver_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/executor/driver_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    driver_test_module.addImport("executor.zig", executor_module);
    driver_test_module.addImport("storage.zig", storage_module);
    driver_test_module.addImport("log.zig", log_module);
    const driver_tests = b.addTest(.{ .root_module = driver_test_module });
    const run_driver_tests = b.addRunArtifact(driver_tests);

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
    sql_module.addImport("cdc.zig", cdc_module);

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

    // SQL FK enforcement tests
    const sql_fk_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sql/fk_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sql_fk_test_module.addImport("sql.zig", sql_module);
    sql_fk_test_module.addImport("executor.zig", executor_module);
    sql_fk_test_module.addImport("storage.zig", storage_module);
    const sql_fk_tests = b.addTest(.{ .root_module = sql_fk_test_module });
    const run_sql_fk_tests = b.addRunArtifact(sql_fk_tests);

    // SQL planner tests
    const sql_planner_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sql/planner_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sql_planner_test_module.addImport("sql.zig", sql_module);
    const sql_planner_tests = b.addTest(.{ .root_module = sql_planner_test_module });
    const run_sql_planner_tests = b.addRunArtifact(sql_planner_tests);

    // Sequencer sub-modules
    const seq_types_module = b.createModule(.{
        .root_source_file = b.path("src/sequencer/types.zig"),
        .target = target,
        .optimize = optimize,
    });
    seq_types_module.addImport("log.zig", log_module);

    const seq_idempotency_module = b.createModule(.{
        .root_source_file = b.path("src/sequencer/idempotency.zig"),
        .target = target,
        .optimize = optimize,
    });
    seq_idempotency_module.addImport("types.zig", seq_types_module);

    const seq_epoch_module = b.createModule(.{
        .root_source_file = b.path("src/sequencer/epoch.zig"),
        .target = target,
        .optimize = optimize,
    });
    seq_epoch_module.addImport("types.zig", seq_types_module);

    // Sequencer main module
    const sequencer_module = b.createModule(.{
        .root_source_file = b.path("src/sequencer/sequencer.zig"),
        .target = target,
        .optimize = optimize,
    });
    sequencer_module.addImport("log.zig", log_module);
    sequencer_module.addImport("raft.zig", raft_module);
    sequencer_module.addImport("types.zig", seq_types_module);
    sequencer_module.addImport("idempotency.zig", seq_idempotency_module);
    sequencer_module.addImport("epoch.zig", seq_epoch_module);
    sequencer_module.addImport("observability.zig", observability_module);

    // Wire sequencer into lib.zig now that it exists
    lib_module.addImport("sequencer.zig", sequencer_module);

    // Errors module (centralized human-readable error messages)
    const errors_module = b.createModule(.{
        .root_source_file = b.path("src/errors.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Errors tests
    const errors_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/errors_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    errors_test_module.addImport("errors.zig", errors_module);
    const errors_tests = b.addTest(.{ .root_module = errors_test_module });
    const run_errors_tests = b.addRunArtifact(errors_tests);

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
    gateway_module.addImport("sequencer.zig", sequencer_module);
    gateway_module.addImport("registry.zig", sql_module);
    gateway_module.addImport("executor_bridge.zig", sql_module);
    gateway_module.addImport("observability.zig", observability_module);
    gateway_module.addImport("schema.zig", sql_module);
    gateway_module.addImport("parser.zig", sql_module);
    gateway_module.addImport("ast.zig", sql_module);
    gateway_module.addImport("types.zig", executor_module);
    gateway_module.addImport("cdc.zig", cdc_module);
    gateway_module.addImport("errors.zig", errors_module);

    // Sim determinism property test
    const sim_determinism_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sim/determinism_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sim_determinism_test_module.addImport("sim.zig", sim_module);
    sim_determinism_test_module.addImport("gateway.zig", gateway_module);
    sim_determinism_test_module.addImport("storage.zig", storage_module);
    sim_determinism_test_module.addImport("sequencer.zig", sequencer_module);
    const sim_determinism_tests = b.addTest(.{ .root_module = sim_determinism_test_module });
    const run_sim_determinism_tests = b.addRunArtifact(sim_determinism_tests);

    // Sim recovery property test
    const sim_recovery_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sim/recovery_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sim_recovery_test_module.addImport("sim.zig", sim_module);
    sim_recovery_test_module.addImport("gateway.zig", gateway_module);
    sim_recovery_test_module.addImport("storage.zig", storage_module);
    sim_recovery_test_module.addImport("sequencer.zig", sequencer_module);
    const sim_recovery_tests = b.addTest(.{ .root_module = sim_recovery_test_module });
    const run_sim_recovery_tests = b.addRunArtifact(sim_recovery_tests);

    // Sim disk fault recovery test
    const sim_disk_fault_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sim/disk_fault_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sim_disk_fault_test_module.addImport("sim.zig", sim_module);
    sim_disk_fault_test_module.addImport("gateway.zig", gateway_module);
    sim_disk_fault_test_module.addImport("storage.zig", storage_module);
    sim_disk_fault_test_module.addImport("sequencer.zig", sequencer_module);
    const sim_disk_fault_tests = b.addTest(.{ .root_module = sim_disk_fault_test_module });
    const run_sim_disk_fault_tests = b.addRunArtifact(sim_disk_fault_tests);

    // Net sub-modules (wire protocol layer)
    const net_frame_module = b.createModule(.{
        .root_source_file = b.path("src/net/frame.zig"),
        .target = target,
        .optimize = optimize,
    });

    const net_codec_module = b.createModule(.{
        .root_source_file = b.path("src/net/codec.zig"),
        .target = target,
        .optimize = optimize,
    });

    const net_messages_module = b.createModule(.{
        .root_source_file = b.path("src/net/messages.zig"),
        .target = target,
        .optimize = optimize,
    });
    net_messages_module.addImport("frame.zig", net_frame_module);
    net_messages_module.addImport("codec.zig", net_codec_module);

    const net_conn_module = b.createModule(.{
        .root_source_file = b.path("src/net/conn.zig"),
        .target = target,
        .optimize = optimize,
    });
    net_conn_module.addImport("frame.zig", net_frame_module);
    net_conn_module.addImport("codec.zig", net_codec_module);
    net_conn_module.addImport("messages.zig", net_messages_module);
    net_conn_module.addImport("gateway.zig", gateway_module);
    net_conn_module.addImport("errors.zig", errors_module);

    const net_server_module = b.createModule(.{
        .root_source_file = b.path("src/net/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    net_server_module.addImport("frame.zig", net_frame_module);
    net_server_module.addImport("conn.zig", net_conn_module);
    net_server_module.addImport("gateway.zig", gateway_module);

    // Wire gateway + server into the main binary
    main_module.addImport("gateway.zig", gateway_module);
    main_module.addImport("server.zig", net_server_module);

    // Client library
    const client_module = b.createModule(.{
        .root_source_file = b.path("src/client/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_module.addImport("frame.zig", net_frame_module);
    client_module.addImport("codec.zig", net_codec_module);
    client_module.addImport("messages.zig", net_messages_module);

    // REPL binary
    const repl_module = b.createModule(.{
        .root_source_file = b.path("src/cmd/repl.zig"),
        .target = target,
        .optimize = optimize,
    });
    repl_module.addImport("client.zig", client_module);
    repl_module.addImport("messages.zig", net_messages_module);

    const repl_exe = b.addExecutable(.{
        .name = "foldb-repl",
        .root_module = repl_module,
    });
    b.installArtifact(repl_exe);

    const run_repl = b.addRunArtifact(repl_exe);
    if (b.args) |bargs| run_repl.addArgs(bargs);
    const repl_step = b.step("repl", "Run the interactive SQL REPL");
    repl_step.dependOn(&run_repl.step);

    const net_module = b.createModule(.{
        .root_source_file = b.path("src/net/net.zig"),
        .target = target,
        .optimize = optimize,
    });
    net_module.addImport("frame.zig", net_frame_module);
    net_module.addImport("codec.zig", net_codec_module);
    net_module.addImport("messages.zig", net_messages_module);
    net_module.addImport("conn.zig", net_conn_module);
    net_module.addImport("server.zig", net_server_module);

    // Net frame tests
    const net_frame_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/net/frame_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    net_frame_test_module.addImport("frame.zig", net_frame_module);
    const net_frame_tests = b.addTest(.{ .root_module = net_frame_test_module });
    const run_net_frame_tests = b.addRunArtifact(net_frame_tests);

    // Net codec tests
    const net_codec_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/net/codec_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    net_codec_test_module.addImport("codec.zig", net_codec_module);
    const net_codec_tests = b.addTest(.{ .root_module = net_codec_test_module });
    const run_net_codec_tests = b.addRunArtifact(net_codec_tests);

    // Sequencer epoch tests
    const seq_epoch_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sequencer/epoch_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    seq_epoch_test_module.addImport("sequencer.zig", sequencer_module);
    seq_epoch_test_module.addImport("log.zig", log_module);
    seq_epoch_test_module.addImport("raft.zig", raft_module);
    seq_epoch_test_module.addImport("types.zig", seq_types_module);
    seq_epoch_test_module.addImport("idempotency.zig", seq_idempotency_module);
    seq_epoch_test_module.addImport("epoch.zig", seq_epoch_module);
    const seq_epoch_tests = b.addTest(.{ .root_module = seq_epoch_test_module });
    const run_seq_epoch_tests = b.addRunArtifact(seq_epoch_tests);

    // Sequencer idempotency tests
    const seq_idem_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sequencer/idempotency_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    seq_idem_test_module.addImport("sequencer.zig", sequencer_module);
    seq_idem_test_module.addImport("log.zig", log_module);
    seq_idem_test_module.addImport("raft.zig", raft_module);
    seq_idem_test_module.addImport("types.zig", seq_types_module);
    seq_idem_test_module.addImport("idempotency.zig", seq_idempotency_module);
    seq_idem_test_module.addImport("epoch.zig", seq_epoch_module);
    const seq_idem_tests = b.addTest(.{ .root_module = seq_idem_test_module });
    const run_seq_idem_tests = b.addRunArtifact(seq_idem_tests);

    // Sequencer integration tests
    const seq_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sequencer/sequencer_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    seq_test_module.addImport("sequencer.zig", sequencer_module);
    seq_test_module.addImport("log.zig", log_module);
    seq_test_module.addImport("raft.zig", raft_module);
    seq_test_module.addImport("types.zig", seq_types_module);
    seq_test_module.addImport("idempotency.zig", seq_idempotency_module);
    seq_test_module.addImport("epoch.zig", seq_epoch_module);
    const seq_tests = b.addTest(.{ .root_module = seq_test_module });
    const run_seq_tests = b.addRunArtifact(seq_tests);

    // CDC unit tests
    const cdc_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/cdc/cdc_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    cdc_test_module.addImport("cdc.zig", cdc_module);
    cdc_test_module.addImport("storage.zig", storage_module);
    cdc_test_module.addImport("executor.zig", executor_module);
    cdc_test_module.addImport("partition_set.zig", partition_set_module);
    cdc_test_module.addImport("log.zig", log_module);
    const cdc_tests = b.addTest(.{ .root_module = cdc_test_module });
    const run_cdc_tests = b.addRunArtifact(cdc_tests);

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
    gateway_test_module.addImport("sequencer.zig", sequencer_module);
    const gateway_tests = b.addTest(.{ .root_module = gateway_test_module });
    const run_gateway_tests = b.addRunArtifact(gateway_tests);

    // Gateway replay (DST)
    const gateway_replay_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/gateway/replay_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    gateway_replay_test_module.addImport("gateway.zig", gateway_module);
    gateway_replay_test_module.addImport("storage.zig", storage_module);
    gateway_replay_test_module.addImport("sequencer.zig", sequencer_module);
    const gateway_replay_tests = b.addTest(.{ .root_module = gateway_replay_test_module });
    const run_gateway_replay_tests = b.addRunArtifact(gateway_replay_tests);

    // Unit tests: pure logic, no simulation harness
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_sim_clock_tests.step);
    test_step.dependOn(&run_sim_scheduler_tests.step);
    test_step.dependOn(&run_sim_network_tests.step);
    test_step.dependOn(&run_obs_tests.step);
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
    test_step.dependOn(&run_storage_tiered_tests.step);
    test_step.dependOn(&run_storage_snapshot_tests.step);
    test_step.dependOn(&run_vector_codec_tests.step);
    test_step.dependOn(&run_json_path_tests.step);
    test_step.dependOn(&run_json_index_tests.step);
    test_step.dependOn(&run_hnsw_tests.step);
    test_step.dependOn(&run_executor_tests.step);
    test_step.dependOn(&run_driver_tests.step);
    test_step.dependOn(&run_recovery_tests.step);
    test_step.dependOn(&run_cross_partition_tests.step);
    test_step.dependOn(&run_sql_lexer_tests.step);
    test_step.dependOn(&run_sql_parser_tests.step);
    test_step.dependOn(&run_sql_registry_tests.step);
    test_step.dependOn(&run_sql_integration_tests.step);
    test_step.dependOn(&run_sql_tc_tests.step);
    test_step.dependOn(&run_sql_schema_tests.step);
    test_step.dependOn(&run_sql_planner_tests.step);
    test_step.dependOn(&run_sql_executor_expr_tests.step);
    test_step.dependOn(&run_sql_fk_tests.step);
    test_step.dependOn(&run_cdc_tests.step);
    test_step.dependOn(&run_gateway_tests.step);
    test_step.dependOn(&run_seq_epoch_tests.step);
    test_step.dependOn(&run_seq_idem_tests.step);
    test_step.dependOn(&run_seq_tests.step);
    test_step.dependOn(&run_net_frame_tests.step);
    test_step.dependOn(&run_net_codec_tests.step);
    test_step.dependOn(&run_errors_tests.step);

    // Raft consensus seed sweep executable
    const dst_sweep_module = b.createModule(.{
        .root_source_file = b.path("src/cmd/dst_sweep.zig"),
        .target = target,
        .optimize = optimize,
    });
    dst_sweep_module.addImport("raft.zig", raft_module);

    const dst_sweep_exe = b.addExecutable(.{
        .name = "raft-sweep",
        .root_module = dst_sweep_module,
    });
    b.installArtifact(dst_sweep_exe);

    const run_dst_sweep = b.addRunArtifact(dst_sweep_exe);
    if (b.args) |bargs| run_dst_sweep.addArgs(bargs);

    const dst_sweep_step = b.step("raft-sweep", "Run Raft consensus seed sweep (pass -- --seeds N)");
    dst_sweep_step.dependOn(&run_dst_sweep.step);

    // Deterministic simulation tests
    const dst_step = b.step("dst-test", "Run deterministic simulation tests");
    dst_step.dependOn(&run_raft_cluster_tests.step);
    dst_step.dependOn(&run_raft_linear_tests.step);
    dst_step.dependOn(&run_storage_replay_tests.step);
    dst_step.dependOn(&run_executor_replay_tests.step);
    dst_step.dependOn(&run_sql_replay_tests.step);
    dst_step.dependOn(&run_log_replay_tests.step);
    dst_step.dependOn(&run_gateway_replay_tests.step);
    dst_step.dependOn(&run_cross_partition_tests.step);
    dst_step.dependOn(&run_sim_determinism_tests.step);
    dst_step.dependOn(&run_sim_recovery_tests.step);
    dst_step.dependOn(&run_sim_disk_fault_tests.step);
}
