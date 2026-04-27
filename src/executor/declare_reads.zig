/// DeclareReads: walk a SQL ExecutionPlan and emit ForeignRead entries for every
/// table scan that must be satisfied by a peer partition.
///
/// Strategy:
///   - Collect all table IDs that the plan scans (scan, ann_scan, update, delete,
///     merge source/target, and their nested nodes).
///   - For each table, for each partition in `read_set_hint` that is not
///     `my_partition`, emit a sentinel ForeignRead with key = "" (meaning "send me
///     your full scan slice for this table").
///   - Point-lookups (pk_lookup) are handled via the same conservative full-table-scan
///     path: the table is added to the read set and a sentinel ForeignRead is emitted.
///
/// The sentinel key "" is recognised by the serve-and-wait loop in FoldExecutor,
/// which responds by sending all rows it has for that (partition, table).
const std = @import("std");
const sql_root = @import("sql.zig");
const plan_mod = sql_root.plan; // src/sql/plan.zig via sql.zig re-export
const exchange = @import("exchange.zig");

pub const PartitionId = exchange.PartitionId;
pub const TableId = exchange.TableId;
pub const ForeignRead = exchange.ForeignRead;

/// Walk `plan` and emit ForeignRead entries for every table that spans partitions
/// beyond `my_partition`.
///
/// `read_set_hint` is the TxnIntent.read_set_hint: the set of partitions this
/// transaction is known to read from.  A partition in the hint that is not
/// `my_partition` gets one sentinel ForeignRead per scanned table.
pub fn declareReads(
    plan: plan_mod.ExecutionPlan,
    my_partition: PartitionId,
    read_set_hint: []const PartitionId,
    alloc: std.mem.Allocator,
    out: *std.ArrayList(ForeignRead),
) !void {
    // Collect the set of table IDs this plan reads from.
    var tables: std.AutoHashMapUnmanaged(TableId, void) = .empty;
    defer tables.deinit(alloc);

    for (plan.stmts) |stmt| {
        try collectStmtTables(stmt, alloc, &tables);
    }

    if (tables.count() == 0) return;

    // For each foreign partition in the read hint, emit a sentinel per table.
    for (read_set_hint) |pid| {
        if (pid == my_partition) continue;
        var it = tables.keyIterator();
        while (it.next()) |tid| {
            try out.append(alloc, .{
                .table_id = tid.*,
                .key = "", // sentinel: full-scan request
            });
        }
    }
}

fn collectStmtTables(
    stmt: plan_mod.StmtPlan,
    alloc: std.mem.Allocator,
    out: *std.AutoHashMapUnmanaged(TableId, void),
) !void {
    switch (stmt) {
        .select => |node| try collectNodeTables(node, alloc, out),
        .insert => |ins| {
            switch (ins.source) {
                .query => |q| try collectNodeTables(q, alloc, out),
                .values => {}, // no reads from storage
            }
        },
        .update => |upd| {
            try out.put(alloc, upd.table_id, {});
            if (upd.from_table_id) |fid| try out.put(alloc, fid, {});
        },
        .delete => |del| {
            try out.put(alloc, del.table_id, {});
            for (del.using_table_ids) |tid| try out.put(alloc, tid, {});
        },
        .merge => |mrg| {
            try out.put(alloc, mrg.target_id, {});
            try collectNodeTables(mrg.source, alloc, out);
        },
        .assert => |a| {
            // ASSERT predicates may reference subqueries.
            try collectExprTables(a.predicate, alloc, out);
        },
        .describe_table, .describe_transaction, .show_transactions, .drop_transaction,
        .show_databases => {},
    }
}

fn collectNodeTables(
    node: *const plan_mod.PlanNode,
    alloc: std.mem.Allocator,
    out: *std.AutoHashMapUnmanaged(TableId, void),
) error{OutOfMemory}!void {
    switch (node.*) {
        .scan => |s| try out.put(alloc, s.table_id, {}),
        .ann_scan => |s| try out.put(alloc, s.table_id, {}),
        .pk_lookup => |s| try out.put(alloc, s.table_id, {}),
        .filter => |f| try collectNodeTables(f.input, alloc, out),
        .project => |p| try collectNodeTables(p.input, alloc, out),
        .sort => |s| try collectNodeTables(s.input, alloc, out),
        .limit => |l| try collectNodeTables(l.input, alloc, out),
        .hash_agg => |ha| try collectNodeTables(ha.input, alloc, out),
        .hash_join => |j| {
            try collectNodeTables(j.left, alloc, out);
            try collectNodeTables(j.right, alloc, out);
        },
        .window => |w| try collectNodeTables(w.input, alloc, out),
        .insert => |ins| {
            switch (ins.source) {
                .query => |q| try collectNodeTables(q, alloc, out),
                .values => {},
            }
        },
        .update => |upd| {
            try out.put(alloc, upd.table_id, {});
            if (upd.from_table_id) |fid| try out.put(alloc, fid, {});
        },
        .delete => |del| {
            try out.put(alloc, del.table_id, {});
            for (del.using_table_ids) |tid| try out.put(alloc, tid, {});
        },
        .merge => |mrg| {
            try out.put(alloc, mrg.target_id, {});
            try collectNodeTables(mrg.source, alloc, out);
        },
        .assert => |a| try collectExprTables(a.predicate, alloc, out),
        .empty, .single_row => {},
    }
}

fn collectExprTables(
    expr: *const plan_mod.PlanExpr,
    alloc: std.mem.Allocator,
    out: *std.AutoHashMapUnmanaged(TableId, void),
) error{OutOfMemory}!void {
    switch (expr.*) {
        .scalar_subquery,
        .exists_subquery,
        .not_exists_subquery,
        => |sub| try collectNodeTables(sub, alloc, out),
        .in_subquery => |s| {
            try collectExprTables(s.expr, alloc, out);
            try collectNodeTables(s.plan, alloc, out);
        },
        .not_in_subquery => |s| {
            try collectExprTables(s.expr, alloc, out);
            try collectNodeTables(s.plan, alloc, out);
        },
        .binary => |b| {
            try collectExprTables(b.left, alloc, out);
            try collectExprTables(b.right, alloc, out);
        },
        .unary => |u| try collectExprTables(u.expr, alloc, out),
        .cast => |c| try collectExprTables(c.expr, alloc, out),
        .is_null => |e| try collectExprTables(e, alloc, out),
        .is_not_null => |e| try collectExprTables(e, alloc, out),
        .fn_call => |f| {
            for (f.args) |a| try collectExprTables(a, alloc, out);
        },
        .case_searched => |cs| {
            for (cs.whens) |w| {
                try collectExprTables(w.cond, alloc, out);
                try collectExprTables(w.result, alloc, out);
            }
            if (cs.else_expr) |e| try collectExprTables(e, alloc, out);
        },
        else => {}, // literals, params, column refs — no table accesses
    }
}
