/// Foldb Gateway: client-facing entry point for query registration, execution, and CDC.
const std = @import("std");
const errors = @import("errors.zig");

const sql_mod = @import("sql.zig");
const storage_mod = @import("storage.zig");
const executor_mod = @import("executor.zig");
const sequencer_mod = @import("sequencer.zig");
const log_mod = @import("log.zig");
const obs = @import("observability.zig");
const cdc_mod = @import("cdc.zig");

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

/// Injectable clock source. Production uses real clock_gettime; sim substitutes VirtualClock.
/// now_micros_fn returns unix microseconds as i64.
pub const ClockSource = struct {
    ptr: ?*anyopaque = null,
    now_micros_fn: *const fn (?*anyopaque) i64 = realNowMicros,

    pub fn now(self: ClockSource) i64 {
        return self.now_micros_fn(self.ptr);
    }

    fn realNowMicros(_: ?*anyopaque) i64 {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
        return @as(i64, @intCast(ts.sec)) * 1_000_000 + @as(i64, @intCast(@divTrunc(ts.nsec, 1_000)));
    }
};

/// Injectable random source. Production uses clock-seeded PRNG; sim substitutes SimScheduler.
pub const RandSource = struct {
    ptr: ?*anyopaque = null,
    fill_fn: *const fn (?*anyopaque, []u8) void = realFill,

    pub fn fill(self: RandSource, buf: []u8) void {
        self.fill_fn(self.ptr, buf);
    }

    fn realFill(_: ?*anyopaque, buf: []u8) void {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
        const seed: u64 = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
        var rand = std.Random.Xoroshiro128.init(seed);
        rand.fill(buf);
    }
};

/// Nondeterminism resolver - computes values for NOW(), RANDOM(), UUID()
pub const NondetResolver = struct {
    clock: ClockSource,
    rand: RandSource,

    pub fn init(clock: ClockSource, rand: RandSource) NondetResolver {
        return .{ .clock = clock, .rand = rand };
    }

    pub fn resolveNow(self: NondetResolver) ResolvedValue {
        return .{ .now = self.clock.now() };
    }

    pub fn resolveRandom(self: NondetResolver) ResolvedValue {
        var bytes: [16]u8 = undefined;
        self.rand.fill(&bytes);
        return .{ .random = bytes };
    }

    pub fn resolveUuidV7(self: NondetResolver) ResolvedValue {
        const micros = self.clock.now();
        var uuid: [16]u8 = undefined;
        const ms: u64 = @intCast(@divTrunc(micros, 1_000));
        std.mem.writeInt(u64, &uuid[0..8].*, ms, .big);
        uuid[6] = (uuid[6] & 0x0F) | 0x70;
        var rand_bytes: [8]u8 = undefined;
        self.rand.fill(&rand_bytes);
        @memcpy(uuid[8..16], &rand_bytes);
        uuid[8] = (uuid[8] & 0x3F) | 0x80;
        return .{ .uuid_v7 = uuid };
    }
};

/// Context for a per-partition snapshot log writer. Stable once allocated in init.
const SnapshotWriterCtx = struct {
    log: *log_mod.Log,
    next_seq: *sequencer_mod.Seq,
};

/// Context for the post-snapshot truncation hook. Stable once set in init.
const TruncateCtx = struct { gateway: *Gateway };

fn postSnapshotImpl(ptr: *anyopaque, snapshot_seq: sequencer_mod.Seq) void {
    const ctx: *TruncateCtx = @ptrCast(@alignCast(ptr));
    const gw = ctx.gateway;
    if (snapshot_seq > gw.durable_snapshot_seq) gw.durable_snapshot_seq = snapshot_seq;
    gw.truncateLog() catch {};
}

