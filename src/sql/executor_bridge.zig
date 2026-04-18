/// SqlExecutor: bridges SQL plans to the storage layer.
///
/// Executes ExecutionPlans against Storage, producing ExecResults.
/// Handles: table scans, PK lookups, filters, projections, aggregates,
///          INSERT/UPDATE/DELETE mutations, and ASSERT constraints.
const std = @import("std");
const plan_mod = @import("plan.zig");
const ast = @import("ast.zig");
const schema_mod = @import("schema.zig");
const registry_mod = @import("registry.zig");

// Re-export storage types — these are imported via build.zig module imports
const storage_mod = @import("storage.zig");
const executor_mod = @import("executor.zig");
const log_mod = @import("log.zig");

pub const Storage = storage_mod.Storage;
pub const Row = storage_mod.Row;
pub const ColumnValue = storage_mod.ColumnValue;
pub const ColumnType = storage_mod.ColumnType;
pub const Mutation = storage_mod.Mutation;
pub const MutationKind = storage_mod.MutationKind;
pub const KeyRange = storage_mod.KeyRange;
pub const TableId = storage_mod.TableId;
pub const Seq = executor_mod.Seq;
pub const LogEntry = log_mod.LogEntry;
pub const ResolvedValue = executor_mod.ResolvedValue;
pub const ExecResult = executor_mod.ExecResult;
pub const AbortCode = executor_mod.AbortCode;

pub const SqlExecError = error{
    ConstraintViolation,
    TableNotFound,
    ColumnNotFound,
    TypeMismatch,
    DivisionByZero,
    IntegerOverflow,
    NullViolation,
    AssertionFailed,
    OutOfMemory,
};

/// Result of executing a SELECT plan.
pub const ResultSet = struct {
    columns: []const []const u8,
    rows: []const []const ?ColumnValue,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *ResultSet) void {
        for (self.rows) |row| {
            for (row) |v| {
                if (v) |val| val.freeIfOwned(self.alloc);
            }
            self.alloc.free(row);
        }
        self.alloc.free(self.rows);
        self.alloc.free(self.columns);
    }
};

/// Context passed to expression evaluator during plan execution.
const EvalCtx = struct {
    params: []const ColumnValue,
    nondet: []const ResolvedValue,
    seq: Seq,
    row: ?[]const ?ColumnValue, // current row being evaluated
    schema: *const schema_mod.SchemaRegistry,
    alloc: std.mem.Allocator,
};

