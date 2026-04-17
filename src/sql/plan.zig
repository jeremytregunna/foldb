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
    bool_val:   bool,
    int_val:    i64,
    uint_val:   u64,
    float_val:  f64,
    string_val: []const u8,
    bytes_val:  []const u8,
    // Complex types stored as opaque bytes
    opaque_val: []const u8,

    pub fn isNull(self: Value) bool { return self == .null_val; }

    pub fn toBool(self: Value) ?bool {
        return switch (self) { .bool_val => |b| b, else => null };
    }

    pub fn eql(self: Value, other: Value) bool {
        return switch (self) {
            .null_val   => other == .null_val,
            .bool_val   => |b| switch (other) { .bool_val   => |ob| b == ob, else => false },
            .int_val    => |v| switch (other) { .int_val    => |ov| v == ov, else => false },
            .uint_val   => |v| switch (other) { .uint_val   => |ov| v == ov, else => false },
            .float_val  => |v| switch (other) { .float_val  => |ov| v == ov, else => false },
            .string_val => |v| switch (other) { .string_val => |ov| std.mem.eql(u8, v, ov), else => false },
            .bytes_val  => |v| switch (other) { .bytes_val  => |ov| std.mem.eql(u8, v, ov), else => false },
            .opaque_val => |v| switch (other) { .opaque_val => |ov| std.mem.eql(u8, v, ov), else => false },
        };
    }

    pub fn lessThan(self: Value, other: Value) bool {
        return switch (self) {
            .int_val    => |v| switch (other) { .int_val    => |ov| v < ov, else => false },
            .uint_val   => |v| switch (other) { .uint_val   => |ov| v < ov, else => false },
            .float_val  => |v| switch (other) { .float_val  => |ov| v < ov, else => false },
            .string_val => |v| switch (other) { .string_val => |ov| std.mem.lessThan(u8, v, ov), else => false },
            else        => false,
        };
    }
};

// ─── Planner scope tracking ───────────────────────────────────────────────────

const PlanScopeEntry = struct {
    table_alias: []const u8, // "" if no qualifier
    col_name:    []const u8,
    position:    u32,
};

const PostAggCol = struct {
    fn_name:  []const u8,
    position: u32,
};

// ─── Plan nodes ──────────────────────────────────────────────────────────────

pub const ScanNode = struct {
    table_id:  schema_mod.TableId,
    columns:   []const schema_mod.ColumnId, // which columns to project
};

pub const PkLookupNode = struct {
    table_id:  schema_mod.TableId,
    key_expr:  *PlanExpr,
    columns:   []const schema_mod.ColumnId,
};

pub const FilterNode = struct {
    input:     *PlanNode,
    predicate: *PlanExpr,
};

pub const ProjectNode = struct {
    input:    *PlanNode,
    exprs:    []const ProjectItem,
};

pub const ProjectItem = struct {
    expr:  *PlanExpr,
    alias: []const u8,
};

pub const SortNode = struct {
    input:   *PlanNode,
    keys:    []const SortKey,
};

pub const SortKey = struct {
    expr:        *PlanExpr,
    asc:         bool,
    nulls_first: bool,
};

pub const LimitNode = struct {
    input:  *PlanNode,
    limit:  ?*PlanExpr,
    offset: ?*PlanExpr,
};

pub const HashAggNode = struct {
    input:      *PlanNode,
    group_keys: []const *PlanExpr,
    agg_exprs:  []const AggExpr,
};

pub const AggExpr = struct {
    fn_name:  []const u8,
    arg:      ?*PlanExpr,
    distinct: bool,
    alias:    []const u8,
};

pub const HashJoinNode = struct {
    left:       *PlanNode,
    right:      *PlanNode,
    kind:       ast.JoinKind,
    condition:  *PlanExpr,
};

pub const InsertPlan = struct {
    table_id:    schema_mod.TableId,
    column_ids:  []const schema_mod.ColumnId,
    source:      InsertSource,
    on_conflict: ?OnConflictPlan,
};

pub const InsertSource = union(enum) {
    values: []const []const *PlanExpr,
    query:  *PlanNode,
};

pub const OnConflictPlan = union(enum) {
    do_nothing,
    do_update: []const UpdateAssignment,
};

