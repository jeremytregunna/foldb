/// Query planner: converts type-checked AST to a deterministic ExecutionPlan.
const std = @import("std");
const ast = @import("ast.zig");
const schema_mod = @import("schema.zig");

pub const PlanError = error{
    TableNotFound,
    ColumnNotFound,
    UnsupportedOperation,
    OutOfMemory,
};

// ─── Value representation ─────────────────────────────────────────────────────

/// A resolved value during plan evaluation.
pub const Value = union(enum) {
    null_val,
    bool_val: bool,
    int_val: i64,
    uint_val: u64,
    float_val: f64,
    string_val: []const u8,
    bytes_val: []const u8,
    // Complex types stored as opaque bytes
    opaque_val: []const u8,

    pub fn isNull(self: Value) bool {
        return self == .null_val;
    }

    pub fn toBool(self: Value) ?bool {
        return switch (self) {
            .bool_val => |b| b,
            else => null,
        };
    }

    pub fn eql(self: Value, other: Value) bool {
        return switch (self) {
            .null_val => other == .null_val,
            .bool_val => |b| switch (other) {
                .bool_val => |ob| b == ob,
                else => false,
            },
            .int_val => |v| switch (other) {
                .int_val => |ov| v == ov,
                else => false,
            },
            .uint_val => |v| switch (other) {
                .uint_val => |ov| v == ov,
                else => false,
            },
            .float_val => |v| switch (other) {
                .float_val => |ov| v == ov,
                else => false,
            },
            .string_val => |v| switch (other) {
                .string_val => |ov| std.mem.eql(u8, v, ov),
                else => false,
            },
            .bytes_val => |v| switch (other) {
                .bytes_val => |ov| std.mem.eql(u8, v, ov),
                else => false,
            },
            .opaque_val => |v| switch (other) {
                .opaque_val => |ov| std.mem.eql(u8, v, ov),
                else => false,
            },
        };
    }

    pub fn lessThan(self: Value, other: Value) bool {
        return switch (self) {
            .int_val => |v| switch (other) {
                .int_val => |ov| v < ov,
                else => false,
            },
            .uint_val => |v| switch (other) {
                .uint_val => |ov| v < ov,
                else => false,
            },
            .float_val => |v| switch (other) {
                .float_val => |ov| v < ov,
                else => false,
            },
            .string_val => |v| switch (other) {
                .string_val => |ov| std.mem.lessThan(u8, v, ov),
                else => false,
            },
            else => false,
        };
    }
};

// ─── Planner scope tracking ───────────────────────────────────────────────────

const PlanScopeEntry = struct {
    table_alias: []const u8, // "" if no qualifier
    col_name: []const u8,
    position: u32,
};

const PostAggCol = struct {
    fn_name: []const u8,
    position: u32,
};

// ─── Plan nodes ──────────────────────────────────────────────────────────────

pub const ScanNode = struct {
    table_id: schema_mod.TableId,
    columns: []const schema_mod.ColumnId, // which columns to project
    index_hint: ?schema_mod.IndexId = null, // set when a specialty index is applicable
};

pub const PkLookupNode = struct {
    table_id: schema_mod.TableId,
    key_expr: *PlanExpr,
    columns: []const schema_mod.ColumnId,
};

pub const FilterNode = struct {
    input: *PlanNode,
    predicate: *PlanExpr,
};

pub const ProjectNode = struct {
    input: *PlanNode,
    exprs: []const ProjectItem,
    distinct: bool = false,
};

pub const ProjectItem = struct {
    expr: *PlanExpr,
    alias: []const u8,
};

pub const SortNode = struct {
    input: *PlanNode,
    keys: []const SortKey,
};

pub const SortKey = struct {
    expr: *PlanExpr,
    asc: bool,
    nulls_first: bool,
};

pub const LimitNode = struct {
    input: *PlanNode,
    limit: ?*PlanExpr,
    offset: ?*PlanExpr,
};

pub const HashAggNode = struct {
    input: *PlanNode,
    group_keys: []const *PlanExpr,
    agg_exprs: []const AggExpr,
};

pub const AggExpr = struct {
    fn_name: []const u8,
    arg: ?*PlanExpr,
    distinct: bool,
    alias: []const u8,
};

pub const HashJoinNode = struct {
    left: *PlanNode,
    right: *PlanNode,
    kind: ast.JoinKind,
    condition: *PlanExpr,
};

pub const InsertPlan = struct {
    table_id: schema_mod.TableId,
    column_ids: []const schema_mod.ColumnId,
    source: InsertSource,
    on_conflict: ?OnConflictPlan,
    returning: []const ProjectItem = &.{},
};

pub const InsertSource = union(enum) {
    values: []const []const *PlanExpr,
    query: *PlanNode,
};

pub const OnConflictPlan = union(enum) {
    do_nothing,
    do_update: []const UpdateAssignment,
};

pub const UpdatePlan = struct {
    table_id: schema_mod.TableId,
    assignments: []const UpdateAssignment,
    filter: ?*PlanExpr,
    returning: []const ProjectItem = &.{},
    from_table_id: ?schema_mod.TableId = null,
};

pub const UpdateAssignment = struct {
    column_id: schema_mod.ColumnId,
    value: *PlanExpr,
};

pub const DeletePlan = struct {
    table_id: schema_mod.TableId,
    filter: ?*PlanExpr,
    returning: []const ProjectItem = &.{},
    using_table_ids: []const schema_mod.TableId = &.{},
};

pub const AssertPlan = struct {
    predicate: *PlanExpr,
    message: []const u8,
};

pub const WindowFnSpec = struct {
    fn_name: []const u8,
    args: []const *PlanExpr,
    partition_by: []const *PlanExpr,
    order_by: []const SortKey,
    result_col: u32,
};