/// High-level SQL executor wrapping the storage and SQL registry.
pub const SqlExecutor = struct {
    storage: *Storage,
    registry: *registry_mod.SqlRegistry,
    schema: *schema_mod.SchemaRegistry,
    committed_seq: Seq,
    alloc: std.mem.Allocator,

    pub fn init(
        storage: *Storage,
        registry: *registry_mod.SqlRegistry,
        schema: *schema_mod.SchemaRegistry,
        alloc: std.mem.Allocator,
    ) SqlExecutor {
        return .{
            .storage = storage,
            .registry = registry,
            .schema = schema,
            .committed_seq = 0,
            .alloc = alloc,
        };
    }

    pub fn currentSeq(self: *const SqlExecutor) Seq {
        return self.committed_seq;
    }

    /// Execute a LogEntry through the SQL registry, falling back to the raw
    /// executor registry for hand-crafted handlers.
    pub fn run(self: *SqlExecutor, entry: LogEntry) !ExecResult {
        defer self.committed_seq = entry.header.seq;

        if (entry.header.kind != .txn_intent) {
            return .{ .ok = .{ .rows_affected = 0 } };
        }
        if (!entry.verifyCrc()) {
            return .{ .abort = .{ .code = .bad_params, .detail = "crc mismatch" } };
        }

        var decoded = executor_mod.deserializeTxnIntent(entry.payload, self.alloc) catch {
            return .{ .abort = .{ .code = .bad_params, .detail = "invalid payload" } };
        };
        defer decoded.deinit();

        const rq = self.registry.lookup(decoded.query_hash.*) orelse {
            return .{ .abort = .{ .code = .missing_query, .detail = "unknown query hash" } };
        };

        // Decode params from raw bytes using registered param types
        const params = decodeParams(decoded.params, rq.param_types, self.alloc) catch {
            return .{ .abort = .{ .code = .bad_params, .detail = "param decode failed" } };
        };
        defer {
            for (params) |v| v.freeIfOwned(self.alloc);
            self.alloc.free(params);
        }

        const result = self.executePlan(
            rq.plan,
            params,
            decoded.nondet,
            entry.header.seq,
        ) catch |e| {
            return switch (e) {
                error.AssertionFailed => .{ .abort = .{ .code = .constraint_violation, .detail = "assertion failed" } },
                error.ConstraintViolation => .{ .abort = .{ .code = .constraint_violation, .detail = "constraint violation" } },
                else => return e,
            };
        };

        return .{ .ok = .{ .rows_affected = result } };
    }

    /// Execute a SELECT plan and return collected rows.
    /// Used for testing and by the gateway (M6).
    pub fn querySelect(
        self: *SqlExecutor,
        plan: plan_mod.ExecutionPlan,
        params: []const ColumnValue,
        nondet: []const ResolvedValue,
        seq: Seq,
        alloc: std.mem.Allocator,
    ) SqlExecError!std.ArrayList([]const ?ColumnValue) {
        const ctx = EvalCtx{
            .params = params,
            .nondet = nondet,
            .seq = seq,
            .row = null,
            .schema = self.schema,
            .alloc = alloc,
        };
        var rows: std.ArrayList([]const ?ColumnValue) = .empty;
        for (plan.stmts) |stmt| {
            switch (stmt) {
                .select => |node| try self.executeScan(node, ctx, &rows),
                else => {},
            }
        }
        return rows;
    }

    /// Execute a plan directly (without going through the log).
    /// Used by the gateway (M6) to run queries and return result sets.
    pub fn executePlanDirect(
        self: *SqlExecutor,
        plan: plan_mod.ExecutionPlan,
        params: []const ColumnValue,
        nondet: []const ResolvedValue,
        seq: Seq,
    ) SqlExecError!u64 {
        return self.executePlan(plan, params, nondet, seq);
    }

    fn executePlan(
        self: *SqlExecutor,
        plan: plan_mod.ExecutionPlan,
        params: []const ColumnValue,
        nondet: []const ResolvedValue,
        seq: Seq,
    ) SqlExecError!u64 {
        var mutations: std.ArrayList(Mutation) = .empty;
        defer {
            for (mutations.items) |m| {
                self.alloc.free(m.key);
                if (m.values) |vs| {
                    for (vs) |v| v.freeIfOwned(self.alloc);
                    self.alloc.free(vs);
                }
            }
            mutations.deinit(self.alloc);
        }

        const ctx = EvalCtx{
            .params = params,
            .nondet = nondet,
            .seq = seq,
            .row = null,
            .schema = self.schema,
            .alloc = self.alloc,
        };

        for (plan.stmts) |stmt| {
            try self.executeStmt(stmt, ctx, &mutations);
        }

        const count: u64 = @intCast(mutations.items.len);
        self.storage.apply(mutations.items, seq) catch return error.TableNotFound;
        return count;
    }

    fn executeStmt(
        self: *SqlExecutor,
        stmt: plan_mod.StmtPlan,
        ctx: EvalCtx,
        mutations: *std.ArrayList(Mutation),
    ) SqlExecError!void {
        switch (stmt) {
            .select => |node| {
                // Execute SELECT and discard results (results returned via gateway in M6)
                var rows: std.ArrayList([]const ?ColumnValue) = .empty;
                defer {
                    for (rows.items) |r| self.alloc.free(r);
                    rows.deinit(self.alloc);
                }
                try self.executeScan(node, ctx, &rows);
            },
            .insert => |ins| try self.executeInsert(ins, ctx, mutations),
            .update => |upd| try self.executeUpdate(upd, ctx, mutations),
            .delete => |del| try self.executeDelete(del, ctx, mutations),
            .assert => |a| try self.executeAssert(a, ctx),
            .merge => |m| try self.executeMerge(m, ctx, mutations),
        }
    }

    fn executeScan(
        self: *SqlExecutor,
        node: *plan_mod.PlanNode,
        ctx: EvalCtx,
        out: *std.ArrayList([]const ?ColumnValue),
    ) SqlExecError!void {
        switch (node.*) {
            .scan => |s| {
                var iter = self.storage.scan(s.table_id, KeyRange.all(), ctx.seq -| 1, ctx.alloc) catch return error.TableNotFound;
                defer iter.deinit();
                while (iter.next() catch null) |row| {
                    const r = try self.rowToValues(row, s.columns, ctx.alloc);
                    try out.append(ctx.alloc, r);
                }
            },
            .filter => |f| {
                var inner: std.ArrayList([]const ?ColumnValue) = .empty;
                defer {
                    for (inner.items) |r| ctx.alloc.free(r);
                    inner.deinit(ctx.alloc);
                }
                try self.executeScan(f.input, ctx, &inner);
                for (inner.items) |row| {
                    var row_ctx = ctx;
                    row_ctx.row = row;
                    const v = try evalExpr(f.predicate, row_ctx);
                    if (v.toBool() orelse false) {
                        const r = try ctx.alloc.dupe(?ColumnValue, row);
                        try out.append(ctx.alloc, r);
                    }
                }
            },
            .project => |p| {
                var inner: std.ArrayList([]const ?ColumnValue) = .empty;
                defer {
                    for (inner.items) |r| ctx.alloc.free(r);
                    inner.deinit(ctx.alloc);
                }
                try self.executeScan(p.input, ctx, &inner);
                for (inner.items) |row| {
                    var row_ctx = ctx;
                    row_ctx.row = row;
                    const projected = try ctx.alloc.alloc(?ColumnValue, p.exprs.len);
                    for (p.exprs, 0..) |item, i| {
                        const v = try evalExpr(item.expr, row_ctx);
                        projected[i] = planValueToColumnValue(v, ctx.alloc) catch null;
                    }
                    try out.append(ctx.alloc, projected);
                }
            },
            .limit => |l| {
                var inner: std.ArrayList([]const ?ColumnValue) = .empty;
                defer {
                    for (inner.items) |r| ctx.alloc.free(r);
                    inner.deinit(ctx.alloc);
                }
                try self.executeScan(l.input, ctx, &inner);
                const offset_val: u64 = if (l.offset) |o| blk: {
                    const v = try evalExpr(o, ctx);
                    break :blk switch (v) {
                        .int_val => |n| @intCast(n),
                        else => 0,
                    };
                } else 0;
                const limit_val: u64 = if (l.limit) |lim| blk: {
                    const v = try evalExpr(lim, ctx);
                    break :blk switch (v) {
                        .int_val => |n| @intCast(n),
                        else => std.math.maxInt(u64),
                    };
                } else std.math.maxInt(u64);
                var taken: u64 = 0;
                for (inner.items, 0..) |row, i| {
                    if (i < offset_val) continue;
                    if (taken >= limit_val) break;
                    const r = try ctx.alloc.dupe(?ColumnValue, row);
                    try out.append(ctx.alloc, r);
                    taken += 1;
                }
            },
            .sort => |s| {
                var inner: std.ArrayList([]const ?ColumnValue) = .empty;
                defer {
                    for (inner.items) |r| ctx.alloc.free(r);
                    inner.deinit(ctx.alloc);
                }
                try self.executeScan(s.input, ctx, &inner);
                // Deterministic sort: evaluate sort keys for each row, then sort
                const SortCtx = struct {
                    rows: []const []const ?ColumnValue,
                    keys: []const plan_mod.SortKey,
                    eval_ctx: EvalCtx,
                };
                _ = SortCtx{
                    .rows = inner.items,
                    .keys = s.keys,
                    .eval_ctx = ctx,
                };
                // Simple insertion sort for determinism (stable)
                var sorted = try ctx.alloc.dupe([]const ?ColumnValue, inner.items);
                defer ctx.alloc.free(sorted);
                for (1..sorted.len) |i| {
                    const key = sorted[i];
                    var j: usize = i;
                    while (j > 0) {
                        var row_ctx_a = ctx;
                        var row_ctx_b = ctx;
                        row_ctx_a.row = sorted[j - 1];
                        row_ctx_b.row = key;
                        const should_swap = blk: {
                            for (s.keys) |sk| {
                                const va = evalExpr(sk.expr, row_ctx_a) catch break :blk false;
                                const vb = evalExpr(sk.expr, row_ctx_b) catch break :blk false;
                                if (!va.eql(vb)) {
                                    break :blk if (sk.asc) vb.lessThan(va) else va.lessThan(vb);
                                }
                            }
                            break :blk false;
                        };
                        if (!should_swap) break;
                        sorted[j] = sorted[j - 1];
                        j -= 1;
                    }
                    sorted[j] = key;
                }
                for (sorted) |r| {
                    try out.append(ctx.alloc, try ctx.alloc.dupe(?ColumnValue, r));
                }
            },
            .empty => {}, // no rows
            .single_row => { // one empty row (for FROM-less SELECT)
                const r = try ctx.alloc.alloc(?ColumnValue, 0);
                try out.append(ctx.alloc, r);
            },

            .window => |w| {
                var inner: std.ArrayList([]const ?ColumnValue) = .empty;
                defer {
                    for (inner.items) |r| ctx.alloc.free(r);
                    inner.deinit(ctx.alloc);
                }
                try self.executeScan(w.input, ctx, &inner);

                if (inner.items.len == 0) return;

                // Allocate result matrix: [row_idx][fn_idx] = ColumnValue
                const win_results = try ctx.alloc.alloc([]?ColumnValue, inner.items.len);
                defer {
                    for (win_results) |r| ctx.alloc.free(r);
                    ctx.alloc.free(win_results);
                }
                for (win_results) |*r| {
                    r.* = try ctx.alloc.alloc(?ColumnValue, w.fns.len);
                    for (r.*) |*v| v.* = null;
                }

                for (w.fns, 0..) |wf, fi| {
                    try self.computeWindowFnForAll(wf, inner.items, win_results, fi, ctx);
                }

                for (inner.items, 0..) |row, ri| {
                    const aug = try ctx.alloc.alloc(?ColumnValue, row.len + w.fns.len);
                    @memcpy(aug[0..row.len], row);
                    @memcpy(aug[row.len..], win_results[ri]);
                    try out.append(ctx.alloc, aug);
                }
            },

            .merge => {}, // not a scan context

            .hash_join => |j| {
                var left_rows: std.ArrayList([]const ?ColumnValue) = .empty;
                defer {
                    for (left_rows.items) |r| ctx.alloc.free(r);
                    left_rows.deinit(ctx.alloc);
                }
                var right_rows: std.ArrayList([]const ?ColumnValue) = .empty;
                defer {
                    for (right_rows.items) |r| ctx.alloc.free(r);
                    right_rows.deinit(ctx.alloc);
                }
                try self.executeScan(j.left, ctx, &left_rows);
                try self.executeScan(j.right, ctx, &right_rows);

                const right_width = if (right_rows.items.len > 0) right_rows.items[0].len else 0;

                for (left_rows.items) |lr| {
                    var matched = false;
                    for (right_rows.items) |rr| {
                        const combined = try ctx.alloc.alloc(?ColumnValue, lr.len + rr.len);
                        @memcpy(combined[0..lr.len], lr);
                        @memcpy(combined[lr.len..], rr);
                        var join_ctx = ctx;
                        join_ctx.row = combined;
                        const passes = (try evalExpr(j.condition, join_ctx)).toBool() orelse false;
                        if (passes) {
                            matched = true;
                            try out.append(ctx.alloc, combined);
                        } else {
                            ctx.alloc.free(combined);
                        }
                    }
                    if (!matched and (j.kind == .left)) {
                        const padded = try ctx.alloc.alloc(?ColumnValue, lr.len + right_width);
                        @memcpy(padded[0..lr.len], lr);
                        for (padded[lr.len..]) |*v| v.* = null;
                        try out.append(ctx.alloc, padded);
                    }
                }
                // RIGHT JOIN: emit right rows with no match as NULL-padded
                if (j.kind == .right) {
                    for (right_rows.items) |rr| {
                        var any_match = false;
                        for (left_rows.items) |lr| {
                            const combined = try ctx.alloc.alloc(?ColumnValue, lr.len + rr.len);
                            @memcpy(combined[0..lr.len], lr);
                            @memcpy(combined[lr.len..], rr);
                            var join_ctx = ctx;
                            join_ctx.row = combined;
                            const passes = (try evalExpr(j.condition, join_ctx)).toBool() orelse false;
                            ctx.alloc.free(combined);
                            if (passes) {
                                any_match = true;
                                break;
                            }
                        }
                        if (!any_match) {
                            const padded = try ctx.alloc.alloc(?ColumnValue, left_rows.items[0].len + rr.len);
                            for (padded[0..left_rows.items[0].len]) |*v| v.* = null;
                            @memcpy(padded[left_rows.items[0].len..], rr);
                            try out.append(ctx.alloc, padded);
                        }
                    }
                }
            },

            .hash_agg => |ha| {
                var inner: std.ArrayList([]const ?ColumnValue) = .empty;
                defer {
                    for (inner.items) |r| ctx.alloc.free(r);
                    inner.deinit(ctx.alloc);
                }
                try self.executeScan(ha.input, ctx, &inner);

                const GroupRow = struct {
                    key: []const ?ColumnValue,
                    accums: []AggAccum,
                };

                var groups: std.ArrayList(GroupRow) = .empty;
                defer {
                    for (groups.items) |g| {
                        ctx.alloc.free(g.key);
                        ctx.alloc.free(g.accums);
                    }
                    groups.deinit(ctx.alloc);
                }

                for (inner.items) |row| {
                    var row_ctx = ctx;
                    row_ctx.row = row;

                    const key = try ctx.alloc.alloc(?ColumnValue, ha.group_keys.len);
                    for (ha.group_keys, 0..) |ke, i| {
                        const v = try evalExpr(ke, row_ctx);
                        key[i] = planValueToColumnValue(v, ctx.alloc) catch null;
                    }

                    var found_group: ?*GroupRow = null;
                    for (groups.items) |*g| {
                        if (aggKeyEquals(g.key, key)) {
                            found_group = g;
                            break;
                        }
                    }

                    if (found_group) |g| {
                        ctx.alloc.free(key);
                        for (ha.agg_exprs, g.accums) |ae, *acc| {
                            try acc.update(ae, row_ctx);
                        }
                    } else {
                        const accums = try ctx.alloc.alloc(AggAccum, ha.agg_exprs.len);
                        for (accums) |*a| a.* = .{};
                        for (ha.agg_exprs, accums) |ae, *acc| {
                            try acc.update(ae, row_ctx);
                        }
                        try groups.append(ctx.alloc, .{ .key = key, .accums = accums });
                    }
                }

                // If no rows and no GROUP BY, still emit one aggregate row (e.g. COUNT(*) = 0)
                if (groups.items.len == 0 and ha.group_keys.len == 0) {
                    const accums = try ctx.alloc.alloc(AggAccum, ha.agg_exprs.len);
                    for (accums) |*a| a.* = .{};
                    const key = try ctx.alloc.alloc(?ColumnValue, 0);
                    try groups.append(ctx.alloc, .{ .key = key, .accums = accums });
                }

                for (groups.items) |g| {
                    const result_row = try ctx.alloc.alloc(?ColumnValue, ha.group_keys.len + ha.agg_exprs.len);
                    @memcpy(result_row[0..ha.group_keys.len], g.key);
                    for (ha.agg_exprs, g.accums, 0..) |ae, acc, i| {
                        const v = acc.toValue(ae.fn_name);
                        result_row[ha.group_keys.len + i] = planValueToColumnValue(v, ctx.alloc) catch null;
                    }
                    try out.append(ctx.alloc, result_row);
                }
            },

            // DML nodes not valid in scan context
            else => {},
        }
    }

    fn executeInsert(
        self: *SqlExecutor,
        ins: plan_mod.InsertPlan,
        ctx: EvalCtx,
        mutations: *std.ArrayList(Mutation),
    ) SqlExecError!void {
        const tbl = self.schema.getTableById(ins.table_id) orelse return error.TableNotFound;

        switch (ins.source) {
            .values => |rows| {
                for (rows) |row| {
                    // Evaluate value expressions
                    const values = try ctx.alloc.alloc(ColumnValue, ins.column_ids.len);
                    errdefer ctx.alloc.free(values);
                    for (ins.column_ids, 0..) |col_id, i| {
                        const pv = try evalExpr(row[i], ctx);
                        const col = tbl.columnById(col_id) orelse return error.ColumnNotFound;
                        values[i] = try planValueToTypedColumnValue(pv, col.typ, ctx.alloc);
                    }

                    // Build the primary key
                    const key = try buildPrimaryKey(tbl, ins.column_ids, values, ctx.alloc);

                    try mutations.append(ctx.alloc, .{
                        .kind = .insert,
                        .table_id = ins.table_id,
                        .key = key,
                        .values = values,
                    });
                }
            },
            .query => |node| {
                var rows: std.ArrayList([]const ?ColumnValue) = .empty;
                defer {
                    for (rows.items) |r| ctx.alloc.free(r);
                    rows.deinit(ctx.alloc);
                }
                try self.executeScan(node, ctx, &rows);
                for (rows.items) |row| {
                    const values = try ctx.alloc.alloc(ColumnValue, @min(ins.column_ids.len, row.len));
                    errdefer ctx.alloc.free(values);
                    for (ins.column_ids, 0..) |col_id, i| {
                        if (i >= row.len) return error.TypeMismatch;
                        const col = tbl.columnById(col_id) orelse return error.ColumnNotFound;
                        if (row[i]) |cv| {
                            values[i] = try cv.dupe(ctx.alloc);
                        } else {
                            if (col.nullable == .not_null) return error.NullViolation;
                            values[i] = defaultValue(col.typ);
                        }
                    }
                    const key = try buildPrimaryKey(tbl, ins.column_ids, values, ctx.alloc);
                    try mutations.append(ctx.alloc, .{
                        .kind = .insert,
                        .table_id = ins.table_id,
                        .key = key,
                        .values = values,
                    });
                }
            },
        }
    }

    fn executeUpdate(
        self: *SqlExecutor,
        upd: plan_mod.UpdatePlan,
        ctx: EvalCtx,
        mutations: *std.ArrayList(Mutation),
    ) SqlExecError!void {
        const tbl = self.schema.getTableById(upd.table_id) orelse return error.TableNotFound;
        var iter = self.storage.scan(upd.table_id, KeyRange.all(), ctx.seq -| 1, ctx.alloc) catch return error.TableNotFound;
        defer iter.deinit();

        while (iter.next() catch null) |row| {
            // Convert row to nullable values for filter evaluation
            const row_vals = try self.rowToValues(row, pkColumnIds(tbl), ctx.alloc);
            defer ctx.alloc.free(row_vals);

            var row_ctx = ctx;
            row_ctx.row = row_vals;

            // Apply WHERE filter
            if (upd.filter) |f| {
                const v = try evalExpr(f, row_ctx);
                if (!(v.toBool() orelse false)) continue;
            }

            // Evaluate new values
            const new_values = try ctx.alloc.alloc(ColumnValue, tbl.columns.len);
            errdefer ctx.alloc.free(new_values);
            // Copy existing values
            for (tbl.columns, 0..) |col, i| {
                new_values[i] = if (i < row.values.len)
                    row.values[i].dupe(ctx.alloc) catch defaultValue(col.typ)
                else
                    defaultValue(col.typ);
            }
            // Apply assignments
            for (upd.assignments) |asgn| {
                const pv = try evalExpr(asgn.value, row_ctx);
                const col = tbl.columnById(asgn.column_id) orelse return error.ColumnNotFound;
                const col_pos: usize = @intCast(asgn.column_id);
                if (col_pos < new_values.len) {
                    new_values[col_pos] = try planValueToTypedColumnValue(pv, col.typ, ctx.alloc);
                }
            }

            const key = try ctx.alloc.dupe(u8, row.key);
            try mutations.append(ctx.alloc, .{
                .kind = .update,
                .table_id = upd.table_id,
                .key = key,
                .values = new_values,
            });
        }
    }

    fn executeDelete(
        self: *SqlExecutor,
        del: plan_mod.DeletePlan,
        ctx: EvalCtx,
        mutations: *std.ArrayList(Mutation),
    ) SqlExecError!void {
        const tbl = self.schema.getTableById(del.table_id) orelse return error.TableNotFound;
        _ = tbl;
        var iter = self.storage.scan(del.table_id, KeyRange.all(), ctx.seq -| 1, ctx.alloc) catch return error.TableNotFound;
        defer iter.deinit();

        while (iter.next() catch null) |row| {
            if (del.filter) |f| {
                const row_vals = try self.rowToValues(row, &.{}, ctx.alloc);
                defer ctx.alloc.free(row_vals);
                var row_ctx = ctx;
                row_ctx.row = row_vals;
                const v = try evalExpr(f, row_ctx);
                if (!(v.toBool() orelse false)) continue;
            }
            const key = try ctx.alloc.dupe(u8, row.key);
            try mutations.append(ctx.alloc, .{
                .kind = .delete,
                .table_id = del.table_id,
                .key = key,
                .values = null,
            });
        }
    }

    fn executeAssert(
        self: *SqlExecutor,
        a: plan_mod.AssertPlan,
        ctx: EvalCtx,
    ) SqlExecError!void {
        _ = self;
        const v = try evalExpr(a.predicate, ctx);
        if (!(v.toBool() orelse false)) return error.AssertionFailed;
    }

    fn computeWindowFnForAll(
        self: *SqlExecutor,
        wf: plan_mod.WindowFnSpec,
        rows: []const []const ?ColumnValue,
        results: [][]?ColumnValue,
        fn_idx: usize,
        ctx: EvalCtx,
    ) SqlExecError!void {
        _ = self;

        // Group rows into partitions by evaluating partition_by expressions
        const PartKey = struct { vals: []?ColumnValue, indices: std.ArrayList(usize) };
        var parts: std.ArrayList(PartKey) = .empty;
        defer {
            for (parts.items) |*p| {
                ctx.alloc.free(p.vals);
                p.indices.deinit(ctx.alloc);
            }
            parts.deinit(ctx.alloc);
        }

        for (rows, 0..) |row, ri| {
            var row_ctx = ctx;
            row_ctx.row = row;
            const pk = try ctx.alloc.alloc(?ColumnValue, wf.partition_by.len);
            for (wf.partition_by, 0..) |pb, i| {
                const v = evalExpr(pb, row_ctx) catch .null_val;
                pk[i] = planValueToColumnValue(v, ctx.alloc) catch null;
            }

            var found: ?*PartKey = null;
            for (parts.items) |*p| {
                if (aggKeyEquals(p.vals, pk)) {
                    found = p;
                    break;
                }
            }
            if (found) |p| {
                ctx.alloc.free(pk);
                try p.indices.append(ctx.alloc, ri);
            } else {
                var idx_list: std.ArrayList(usize) = .empty;
                try idx_list.append(ctx.alloc, ri);
                try parts.append(ctx.alloc, .{ .vals = pk, .indices = idx_list });
            }
        }

        // For each partition, sort by order_by, then assign window fn values
        for (parts.items) |*p| {
            const indices = p.indices.items;
            var sorted = try ctx.alloc.dupe(usize, indices);
            defer ctx.alloc.free(sorted);

            // Stable insertion sort by order_by keys
            for (1..sorted.len) |i| {
                const key_idx = sorted[i];
                var j: usize = i;
                while (j > 0) {
                    var ctx_a = ctx;
                    var ctx_b = ctx;
                    ctx_a.row = rows[sorted[j - 1]];
                    ctx_b.row = rows[key_idx];
                    const swap = blk: {
                        for (wf.order_by) |sk| {
                            const va = evalExpr(sk.expr, ctx_a) catch break :blk false;
                            const vb = evalExpr(sk.expr, ctx_b) catch break :blk false;
                            if (!va.eql(vb)) break :blk if (sk.asc) vb.lessThan(va) else va.lessThan(vb);
                        }
                        break :blk false;
                    };
                    if (!swap) break;
                    sorted[j] = sorted[j - 1];
                    j -= 1;
                }
                sorted[j] = key_idx;
            }

            if (std.ascii.eqlIgnoreCase(wf.fn_name, "row_number")) {
                for (sorted, 0..) |ri, pos| {
                    results[ri][fn_idx] = .{ .int64 = @intCast(pos + 1) };
                }
            } else if (std.ascii.eqlIgnoreCase(wf.fn_name, "rank")) {
                var rank: i64 = 1;
                var count: i64 = 0;
                var prev_order_vals: ?[]plan_mod.Value = null;
                defer if (prev_order_vals) |pv| ctx.alloc.free(pv);
                for (sorted) |ri| {
                    count += 1;
                    var row_ctx = ctx;
                    row_ctx.row = rows[ri];
                    const cur = try ctx.alloc.alloc(plan_mod.Value, wf.order_by.len);
                    defer ctx.alloc.free(cur);
                    for (wf.order_by, 0..) |sk, i| {
                        cur[i] = evalExpr(sk.expr, row_ctx) catch .null_val;
                    }
                    if (prev_order_vals) |pv| {
                        var same = true;
                        for (cur, pv) |cv, pval| {
                            if (!cv.eql(pval)) {
                                same = false;
                                break;
                            }
                        }
                        if (!same) {
                            rank = count;
                            ctx.alloc.free(pv);
                            prev_order_vals = try ctx.alloc.dupe(plan_mod.Value, cur);
                        }
                    } else {
                        prev_order_vals = try ctx.alloc.dupe(plan_mod.Value, cur);
                    }
                    results[ri][fn_idx] = .{ .int64 = rank };
                }
            } else if (std.ascii.eqlIgnoreCase(wf.fn_name, "dense_rank")) {
                var rank: i64 = 0;
                var prev_order_vals: ?[]plan_mod.Value = null;
                defer if (prev_order_vals) |pv| ctx.alloc.free(pv);
                for (sorted) |ri| {
                    var row_ctx = ctx;
                    row_ctx.row = rows[ri];
                    const cur = try ctx.alloc.alloc(plan_mod.Value, wf.order_by.len);
                    defer ctx.alloc.free(cur);
                    for (wf.order_by, 0..) |sk, i| {
                        cur[i] = evalExpr(sk.expr, row_ctx) catch .null_val;
                    }
                    if (prev_order_vals) |pv| {
                        var same = true;
                        for (cur, pv) |cv, pval| {
                            if (!cv.eql(pval)) {
                                same = false;
                                break;
                            }
                        }
                        if (!same) {
                            rank += 1;
                            ctx.alloc.free(pv);
                            prev_order_vals = try ctx.alloc.dupe(plan_mod.Value, cur);
                        }
                    } else {
                        rank = 1;
                        prev_order_vals = try ctx.alloc.dupe(plan_mod.Value, cur);
                    }
                    results[ri][fn_idx] = .{ .int64 = rank };
                }
            }
            // Unknown window functions leave result as null
        }
    }

    fn executeMerge(
        self: *SqlExecutor,
        m: plan_mod.MergePlan,
        ctx: EvalCtx,
        mutations: *std.ArrayList(Mutation),
    ) SqlExecError!void {
        const tbl = self.schema.getTableById(m.target_id) orelse return error.TableNotFound;

        // Collect source rows
        var source_rows: std.ArrayList([]const ?ColumnValue) = .empty;
        defer {
            for (source_rows.items) |r| ctx.alloc.free(r);
            source_rows.deinit(ctx.alloc);
        }
        try self.executeScan(m.source, ctx, &source_rows);

        // Collect target rows with their storage keys
        const TargetEntry = struct { key: []const u8, vals: []const ?ColumnValue };
        var target_data: std.ArrayList(TargetEntry) = .empty;
        defer {
            for (target_data.items) |td| {
                ctx.alloc.free(td.key);
                ctx.alloc.free(td.vals);
            }
            target_data.deinit(ctx.alloc);
        }
        var target_iter = self.storage.scan(m.target_id, KeyRange.all(), ctx.seq -| 1, ctx.alloc) catch return error.TableNotFound;
        defer target_iter.deinit();
        while (target_iter.next() catch null) |row| {
            const key_copy = try ctx.alloc.dupe(u8, row.key);
            const vals = try self.rowToValues(row, &.{}, ctx.alloc);
            try target_data.append(ctx.alloc, .{ .key = key_copy, .vals = vals });
        }

        // Track which target rows were matched (for WHEN NOT MATCHED logic)
        const matched = try ctx.alloc.alloc(bool, target_data.items.len);
        defer ctx.alloc.free(matched);
        @memset(matched, false);

        for (source_rows.items) |src_row| {
            // Find a matching target row via ON condition
            var found_target_idx: ?usize = null;
            for (target_data.items, 0..) |td, ti| {
                const combined = try ctx.alloc.alloc(?ColumnValue, td.vals.len + src_row.len);
                @memcpy(combined[0..td.vals.len], td.vals);
                @memcpy(combined[td.vals.len..], src_row);
                var row_ctx = ctx;
                row_ctx.row = combined;
                const on_eval = evalExpr(m.on_condition, row_ctx) catch plan_mod.Value.null_val;
                const on_result = on_eval.toBool() orelse false;
                ctx.alloc.free(combined);
                if (on_result) {
                    found_target_idx = ti;
                    matched[ti] = true;
                    break;
                }
            }

            // Apply first matching WHEN clause
            when_loop: for (m.whens) |when| {
                switch (when) {
                    .matched => |mw| {
                        const ti = found_target_idx orelse continue :when_loop;
                        const td = target_data.items[ti];
                        const combined = try ctx.alloc.alloc(?ColumnValue, td.vals.len + src_row.len);
                        defer ctx.alloc.free(combined);
                        @memcpy(combined[0..td.vals.len], td.vals);
                        @memcpy(combined[td.vals.len..], src_row);
                        var row_ctx = ctx;
                        row_ctx.row = combined;

                        if (mw.cond) |c| {
                            const cv = evalExpr(c, row_ctx) catch plan_mod.Value.null_val;
                            if (!(cv.toBool() orelse false)) continue :when_loop;
                        }

                        switch (mw.action) {
                            .update => |asgns| {
                                const new_vals = try ctx.alloc.alloc(ColumnValue, tbl.columns.len);
                                errdefer ctx.alloc.free(new_vals);
                                for (tbl.columns, 0..) |col, ci| {
                                    new_vals[ci] = if (ci < td.vals.len)
                                        if (td.vals[ci]) |cv| cv.dupe(ctx.alloc) catch defaultValue(col.typ) else defaultValue(col.typ)
                                    else
                                        defaultValue(col.typ);
                                }
                                for (asgns) |asgn| {
                                    const pv = try evalExpr(asgn.value, row_ctx);
                                    const col = tbl.columnById(asgn.column_id) orelse return error.ColumnNotFound;
                                    const ci: usize = @intCast(asgn.column_id);
                                    if (ci < new_vals.len) {
                                        new_vals[ci] = try planValueToTypedColumnValue(pv, col.typ, ctx.alloc);
                                    }
                                }
                                const key = try ctx.alloc.dupe(u8, td.key);
                                try mutations.append(ctx.alloc, .{
                                    .kind = .update,
                                    .table_id = m.target_id,
                                    .key = key,
                                    .values = new_vals,
                                });
                            },
                            .delete => {
                                const key = try ctx.alloc.dupe(u8, td.key);
                                try mutations.append(ctx.alloc, .{
                                    .kind = .delete,
                                    .table_id = m.target_id,
                                    .key = key,
                                    .values = null,
                                });
                            },
                            .do_nothing => {},
                        }
                        break :when_loop;
                    },
                    .not_matched => |nm| {
                        if (found_target_idx != null) continue :when_loop;
                        var row_ctx = ctx;
                        row_ctx.row = src_row;

                        if (nm.cond) |c| {
                            const nv = evalExpr(c, row_ctx) catch plan_mod.Value.null_val;
                            if (!(nv.toBool() orelse false)) continue :when_loop;
                        }

                        const values = try ctx.alloc.alloc(ColumnValue, nm.column_ids.len);
                        errdefer ctx.alloc.free(values);
                        for (nm.column_ids, 0..) |col_id, vi| {
                            const pv = try evalExpr(nm.values[vi], row_ctx);
                            const col = tbl.columnById(col_id) orelse return error.ColumnNotFound;
                            values[vi] = try planValueToTypedColumnValue(pv, col.typ, ctx.alloc);
                        }
                        const key = try buildPrimaryKey(tbl, nm.column_ids, values, ctx.alloc);
                        try mutations.append(ctx.alloc, .{
                            .kind = .insert,
                            .table_id = m.target_id,
                            .key = key,
                            .values = values,
                        });
                        break :when_loop;
                    },
                }
            }
        }
    }

    fn rowToValues(
        self: *SqlExecutor,
        row: Row,
        cols: []const schema_mod.ColumnId,
        alloc: std.mem.Allocator,
    ) SqlExecError![]const ?ColumnValue {
        _ = self;
        // When cols is empty, return all row values (used for filter-only scans)
        if (cols.len == 0) {
            const vals = try alloc.alloc(?ColumnValue, row.values.len);
            for (row.values, 0..) |v, i| vals[i] = v;
            return vals;
        }
        // Project: for each requested column ID, find its value in the row.
        // Column IDs correspond to ordinal positions in the storage row.
        const vals = try alloc.alloc(?ColumnValue, row.values.len);
        for (row.values, 0..) |v, i| vals[i] = v;
        return vals;
    }
};

