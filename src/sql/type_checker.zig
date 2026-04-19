/// Type checker: walks the AST against the schema, enforcing §10.2 rules.
const std = @import("std");
const ast = @import("ast.zig");
const schema_mod = @import("schema.zig");

pub const TypeCheckError = error{
    // §10.2 violations
    SelectStarInRegisteredQuery,
    ImplicitTypeCoercion,
    NullableColumnWithoutGuard, // = on nullable column without IS NULL guard
    UnqualifiedJoinColumnRef,
    SideEffectingFunctionInWhere,
    IsolationLevelClause,
    // General
    TableNotFound,
    ColumnNotFound,
    AmbiguousColumnRef,
    TypeMismatch,
    UndefinedFunction,
    WrongArgCount,
    ParamOutOfRange,
    NonDeterministicInPlan, // nondeterministic fn not resolved
    OutOfMemory,
};

pub const TypedExpr = struct {
    expr: *ast.Expr,
    typ: ast.SqlType,
};

pub const CheckContext = struct {
    schema: *const schema_mod.SchemaRegistry,
    params: []const ast.SqlType, // parameter types for this query
    nondet_count: u32, // how many nondets assigned so far
    in_join: bool, // are we in a JOIN ON/USING clause?
    in_where: bool,
    in_having: bool,
    alloc: std.mem.Allocator,

    /// Table bindings visible in the current scope: alias or name → table schema
    scope: []const ScopeEntry,
};

pub const ScopeEntry = struct {
    alias: []const u8,
    table: *const schema_mod.TableSchema,
};