pub const WindowNode = struct {
    input: *PlanNode,
    fns: []const WindowFnSpec,
    input_width: u32,
};

pub const MergeActionPlan = union(enum) {
    update: []const UpdateAssignment,
    delete,
    do_nothing,
};

pub const MergeWhenMatchedPlan = struct {
    cond: ?*PlanExpr,
    action: MergeActionPlan,
};

pub const MergeWhenNotMatchedPlan = struct {
    cond: ?*PlanExpr,
    column_ids: []const schema_mod.ColumnId,
    values: []const *PlanExpr,
};

pub const MergeWhenPlan = union(enum) {
    matched: MergeWhenMatchedPlan,
    not_matched: MergeWhenNotMatchedPlan,
};

pub const MergePlan = struct {
    target_id: schema_mod.TableId,
    source: *PlanNode,
    on_condition: *PlanExpr,
    target_width: u32,
    whens: []const MergeWhenPlan,
};

pub const PlanNode = union(enum) {
    scan: ScanNode,
    pk_lookup: PkLookupNode,
    filter: FilterNode,
    project: ProjectNode,
    sort: SortNode,
    limit: LimitNode,
    hash_agg: HashAggNode,
    hash_join: HashJoinNode,
    window: WindowNode,
    // DML nodes
    insert: InsertPlan,
    update: UpdatePlan,
    delete: DeletePlan,
    assert: AssertPlan,
    merge: MergePlan,
    // Empty result (zero rows)
    empty,
    // Single-row source for FROM-less SELECT (produces exactly one empty row)
    single_row,
};

// ─── Plan expressions ─────────────────────────────────────────────────────────

pub const PlanExpr = union(enum) {
    null_literal,
    bool_literal: bool,
    int_literal: i64,
    uint_literal: u64,
    float_literal: f64,
    string_literal: []const u8,
    bytes_literal: []const u8,

    // Parameter reference (0-based)
    param: u32,

    // Nondeterminism reference (0-based index into resolved_nondet)
    nondet: u32,

    // Column in the current row (by position in the output schema)
    column: u32,

    // Column from a specific table in a join context
    table_column: struct { table_idx: u32, col_idx: u32 },

    binary: struct { op: ast.BinOp, left: *PlanExpr, right: *PlanExpr },
    unary: struct { op: ast.UnaryOp, expr: *PlanExpr },

    cast: struct { expr: *PlanExpr, to: ast.SqlType },

    is_null: *PlanExpr,
    is_not_null: *PlanExpr,

    fn_call: struct { name: []const u8, args: []*PlanExpr },

    case_searched: struct { whens: []PlanCaseWhen, else_expr: ?*PlanExpr },

    // Subquery expressions — plan node is executed at eval time.
    scalar_subquery: *PlanNode,
    exists_subquery: *PlanNode,
    not_exists_subquery: *PlanNode,
    in_subquery: struct { expr: *PlanExpr, plan: *PlanNode },
    not_in_subquery: struct { expr: *PlanExpr, plan: *PlanNode },
};

pub const PlanCaseWhen = struct { cond: *PlanExpr, result: *PlanExpr };

// ─── Execution plan (top-level) ───────────────────────────────────────────────

pub const ExecutionPlan = struct {
    /// For TRANSACTION blocks: ordered list of statement plans
    stmts: []const StmtPlan,
    /// Parameter types in order
    param_types: []const ast.SqlType,
    /// Number of nondeterministic values needed (for gateway to resolve)
    nondet_count: u32,
};

pub const StmtKind = enum { select, insert, update, delete, assert, merge };

pub const StmtPlan = union(enum) {
    select: *PlanNode,
    insert: InsertPlan,
    update: UpdatePlan,
    delete: DeletePlan,
    assert: AssertPlan,
    merge: MergePlan,
};

// ─── CTE tracking ────────────────────────────────────────────────────────────

const CteEntry = struct {
    name: []const u8,
    node: *PlanNode,
    items: []const ast.SelectItem, // output column info for scope setup
};

/// Returns the "natural" display name of an expression (for SELECT without AS alias).
fn exprNaturalName(expr: *const ast.Expr) []const u8 {
    return switch (expr.*) {
        .column_ref => |r| r.column,
        .fn_call => |f| f.name,
        .cast => |c| exprNaturalName(c.expr),
        else => "?",
    };
}

// ─── Planner ─────────────────────────────────────────────────────────────────