// ─── Aggregate accumulator ────────────────────────────────────────────────────

const AggAccum = struct {
    count: i64 = 0,
    sum_int: i64 = 0,
    sum_float: f64 = 0.0,
    is_float: bool = false,
    min: ?plan_mod.Value = null,
    max: ?plan_mod.Value = null,

    fn update(self: *AggAccum, ae: plan_mod.AggExpr, row_ctx: EvalCtx) SqlExecError!void {
        const val = if (ae.arg) |arg| try evalExpr(arg, row_ctx) else .null_val;
        const fn_name = ae.fn_name;

        if (std.ascii.eqlIgnoreCase(fn_name, "count")) {
            if (ae.arg == null or val != .null_val) self.count += 1;
        } else if (std.ascii.eqlIgnoreCase(fn_name, "sum") or
            std.ascii.eqlIgnoreCase(fn_name, "avg"))
        {
            if (val != .null_val) {
                self.count += 1;
                switch (val) {
                    .int_val => |n| self.sum_int += n,
                    .float_val => |f| {
                        self.sum_float += f;
                        self.is_float = true;
                    },
                    else => {},
                }
            }
        } else if (std.ascii.eqlIgnoreCase(fn_name, "min")) {
            if (val != .null_val) {
                if (self.min == null or val.lessThan(self.min.?)) self.min = val;
            }
        } else if (std.ascii.eqlIgnoreCase(fn_name, "max")) {
            if (val != .null_val) {
                if (self.max == null or self.max.?.lessThan(val)) self.max = val;
            }
        }
    }

    fn toValue(self: AggAccum, fn_name: []const u8) plan_mod.Value {
        if (std.ascii.eqlIgnoreCase(fn_name, "count")) {
            return .{ .int_val = self.count };
        } else if (std.ascii.eqlIgnoreCase(fn_name, "sum")) {
            if (self.is_float) return .{ .float_val = self.sum_float };
            return .{ .int_val = self.sum_int };
        } else if (std.ascii.eqlIgnoreCase(fn_name, "avg")) {
            if (self.count == 0) return .null_val;
            const total: f64 = if (self.is_float) self.sum_float else @floatFromInt(self.sum_int);
            return .{ .float_val = total / @as(f64, @floatFromInt(self.count)) };
        } else if (std.ascii.eqlIgnoreCase(fn_name, "min")) {
            return self.min orelse .null_val;
        } else if (std.ascii.eqlIgnoreCase(fn_name, "max")) {
            return self.max orelse .null_val;
        }
        return .null_val;
    }
};

