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
const cdc_mod = @import("cdc.zig");

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
pub const ExecResult = union(enum) {
    ok: struct { rows_affected: u64, result_set: ?ResultSet = null },
    abort: struct { code: executor_mod.AbortCode, detail: []const u8 },
};
pub const AbortCode = executor_mod.AbortCode;

pub const SqlExecError = error{
    ConstraintViolation,
    ForeignKeyViolation,
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
        for (self.columns) |name| self.alloc.free(name);
        self.alloc.free(self.columns);
    }
};

/// Context passed to expression evaluator during plan execution.
const EvalCtx = struct {
    executor: *SqlExecutor,
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
    /// Optional CDC manager. When set, mutations are captured and fanned out to subscribers.
    cdc: ?*cdc_mod.CdcManager = null,
    error_detail: [256]u8 = undefined,
    error_detail_len: usize = 0,

    pub fn lastDetail(self: *const SqlExecutor) []const u8 {
        return self.error_detail[0..self.error_detail_len];
    }

    fn setDetail(self: *SqlExecutor, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.error_detail, fmt, args) catch &self.error_detail;
        self.error_detail_len = s.len;
    }

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

    /// Wire a CdcManager into this executor so committed mutations fan out to subscribers.
    pub fn initCdc(self: *SqlExecutor, cdc: *cdc_mod.CdcManager) void {
        self.cdc = cdc;
    }

    pub fn currentSeq(self: *const SqlExecutor) Seq {
        return self.committed_seq;
    }

    /// Domain boundary — validates and dispatches a LogEntry.
    /// Non-txn_intent entries advance committed_seq and return ok.
    /// For txn_intent: CRC-verifies and deserializes at the boundary, then
    /// hands a proven-valid entry to runValidated.
    pub fn run(self: *SqlExecutor, entry: LogEntry) !ExecResult {
        if (entry.header.kind != .txn_intent) {
            self.committed_seq = entry.header.seq;
            return .{ .ok = .{ .rows_affected = 0 } };
        }
        // This is the domain boundary — CRC-verify and deserialize before the core.
        var validated = executor_mod.validateTxnEntry(entry, self.alloc) catch |e| {
            self.committed_seq = entry.header.seq;
            return switch (e) {
                error.CrcMismatch => .{ .abort = .{ .code = .bad_params, .detail = "crc mismatch" } },
                else => .{ .abort = .{ .code = .bad_params, .detail = "invalid payload" } },
            };
        };
        defer validated.decoded.deinit();
        return self.runValidated(validated);
    }

    /// Domain core — receives a proven-valid TxnIntent entry. No input
    /// validation here; only business invariants (missing_query, constraint_violation).
    pub fn runValidated(self: *SqlExecutor, validated: executor_mod.ValidatedTxnEntry) !ExecResult {
        defer self.committed_seq = validated.seq;
        const decoded = validated.decoded;

        const rq = self.registry.lookup(decoded.query_hash.*) orelse {
            return .{ .abort = .{ .code = .missing_query, .detail = "unknown query hash" } };
        };

        // Domain boundary — decode raw param bytes into typed ColumnValues using the registered schema.
        const params = decodeParams(decoded.params, rq.param_types, self.alloc) catch {
            return .{ .abort = .{ .code = .bad_params, .detail = "param decode failed" } };
        };
        defer {
            for (params) |v| v.freeIfOwned(self.alloc);
            self.alloc.free(params);
        }

        const has_returning = blk: {
            for (rq.plan.stmts) |stmt| {
                switch (stmt) {
                    .insert => |ins| if (ins.returning.len > 0) break :blk true,
                    .update => |upd| if (upd.returning.len > 0) break :blk true,
                    .delete => |del| if (del.returning.len > 0) break :blk true,
                    else => {},
                }
            }
            break :blk false;
        };

        var returning_rows: std.ArrayList([]const ?ColumnValue) = .empty;
        defer {
            if (!has_returning) {
                for (returning_rows.items) |r| SqlExecutor.freeRowValues(r, self.alloc);
                returning_rows.deinit(self.alloc);
            }
        }

        const result = self.executePlan(
            rq.plan,
            params,
            decoded.nondet,
            validated.seq,
            validated.epoch,
            .txn_intent,
            if (has_returning) &returning_rows else null,
        ) catch |e| {
            return switch (e) {
                error.AssertionFailed => .{ .abort = .{ .code = .constraint_violation, .detail = "assertion failed" } },
                error.ConstraintViolation => .{ .abort = .{ .code = .constraint_violation, .detail = "constraint violation" } },
                else => return e,
            };
        };

        if (has_returning and returning_rows.items.len > 0) {
            const result_set = try buildReturningResultSet(rq.plan, returning_rows.toOwnedSlice(self.alloc) catch &.{}, self.alloc);
            return .{ .ok = .{ .rows_affected = result, .result_set = result_set } };
        }

        return .{ .ok = .{ .rows_affected = result, .result_set = null } };
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
            .executor = self,
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
        return self.executePlan(plan, params, nondet, seq, 0, .txn_intent, null);
    }

    fn executePlan(
        self: *SqlExecutor,
        plan: plan_mod.ExecutionPlan,
        params: []const ColumnValue,
        nondet: []const ResolvedValue,
        seq: Seq,
        epoch: log_mod.Epoch,
        entry_kind: log_mod.EntryKind,
        returning_rows: ?*std.ArrayList([]const ?ColumnValue),
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
            .executor = self,
            .params = params,
            .nondet = nondet,
            .seq = seq,
            .row = null,
            .schema = self.schema,
            .alloc = self.alloc,
        };

        for (plan.stmts) |stmt| {
            try self.executeStmt(stmt, ctx, &mutations, returning_rows);
        }

        // Capture before-images for CDC (before storage.apply)
        var before: ?cdc_mod.BeforeImages = null;
        if (self.cdc) |cdc| {
            if (mutations.items.len > 0) {
                before = cdc.captureBeforeImages(mutations.items, self.storage, seq, self.alloc) catch null;
            }
        }
        defer if (before) |*b| b.deinit();

        const count: u64 = @intCast(mutations.items.len);
        self.storage.apply(mutations.items, seq) catch return error.TableNotFound;

        // Dispatch CDC events (after storage.apply)
        if (self.cdc) |cdc| {
            if (before) |b| {
                cdc.dispatch(seq, epoch, entry_kind, mutations.items, b, self.alloc) catch {};
            }
        }

        return count;
    }

    fn executeStmt(
        self: *SqlExecutor,
        stmt: plan_mod.StmtPlan,
        ctx: EvalCtx,
        mutations: *std.ArrayList(Mutation),
        returning_rows: ?*std.ArrayList([]const ?ColumnValue),
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
            .insert => |ins| try self.executeInsert(ins, ctx, mutations, returning_rows),
            .update => |upd| try self.executeUpdate(upd, ctx, mutations, returning_rows),
            .delete => |del| try self.executeDelete(del, ctx, mutations, returning_rows),
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
                    for (inner.items) |r| SqlExecutor.freeRowValues(r, ctx.alloc);
                    inner.deinit(ctx.alloc);
                }
                try self.executeScan(f.input, ctx, &inner);
                for (inner.items) |row| {
                    var row_ctx = ctx;
                    row_ctx.row = row;
                    const v = try evalExpr(f.predicate, row_ctx);
                    if (v.toBool() orelse false) {
                        const r = try SqlExecutor.dupeRow(row, ctx.alloc);
                        try out.append(ctx.alloc, r);
                    }
                }
            },
            .project => |p| {
                var inner: std.ArrayList([]const ?ColumnValue) = .empty;
                defer {
                    for (inner.items) |r| SqlExecutor.freeRowValues(r, ctx.alloc);
                    inner.deinit(ctx.alloc);
                }
                try self.executeScan(p.input, ctx, &inner);
                var seen = std.StringHashMap(void).init(ctx.alloc);
                defer {
                    var it = seen.keyIterator();
                    while (it.next()) |k| ctx.alloc.free(k.*);
                    seen.deinit();
                }
                for (inner.items) |row| {
                    var eval_arena = std.heap.ArenaAllocator.init(ctx.alloc);
                    defer eval_arena.deinit();
                    var row_ctx = ctx;
                    row_ctx.row = row;
                    row_ctx.alloc = eval_arena.allocator();
                    const projected = try ctx.alloc.alloc(?ColumnValue, p.exprs.len);
                    for (p.exprs, 0..) |item, i| {
                        const v = try evalExpr(item.expr, row_ctx);
                        projected[i] = planValueToColumnValue(v, ctx.alloc) catch null;
                    }
                    if (p.distinct) {
                        const key = try serializeRowKey(projected, ctx.alloc);
                        const gop = try seen.getOrPut(key);
                        if (gop.found_existing) {
                            ctx.alloc.free(key);
                            SqlExecutor.freeRowValues(projected, ctx.alloc);
                            continue;
                        }
                    }
                    try out.append(ctx.alloc, projected);
                }
            },
            .limit => |l| {
                var inner: std.ArrayList([]const ?ColumnValue) = .empty;
                defer {
                    for (inner.items) |r| SqlExecutor.freeRowValues(r, ctx.alloc);
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
                    const r = try SqlExecutor.dupeRow(row, ctx.alloc);
                    try out.append(ctx.alloc, r);
                    taken += 1;
                }
            },
            .sort => |s| {
                var inner: std.ArrayList([]const ?ColumnValue) = .empty;
                defer {
                    for (inner.items) |r| SqlExecutor.freeRowValues(r, ctx.alloc);
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
                    try out.append(ctx.alloc, try SqlExecutor.dupeRow(r, ctx.alloc));
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
                    for (inner.items) |r| SqlExecutor.freeRowValues(r, ctx.alloc);
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
                    errdefer ctx.alloc.free(aug);
                    for (row, 0..) |v, i| aug[i] = if (v) |cv| try cv.dupe(ctx.alloc) else null;
                    @memcpy(aug[row.len..], win_results[ri]);
                    try out.append(ctx.alloc, aug);
                }
            },

            .merge => {}, // not a scan context

            .hash_join => |j| {
                var left_rows: std.ArrayList([]const ?ColumnValue) = .empty;
                defer {
                    for (left_rows.items) |r| SqlExecutor.freeRowValues(r, ctx.alloc);
                    left_rows.deinit(ctx.alloc);
                }
                var right_rows: std.ArrayList([]const ?ColumnValue) = .empty;
                defer {
                    for (right_rows.items) |r| SqlExecutor.freeRowValues(r, ctx.alloc);
                    right_rows.deinit(ctx.alloc);
                }
                try self.executeScan(j.left, ctx, &left_rows);
                try self.executeScan(j.right, ctx, &right_rows);

                const right_width = if (right_rows.items.len > 0) right_rows.items[0].len else 0;

                const left_width = if (left_rows.items.len > 0) left_rows.items[0].len else 0;

                // Track which right rows were matched (for RIGHT and FULL joins)
                const right_matched = try ctx.alloc.alloc(bool, right_rows.items.len);
                defer ctx.alloc.free(right_matched);
                @memset(right_matched, false);

                for (left_rows.items) |lr| {
                    var matched = false;
                    for (right_rows.items, 0..) |rr, ri| {
                        const passes = if (j.kind == .cross) true else blk: {
                            const combined = try ctx.alloc.alloc(?ColumnValue, lr.len + rr.len);
                            @memcpy(combined[0..lr.len], lr);
                            @memcpy(combined[lr.len..], rr);
                            var join_ctx = ctx;
                            join_ctx.row = combined;
                            const v = (try evalExpr(j.condition, join_ctx)).toBool() orelse false;
                            ctx.alloc.free(combined);
                            break :blk v;
                        };
                        if (passes) {
                            matched = true;
                            right_matched[ri] = true;
                            const owned = try ctx.alloc.alloc(?ColumnValue, lr.len + rr.len);
                            errdefer ctx.alloc.free(owned);
                            for (lr, 0..) |v, i| owned[i] = if (v) |cv| try cv.dupe(ctx.alloc) else null;
                            for (rr, 0..) |v, i| owned[lr.len + i] = if (v) |cv| try cv.dupe(ctx.alloc) else null;
                            try out.append(ctx.alloc, owned);
                        }
                    }
                    // LEFT and FULL: unmatched left rows get NULL-padded right side
                    if (!matched and (j.kind == .left or j.kind == .full)) {
                        const padded = try ctx.alloc.alloc(?ColumnValue, lr.len + right_width);
                        errdefer ctx.alloc.free(padded);
                        for (lr, 0..) |v, i| padded[i] = if (v) |cv| try cv.dupe(ctx.alloc) else null;
                        for (padded[lr.len..]) |*v| v.* = null;
                        try out.append(ctx.alloc, padded);
                    }
                }
                // RIGHT and FULL: unmatched right rows get NULL-padded left side
                if (j.kind == .right or j.kind == .full) {
                    for (right_rows.items, 0..) |rr, ri| {
                        if (right_matched[ri]) continue;
                        const padded = try ctx.alloc.alloc(?ColumnValue, left_width + rr.len);
                        errdefer ctx.alloc.free(padded);
                        for (padded[0..left_width]) |*v| v.* = null;
                        for (rr, 0..) |v, i| padded[left_width + i] = if (v) |cv| try cv.dupe(ctx.alloc) else null;
                        try out.append(ctx.alloc, padded);
                    }
                }
            },

            .hash_agg => |ha| {
                var inner: std.ArrayList([]const ?ColumnValue) = .empty;
                defer {
                    for (inner.items) |r| SqlExecutor.freeRowValues(r, ctx.alloc);
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
                        SqlExecutor.freeRowValues(g.key, ctx.alloc);
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
                        SqlExecutor.freeRowValues(key, ctx.alloc);
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
                    errdefer ctx.alloc.free(result_row);
                    for (g.key, 0..) |v, i| result_row[i] = if (v) |cv| try cv.dupe(ctx.alloc) else null;
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
        returning_rows: ?*std.ArrayList([]const ?ColumnValue),
    ) SqlExecError!void {
        const tbl = self.schema.getTableById(ins.table_id) orelse return error.TableNotFound;

        switch (ins.source) {
            .values => |rows| {
                for (rows) |row| {
                    const values = try ctx.alloc.alloc(ColumnValue, ins.column_ids.len);
                    errdefer {
                        for (values) |v| v.freeIfOwned(ctx.alloc);
                        ctx.alloc.free(values);
                    }
                    for (ins.column_ids, 0..) |col_id, i| {
                        const pv = try evalExpr(row[i], ctx);
                        const col = tbl.columnById(col_id) orelse return error.ColumnNotFound;
                        values[i] = try planValueToTypedColumnValue(pv, col.typ, ctx.alloc);
                    }
                    try self.checkForeignKeys(tbl, ins.column_ids, values, ctx);
                    const key = try buildPrimaryKey(tbl, ins.column_ids, values, ctx.alloc);
                    try self.appendInsertMutation(ins, tbl, key, values, ctx, mutations, returning_rows);
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
                    try self.checkForeignKeys(tbl, ins.column_ids, values, ctx);
                    const key = try buildPrimaryKey(tbl, ins.column_ids, values, ctx.alloc);
                    try self.appendInsertMutation(ins, tbl, key, values, ctx, mutations, returning_rows);
                }
            },
        }
    }

    /// Resolves ON CONFLICT and appends the appropriate mutation.
    /// Takes ownership of `key` and `values` (frees them on DO NOTHING).
    fn appendInsertMutation(
        self: *SqlExecutor,
        ins: plan_mod.InsertPlan,
        tbl: *const schema_mod.TableSchema,
        key: []const u8,
        values: []ColumnValue,
        ctx: EvalCtx,
        mutations: *std.ArrayList(Mutation),
        returning_rows: ?*std.ArrayList([]const ?ColumnValue),
    ) SqlExecError!void {
        if (ins.on_conflict) |oc| {
            // Check whether the key already exists in storage.
            var existing = self.storage.get(ins.table_id, key, ctx.seq -| 1) catch null;
            defer if (existing) |*ex| ex.deinit(ctx.alloc);

            if (existing != null) {
                switch (oc) {
                    .do_nothing => {
                        // Discard incoming row — keep existing, emit nothing.
                        ctx.alloc.free(key);
                        for (values) |v| v.freeIfOwned(ctx.alloc);
                        ctx.alloc.free(values);
                        return;
                    },
                    .do_update => |assignments| {
                        const ex_row = existing.?;
                        // Build full table-width row from existing values.
                        const new_values = try ctx.alloc.alloc(ColumnValue, tbl.columns.len);
                        errdefer {
                            for (new_values) |v| v.freeIfOwned(ctx.alloc);
                            ctx.alloc.free(new_values);
                        }
                        for (tbl.columns, 0..) |col, i| {
                            new_values[i] = if (i < ex_row.values.len)
                                ex_row.values[i].dupe(ctx.alloc) catch defaultValue(col.typ)
                            else
                                defaultValue(col.typ);
                        }
                        // Build a row context using the existing row values for referencing old columns.
                        const ex_nullable = try ctx.alloc.alloc(?ColumnValue, tbl.columns.len);
                        defer ctx.alloc.free(ex_nullable);
                        @memset(ex_nullable, null);
                        for (ex_row.values, 0..) |v, i| {
                            if (i < ex_nullable.len) ex_nullable[i] = v;
                        }
                        var row_ctx = ctx;
                        row_ctx.row = ex_nullable;
                        // Apply SET assignments.
                        for (assignments) |asgn| {
                            const pv = try evalExpr(asgn.value, row_ctx);
                            const col = tbl.columnById(asgn.column_id) orelse return error.ColumnNotFound;
                            const pos: usize = @intCast(asgn.column_id);
                            if (pos < new_values.len) {
                                new_values[pos].freeIfOwned(ctx.alloc);
                                new_values[pos] = try planValueToTypedColumnValue(pv, col.typ, ctx.alloc);
                            }
                        }
                        // Enforce FK constraints on the updated values.
                        const all_col_ids = try ctx.alloc.alloc(schema_mod.ColumnId, tbl.columns.len);
                        defer ctx.alloc.free(all_col_ids);
                        for (tbl.columns, 0..) |col, i| all_col_ids[i] = col.id;
                        try self.checkForeignKeys(tbl, all_col_ids, new_values, ctx);

                        // Discard the incoming insert values (replaced by update).
                        for (values) |v| v.freeIfOwned(ctx.alloc);
                        ctx.alloc.free(values);

                        try mutations.append(ctx.alloc, .{
                            .kind = .update,
                            .table_id = ins.table_id,
                            .key = key,
                            .values = new_values,
                        });
                        if (returning_rows) |rr| {
                            if (ins.returning.len > 0) {
                                const virtual = try ctx.alloc.alloc(?ColumnValue, new_values.len);
                                defer ctx.alloc.free(virtual);
                                for (new_values, 0..) |v, i| virtual[i] = v;
                                try projectReturning(ins.returning, virtual, ctx, rr);
                            }
                        }
                        return;
                    },
                }
            }
        }

        // No conflict (or no on_conflict clause) — regular insert.
        try mutations.append(ctx.alloc, .{
            .kind = .insert,
            .table_id = ins.table_id,
            .key = key,
            .values = values,
        });
        if (returning_rows) |rr| {
            if (ins.returning.len > 0) {
                const virtual = try buildVirtualRow(tbl.columns.len, ins.column_ids, values, ctx.alloc);
                defer ctx.alloc.free(virtual);
                try projectReturning(ins.returning, virtual, ctx, rr);
            }
        }
    }

    fn executeUpdate(
        self: *SqlExecutor,
        upd: plan_mod.UpdatePlan,
        ctx: EvalCtx,
        mutations: *std.ArrayList(Mutation),
        returning_rows: ?*std.ArrayList([]const ?ColumnValue),
    ) SqlExecError!void {
        const tbl = self.schema.getTableById(upd.table_id) orelse return error.TableNotFound;

        // Pre-load FROM table rows if a FROM clause was specified.
        var from_rows: std.ArrayList([]const ?ColumnValue) = .empty;
        defer {
            for (from_rows.items) |r| SqlExecutor.freeRowValues(r, ctx.alloc);
            from_rows.deinit(ctx.alloc);
        }
        if (upd.from_table_id) |from_id| {
            var fi = self.storage.scan(from_id, KeyRange.all(), ctx.seq -| 1, ctx.alloc) catch return error.TableNotFound;
            defer fi.deinit();
            while (fi.next() catch null) |fr| {
                try from_rows.append(ctx.alloc, try self.rowToValues(fr, &.{}, ctx.alloc));
            }
        }

        var iter = self.storage.scan(upd.table_id, KeyRange.all(), ctx.seq -| 1, ctx.alloc) catch return error.TableNotFound;
        defer iter.deinit();

        while (iter.next() catch null) |row| {
            const row_vals = try self.rowToValues(row, pkColumnIds(tbl), ctx.alloc);
            defer SqlExecutor.freeRowValues(row_vals, ctx.alloc);

            // Build eval row: target cols, then FROM cols (if any).
            // For no-FROM case we avoid the allocation.
            const eval_row: []const ?ColumnValue = if (from_rows.items.len == 0) blk: {
                break :blk row_vals;
            } else blk: {
                // Attempt each FROM row; use the first that satisfies the filter.
                var matched_from: ?[]const ?ColumnValue = null;
                for (from_rows.items) |fv| {
                    const combined = try ctx.alloc.alloc(?ColumnValue, row_vals.len + fv.len);
                    @memcpy(combined[0..row_vals.len], row_vals);
                    @memcpy(combined[row_vals.len..], fv);
                    var row_ctx = ctx;
                    row_ctx.row = combined;
                    const passes = if (upd.filter) |f| blk2: {
                        const v = try evalExpr(f, row_ctx);
                        break :blk2 v.toBool() orelse false;
                    } else true;
                    if (passes) {
                        matched_from = combined;
                        break;
                    }
                    ctx.alloc.free(combined);
                }
                const mf = matched_from orelse continue; // no FROM row matched
                break :blk mf;
            };
            defer if (from_rows.items.len > 0) ctx.alloc.free(eval_row);

            var row_ctx = ctx;
            row_ctx.row = eval_row;

            // Apply WHERE filter (already applied above when FROM is present).
            if (from_rows.items.len == 0) {
                if (upd.filter) |f| {
                    const v = try evalExpr(f, row_ctx);
                    if (!(v.toBool() orelse false)) continue;
                }
            }

            // Copy existing values and apply assignments.
            const new_values = try ctx.alloc.alloc(ColumnValue, tbl.columns.len);
            errdefer {
                for (new_values) |v| v.freeIfOwned(ctx.alloc);
                ctx.alloc.free(new_values);
            }
            for (tbl.columns, 0..) |col, i| {
                new_values[i] = if (i < row.values.len)
                    row.values[i].dupe(ctx.alloc) catch defaultValue(col.typ)
                else
                    defaultValue(col.typ);
            }
            for (upd.assignments) |asgn| {
                const pv = try evalExpr(asgn.value, row_ctx);
                const col = tbl.columnById(asgn.column_id) orelse return error.ColumnNotFound;
                const col_pos: usize = @intCast(asgn.column_id);
                if (col_pos < new_values.len) {
                    new_values[col_pos].freeIfOwned(ctx.alloc);
                    new_values[col_pos] = try planValueToTypedColumnValue(pv, col.typ, ctx.alloc);
                }
            }

            const all_col_ids = try ctx.alloc.alloc(schema_mod.ColumnId, tbl.columns.len);
            defer ctx.alloc.free(all_col_ids);
            for (tbl.columns, 0..) |col, i| all_col_ids[i] = col.id;
            try self.checkForeignKeys(tbl, all_col_ids, new_values, ctx);

            const key = try ctx.alloc.dupe(u8, row.key);
            try mutations.append(ctx.alloc, .{
                .kind = .update,
                .table_id = upd.table_id,
                .key = key,
                .values = new_values,
            });

            if (returning_rows) |rr| {
                if (upd.returning.len > 0) {
                    const virtual = try ctx.alloc.alloc(?ColumnValue, new_values.len);
                    defer ctx.alloc.free(virtual);
                    for (new_values, 0..) |v, i| virtual[i] = v;
                    try projectReturning(upd.returning, virtual, ctx, rr);
                }
            }
        }
    }

    fn executeDelete(
        self: *SqlExecutor,
        del: plan_mod.DeletePlan,
        ctx: EvalCtx,
        mutations: *std.ArrayList(Mutation),
        returning_rows: ?*std.ArrayList([]const ?ColumnValue),
    ) SqlExecError!void {
        const tbl = self.schema.getTableById(del.table_id) orelse return error.TableNotFound;

        // Pre-load each USING table's rows into memory for the nested-loop join.
        var using_rows: std.ArrayList(std.ArrayList([]const ?ColumnValue)) = .empty;
        defer {
            for (using_rows.items) |*bucket| {
                for (bucket.items) |r| SqlExecutor.freeRowValues(r, ctx.alloc);
                bucket.deinit(ctx.alloc);
            }
            using_rows.deinit(ctx.alloc);
        }
        var using_widths: std.ArrayList(usize) = .empty;
        defer using_widths.deinit(ctx.alloc);
        for (del.using_table_ids) |uid| {
            const using_tbl = self.schema.getTableById(uid) orelse return error.TableNotFound;
            var bucket: std.ArrayList([]const ?ColumnValue) = .empty;
            var ui = self.storage.scan(uid, KeyRange.all(), ctx.seq -| 1, ctx.alloc) catch return error.TableNotFound;
            defer ui.deinit();
            while (ui.next() catch null) |ur| {
                try bucket.append(ctx.alloc, try self.rowToValues(ur, &.{}, ctx.alloc));
            }
            try using_rows.append(ctx.alloc, bucket);
            try using_widths.append(ctx.alloc, using_tbl.columns.len);
        }

        const inbound = self.schema.getInboundForeignKeys(del.table_id, ctx.alloc) catch &.{};
        defer ctx.alloc.free(inbound);

        var iter = self.storage.scan(del.table_id, KeyRange.all(), ctx.seq -| 1, ctx.alloc) catch return error.TableNotFound;
        defer iter.deinit();

        while (iter.next() catch null) |row| {
            const need_row_vals = del.filter != null or del.using_table_ids.len > 0 or (returning_rows != null and del.returning.len > 0);
            const row_vals: ?[]const ?ColumnValue = if (need_row_vals)
                try self.rowToValues(row, &.{}, ctx.alloc)
            else
                null;
            defer if (row_vals) |rv| SqlExecutor.freeRowValues(rv, ctx.alloc);

            // Apply WHERE (with USING join if present).
            if (del.filter != null or del.using_table_ids.len > 0) {
                const target_vals = row_vals.?;
                const passes = if (del.using_table_ids.len == 0) blk: {
                    var row_ctx = ctx;
                    row_ctx.row = target_vals;
                    const v = try evalExpr(del.filter.?, row_ctx);
                    break :blk v.toBool() orelse false;
                } else blk: {
                    // Compute combined row width for the cross product.
                    var total_width = target_vals.len;
                    for (using_widths.items) |w| total_width += w;
                    const combined = try ctx.alloc.alloc(?ColumnValue, total_width);
                    defer ctx.alloc.free(combined);
                    @memcpy(combined[0..target_vals.len], target_vals);

                    // Iterate cross product of all USING tables via index counters.
                    const n_using = using_rows.items.len;
                    const indices = try ctx.alloc.alloc(usize, n_using);
                    defer ctx.alloc.free(indices);
                    @memset(indices, 0);

                    var found = false;
                    outer: while (true) {
                        // Skip empty USING tables immediately.
                        for (using_rows.items, 0..) |bucket, bi| {
                            if (bucket.items.len == 0) break :outer;
                            _ = bi;
                        }
                        // Populate combined row with current USING combination.
                        var offset = target_vals.len;
                        for (using_rows.items, indices) |bucket, idx| {
                            const uv = bucket.items[idx];
                            @memcpy(combined[offset..offset + uv.len], uv);
                            offset += uv.len;
                        }
                        var row_ctx = ctx;
                        row_ctx.row = combined;
                        const passes_filter = if (del.filter) |f| v: {
                            const v = try evalExpr(f, row_ctx);
                            break :v v.toBool() orelse false;
                        } else true;
                        if (passes_filter) { found = true; break; }

                        // Advance counters (right-to-left carry).
                        var k: usize = n_using;
                        while (k > 0) {
                            k -= 1;
                            indices[k] += 1;
                            if (indices[k] < using_rows.items[k].items.len) break;
                            indices[k] = 0;
                            if (k == 0) break :outer;
                        }
                    }
                    break :blk found;
                };
                if (!passes) continue;
            }

            if (inbound.len > 0) {
                try self.checkInboundForeignKeys(tbl, row, inbound, ctx);
            }

            const key = try ctx.alloc.dupe(u8, row.key);
            try mutations.append(ctx.alloc, .{
                .kind = .delete,
                .table_id = del.table_id,
                .key = key,
                .values = null,
            });

            if (returning_rows) |rr| {
                if (del.returning.len > 0) {
                    try projectReturning(del.returning, row_vals.?, ctx, rr);
                }
            }
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

    /// Verify FK parent rows exist for the given row being inserted/updated.
    fn checkForeignKeys(
        self: *SqlExecutor,
        tbl: *const schema_mod.TableSchema,
        col_ids: []const schema_mod.ColumnId,
        values: []const ColumnValue,
        ctx: EvalCtx,
    ) SqlExecError!void {
        for (tbl.foreign_keys) |fk| {
            const ref_tbl = self.schema.getTableById(fk.ref_table_id) orelse return error.TableNotFound;

            // Collect the FK column values from the current row; skip if any column is missing
            var fk_vals = try ctx.alloc.alloc(ColumnValue, fk.columns.len);
            defer ctx.alloc.free(fk_vals);
            var all_found = true;
            for (fk.columns, 0..) |fk_col_id, i| {
                var found = false;
                for (col_ids, 0..) |col_id, j| {
                    if (col_id == fk_col_id and j < values.len) {
                        fk_vals[i] = values[j];
                        found = true;
                        break;
                    }
                }
                if (!found) { all_found = false; break; }
            }
            if (!all_found) continue;

            const ref_key = try buildForeignKeyLookup(ref_tbl, fk.ref_columns, fk_vals, ctx.alloc);
            defer ctx.alloc.free(ref_key);

            const maybe_row = self.storage.get(fk.ref_table_id, ref_key, ctx.seq -| 1) catch null;
            if (maybe_row) |row| {
                var r = row;
                r.deinit(ctx.alloc);
            } else {
                if (fk.name) |n| {
                    self.setDetail("foreign key '{s}' references missing row in '{s}'", .{ n, ref_tbl.name });
                } else {
                    self.setDetail("foreign key references missing row in '{s}'", .{ref_tbl.name});
                }
                return error.ForeignKeyViolation;
            }
        }
    }

    /// Verify no child rows reference the given parent row being deleted.
    fn checkInboundForeignKeys(
        self: *SqlExecutor,
        parent_tbl: *const schema_mod.TableSchema,
        parent_row: storage_mod.Row,
        inbound: []const schema_mod.InboundForeignKey,
        ctx: EvalCtx,
    ) SqlExecError!void {
        for (inbound) |ibfk| {
            const child_tbl = self.schema.getTableById(ibfk.source_table_id) orelse continue;
            const fk = ibfk.fk;

            // Get the parent's referenced column values
            const parent_ref_vals = try ctx.alloc.alloc(ColumnValue, fk.ref_columns.len);
            defer ctx.alloc.free(parent_ref_vals);
            var parent_ok = true;
            for (fk.ref_columns, 0..) |ref_col_id, i| {
                const col_pos: usize = for (parent_tbl.columns, 0..) |col, ci| {
                    if (col.id == ref_col_id) break ci;
                } else { parent_ok = false; break; };
                if (col_pos >= parent_row.values.len) { parent_ok = false; break; }
                parent_ref_vals[i] = parent_row.values[col_pos];
            }
            if (!parent_ok) continue;

            // Scan child table; if any child row's FK columns match, reject the delete
            var child_iter = self.storage.scan(child_tbl.id, KeyRange.all(), ctx.seq -| 1, ctx.alloc) catch continue;
            defer child_iter.deinit();
            while (child_iter.next() catch null) |child_row| {
                var matches = true;
                for (fk.columns, 0..) |fk_col_id, i| {
                    const col_pos: usize = for (child_tbl.columns, 0..) |col, ci| {
                        if (col.id == fk_col_id) break ci;
                    } else { matches = false; break; };
                    if (col_pos >= child_row.values.len) { matches = false; break; }
                    if (!child_row.values[col_pos].eql(parent_ref_vals[i])) { matches = false; break; }
                }
                if (matches) {
                    if (ibfk.fk.name) |n| {
                        self.setDetail("foreign key '{s}' in '{s}' still references this row", .{ n, child_tbl.name });
                    } else {
                        self.setDetail("'{s}' still references this row via foreign key", .{child_tbl.name});
                    }
                    return error.ForeignKeyViolation;
                }
            }
        }
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
            for (source_rows.items) |r| SqlExecutor.freeRowValues(r, ctx.alloc);
            source_rows.deinit(ctx.alloc);
        }
        try self.executeScan(m.source, ctx, &source_rows);

        // Collect target rows with their storage keys
        const TargetEntry = struct { key: []const u8, vals: []const ?ColumnValue };
        var target_data: std.ArrayList(TargetEntry) = .empty;
        defer {
            for (target_data.items) |td| {
                ctx.alloc.free(td.key);
                SqlExecutor.freeRowValues(td.vals, ctx.alloc);
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

    fn freeRowValues(vals: []const ?ColumnValue, alloc: std.mem.Allocator) void {
        for (vals) |v| if (v) |cv| cv.freeIfOwned(alloc);
        alloc.free(vals);
    }

    fn dupeRow(row: []const ?ColumnValue, alloc: std.mem.Allocator) ![]const ?ColumnValue {
        const copy = try alloc.alloc(?ColumnValue, row.len);
        errdefer alloc.free(copy);
        var duped: usize = 0;
        errdefer for (copy[0..duped]) |v| if (v) |cv| cv.freeIfOwned(alloc);
        for (row, 0..) |v, i| {
            copy[i] = if (v) |cv| try cv.dupe(alloc) else null;
            duped += 1;
        }
        return copy;
    }

    fn rowToValues(
        self: *SqlExecutor,
        row: Row,
        cols: []const schema_mod.ColumnId,
        alloc: std.mem.Allocator,
    ) SqlExecError![]const ?ColumnValue {
        _ = self;
        _ = cols;
        // Dupe each ColumnValue so the result outlives the scan iterator.
        const vals = try alloc.alloc(?ColumnValue, row.values.len);
        errdefer alloc.free(vals);
        var duped: usize = 0;
        errdefer for (vals[0..duped]) |v| if (v) |vv| vv.freeIfOwned(alloc) else {};
        for (row.values, 0..) |v, i| {
            vals[i] = try v.dupe(alloc);
            duped += 1;
        }
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
            .bit_not => {
                const v = try evalExpr(u.expr, ctx);
                return switch (v) {
                    .int_val => |n| .{ .int_val = ~n },
                    else => error.TypeMismatch,
                };
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

        .scalar_subquery => |sub| {
            var rows: std.ArrayList([]const ?ColumnValue) = .empty;
            defer {
                for (rows.items) |r| SqlExecutor.freeRowValues(r, ctx.alloc);
                rows.deinit(ctx.alloc);
            }
            try ctx.executor.executeScan(sub, ctx, &rows);
            if (rows.items.len == 0 or rows.items[0].len == 0) return .null_val;
            const cv = rows.items[0][0] orelse return .null_val;
            return columnValueToPlanValue(cv);
        },

        .exists_subquery => |sub| {
            var rows: std.ArrayList([]const ?ColumnValue) = .empty;
            defer {
                for (rows.items) |r| SqlExecutor.freeRowValues(r, ctx.alloc);
                rows.deinit(ctx.alloc);
            }
            try ctx.executor.executeScan(sub, ctx, &rows);
            return .{ .bool_val = rows.items.len > 0 };
        },

        .not_exists_subquery => |sub| {
            var rows: std.ArrayList([]const ?ColumnValue) = .empty;
            defer {
                for (rows.items) |r| SqlExecutor.freeRowValues(r, ctx.alloc);
                rows.deinit(ctx.alloc);
            }
            try ctx.executor.executeScan(sub, ctx, &rows);
            return .{ .bool_val = rows.items.len == 0 };
        },

        .in_subquery => |s| {
            const lhs = try evalExpr(s.expr, ctx);
            var rows: std.ArrayList([]const ?ColumnValue) = .empty;
            defer {
                for (rows.items) |r| SqlExecutor.freeRowValues(r, ctx.alloc);
                rows.deinit(ctx.alloc);
            }
            try ctx.executor.executeScan(s.plan, ctx, &rows);
            for (rows.items) |row| {
                if (row.len == 0) continue;
                const cv = row[0] orelse continue;
                if (lhs.eql(columnValueToPlanValue(cv))) return .{ .bool_val = true };
            }
            return .{ .bool_val = false };
        },

        .not_in_subquery => |s| {
            const lhs = try evalExpr(s.expr, ctx);
            var rows: std.ArrayList([]const ?ColumnValue) = .empty;
            defer {
                for (rows.items) |r| SqlExecutor.freeRowValues(r, ctx.alloc);
                rows.deinit(ctx.alloc);
            }
            try ctx.executor.executeScan(s.plan, ctx, &rows);
            for (rows.items) |row| {
                if (row.len == 0) continue;
                const cv = row[0] orelse continue;
                if (lhs.eql(columnValueToPlanValue(cv))) return .{ .bool_val = false };
            }
            return .{ .bool_val = true };
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
        .contains => blk: {
            const ls = switch (lv) { .bytes_val => |b| b, .string_val => |s| s, else => break :blk plan_mod.Value.null_val };
            const rs = switch (rv) { .bytes_val => |b| b, .string_val => |s| s, else => break :blk plan_mod.Value.null_val };
            break :blk .{ .bool_val = jsonContains(ls, rs, ctx.alloc) };
        },
        .contained => blk: {
            const ls = switch (lv) { .bytes_val => |b| b, .string_val => |s| s, else => break :blk plan_mod.Value.null_val };
            const rs = switch (rv) { .bytes_val => |b| b, .string_val => |s| s, else => break :blk plan_mod.Value.null_val };
            break :blk .{ .bool_val = jsonContains(rs, ls, ctx.alloc) };
        },
        .arrow => blk: {
            const json = switch (lv) { .bytes_val => |b| b, .string_val => |s| s, else => break :blk plan_mod.Value.null_val };
            break :blk jsonFieldAccess(json, rv, false, ctx.alloc);
        },
        .darrow => blk: {
            const json = switch (lv) { .bytes_val => |b| b, .string_val => |s| s, else => break :blk plan_mod.Value.null_val };
            break :blk jsonFieldAccess(json, rv, true, ctx.alloc);
        },
        .bit_and => switch (lv) {
            .int_val => |a| switch (rv) {
                .int_val => |b| .{ .int_val = a & b },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        },
        .bit_or => switch (lv) {
            .int_val => |a| switch (rv) {
                .int_val => |b| .{ .int_val = a | b },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        },
        .bit_xor => switch (lv) {
            .int_val => |a| switch (rv) {
                .int_val => |b| .{ .int_val = a ^ b },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        },
        .shl => switch (lv) {
            .int_val => |a| switch (rv) {
                .int_val => |b| .{ .int_val = a << @as(u6, @truncate(@as(u64, @bitCast(b)))) },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        },
        .shr => switch (lv) {
            .int_val => |a| switch (rv) {
                .int_val => |b| .{ .int_val = a >> @as(u6, @truncate(@as(u64, @bitCast(b)))) },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        },
    };
}

fn jsonFieldAccess(json_bytes: []const u8, key: plan_mod.Value, as_text: bool, alloc: std.mem.Allocator) plan_mod.Value {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{}) catch return .null_val;
    defer parsed.deinit();

    const field: std.json.Value = switch (key) {
        .string_val => |k| switch (parsed.value) {
            .object => |obj| obj.get(k) orelse return .null_val,
            else => return .null_val,
        },
        .int_val => |idx| switch (parsed.value) {
            .array => |arr| blk: {
                if (idx < 0 or @as(usize, @intCast(idx)) >= arr.items.len) return .null_val;
                break :blk arr.items[@as(usize, @intCast(idx))];
            },
            else => return .null_val,
        },
        else => return .null_val,
    };

    if (as_text) {
        return switch (field) {
            .null => .null_val,
            .bool => |b| .{ .string_val = if (b) "true" else "false" },
            .integer => |n| .{ .string_val = std.fmt.allocPrint(alloc, "{d}", .{n}) catch return .null_val },
            .float => |f| .{ .string_val = std.fmt.allocPrint(alloc, "{d}", .{f}) catch return .null_val },
            .number_string => |s| .{ .string_val = alloc.dupe(u8, s) catch return .null_val },
            .string => |s| .{ .string_val = alloc.dupe(u8, s) catch return .null_val },
            else => blk: {
                const s = std.json.Stringify.valueAlloc(alloc, field, .{}) catch return .null_val;
                break :blk .{ .string_val = s };
            },
        };
    } else {
        const b = std.json.Stringify.valueAlloc(alloc, field, .{}) catch return .null_val;
        return .{ .bytes_val = b };
    }
}

fn jsonContains(left: []const u8, right: []const u8, alloc: std.mem.Allocator) bool {
    var lp = std.json.parseFromSlice(std.json.Value, alloc, left, .{}) catch return false;
    defer lp.deinit();
    var rp = std.json.parseFromSlice(std.json.Value, alloc, right, .{}) catch return false;
    defer rp.deinit();
    return jsonValueContains(lp.value, rp.value);
}

fn jsonValueContains(left: std.json.Value, right: std.json.Value) bool {
    return switch (right) {
        .object => |ro| {
            const lo = switch (left) { .object => |o| o, else => return false };
            var it = ro.iterator();
            while (it.next()) |entry| {
                const lv = lo.get(entry.key_ptr.*) orelse return false;
                if (!jsonValueContains(lv, entry.value_ptr.*)) return false;
            }
            return true;
        },
        .array => |ra| {
            const la = switch (left) { .array => |a| a, else => return false };
            for (ra.items) |rv| {
                var found = false;
                for (la.items) |lv| {
                    if (jsonValueContains(lv, rv)) { found = true; break; }
                }
                if (!found) return false;
            }
            return true;
        },
        .null => left == .null,
        .bool => |b| switch (left) { .bool => |lb| lb == b, else => false },
        .integer => |n| switch (left) { .integer => |ln| ln == n, else => false },
        .float => |f| switch (left) { .float => |lf| lf == f, else => false },
        .string => |s| switch (left) { .string => |ls| std.mem.eql(u8, ls, s), else => false },
        .number_string => |s| switch (left) { .number_string => |ls| std.mem.eql(u8, ls, s), else => false },
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

/// Build the storage key for a referenced table row given FK column values.
/// ref_col_ids are the referenced table's column IDs in FK order; fk_vals are the matching values.
fn buildForeignKeyLookup(
    ref_tbl: *const schema_mod.TableSchema,
    ref_col_ids: []const schema_mod.ColumnId,
    fk_vals: []const ColumnValue,
    alloc: std.mem.Allocator,
) SqlExecError![]const u8 {
    var key_buf: std.ArrayList(u8) = .empty;
    for (ref_tbl.primary_key) |pk_col_id| {
        for (ref_col_ids, 0..) |ref_cid, i| {
            if (ref_cid == pk_col_id and i < fk_vals.len) {
                try encodeKeyComponent(&key_buf, fk_vals[i], alloc);
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

fn buildVirtualRow(
    n_cols: usize,
    col_ids: []const schema_mod.ColumnId,
    values: []const ColumnValue,
    alloc: std.mem.Allocator,
) ![]const ?ColumnValue {
    const virtual = try alloc.alloc(?ColumnValue, n_cols);
    @memset(virtual, null);
    for (col_ids, values) |col_id, val| {
        const pos: usize = @intCast(col_id);
        if (pos < virtual.len) virtual[pos] = val;
    }
    return virtual;
}

fn projectReturning(
    items: []const plan_mod.ProjectItem,
    virtual_row: []const ?ColumnValue,
    ctx: EvalCtx,
    out: *std.ArrayList([]const ?ColumnValue),
) !void {
    const projected = try ctx.alloc.alloc(?ColumnValue, items.len);
    errdefer ctx.alloc.free(projected);
    var row_ctx = ctx;
    row_ctx.row = virtual_row;
    for (items, 0..) |item, i| {
        const v = try evalExpr(item.expr, row_ctx);
        projected[i] = planValueToColumnValue(v, ctx.alloc) catch null;
    }
    try out.append(ctx.alloc, projected);
}

fn buildReturningResultSet(
    plan: plan_mod.ExecutionPlan,
    rows: []const []const ?ColumnValue,
    alloc: std.mem.Allocator,
) !ResultSet {
    var col_names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (col_names.items) |n| alloc.free(n);
        col_names.deinit(alloc);
    }
    for (plan.stmts) |stmt| {
        const returning = switch (stmt) {
            .insert => |ins| ins.returning,
            .update => |upd| upd.returning,
            .delete => |del| del.returning,
            else => continue,
        };
        for (returning) |item| {
            try col_names.append(alloc, try alloc.dupe(u8, item.alias));
        }
        break;
    }
    return ResultSet{
        .columns = try col_names.toOwnedSlice(alloc),
        .rows = rows,
        .alloc = alloc,
    };
}

fn serializeRowKey(row: []const ?ColumnValue, alloc: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (row) |maybe_val| {
        if (maybe_val) |cv| {
            try buf.append(alloc, 1);
            switch (cv) {
                .bool_t => |b| try buf.append(alloc, if (b) 1 else 0),
                .int8 => |v| { var tmp: [1]u8 = undefined; std.mem.writeInt(i8, &tmp, v, .little); try buf.appendSlice(alloc, &tmp); },
                .int16 => |v| { var tmp: [2]u8 = undefined; std.mem.writeInt(i16, &tmp, v, .little); try buf.appendSlice(alloc, &tmp); },
                .int32 => |v| { var tmp: [4]u8 = undefined; std.mem.writeInt(i32, &tmp, v, .little); try buf.appendSlice(alloc, &tmp); },
                .int64 => |v| { var tmp: [8]u8 = undefined; std.mem.writeInt(i64, &tmp, v, .little); try buf.appendSlice(alloc, &tmp); },
                .uint8 => |v| try buf.append(alloc, v),
                .uint16 => |v| { var tmp: [2]u8 = undefined; std.mem.writeInt(u16, &tmp, v, .little); try buf.appendSlice(alloc, &tmp); },
                .uint32 => |v| { var tmp: [4]u8 = undefined; std.mem.writeInt(u32, &tmp, v, .little); try buf.appendSlice(alloc, &tmp); },
                .uint64 => |v| { var tmp: [8]u8 = undefined; std.mem.writeInt(u64, &tmp, v, .little); try buf.appendSlice(alloc, &tmp); },
                .float32 => |v| { var tmp: [4]u8 = undefined; std.mem.writeInt(u32, &tmp, @bitCast(v), .little); try buf.appendSlice(alloc, &tmp); },
                .float64 => |v| { var tmp: [8]u8 = undefined; std.mem.writeInt(u64, &tmp, @bitCast(v), .little); try buf.appendSlice(alloc, &tmp); },
                .string => |s| {
                    var tmp: [4]u8 = undefined;
                    std.mem.writeInt(u32, &tmp, @intCast(s.len), .little);
                    try buf.appendSlice(alloc, &tmp);
                    try buf.appendSlice(alloc, s);
                },
                .bytes => |b| {
                    var tmp: [4]u8 = undefined;
                    std.mem.writeInt(u32, &tmp, @intCast(b.len), .little);
                    try buf.appendSlice(alloc, &tmp);
                    try buf.appendSlice(alloc, b);
                },
            }
        } else {
            try buf.append(alloc, 0);
        }
        try buf.append(alloc, 0xFF);
    }
    return buf.toOwnedSlice(alloc);
}