pub const Planner = struct {
    schema: *const schema_mod.SchemaRegistry,
    arena: std.mem.Allocator,
    nondet_idx: u32 = 0,
    scope: std.ArrayList(PlanScopeEntry) = .empty,
    post_agg_cols: std.ArrayList(PostAggCol) = .empty,
    cte_stack: std.ArrayList(CteEntry) = .empty,
    window_fn_cols: std.ArrayList(PostAggCol) = .empty,

    pub fn init(arena: std.mem.Allocator, schema: *const schema_mod.SchemaRegistry) Planner {
        return .{ .schema = schema, .arena = arena };
    }

    fn resolveColRef(self: *const Planner, ref: ast.ColumnRef) ?u32 {
        if (ref.table) |tbl_name| {
            for (self.scope.items) |e| {
                if (!std.ascii.eqlIgnoreCase(e.col_name, ref.column)) continue;
                if (std.ascii.eqlIgnoreCase(e.table_alias, tbl_name)) return e.position;
            }
            return null;
        }
        for (self.scope.items) |e| {
            if (std.ascii.eqlIgnoreCase(e.col_name, ref.column)) return e.position;
        }
        return null;
    }

    fn resolveAggFn(self: *const Planner, name: []const u8) ?u32 {
        if (self.post_agg_cols.items.len == 0) return null;
        for (self.post_agg_cols.items) |e| {
            if (std.ascii.eqlIgnoreCase(e.fn_name, name)) return e.position;
        }
        return null;
    }

    fn resolveWindowFn(self: *const Planner, name: []const u8) ?u32 {
        for (self.window_fn_cols.items) |e| {
            if (std.ascii.eqlIgnoreCase(e.fn_name, name)) return e.position;
        }
        return null;
    }

    fn resolveCte(self: *const Planner, name: []const u8) ?CteEntry {
        var i = self.cte_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (std.ascii.eqlIgnoreCase(self.cte_stack.items[i].name, name)) {
                return self.cte_stack.items[i];
            }
        }
        return null;
    }

    pub fn planTransaction(self: *Planner, txn: ast.TransactionBlock) PlanError!ExecutionPlan {
        var param_types: std.ArrayList(ast.SqlType) = .empty;
        for (txn.params) |p| {
            try param_types.append(self.arena, p.typ);
        }

        var stmts: std.ArrayList(StmtPlan) = .empty;
        for (txn.stmts) |s| {
            const sp = try self.planTxnStmt(s);
            try stmts.append(self.arena, sp);
        }

        return .{
            .stmts = try stmts.toOwnedSlice(self.arena),
            .param_types = try param_types.toOwnedSlice(self.arena),
            .nondet_count = self.nondet_idx,
        };
    }

    pub fn planStmt(self: *Planner, s: ast.Stmt, params: []const ast.SqlType) PlanError!ExecutionPlan {
        const sp = try self.planAstStmt(s);
        return .{
            .stmts = try self.arena.dupe(StmtPlan, &.{sp}),
            .param_types = params,
            .nondet_count = self.nondet_idx,
        };
    }

    fn planTxnStmt(self: *Planner, s: ast.TxnStmt) PlanError!StmtPlan {
        return switch (s) {
            .select => |q| .{ .select = try self.planSelect(q) },
            .insert => |q| .{ .insert = try self.planInsert(q) },
            .update => |q| .{ .update = try self.planUpdate(q) },
            .delete => |q| .{ .delete = try self.planDelete(q) },
            .merge => |q| .{ .merge = try self.planMerge(q) },
            .assert => |e| .{ .assert = .{ .predicate = try self.planExpr(e), .message = "assertion failed" } },
        };
    }

    // Domain core entry point — caller guarantees the AST has passed TypeChecker.checkStmt.
    // No input validation here; only domain invariants (TableNotFound, ColumnNotFound) as asserts.
    pub fn planAstStmt(self: *Planner, s: ast.Stmt) PlanError!StmtPlan {
        return switch (s) {
            .select => |q| .{ .select = try self.planSelect(q) },
            .insert => |q| .{ .insert = try self.planInsert(q) },
            .update => |q| .{ .update = try self.planUpdate(q) },
            .delete => |q| .{ .delete = try self.planDelete(q) },
            .merge => |q| .{ .merge = try self.planMerge(q) },
            .create_table, .create_index, .alter_table => error.UnsupportedOperation,
            .transaction => error.UnsupportedOperation,
        };
    }

    fn planSelect(self: *Planner, q: ast.SelectStmt) PlanError!*PlanNode {
        const scope_save = self.scope.items.len;
        const post_agg_save = self.post_agg_cols.items.len;
        const cte_save = self.cte_stack.items.len;
        const win_fn_save = self.window_fn_cols.items.len;
        defer {
            self.scope.shrinkRetainingCapacity(scope_save);
            self.post_agg_cols.shrinkRetainingCapacity(post_agg_save);
            self.cte_stack.shrinkRetainingCapacity(cte_save);
            self.window_fn_cols.shrinkRetainingCapacity(win_fn_save);
        }

        // Register CTEs so planTableRef can resolve cte_ref nodes
        for (q.with) |cte| {
            const cte_node = try self.planSelect(cte.query.*);
            try self.cte_stack.append(self.arena, .{
                .name = cte.name,
                .node = cte_node,
                .items = cte.query.items,
            });
        }

        const tbl_ref = q.from orelse {
            // SELECT without FROM — emit a single empty row so expressions can be evaluated
            const node = try self.arena.create(PlanNode);
            node.* = .single_row;
            return node;
        };

        var node = try self.planTableRef(tbl_ref);

        // Joins
        for (q.joins) |j| {
            const right_scope_start: usize = self.scope.items.len;
            const right = try self.planTableRef(j.table);
            const cond = if (j.condition) |c| switch (c) {
                .on => |e| try self.planExpr(e),
                .using => |cols| blk: {
                    // Build: col_left = col_right [AND ...] by matching column names in each side's scope
                    var cond_expr: ?*PlanExpr = null;
                    for (cols) |col_name| {
                        var left_pos: ?u32 = null;
                        var right_pos: ?u32 = null;
                        for (self.scope.items[0..right_scope_start]) |e| {
                            if (std.ascii.eqlIgnoreCase(e.col_name, col_name)) { left_pos = e.position; break; }
                        }
                        for (self.scope.items[right_scope_start..]) |e| {
                            if (std.ascii.eqlIgnoreCase(e.col_name, col_name)) { right_pos = e.position; break; }
                        }
                        if (left_pos == null or right_pos == null) return error.ColumnNotFound;
                        const lc = try self.arena.create(PlanExpr);
                        lc.* = .{ .column = left_pos.? };
                        const rc = try self.arena.create(PlanExpr);
                        rc.* = .{ .column = right_pos.? };
                        const eq = try self.arena.create(PlanExpr);
                        eq.* = .{ .binary = .{ .op = .eq, .left = lc, .right = rc } };
                        if (cond_expr == null) {
                            cond_expr = eq;
                        } else {
                            const and_node = try self.arena.create(PlanExpr);
                            and_node.* = .{ .binary = .{ .op = .and_op, .left = cond_expr.?, .right = eq } };
                            cond_expr = and_node;
                        }
                    }
                    if (cond_expr) |e| break :blk e;
                    const dummy = try self.arena.create(PlanExpr);
                    dummy.* = .{ .bool_literal = true };
                    break :blk dummy;
                },
            } else blk: {
                const dummy = try self.arena.create(PlanExpr);
                dummy.* = .{ .bool_literal = true };
                break :blk dummy;
            };
            const join_node = try self.arena.create(PlanNode);
            join_node.* = .{ .hash_join = .{
                .left = node,
                .right = right,
                .kind = j.kind,
                .condition = cond,
            } };
            node = join_node;
        }

        // WHERE filter
        if (q.where) |w| {
            const pred = try self.planExpr(w);
            const filter_node = try self.arena.create(PlanNode);
            filter_node.* = .{ .filter = .{ .input = node, .predicate = pred } };
            node = filter_node;
        }

        // GROUP BY + aggregates (also handles implicit aggregate: SELECT COUNT(*) FROM t with no GROUP BY)
        const has_implicit_agg = q.group_by.len == 0 and blk: {
            for (q.items) |item| {
                switch (item) {
                    .star => {},
                    .expr => |ei| if (extractAggFn(ei.expr) != null) break :blk true,
                }
            }
            break :blk false;
        };
        if (q.group_by.len > 0 or has_implicit_agg) {
            var keys: std.ArrayList(*PlanExpr) = .empty;
            var key_col_refs: std.ArrayList(?ast.ColumnRef) = .empty;
            for (q.group_by) |g| {
                try keys.append(self.arena, try self.planExpr(g));
                try key_col_refs.append(self.arena, if (g.* == .column_ref) g.column_ref else null);
            }
            var agg_exprs: std.ArrayList(AggExpr) = .empty;
            for (q.items) |item| {
                switch (item) {
                    .star => {},
                    .expr => |ei| {
                        if (extractAggFn(ei.expr)) |fn_call| {
                            const arg: ?*PlanExpr = if (fn_call.args.len > 0)
                                try self.planExpr(fn_call.args[0])
                            else
                                null;
                            try agg_exprs.append(self.arena, .{
                                .fn_name = fn_call.name,
                                .arg = arg,
                                .distinct = fn_call.distinct,
                                .alias = ei.alias orelse fn_call.name,
                            });
                        }
                    },
                }
            }
            const group_keys_slice = try keys.toOwnedSlice(self.arena);
            const agg_exprs_slice = try agg_exprs.toOwnedSlice(self.arena);
            const agg_node = try self.arena.create(PlanNode);
            agg_node.* = .{ .hash_agg = .{
                .input = node,
                .group_keys = group_keys_slice,
                .agg_exprs = agg_exprs_slice,
            } };
            node = agg_node;

            // Rebuild scope for hash_agg output: [group_key_0, ..., agg_0, ...]
            self.scope.shrinkRetainingCapacity(scope_save);
            self.post_agg_cols.shrinkRetainingCapacity(post_agg_save);
            for (key_col_refs.items, 0..) |maybe_ref, i| {
                if (maybe_ref) |ref| {
                    try self.scope.append(self.arena, .{
                        .table_alias = ref.table orelse "",
                        .col_name = ref.column,
                        .position = @intCast(i),
                    });
                }
            }
            for (agg_exprs_slice, 0..) |ae, i| {
                try self.post_agg_cols.append(self.arena, .{
                    .fn_name = ae.fn_name,
                    .position = @intCast(group_keys_slice.len + i),
                });
            }
        }

        // HAVING filter
        if (q.having) |h| {
            const pred = try self.planExpr(h);
            const filter_node = try self.arena.create(PlanNode);
            filter_node.* = .{ .filter = .{ .input = node, .predicate = pred } };
            node = filter_node;
        }

        // Window functions: pre-scan SELECT items, assign positions, build WindowNode
        {
            const win_base: u32 = @intCast(self.scope.items.len);
            var win_specs: std.ArrayList(WindowFnSpec) = .empty;
            for (q.items) |item| {
                switch (item) {
                    .star => {},
                    .expr => |ei| {
                        if (ei.expr.* == .window_fn) {
                            const wf = ei.expr.window_fn;
                            const pos = win_base + @as(u32, @intCast(win_specs.items.len));
                            var args_pe: std.ArrayList(*PlanExpr) = .empty;
                            for (wf.call.args) |a| try args_pe.append(self.arena, try self.planExpr(a));
                            var pb_pe: std.ArrayList(*PlanExpr) = .empty;
                            for (wf.window.partition_by) |pb| try pb_pe.append(self.arena, try self.planExpr(pb));
                            var ob_keys: std.ArrayList(SortKey) = .empty;
                            for (wf.window.order_by) |ob| {
                                try ob_keys.append(self.arena, .{
                                    .expr = try self.planExpr(ob.expr),
                                    .asc = ob.asc,
                                    .nulls_first = ob.nulls_first orelse !ob.asc,
                                });
                            }
                            try win_specs.append(self.arena, .{
                                .fn_name = wf.call.name,
                                .args = try args_pe.toOwnedSlice(self.arena),
                                .partition_by = try pb_pe.toOwnedSlice(self.arena),
                                .order_by = try ob_keys.toOwnedSlice(self.arena),
                                .result_col = pos,
                            });
                            try self.window_fn_cols.append(self.arena, .{
                                .fn_name = wf.call.name,
                                .position = pos,
                            });
                        }
                    },
                }
            }
            if (win_specs.items.len > 0) {
                const win_node = try self.arena.create(PlanNode);
                win_node.* = .{ .window = .{
                    .input = node,
                    .fns = try win_specs.toOwnedSlice(self.arena),
                    .input_width = win_base,
                } };
                node = win_node;
            }
        }

        // ORDER BY (always with deterministic ordering)
        if (q.order_by.len > 0) {
            var keys: std.ArrayList(SortKey) = .empty;
            for (q.order_by) |ob| {
                try keys.append(self.arena, .{
                    .expr = try self.planExpr(ob.expr),
                    .asc = ob.asc,
                    .nulls_first = ob.nulls_first orelse !ob.asc, // NULLS LAST for ASC by default
                });
            }
            const sort_node = try self.arena.create(PlanNode);
            sort_node.* = .{ .sort = .{ .input = node, .keys = try keys.toOwnedSlice(self.arena) } };
            node = sort_node;
        }

        // LIMIT / OFFSET
        if (q.limit != null or q.offset != null) {
            const limit_node = try self.arena.create(PlanNode);
            limit_node.* = .{ .limit = .{
                .input = node,
                .limit = if (q.limit) |l| try self.planExpr(l) else null,
                .offset = if (q.offset) |o| try self.planExpr(o) else null,
            } };
            node = limit_node;
        }

        // Project selected items
        var proj_items: std.ArrayList(ProjectItem) = .empty;
        for (q.items) |item| {
            switch (item) {
                .star => {}, // expand at execution time
                .expr => |ei| {
                    const alias = ei.alias orelse blk: {
                        if (ei.expr.* == .column_ref) {
                            const r = ei.expr.column_ref;
                            if (r.table) |t| break :blk try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ t, r.column });
                        }
                        break :blk exprNaturalName(ei.expr);
                    };
                    try proj_items.append(self.arena, .{
                        .expr = try self.planExpr(ei.expr),
                        .alias = alias,
                    });
                },
            }
        }
        if (proj_items.items.len > 0) {
            const proj_node = try self.arena.create(PlanNode);
            proj_node.* = .{ .project = .{ .input = node, .exprs = try proj_items.toOwnedSlice(self.arena), .distinct = q.distinct } };
            node = proj_node;
        }

        return node;
    }

    fn planTableRef(self: *Planner, tref: ast.TableRef) PlanError!*PlanNode {
        switch (tref) {
            .named => |n| {
                const tbl = self.schema.getTable(n.name) orelse return error.TableNotFound;
                const alias = n.alias orelse n.name;
                const start_pos: u32 = @intCast(self.scope.items.len);
                var col_ids: std.ArrayList(schema_mod.ColumnId) = .empty;
                for (tbl.columns, 0..) |col, i| {
                    try col_ids.append(self.arena, col.id);
                    try self.scope.append(self.arena, .{
                        .table_alias = alias,
                        .col_name = col.name,
                        .position = start_pos + @as(u32, @intCast(i)),
                    });
                }
                const node = try self.arena.create(PlanNode);
                var index_hint: ?schema_mod.IndexId = null;
                for (tbl.indexes) |idx| {
                    if (idx.kind == .vector or idx.kind == .json_path) {
                        index_hint = idx.id;
                        break;
                    }
                }
                node.* = .{ .scan = .{
                    .table_id = tbl.id,
                    .columns = try col_ids.toOwnedSlice(self.arena),
                    .index_hint = index_hint,
                } };
                return node;
            },
            .subquery => |sq| return self.planSelect(sq.query.*),
            .cte_ref => |cref| {
                if (self.resolveCte(cref.name)) |entry| {
                    // Add output columns of the CTE to scope so column refs resolve
                    const alias = cref.alias orelse cref.name;
                    const start_pos: u32 = @intCast(self.scope.items.len);
                    for (entry.items, 0..) |item, i| {
                        switch (item) {
                            .star => {},
                            .expr => |ei| {
                                const col_name = ei.alias orelse blk: {
                                    if (ei.expr.* == .column_ref) break :blk ei.expr.column_ref.column;
                                    break :blk "";
                                };
                                if (col_name.len > 0) {
                                    try self.scope.append(self.arena, .{
                                        .table_alias = alias,
                                        .col_name = col_name,
                                        .position = start_pos + @as(u32, @intCast(i)),
                                    });
                                }
                            },
                        }
                    }
                    return entry.node;
                }
                const node = try self.arena.create(PlanNode);
                node.* = .empty;
                return node;
            },
        }
    }

    fn planInsert(self: *Planner, stmt: ast.InsertStmt) PlanError!InsertPlan {
        const tbl = self.schema.getTable(stmt.table) orelse return error.TableNotFound;
        var col_ids: std.ArrayList(schema_mod.ColumnId) = .empty;
        if (stmt.columns.len == 0) {
            for (tbl.columns) |col| try col_ids.append(self.arena, col.id);
        } else {
            for (stmt.columns) |col_name| {
                const col = tbl.columnByName(col_name) orelse return error.ColumnNotFound;
                try col_ids.append(self.arena, col.id);
            }
        }
        const source: InsertSource = switch (stmt.source) {
            .values => |rows| blk: {
                var planned_rows: std.ArrayList([]const *PlanExpr) = .empty;
                for (rows) |row| {
                    var planned_row: std.ArrayList(*PlanExpr) = .empty;
                    for (row) |e| {
                        try planned_row.append(self.arena, try self.planExpr(e));
                    }
                    try planned_rows.append(self.arena, try planned_row.toOwnedSlice(self.arena));
                }
                break :blk .{ .values = try planned_rows.toOwnedSlice(self.arena) };
            },
            .query => |q| .{ .query = try self.planSelect(q.*) },
        };
        const on_conflict: ?OnConflictPlan = if (stmt.on_conflict) |oc| switch (oc) {
            .do_nothing => .do_nothing,
            .do_update => |du| blk: {
                // Set up table scope so SET expressions can reference existing column values.
                const scope_save = self.scope.items.len;
                defer self.scope.shrinkRetainingCapacity(scope_save);
                for (tbl.columns, 0..) |col, i| {
                    try self.scope.append(self.arena, .{
                        .table_alias = stmt.table,
                        .col_name = col.name,
                        .position = @intCast(i),
                    });
                }
                var assignments: std.ArrayList(UpdateAssignment) = .empty;
                for (du.sets) |a| {
                    const col = tbl.columnByName(a.column) orelse return error.ColumnNotFound;
                    try assignments.append(self.arena, .{
                        .column_id = col.id,
                        .value = try self.planExpr(a.value),
                    });
                }
                break :blk .{ .do_update = try assignments.toOwnedSlice(self.arena) };
            },
        } else null;

        var returning_items: std.ArrayList(ProjectItem) = .empty;
        if (stmt.returning.len > 0) {
            const scope_save = self.scope.items.len;
            defer self.scope.shrinkRetainingCapacity(scope_save);
            for (tbl.columns, 0..) |col, i| {
                try self.scope.append(self.arena, .{
                    .table_alias = stmt.table,
                    .col_name = col.name,
                    .position = @intCast(i),
                });
            }
            for (stmt.returning) |item| {
                switch (item) {
                    .star => {},
                    .expr => |ei| {
                        const alias = ei.alias orelse exprNaturalName(ei.expr);
                        try returning_items.append(self.arena, .{
                            .expr = try self.planExpr(ei.expr),
                            .alias = alias,
                        });
                    },
                }
            }
        }

        return .{
            .table_id = tbl.id,
            .column_ids = try col_ids.toOwnedSlice(self.arena),
            .source = source,
            .on_conflict = on_conflict,
            .returning = try returning_items.toOwnedSlice(self.arena),
        };
    }

    fn planUpdate(self: *Planner, stmt: ast.UpdateStmt) PlanError!UpdatePlan {
        const tbl = self.schema.getTable(stmt.table) orelse return error.TableNotFound;
        const scope_save = self.scope.items.len;
        defer self.scope.shrinkRetainingCapacity(scope_save);
        for (tbl.columns, 0..) |col, i| {
            try self.scope.append(self.arena, .{
                .table_alias = stmt.alias orelse stmt.table,
                .col_name = col.name,
                .position = @intCast(i),
            });
        }
        var from_table_id: ?schema_mod.TableId = null;
        if (stmt.from) |from_ref| {
            switch (from_ref) {
                .named => |n| {
                    const from_tbl = self.schema.getTable(n.name) orelse return error.TableNotFound;
                    const from_alias = n.alias orelse n.name;
                    const start: u32 = @intCast(self.scope.items.len);
                    for (from_tbl.columns, 0..) |col, i| {
                        try self.scope.append(self.arena, .{
                            .table_alias = from_alias,
                            .col_name = col.name,
                            .position = start + @as(u32, @intCast(i)),
                        });
                    }
                    from_table_id = from_tbl.id;
                },
                else => return error.TableNotFound,
            }
        }
        var assignments: std.ArrayList(UpdateAssignment) = .empty;
        for (stmt.sets) |a| {
            const col = tbl.columnByName(a.column) orelse return error.ColumnNotFound;
            try assignments.append(self.arena, .{
                .column_id = col.id,
                .value = try self.planExpr(a.value),
            });
        }
        const filter = if (stmt.where) |w| try self.planExpr(w) else null;
        var upd_returning: std.ArrayList(ProjectItem) = .empty;
        for (stmt.returning) |item| {
            switch (item) {
                .star => {},
                .expr => |ei| {
                    const alias = ei.alias orelse exprNaturalName(ei.expr);
                    try upd_returning.append(self.arena, .{
                        .expr = try self.planExpr(ei.expr),
                        .alias = alias,
                    });
                },
            }
        }
        return .{
            .table_id = tbl.id,
            .assignments = try assignments.toOwnedSlice(self.arena),
            .filter = filter,
            .returning = try upd_returning.toOwnedSlice(self.arena),
            .from_table_id = from_table_id,
        };
    }

    fn planDelete(self: *Planner, stmt: ast.DeleteStmt) PlanError!DeletePlan {
        const tbl = self.schema.getTable(stmt.table) orelse return error.TableNotFound;
        const scope_save = self.scope.items.len;
        defer self.scope.shrinkRetainingCapacity(scope_save);
        for (tbl.columns, 0..) |col, i| {
            try self.scope.append(self.arena, .{
                .table_alias = stmt.alias orelse stmt.table,
                .col_name = col.name,
                .position = @intCast(i),
            });
        }
        var using_ids: std.ArrayList(schema_mod.TableId) = .empty;
        for (stmt.using) |using_ref| {
            switch (using_ref) {
                .named => |n| {
                    const using_tbl = self.schema.getTable(n.name) orelse return error.TableNotFound;
                    const using_alias = n.alias orelse n.name;
                    const start: u32 = @intCast(self.scope.items.len);
                    for (using_tbl.columns, 0..) |col, i| {
                        try self.scope.append(self.arena, .{
                            .table_alias = using_alias,
                            .col_name = col.name,
                            .position = start + @as(u32, @intCast(i)),
                        });
                    }
                    try using_ids.append(self.arena, using_tbl.id);
                },
                else => return error.TableNotFound,
            }
        }
        const filter = if (stmt.where) |w| try self.planExpr(w) else null;
        var del_returning: std.ArrayList(ProjectItem) = .empty;
        for (stmt.returning) |item| {
            switch (item) {
                .star => {},
                .expr => |ei| {
                    const alias = ei.alias orelse exprNaturalName(ei.expr);
                    try del_returning.append(self.arena, .{
                        .expr = try self.planExpr(ei.expr),
                        .alias = alias,
                    });
                },
            }
        }
        return .{
            .table_id = tbl.id,
            .filter = filter,
            .returning = try del_returning.toOwnedSlice(self.arena),
            .using_table_ids = try using_ids.toOwnedSlice(self.arena),
        };
    }

    fn planMerge(self: *Planner, stmt: ast.MergeStmt) PlanError!MergePlan {
        const target_tbl = self.schema.getTable(stmt.target.name) orelse return error.TableNotFound;
        const target_alias = stmt.target.alias orelse stmt.target.name;
        const scope_save = self.scope.items.len;
        defer self.scope.shrinkRetainingCapacity(scope_save);

        // Target columns come first in the combined row
        const target_width: u32 = @intCast(target_tbl.columns.len);
        for (target_tbl.columns, 0..) |col, i| {
            try self.scope.append(self.arena, .{
                .table_alias = target_alias,
                .col_name = col.name,
                .position = @intCast(i),
            });
        }

        // Plan source and add source columns to scope after target columns
        const source_node = try self.planTableRef(stmt.source.ref);
        switch (stmt.source.ref) {
            .named => |n| {
                const src_tbl = self.schema.getTable(n.name) orelse return error.TableNotFound;
                const src_alias = n.alias orelse n.name;
                for (src_tbl.columns, 0..) |col, i| {
                    try self.scope.append(self.arena, .{
                        .table_alias = src_alias,
                        .col_name = col.name,
                        .position = target_width + @as(u32, @intCast(i)),
                    });
                }
            },
            else => {},
        }

        const on_condition = try self.planExpr(stmt.on);

        var whens: std.ArrayList(MergeWhenPlan) = .empty;
        for (stmt.whens) |when| {
            switch (when) {
                .matched => |m| {
                    const cond = if (m.cond) |c| try self.planExpr(c) else null;
                    const action: MergeActionPlan = switch (m.action) {
                        .update => |sets| blk: {
                            var asgns: std.ArrayList(UpdateAssignment) = .empty;
                            for (sets) |a| {
                                const col = target_tbl.columnByName(a.column) orelse return error.ColumnNotFound;
                                try asgns.append(self.arena, .{
                                    .column_id = col.id,
                                    .value = try self.planExpr(a.value),
                                });
                            }
                            break :blk .{ .update = try asgns.toOwnedSlice(self.arena) };
                        },
                        .delete => .delete,
                        .do_nothing => .do_nothing,
                    };
                    try whens.append(self.arena, .{
                        .matched = .{ .cond = cond, .action = action },
                    });
                },
                .not_matched => |nm| {
                    const cond = if (nm.cond) |c| try self.planExpr(c) else null;
                    var col_ids: std.ArrayList(schema_mod.ColumnId) = .empty;
                    for (nm.columns) |col_name| {
                        const col = target_tbl.columnByName(col_name) orelse return error.ColumnNotFound;
                        try col_ids.append(self.arena, col.id);
                    }
                    var vals: std.ArrayList(*PlanExpr) = .empty;
                    for (nm.values) |v| try vals.append(self.arena, try self.planExpr(v));
                    try whens.append(self.arena, .{
                        .not_matched = .{
                            .cond = cond,
                            .column_ids = try col_ids.toOwnedSlice(self.arena),
                            .values = try vals.toOwnedSlice(self.arena),
                        },
                    });
                },
            }
        }

        return .{
            .target_id = target_tbl.id,
            .source = source_node,
            .on_condition = on_condition,
            .target_width = target_width,
            .whens = try whens.toOwnedSlice(self.arena),
        };
    }

    pub fn planExpr(self: *Planner, e: *ast.Expr) PlanError!*PlanExpr {
        const pe = try self.arena.create(PlanExpr);
        switch (e.*) {
            .lit_int => |v| pe.* = .{ .int_literal = @intCast(v) },
            .lit_float => |v| pe.* = .{ .float_literal = v },
            .lit_string => |v| pe.* = .{ .string_literal = v },
            .lit_bytes => |v| pe.* = .{ .bytes_literal = v },
            .lit_bool => |v| pe.* = .{ .bool_literal = v },
            .lit_null => pe.* = .null_literal,
            .param => |i| pe.* = .{ .param = i },
            .nondet => {
                pe.* = .{ .nondet = self.nondet_idx };
                self.nondet_idx += 1;
            },
            .column_ref => |ref| {
                // Type-checked AST guarantees all column refs are resolvable.
                const pos = self.resolveColRef(ref) orelse return error.ColumnNotFound;
                pe.* = .{ .column = pos };
            },
            .cast => |c| pe.* = .{ .cast = .{
                .expr = try self.planExpr(c.expr),
                .to = c.to,
            } },
            .binary => |b| pe.* = .{ .binary = .{
                .op = b.op,
                .left = try self.planExpr(b.left),
                .right = try self.planExpr(b.right),
            } },
            .unary => |u| pe.* = .{ .unary = .{
                .op = u.op,
                .expr = try self.planExpr(u.expr),
            } },
            .is_null => |inner| pe.* = .{ .is_null = try self.planExpr(inner) },
            .is_not_null => |inner| pe.* = .{ .is_not_null = try self.planExpr(inner) },
            .is_distinct => |pair| pe.* = .{ .binary = .{
                .op = .neq,
                .left = try self.planExpr(pair.left),
                .right = try self.planExpr(pair.right),
            } },
            .is_not_distinct => |pair| pe.* = .{ .binary = .{
                .op = .eq,
                .left = try self.planExpr(pair.left),
                .right = try self.planExpr(pair.right),
            } },
            .fn_call => |f| {
                // In post-agg projection context, the agg result is already computed —
                // resolve by name to its output column regardless of arg count.
                if (self.resolveAggFn(f.name)) |pos| {
                    pe.* = .{ .column = pos };
                    return pe;
                }
                var args: std.ArrayList(*PlanExpr) = .empty;
                for (f.args) |a| try args.append(self.arena, try self.planExpr(a));
                pe.* = .{ .fn_call = .{
                    .name = f.name,
                    .args = try args.toOwnedSlice(self.arena),
                } };
            },
            .window_fn => |w| {
                // Window node is pre-inserted by planSelect before any item projection.
                const pos = self.resolveWindowFn(w.call.name) orelse return error.UnsupportedOperation;
                pe.* = .{ .column = pos };
            },
            .case_searched => |c| {
                var whens: std.ArrayList(PlanCaseWhen) = .empty;
                for (c.whens) |w| {
                    try whens.append(self.arena, .{
                        .cond = try self.planExpr(w.cond),
                        .result = try self.planExpr(w.result),
                    });
                }
                const else_pe: ?*PlanExpr = if (c.else_expr) |ee| try self.planExpr(ee) else null;
                pe.* = .{ .case_searched = .{
                    .whens = try whens.toOwnedSlice(self.arena),
                    .else_expr = else_pe,
                } };
            },
            .case_simple => |c| {
                // Expand to searched CASE
                var whens: std.ArrayList(PlanCaseWhen) = .empty;
                const op_pe = try self.planExpr(c.operand);
                for (c.whens) |w| {
                    const cond_val = try self.planExpr(w.cond);
                    const eq_pe = try self.arena.create(PlanExpr);
                    eq_pe.* = .{ .binary = .{ .op = .eq, .left = op_pe, .right = cond_val } };
                    try whens.append(self.arena, .{
                        .cond = eq_pe,
                        .result = try self.planExpr(w.result),
                    });
                }
                const else_pe: ?*PlanExpr = if (c.else_expr) |ee| try self.planExpr(ee) else null;
                pe.* = .{ .case_searched = .{
                    .whens = try whens.toOwnedSlice(self.arena),
                    .else_expr = else_pe,
                } };
            },
            .between => |b| {
                // a BETWEEN low AND high → a >= low AND a <= high
                const a_low = try self.arena.create(PlanExpr);
                const a_high = try self.arena.create(PlanExpr);
                a_low.* = .{ .binary = .{ .op = .gte, .left = try self.planExpr(b.expr), .right = try self.planExpr(b.low) } };
                a_high.* = .{ .binary = .{ .op = .lte, .left = try self.planExpr(b.expr), .right = try self.planExpr(b.high) } };
                pe.* = .{ .binary = .{ .op = .and_op, .left = a_low, .right = a_high } };
            },
            .like => |l| pe.* = .{ .fn_call = .{
                .name = "like",
                .args = try self.arena.dupe(*PlanExpr, &.{ try self.planExpr(l.expr), try self.planExpr(l.pattern) }),
            } },
            .in_list => |il| {
                var args: std.ArrayList(*PlanExpr) = .empty;
                try args.append(self.arena, try self.planExpr(il.expr));
                for (il.values) |v| try args.append(self.arena, try self.planExpr(v));
                pe.* = .{ .fn_call = .{ .name = "in_list", .args = try args.toOwnedSlice(self.arena) } };
            },
            .not_in_list => |il| {
                var args: std.ArrayList(*PlanExpr) = .empty;
                try args.append(self.arena, try self.planExpr(il.expr));
                for (il.values) |v| try args.append(self.arena, try self.planExpr(v));
                pe.* = .{ .fn_call = .{ .name = "not_in_list", .args = try args.toOwnedSlice(self.arena) } };
            },
            .subquery => |q| {
                // Fresh planner so subquery column positions start at 0,
                // independent of the outer query's scope.
                var sp = Planner.init(self.arena, self.schema);
                const sub = try sp.planSelect(q.*);
                pe.* = .{ .scalar_subquery = sub };
            },
            .exists => |q| {
                var sp = Planner.init(self.arena, self.schema);
                const sub = try sp.planSelect(q.*);
                pe.* = .{ .exists_subquery = sub };
            },
            .not_exists => |q| {
                var sp = Planner.init(self.arena, self.schema);
                const sub = try sp.planSelect(q.*);
                pe.* = .{ .not_exists_subquery = sub };
            },
            .in_subquery => |s| {
                var sp = Planner.init(self.arena, self.schema);
                const sub = try sp.planSelect(s.query.*);
                pe.* = .{ .in_subquery = .{ .expr = try self.planExpr(s.expr), .plan = sub } };
            },
            .not_in_subquery => |s| {
                var sp = Planner.init(self.arena, self.schema);
                const sub = try sp.planSelect(s.query.*);
                pe.* = .{ .not_in_subquery = .{ .expr = try self.planExpr(s.expr), .plan = sub } };
            },
            .typed => |t| return self.planExpr(t.inner),
        }
        return pe;
    }
};

fn extractAggFn(e: *ast.Expr) ?ast.FnCall {
    return switch (e.*) {
        .fn_call => |f| blk: {
            const aggs = [_][]const u8{ "count", "sum", "avg", "min", "max", "array_agg", "string_agg" };
            for (aggs) |a| {
                if (std.ascii.eqlIgnoreCase(f.name, a)) break :blk f;
            }
            break :blk null;
        },
        else => null,
    };
}