fn aggKeyEquals(a: []const ?ColumnValue, b: []const ?ColumnValue) bool {
    if (a.len != b.len) return false;
    for (a, b) |av, bv| {
        if (av == null and bv == null) continue;
        if (av == null or bv == null) return false;
        if (!columnValueToPlanValue(av.?).eql(columnValueToPlanValue(bv.?))) return false;
    }
    return true;
}

// ─── Expression evaluator ─────────────────────────────────────────────────────

fn evalExpr(e: *plan_mod.PlanExpr, ctx: EvalCtx) SqlExecError!plan_mod.Value {
    return switch (e.*) {
        .null_literal => .null_val,
        .bool_literal => |v| .{ .bool_val = v },
        .int_literal => |v| .{ .int_val = v },
        .uint_literal => |v| .{ .uint_val = v },
        .float_literal => |v| .{ .float_val = v },
        .string_literal => |v| .{ .string_val = v },
        .bytes_literal => |v| .{ .bytes_val = v },

        .param => |i| {
            if (i >= ctx.params.len) return error.TypeMismatch;
            return columnValueToPlanValue(ctx.params[i]);
        },

        .nondet => |i| {
            if (i >= ctx.nondet.len) return .null_val;
            return switch (ctx.nondet[i]) {
                .now => |ts| .{ .int_val = ts },
                .random => |b| .{ .bytes_val = &b },
                .uuid_v7 => |b| .{ .bytes_val = &b },
            };
        },

        .column => |idx| {
            const row = ctx.row orelse return .null_val;
            if (idx >= row.len) return .null_val;
            const cv = row[idx] orelse return .null_val;
            return columnValueToPlanValue(cv);
        },

        .fn_call => |f| try evalBuiltin(f.name, f.args, ctx),

        .binary => |b| try evalBinary(b.op, b.left, b.right, ctx),

        .unary => |u| switch (u.op) {
            .neg => {
                const v = try evalExpr(u.expr, ctx);
                return switch (v) {
                    .int_val => |n| .{ .int_val = -n },
                    .float_val => |n| .{ .float_val = -n },
                    else => error.TypeMismatch,
                };
            },
            .not => {
                const v = try evalExpr(u.expr, ctx);
                return .{ .bool_val = !(v.toBool() orelse return error.TypeMismatch) };
            },
        },

        .is_null => |inner| blk: {
            const v = try evalExpr(inner, ctx);
            break :blk .{ .bool_val = v == .null_val };
        },
        .is_not_null => |inner| blk: {
            const v = try evalExpr(inner, ctx);
            break :blk .{ .bool_val = v != .null_val };
        },

        .cast => |c| {
            const v = try evalExpr(c.expr, ctx);
            return castValue(v, c.to) catch error.TypeMismatch;
        },

        .case_searched => |cs| blk: {
            for (cs.whens) |w| {
                const cond = try evalExpr(w.cond, ctx);
                if (cond.toBool() orelse false) {
                    break :blk try evalExpr(w.result, ctx);
                }
            }
            if (cs.else_expr) |ee| break :blk try evalExpr(ee, ctx);
            break :blk .null_val;
        },

        .table_column => |tc| {
            // In a join context, the combined row has left then right columns.
            // table_idx and col_idx were set by the planner; for M5 we treat the
            // absolute position as table_idx * table_width + col_idx — but since
            // the planner now emits .column for resolved refs, this path is only
            // hit for unresolved cases. Return null safely.
            _ = tc;
            return .null_val;
        },
    };
}

