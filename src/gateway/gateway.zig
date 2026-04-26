/// Foldb Gateway: client-facing entry point for query registration, execution, and CDC.
const std = @import("std");

const sql_mod = @import("sql.zig");
const storage_mod = @import("storage.zig");
const executor_mod = @import("executor.zig");
const fold_executor_mod = @import("fold_executor.zig");
const sequencer_mod = @import("sequencer.zig");
const observability_mod = @import("observability.zig");
const cdc_mod = @import("cdc.zig");
const nondet_mod = @import("nondet.zig");
const recon_mod = @import("recon.zig");
const snapshot_hooks_mod = @import("snapshot_hooks.zig");

pub const QueryHash = sql_mod.QueryHash;
pub const Seq = @import("types.zig").Seq;
pub const ResolvedValue = fold_executor_mod.ResolvedValue;

// Re-export CDC types for use by the net layer
pub const CdcSubscription = cdc_mod.CdcSubscription;
pub const CdcEvent = cdc_mod.CdcEvent;
pub const ResolvedKind = @import("types.zig").ResolvedKind;
pub const ColumnValue = storage_mod.ColumnValue;
pub const ResultSet = sql_mod.ResultSet;

/// Result from query registration.
pub const RegisterResult = struct {
    hash: QueryHash,
    schema_version: u64,
};

/// Result from query execution.
pub const ExecResult = struct {
    rows_affected: u64,
    result_set: ?ResultSet,
};

/// Gateway error types.
pub const GatewayError = error{
    QueryNotFound,
    ParamDecodeError,
    SchemaBreakingChange,
    ExecutionError,
    TableNotFound,
    ConstraintViolation,
};

pub const ReconStrategy = recon_mod.ReconStrategy;
pub const ClockSource = nondet_mod.ClockSource;
pub const RandSource = nondet_mod.RandSource;
pub const NondetResolver = nondet_mod.NondetResolver;

/// Context for the post-snapshot truncation hook. Stable once set in init.
const TruncateCtx = struct { gateway: *Gateway };

fn onSnapshotComplete(ptr: *anyopaque, snapshot_seq: sequencer_mod.Seq) void {
    const ctx: *TruncateCtx = @ptrCast(@alignCast(ptr));
    const gw = ctx.gateway;
    if (snapshot_seq > gw.durable_snapshot_seq) gw.durable_snapshot_seq = snapshot_seq;
    gw.truncateLog() catch |err| std.log.warn("truncateLog failed after snapshot: {}", .{err});
}