fn snapshotLogWriteImpl(ptr: *anyopaque, manifest_key: []const u8, seq: u64, partition_id: u32, alloc: std.mem.Allocator) anyerror!void {
    const ctx: *SnapshotWriterCtx = @ptrCast(@alignCast(ptr));
    const payload = storage_mod.SnapshotMarkerPayload{
        .manifest_key = manifest_key,
        .seq = seq,
        .partition_id = partition_id,
    };
    const bytes = try payload.serialize(alloc);
    defer alloc.free(bytes);
    const entry_seq = ctx.next_seq.*;
    ctx.next_seq.* += 1;
    const entry = log_mod.LogEntry.create(entry_seq, partition_id, .snapshot_marker, bytes);
    try ctx.log.appendEntryAt(entry);
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
    nondet_resolver: NondetResolver,
    sequencer: sequencer_mod.Sequencer,
    /// CDC event fan-out for wire-protocol subscriptions.
    cdc: cdc_mod.CdcManager,
    /// Per-gateway client identity for idempotency tracking.
    client_id: u64,
    client_seq: u64,
    /// Number of data partitions — used to hash PK keys to partition IDs during reconnaissance.
    partition_count: u32,
    alloc: std.mem.Allocator,
    metrics: obs.GatewayMetrics = .{},
    /// Heap-allocated S3 store; non-null when S3 is configured. Freed in deinit.
    s3_store: ?*storage_mod.S3ObjectStore = null,
    /// Per-partition context structs for snapshot log writers. Freed in deinit.
    snapshot_writer_ctxs: []SnapshotWriterCtx = &.{},
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
        const storages = try alloc.alloc(*storage_mod.Storage, pc);
        errdefer alloc.free(storages);
        var n_inited: usize = 0;
        errdefer for (storages[0..n_inited]) |s| {
            const dir = s.dir;
            s.flushAll() catch {};
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
        if (opts.s3_access_key.len > 0 and opts.s3_bucket.len > 0) {
            const s3_io = opts.s3_io orelse return error.IoRequiredForS3;
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
        }

        gw.schema = sql_mod.SchemaRegistry.init(alloc);
        gw.registry = sql_mod.SqlRegistry.init(alloc, &gw.schema);
        gw.sql_exec = sql_mod.SqlExecutor.init(&gw.partitioned, &gw.registry, &gw.schema, alloc);
        gw.nondet_resolver = NondetResolver.init(opts.clock, opts.rand);

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

        gw.cdc = cdc_mod.CdcManager.init(alloc);
        gw.sql_exec.initCdc(&gw.cdc);

        // Wire snapshot scheduling if an object store is available and interval is set.
        const snap_obj: ?storage_mod.ObjectStore = blk: {
            if (opts.snapshot_store) |s| break :blk s;
            if (gw.s3_store) |s3| break :blk s3.objectStore();
            break :blk null;
        };
        if (snap_obj) |obj| {
            if (opts.snapshot_interval_entries > 0) {
                const ctxs = try alloc.alloc(SnapshotWriterCtx, pc);
                for (ctxs, 0..) |*ctx, i| {
                    ctx.* = .{
                        .log = &gw.sequencer.partition_logs[i],
                        .next_seq = &gw.sequencer.next_seq,
                    };
                }
                gw.snapshot_writer_ctxs = ctxs;
                for (gw.storages, 0..) |stor, i| {
                    stor.setSnapshotPolicy(.{
                        .interval = opts.snapshot_interval_entries,
                        .store = obj,
                        .log_writer = .{
                            .ptr = &ctxs[i],
                            .writeFn = &snapshotLogWriteImpl,
                        },
                        .partition_id = @intCast(i),
                        .post_snapshot = .{
                            .ptr = &gw.truncate_ctx,
                            .hookFn = &postSnapshotImpl,
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
            var h: u64 = 0xcbf29ce484222325;
            for (storage_dir) |b| {
                h ^= b;
                h *%= 0x100000001b3;
            }
            break :blk h;
        };
        gw.client_seq = 0;
        gw.partition_count = opts.partition_count;

        return gw;
    }

    pub fn deinit(self: *Gateway) void {
        self.cdc.deinit();
        self.sequencer.deinit();
        self.registry.deinit();
        self.schema.deinit();
        // Flush memtables to SSTables before teardown so data survives restart.
        for (self.storages) |s| {
            const dir = s.dir;
            s.flushAll() catch {};
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
        for (self.cdc.subscriptions.items) |sub| {
            if (sub.cursor < safe_seq) safe_seq = sub.cursor;
        }
        for (self.sequencer.partition_logs) |*log| {
            log.notifySnapshot(safe_seq);
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
    pub fn register(self: *Gateway, sql: []const u8) !RegisterResult {
        self.error_detail_len = 0;
        const hash = try self.registry.register(sql);
        self.metrics.queries_registered.inc();
        // Persist registration so it can be replayed on restart.
        const seq = self.sequencer.next_seq;
        self.sequencer.next_seq += 1;
        const entry = log_mod.LogEntry.create(seq, 0, .schema_change, sql);
        try self.sequencer.partition_logs[0].appendEntryAt(entry);
        return .{
            .hash = hash,
            .schema_version = self.registry.schema_seq,
        };
    }

    /// Execute a registered DML query (INSERT/UPDATE/DELETE) with the given parameters.
    /// Routes through the Sequencer → partition log → SqlExecutor.run().
    // This is the domain boundary — all data past this point is validated.
    pub fn execute(
        self: *Gateway,
        io: std.Io,
        hash: QueryHash,
        params: []const ColumnValue,
        nondet: []const ResolvedValue,
    ) !ExecResult {
        const rq = self.registry.lookup(hash) orelse return error.QueryNotFound;

        self.metrics.queries_executed.inc();

        // Assign a stable client_seq for this logical operation ONCE, before any retry.
        self.client_seq += 1;
        const op_seq = self.client_seq;

        // Encode params to canonical bytes
        const params_bytes = try sql_mod.executor_bridge.encodeParams(params, self.alloc);
        defer self.alloc.free(params_bytes);

        // Resolve nondeterministic functions in the SQL text (NOW(), RANDOM(), UUID()).
        const resolved = try resolveNondet(rq.sql_text, &self.nondet_resolver, self.alloc);
        defer self.alloc.free(resolved);
        if (resolved.len > 0) self.metrics.nondet_resolved.add(@intCast(resolved.len));

        // Merge caller-supplied nondet with gateway-resolved values.
        const all_nondet = if (nondet.len > 0) nondet else resolved;

        // Reconnaissance: determine which storage partitions this transaction will touch.
        // On retry, re-run at the seq the executor assigned to the conflicting entry so
        // hints reflect state as of that point.
        var recon_seq: Seq = self.sql_exec.committed_seq;
        var hints = try reconnaissanceScan(rq.plan, &self.partitioned, params, &self.schema, recon_seq, self.partition_count, self.alloc);
        defer hints.deinit();

        const max_retries: usize = 3;
        var attempt: usize = 0;
        while (attempt < max_retries) : (attempt += 1) {
            if (attempt > 0) {
                self.metrics.recon_retries.inc();
                // Build new hints before freeing old ones so a failed alloc leaves hints valid.
                const new_hints = try reconnaissanceScan(rq.plan, &self.partitioned, params, &self.schema, recon_seq, self.partition_count, self.alloc);
                hints.deinit();
                hints = new_hints;
            }

            // Serialize TxnIntent payload — client_seq stays constant across retries.
            var intent_buf: std.ArrayList(u8) = .empty;
            defer intent_buf.deinit(self.alloc);

            try executor_mod.serializeTxnIntent(
                &hash,
                self.client_id,
                op_seq,
                recon_seq,
                hints.read,
                hints.write,
                params_bytes,
                all_nondet,
                &intent_buf,
                self.alloc,
            );

            // Submit to Sequencer — infallible; blocks on awaitCommit
            var handle = self.sequencer.submitBytes(io, intent_buf.items, self.client_id, op_seq);
            defer if (handle.future.cancel(io)) |_| {} else |_| {};
            const result = try handle.awaitCommit(io);

            // Read committed entry from partition log
            const partition_log = self.sequencer.partitionLog(result.partition);
            const entries = try partition_log.read(result.seq, 1, self.alloc);
            defer {
                for (entries) |*e| e.deinit(self.alloc);
                self.alloc.free(entries);
            }
            if (entries.len == 0 or entries[0].header.seq != result.seq) {
                return error.ExecutionError;
            }

            // This is the domain boundary — validate the committed log entry before execution.
            var validated = executor_mod.validateTxnEntry(entries[0], self.alloc) catch {
                return error.ExecutionError;
            };
            defer validated.decoded.deinit();
            const exec_result = self.sql_exec.runValidated(validated) catch |e| {
                // Forward executor-level detail (e.g. FK violation message) to gateway detail
                const exec_detail = self.sql_exec.lastDetail();
                if (exec_detail.len > 0) self.setDetail("{s}", .{exec_detail});
                return e;
            };

            switch (exec_result) {
                .ok => |ok| return .{ .rows_affected = ok.rows_affected, .result_set = ok.result_set },
                .abort => |ab| switch (ab.code) {
                    .constraint_violation => {
                        self.metrics.queries_aborted.inc();
                        return error.ConstraintViolation;
                    },
                    .missing_query => {
                        self.metrics.queries_aborted.inc();
                        return error.QueryNotFound;
                    },
                    .retry => {
                        // Executor detected a read-set mismatch; re-run reconnaissance at
                        // the seq this entry was assigned and resubmit with updated hints.
                        recon_seq = validated.seq;
                        continue;
                    },
                    else => {
                        self.metrics.queries_aborted.inc();
                        return error.ExecutionError;
                    },
                },
            }
        }
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
            self.sql_exec.committed_seq + 1,
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
                        self.replayDdl(e.payload) catch {};
                    } else {
                        _ = self.registry.register(e.payload) catch {};
                    }
                }
                from_seq = e.header.seq + 1;
            }
            if (entries.len < batch) break;
        }

        // Pass 2: DML — apply txn_intent entries to rebuild storage state.
        // SqlExecutor.run handles CRC validation, deserialization, and committed_seq tracking.
        // Aborted results (missing query, bad params) are silently skipped — they indicate
        // entries that were rejected at runtime and should not affect recovered state.
        from_seq = 1;
        while (true) {
            const entries = try self.sequencer.partition_logs[0].read(from_seq, batch, self.alloc);
            defer {
                for (entries) |*e| e.deinit(self.alloc);
                self.alloc.free(entries);
            }
            if (entries.len == 0) break;
            for (entries) |e| {
                if (e.header.kind == .txn_intent) {
                    _ = self.sql_exec.run(e) catch {};
                } else {
                    self.sql_exec.committed_seq = e.header.seq;
                }
                from_seq = e.header.seq + 1;
            }
            if (entries.len < batch) break;
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
        try self.sequencer.partition_logs[0].appendEntryAt(entry);
    }

    /// Apply DDL during log replay (does not write to log).
    /// Silently ignores "already exists" errors — these are expected on replay.
    fn replayDdl(self: *Gateway, sql: []const u8) !void {
        self.applyDdlToSchema(sql) catch |e| switch (e) {
            error.TableAlreadyExists, error.IndexAlreadyExists, error.ColumnAlreadyExists => {},
            else => return e,
        };
    }

    fn applyDdlToSchema(self: *Gateway, sql: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();

        const parsed = try @import("sql.zig").parser.parse(sql, arena.allocator());

        if (parsed.stmts.len == 0) return;
        const stmt = parsed.stmts[0];

        self.registry.applyDdl(stmt) catch |e| {
            switch (stmt) {
                .create_table => |ct| self.setDetail("'{s}': {s}", .{ ct.name, errors.humanize(e) }),
                .create_index => |ci| self.setDetail("'{s}' on '{s}': {s}", .{ ci.name, ci.table, errors.humanize(e) }),
                .alter_table => |at| self.setDetail("'{s}': {s}", .{ at.table, errors.humanize(e) }),
                else => self.setDetail("{s}", .{errors.humanize(e)}),
            }
            return e;
        };

        switch (stmt) {
            .create_table => |ct| {
                const tbl = self.schema.getTable(ct.name) orelse return error.TableNotFound;
                try self.partitioned.registerTable(try sqlTableToStorage(tbl, self.storage_schema_arena.allocator()));
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
        try self.sequencer.addNode(node_id, addr, self.alloc);
    }

    /// Remove a sequencer node from the Raft group. Only valid on the current leader.
    pub fn removeSequencerNode(self: *Gateway, node_id: sequencer_mod.NodeId) !void {
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
        for (self.cdc.subscriptions.items) |sub| {
            if (sub.id == id) return sub;
        }
        return null;
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

/// Scan sql_text for NOW(), RANDOM(), UUID() calls (case-insensitive) and resolve each.
fn resolveNondet(sql_text: []const u8, resolver: *const NondetResolver, alloc: std.mem.Allocator) ![]ResolvedValue {
    var results: std.ArrayList(ResolvedValue) = .empty;
    errdefer results.deinit(alloc);

    var i: usize = 0;
    while (i < sql_text.len) {
        // Try to match NOW(), RANDOM(), UUID() at position i (case-insensitive).
        if (matchToken(sql_text, i, "now(")) {
            try results.append(alloc, resolver.resolveNow());
            i += 4;
        } else if (matchToken(sql_text, i, "random(")) {
            try results.append(alloc, resolver.resolveRandom());
            i += 7;
        } else if (matchToken(sql_text, i, "uuid(")) {
            try results.append(alloc, resolver.resolveUuidV7());
            i += 5;
        } else {
            i += 1;
        }
    }

    return results.toOwnedSlice(alloc);
}

fn matchToken(haystack: []const u8, pos: usize, needle: []const u8) bool {
    if (pos + needle.len > haystack.len) return false;
    for (needle, 0..) |c, j| {
        const h = haystack[pos + j];
        const hc = if (h >= 'A' and h <= 'Z') h + 32 else h;
        if (hc != c) return false;
    }
    return true;
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
        .float32 => .float32,
        .float64 => .float64,
        .string => .string,
        .bytes => .bytes,
        .uuid => .bytes,
        .timestamp => .int64,
        .interval_months, .interval_micros => .int64,
        .decimal, .json, .vector, .array, .struct_type => .bytes,
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

// ── Reconnaissance ────────────────────────────────────────────────────────────

/// Partition routing hints produced by reconnaissance.
/// Callers must call deinit() when done.
const ReconHints = struct {
    read: []executor_mod.PartitionId,
    write: []executor_mod.PartitionId,
    alloc: std.mem.Allocator,

    fn deinit(self: *ReconHints) void {
        self.alloc.free(self.read);
        self.alloc.free(self.write);
    }
};

/// Determine which storage partitions a transaction plan will read and write.
///
/// For PK lookups: hashes the encoded key to a partition ID.
/// For full-table scans and non-PK DML: enumerates actual rows in storage at
/// at_seq and hashes each row's primary key. This is correct for any
/// partition_count and produces exact partition sets rather than table-level
/// over-approximations.
fn reconnaissanceScan(
    plan: sql_mod.plan.ExecutionPlan,
    storage: *storage_mod.PartitionedStorage,
    params: []const ColumnValue,
    schema: *const sql_mod.SchemaRegistry,
    at_seq: Seq,
    partition_count: u32,
    alloc: std.mem.Allocator,
) !ReconHints {
    var read_set: std.ArrayList(executor_mod.PartitionId) = .empty;
    errdefer read_set.deinit(alloc);
    var write_set: std.ArrayList(executor_mod.PartitionId) = .empty;
    errdefer write_set.deinit(alloc);

    for (plan.stmts) |stmt| {
        switch (stmt) {
            .select => |node| try collectNodePartitions(node, storage, params, at_seq, partition_count, &read_set, alloc),
            .insert => |ins| {
                try collectInsertPartitions(ins, storage, params, schema, at_seq, partition_count, &write_set, alloc);
                if (ins.source == .query) {
                    try collectNodePartitions(ins.source.query, storage, params, at_seq, partition_count, &read_set, alloc);
                }
            },
            .update => |upd| {
                try scanTablePartitions(storage, upd.table_id, at_seq, partition_count, &write_set, alloc);
                try scanTablePartitions(storage, upd.table_id, at_seq, partition_count, &read_set, alloc);
                if (upd.from_table_id) |from_tid| {
                    try scanTablePartitions(storage, from_tid, at_seq, partition_count, &read_set, alloc);
                }
            },
            .delete => |del| {
                try scanTablePartitions(storage, del.table_id, at_seq, partition_count, &write_set, alloc);
                try scanTablePartitions(storage, del.table_id, at_seq, partition_count, &read_set, alloc);
                for (del.using_table_ids) |tid| {
                    try scanTablePartitions(storage, tid, at_seq, partition_count, &read_set, alloc);
                }
            },
            .merge => |mrg| {
                try scanTablePartitions(storage, mrg.target_id, at_seq, partition_count, &write_set, alloc);
                try scanTablePartitions(storage, mrg.target_id, at_seq, partition_count, &read_set, alloc);
                try collectNodePartitions(mrg.source, storage, params, at_seq, partition_count, &read_set, alloc);
            },
            .assert => {},
        }
    }

    return .{
        .read = try read_set.toOwnedSlice(alloc),
        .write = try write_set.toOwnedSlice(alloc),
        .alloc = alloc,
    };
}

/// Map an encoded storage key to a partition ID by hashing.
fn keyToPartitionId(key: []const u8, partition_count: u32) executor_mod.PartitionId {
    if (partition_count <= 1) return 0;
    const h = std.hash.Wyhash.hash(0, key);
    return @intCast(h % partition_count);
}

/// Append a partition ID to a list only if not already present.
fn appendPartitionUnique(
    list: *std.ArrayList(executor_mod.PartitionId),
    val: executor_mod.PartitionId,
    alloc: std.mem.Allocator,
) !void {
    for (list.items) |item| {
        if (item == val) return;
    }
    try list.append(alloc, val);
}

/// Scan all rows in a table at at_seq and collect their partition IDs.
/// Silently skips tables not yet registered in storage (no rows, no partitions).
fn scanTablePartitions(
    storage: *storage_mod.PartitionedStorage,
    table_id: storage_mod.TableId,
    at_seq: Seq,
    partition_count: u32,
    out: *std.ArrayList(executor_mod.PartitionId),
    alloc: std.mem.Allocator,
) !void {
    var it = storage.scan(table_id, storage_mod.KeyRange.all(), at_seq, alloc) catch |err| switch (err) {
        error.TableNotFound => return,
        else => return err,
    };
    defer it.deinit();
    while (try it.next()) |row| {
        try appendPartitionUnique(out, keyToPartitionId(row.key, partition_count), alloc);
    }
}

/// Try to evaluate a plan expression to a concrete ColumnValue using the bound params.
/// Returns null for expressions that require execution-time context (columns, subqueries, etc.).
fn evalLiteralExpr(expr: *const sql_mod.plan.PlanExpr, params: []const ColumnValue) ?ColumnValue {
    return switch (expr.*) {
        .param => |n| if (n < params.len) params[n] else null,
        .string_literal => |s| ColumnValue{ .string = s },
        .int_literal => |n| ColumnValue{ .int64 = n },
        .uint_literal => |n| ColumnValue{ .uint64 = n },
        .bool_literal => |b| ColumnValue{ .bool_t = b },
        .bytes_literal => |b| ColumnValue{ .bytes = b },
        else => null,
    };
}

/// Encode a single literal expression as a storage key component.
/// Returns an owned slice, or null if the expression is not statically evaluable.
fn encodeLiteralKey(expr: *const sql_mod.plan.PlanExpr, params: []const ColumnValue, alloc: std.mem.Allocator) ?[]const u8 {
    const val = evalLiteralExpr(expr, params) orelse return null;
    var buf: std.ArrayList(u8) = .empty;
    sql_mod.key_encode.encodeKeyComponent(&buf, val, alloc) catch {
        buf.deinit(alloc);
        return null;
    };
    return buf.toOwnedSlice(alloc) catch {
        buf.deinit(alloc);
        return null;
    };
}

/// Try to build the encoded primary key for a row in an INSERT VALUES clause.
/// Returns null if any PK column's expression cannot be statically evaluated.
/// Caller owns the returned slice.
fn extractInsertRowKey(
    tbl: *const sql_mod.schema.TableSchema,
    column_ids: []const sql_mod.schema.ColumnId,
    row_exprs: []const *sql_mod.plan.PlanExpr,
    params: []const ColumnValue,
    alloc: std.mem.Allocator,
) ?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (tbl.primary_key) |pk_col_id| {
        const idx: usize = blk: {
            for (column_ids, 0..) |cid, i| {
                if (cid == pk_col_id) break :blk i;
            }
            buf.deinit(alloc);
            return null;
        };
        if (idx >= row_exprs.len) {
            buf.deinit(alloc);
            return null;
        }
        const val = evalLiteralExpr(row_exprs[idx], params) orelse {
            buf.deinit(alloc);
            return null;
        };
        sql_mod.key_encode.encodeKeyComponent(&buf, val, alloc) catch {
            buf.deinit(alloc);
            return null;
        };
    }
    return buf.toOwnedSlice(alloc) catch {
        buf.deinit(alloc);
        return null;
    };
}

/// Collect write partitions for an INSERT plan.
/// For VALUES rows where the PK can be statically determined, hashes the key.
/// Falls back to partition 0 for rows whose PK expressions are complex.
fn collectInsertPartitions(
    ins: sql_mod.plan.InsertPlan,
    storage: *storage_mod.PartitionedStorage,
    params: []const ColumnValue,
    schema: *const sql_mod.SchemaRegistry,
    at_seq: Seq,
    partition_count: u32,
    out: *std.ArrayList(executor_mod.PartitionId),
    alloc: std.mem.Allocator,
) !void {
    if (ins.source == .query) {
        // Can't determine write keys statically; scan for current rows as over-approximation.
        try scanTablePartitions(storage, ins.table_id, at_seq, partition_count, out, alloc);
        return;
    }
    const tbl = schema.getTableById(ins.table_id) orelse {
        try appendPartitionUnique(out, 0, alloc);
        return;
    };
    for (ins.source.values) |row_exprs| {
        if (extractInsertRowKey(tbl, ins.column_ids, row_exprs, params, alloc)) |key| {
            defer alloc.free(key);
            try appendPartitionUnique(out, keyToPartitionId(key, partition_count), alloc);
        } else {
            try appendPartitionUnique(out, 0, alloc);
        }
    }
}

/// Walk a plan node tree and collect the storage partition IDs for every table read.
/// For pk_lookup: hashes the key expression if it can be statically evaluated.
/// For scan and DML nodes: enumerates rows from storage.
fn collectNodePartitions(
    node: *const sql_mod.plan.PlanNode,
    storage: *storage_mod.PartitionedStorage,
    params: []const ColumnValue,
    at_seq: Seq,
    partition_count: u32,
    out: *std.ArrayList(executor_mod.PartitionId),
    alloc: std.mem.Allocator,
) !void {
    switch (node.*) {
        .scan => |s| try scanTablePartitions(storage, s.table_id, at_seq, partition_count, out, alloc),
        .pk_lookup => |pk| {
            // key_expr evaluates to the full encoded PK. Hash it if statically known.
            const maybe_key = encodeLiteralKey(pk.key_expr, params, alloc);
            if (maybe_key) |key| {
                defer alloc.free(key);
                try appendPartitionUnique(out, keyToPartitionId(key, partition_count), alloc);
            } else {
                try scanTablePartitions(storage, pk.table_id, at_seq, partition_count, out, alloc);
            }
        },
        .filter => |f| try collectNodePartitions(f.input, storage, params, at_seq, partition_count, out, alloc),
        .project => |p| try collectNodePartitions(p.input, storage, params, at_seq, partition_count, out, alloc),
        .sort => |s| try collectNodePartitions(s.input, storage, params, at_seq, partition_count, out, alloc),
        .limit => |l| try collectNodePartitions(l.input, storage, params, at_seq, partition_count, out, alloc),
        .hash_agg => |h| try collectNodePartitions(h.input, storage, params, at_seq, partition_count, out, alloc),
        .hash_join => |j| {
            try collectNodePartitions(j.left, storage, params, at_seq, partition_count, out, alloc);
            try collectNodePartitions(j.right, storage, params, at_seq, partition_count, out, alloc);
        },
        .window => |w| try collectNodePartitions(w.input, storage, params, at_seq, partition_count, out, alloc),
        .insert => |ins| {
            try scanTablePartitions(storage, ins.table_id, at_seq, partition_count, out, alloc);
            if (ins.source == .query) {
                try collectNodePartitions(ins.source.query, storage, params, at_seq, partition_count, out, alloc);
            }
        },
        .update => |upd| try scanTablePartitions(storage, upd.table_id, at_seq, partition_count, out, alloc),
        .delete => |del| try scanTablePartitions(storage, del.table_id, at_seq, partition_count, out, alloc),
        .merge => |mrg| {
            try scanTablePartitions(storage, mrg.target_id, at_seq, partition_count, out, alloc);
            try collectNodePartitions(mrg.source, storage, params, at_seq, partition_count, out, alloc);
        },
        .ann_scan => |s| try scanTablePartitions(storage, s.table_id, at_seq, partition_count, out, alloc),
        .assert, .empty, .single_row => {},
    }
}
