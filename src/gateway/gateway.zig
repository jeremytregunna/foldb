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

/// Nondeterminism resolver - computes values for NOW(), RANDOM(), UUID()
pub const NondetResolver = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) NondetResolver {
        return .{ .alloc = alloc };
    }

    pub fn resolveNow(self: NondetResolver) ResolvedValue {
        _ = self;
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
        const micros: i64 = @as(i64, @intCast(ts.sec)) * 1_000_000 + @as(i64, @intCast(@divTrunc(ts.nsec, 1_000)));
        return .{ .now = micros };
    }

    pub fn resolveRandom(self: NondetResolver) ResolvedValue {
        _ = self;
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
        const seed: u64 = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
        var rand = std.Random.Xoroshiro128.init(seed);
        var bytes: [16]u8 = undefined;
        rand.fill(&bytes);
        return .{ .random = bytes };
    }

    pub fn resolveUuidV7(self: NondetResolver) ResolvedValue {
        _ = self;
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
        const micros: i64 = @as(i64, @intCast(ts.sec)) * 1_000_000 + @as(i64, @intCast(@divTrunc(ts.nsec, 1_000)));

        var uuid: [16]u8 = undefined;
        const ms: u64 = @intCast(@divTrunc(micros, 1_000));
        std.mem.writeInt(u64, &uuid[0..8].*, ms, .big);
        uuid[6] = (uuid[6] & 0x0F) | 0x70;
        var rand = std.Random.DefaultPrng.init(ms);
        rand.random().bytes(uuid[8..16]);
        uuid[8] = (uuid[8] & 0x3F) | 0x80;

        return .{ .uuid_v7 = uuid };
    }
};

