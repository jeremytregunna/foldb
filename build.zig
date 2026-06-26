const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options.
    const optimize = b.standardOptimizeOption(.{});

    // DST seed count — override with -Ddst-seeds=N (e.g. zig build dst-test -Ddst-seeds=10000)
    const dst_seeds = b.option(usize, "dst-seeds", "Number of seeds for DST sweep tests (default: 200)") orelse 200;
    const dst_seeds_options = b.addOptions();
    dst_seeds_options.addOption(usize, "dst_seeds", dst_seeds);

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

    // Log mux tests
    const log_mux_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/log/mux_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    log_mux_test_module.addImport("log.zig", log_module);
    const log_mux_tests = b.addTest(.{ .root_module = log_mux_test_module });
    const run_log_mux_tests = b.addRunArtifact(log_mux_tests);

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

    // Raft TCP transport tests
    const raft_transport_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/raft/transport_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_transport_test_module.addImport("raft.zig", raft_module);
    const raft_transport_tests = b.addTest(.{ .root_module = raft_transport_test_module });
    const run_raft_transport_tests = b.addRunArtifact(raft_transport_tests);

    // Raft TCP transport DST tests
    const raft_tcp_dst_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/raft/tcp_dst_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_tcp_dst_test_module.addImport("raft.zig", raft_module);
    const raft_tcp_dst_tests = b.addTest(.{ .root_module = raft_tcp_dst_test_module });
    const run_raft_tcp_dst_tests = b.addRunArtifact(raft_tcp_dst_tests);

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

    // Raft consensus seed sweep DST
    const raft_sweep_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/raft/raft_sweep_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_sweep_test_module.addImport("raft.zig", raft_module);
    raft_sweep_test_module.addOptions("options", dst_seeds_options);
    const raft_sweep_tests = b.addTest(.{ .root_module = raft_sweep_test_module });
    const run_raft_sweep_tests = b.addRunArtifact(raft_sweep_tests);

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

    // Storage S3 tests (inline tests in s3.zig)
    const storage_s3_test_module = b.createModule(.{
        .root_source_file = b.path("src/storage/s3.zig"),
        .target = target,
        .optimize = optimize,
    });
    const storage_s3_tests = b.addTest(.{ .root_module = storage_s3_test_module });
    const run_storage_s3_tests = b.addRunArtifact(storage_s3_tests);

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

    // CDC module
    const cdc_module = b.createModule(.{
        .root_source_file = b.path("src/cdc/cdc.zig"),
        .target = target,
        .optimize = optimize,
    });
    cdc_module.addImport("storage.zig", storage_module);
    cdc_module.addImport("log.zig", log_module);
    cdc_module.addImport("observability.zig", observability_module);

    // Deterministic std shim — approved import surface for execution-path modules (spec §7.4).

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

    // Sequencer sub-modules
    const seq_mpsc_module = b.createModule(.{
        .root_source_file = b.path("src/sequencer/mpsc_queue.zig"),
        .target = target,
        .optimize = optimize,
    });

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
    sequencer_module.addImport("mpsc_queue.zig", seq_mpsc_module);

    // Wire sequencer into lib.zig now that it exists
    lib_module.addImport("sequencer.zig", sequencer_module);

    // Config module
    const config_module = b.createModule(.{
        .root_source_file = b.path("src/config/config.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Config tests
    const config_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/config/config_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    config_test_module.addImport("config.zig", config_module);
    const config_tests = b.addTest(.{ .root_module = config_test_module });
    const run_config_tests = b.addRunArtifact(config_tests);

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

    // Net payload modules used by both gateway and client/server code.
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

    // Gateway module
    const gateway_module = b.createModule(.{
        .root_source_file = b.path("src/gateway/gateway.zig"),
        .target = target,
        .optimize = optimize,
    });
    gateway_module.addImport("storage.zig", storage_module);
    gateway_module.addImport("executor.zig", executor_module);
    gateway_module.addImport("log.zig", log_module);
    gateway_module.addImport("sequencer.zig", sequencer_module);
    gateway_module.addImport("observability.zig", observability_module);
    gateway_module.addImport("types.zig", executor_module);
    gateway_module.addImport("cdc.zig", cdc_module);
    gateway_module.addImport("errors.zig", errors_module);
    gateway_module.addImport("config.zig", config_module);
    gateway_module.addImport("codec.zig", net_codec_module);
    gateway_module.addImport("frame.zig", net_frame_module);
    gateway_module.addImport("messages.zig", net_messages_module);

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
    net_conn_module.addImport("config.zig", config_module);

    const net_server_module = b.createModule(.{
        .root_source_file = b.path("src/net/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    net_server_module.addImport("frame.zig", net_frame_module);
    net_server_module.addImport("conn.zig", net_conn_module);
    net_server_module.addImport("gateway.zig", gateway_module);
    net_server_module.addImport("config.zig", config_module);

    // Wire gateway + server into the main binary
    main_module.addImport("gateway.zig", gateway_module);
    main_module.addImport("server.zig", net_server_module);
    main_module.addImport("config.zig", config_module);
    main_module.addImport("sequencer.zig", sequencer_module);

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
    const repl_step = b.step("repl", "Run the interactive KV REPL");
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

    // Sequencer TCP cluster tests
    const seq_tcp_cluster_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sequencer/tcp_cluster_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    seq_tcp_cluster_test_module.addImport("sequencer.zig", sequencer_module);
    const seq_tcp_cluster_tests = b.addTest(.{ .root_module = seq_tcp_cluster_test_module });
    const run_seq_tcp_cluster_tests = b.addRunArtifact(seq_tcp_cluster_tests);

    // Sequencer actor (multi-node via start/submitBytes) tests
    const seq_tcp_actor_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sequencer/tcp_actor_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    seq_tcp_actor_test_module.addImport("sequencer.zig", sequencer_module);
    const seq_tcp_actor_tests = b.addTest(.{ .root_module = seq_tcp_actor_test_module });
    const run_seq_tcp_actor_tests = b.addRunArtifact(seq_tcp_actor_tests);

    // Sequencer reconfiguration tests
    const seq_reconfig_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sequencer/reconfig_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    seq_reconfig_test_module.addImport("sequencer.zig", sequencer_module);
    const seq_reconfig_tests = b.addTest(.{ .root_module = seq_reconfig_test_module });
    const run_seq_reconfig_tests = b.addRunArtifact(seq_reconfig_tests);

    // Sequencer follower submission tests (Fix 2: commitInner error return)
    const seq_follower_submit_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sequencer/follower_submit_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    seq_follower_submit_test_module.addImport("sequencer.zig", sequencer_module);
    const seq_follower_submit_tests = b.addTest(.{ .root_module = seq_follower_submit_test_module });
    const run_seq_follower_submit_tests = b.addRunArtifact(seq_follower_submit_tests);

    // Sequencer seq monotonicity DST (Fix 2: counter ordering)
    const seq_mono_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/sequencer/seq_monotonicity_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    seq_mono_test_module.addImport("sequencer.zig", sequencer_module);
    const seq_mono_tests = b.addTest(.{ .root_module = seq_mono_test_module });
    const run_seq_mono_tests = b.addRunArtifact(seq_mono_tests);

    // CDC concurrent tests
    const cdc_concurrent_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests/cdc/cdc_concurrent_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    cdc_concurrent_test_module.addImport("cdc.zig", cdc_module);
    cdc_concurrent_test_module.addImport("storage.zig", storage_module);
    cdc_concurrent_test_module.addImport("log.zig", log_module);
    const cdc_concurrent_tests = b.addTest(.{ .root_module = cdc_concurrent_test_module });
    const run_cdc_concurrent_tests = b.addRunArtifact(cdc_concurrent_tests);

    // Unit tests: pure logic, no simulation harness
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_obs_tests.step);
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_log_segment_tests.step);
    test_step.dependOn(&run_log_mux_tests.step);
    test_step.dependOn(&run_raft_rpc_tests.step);
    test_step.dependOn(&run_raft_node_tests.step);
    test_step.dependOn(&run_raft_transport_tests.step);
    test_step.dependOn(&run_storage_codec_tests.step);
    test_step.dependOn(&run_storage_block_tests.step);
    test_step.dependOn(&run_storage_sstable_tests.step);
    test_step.dependOn(&run_storage_lsm_tests.step);
    test_step.dependOn(&run_storage_s3_tests.step);
    test_step.dependOn(&run_storage_tiered_tests.step);
    test_step.dependOn(&run_storage_snapshot_tests.step);
    test_step.dependOn(&run_cdc_concurrent_tests.step);
    test_step.dependOn(&run_seq_epoch_tests.step);
    test_step.dependOn(&run_seq_idem_tests.step);
    test_step.dependOn(&run_seq_tests.step);
    test_step.dependOn(&run_net_frame_tests.step);
    test_step.dependOn(&run_net_codec_tests.step);
    test_step.dependOn(&run_errors_tests.step);
    test_step.dependOn(&run_config_tests.step);
    test_step.dependOn(&run_raft_tcp_dst_tests.step);
    test_step.dependOn(&run_seq_tcp_cluster_tests.step);
    test_step.dependOn(&run_seq_tcp_actor_tests.step);
    test_step.dependOn(&run_seq_reconfig_tests.step);
    test_step.dependOn(&run_seq_follower_submit_tests.step);

    // Deterministic simulation tests
    const dst_step = b.step("dst-test", "Run deterministic simulation tests");
    dst_step.dependOn(&run_raft_cluster_tests.step);
    dst_step.dependOn(&run_raft_linear_tests.step);
    dst_step.dependOn(&run_log_replay_tests.step);
    dst_step.dependOn(&run_raft_tcp_dst_tests.step);
    dst_step.dependOn(&run_raft_sweep_tests.step);
    dst_step.dependOn(&run_seq_mono_tests.step);
}
