/// Reconnaissance: determine which storage partitions a transaction plan will read and write.
const std = @import("std");
const sql_mod = @import("sql.zig");
const storage_mod = @import("storage.zig");
const executor_mod = @import("executor.zig");

const Seq = @import("types.zig").Seq;
const ColumnValue = @import("storage.zig").ColumnValue;

/// Reconnaissance scan strategy used during transaction intent building.
pub const ReconStrategy = enum {
    /// Scan rows but stop as soon as all partition_count slots are seen. Default.
    early_exit,
    /// Skip the row scan entirely and claim all partitions. Cheaper but reduces concurrency.
    all_partitions,
};

/// Partition routing hints produced by reconnaissance. Caller must call deinit().
pub const ReconHints = struct {
    read: []executor_mod.PartitionId,
    write: []executor_mod.PartitionId,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *ReconHints) void {
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
pub fn reconnaissanceScan(
    plan: sql_mod.plan.ExecutionPlan,
    storage: *storage_mod.PartitionedStorage,
    params: []const ColumnValue,
    schema: *const sql_mod.SchemaRegistry,
    at_seq: Seq,
    partition_count: u32,
    strategy: ReconStrategy,
    alloc: std.mem.Allocator,
) !ReconHints {
    var read_set: PartitionSet = .{};
    errdefer read_set.deinit(alloc);
    var write_set: PartitionSet = .{};
    errdefer write_set.deinit(alloc);

    for (plan.stmts) |stmt| {
        switch (stmt) {
            .select => |node| try collectNodePartitions(node, storage, params, at_seq, partition_count, strategy, &read_set, alloc),
            .insert => |ins| {
                try collectInsertPartitions(ins, storage, params, schema, at_seq, partition_count, strategy, &write_set, alloc);
                if (ins.source == .query) {
                    try collectNodePartitions(ins.source.query, storage, params, at_seq, partition_count, strategy, &read_set, alloc);
                }
            },
            .update => |upd| {
                try scanTablePartitions(storage, upd.table_id, at_seq, partition_count, strategy, &write_set, alloc);
                try scanTablePartitions(storage, upd.table_id, at_seq, partition_count, strategy, &read_set, alloc);
                if (upd.from_table_id) |from_tid| {
                    try scanTablePartitions(storage, from_tid, at_seq, partition_count, strategy, &read_set, alloc);
                }
            },
            .delete => |del| {
                try scanTablePartitions(storage, del.table_id, at_seq, partition_count, strategy, &write_set, alloc);
                try scanTablePartitions(storage, del.table_id, at_seq, partition_count, strategy, &read_set, alloc);
                for (del.using_table_ids) |tid| {
                    try scanTablePartitions(storage, tid, at_seq, partition_count, strategy, &read_set, alloc);
                }
            },
            .merge => |mrg| {
                try scanTablePartitions(storage, mrg.target_id, at_seq, partition_count, strategy, &write_set, alloc);
                try scanTablePartitions(storage, mrg.target_id, at_seq, partition_count, strategy, &read_set, alloc);
                try collectNodePartitions(mrg.source, storage, params, at_seq, partition_count, strategy, &read_set, alloc);
            },
            .assert, .describe_table, .describe_transaction, .show_transactions, .drop_transaction,
            .show_databases => {},
        }
    }

    return .{
        .read = try read_set.list.toOwnedSlice(alloc),
        .write = try write_set.list.toOwnedSlice(alloc),
        .alloc = alloc,
    };
}

/// Map an encoded storage key to a partition ID by hashing.
fn keyToPartitionId(key: []const u8, partition_count: u32) executor_mod.PartitionId {
    if (partition_count <= 1) return 0;
    std.debug.assert(partition_count > 0);
    const h = std.hash.Wyhash.hash(0, key);
    return @intCast(h % partition_count);
}

/// Accumulates unique partition IDs using an O(1) bitmask.
/// Requires partition_count <= 64 (enforced by gateway init assertion).
const PartitionSet = struct {
    list: std.ArrayList(executor_mod.PartitionId) = .empty,
    seen: u64 = 0,

    fn append(ps: *PartitionSet, val: executor_mod.PartitionId, alloc: std.mem.Allocator) !void {
        std.debug.assert(val < 64);
        const bit: u64 = @as(u64, 1) << @intCast(val);
        if (ps.seen & bit != 0) return;
        ps.seen |= bit;
        try ps.list.append(alloc, val);
    }

    fn deinit(ps: *PartitionSet, alloc: std.mem.Allocator) void {
        ps.list.deinit(alloc);
    }
};

/// Scan all rows in a table at at_seq and collect their partition IDs.
/// Silently skips tables not yet registered in storage (no rows, no partitions).
fn scanTablePartitions(
    storage: *storage_mod.PartitionedStorage,
    table_id: storage_mod.TableId,
    at_seq: Seq,
    partition_count: u32,
    strategy: ReconStrategy,
    out: *PartitionSet,
    alloc: std.mem.Allocator,
) !void {
    if (strategy == .all_partitions) {
        for (0..partition_count) |i| try out.append(@intCast(i), alloc);
        return;
    }
    // early_exit: stop as soon as every partition slot is occupied.
    const full_mask: u64 = if (partition_count == 64)
        std.math.maxInt(u64)
    else
        (@as(u64, 1) << @intCast(partition_count)) - 1;
    var it = storage.scan(table_id, storage_mod.KeyRange.all(), at_seq, alloc) catch |err| switch (err) {
        error.TableNotFound => return,
        else => return err,
    };
    defer it.deinit();
    while (try it.next()) |row| {
        try out.append(keyToPartitionId(row.key, partition_count), alloc);
        if (out.seen & full_mask == full_mask) break;
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
    strategy: ReconStrategy,
    out: *PartitionSet,
    alloc: std.mem.Allocator,
) !void {
    if (ins.source == .query) {
        // Can't determine write keys statically; scan for current rows as over-approximation.
        try scanTablePartitions(storage, ins.table_id, at_seq, partition_count, strategy, out, alloc);
        return;
    }
    const tbl = schema.getTableById(ins.table_id) orelse {
        try out.append(0, alloc);
        return;
    };
    for (ins.source.values) |row_exprs| {
        if (extractInsertRowKey(tbl, ins.column_ids, row_exprs, params, alloc)) |key| {
            defer alloc.free(key);
            try out.append(keyToPartitionId(key, partition_count), alloc);
        } else {
            try out.append(0, alloc);
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
    strategy: ReconStrategy,
    out: *PartitionSet,
    alloc: std.mem.Allocator,
) !void {
    switch (node.*) {
        .scan => |s| try scanTablePartitions(storage, s.table_id, at_seq, partition_count, strategy, out, alloc),
        .pk_lookup => |pk| {
            // key_expr evaluates to the full encoded PK. Hash it if statically known.
            const maybe_key = encodeLiteralKey(pk.key_expr, params, alloc);
            if (maybe_key) |key| {
                defer alloc.free(key);
                try out.append(keyToPartitionId(key, partition_count), alloc);
            } else {
                try scanTablePartitions(storage, pk.table_id, at_seq, partition_count, strategy, out, alloc);
            }
        },
        .filter => |f| try collectNodePartitions(f.input, storage, params, at_seq, partition_count, strategy, out, alloc),
        .project => |p| try collectNodePartitions(p.input, storage, params, at_seq, partition_count, strategy, out, alloc),
        .sort => |s| try collectNodePartitions(s.input, storage, params, at_seq, partition_count, strategy, out, alloc),
        .limit => |l| try collectNodePartitions(l.input, storage, params, at_seq, partition_count, strategy, out, alloc),
        .hash_agg => |h| try collectNodePartitions(h.input, storage, params, at_seq, partition_count, strategy, out, alloc),
        .hash_join => |j| {
            try collectNodePartitions(j.left, storage, params, at_seq, partition_count, strategy, out, alloc);
            try collectNodePartitions(j.right, storage, params, at_seq, partition_count, strategy, out, alloc);
        },
        .window => |w| try collectNodePartitions(w.input, storage, params, at_seq, partition_count, strategy, out, alloc),
        .insert => |ins| {
            try scanTablePartitions(storage, ins.table_id, at_seq, partition_count, strategy, out, alloc);
            if (ins.source == .query) {
                try collectNodePartitions(ins.source.query, storage, params, at_seq, partition_count, strategy, out, alloc);
            }
        },
        .update => |upd| try scanTablePartitions(storage, upd.table_id, at_seq, partition_count, strategy, out, alloc),
        .delete => |del| try scanTablePartitions(storage, del.table_id, at_seq, partition_count, strategy, out, alloc),
        .merge => |mrg| {
            try scanTablePartitions(storage, mrg.target_id, at_seq, partition_count, strategy, out, alloc);
            try collectNodePartitions(mrg.source, storage, params, at_seq, partition_count, strategy, out, alloc);
        },
        .ann_scan => |s| try scanTablePartitions(storage, s.table_id, at_seq, partition_count, strategy, out, alloc),
        .assert, .empty, .single_row => {},
    }
}