pub const UpdatePlan = struct {
    table_id:   schema_mod.TableId,
    assignments: []const UpdateAssignment,
    filter:      ?*PlanExpr,
};

pub const UpdateAssignment = struct {
    column_id: schema_mod.ColumnId,
    value:     *PlanExpr,
};

pub const DeletePlan = struct {
    table_id: schema_mod.TableId,
    filter:   ?*PlanExpr,
};

pub const AssertPlan = struct {
    predicate: *PlanExpr,
    message:   []const u8,
};

pub const PlanNode = union(enum) {
    scan:       ScanNode,
    pk_lookup:  PkLookupNode,
    filter:     FilterNode,
    project:    ProjectNode,
    sort:       SortNode,
    limit:      LimitNode,
    hash_agg:   HashAggNode,
    hash_join:  HashJoinNode,
    // DML nodes
    insert:     InsertPlan,
    update:     UpdatePlan,
    delete:     DeletePlan,
    assert:     AssertPlan,
    // Empty result (zero rows)
    empty,
    // Single-row source for FROM-less SELECT (produces exactly one empty row)
    single_row,
};

// ─── Plan expressions ─────────────────────────────────────────────────────────

pub const PlanExpr = union(enum) {
    null_literal,
    bool_literal:   bool,
    int_literal:    i64,
    uint_literal:   u64,
    float_literal:  f64,
    string_literal: []const u8,
    bytes_literal:  []const u8,

    // Parameter reference (0-based)
    param: u32,

    // Nondeterminism reference (0-based index into resolved_nondet)
    nondet: u32,

    // Column in the current row (by position in the output schema)
    column: u32,

    // Column from a specific table in a join context
    table_column: struct { table_idx: u32, col_idx: u32 },

    binary: struct { op: ast.BinOp, left: *PlanExpr, right: *PlanExpr },
    unary:  struct { op: ast.UnaryOp, expr: *PlanExpr },

    cast:   struct { expr: *PlanExpr, to: ast.SqlType },

    is_null:     *PlanExpr,
    is_not_null: *PlanExpr,

    fn_call: struct { name: []const u8, args: []*PlanExpr },

    case_searched: struct { whens: []PlanCaseWhen, else_expr: ?*PlanExpr },
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

pub const StmtKind = enum { select, insert, update, delete, assert };

pub const StmtPlan = union(enum) {
    select: *PlanNode,
    insert: InsertPlan,
    update: UpdatePlan,
    delete: DeletePlan,
    assert: AssertPlan,
};

// ─── Planner ─────────────────────────────────────────────────────────────────

pub const Planner = struct {
    schema:        *const schema_mod.SchemaRegistry,
    arena:         std.mem.Allocator,
    nondet_idx:    u32 = 0,
    scope:         std.ArrayList(PlanScopeEntry) = .empty,
    post_agg_cols: std.ArrayList(PostAggCol) = .empty,

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
            .stmts        = try stmts.toOwnedSlice(self.arena),
            .param_types  = try param_types.toOwnedSlice(self.arena),
            .nondet_count = self.nondet_idx,
        };
    }

    pub fn planStmt(self: *Planner, s: ast.Stmt, params: []const ast.SqlType) PlanError!ExecutionPlan {
        const sp = try self.planAstStmt(s);
        return .{
            .stmts        = try self.arena.dupe(StmtPlan, &.{sp}),
            .param_types  = params,
            .nondet_count = self.nondet_idx,
        };
    }

    fn planTxnStmt(self: *Planner, s: ast.TxnStmt) PlanError!StmtPlan {
        return switch (s) {
            .select => |q| .{ .select = try self.planSelect(q) },
            .insert => |q| .{ .insert = try self.planInsert(q) },
            .update => |q| .{ .update = try self.planUpdate(q) },
            .delete => |q| .{ .delete = try self.planDelete(q) },
            .merge  => error.UnsupportedOperation,
            .assert => |e| .{ .assert = .{ .predicate = try self.planExpr(e), .message = "assertion failed" } },
        };
    }

    pub fn planAstStmt(self: *Planner, s: ast.Stmt) PlanError!StmtPlan {
        return switch (s) {
            .select      => |q| .{ .select = try self.planSelect(q) },
            .insert      => |q| .{ .insert = try self.planInsert(q) },
            .update      => |q| .{ .update = try self.planUpdate(q) },
            .delete      => |q| .{ .delete = try self.planDelete(q) },
            .merge       => error.UnsupportedOperation,
            .create_table, .create_index, .alter_table => error.UnsupportedOperation,
            .transaction => error.UnsupportedOperation,
        };
    }

    fn planSelect(self: *Planner, q: ast.SelectStmt) PlanError!*PlanNode {
        const scope_save     = self.scope.items.len;
        const post_agg_save  = self.post_agg_cols.items.len;
        defer {
            self.scope.shrinkRetainingCapacity(scope_save);
            self.post_agg_cols.shrinkRetainingCapacity(post_agg_save);
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
            const right = try self.planTableRef(j.table);
            const cond = if (j.condition) |c| switch (c) {
                .on    => |e| try self.planExpr(e),
                .using => blk: {
                    // USING: synthesize equality condition
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
                .left      = node,
                .right     = right,
                .kind      = j.kind,
                .condition = cond,
            }};
            node = join_node;
        }

        // WHERE filter
        if (q.where) |w| {
            const pred = try self.planExpr(w);
            const filter_node = try self.arena.create(PlanNode);
            filter_node.* = .{ .filter = .{ .input = node, .predicate = pred } };
            node = filter_node;
        }

        // GROUP BY + aggregates
        if (q.group_by.len > 0) {
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
                            else null;
                            try agg_exprs.append(self.arena, .{
                                .fn_name  = fn_call.name,
                                .arg      = arg,
                                .distinct = fn_call.distinct,
                                .alias    = ei.alias orelse fn_call.name,
                            });
                        }
                    },
                }
            }
            const group_keys_slice = try keys.toOwnedSlice(self.arena);
            const agg_exprs_slice  = try agg_exprs.toOwnedSlice(self.arena);
            const agg_node = try self.arena.create(PlanNode);
            agg_node.* = .{ .hash_agg = .{
                .input      = node,
                .group_keys = group_keys_slice,
                .agg_exprs  = agg_exprs_slice,
            }};
            node = agg_node;

            // Rebuild scope for hash_agg output: [group_key_0, ..., agg_0, ...]
            self.scope.shrinkRetainingCapacity(scope_save);
            self.post_agg_cols.shrinkRetainingCapacity(post_agg_save);
            for (key_col_refs.items, 0..) |maybe_ref, i| {
                if (maybe_ref) |ref| {
                    try self.scope.append(self.arena, .{
                        .table_alias = ref.table orelse "",
                        .col_name    = ref.column,
                        .position    = @intCast(i),
                    });
                }
            }
            for (agg_exprs_slice, 0..) |ae, i| {
                try self.post_agg_cols.append(self.arena, .{
                    .fn_name  = ae.fn_name,
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

        // ORDER BY (always with deterministic ordering)
        if (q.order_by.len > 0) {
            var keys: std.ArrayList(SortKey) = .empty;
            for (q.order_by) |ob| {
                try keys.append(self.arena, .{
                    .expr        = try self.planExpr(ob.expr),
                    .asc         = ob.asc,
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
                .input  = node,
                .limit  = if (q.limit)  |l| try self.planExpr(l) else null,
                .offset = if (q.offset) |o| try self.planExpr(o) else null,
            }};
            node = limit_node;
        }

        // Project selected items
        var proj_items: std.ArrayList(ProjectItem) = .empty;
        for (q.items) |item| {
            switch (item) {
                .star => {}, // expand at execution time
                .expr => |ei| {
                    try proj_items.append(self.arena, .{
                        .expr  = try self.planExpr(ei.expr),
                        .alias = ei.alias orelse "",
                    });
                },
            }
        }
        if (proj_items.items.len > 0) {
            const proj_node = try self.arena.create(PlanNode);
            proj_node.* = .{ .project = .{ .input = node, .exprs = try proj_items.toOwnedSlice(self.arena) } };
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
                        .col_name    = col.name,
                        .position    = start_pos + @as(u32, @intCast(i)),
                    });
                }
                const node = try self.arena.create(PlanNode);
                node.* = .{ .scan = .{
                    .table_id = tbl.id,
                    .columns  = try col_ids.toOwnedSlice(self.arena),
                }};
                return node;
            },
            .subquery => |sq| return self.planSelect(sq.query.*),
            .cte_ref  => {
                const node = try self.arena.create(PlanNode);
                node.* = .empty;
                return node;
            },
        }
    }

    fn planInsert(self: *Planner, stmt: ast.InsertStmt) PlanError!InsertPlan {
        const tbl = self.schema.getTable(stmt.table) orelse return error.TableNotFound;
        var col_ids: std.ArrayList(schema_mod.ColumnId) = .empty;
        for (stmt.columns) |col_name| {
            const col = tbl.columnByName(col_name) orelse return error.ColumnNotFound;
            try col_ids.append(self.arena, col.id);
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
            .do_update  => |du| blk: {
                var assignments: std.ArrayList(UpdateAssignment) = .empty;
                for (du.sets) |a| {
                    const col = tbl.columnByName(a.column) orelse return error.ColumnNotFound;
                    try assignments.append(self.arena, .{
                        .column_id = col.id,
                        .value     = try self.planExpr(a.value),
                    });
                }
                break :blk .{ .do_update = try assignments.toOwnedSlice(self.arena) };
            },
        } else null;

        return .{
            .table_id    = tbl.id,
            .column_ids  = try col_ids.toOwnedSlice(self.arena),
            .source      = source,
            .on_conflict = on_conflict,
        };
    }

    fn planUpdate(self: *Planner, stmt: ast.UpdateStmt) PlanError!UpdatePlan {
        const tbl = self.schema.getTable(stmt.table) orelse return error.TableNotFound;
        const scope_save = self.scope.items.len;
        defer self.scope.shrinkRetainingCapacity(scope_save);
        for (tbl.columns, 0..) |col, i| {
            try self.scope.append(self.arena, .{
                .table_alias = stmt.table,
                .col_name    = col.name,
                .position    = @intCast(i),
            });
        }
        var assignments: std.ArrayList(UpdateAssignment) = .empty;
        for (stmt.sets) |a| {
            const col = tbl.columnByName(a.column) orelse return error.ColumnNotFound;
            try assignments.append(self.arena, .{
                .column_id = col.id,
                .value     = try self.planExpr(a.value),
            });
        }
        const filter = if (stmt.where) |w| try self.planExpr(w) else null;
        return .{
            .table_id    = tbl.id,
            .assignments = try assignments.toOwnedSlice(self.arena),
            .filter      = filter,
        };
    }

    fn planDelete(self: *Planner, stmt: ast.DeleteStmt) PlanError!DeletePlan {
        const tbl = self.schema.getTable(stmt.table) orelse return error.TableNotFound;
        const scope_save = self.scope.items.len;
        defer self.scope.shrinkRetainingCapacity(scope_save);
        for (tbl.columns, 0..) |col, i| {
            try self.scope.append(self.arena, .{
                .table_alias = stmt.table,
                .col_name    = col.name,
                .position    = @intCast(i),
            });
        }
        const filter = if (stmt.where) |w| try self.planExpr(w) else null;
        return .{ .table_id = tbl.id, .filter = filter };
    }

    pub fn planExpr(self: *Planner, e: *ast.Expr) PlanError!*PlanExpr {
        const pe = try self.arena.create(PlanExpr);
        switch (e.*) {
            .lit_int    => |v| pe.* = .{ .int_literal    = @intCast(v) },
            .lit_float  => |v| pe.* = .{ .float_literal  = v },
            .lit_string => |v| pe.* = .{ .string_literal = v },
            .lit_bytes  => |v| pe.* = .{ .bytes_literal  = v },
            .lit_bool   => |v| pe.* = .{ .bool_literal   = v },
            .lit_null   => pe.* = .null_literal,
            .param      => |i| pe.* = .{ .param = i },
            .nondet     => {
                pe.* = .{ .nondet = self.nondet_idx };
                self.nondet_idx += 1;
            },
            .column_ref => |ref| {
                if (self.resolveColRef(ref)) |pos| {
                    pe.* = .{ .column = pos };
                } else {
                    // CTE ref or subquery col — fall back to name-based lookup
                    pe.* = .{ .fn_call = .{ .name = ref.column, .args = &.{} }};
                }
            },
            .cast => |c| pe.* = .{ .cast = .{
                .expr = try self.planExpr(c.expr),
                .to   = c.to,
            }},
            .binary => |b| pe.* = .{ .binary = .{
                .op    = b.op,
                .left  = try self.planExpr(b.left),
                .right = try self.planExpr(b.right),
            }},
            .unary => |u| pe.* = .{ .unary = .{
                .op   = u.op,
                .expr = try self.planExpr(u.expr),
            }},
            .is_null     => |inner| pe.* = .{ .is_null     = try self.planExpr(inner) },
            .is_not_null => |inner| pe.* = .{ .is_not_null = try self.planExpr(inner) },
            .is_distinct => |pair| pe.* = .{ .binary = .{
                .op    = .neq,
                .left  = try self.planExpr(pair.left),
                .right = try self.planExpr(pair.right),
            }},
            .is_not_distinct => |pair| pe.* = .{ .binary = .{
                .op    = .eq,
                .left  = try self.planExpr(pair.left),
                .right = try self.planExpr(pair.right),
            }},
            .fn_call => |f| {
                // In post-agg projection context, resolve aggregate fn names to column positions
                if (f.args.len == 0 or f.star) {
                    if (self.resolveAggFn(f.name)) |pos| {
                        pe.* = .{ .column = pos };
                        return pe;
                    }
                }
                var args: std.ArrayList(*PlanExpr) = .empty;
                for (f.args) |a| try args.append(self.arena, try self.planExpr(a));
                pe.* = .{ .fn_call = .{
                    .name = f.name,
                    .args = try args.toOwnedSlice(self.arena),
                }};
            },
            .window_fn => |w| {
                var args: std.ArrayList(*PlanExpr) = .empty;
                for (w.call.args) |a| try args.append(self.arena, try self.planExpr(a));
                pe.* = .{ .fn_call = .{
                    .name = w.call.name,
                    .args = try args.toOwnedSlice(self.arena),
                }};
            },
            .case_searched => |c| {
                var whens: std.ArrayList(PlanCaseWhen) = .empty;
                for (c.whens) |w| {
                    try whens.append(self.arena, .{
                        .cond   = try self.planExpr(w.cond),
                        .result = try self.planExpr(w.result),
                    });
                }
                const else_pe: ?*PlanExpr = if (c.else_expr) |ee| try self.planExpr(ee) else null;
                pe.* = .{ .case_searched = .{
                    .whens     = try whens.toOwnedSlice(self.arena),
                    .else_expr = else_pe,
                }};
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
                        .cond   = eq_pe,
                        .result = try self.planExpr(w.result),
                    });
                }
                const else_pe: ?*PlanExpr = if (c.else_expr) |ee| try self.planExpr(ee) else null;
                pe.* = .{ .case_searched = .{
                    .whens     = try whens.toOwnedSlice(self.arena),
                    .else_expr = else_pe,
                }};
            },
            .between => |b| {
                // a BETWEEN low AND high → a >= low AND a <= high
                const a_low = try self.arena.create(PlanExpr);
                const a_high = try self.arena.create(PlanExpr);
                a_low.*  = .{ .binary = .{ .op = .gte, .left = try self.planExpr(b.expr), .right = try self.planExpr(b.low) } };
                a_high.* = .{ .binary = .{ .op = .lte, .left = try self.planExpr(b.expr), .right = try self.planExpr(b.high) } };
                pe.* = .{ .binary = .{ .op = .and_op, .left = a_low, .right = a_high } };
            },
            .like => |l| pe.* = .{ .fn_call = .{
                .name = "like",
                .args = try self.arena.dupe(*PlanExpr, &.{ try self.planExpr(l.expr), try self.planExpr(l.pattern) }),
            }},
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
            .in_subquery, .not_in_subquery, .exists, .not_exists, .subquery => {
                pe.* = .null_literal; // subquery execution planned separately
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