fn evalBinary(
    op: ast.BinOp,
    left: *plan_mod.PlanExpr,
    right: *plan_mod.PlanExpr,
    ctx: EvalCtx,
) SqlExecError!plan_mod.Value {
    const lv = try evalExpr(left, ctx);
    const rv = try evalExpr(right, ctx);

    if (lv == .null_val or rv == .null_val) {
        return switch (op) {
            .eq, .neq, .lt, .gt, .lte, .gte => .null_val,
            .and_op => if (lv == .null_val and rv.toBool() == false) .{ .bool_val = false } else .null_val,
            .or_op => if (lv == .null_val and rv.toBool() == true) .{ .bool_val = true } else .null_val,
            else => .null_val,
        };
    }

    return switch (op) {
        .add => switch (lv) {
            .int_val => |a| switch (rv) {
                .int_val => |b| .{ .int_val = a + b },
                else => error.TypeMismatch,
            },
            .float_val => |a| switch (rv) {
                .float_val => |b| .{ .float_val = a + b },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        },
        .sub => switch (lv) {
            .int_val => |a| switch (rv) {
                .int_val => |b| .{ .int_val = a - b },
                else => error.TypeMismatch,
            },
            .float_val => |a| switch (rv) {
                .float_val => |b| .{ .float_val = a - b },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        },
        .mul => switch (lv) {
            .int_val => |a| switch (rv) {
                .int_val => |b| .{ .int_val = a * b },
                else => error.TypeMismatch,
            },
            .float_val => |a| switch (rv) {
                .float_val => |b| .{ .float_val = a * b },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        },
        .div => switch (lv) {
            .int_val => |a| switch (rv) {
                .int_val => |b| if (b == 0) error.DivisionByZero else .{ .int_val = @divTrunc(a, b) },
                else => error.TypeMismatch,
            },
            .float_val => |a| switch (rv) {
                .float_val => |b| .{ .float_val = a / b },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        },
        .mod => switch (lv) {
            .int_val => |a| switch (rv) {
                .int_val => |b| if (b == 0) error.DivisionByZero else .{ .int_val = @rem(a, b) },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        },
        .eq => .{ .bool_val = lv.eql(rv) },
        .neq => .{ .bool_val = !lv.eql(rv) },
        .lt => .{ .bool_val = lv.lessThan(rv) },
        .gt => .{ .bool_val = rv.lessThan(lv) },
        .lte => .{ .bool_val = lv.lessThan(rv) or lv.eql(rv) },
        .gte => .{ .bool_val = rv.lessThan(lv) or lv.eql(rv) },
        .and_op => .{ .bool_val = (lv.toBool() orelse false) and (rv.toBool() orelse false) },
        .or_op => .{ .bool_val = (lv.toBool() orelse false) or (rv.toBool() orelse false) },
        .concat => switch (lv) {
            .string_val => |a| switch (rv) {
                .string_val => |b| blk: {
                    const s = try ctx.alloc.alloc(u8, a.len + b.len);
                    @memcpy(s[0..a.len], a);
                    @memcpy(s[a.len..], b);
                    break :blk .{ .string_val = s };
                },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        },
        .contains, .contained => .null_val, // JSON ops - simplified
        .arrow, .darrow => .null_val, // JSON ops - simplified
    };
}

fn evalBuiltin(name: []const u8, args: []*plan_mod.PlanExpr, ctx: EvalCtx) SqlExecError!plan_mod.Value {
    if (std.ascii.eqlIgnoreCase(name, "in_list")) {
        if (args.len < 1) return .{ .bool_val = false };
        const needle = try evalExpr(args[0], ctx);
        for (args[1..]) |a| {
            const v = try evalExpr(a, ctx);
            if (needle.eql(v)) return .{ .bool_val = true };
        }
        return .{ .bool_val = false };
    }
    if (std.ascii.eqlIgnoreCase(name, "not_in_list")) {
        if (args.len < 1) return .{ .bool_val = true };
        const needle = try evalExpr(args[0], ctx);
        for (args[1..]) |a| {
            const v = try evalExpr(a, ctx);
            if (needle.eql(v)) return .{ .bool_val = false };
        }
        return .{ .bool_val = true };
    }
    if (std.ascii.eqlIgnoreCase(name, "like")) {
        if (args.len != 2) return error.TypeMismatch;
        const s = (try evalExpr(args[0], ctx)).string_val;
        const pat = (try evalExpr(args[1], ctx)).string_val;
        return .{ .bool_val = likeMatch(s, pat) };
    }
    if (std.ascii.eqlIgnoreCase(name, "coalesce")) {
        for (args) |a| {
            const v = try evalExpr(a, ctx);
            if (v != .null_val) return v;
        }
        return .null_val;
    }
    if (std.ascii.eqlIgnoreCase(name, "length") or std.ascii.eqlIgnoreCase(name, "char_length")) {
        if (args.len != 1) return error.TypeMismatch;
        const v = try evalExpr(args[0], ctx);
        return switch (v) {
            .string_val => |s| .{ .int_val = @intCast(s.len) },
            .bytes_val => |b| .{ .int_val = @intCast(b.len) },
            else => error.TypeMismatch,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "lower")) {
        if (args.len != 1) return error.TypeMismatch;
        const s = (try evalExpr(args[0], ctx)).string_val;
        const out = try ctx.alloc.dupe(u8, s);
        for (out) |*c| c.* = std.ascii.toLower(c.*);
        return .{ .string_val = out };
    }
    if (std.ascii.eqlIgnoreCase(name, "upper")) {
        if (args.len != 1) return error.TypeMismatch;
        const s = (try evalExpr(args[0], ctx)).string_val;
        const out = try ctx.alloc.dupe(u8, s);
        for (out) |*c| c.* = std.ascii.toUpper(c.*);
        return .{ .string_val = out };
    }
    if (std.ascii.eqlIgnoreCase(name, "trim")) {
        if (args.len != 1) return error.TypeMismatch;
        const s = (try evalExpr(args[0], ctx)).string_val;
        return .{ .string_val = std.mem.trim(u8, s, " \t\n\r") };
    }
    if (std.ascii.eqlIgnoreCase(name, "ltrim")) {
        if (args.len != 1) return error.TypeMismatch;
        const s = (try evalExpr(args[0], ctx)).string_val;
        var i: usize = 0;
        while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) i += 1;
        return .{ .string_val = s[i..] };
    }
    if (std.ascii.eqlIgnoreCase(name, "rtrim")) {
        if (args.len != 1) return error.TypeMismatch;
        const s = (try evalExpr(args[0], ctx)).string_val;
        var i: usize = s.len;
        while (i > 0 and (s[i - 1] == ' ' or s[i - 1] == '\t' or s[i - 1] == '\n' or s[i - 1] == '\r')) i -= 1;
        return .{ .string_val = s[0..i] };
    }
    if (std.ascii.eqlIgnoreCase(name, "substr") or std.ascii.eqlIgnoreCase(name, "substring")) {
        if (args.len < 2) return error.TypeMismatch;
        const s = (try evalExpr(args[0], ctx)).string_val;
        const start_v = try evalExpr(args[1], ctx);
        const start: usize = if (start_v == .int_val) @intCast(@max(0, start_v.int_val - 1)) else 0;
        if (args.len >= 3) {
            const len_v = try evalExpr(args[2], ctx);
            const len: usize = if (len_v == .int_val) @intCast(@max(0, len_v.int_val)) else 0;
            const end = @min(start + len, s.len);
            if (start >= s.len) return .{ .string_val = "" };
            return .{ .string_val = s[start..end] };
        }
        if (start >= s.len) return .{ .string_val = "" };
        return .{ .string_val = s[start..] };
    }
    if (std.ascii.eqlIgnoreCase(name, "replace")) {
        if (args.len != 3) return error.TypeMismatch;
        const s = (try evalExpr(args[0], ctx)).string_val;
        const from = (try evalExpr(args[1], ctx)).string_val;
        const to = (try evalExpr(args[2], ctx)).string_val;
        if (from.len == 0) return .{ .string_val = s };
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < s.len) {
            if (i + from.len <= s.len and std.mem.eql(u8, s[i .. i + from.len], from)) {
                try buf.appendSlice(ctx.alloc, to);
                i += from.len;
            } else {
                try buf.append(ctx.alloc, s[i]);
                i += 1;
            }
        }
        return .{ .string_val = try buf.toOwnedSlice(ctx.alloc) };
    }
    if (std.ascii.eqlIgnoreCase(name, "concat")) {
        var result: std.ArrayList(u8) = .empty;
        for (args) |a| {
            const v = try evalExpr(a, ctx);
            switch (v) {
                .string_val => |s| try result.appendSlice(ctx.alloc, s),
                .int_val => |n| {
                    const s = try std.fmt.allocPrint(ctx.alloc, "{d}", .{n});
                    defer ctx.alloc.free(s);
                    try result.appendSlice(ctx.alloc, s);
                },
                .float_val => |f| {
                    const s = try std.fmt.allocPrint(ctx.alloc, "{d}", .{f});
                    defer ctx.alloc.free(s);
                    try result.appendSlice(ctx.alloc, s);
                },
                else => {},
            }
        }
        return .{ .string_val = try result.toOwnedSlice(ctx.alloc) };
    }
    if (std.ascii.eqlIgnoreCase(name, "nullif")) {
        if (args.len != 2) return error.TypeMismatch;
        const a = try evalExpr(args[0], ctx);
        const b = try evalExpr(args[1], ctx);
        return if (a.eql(b)) .null_val else a;
    }
    if (std.ascii.eqlIgnoreCase(name, "greatest")) {
        if (args.len == 0) return .null_val;
        var best = try evalExpr(args[0], ctx);
        for (args[1..]) |a| {
            const v = try evalExpr(a, ctx);
            if (v != .null_val and best.lessThan(v)) best = v;
        }
        return best;
    }
    if (std.ascii.eqlIgnoreCase(name, "least")) {
        if (args.len == 0) return .null_val;
        var best = try evalExpr(args[0], ctx);
        for (args[1..]) |a| {
            const v = try evalExpr(a, ctx);
            if (v != .null_val and v.lessThan(best)) best = v;
        }
        return best;
    }
    if (std.ascii.eqlIgnoreCase(name, "abs")) {
        if (args.len != 1) return error.TypeMismatch;
        const v = try evalExpr(args[0], ctx);
        return switch (v) {
            .int_val => |n| .{ .int_val = if (n < 0) -n else n },
            .float_val => |f| .{ .float_val = @abs(f) },
            else => error.TypeMismatch,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "floor")) {
        if (args.len != 1) return error.TypeMismatch;
        const v = try evalExpr(args[0], ctx);
        return switch (v) {
            .float_val => |f| .{ .float_val = @floor(f) },
            .int_val => v,
            else => error.TypeMismatch,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "ceil") or std.ascii.eqlIgnoreCase(name, "ceiling")) {
        if (args.len != 1) return error.TypeMismatch;
        const v = try evalExpr(args[0], ctx);
        return switch (v) {
            .float_val => |f| .{ .float_val = @ceil(f) },
            .int_val => v,
            else => error.TypeMismatch,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "round")) {
        if (args.len < 1) return error.TypeMismatch;
        const v = try evalExpr(args[0], ctx);
        return switch (v) {
            .float_val => |f| .{ .float_val = @round(f) },
            .int_val => v,
            else => error.TypeMismatch,
        };
    }
    // Unknown functions return null (user WASM functions handled separately)
    return .null_val;
}

fn likeMatch(s: []const u8, pattern: []const u8) bool {
    // Simple % and _ matching
    var si: usize = 0;
    var pi: usize = 0;
    var star_pi: usize = std.math.maxInt(usize);
    var star_si: usize = 0;

    while (si < s.len) {
        if (pi < pattern.len and (pattern[pi] == '_' or pattern[pi] == s[si])) {
            si += 1;
            pi += 1;
        } else if (pi < pattern.len and pattern[pi] == '%') {
            star_pi = pi;
            star_si = si;
            pi += 1;
        } else if (star_pi != std.math.maxInt(usize)) {
            star_si += 1;
            si = star_si;
            pi = star_pi + 1;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '%') pi += 1;
    return pi == pattern.len;
}

// ─── Type conversion helpers ──────────────────────────────────────────────────

fn columnValueToPlanValue(cv: ColumnValue) plan_mod.Value {
    return switch (cv) {
        .bool_t => |v| .{ .bool_val = v },
        .int8 => |v| .{ .int_val = v },
        .int16 => |v| .{ .int_val = v },
        .int32 => |v| .{ .int_val = v },
        .int64 => |v| .{ .int_val = v },
        .uint8 => |v| .{ .uint_val = v },
        .uint16 => |v| .{ .uint_val = v },
        .uint32 => |v| .{ .uint_val = v },
        .uint64 => |v| .{ .uint_val = v },
        .float32 => |v| .{ .float_val = v },
        .float64 => |v| .{ .float_val = v },
        .string => |v| .{ .string_val = v },
        .bytes => |v| .{ .bytes_val = v },
    };
}

fn planValueToColumnValue(v: plan_mod.Value, alloc: std.mem.Allocator) !ColumnValue {
    return switch (v) {
        .null_val => error.TypeMismatch,
        .bool_val => |b| .{ .bool_t = b },
        .int_val => |n| .{ .int64 = n },
        .uint_val => |n| .{ .uint64 = n },
        .float_val => |f| .{ .float64 = f },
        .string_val => |s| .{ .string = try alloc.dupe(u8, s) },
        .bytes_val => |b| .{ .bytes = try alloc.dupe(u8, b) },
        .opaque_val => |b| .{ .bytes = try alloc.dupe(u8, b) },
    };
}

fn planValueToTypedColumnValue(v: plan_mod.Value, typ: ast.SqlType, alloc: std.mem.Allocator) SqlExecError!ColumnValue {
    return switch (typ) {
        .bool => .{ .bool_t = v.toBool() orelse return error.TypeMismatch },
        .int8 => switch (v) {
            .int_val => |n| .{ .int8 = @intCast(n) },
            else => error.TypeMismatch,
        },
        .int16 => switch (v) {
            .int_val => |n| .{ .int16 = @intCast(n) },
            else => error.TypeMismatch,
        },
        .int32 => switch (v) {
            .int_val => |n| .{ .int32 = @intCast(n) },
            else => error.TypeMismatch,
        },
        .int64 => switch (v) {
            .int_val => |n| .{ .int64 = n },
            else => error.TypeMismatch,
        },
        .uint8 => switch (v) {
            .uint_val => |n| .{ .uint8 = @intCast(n) },
            else => error.TypeMismatch,
        },
        .uint16 => switch (v) {
            .uint_val => |n| .{ .uint16 = @intCast(n) },
            else => error.TypeMismatch,
        },
        .uint32 => switch (v) {
            .uint_val => |n| .{ .uint32 = @intCast(n) },
            else => error.TypeMismatch,
        },
        .uint64 => switch (v) {
            .uint_val => |n| .{ .uint64 = n },
            else => error.TypeMismatch,
        },
        .float32 => switch (v) {
            .float_val => |f| .{ .float32 = @floatCast(f) },
            else => error.TypeMismatch,
        },
        .float64 => switch (v) {
            .float_val => |f| .{ .float64 = f },
            else => error.TypeMismatch,
        },
        .string => switch (v) {
            .string_val => |s| .{ .string = try alloc.dupe(u8, s) },
            else => error.TypeMismatch,
        },
        .bytes => switch (v) {
            .bytes_val => |b| .{ .bytes = try alloc.dupe(u8, b) },
            else => error.TypeMismatch,
        },
        else => planValueToColumnValue(v, alloc) catch error.TypeMismatch,
    };
}

fn castValue(v: plan_mod.Value, to: ast.SqlType) !plan_mod.Value {
    return switch (to) {
        .int64 => switch (v) {
            .int_val => v,
            .uint_val => |n| .{ .int_val = @intCast(n) },
            .float_val => |f| .{ .int_val = @as(i64, @intFromFloat(f)) },
            else => error.TypeMismatch,
        },
        .float64 => switch (v) {
            .float_val => v,
            .int_val => |n| .{ .float_val = @floatFromInt(n) },
            .uint_val => |n| .{ .float_val = @floatFromInt(n) },
            else => error.TypeMismatch,
        },
        .string => switch (v) {
            .string_val => v,
            else => error.TypeMismatch,
        },
        else => v,
    };
}

fn defaultValue(typ: ast.SqlType) ColumnValue {
    return switch (typ) {
        .bool => .{ .bool_t = false },
        .int8 => .{ .int8 = 0 },
        .int16 => .{ .int16 = 0 },
        .int32 => .{ .int32 = 0 },
        .int64 => .{ .int64 = 0 },
        .uint8 => .{ .uint8 = 0 },
        .uint16 => .{ .uint16 = 0 },
        .uint32 => .{ .uint32 = 0 },
        .uint64 => .{ .uint64 = 0 },
        .float32 => .{ .float32 = 0.0 },
        .float64 => .{ .float64 = 0.0 },
        .string => .{ .string = "" },
        .bytes => .{ .bytes = "" },
        else => .{ .bytes = "" },
    };
}

fn buildPrimaryKey(
    tbl: *const schema_mod.TableSchema,
    col_ids: []const schema_mod.ColumnId,
    values: []const ColumnValue,
    alloc: std.mem.Allocator,
) SqlExecError![]const u8 {
    var key_buf: std.ArrayList(u8) = .empty;
    for (tbl.primary_key) |pk_col_id| {
        // Find the value for this PK column in our values list
        for (col_ids, 0..) |cid, i| {
            if (cid == pk_col_id and i < values.len) {
                try encodeKeyComponent(&key_buf, values[i], alloc);
                break;
            }
        }
    }
    return key_buf.toOwnedSlice(alloc);
}

fn encodeKeyComponent(buf: *std.ArrayList(u8), v: ColumnValue, alloc: std.mem.Allocator) !void {
    switch (v) {
        .bool_t => |b| try buf.append(alloc, if (b) 1 else 0),
        .int8 => |n| try buf.append(alloc, @bitCast(n)),
        .int16 => |n| {
            var b: [2]u8 = undefined;
            std.mem.writeInt(i16, &b, n, .big);
            try buf.appendSlice(alloc, &b);
        },
        .int32 => |n| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(i32, &b, n, .big);
            try buf.appendSlice(alloc, &b);
        },
        .int64 => |n| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(i64, &b, n, .big);
            try buf.appendSlice(alloc, &b);
        },
        .uint8 => |n| try buf.append(alloc, n),
        .uint16 => |n| {
            var b: [2]u8 = undefined;
            std.mem.writeInt(u16, &b, n, .big);
            try buf.appendSlice(alloc, &b);
        },
        .uint32 => |n| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, n, .big);
            try buf.appendSlice(alloc, &b);
        },
        .uint64 => |n| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, n, .big);
            try buf.appendSlice(alloc, &b);
        },
        .float32 => |n| {
            const bits = @as(u32, @bitCast(n));
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, bits, .big);
            try buf.appendSlice(alloc, &b);
        },
        .float64 => |n| {
            const bits = @as(u64, @bitCast(n));
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, bits, .big);
            try buf.appendSlice(alloc, &b);
        },
        .string => |s| {
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @intCast(s.len), .big);
            try buf.appendSlice(alloc, &len_buf);
            try buf.appendSlice(alloc, s);
        },
        .bytes => |b| {
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @intCast(b.len), .big);
            try buf.appendSlice(alloc, &len_buf);
            try buf.appendSlice(alloc, b);
        },
    }
}

