/// Foldb Gateway (M6): client-facing entry point for query registration and execution.
///
/// Handles:
/// - Query registration (SQL → QueryHash with schema-version pinning)
/// - Query execution (execute registered queries with params)
/// - Historical reads (read at specific seq)
///
/// For M6 (single partition), the execute path calls the executor directly
/// without the Sequencer.
const std = @import("std");

const sql_mod = @import("sql.zig");
const storage_mod = @import("storage.zig");
const executor_mod = @import("executor.zig");

pub const QueryHash = sql_mod.QueryHash;
pub const Seq = @import("types.zig").Seq;
pub const ResolvedValue = @import("types.zig").ResolvedValue;
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
};

/// Nondeterminism resolver - computes values for NOW(), RANDOM(), UUID()
pub const NondetResolver = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) NondetResolver {
        return .{ .alloc = alloc };
    }

    /// Resolve a nondeterministic value.
    pub fn resolveNow(self: NondetResolver) ResolvedValue {
        _ = self;
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
        const micros: i64 = @as(i64, @intCast(ts.sec)) * 1_000_000 + @as(i64, @intCast(@divTrunc(ts.nsec, 1_000)));
        return .{ .now = micros };
    }

    /// Resolve a random 128-bit value.
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

    /// Resolve a UUID v7 (time-based).
    pub fn resolveUuidV7(self: NondetResolver) ResolvedValue {
        _ = self;
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
        const micros: i64 = @as(i64, @intCast(ts.sec)) * 1_000_000 + @as(i64, @intCast(@divTrunc(ts.nsec, 1_000)));

        var uuid: [16]u8 = undefined;
        const ms: u64 = @intCast(@divTrunc(micros, 1_000));
        std.mem.writeInt(u64, &uuid[0..8].*, ms, .big);
        // Version 7: bits 12-15 of byte 6
        uuid[6] = (uuid[6] & 0x0F) | 0x70;
        // Randomize bytes 8-16 first, then apply variant bits
        var rand = std.Random.DefaultPrng.init(ms);
        rand.random().bytes(uuid[8..16]);
        // Variant: bits 6-7 of byte 8 (must be set AFTER randomizing)
        uuid[8] = (uuid[8] & 0x3F) | 0x80;

        return .{ .uuid_v7 = uuid };
    }
};