/// The main Gateway struct.
/// Always heap-allocated via `init`; internal pointers remain stable.
pub const Gateway = struct {
    /// One FoldExecutor per partition; each runs on its own thread pinned to a CPU.
    fold_executors: []*fold_executor_mod.FoldExecutor,
    /// One Storage per data partition. Heap-allocated; owned by this gateway.
    storages: []*storage_mod.Storage,
    /// Routing wrapper over storages — used by fold_executor and reconnaissance.
    partitioned: storage_mod.PartitionedStorage,
    nondet_resolver: nondet_mod.NondetResolver,
    sequencer: sequencer_mod.Sequencer,
    /// CDC event fan-out for wire-protocol subscriptions.
    cdc: cdc_mod.CdcManager,
    /// Per-gateway client identity for idempotency tracking.
    client_id: u64,
    client_seq: u64,
    /// Number of data partitions — used to hash PK keys to partition IDs during reconnaissance.
    partition_count: u32,
    recon_strategy: ReconStrategy,
    alloc: std.mem.Allocator,
    metrics: observability_mod.GatewayMetrics = .{},
    /// I/O context for async awaitCommit on the fiber scheduler. Null in tests.
    io: ?std.Io = null,
    /// Heap-allocated S3 store; non-null when S3 is configured. Freed in deinit.
    s3_store: ?*storage_mod.S3ObjectStore = null,
    /// Per-partition context structs for snapshot log writers. Freed in deinit.
    snapshot_writer_ctxs: []snapshot_hooks_mod.SnapshotWriterCtx = &.{},
    /// Highest seq for which a snapshot has been durably uploaded. Updated by postSnapshotImpl.
    durable_snapshot_seq: sequencer_mod.Seq = 0,
    /// Stable context for the post-snapshot truncation hook. Initialized in init.
    truncate_ctx: TruncateCtx,
    /// Last error detail set by gateway operations (table/column context).
    /// Reset at the start of each operation that may set it.
    error_detail: [256]u8,
    error_detail_len: usize = 0,

    pub const Options = struct {
        clock: ClockSource = .{},
        rand: RandSource = .{},
        disk_fault: ?storage_mod.DiskFaultHook = null,
        partition_count: u32 = 1,
        recon_strategy: ReconStrategy = .early_exit,
        node_id: u64 = 1,
        tick_interval_ms: u32 = 10,
        election_timeout_min_ms: u32 = 150,
        election_timeout_max_ms: u32 = 300,
        heartbeat_interval_ms: u32 = 50,
        peers: []const sequencer_mod.PeerAddr = &.{},
        /// I/O context for the fiber scheduler. When set, awaitCommit suspends
        /// the fiber during Raft round-trips instead of busy-spinning.
        io: ?std.Io = null,
        // S3 / object storage (all optional — zero values disable tiering).
        /// Required when S3 credentials are provided; used for hostname resolution and connection.
        s3_io: ?std.Io = null,
        s3_endpoint_host: []const u8 = "",
        s3_endpoint_port: u16 = 0,
        s3_access_key: []const u8 = "",
        s3_secret_key: []const u8 = "",
        s3_region: []const u8 = "us-east-1",
        s3_bucket: []const u8 = "",
        s3_bucket_style: storage_mod.BucketStyle = .path,
        /// Local directory for caching downloaded L3 SSTables. Defaults to storage_dir.
        s3_cache_dir: []const u8 = "",
        /// How many applied mutations between automatic snapshots. 0 disables scheduling.
        snapshot_interval_entries: u64 = 10_000_000,
        /// Optional object store for snapshot uploads (bypasses S3; useful in tests).
        snapshot_store: ?storage_mod.ObjectStore = null,
        /// When true, the caller is responsible for calling gw.sequencer.start()
        /// after configuring peer addresses. Used in multinode test setup.
        defer_sequencer_start: bool = false,
    };

    /// Initialize and heap-allocate a Gateway. Caller owns the pointer; call `deinit` to free.
    pub fn init(
        storage_dir: []const u8,
        alloc: std.mem.Allocator,
        opts: Options,
    ) !*Gateway {
        const gw = try alloc.create(Gateway);
        errdefer alloc.destroy(gw);

        gw.alloc = alloc;

        // Ensure the top-level storage directory exists before creating partition subdirs.
        storage_mod.mkdirAll(storage_dir);

        // Allocate one Storage per partition. Each lives at {storage_dir}/p{i}.
        // Storage does not own its dir string; each dir is freed in deinit via s.dir.
        const pc = opts.partition_count;
        std.debug.assert(pc >= 1);
        std.debug.assert(pc <= 64); // PartitionSet bitmask is u64.
        const storages = try alloc.alloc(*storage_mod.Storage, pc);
        errdefer alloc.free(storages);
        var n_inited: usize = 0;
        errdefer for (storages[0..n_inited]) |s| {
            const dir = s.dir;
            s.flushAll() catch |err| std.log.warn("flushAll failed during init cleanup: {}", .{err});
            s.deinit();
            alloc.destroy(s);
            alloc.free(dir);
        };
        for (0..pc) |i| {
            const dir = try std.fmt.allocPrint(alloc, "{s}/p{d}", .{ storage_dir, i });
            // dir is NOT freed here — Storage holds a reference; freed in deinit via s.dir.
            const s = alloc.create(storage_mod.Storage) catch |e| {
                alloc.free(dir);
                return e;
            };
            s.* = storage_mod.Storage.init(dir, alloc) catch |e| {
                alloc.destroy(s);
                alloc.free(dir);
                return e;
            };
            if (opts.disk_fault) |hook| s.fault_hook = hook;
            storages[i] = s;
            n_inited += 1;
        }
        gw.storages = storages;
        gw.partitioned = .{ .partitions = storages, .alloc = alloc };
        gw.s3_store = null;
        gw.snapshot_writer_ctxs = &.{};
        gw.durable_snapshot_seq = 0;
        gw.truncate_ctx = .{ .gateway = gw };
        gw.error_detail = undefined;
        gw.error_detail_len = 0;

        // Wire S3 tiered storage when credentials are provided.
        if (opts.s3_access_key.len > 0) {
            if (opts.s3_bucket.len > 0) {
                if (opts.s3_io) |s3_io| {
                    const s3 = try alloc.create(storage_mod.S3ObjectStore);
                    errdefer alloc.destroy(s3);
                    s3.* = storage_mod.S3ObjectStore.init(.{
                        .access_key = opts.s3_access_key,
                        .secret_key = opts.s3_secret_key,
                        .region = opts.s3_region,
                        .endpoint_host = opts.s3_endpoint_host,
                        .endpoint_port = opts.s3_endpoint_port,
                        .io = s3_io,
                        .bucket = opts.s3_bucket,
                        .bucket_style = opts.s3_bucket_style,
                        .alloc = alloc,
                    });
                    gw.s3_store = s3;
                    const cache_dir = if (opts.s3_cache_dir.len > 0) opts.s3_cache_dir else storage_dir;
                    const obj = s3.objectStore();
                    for (storages) |stor| try stor.setObjectStore(obj, cache_dir);
                } else {
                    return error.IoRequiredForS3;
                }
            }
        }

        gw.io = opts.io;
        gw.nondet_resolver = nondet_mod.NondetResolver.init(opts.clock, opts.rand);

        const seq_cfg = sequencer_mod.Config{
            .partition_count = opts.partition_count,
            .node_id = opts.node_id,
            .tick_interval_ms = opts.tick_interval_ms,
            .election_timeout_min_ms = opts.election_timeout_min_ms,
            .election_timeout_max_ms = opts.election_timeout_max_ms,
            .heartbeat_interval_ms = opts.heartbeat_interval_ms,
            .peers = opts.peers,
        };
        gw.sequencer = try sequencer_mod.Sequencer.init(storage_dir, seq_cfg, alloc);
        errdefer gw.sequencer.deinit();
        if (!opts.defer_sequencer_start) try gw.sequencer.start();

        gw.cdc = try cdc_mod.CdcManager.init(alloc);

        // Create one FoldExecutor per partition, each pinned to a CPU (round-robin if CPUs < partitions).
        const cpu_count: u32 = @intCast(std.Thread.getCpuCount() catch 1);
        const fold_executors = try alloc.alloc(*fold_executor_mod.FoldExecutor, pc);
        errdefer alloc.free(fold_executors);
        var n_fe_inited: usize = 0;
        errdefer for (fold_executors[0..n_fe_inited]) |fe| {
            fe.stop();
            fe.deinit();
        };
        for (0..pc) |i| {
            const cpu_id: u32 = @intCast(i % cpu_count);
            fold_executors[i] = try fold_executor_mod.FoldExecutor.init(
                &gw.partitioned,
                &gw.cdc,
                &gw.sequencer.partition_logs[i],
                @intCast(i),
                cpu_id,
                alloc,
            );
            n_fe_inited += 1;
        }
        gw.fold_executors = fold_executors;

        // Wire sibling references so each FoldExecutor can do the cross-partition wait.
        for (fold_executors) |fe| fe.setSiblings(fold_executors);

        // Wire snapshot scheduling if an object store is available and interval is set.
        const snap_obj: ?storage_mod.ObjectStore = blk: {
            if (opts.snapshot_store) |s| break :blk s;
            if (gw.s3_store) |s3| break :blk s3.objectStore();
            break :blk null;
        };
        if (snap_obj) |obj| {
            if (opts.snapshot_interval_entries > 0) {
                const ctxs = try alloc.alloc(snapshot_hooks_mod.SnapshotWriterCtx, pc);
                for (ctxs, 0..) |*ctx, i| {
                    ctx.* = .{
                        .sequencer = &gw.sequencer,
                        .partition_id = @intCast(i),
                        // XOR with a per-partition salt so snapshot client_ids don't
                        // collide with each other or with gateway.client_id.
                        .client_id = gw.client_id ^ (@as(u64, @intCast(i)) +% 0x9e3779b97f4a7c15), // Fibonacci hashing salt
                        .client_seq = 0,
                    };
                }
                gw.snapshot_writer_ctxs = ctxs;
                for (gw.storages, 0..) |stor, i| {
                    stor.setSnapshotPolicy(.{
                        .interval = opts.snapshot_interval_entries,
                        .store = obj,
                        .log_writer = .{
                            .ptr = &ctxs[i],
                            .writeFn = &snapshot_hooks_mod.writeSnapshotToLog,
                        },
                        .partition_id = @intCast(i),
                        .post_snapshot = .{
                            .ptr = &gw.truncate_ctx,
                            .hookFn = &onSnapshotComplete,
                        },
                    });
                }
            }
        }

        // Replay log to rebuild schema and storage state after restart.
        // Pass 1 reconstructs DDL/query registry; pass 2 replays DML into storage,
        // recovering rows that were in the memtable and not flushed before a crash.
        for (gw.fold_executors) |fe| try fe.replayFromLog();

        // Start FoldExecutor OS threads — each continuously applies committed entries for its partition.
        for (gw.fold_executors) |fe| try fe.start();

        // Derive a stable client_id from the storage path hash
        gw.client_id = blk: {
            var h: u64 = 0xcbf29ce484222325; // FNV-1a 64-bit offset basis
            for (storage_dir) |b| {
                h ^= b;
                h *%= 0x100000001b3; // FNV-1a 64-bit prime
            }
            break :blk h;
        };
        gw.client_seq = 0;
        gw.partition_count = opts.partition_count;
        gw.recon_strategy = opts.recon_strategy;
        return gw;
    }

    pub fn deinit(self: *Gateway) void {
        for (self.fold_executors) |fe| fe.stop();
        // Flush memtables BEFORE freeing fold_executor storage_schema_arenas.
        // Block.append() dereferences schema.columns; freeing the arena first causes a segfault.
        for (self.storages) |s| {
            const dir = s.dir;
            s.flushAll() catch |err| std.log.warn("flushAll failed during deinit: {}", .{err});
            s.deinit();
            self.alloc.destroy(s);
            self.alloc.free(dir);
        }
        self.alloc.free(self.storages);
        for (self.fold_executors) |fe| fe.deinit();
        self.alloc.free(self.fold_executors);
        self.cdc.deinit();
        self.sequencer.deinit();
        if (self.s3_store) |s3| self.alloc.destroy(s3);
        if (self.snapshot_writer_ctxs.len > 0) self.alloc.free(self.snapshot_writer_ctxs);
        self.alloc.destroy(self);
    }

    /// Truncate sealed log segments that predate the durable snapshot.
    /// Safe point is min(durable_snapshot_seq, min CDC cursor across all subscribers).
    /// Errors are swallowed — truncation is best-effort and does not affect correctness.
    pub fn truncateLog(self: *Gateway) !void {
        var safe_seq = self.durable_snapshot_seq;
        if (safe_seq == 0) return;
        const min_cdc = self.cdc.min_cursor();
        if (min_cdc > 0 and min_cdc < safe_seq) safe_seq = min_cdc;
        for (self.sequencer.partition_logs) |*log| {
            log.notify_snapshot(safe_seq);
            try log.truncate_prefix(safe_seq);
        }
    }

    /// Returns true if the registered query is a pure SELECT (no mutations).
    pub fn isSelectQuery(self: *Gateway, hash: QueryHash) bool {
        return self.fold_executors[0].isSelectQuery(hash);
    }

    /// Register a SQL query and return its hash with schema version.
    /// Idempotent: registering the same SQL twice returns the same hash.
    /// Routes through Raft so all nodes replicate the schema change.
    pub fn register(self: *Gateway, sql: []const u8) !RegisterResult {
        self.error_detail_len = 0;
        // Validate SQL against the current schema before committing to Raft.
        // registerLocal does full parse+typecheck+plan — returns ColumnNotFound etc.
        // if the query references columns/tables that don't exist in the current schema.
        const hash = self.fold_executors[0].registerLocal(sql) catch |e| {
            if (e == error.UnexpectedToken or e == error.UnsupportedSyntax) {
                var arena = std.heap.ArenaAllocator.init(self.alloc);
                defer arena.deinit();
                var p = sql_mod.parser.Parser.init(sql, arena.allocator());
                _ = p.parseQuery() catch |err| std.log.debug("parse probe: {}", .{err});
                if (p.err_msg) |msg| {
                    const pos = p.err_pos;
                    if (pos < sql.len) {
                        var end = pos;
                        while (end < sql.len and end - pos < 24) : (end += 1) {
                            const c = sql[end];
                            if (c == ' ' or c == '\t' or c == '\n' or c == ';') break;
                        }
                        self.setDetail("{s} '{s}'", .{ msg, sql[pos..end] });
                    } else {
                        self.setDetail("{s}", .{msg});
                    }
                }
            }
            return e;
        };
        self.metrics.queries_registered.inc();
        self.client_seq += 1;
        // SAFETY: submitBytes writes to pending before awaitCommit is called on the returned handle.
        var pending: sequencer_mod.PendingSubmit = undefined;
        const result = try self.sequencer.submitBytes(
            &pending,
            sql,
            self.client_id,
            self.client_seq,
            .schema_change,
        ).awaitCommit(self.io);
        try self.waitAllFoldExecutors(result.seq);
        return .{
            .hash = hash,
            .schema_version = self.fold_executors[0].schemaVersion(),
        };
    }

    /// Wait for all FoldExecutors to process their entries from a broadcast batch.
    /// The sequencer returns last_seq (highest seq assigned); N entries have seqs
    /// first_seq..last_seq with sequential routing: entry i → partition i.
    fn waitAllFoldExecutors(self: *Gateway, last_seq: Seq) !void {
        const n: u32 = @intCast(self.fold_executors.len);
        const first_seq = last_seq - @as(Seq, n) + 1;
        for (self.fold_executors, 0..) |fe, p| {
            try fe.wait_for(first_seq + @as(Seq, p), self.io);
        }
    }

    /// Outcome of a single submit-and-drain attempt.
    const SubmitOutcome = union(enum) {
        done: ExecResult,
        /// Executor detected a read-set conflict; value is the seq to retry recon at.
        retry: Seq,
    };

    /// Run reconnaissance and serialize the TxnIntent bytes into buf.
    /// Hints are allocated and freed within this call.
    fn buildTxnIntent(
        self: *Gateway,
        hash: *const QueryHash,
        plan: sql_mod.plan.ExecutionPlan,
        op_seq: u64,
        recon_seq: Seq,
        params: []const ColumnValue,
        params_bytes: []const u8,
        all_nondet: []const ResolvedValue,
        buf: *std.ArrayList(u8),
    ) !void {
        var hints = try recon_mod.reconnaissanceScan(
            plan,
            &self.partitioned,
            params,
            &self.fold_executors[0].schema,
            recon_seq,
            self.partition_count,
            self.recon_strategy,
            self.alloc,
        );
        defer hints.deinit();
        try executor_mod.serialize_txn_intent(
            hash,
            self.client_id,
            op_seq,
            recon_seq,
            hints.read,
            hints.write,
            params_bytes,
            all_nondet,
            buf,
            self.alloc,
        );
    }

    /// Submit serialized intent bytes to the sequencer, wait for all FoldExecutors to apply,
    /// and aggregate results. Returns .done on success or .retry with conflict seq.
    fn submitAndDrain(self: *Gateway, intent_bytes: []const u8, op_seq: u64) !SubmitOutcome {
        // SAFETY: submitBytes writes to pending synchronously before the handle is used.
        var pending: sequencer_mod.PendingSubmit = undefined;
        const handle = self.sequencer.submitBytes(
            &pending,
            intent_bytes,
            self.client_id,
            op_seq,
            .txn_intent,
        );
        const result = try handle.awaitCommit(self.io);

        // Txn is broadcast: last_seq = result.seq, first_seq = last_seq - N + 1.
        // Each partition P gets seq first_seq + P.
        const n: u32 = @intCast(self.fold_executors.len);
        const first_seq = result.seq - @as(Seq, n) + 1;

        var total_rows: u64 = 0;
        var combined_result_set: ?ResultSet = null;

        for (self.fold_executors, 0..) |fe, p| {
            const target_seq = first_seq + @as(Seq, p);
            try fe.wait_for(target_seq, self.io);
            const exec_result = fe.waitFor(target_seq);
            const exec_detail = fe.lastExecDetail();
            if (exec_detail.len > 0) self.setDetail("{s}", .{exec_detail});

            switch (exec_result) {
                .ok => |ok| {
                    total_rows += ok.rows_affected;
                    if (ok.result_set) |rs| {
                        if (combined_result_set == null) {
                            combined_result_set = rs;
                        } else {
                            var mutable = rs;
                            mutable.deinit();
                        }
                    }
                },
                .abort => |ab| {
                    if (combined_result_set) |*rs| rs.deinit();
                    switch (ab.code) {
                        .constraint_violation => {
                            self.metrics.queries_aborted.inc();
                            return error.ConstraintViolation;
                        },
                        .missing_query => {
                            self.metrics.queries_aborted.inc();
                            return error.QueryNotFound;
                        },
                        .retry => return .{ .retry = result.seq },
                        else => {
                            self.metrics.queries_aborted.inc();
                            return error.ExecutionError;
                        },
                    }
                },
            }
        }

        return .{ .done = .{
            .rows_affected = total_rows,
            .result_set = combined_result_set,
        } };
    }

    /// Execute a registered DML query (INSERT/UPDATE/DELETE) with the given parameters.
    /// Routes through the Sequencer → partition log → SqlExecutor.run().
    // This is the domain boundary — all data past this point is validated.
    pub fn execute(
        self: *Gateway,
        hash: QueryHash,
        params: []const ColumnValue,
        nondet: []const ResolvedValue,
    ) !ExecResult {
        const rq = self.fold_executors[0].lookupQuery(hash) orelse return error.QueryNotFound;
        self.metrics.queries_executed.inc();

        // Assign a stable client_seq for this logical operation ONCE, before any retry.
        self.client_seq += 1;
        const op_seq = self.client_seq;

        // Encode params to canonical bytes.
        const params_bytes = try sql_mod.executor_bridge.encodeParams(params, self.alloc);
        defer self.alloc.free(params_bytes);

        // Resolve nondeterministic functions in the SQL text (NOW(), RANDOM(), UUID()).
        const resolved = try nondet_mod.resolveNondet(rq.sql_text, &self.nondet_resolver, self.alloc);
        defer self.alloc.free(resolved);
        if (resolved.len > 0) self.metrics.nondet_resolved.add(@intCast(resolved.len));

        // Merge caller-supplied nondet with gateway-resolved values.
        const all_nondet = if (nondet.len > 0) nondet else resolved;

        // On retry, re-run reconnaissance at the seq the executor assigned to the
        // conflicting entry so hints reflect state as of that point.
        var hint_seq: Seq = blk: {
            var max: Seq = 0;
            for (self.fold_executors) |fe| {
                const cs = fe.current_seq();
                if (cs > max) max = cs;
            }
            break :blk max;
        };

        const max_retries: usize = 3;
        std.debug.assert(max_retries > 0);
        var intent_buf: std.ArrayList(u8) = .empty;
        defer intent_buf.deinit(self.alloc);
        var attempt: usize = 0;
        while (attempt < max_retries) : (attempt += 1) {
            if (attempt > 0) self.metrics.recon_retries.inc();

            intent_buf.clearRetainingCapacity();
            try self.buildTxnIntent(
                &hash,
                rq.plan,
                op_seq,
                hint_seq,
                params,
                params_bytes,
                all_nondet,
                &intent_buf,
            );
            switch (try self.submitAndDrain(intent_buf.items, op_seq)) {
                .done => |r| return r,
                .retry => |conflict_seq| hint_seq = conflict_seq,
            }
        }
        std.debug.assert(attempt == max_retries);
        return error.ExecutionError;
    }

    /// Execute a SELECT query and return the result set.
    /// Reads go directly to storage (no log routing needed for reads).
    // This is the domain boundary — all data past this point is validated.
    pub fn querySelect(
        self: *Gateway,
        hash: QueryHash,
        params: []const ColumnValue,
        nondet: []const ResolvedValue,
    ) !ResultSet {
        return self.fold_executors[0].querySelect(hash, params, nondet, self.alloc);
    }

    /// Read data at a specific sequence number (historical read).
    // This is the domain boundary — all data past this point is validated.
    pub fn readAt(
        self: *Gateway,
        hash: QueryHash,
        params: []const ColumnValue,
        seq: Seq,
    ) !ResultSet {
        return self.fold_executors[0].readAt(hash, params, seq, self.alloc);
    }

    /// Set a human-readable detail string for the last error (table/column context).
    fn setDetail(self: *Gateway, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.error_detail, fmt, args) catch &self.error_detail;
        self.error_detail_len = s.len;
    }

    /// Return the detail string set by the last failing operation, or "" if none.
    pub fn lastDetail(self: *const Gateway) []const u8 {
        return self.error_detail[0..self.error_detail_len];
    }

    /// Apply a DDL statement to the schema and replicate it via Raft.
    /// Validates and applies locally first so the connection sees errors before committing.
    pub fn applyDdl(self: *Gateway, sql: []const u8) !void {
        self.error_detail_len = 0;
        try self.fold_executors[0].applyDdlLocal(sql);
        self.client_seq += 1;
        // SAFETY: submitBytes writes to pending before awaitCommit is called on the returned handle.
        var pending: sequencer_mod.PendingSubmit = undefined;
        const result = try self.sequencer.submitBytes(
            &pending,
            sql,
            self.client_id,
            self.client_seq,
            .schema_change,
        ).awaitCommit(self.io);
        try self.waitAllFoldExecutors(result.seq);
    }

    /// Get the current committed sequence number.
    pub fn currentSeq(self: *const Gateway) Seq {
        return self.sequencer.currentSeq();
    }

    /// Add a new sequencer node to the Raft group. Only valid on the current leader.
    /// Note: only the ordering layer is affected — the new node does not automatically
    /// receive data partition log entries or storage state.
    pub fn addSequencerNode(self: *Gateway, node_id: sequencer_mod.NodeId, addr: []const u8) !void {
        std.debug.assert(node_id != 0);
        std.debug.assert(addr.len > 0);
        try self.sequencer.addNode(node_id, addr, self.alloc);
    }

    /// Remove a sequencer node from the Raft group. Only valid on the current leader.
    pub fn removeSequencerNode(self: *Gateway, node_id: sequencer_mod.NodeId) !void {
        std.debug.assert(node_id != 0);
        try self.sequencer.removeNode(node_id, self.alloc);
    }

    /// Flush all storage to disk.
    pub fn flushAll(self: *Gateway) !void {
        try self.partitioned.flushAll();
    }

    // ---- CDC subscription API (used by the net layer) ----

    /// Create a CDC subscription. Pass null table_filter to receive all tables.
    pub fn subscribeCdc(
        self: *Gateway,
        table_filter: ?u32,
        from_seq: Seq,
    ) !*cdc_mod.CdcSubscription {
        return self.cdc.subscribe(table_filter, from_seq);
    }

    /// Remove a CDC subscription by its ID.
    pub fn unsubscribeCdc(self: *Gateway, id: u64) void {
        self.cdc.unsubscribe(id);
    }

    /// Look up an active CDC subscription by ID (returns null if not found).
    pub fn getCdcSub(self: *Gateway, id: u64) ?*cdc_mod.CdcSubscription {
        return self.cdc.find_by_id(id);
    }

    /// Resolve a table name to its numeric ID via the schema registry.
    /// Returns null if the table is not found.
    pub fn resolveTableName(self: *Gateway, name: []const u8) ?u32 {
        return self.fold_executors[0].resolveTableName(name);
    }

    /// Returns true if a table with this numeric ID exists in the schema.
    pub fn tableIdExists(self: *Gateway, id: u32) bool {
        return self.fold_executors[0].tableIdExists(id);
    }
};