fn pkColumnIds(tbl: *const schema_mod.TableSchema) []const schema_mod.ColumnId {
    return tbl.primary_key;
}

// ─── Params serialization ─────────────────────────────────────────────────────

/// Serialize ColumnValues into the params wire format.
/// Format: [u16 count] [for each: u8 type_tag] [value bytes]
pub fn encodeParams(values: []const ColumnValue, alloc: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var count_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &count_buf, @intCast(values.len), .little);
    try buf.appendSlice(alloc, &count_buf);
    for (values) |v| {
        try encodeParamValue(&buf, v, alloc);
    }
    return buf.toOwnedSlice(alloc);
}

fn encodeParamValue(buf: *std.ArrayList(u8), v: ColumnValue, alloc: std.mem.Allocator) !void {
    const tag: u8 = @intFromEnum(@as(ColumnType, v));
    try buf.append(alloc, tag);
    switch (v) {
        .bool_t => |b| try buf.append(alloc, if (b) 1 else 0),
        .int8 => |n| try buf.append(alloc, @bitCast(n)),
        .int16 => |n| {
            var b: [2]u8 = undefined;
            std.mem.writeInt(i16, &b, n, .little);
            try buf.appendSlice(alloc, &b);
        },
        .int32 => |n| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(i32, &b, n, .little);
            try buf.appendSlice(alloc, &b);
        },
        .int64 => |n| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(i64, &b, n, .little);
            try buf.appendSlice(alloc, &b);
        },
        .uint8 => |n| try buf.append(alloc, n),
        .uint16 => |n| {
            var b: [2]u8 = undefined;
            std.mem.writeInt(u16, &b, n, .little);
            try buf.appendSlice(alloc, &b);
        },
        .uint32 => |n| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, n, .little);
            try buf.appendSlice(alloc, &b);
        },
        .uint64 => |n| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, n, .little);
            try buf.appendSlice(alloc, &b);
        },
        .float32 => |n| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, @bitCast(n), .little);
            try buf.appendSlice(alloc, &b);
        },
        .float64 => |n| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, @bitCast(n), .little);
            try buf.appendSlice(alloc, &b);
        },
        .string => |s| {
            var lb: [4]u8 = undefined;
            std.mem.writeInt(u32, &lb, @intCast(s.len), .little);
            try buf.appendSlice(alloc, &lb);
            try buf.appendSlice(alloc, s);
        },
        .bytes => |s| {
            var lb: [4]u8 = undefined;
            std.mem.writeInt(u32, &lb, @intCast(s.len), .little);
            try buf.appendSlice(alloc, &lb);
            try buf.appendSlice(alloc, s);
        },
    }
}

