/// Foldb Gateway: client-facing entry point for query registration, execution, and CDC.
const std = @import("std");
const errors = @import("errors.zig");

const sql_mod = @import("sql.zig");
const storage_mod = @import("storage.zig");
const executor_mod = @import("executor.zig");
const sequencer_mod = @import("sequencer.zig");
const log_mod = @import("log.zig");
const observability_mod = @import("observability.zig");
const cdc_mod = @import("cdc.zig");
const nondet_mod = @import("nondet.zig");
const recon_mod = @import("recon.zig");
const snapshot_hooks_mod = @import("snapshot_hooks.zig");

pub const QueryHash = sql_mod.QueryHash;
pub const Seq = @import("types.zig").Seq;
pub const ResolvedValue = @import("types.zig").ResolvedValue;

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
    schema: sql_mod.SchemaRegistry,
    registry: sql_mod.SqlRegistry,
    sql_exec: sql_mod.SqlExecutor,
    /// One Storage per data partition. Heap-allocated; owned by this gateway.
    storages: []*storage_mod.Storage,
    /// Routing wrapper over storages — used by sql_exec and reconnaissance.
    partitioned: storage_mod.PartitionedStorage,
    /// Arena that owns storage-schema column slices allocated during DDL.
    storage_schema_arena: std.heap.ArenaAllocator,
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
    /// Background executor thread — applies committed partition log entries to storage
    /// on follower nodes. On the leader, runValidated() in execute() is the apply path.
    /// TODO: the leader↔follower transition window is a known gap — a briefly demoted
    /// leader may have an in-flight runValidated concurrent with the apply loop starting.
    /// Needs a proper handoff mechanism when leadership changes are handled end-to-end.
    apply_thread: ?std.Thread = null,
    apply_shutdown: std.atomic.Value(bool) = .init(false),
    /// Heap-allocated S3 store; non-null when S3 is configured. Freed in deinit.
    s3_store: ?*storage_mod.S3ObjectStore = null,
    /// Per-partition context structs for snapshot log writers. Freed in deinit.
    snapshot_writer_ctxs: []snapshot_hooks_mod.SnapshotWriterCtx = &.{},
    /// Highest seq for which a snapshot has been durably uploaded. Updated by postSnapshotImpl.
    durable_snapshot_seq: sequencer_mod.Seq = 0,
    /// Stable context for the post-snapshot truncation hook. Initialized in init.
    truncate_ctx: TruncateCtx = undefined,
    /// Last error detail set by gateway operations (table/column context).
    /// Reset at the start of each operation that may set it.
    error_detail: [256]u8 = undefined,
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
        gw.storage_schema_arena = std.heap.ArenaAllocator.init(alloc);

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

        gw.schema = sql_mod.SchemaRegistry.init(alloc);
        gw.registry = sql_mod.SqlRegistry.init(alloc, &gw.schema);
        gw.sql_exec = sql_mod.SqlExecutor.init(&gw.partitioned, &gw.registry, &gw.schema, alloc);
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
        try gw.sequencer.start();

        gw.cdc = try cdc_mod.CdcManager.init(alloc);
        gw.sql_exec.initCdc(&gw.cdc);

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
        try gw.replayFromLog();

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
        gw.apply_shutdown = .init(false);
        gw.apply_thread = null;

        return gw;
    }

    pub fn deinit(self: *Gateway) void {
        self.apply_shutdown.store(true, .release);
        if (self.apply_thread) |t| t.join();
        self.cdc.deinit();
        self.sequencer.deinit();
        self.registry.deinit();
        self.schema.deinit();
        // Flush memtables to SSTables before teardown so data survives restart.
        for (self.storages) |s| {
            const dir = s.dir;
            s.flushAll() catch |err| std.log.warn("flushAll failed during deinit: {}", .{err});
            s.deinit();
            self.alloc.destroy(s);
            self.alloc.free(dir);
        }
        self.alloc.free(self.storages);
        self.storage_schema_arena.deinit();
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
    pub fn isSelectQuery(self: *const Gateway, hash: QueryHash) bool {
        const rq = self.registry.lookup(hash) orelse return false;
        for (rq.plan.stmts) |stmt| {
            switch (stmt) {
                .select => {},
                else => return false,
            }
        }
        return true;
    }

    /// Register a SQL query and return its hash with schema version.
    /// Idempotent: registering the same SQL twice returns the same hash.
    /// Routes through Raft so all nodes replicate the schema change.
    pub fn register(self: *Gateway, sql: []const u8) !RegisterResult {
        self.error_detail_len = 0;
        // Register locally to compute the hash (idempotent — safe to call before commit).
        const hash = self.registry.register(sql) catch |e| {
            // On parse error, re-parse directly to surface the offending token.
            if (e == error.UnexpectedToken or e == error.UnsupportedSyntax) {
                var arena = std.heap.ArenaAllocator.init(self.alloc);
                defer arena.deinit();
                var p = sql_mod.parser.Parser.init(sql, arena.allocator());
                _ = p.parseQuery() catch {};
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
        // Replicate via Raft — all nodes will apply this schema_change from the
        // committed Raft entry and register the query in their local registries.
        self.client_seq += 1;
        var pending: sequencer_mod.PendingSubmit = undefined;
        _ = try self.sequencer.submitBytes(
            &pending,
            sql,
            self.client_id,
            self.client_seq,
            .schema_change,
        ).awaitCommit();
        return .{
            .hash = hash,
            .schema_version = self.registry.schema_seq,
        };
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
            plan, &self.partitioned, params, &self.schema,
            recon_seq, self.partition_count, self.recon_strategy, self.alloc,
        );
        defer hints.deinit();
        try executor_mod.serialize_txn_intent(
            hash, self.client_id, op_seq, recon_seq,
            hints.read, hints.write, params_bytes, all_nondet,
            buf, self.alloc,
        );
    }

    /// Submit serialized intent bytes to the sequencer, drain the log, and dispatch
    /// the executor result. Returns .done on success or .retry with the conflict seq.
    fn submitAndDrain(self: *Gateway, intent_bytes: []const u8, op_seq: u64) !SubmitOutcome {
        var pending: sequencer_mod.PendingSubmit = undefined;
        const handle = self.sequencer.submitBytes(
            &pending, intent_bytes, self.client_id, op_seq, .txn_intent,
        );
        const result = try handle.awaitCommit();

        // Drain committed log entries up to result.seq. This runs on the gateway thread
        // after awaitCommit() guarantees the entry is durable — commit precedes execution.
        // When a background apply thread is running (follower mode), waitFor() returns
        // without draining here.
        while (self.sql_exec.current_seq() < result.seq) {
            try self.applyNewEntries();
        }
        const exec_result = self.sql_exec.waitFor(result.seq);
        const exec_detail = self.sql_exec.lastDetail();
        if (exec_detail.len > 0) self.setDetail("{s}", .{exec_detail});

        switch (exec_result) {
            .ok => |ok| return .{ .done = .{
                .rows_affected = ok.rows_affected,
                .result_set = ok.result_set,
            } },
            .abort => |ab| switch (ab.code) {
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
            },
        }
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
        const rq = self.registry.lookup(hash) orelse return error.QueryNotFound;
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
        var hint_seq: Seq = self.sql_exec.current_seq();

        const max_retries: usize = 3;
        std.debug.assert(max_retries > 0);
        var intent_buf: std.ArrayList(u8) = .empty;
        defer intent_buf.deinit(self.alloc);
        var attempt: usize = 0;
        while (attempt < max_retries) : (attempt += 1) {
            if (attempt > 0) self.metrics.recon_retries.inc();

            intent_buf.clearRetainingCapacity();
            try self.buildTxnIntent(
                &hash, rq.plan, op_seq, hint_seq, params, params_bytes, all_nondet, &intent_buf,
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
        const rq = self.registry.lookup(hash) orelse return error.QueryNotFound;

        const decoded_params = try decodeParams(params, rq.param_types, self.alloc);
        defer self.alloc.free(decoded_params);

        var rows = try self.sql_exec.querySelect(
            rq.plan,
            decoded_params,
            nondet,
            self.sql_exec.current_seq() + 1,
            self.alloc,
        );
        const rows_slice = try rows.toOwnedSlice(self.alloc);
        const columns_slice = if (rq.plan.stmts.len > 0 and rq.plan.stmts[0] == .select) blk: {
            break :blk try extractColumnNames(rq.plan.stmts[0].select, &self.schema, self.alloc);
        } else try self.alloc.alloc([]const u8, 0);

        return ResultSet{
            .columns = columns_slice,
            .rows = rows_slice,
            .alloc = self.alloc,
        };
    }

    /// Read data at a specific sequence number (historical read).
    // This is the domain boundary — all data past this point is validated.
    pub fn readAt(
        self: *Gateway,
        hash: QueryHash,
        params: []const ColumnValue,
        seq: Seq,
    ) !ResultSet {
        const rq = self.registry.lookup(hash) orelse return error.QueryNotFound;

        const decoded_params = try decodeParams(params, rq.param_types, self.alloc);
        defer self.alloc.free(decoded_params);

        var rows = try self.sql_exec.querySelect(
            rq.plan,
            decoded_params,
            &.{},
            seq + 1,
            self.alloc,
        );
        const rows_slice = try rows.toOwnedSlice(self.alloc);
        const columns_slice = if (rq.plan.stmts.len > 0 and rq.plan.stmts[0] == .select) blk: {
            break :blk try extractColumnNames(rq.plan.stmts[0].select, &self.schema, self.alloc);
        } else try self.alloc.alloc([]const u8, 0);

        return ResultSet{
            .columns = columns_slice,
            .rows = rows_slice,
            .alloc = self.alloc,
        };
    }

    /// Replay partition log 0 in two passes to rebuild full gateway state after restart.
    // This is the domain boundary — entries are read from the durable partition log whose
    // payloads were validated at write time. Errors such as already-exists or parse failures
    // are silently dropped: idempotent re-registration on restart is expected and correct.
    //
    // Pass 1 (schema): rebuild DDL and query registry so all query hashes are known.
    // Pass 2 (DML): replay txn_intent entries through SqlExecutor to rebuild storage state,
    //   including rows that were in the memtable and not yet flushed to SSTables at crash time.
    fn replayFromLog(self: *Gateway) !void {
        const batch = 256;

        // Pass 1: schema — DDL and query registration only.
        var from_seq: log_mod.Seq = 1;
        while (true) {
            const entries = try self.sequencer.partition_logs[0].read(from_seq, batch, self.alloc);
            defer {
                for (entries) |*e| e.deinit(self.alloc);
                self.alloc.free(entries);
            }
            if (entries.len == 0) break;
            for (entries) |e| {
                if (e.header.kind == .schema_change) {
                    if (isSqlDdl(e.payload)) {
                        try self.replayDdl(e.payload);
                    } else {
                        _ = try self.registry.register(e.payload);
                    }
                }
                from_seq = e.header.seq + 1;
            }
            if (entries.len < batch) break;
        }

        // Pass 2: DML — apply txn_intent entries to rebuild storage state.
        // SqlExecutor.run handles CRC validation, deserialization, and committed_seq tracking.
        // Aborted results (missing query, bad params) are encoded as ExecResult.abort, not Zig
        // errors, so they advance committed_seq without surfacing here.
        from_seq = 1;
        while (true) {
            const entries = try self.readMergedEntries(from_seq, batch);
            defer {
                for (entries) |*e| e.deinit(self.alloc);
                self.alloc.free(entries);
            }
            if (entries.len == 0) break;
            for (entries) |e| {
                if (e.header.kind == .txn_intent) {
                    _ = try self.sql_exec.run(e);
                } else {
                    self.sql_exec.advanceSeq(e.header.seq);
                }
                from_seq = e.header.seq + 1;
            }
            if (entries.len < batch * self.sequencer.partition_logs.len) break;
        }
    }

    /// Read up to batch entries from every partition log starting at from_seq,
    /// merge them, and return them sorted by seq. For partition_count=1 this is
    /// a direct passthrough. Caller owns the returned slice and each entry's payload.
    fn readMergedEntries(self: *Gateway, from_seq: log_mod.Seq, batch: usize) ![]log_mod.LogEntry {
        const logs = self.sequencer.partition_logs;
        if (logs.len == 1) return logs[0].read(from_seq, batch, self.alloc);
        var list: std.ArrayList(log_mod.LogEntry) = .empty;
        errdefer {
            for (list.items) |*e| e.deinit(self.alloc);
            list.deinit(self.alloc);
        }
        for (logs) |*log| {
            const slice = try log.read(from_seq, batch, self.alloc);
            defer self.alloc.free(slice);
            try list.appendSlice(self.alloc, slice);
        }
        const merged = try list.toOwnedSlice(self.alloc);
        std.sort.block(log_mod.LogEntry, merged, {}, struct {
            fn lt(_: void, a: log_mod.LogEntry, b: log_mod.LogEntry) bool {
                return a.header.seq < b.header.seq;
            }
        }.lt);
        return merged;
    }

    /// Drain newly committed log entries into the executor.
    /// The apply thread calls this in a loop; schema_change entries update the
    /// registry before sql_exec.run() advances committed_seq.
    pub fn applyNewEntries(self: *Gateway) !void {
        const batch = 64;
        var from_seq = self.sql_exec.current_seq() + 1;
        while (true) {
            const entries = try self.readMergedEntries(from_seq, batch);
            defer {
                for (entries) |*e| e.deinit(self.alloc);
                self.alloc.free(entries);
            }
            if (entries.len == 0) break;
            for (entries) |e| {
                switch (e.header.kind) {
                    .schema_change => {
                        if (isSqlDdl(e.payload)) {
                            try self.replayDdl(e.payload);
                        } else {
                            _ = try self.registry.register(e.payload);
                        }
                        self.sql_exec.advanceSeq(e.header.seq);
                    },
                    .txn_intent => _ = try self.sql_exec.run(e),
                    else => self.sql_exec.advanceSeq(e.header.seq),
                }
                from_seq = e.header.seq + 1;
            }
            if (entries.len < batch * self.sequencer.partition_logs.len) break;
        }
    }

    fn isSqlDdl(sql: []const u8) bool {
        const s = std.mem.trimStart(u8, sql, " \t\r\n");
        var end: usize = 0;
        while (end < s.len and s[end] != ' ' and s[end] != '\t' and s[end] != '(') : (end += 1) {}
        if (end == 0) return false;
        var buf: [6]u8 = undefined;
        const len = @min(end, buf.len);
        for (s[0..len], 0..) |c, i| buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        const tok = buf[0..len];
        return std.mem.eql(u8, tok, "create") or std.mem.eql(u8, tok, "drop") or std.mem.eql(u8, tok, "alter");
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

    /// Apply a DDL statement to the schema, propagate to storage, and persist to log.
    pub fn applyDdl(self: *Gateway, sql: []const u8) !void {
        self.error_detail_len = 0;
        try self.applyDdlToSchema(sql);
        // Persist to partition log 0 so schema survives restart.
        const seq = self.sequencer.next_seq;
        self.sequencer.next_seq += 1;
        const entry = log_mod.LogEntry.create(seq, 0, .schema_change, sql);
        try self.sequencer.partition_logs[0].append_entry_at(entry);
    }

    /// Apply DDL during log replay (does not write to log).
    /// Silently ignores "already exists" errors — these are expected on replay.
    fn replayDdl(self: *Gateway, sql: []const u8) !void {
        self.applyDdlToSchema(sql) catch |e| switch (e) {
            error.TableAlreadyExists, error.IndexAlreadyExists, error.ColumnAlreadyExists => {},
            error.TableNotFound => {}, // DROP TABLE on already-dropped table is a no-op on replay
            else => return e,
        };
    }

    fn applyDdlToSchema(self: *Gateway, sql: []const u8) !void {
        std.debug.assert(sql.len > 0);
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();

        var parser = sql_mod.parser.Parser.init(sql, arena.allocator());
        const parsed = parser.parseQuery() catch |e| {
            if (parser.err_msg) |msg| {
                const pos = parser.err_pos;
                if (pos < sql.len) {
                    // Extract the token starting at err_pos (up to 24 chars).
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
            return e;
        };

        if (parsed.stmts.len == 0) return;
        const stmt = parsed.stmts[0];

        // For DROP TABLE, capture the table_id before registry.applyDdl removes it from schema.
        const drop_table_id: ?storage_mod.TableId = if (stmt == .drop_table) blk: {
            const dt = stmt.drop_table;
            const tbl = self.schema.getTable(dt.name) orelse {
                if (dt.if_exists) return; // table doesn't exist but IF EXISTS — silent success
                break :blk null;
            };
            break :blk tbl.id;
        } else null;

        self.registry.applyDdl(stmt) catch |e| {
            switch (stmt) {
                .create_table => |ct| self.setDetail("'{s}': {s}", .{ ct.name, errors.humanize(e) }),
                .create_index => |ci| self.setDetail("'{s}' on '{s}': {s}", .{ ci.name, ci.table, errors.humanize(e) }),
                .alter_table => |at| self.setDetail("'{s}': {s}", .{ at.table, errors.humanize(e) }),
                .drop_table => |dt| self.setDetail("'{s}': {s}", .{ dt.name, errors.humanize(e) }),
                else => self.setDetail("{s}", .{errors.humanize(e)}),
            }
            return e;
        };

        switch (stmt) {
            .create_table => |ct| {
                const tbl = self.schema.getTable(ct.name) orelse return error.TableNotFound;
                try self.partitioned.registerTable(try sqlTableToStorage(tbl, self.storage_schema_arena.allocator()));
            },
            .drop_table => {
                if (drop_table_id) |id| self.partitioned.unregisterTable(id);
            },
            .create_index => |ci| {
                const tbl = self.schema.getTable(ci.table) orelse return error.TableNotFound;
                if (tbl.indexes.len == 0) return;
                const idx = tbl.indexes[tbl.indexes.len - 1];
                // Domain boundary — SQL-level index kind is validated by schema.createIndex()
                // before reaching here; only vector and json_path kinds are passed to storage.
                const spec: storage_mod.IndexSpec = switch (idx.kind) {
                    .vector => .{ .vector = switch (idx.extra) {
                        .vector_dim => |d| d,
                        else => 0,
                    } },
                    .json_path => .{ .json_path = switch (idx.extra) {
                        .json_paths => |p| p,
                        else => &.{},
                    } },
                    else => return,
                };
                const column_idx: u32 = if (idx.columns.len > 0) idx.columns[0] else 0;
                try self.partitioned.registerIndex(.{
                    .id = idx.id,
                    .table_id = tbl.id,
                    .column_idx = column_idx,
                    .spec = spec,
                });
            },
            else => {},
        }
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
        const tbl = self.schema.getTable(name) orelse return null;
        return tbl.id;
    }

    /// Returns true if a table with this numeric ID exists in the schema.
    pub fn tableIdExists(self: *Gateway, id: u32) bool {
        return self.schema.getTableById(id) != null;
    }
};

// Drives applyNewEntries() in a loop until apply_shutdown is set.
// Schema_change entries are applied to the registry before sql_exec advances
// committed_seq, so txn_intent entries that follow always see current schema.
fn applyThreadFn(gw: *Gateway) void {
    while (!gw.apply_shutdown.load(.acquire)) {
        gw.applyNewEntries() catch |err| std.log.err("applyNewEntries failed in apply thread: {}", .{err});
        std.Thread.yield() catch {}; // EINTR is benign; the loop continues regardless.
    }
}

fn decodeParams(
    params: []const ColumnValue,
    param_types: []const sql_mod.ast.SqlType,
    alloc: std.mem.Allocator,
) ![]const ColumnValue {
    // param_types is only populated for TRANSACTION blocks; plain SELECT param types are not
    // yet extracted by extractParamTypes. Enforce the count only when types are known.
    if (param_types.len > 0 and params.len != param_types.len) return error.ParamDecodeError;
    return try alloc.dupe(ColumnValue, params);
}

fn sqlTableToStorage(
    tbl: *const sql_mod.schema.TableSchema,
    alloc: std.mem.Allocator,
) !storage_mod.TableSchema {
    const cols = try alloc.alloc(storage_mod.ColumnSchema, tbl.columns.len);
    for (tbl.columns, cols) |src, *dst| {
        dst.* = .{
            .col_type = sqlTypeToColumnType(src.typ),
            .nullable = src.nullable == .nullable,
        };
    }
    return .{
        .table_id = tbl.id,
        .columns = cols,
    };
}

fn sqlTypeToColumnType(t: sql_mod.ast.SqlType) storage_mod.ColumnType {
    return switch (t) {
        .bool => .bool_t,
        .int8 => .int8,
        .int16 => .int16,
        .int32 => .int32,
        .int64 => .int64,
        .uint8 => .uint8,
        .uint16 => .uint16,
        .uint32 => .uint32,
        .uint64 => .uint64,
        .string => .string,
        .bytes => .bytes,
        .uuid => .bytes,
        .timestamp => .int64,
        .interval_months, .interval_micros => .int64,
        .decimal => .decimal,
        .json, .vector, .array, .struct_type => .bytes,
        .null_type => .bytes,
    };
}

/// Extract output column names from a SELECT plan node.
/// For project nodes uses the alias; for scan nodes uses schema column names.
/// Caller owns the returned slice and its strings.
fn extractColumnNames(
    node: *const sql_mod.plan.PlanNode,
    schema: *const sql_mod.SchemaRegistry,
    alloc: std.mem.Allocator,
) ![][]const u8 {
    switch (node.*) {
        .project => |p| {
            const names = try alloc.alloc([]const u8, p.exprs.len);
            errdefer alloc.free(names);
            for (p.exprs, 0..) |item, i| names[i] = try alloc.dupe(u8, item.alias);
            return names;
        },
        .scan => |s| {
            const tbl = schema.getTableById(s.table_id) orelse return try alloc.alloc([]const u8, 0);
            const ids = if (s.columns.len > 0) s.columns else blk: {
                // all columns
                const all = try alloc.alloc(sql_mod.schema.ColumnId, tbl.columns.len);
                defer alloc.free(all);
                for (tbl.columns, 0..) |col, i| all[i] = col.id;
                break :blk all;
            };
            const names = try alloc.alloc([]const u8, ids.len);
            errdefer alloc.free(names);
            for (ids, 0..) |col_id, i| {
                const col = tbl.columnById(col_id);
                names[i] = if (col) |c| try alloc.dupe(u8, c.name) else try std.fmt.allocPrint(alloc, "col{d}", .{i});
            }
            return names;
        },
        .filter => |f| return extractColumnNames(f.input, schema, alloc),
        .sort => |s| return extractColumnNames(s.input, schema, alloc),
        .limit => |l| return extractColumnNames(l.input, schema, alloc),
        .pk_lookup => |pk| {
            const tbl = schema.getTableById(pk.table_id) orelse return try alloc.alloc([]const u8, 0);
            const names = try alloc.alloc([]const u8, pk.columns.len);
            errdefer alloc.free(names);
            for (pk.columns, 0..) |col_id, i| {
                const col = tbl.columnById(col_id);
                names[i] = if (col) |c| try alloc.dupe(u8, c.name) else try std.fmt.allocPrint(alloc, "col{d}", .{i});
            }
            return names;
        },
        else => return try alloc.alloc([]const u8, 0),
    }
}