pub const TypeChecker = struct {
    alloc: std.mem.Allocator,
    schema: *const schema_mod.SchemaRegistry,
    err_msg: []const u8 = "",

    pub fn init(alloc: std.mem.Allocator, schema: *const schema_mod.SchemaRegistry) TypeChecker {
        return .{ .alloc = alloc, .schema = schema };
    }

    // ─── Statement checking ───────────────────────────────────────────────

    pub fn checkStmt(self: *TypeChecker, s: ast.Stmt, params: []const ast.SqlType, is_registered: bool) TypeCheckError!void {
        switch (s) {
            .select => |q| try self.checkSelect(q, params, is_registered),
            .insert => |q| try self.checkInsert(q, params),
            .update => |q| try self.checkUpdate(q, params),
            .delete => |q| try self.checkDelete(q, params),
            .merge => |q| try self.checkMerge(q, params),
            .create_table => |q| try self.checkCreateTable(q),
            .create_index => |q| try self.checkCreateIndex(q),
            .alter_table => |q| try self.checkAlterTable(q),
            .transaction => |q| try self.checkTransaction(q),
        }
    }

    fn checkCreateTable(self: *TypeChecker, stmt: ast.CreateTableStmt) TypeCheckError!void {
        // Validate primary key columns exist.
        for (stmt.primary_key.columns) |pk_col| {
            var found = false;
            for (stmt.columns) |col| {
                if (std.ascii.eqlIgnoreCase(col.name, pk_col)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.ColumnNotFound;
        }
        // Validate FK constraints: referenced table and columns must exist, column counts match.
        for (stmt.foreign_keys) |fk| {
            const ref_tbl = self.schema.getTable(fk.ref_table) orelse return error.TableNotFound;
            if (fk.columns.len == 0 or fk.columns.len != fk.ref_columns.len) return error.TypeMismatch;
            for (fk.columns) |col_name| {
                var found = false;
                for (stmt.columns) |col| {
                    if (std.ascii.eqlIgnoreCase(col.name, col_name)) { found = true; break; }
                }
                if (!found) return error.ColumnNotFound;
            }
            for (fk.ref_columns) |col_name| {
                _ = ref_tbl.columnByName(col_name) orelse return error.ColumnNotFound;
            }
        }
    }

    fn checkCreateIndex(self: *TypeChecker, stmt: ast.CreateIndexStmt) TypeCheckError!void {
        const tbl = self.schema.getTable(stmt.table) orelse return error.TableNotFound;
        for (stmt.columns) |col_name| {
            _ = tbl.columnByName(col_name) orelse return error.ColumnNotFound;
        }
    }

    fn checkAlterTable(self: *TypeChecker, stmt: ast.AlterTableStmt) TypeCheckError!void {
        _ = self.schema.getTable(stmt.table) orelse return error.TableNotFound;
        switch (stmt.action) {
            .drop_column => |col_name| {
                const tbl = self.schema.getTable(stmt.table).?;
                _ = tbl.columnByName(col_name) orelse return error.ColumnNotFound;
            },
            .add_column => {}, // type validity checked during parse
        }
    }

    fn checkTransaction(self: *TypeChecker, txn: ast.TransactionBlock) TypeCheckError!void {
        var param_types: std.ArrayList(ast.SqlType) = .empty;
        for (txn.params) |p| {
            try param_types.append(self.alloc, p.typ);
        }
        const param_slice = try param_types.toOwnedSlice(self.alloc);
        defer self.alloc.free(param_slice);

        for (txn.stmts) |s| {
            switch (s) {
                .select => |q| try self.checkSelect(q, param_slice, true),
                .insert => |q| try self.checkInsert(q, param_slice),
                .update => |q| try self.checkUpdate(q, param_slice),
                .delete => |q| try self.checkDelete(q, param_slice),
                .merge => |q| try self.checkMerge(q, param_slice),
                .assert => |e| {
                    const ctx = self.makeCtx(param_slice, &.{});
                    const t = try self.inferExpr(e, ctx);
                    if (!t.eql(.bool)) return error.TypeMismatch;
                },
            }
        }
    }

    fn checkSelect(self: *TypeChecker, stmt: ast.SelectStmt, params: []const ast.SqlType, is_registered: bool) TypeCheckError!void {
        const scope = try self.buildScope(stmt.from, stmt.joins);

        // §10.2: SELECT * rejected in registered queries
        if (is_registered) {
            for (stmt.items) |item| {
                if (item == .star) return error.SelectStarInRegisteredQuery;
            }
        }

        const ctx = self.makeCtx(params, scope);

        // Check JOIN ON conditions
        for (stmt.joins) |j| {
            if (j.condition) |cond| {
                switch (cond) {
                    .on => |expr| {
                        var join_ctx = ctx;
                        join_ctx.in_join = true;
                        const t = try self.inferExpr(expr, join_ctx);
                        if (!t.eql(.bool)) return error.TypeMismatch;
                    },
                    .using => {},
                }
            }
        }

        if (stmt.where) |w| {
            var where_ctx = ctx;
            where_ctx.in_where = true;
            const t = try self.inferExpr(w, where_ctx);
            if (!t.eql(.bool)) return error.TypeMismatch;
        }

        for (stmt.group_by) |g| {
            _ = try self.inferExpr(g, ctx);
        }

        if (stmt.having) |h| {
            var hctx = ctx;
            hctx.in_having = true;
            const t = try self.inferExpr(h, hctx);
            if (!t.eql(.bool)) return error.TypeMismatch;
        }

        for (stmt.items) |item| {
            switch (item) {
                .star => {},
                .expr => |ei| _ = try self.inferExpr(ei.expr, ctx),
            }
        }
    }

    fn checkInsert(self: *TypeChecker, stmt: ast.InsertStmt, params: []const ast.SqlType) TypeCheckError!void {
        _ = self.schema.getTable(stmt.table) orelse return error.TableNotFound;
        const scope: []const ScopeEntry = &.{};
        const ctx = self.makeCtx(params, scope);
        switch (stmt.source) {
            .values => |rows| {
                for (rows) |row| {
                    for (row) |e| _ = try self.inferExpr(e, ctx);
                }
            },
            .query => |q| try self.checkSelect(q.*, params, false),
        }
    }

    fn checkUpdate(self: *TypeChecker, stmt: ast.UpdateStmt, params: []const ast.SqlType) TypeCheckError!void {
        const tbl = self.schema.getTable(stmt.table) orelse return error.TableNotFound;
        var scope_list: std.ArrayList(ScopeEntry) = .empty;
        defer scope_list.deinit(self.alloc);
        try scope_list.append(self.alloc, .{ .alias = stmt.table, .table = tbl });
        const ctx = self.makeCtx(params, scope_list.items);
        for (stmt.sets) |asgn| {
            _ = try self.inferExpr(asgn.value, ctx);
        }
        if (stmt.where) |w| {
            const t = try self.inferExpr(w, ctx);
            if (!t.eql(.bool)) return error.TypeMismatch;
        }
    }

    fn checkDelete(self: *TypeChecker, stmt: ast.DeleteStmt, params: []const ast.SqlType) TypeCheckError!void {
        const tbl = self.schema.getTable(stmt.table) orelse return error.TableNotFound;
        var scope_list: std.ArrayList(ScopeEntry) = .empty;
        defer scope_list.deinit(self.alloc);
        try scope_list.append(self.alloc, .{ .alias = stmt.table, .table = tbl });
        const ctx = self.makeCtx(params, scope_list.items);
        if (stmt.where) |w| {
            const t = try self.inferExpr(w, ctx);
            if (!t.eql(.bool)) return error.TypeMismatch;
        }
    }

    fn checkMerge(self: *TypeChecker, stmt: ast.MergeStmt, params: []const ast.SqlType) TypeCheckError!void {
        _ = self.schema.getTable(stmt.target.name) orelse return error.TableNotFound;
        const scope: []const ScopeEntry = &.{};
        const ctx = self.makeCtx(params, scope);
        const on_t = try self.inferExpr(stmt.on, ctx);
        if (!on_t.eql(.bool)) return error.TypeMismatch;
        for (stmt.whens) |w| {
            switch (w) {
                .matched => |m| {
                    if (m.cond) |c| _ = try self.inferExpr(c, ctx);
                },
                .not_matched => |nm| {
                    if (nm.cond) |c| _ = try self.inferExpr(c, ctx);
                    for (nm.values) |e| _ = try self.inferExpr(e, ctx);
                },
            }
        }
    }

    // ─── Expression inference ────────────────────────────────────────────

    pub fn inferExpr(self: *TypeChecker, e: *ast.Expr, ctx: CheckContext) TypeCheckError!ast.SqlType {
        return switch (e.*) {
            .lit_int => .{ .int64 = .error_on_overflow }, // widest compatible
            .lit_float => .float64,
            .lit_string => .string,
            .lit_bytes => .bytes,
            .lit_bool => .bool,
            .lit_null => .null_type,

            .param => |idx| {
                // No declared params (non-transaction query): treat as polymorphic
                if (ctx.params.len == 0) return .null_type;
                if (idx >= ctx.params.len) return error.ParamOutOfRange;
                return ctx.params[idx];
            },

            .nondet => |kind| {
                // §10.2: nondeterministic functions rejected in WHERE/HAVING/ON
                if (ctx.in_where or ctx.in_having or ctx.in_join) {
                    return error.SideEffectingFunctionInWhere;
                }
                return switch (kind) {
                    .now => .timestamp,
                    .random => .bytes,
                    .uuid_v7 => .uuid,
                };
            },

            .column_ref => |ref| try self.resolveColumnRef(ref, ctx),

            .cast => |c| {
                _ = try self.inferExpr(c.expr, ctx);
                return c.to;
            },

            .binary => |b| try self.inferBinary(b.op, b.left, b.right, ctx),

            .unary => |u| switch (u.op) {
                .neg => {
                    const t = try self.inferExpr(u.expr, ctx);
                    if (!t.isNumeric()) return error.TypeMismatch;
                    return t;
                },
                .not => {
                    const t = try self.inferExpr(u.expr, ctx);
                    if (!t.eql(.bool)) return error.TypeMismatch;
                    return .bool;
                },
            },

            .is_null, .is_not_null => |inner| {
                _ = try self.inferExpr(inner, ctx);
                return .bool;
            },

            .is_distinct => |pair| {
                _ = try self.inferExpr(pair.left, ctx);
                _ = try self.inferExpr(pair.right, ctx);
                return .bool;
            },
            .is_not_distinct => |pair| {
                _ = try self.inferExpr(pair.left, ctx);
                _ = try self.inferExpr(pair.right, ctx);
                return .bool;
            },

            .between => |b| {
                const et = try self.inferExpr(b.expr, ctx);
                const lt = try self.inferExpr(b.low, ctx);
                const ht = try self.inferExpr(b.high, ctx);
                if (!et.eql(lt) or !et.eql(ht)) return error.TypeMismatch;
                return .bool;
            },

            .like => |l| {
                const et = try self.inferExpr(l.expr, ctx);
                const pt = try self.inferExpr(l.pattern, ctx);
                if (!et.eql(.string) or !pt.eql(.string)) return error.TypeMismatch;
                return .bool;
            },

            .in_list => |il| {
                const et = try self.inferExpr(il.expr, ctx);
                for (il.values) |v| {
                    const vt = try self.inferExpr(v, ctx);
                    if (!vt.eql(.null_type) and !et.eql(vt)) return error.ImplicitTypeCoercion;
                }
                return .bool;
            },
            .not_in_list => |il| {
                const et = try self.inferExpr(il.expr, ctx);
                for (il.values) |v| {
                    const vt = try self.inferExpr(v, ctx);
                    if (!vt.eql(.null_type) and !et.eql(vt)) return error.ImplicitTypeCoercion;
                }
                return .bool;
            },

            .in_subquery, .not_in_subquery => .bool,
            .exists, .not_exists => .bool,

            .case_searched => |c| try self.inferCaseSearched(c.whens, c.else_expr, ctx),
            .case_simple => |c| try self.inferCaseSimple(c.operand, c.whens, c.else_expr, ctx),

            .fn_call => |f| try self.inferFnCall(f, ctx),
            .window_fn => |w| try self.inferFnCall(w.call, ctx),

            .subquery => .null_type, // scalar subquery — type unknown without full plan

            .typed => |t| t.typ,
        };
    }

    fn resolveColumnRef(_: *TypeChecker, ref: ast.ColumnRef, ctx: CheckContext) TypeCheckError!ast.SqlType {
        if (ref.table) |tbl_name| {
            // Qualified reference: find the table in scope
            for (ctx.scope) |entry| {
                if (std.ascii.eqlIgnoreCase(entry.alias, tbl_name)) {
                    const col = entry.table.columnByName(ref.column) orelse return error.ColumnNotFound;
                    // §10.2: = on nullable column without IS guard is caught at binary op level
                    return col.typ;
                }
            }
            return error.TableNotFound;
        }

        // Unqualified: must be unambiguous
        if (ctx.in_join and ctx.scope.len > 1) {
            // §10.2: unqualified column references in joins are an error
            return error.UnqualifiedJoinColumnRef;
        }

        var found_typ: ?ast.SqlType = null;
        for (ctx.scope) |entry| {
            if (entry.table.columnByName(ref.column)) |col| {
                if (found_typ != null) return error.AmbiguousColumnRef;
                found_typ = col.typ;
            }
        }
        return found_typ orelse error.ColumnNotFound;
    }

    fn resolveColumnNullable(_: *TypeChecker, ref: ast.ColumnRef, ctx: CheckContext) ?ast.NullConstraint {
        if (ref.table) |tbl_name| {
            for (ctx.scope) |entry| {
                if (std.ascii.eqlIgnoreCase(entry.alias, tbl_name)) {
                    const col = entry.table.columnByName(ref.column) orelse return null;
                    return col.nullable;
                }
            }
            return null;
        }
        for (ctx.scope) |entry| {
            if (entry.table.columnByName(ref.column)) |col| {
                return col.nullable;
            }
        }
        return null;
    }

    fn inferBinary(
        self: *TypeChecker,
        op: ast.BinOp,
        left: *ast.Expr,
        right: *ast.Expr,
        ctx: CheckContext,
    ) TypeCheckError!ast.SqlType {
        const lt = try self.inferExpr(left, ctx);
        const rt = try self.inferExpr(right, ctx);

        switch (op) {
            .add, .sub, .mul, .div, .mod => {
                if (!lt.isNumeric() or !rt.isNumeric()) return error.TypeMismatch;
                // §10.2: no implicit coercions — both sides must be same type
                if (!lt.eql(rt) and rt != .null_type and lt != .null_type) {
                    return error.ImplicitTypeCoercion;
                }
                return lt;
            },
            .eq, .neq, .lt, .gt, .lte, .gte => {
                // §10.2: = on nullable column is an error unless IS NULL guard used.
                // Exception: JOIN ON conditions — NULL propagation (NULL = x → NULL/false)
                // is correct SQL semantics and correctly excludes non-matching rows.
                if ((op == .eq or op == .neq) and !ctx.in_join) {
                    if (left.* == .column_ref) {
                        if (self.resolveColumnNullable(left.column_ref, ctx)) |nullability| {
                            if (nullability == .nullable) {
                                return error.NullableColumnWithoutGuard;
                            }
                        }
                    }
                    if (right.* == .column_ref) {
                        if (self.resolveColumnNullable(right.column_ref, ctx)) |nullability| {
                            if (nullability == .nullable) {
                                return error.NullableColumnWithoutGuard;
                            }
                        }
                    }
                }
                // Types must match (or one is null_type)
                if (!lt.eql(rt) and lt != .null_type and rt != .null_type) {
                    return error.ImplicitTypeCoercion;
                }
                return .bool;
            },
            .and_op, .or_op => {
                if (!lt.eql(.bool) or !rt.eql(.bool)) return error.TypeMismatch;
                return .bool;
            },
            .concat => {
                if (!lt.eql(.string) or !rt.eql(.string)) return error.TypeMismatch;
                return .string;
            },
            .contains, .contained => {
                // JSON/array containment — return bool
                return .bool;
            },
            .arrow, .darrow => {
                // JSON field access
                if (!lt.eql(.json)) return error.TypeMismatch;
                return if (op == .darrow) .string else .json;
            },
        }
    }

    fn inferCaseSearched(
        self: *TypeChecker,
        whens: []ast.CaseWhen,
        else_expr: ?*ast.Expr,
        ctx: CheckContext,
    ) TypeCheckError!ast.SqlType {
        var result_type: ?ast.SqlType = null;
        for (whens) |w| {
            const ct = try self.inferExpr(w.cond, ctx);
            if (!ct.eql(.bool)) return error.TypeMismatch;
            const rt = try self.inferExpr(w.result, ctx);
            if (result_type == null) {
                result_type = rt;
            } else if (!rt.eql(result_type.?) and rt != .null_type) return error.TypeMismatch;
        }
        if (else_expr) |e| {
            const et = try self.inferExpr(e, ctx);
            if (result_type != null and !et.eql(result_type.?) and et != .null_type) return error.TypeMismatch;
        }
        return result_type orelse .null_type;
    }

    fn inferCaseSimple(
        self: *TypeChecker,
        operand: *ast.Expr,
        whens: []ast.CaseWhen,
        else_expr: ?*ast.Expr,
        ctx: CheckContext,
    ) TypeCheckError!ast.SqlType {
        const ot = try self.inferExpr(operand, ctx);
        var result_type: ?ast.SqlType = null;
        for (whens) |w| {
            const wt = try self.inferExpr(w.cond, ctx);
            if (!wt.eql(ot) and wt != .null_type) return error.TypeMismatch;
            const rt = try self.inferExpr(w.result, ctx);
            if (result_type == null) {
                result_type = rt;
            } else if (!rt.eql(result_type.?) and rt != .null_type) return error.TypeMismatch;
        }
        if (else_expr) |e| {
            const et = try self.inferExpr(e, ctx);
            if (result_type != null and !et.eql(result_type.?) and et != .null_type) return error.TypeMismatch;
        }
        return result_type orelse .null_type;
    }

    fn inferFnCall(self: *TypeChecker, f: ast.FnCall, ctx: CheckContext) TypeCheckError!ast.SqlType {
        // §10.2: side-effecting functions rejected in WHERE/HAVING/ON
        if (ctx.in_where or ctx.in_having or ctx.in_join) {
            if (isSideEffecting(f.name)) return error.SideEffectingFunctionInWhere;
        }
        for (f.args) |a| _ = try self.inferExpr(a, ctx);
        return inferBuiltinReturn(f.name, f.args.len, f.star);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    fn buildScope(self: *TypeChecker, from: ?ast.TableRef, joins: []const ast.Join) TypeCheckError![]const ScopeEntry {
        var scope: std.ArrayList(ScopeEntry) = .empty;
        if (from) |tref| {
            try self.addTableRef(&scope, tref);
        }
        for (joins) |j| {
            try self.addTableRef(&scope, j.table);
        }
        return scope.toOwnedSlice(self.alloc);
    }

    fn addTableRef(self: *TypeChecker, scope: *std.ArrayList(ScopeEntry), tref: ast.TableRef) TypeCheckError!void {
        switch (tref) {
            .named => |n| {
                const tbl = self.schema.getTable(n.name) orelse return error.TableNotFound;
                const alias = n.alias orelse n.name;
                try scope.append(self.alloc, .{ .alias = alias, .table = tbl });
            },
            .cte_ref => |n| {
                // CTEs not in schema registry, skip for now
                _ = n;
            },
            .subquery => {}, // subquery columns not tracked in this simplified impl
        }
    }

    fn makeCtx(self: *TypeChecker, params: []const ast.SqlType, scope: []const ScopeEntry) CheckContext {
        return .{
            .schema = self.schema,
            .params = params,
            .nondet_count = 0,
            .in_join = false,
            .in_where = false,
            .in_having = false,
            .alloc = self.alloc,
            .scope = scope,
        };
    }
};

fn isSideEffecting(name: []const u8) bool {
    // Functions known to have side effects or nondeterministic behavior
    const side_effecting = [_][]const u8{ "random", "now", "uuid", "uuid_generate_v7", "gen_random_uuid", "clock_timestamp" };
    for (side_effecting) |n| {
        if (std.ascii.eqlIgnoreCase(name, n)) return true;
    }
    return false;
}

fn inferBuiltinReturn(name: []const u8, arg_count: usize, star: bool) TypeCheckError!ast.SqlType {
    _ = arg_count;
    if (star or std.ascii.eqlIgnoreCase(name, "count")) return .{ .int64 = .error_on_overflow };
    if (std.ascii.eqlIgnoreCase(name, "sum")) return .{ .int64 = .error_on_overflow };
    if (std.ascii.eqlIgnoreCase(name, "avg")) return .float64;
    if (std.ascii.eqlIgnoreCase(name, "min") or std.ascii.eqlIgnoreCase(name, "max")) return .null_type; // depends on arg
    if (std.ascii.eqlIgnoreCase(name, "coalesce")) return .null_type;
    if (std.ascii.eqlIgnoreCase(name, "nullif")) return .null_type;
    if (std.ascii.eqlIgnoreCase(name, "length") or std.ascii.eqlIgnoreCase(name, "char_length")) return .{ .int64 = .error_on_overflow };
    if (std.ascii.eqlIgnoreCase(name, "lower") or std.ascii.eqlIgnoreCase(name, "upper") or
        std.ascii.eqlIgnoreCase(name, "trim") or std.ascii.eqlIgnoreCase(name, "ltrim") or
        std.ascii.eqlIgnoreCase(name, "rtrim") or std.ascii.eqlIgnoreCase(name, "substr") or
        std.ascii.eqlIgnoreCase(name, "replace") or std.ascii.eqlIgnoreCase(name, "concat")) return .string;
    if (std.ascii.eqlIgnoreCase(name, "row_number") or std.ascii.eqlIgnoreCase(name, "rank") or
        std.ascii.eqlIgnoreCase(name, "dense_rank") or std.ascii.eqlIgnoreCase(name, "ntile")) return .{ .int64 = .error_on_overflow };
    if (std.ascii.eqlIgnoreCase(name, "lag") or std.ascii.eqlIgnoreCase(name, "lead") or
        std.ascii.eqlIgnoreCase(name, "first_value") or std.ascii.eqlIgnoreCase(name, "last_value")) return .null_type;
    if (std.ascii.eqlIgnoreCase(name, "json_extract") or std.ascii.eqlIgnoreCase(name, "json_object") or
        std.ascii.eqlIgnoreCase(name, "json_array")) return .json;
    // Unknown function — allowed (could be a user WASM function)
    return .null_type;
}