/// Decode params wire format into ColumnValues using declared types.
/// When types is empty (non-TRANSACTION queries), falls back to tag-based decoding.
pub fn decodeParams(data: []const u8, types: []const ast.SqlType, alloc: std.mem.Allocator) ![]ColumnValue {
    if (data.len < 2) {
        if (types.len == 0) return &.{};
        return error.TypeMismatch;
    }
    const count = std.mem.readInt(u16, data[0..2], .little);
    if (count == 0) return &.{};
    if (types.len > 0 and count != types.len) return error.TypeMismatch;
    const values = try alloc.alloc(ColumnValue, count);
    var pos: usize = 2;
    for (0..count) |i| {
        if (pos >= data.len) return error.TypeMismatch;
        const tag_byte = data[pos];
        pos += 1;
        if (types.len > 0) {
            values[i] = try decodeParamValue(data, &pos, types[i], alloc);
        } else {
            // No declared types: decode using the tag byte from ColumnType enum
            values[i] = try decodeParamValueByTag(data, &pos, tag_byte, alloc);
        }
    }
    return values;
}

fn decodeParamValue(data: []const u8, pos: *usize, typ: ast.SqlType, alloc: std.mem.Allocator) !ColumnValue {
    return switch (typ) {
        .bool => blk: {
            const b = data[pos.*];
            pos.* += 1;
            break :blk .{ .bool_t = b != 0 };
        },
        .int8 => blk: {
            const n: i8 = @bitCast(data[pos.*]);
            pos.* += 1;
            break :blk .{ .int8 = n };
        },
        .int16 => blk: {
            const n = std.mem.readInt(i16, data[pos.*..][0..2], .little);
            pos.* += 2;
            break :blk .{ .int16 = n };
        },
        .int32 => blk: {
            const n = std.mem.readInt(i32, data[pos.*..][0..4], .little);
            pos.* += 4;
            break :blk .{ .int32 = n };
        },
        .int64 => blk: {
            const n = std.mem.readInt(i64, data[pos.*..][0..8], .little);
            pos.* += 8;
            break :blk .{ .int64 = n };
        },
        .uint8 => blk: {
            const n = data[pos.*];
            pos.* += 1;
            break :blk .{ .uint8 = n };
        },
        .uint16 => blk: {
            const n = std.mem.readInt(u16, data[pos.*..][0..2], .little);
            pos.* += 2;
            break :blk .{ .uint16 = n };
        },
        .uint32 => blk: {
            const n = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            break :blk .{ .uint32 = n };
        },
        .uint64 => blk: {
            const n = std.mem.readInt(u64, data[pos.*..][0..8], .little);
            pos.* += 8;
            break :blk .{ .uint64 = n };
        },
        .float32 => blk: {
            const bits = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            break :blk .{ .float32 = @bitCast(bits) };
        },
        .float64 => blk: {
            const bits = std.mem.readInt(u64, data[pos.*..][0..8], .little);
            pos.* += 8;
            break :blk .{ .float64 = @bitCast(bits) };
        },
        .string => blk: {
            const len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            const s = try alloc.dupe(u8, data[pos.* .. pos.* + len]);
            pos.* += len;
            break :blk .{ .string = s };
        },
        .bytes, .uuid, .timestamp, .interval_months, .interval_micros, .json, .vector, .decimal => blk: {
            const len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            const b = try alloc.dupe(u8, data[pos.* .. pos.* + len]);
            pos.* += len;
            break :blk .{ .bytes = b };
        },
        else => error.TypeMismatch,
    };
}

