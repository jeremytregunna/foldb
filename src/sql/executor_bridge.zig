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

// Sub-modules split from this file
const type_conv = @import("type_conv.zig");
const agg_helpers = @import("agg_helpers.zig");
const params_codec = @import("params_codec.zig");
const key_encode = @import("key_encode.zig");
const eval_expr_mod = @import("eval_expr.zig");
const window_exec_mod = @import("window_exec.zig");
const agg_accum_mod = @import("agg_accum.zig");

// Aliases so internal call sites remain unchanged
const columnValueToPlanValue = type_conv.columnValueToPlanValue;
const planValueToColumnValue = type_conv.planValueToColumnValue;
const planValueToTypedColumnValue = type_conv.planValueToTypedColumnValue;
const castValue = type_conv.castValue;
const defaultValue = type_conv.defaultValue;
const aggKeyEquals = type_conv.aggKeyEquals;
const dupePlanValue = agg_helpers.dupePlanValue;
const freePlanValue = agg_helpers.freePlanValue;
const serializeArrayAgg = agg_helpers.serializeArrayAgg;
const buildStringAgg = agg_helpers.buildStringAgg;
const buildPrimaryKey = key_encode.buildPrimaryKey;
const buildForeignKeyLookup = key_encode.buildForeignKeyLookup;
const encodeKeyComponent = key_encode.encodeKeyComponent;
const pkColumnIds = key_encode.pkColumnIds;
const buildVirtualRow = key_encode.buildVirtualRow;
const serializeRowKey = key_encode.serializeRowKey;
pub const encodeParams = params_codec.encodeParams;
pub const decodeParams = params_codec.decodeParams;
const EvalCtx = eval_expr_mod.EvalCtx;
const evalExpr = eval_expr_mod.evalExpr;
const freeRowValues = eval_expr_mod.freeRowValues;
const AggAccum = agg_accum_mod.AggAccum;

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

pub const SqlExecError = eval_expr_mod.SqlExecError;

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
                for (returning_rows.items) |r| freeRowValues(r, self.alloc);
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
            .scan_fn = &executeScanShim,
            .executor_ctx = self,
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
            .scan_fn = &executeScanShim,
            .executor_ctx = self,
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
                    for (inner.items) |r| freeRowValues(r, ctx.alloc);
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
                    for (inner.items) |r| freeRowValues(r, ctx.alloc);
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
                            freeRowValues(projected, ctx.alloc);
                            continue;
                        }
                    }
                    try out.append(ctx.alloc, projected);
                }
            },
            .limit => |l| {
                var inner: std.ArrayList([]const ?ColumnValue) = .empty;
                defer {
                    for (inner.items) |r| freeRowValues(r, ctx.alloc);
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
                    for (inner.items) |r| freeRowValues(r, ctx.alloc);
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
                    for (inner.items) |r| freeRowValues(r, ctx.alloc);
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
                    try window_exec_mod.computeWindowFnForAll(wf, inner.items, win_results, fi, ctx);
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
                    for (left_rows.items) |r| freeRowValues(r, ctx.alloc);
                    left_rows.deinit(ctx.alloc);
                }
                var right_rows: std.ArrayList([]const ?ColumnValue) = .empty;
                defer {
                    for (right_rows.items) |r| freeRowValues(r, ctx.alloc);
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
                    for (inner.items) |r| freeRowValues(r, ctx.alloc);
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
                        freeRowValues(g.key, ctx.alloc);
                        for (g.accums) |*acc| acc.deinit(ctx.alloc);
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
                        freeRowValues(key, ctx.alloc);
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
                    var agg_arena = std.heap.ArenaAllocator.init(ctx.alloc);
                    defer agg_arena.deinit();
                    const agg_alloc = agg_arena.allocator();
                    const result_row = try ctx.alloc.alloc(?ColumnValue, ha.group_keys.len + ha.agg_exprs.len);
                    errdefer ctx.alloc.free(result_row);
                    for (g.key, 0..) |v, i| result_row[i] = if (v) |cv| try cv.dupe(ctx.alloc) else null;
                    for (ha.agg_exprs, g.accums, 0..) |ae, acc, i| {
                        const v = try acc.toValue(ae, agg_alloc);
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
            for (from_rows.items) |r| freeRowValues(r, ctx.alloc);
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
            defer freeRowValues(row_vals, ctx.alloc);

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
                for (bucket.items) |r| freeRowValues(r, ctx.alloc);
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
            defer if (row_vals) |rv| freeRowValues(rv, ctx.alloc);

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
                            @memcpy(combined[offset .. offset + uv.len], uv);
                            offset += uv.len;
                        }
                        var row_ctx = ctx;
                        row_ctx.row = combined;
                        const passes_filter = if (del.filter) |f| v: {
                            const v = try evalExpr(f, row_ctx);
                            break :v v.toBool() orelse false;
                        } else true;
                        if (passes_filter) {
                            found = true;
                            break;
                        }

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
                if (!found) {
                    all_found = false;
                    break;
                }
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
                } else {
                    parent_ok = false;
                    break;
                };
                if (col_pos >= parent_row.values.len) {
                    parent_ok = false;
                    break;
                }
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
                    } else {
                        matches = false;
                        break;
                    };
                    if (col_pos >= child_row.values.len) {
                        matches = false;
                        break;
                    }
                    if (!child_row.values[col_pos].eql(parent_ref_vals[i])) {
                        matches = false;
                        break;
                    }
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
            for (source_rows.items) |r| freeRowValues(r, ctx.alloc);
            source_rows.deinit(ctx.alloc);
        }
        try self.executeScan(m.source, ctx, &source_rows);

        // Collect target rows with their storage keys
        const TargetEntry = struct { key: []const u8, vals: []const ?ColumnValue };
        var target_data: std.ArrayList(TargetEntry) = .empty;
        defer {
            for (target_data.items) |td| {
                ctx.alloc.free(td.key);
                freeRowValues(td.vals, ctx.alloc);
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

fn executeScanShim(
    opaque_self: *anyopaque,
    node: *plan_mod.PlanNode,
    ctx: *const EvalCtx,
    out: *std.ArrayList([]const ?ColumnValue),
) anyerror!void {
    const self: *SqlExecutor = @ptrCast(@alignCast(opaque_self));
    return self.executeScan(node, ctx.*, out);
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