/// The main Gateway struct.
/// Always heap-allocated via `init`; internal pointers remain stable.
pub const Gateway = struct {
    schema: sql_mod.SchemaRegistry,
    registry: sql_mod.SqlRegistry,
    executor: sql_mod.SqlExecutor,
    storage: storage_mod.Storage,
    /// Arena that owns storage-schema column slices allocated during DDL.
    storage_schema_arena: std.heap.ArenaAllocator,
    nondet_resolver: NondetResolver,
    alloc: std.mem.Allocator,

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
        gw.executor = sql_mod.SqlExecutor.init(&gw.storage, &gw.registry, &gw.schema, alloc);
        gw.nondet_resolver = NondetResolver.init(alloc);

        return gw;
    }

    /// Clean up gateway resources and free the heap-allocated Gateway.
    pub fn deinit(self: *Gateway) void {
        self.registry.deinit();
        self.schema.deinit();
        self.storage.deinit();
        self.storage_schema_arena.deinit();
        self.alloc.destroy(self);
    }

    /// Register a SQL query and return its hash with schema version.
    /// Idempotent: registering the same SQL twice returns the same hash.
    pub fn register(self: *Gateway, sql: []const u8) !RegisterResult {
        const hash = try self.registry.register(sql);
        return .{
            .hash = hash,
            .schema_version = self.registry.schema_seq,
        };
    }

    /// Execute a registered DML query (INSERT/UPDATE/DELETE) with the given parameters.
    /// For M6 (single partition), this calls the executor directly without a Sequencer.
    pub fn execute(
        self: *Gateway,
        hash: QueryHash,
        params: []const ColumnValue,
        nondet: []const ResolvedValue,
    ) !ExecResult {
        const rq = self.registry.lookup(hash) orelse return error.QueryNotFound;

        const decoded_params = try decodeParams(params, rq.param_types, self.alloc);
        defer self.alloc.free(decoded_params);

        const seq = self.executor.committed_seq + 1;
        const rows_affected = try self.executor.executePlanDirect(
            rq.plan,
            decoded_params,
            nondet,
            seq,
        );
        self.executor.committed_seq = seq;

        return .{
            .rows_affected = rows_affected,
            .result_set = null,
        };
    }

    /// Execute a SELECT query and return the result set.
    pub fn querySelect(
        self: *Gateway,
        hash: QueryHash,
        params: []const ColumnValue,
        nondet: []const ResolvedValue,
    ) !ResultSet {
        const rq = self.registry.lookup(hash) orelse return error.QueryNotFound;

        const decoded_params = try decodeParams(params, rq.param_types, self.alloc);
        defer self.alloc.free(decoded_params);

        var rows = try self.executor.querySelect(
            rq.plan,
            decoded_params,
            nondet,
            self.executor.committed_seq,
            self.alloc,
        );
        const rows_slice = try rows.toOwnedSlice(self.alloc);
        const columns_slice = try self.alloc.alloc([]const u8, 0);

        return ResultSet{
            .columns = columns_slice,
            .rows = rows_slice,
            .alloc = self.alloc,
        };
    }

    /// Read data at a specific sequence number (historical read).
    pub fn readAt(
        self: *Gateway,
        hash: QueryHash,
        params: []const ColumnValue,
        seq: Seq,
    ) !ResultSet {
        const rq = self.registry.lookup(hash) orelse return error.QueryNotFound;

        const decoded_params = try decodeParams(params, rq.param_types, self.alloc);
        defer self.alloc.free(decoded_params);

        var rows = try self.executor.querySelect(
            rq.plan,
            decoded_params,
            &.{},
            seq,
            self.alloc,
        );
        const rows_slice = try rows.toOwnedSlice(self.alloc);
        const columns_slice = try self.alloc.alloc([]const u8, 0);

        return ResultSet{
            .columns = columns_slice,
            .rows = rows_slice,
            .alloc = self.alloc,
        };
    }

    /// Apply a DDL statement to the schema and propagate to storage.
    pub fn applyDdl(self: *Gateway, sql: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();

        const parsed = try @import("sql.zig").parser.parse(sql, arena.allocator());

        if (parsed.stmts.len == 0) return;
        const stmt = parsed.stmts[0];

        try self.registry.applyDdl(stmt);

        // Propagate CREATE TABLE to storage so mutations can find the LSM.
        switch (stmt) {
            .create_table => |ct| {
                const tbl = self.schema.getTable(ct.name) orelse return error.TableNotFound;
                try self.storage.registerTable(try sqlTableToStorage(tbl, self.storage_schema_arena.allocator()));
            },
            else => {},
        }
    }

    /// Get the current committed sequence number.
    pub fn currentSeq(self: *const Gateway) Seq {
        return self.executor.committed_seq;
    }

    /// Flush all storage to disk.
    pub fn flushAll(self: *Gateway) !void {
        try self.storage.flushAll();
    }
};

/// Decode parameters from raw ColumnValue array using the registered param types.
/// For now, we just pass through the values since they're already typed.
fn decodeParams(
    params: []const ColumnValue,
    param_types: []const sql_mod.ast.SqlType,
    alloc: std.mem.Allocator,
) ![]const ColumnValue {
    _ = param_types;
    return try alloc.dupe(ColumnValue, params);
}

/// Convert a SQL-layer TableSchema to the storage-layer TableSchema.
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
        // uuid, timestamp → int64 (stored as raw bytes / micros)
        .uuid => .bytes,
        .timestamp => .int64,
        .interval_months, .interval_micros => .int64,
        // complex types → bytes (opaque)
        .decimal, .json, .vector, .array, .struct_type => .bytes,
        .null_type => .bytes,
    };
}