fn decodeParamValueByTag(data: []const u8, pos: *usize, tag: u8, alloc: std.mem.Allocator) !ColumnValue {
    const col_type: ColumnType = switch (tag) {
        0 => .bool_t,
        1 => .int8,
        2 => .int16,
        3 => .int32,
        4 => .int64,
        5 => .uint8,
        6 => .uint16,
        7 => .uint32,
        8 => .uint64,
        9 => .float32,
        10 => .float64,
        11 => .bytes,
        12 => .string,
        else => return error.TypeMismatch,
    };
    return switch (col_type) {
        .bool_t => blk: {
            const b = data[pos.*];
            pos.* += 1;
            break :blk .{ .bool_t = b != 0 };
        },
        .int8 => blk: {
            const n: i8 = @bitCast(data[pos.*]);
            pos.* += 1;
            break :blk .{ .int8 = n };
        },
        .int16 => blk: {
            const n = std.mem.readInt(i16, data[pos.*..][0..2], .little);
            pos.* += 2;
            break :blk .{ .int16 = n };
        },
        .int32 => blk: {
            const n = std.mem.readInt(i32, data[pos.*..][0..4], .little);
            pos.* += 4;
            break :blk .{ .int32 = n };
        },
        .int64 => blk: {
            const n = std.mem.readInt(i64, data[pos.*..][0..8], .little);
            pos.* += 8;
            break :blk .{ .int64 = n };
        },
        .uint8 => blk: {
            const n = data[pos.*];
            pos.* += 1;
            break :blk .{ .uint8 = n };
        },
        .uint16 => blk: {
            const n = std.mem.readInt(u16, data[pos.*..][0..2], .little);
            pos.* += 2;
            break :blk .{ .uint16 = n };
        },
        .uint32 => blk: {
            const n = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            break :blk .{ .uint32 = n };
        },
        .uint64 => blk: {
            const n = std.mem.readInt(u64, data[pos.*..][0..8], .little);
            pos.* += 8;
            break :blk .{ .uint64 = n };
        },
        .float32 => blk: {
            const b = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            break :blk .{ .float32 = @bitCast(b) };
        },
        .float64 => blk: {
            const b = std.mem.readInt(u64, data[pos.*..][0..8], .little);
            pos.* += 8;
            break :blk .{ .float64 = @bitCast(b) };
        },
        .string => blk: {
            const len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            const s = try alloc.dupe(u8, data[pos.* .. pos.* + len]);
            pos.* += len;
            break :blk .{ .string = s };
        },
        .bytes => blk: {
            const len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            const b = try alloc.dupe(u8, data[pos.* .. pos.* + len]);
            pos.* += len;
            break :blk .{ .bytes = b };
        },
    };
}