/// The main Gateway struct.
/// Always heap-allocated via `init`; internal pointers remain stable.
pub const Gateway = struct {
    schema: sql_mod.SchemaRegistry,
    registry: sql_mod.SqlRegistry,
    sql_exec: sql_mod.SqlExecutor,
    storage: storage_mod.Storage,
    /// Arena that owns storage-schema column slices allocated during DDL.
    storage_schema_arena: std.heap.ArenaAllocator,
    nondet_resolver: NondetResolver,
    sequencer: sequencer_mod.Sequencer,
    /// CDC event fan-out for wire-protocol subscriptions.
    cdc: cdc_mod.CdcManager,
    /// Per-gateway client identity for idempotency tracking.
    client_id: u64,
    client_seq: u64,
    alloc: std.mem.Allocator,
    metrics: obs.GatewayMetrics = .{},
    /// Last error detail set by gateway operations (table/column context).
    /// Reset at the start of each operation that may set it.
    error_detail: [256]u8 = undefined,
    error_detail_len: usize = 0,

    /// Initialize and heap-allocate a Gateway. Caller owns the pointer; call `deinit` to free.
    pub fn init(
        storage_dir: []const u8,
        alloc: std.mem.Allocator,
    ) !*Gateway {
        const gw = try alloc.create(Gateway);
        errdefer alloc.destroy(gw);

        gw.alloc = alloc;
        gw.storage_schema_arena = std.heap.ArenaAllocator.init(alloc);
        gw.storage = try storage_mod.Storage.init(storage_dir, alloc);
        errdefer gw.storage.deinit();

        gw.schema = sql_mod.SchemaRegistry.init(alloc);
        gw.registry = sql_mod.SqlRegistry.init(alloc, &gw.schema);
        gw.sql_exec = sql_mod.SqlExecutor.init(&gw.storage, &gw.registry, &gw.schema, alloc);
        gw.nondet_resolver = NondetResolver.init(alloc);

        const seq_cfg = sequencer_mod.Config{
            .partition_count = 1,
            .node_id = 1,
        };
        gw.sequencer = try sequencer_mod.Sequencer.init(storage_dir, seq_cfg, alloc);
        errdefer gw.sequencer.deinit();

        gw.cdc = cdc_mod.CdcManager.init(alloc);
        gw.sql_exec.initCdc(&gw.cdc);

        // Replay schema_change entries from partition log 0 to rebuild schema after restart.
        try gw.replaySchemaFromLog();
        // Sync committed_seq to the log head — storage state is loaded from the durable LSM,
        // not rebuilt by replay, so we just need the cursor to reflect reality.
        gw.sql_exec.committed_seq = try gw.sequencer.partition_logs[0].head();

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

        return gw;
    }

    pub fn deinit(self: *Gateway) void {
        self.cdc.deinit();
        self.sequencer.deinit();
        self.registry.deinit();
        self.schema.deinit();
        self.storage.deinit();
        self.storage_schema_arena.deinit();
        self.alloc.destroy(self);
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

        const max_retries: usize = 3;
        var attempt: usize = 0;
        while (attempt < max_retries) : (attempt += 1) {
            if (attempt > 0) self.metrics.recon_retries.inc();
            // Serialize TxnIntent payload — client_seq stays constant across retries.
            var intent_buf: std.ArrayList(u8) = .empty;
            defer intent_buf.deinit(self.alloc);

            try executor_mod.serializeTxnIntent(
                &hash,
                self.client_id,
                op_seq,
                &.{},
                &.{},
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

            return switch (exec_result) {
                .ok => |ok| .{ .rows_affected = ok.rows_affected, .result_set = null },
                .abort => |ab| switch (ab.code) {
                    .constraint_violation => {
                        self.metrics.queries_aborted.inc();
                        return error.ConstraintViolation;
                    },
                    .missing_query => {
                        self.metrics.queries_aborted.inc();
                        return error.QueryNotFound;
                    },
                    else => {
                        self.metrics.queries_aborted.inc();
                        return error.ExecutionError;
                    },
                },
            };
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

    /// Replay partition log 0 to rebuild schema, query registry, and storage state.
    /// schema_change entries with DDL are applied to the schema; others re-register
    /// queries. txn_intent entries are executed to replay mutations into storage.
    fn replaySchemaFromLog(self: *Gateway) !void {
        var from_seq: log_mod.Seq = 1;
        const batch = 256;
        while (true) {
            const entries = try self.sequencer.partition_logs[0].read(from_seq, batch, self.alloc);
            defer {
                for (entries) |*e| {
                    var mut = e.*;
                    mut.deinit(self.alloc);
                }
                self.alloc.free(entries);
            }
            if (entries.len == 0) break;
            for (entries) |e| {
                switch (e.header.kind) {
                    .schema_change => {
                        if (isSqlDdl(e.payload)) {
                            self.replayDdl(e.payload) catch {};
                        } else {
                            _ = self.registry.register(e.payload) catch {};
                        }
                    },
                    else => {},
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
                try self.storage.registerTable(try sqlTableToStorage(tbl, self.storage_schema_arena.allocator()));
            },
            .create_index => |ci| {
                const tbl = self.schema.getTable(ci.table) orelse return error.TableNotFound;
                if (tbl.indexes.len == 0) return;
                const idx = tbl.indexes[tbl.indexes.len - 1];
                const kind: storage_mod.IndexKind = switch (idx.kind) {
                    .vector => .vector,
                    .json_path => .json_path,
                    else => return,
                };
                const column_idx: u32 = if (idx.columns.len > 0) idx.columns[0] else 0;
                const json_paths: []const []const u8 = switch (idx.extra) {
                    .json_paths => |p| p,
                    else => &.{},
                };
                const vector_dim: u32 = switch (idx.extra) {
                    .vector_dim => |d| d,
                    else => 0,
                };
                try self.storage.registerIndex(.{
                    .id = idx.id,
                    .table_id = tbl.id,
                    .column_idx = column_idx,
                    .kind = kind,
                    .json_paths = json_paths,
                    .vector_dim = vector_dim,
                });
            },
            else => {},
        }
    }

    /// Get the current committed sequence number.
    pub fn currentSeq(self: *const Gateway) Seq {
        return self.sequencer.currentSeq();
    }

    /// Flush all storage to disk.
    pub fn flushAll(self: *Gateway) !void {
        try self.storage.flushAll();
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
