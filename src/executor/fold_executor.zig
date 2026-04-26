/// FoldExecutor: applies committed log entries on a dedicated OS thread.
/// Owns schema, registry, and sql_exec. Runs one thread per instance that
/// reads from partition logs and applies entries in sequence order.
const std = @import("std");
const sql_mod = @import("sql.zig");
const storage_mod = @import("storage.zig");
const log_mod = @import("log.zig");
const cdc_mod = @import("cdc.zig");
const executor_bridge = @import("executor_bridge.zig");

const assert = std.debug.assert;
const Seq = log_mod.Seq;
const LogEntry = log_mod.LogEntry;

pub const ExecResult = executor_bridge.ExecResult;
pub const ResolvedValue = executor_bridge.ResolvedValue;

pub const FoldExecutor = struct {
    schema: sql_mod.SchemaRegistry,
    registry: sql_mod.SqlRegistry,
    sql_exec: sql_mod.SqlExecutor,
    /// Arena for storage-layer column slice allocations during DDL. Owned.
    storage_schema_arena: std.heap.ArenaAllocator,
    /// Routing layer over storage partitions. Borrowed from Gateway.
    partitioned: *storage_mod.PartitionedStorage,
    /// Partition log for this executor. Borrowed from Sequencer (stable pointer).
    log: *log_mod.Log,
    /// Which partition this executor services.
    partition_id: u32,
    /// CPU to pin this executor's thread to.
    cpu_id: u32,
    shutdown: std.atomic.Value(bool),
    thread: ?std.Thread,
    alloc: std.mem.Allocator,

    pub fn init(
        partitioned: *storage_mod.PartitionedStorage,
        cdc: *cdc_mod.CdcManager,
        log: *log_mod.Log,
        partition_id: u32,
        cpu_id: u32,
        alloc: std.mem.Allocator,
    ) !*FoldExecutor {
        const fe = try alloc.create(FoldExecutor);
        errdefer alloc.destroy(fe);
        fe.alloc = alloc;
        fe.storage_schema_arena = std.heap.ArenaAllocator.init(alloc);
        fe.partitioned = partitioned;
        fe.log = log;
        fe.partition_id = partition_id;
        fe.cpu_id = cpu_id;
        fe.shutdown = .init(false);
        fe.thread = null;
        fe.schema = sql_mod.SchemaRegistry.init(alloc);
        fe.registry = sql_mod.SqlRegistry.init(alloc, &fe.schema);
        fe.sql_exec = sql_mod.SqlExecutor.init(partitioned, &fe.registry, &fe.schema, alloc);
        fe.sql_exec.initCdc(cdc);
        return fe;
    }

    pub fn deinit(self: *FoldExecutor) void {
        self.registry.deinit();
        self.schema.deinit();
        self.storage_schema_arena.deinit();
        self.alloc.destroy(self);
    }

    pub fn start(self: *FoldExecutor) !void {
        assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, threadLoop, .{self});
    }

    pub fn stop(self: *FoldExecutor) void {
        self.shutdown.store(true, .release);
        self.log.notifyAppend();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn threadLoop(self: *FoldExecutor) void {
        pinToCpu(self.cpu_id);
        const batch = 64;
        while (!self.shutdown.load(.acquire)) {
            const from = self.sql_exec.current_seq() + 1;
            const entries = self.log.read(from, batch, self.alloc) catch continue;
            defer {
                for (entries) |*e| e.deinit(self.alloc);
                self.alloc.free(entries);
            }
            if (entries.len == 0) {
                if (self.shutdown.load(.acquire)) break;
                self.log.waitForEntries(from);
                continue;
            }
            for (entries) |e| {
                self.applyEntry(e);
            }
        }
    }

    fn pinToCpu(cpu_id: u32) void {
        var cpu_set = std.mem.zeroes(std.os.linux.cpu_set_t);
        const elem = cpu_id / @bitSizeOf(usize);
        if (elem < cpu_set.len) {
            cpu_set[elem] |= @as(usize, 1) << @intCast(cpu_id % @bitSizeOf(usize));
        }
        std.os.linux.sched_setaffinity(0, &cpu_set) catch |err| {
            std.log.warn("FoldExecutor[{d}]: CPU pin to {d} failed: {}", .{ cpu_id, cpu_id, err });
        };
    }

    fn applyEntry(self: *FoldExecutor, entry: LogEntry) void {
        switch (entry.header.kind) {
            .schema_change => {
                if (isSqlDdl(entry.payload)) {
                    self.replayDdl(entry.payload) catch |err| {
                        std.log.warn("FoldExecutor: DDL replay err={}", .{err});
                    };
                } else {
                    _ = self.registry.register(entry.payload) catch {};
                }
                self.sql_exec.advanceSeq(entry.header.seq);
            },
            .txn_intent => {
                // Run always advances committed_seq, even on error, to prevent infinite retry.
                _ = self.sql_exec.run(entry) catch |err| {
                    std.log.warn("FoldExecutor: run seq={d} err={}", .{ entry.header.seq, err });
                    self.sql_exec.advanceSeq(entry.header.seq);
                };
            },
            // Route all non-txn entries through sql_exec.run so snapshot_marker
            // entries trigger notify_snapshot on the log.
            else => _ = self.sql_exec.run(entry) catch |err| {
                std.log.warn("FoldExecutor: run seq={d} err={}", .{ entry.header.seq, err });
                self.sql_exec.advanceSeq(entry.header.seq);
            },
        }
    }

    // ---- Schema / DDL ----

    /// Validate and apply DDL to local schema. Called by Gateway before Raft submission.
    pub fn applyDdlLocal(self: *FoldExecutor, sql: []const u8) !void {
        try self.applyDdlToSchema(sql);
    }

    fn replayDdl(self: *FoldExecutor, sql: []const u8) !void {
        self.applyDdlToSchema(sql) catch |e| switch (e) {
            error.TableAlreadyExists,
            error.IndexAlreadyExists,
            error.ColumnAlreadyExists,
            error.ColumnNotFound,  // DROP COLUMN replay when already applied locally
            error.TableNotFound,
            => {},
            else => return e,
        };
    }

    fn applyDdlToSchema(self: *FoldExecutor, sql: []const u8) !void {
        assert(sql.len > 0);
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();

        var parser = sql_mod.parser.Parser.init(sql, arena.allocator());
        const parsed = try parser.parseQuery();

        if (parsed.stmts.len == 0) return;
        const stmt = parsed.stmts[0];

        const drop_table_id: ?storage_mod.TableId = if (stmt == .drop_table) blk: {
            const dt = stmt.drop_table;
            const tbl = self.schema.getTable(dt.name) orelse {
                if (dt.if_exists) return;
                break :blk null;
            };
            break :blk tbl.id;
        } else null;

        try self.registry.applyDdl(stmt);

        switch (stmt) {
            .create_table => |ct| {
                const tbl = self.schema.getTable(ct.name) orelse return error.TableNotFound;
                try self.partitioned.registerTable(
                    try sqlTableToStorage(tbl, self.storage_schema_arena.allocator()),
                );
            },
            .drop_table => {
                if (drop_table_id) |id| self.partitioned.unregisterTable(id);
            },
            .create_index => |ci| {
                const tbl = self.schema.getTable(ci.table) orelse return error.TableNotFound;
                if (tbl.indexes.len == 0) return;
                const idx = tbl.indexes[tbl.indexes.len - 1];
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

    // ---- Query Registration ----

    /// Validate SQL against the current schema and register it locally.
    /// Safe to call from the gateway thread when FoldExecutor is idle (i.e., after wait_for
    /// returns and before Raft submission of this entry). If validation fails (e.g. column
    /// not found), the error is returned and the caller must not submit to Raft.
    pub fn registerLocal(self: *FoldExecutor, sql: []const u8) !sql_mod.QueryHash {
        return self.registry.register(sql);
    }

    /// Compute the canonical hash of a SQL string without registering it.
    /// Pure computation — safe to call from any thread concurrently.
    pub fn computeQueryHash(self: *const FoldExecutor, sql: []const u8) !sql_mod.QueryHash {
        return sql_mod.computeQueryHash(sql, self.alloc);
    }

    pub fn schemaVersion(self: *const FoldExecutor) u64 {
        return self.registry.schema_seq;
    }

    // ---- Seq tracking ----

    pub fn current_seq(self: *const FoldExecutor) Seq {
        return self.sql_exec.current_seq();
    }

    /// Wait until FoldExecutor has processed target seq.
    /// Suspends the fiber with io.sleep(100µs) so other fibers can run.
    pub fn wait_for(self: *FoldExecutor, target: Seq, io: ?std.Io) !void {
        while (self.sql_exec.current_seq() < target) {
            if (io) |the_io| {
                try the_io.sleep(.{ .nanoseconds = 100_000 }, .awake);
            } else {
                std.Thread.yield() catch {};
            }
        }
    }

    /// Return the ExecResult for seq. Caller must have called wait_for(seq) first.
    pub fn waitFor(self: *FoldExecutor, seq: Seq) ExecResult {
        return self.sql_exec.waitFor(seq);
    }

    pub fn lastExecDetail(self: *const FoldExecutor) []const u8 {
        return self.sql_exec.lastDetail();
    }

    // ---- Query execution ----

    /// Look up a registered query. Returns null if not found.
    /// The returned pointer is stable — RegisteredQuery is heap-allocated and never moved.
    pub fn lookupQuery(self: *const FoldExecutor, hash: sql_mod.QueryHash) ?*const sql_mod.RegisteredQuery {
        return self.registry.lookup(hash);
    }

    pub fn isSelectQuery(self: *const FoldExecutor, hash: sql_mod.QueryHash) bool {
        const rq = self.registry.lookup(hash) orelse return false;
        for (rq.plan.stmts) |stmt| {
            switch (stmt) {
                .select, .describe_table => {},
                else => return false,
            }
        }
        return true;
    }

    pub fn querySelect(
        self: *FoldExecutor,
        hash: sql_mod.QueryHash,
        params: []const storage_mod.ColumnValue,
        nondet: []const ResolvedValue,
        alloc: std.mem.Allocator,
    ) !sql_mod.ResultSet {
        // RegisteredQuery is heap-allocated and never freed (no unregister operation).
        // The acquire/release on committed_seq provides happens-before with FoldExecutor's
        // writes; after wait_for() returns the registry state for this query is stable.
        const rq = self.registry.lookup(hash) orelse return error.QueryNotFound;

        if (rq.plan.stmts.len > 0 and rq.plan.stmts[0] == .describe_table) {
            return self.buildDescribeResult(rq.plan.stmts[0].describe_table, alloc);
        }

        const decoded_params = try decodeParams(params, rq.param_types, alloc);
        defer alloc.free(decoded_params);

        var rows = try self.sql_exec.querySelect(
            rq.plan,
            decoded_params,
            nondet,
            self.sql_exec.current_seq() + 1,
            alloc,
        );
        const rows_slice = try rows.toOwnedSlice(alloc);
        // Column names were pre-computed at registration time — no schema access needed.
        const columns_slice = try dupeStringSlice(rq.output_column_names, alloc);

        return sql_mod.ResultSet{
            .columns = columns_slice,
            .rows = rows_slice,
            .alloc = alloc,
        };
    }

    pub fn readAt(
        self: *FoldExecutor,
        hash: sql_mod.QueryHash,
        params: []const storage_mod.ColumnValue,
        seq: Seq,
        alloc: std.mem.Allocator,
    ) !sql_mod.ResultSet {
        const rq = self.registry.lookup(hash) orelse return error.QueryNotFound;

        const decoded_params = try decodeParams(params, rq.param_types, alloc);
        defer alloc.free(decoded_params);

        var rows = try self.sql_exec.querySelect(rq.plan, decoded_params, &.{}, seq + 1, alloc);
        const rows_slice = try rows.toOwnedSlice(alloc);
        const columns_slice = try dupeStringSlice(rq.output_column_names, alloc);

        return sql_mod.ResultSet{
            .columns = columns_slice,
            .rows = rows_slice,
            .alloc = alloc,
        };
    }

    // ---- Schema queries ----

    pub fn resolveTableName(self: *const FoldExecutor, name: []const u8) ?u32 {
        const tbl = self.schema.getTable(name) orelse return null;
        return tbl.id;
    }

    pub fn tableIdExists(self: *const FoldExecutor, id: u32) bool {
        return self.schema.getTableById(id) != null;
    }

    // ---- Startup replay ----

    /// Replay all committed log entries synchronously. Called by Gateway.init() before start().
    pub fn replayFromLog(self: *FoldExecutor) !void {
        const batch = 256;

        // Pass 1: schema — DDL and query registration only.
        var from_seq: Seq = 1;
        while (true) {
            const entries = try self.log.read(from_seq, batch, self.alloc);
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
        from_seq = 1;
        while (true) {
            const entries = try self.log.read(from_seq, batch, self.alloc);
            defer {
                for (entries) |*e| e.deinit(self.alloc);
                self.alloc.free(entries);
            }
            if (entries.len == 0) break;
            for (entries) |e| {
                if (e.header.kind == .txn_intent) {
                    const r = try self.sql_exec.run(e);
                    // Free any RETURNING result set — nobody reads it during replay
                    if (r == .ok) if (r.ok.result_set) |rs| {
                        var mutable = rs;
                        mutable.deinit();
                    };
                } else {
                    self.sql_exec.advanceSeq(e.header.seq);
                }
                from_seq = e.header.seq + 1;
            }
            if (entries.len < batch) break;
        }
    }

    // ---- Private helpers ----

    fn buildDescribeResult(self: *FoldExecutor, table_name: []const u8, alloc: std.mem.Allocator) !sql_mod.ResultSet {
        assert(table_name.len > 0);
        const tbl = self.schema.getTable(table_name) orelse return error.TableNotFound;
        assert(tbl.columns.len <= std.math.maxInt(u32));

        const col_names = [_][]const u8{ "column", "type", "nullable", "primary_key" };
        const columns = try alloc.alloc([]const u8, col_names.len);
        errdefer alloc.free(columns);
        for (col_names, 0..) |n, i| columns[i] = try alloc.dupe(u8, n);

        const rows = try alloc.alloc([]const ?storage_mod.ColumnValue, tbl.columns.len);
        errdefer alloc.free(rows);
        var built: usize = 0;
        errdefer for (rows[0..built]) |r| {
            for (r) |v| if (v) |cv| cv.freeIfOwned(alloc);
            alloc.free(r);
        };

        for (tbl.columns, 0..) |col, i| {
            var is_pk = false;
            for (tbl.primary_key) |pk_id| {
                if (pk_id == col.id) { is_pk = true; break; }
            }
            const type_str = try sqlTypeStr(col.typ, alloc);
            const row = try alloc.alloc(?storage_mod.ColumnValue, 4);
            row[0] = .{ .string = try alloc.dupe(u8, col.name) };
            row[1] = .{ .string = type_str };
            row[2] = .{ .string = try alloc.dupe(u8, if (col.nullable == .nullable) "YES" else "NO") };
            row[3] = .{ .string = try alloc.dupe(u8, if (is_pk) "YES" else "NO") };
            rows[i] = row;
            built += 1;
        }
        return sql_mod.ResultSet{ .columns = columns, .rows = rows, .alloc = alloc };
    }
};

fn dupeStringSlice(src: []const []const u8, alloc: std.mem.Allocator) ![][]const u8 {
    const dst = try alloc.alloc([]const u8, src.len);
    for (src, 0..) |s, i| dst[i] = try alloc.dupe(u8, s);
    return dst;
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

fn decodeParams(
    params: []const storage_mod.ColumnValue,
    param_types: []const sql_mod.ast.SqlType,
    alloc: std.mem.Allocator,
) ![]const storage_mod.ColumnValue {
    if (param_types.len > 0 and params.len != param_types.len) return error.ParamDecodeError;
    return try alloc.dupe(storage_mod.ColumnValue, params);
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

fn sqlTypeStr(t: sql_mod.ast.SqlType, alloc: std.mem.Allocator) ![]u8 {
    return switch (t) {
        .bool => alloc.dupe(u8, "bool"),
        .int8 => alloc.dupe(u8, "int8"),
        .int16 => alloc.dupe(u8, "int16"),
        .int32 => alloc.dupe(u8, "int32"),
        .int64 => alloc.dupe(u8, "int64"),
        .uint8 => alloc.dupe(u8, "uint8"),
        .uint16 => alloc.dupe(u8, "uint16"),
        .uint32 => alloc.dupe(u8, "uint32"),
        .uint64 => alloc.dupe(u8, "uint64"),
        .decimal => |d| std.fmt.allocPrint(alloc, "decimal({d},{d})", .{ d.precision, d.scale }),
        .string => alloc.dupe(u8, "string"),
        .bytes => alloc.dupe(u8, "bytes"),
        .uuid => alloc.dupe(u8, "uuid"),
        .timestamp => alloc.dupe(u8, "timestamp"),
        .interval_months => alloc.dupe(u8, "interval_months"),
        .interval_micros => alloc.dupe(u8, "interval_micros"),
        .json => alloc.dupe(u8, "json"),
        .vector => |dim| std.fmt.allocPrint(alloc, "vector({d})", .{dim}),
        .array => alloc.dupe(u8, "array"),
        .struct_type => alloc.dupe(u8, "struct"),
        .null_type => alloc.dupe(u8, "null"),
    };
}

