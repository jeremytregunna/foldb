/// Tests for executor expression evaluation: builtins, hash_agg, single_row source.
/// Uses synthetic ExecutionPlans (no real data needed for expression-only tests).
const std = @import("std");
const sql = @import("sql.zig");
const plan_mod     = sql.plan;
const schema_mod   = sql.schema;
const registry_mod = sql.registry;
const eb           = sql.executor_bridge;

const ColumnValue   = eb.ColumnValue;
const Storage       = eb.Storage;
const ResolvedValue = eb.ResolvedValue;

// ─── Test helpers ─────────────────────────────────────────────────────────────

fn makeTempPath(alloc: std.mem.Allocator) ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(alloc, "/tmp/sql_expr_{d}", .{ns});
}

fn makeExec(storage: *Storage, sr: *schema_mod.SchemaRegistry, reg: *registry_mod.SqlRegistry, alloc: std.mem.Allocator) eb.SqlExecutor {
    return eb.SqlExecutor.init(storage, reg, sr, alloc);
}

fn makeIntLit(alloc: std.mem.Allocator, n: i64) !*plan_mod.PlanExpr {
    const pe = try alloc.create(plan_mod.PlanExpr);
    pe.* = .{ .int_literal = n };
    return pe;
}

fn makeStrLit(alloc: std.mem.Allocator, s: []const u8) !*plan_mod.PlanExpr {
    const pe = try alloc.create(plan_mod.PlanExpr);
    pe.* = .{ .string_literal = s };
    return pe;
}

fn makeNullLit(alloc: std.mem.Allocator) !*plan_mod.PlanExpr {
    const pe = try alloc.create(plan_mod.PlanExpr);
    pe.* = .null_literal;
    return pe;
}

fn makeFnCall(alloc: std.mem.Allocator, name: []const u8, args: []*plan_mod.PlanExpr) !*plan_mod.PlanExpr {
    const pe = try alloc.create(plan_mod.PlanExpr);
    pe.* = .{ .fn_call = .{ .name = name, .args = args } };
    return pe;
}

fn makeSelectPlan(alloc: std.mem.Allocator, exprs: []*plan_mod.PlanExpr) !plan_mod.ExecutionPlan {
    const single = try alloc.create(plan_mod.PlanNode);
    single.* = .single_row;

    const proj_items = try alloc.alloc(plan_mod.ProjectItem, exprs.len);
    for (exprs, 0..) |e, i| proj_items[i] = .{ .expr = e, .alias = "" };

    const proj = try alloc.create(plan_mod.PlanNode);
    proj.* = .{ .project = .{ .input = single, .exprs = proj_items } };

    const stmt = try alloc.dupe(plan_mod.StmtPlan, &.{.{ .select = proj }});
    return .{ .stmts = stmt, .param_types = &.{}, .nondet_count = 0 };
}

fn evalExpr(exec: *eb.SqlExecutor, expr: *plan_mod.PlanExpr, alloc: std.mem.Allocator) !?ColumnValue {
    const exprs = try alloc.dupe(*plan_mod.PlanExpr, &.{expr});
    const ep = try makeSelectPlan(alloc, exprs);
    var rows = try exec.querySelect(ep, &.{}, &.{}, 1, alloc);
    defer { for (rows.items) |r| alloc.free(r); rows.deinit(alloc); }
    if (rows.items.len == 0) return null;
    return rows.items[0][0];
}

// ─── Builtin: LOWER / UPPER ───────────────────────────────────────────────────

test "lower converts to lowercase" {
    const alloc = std.testing.allocator;
    const tmp = try makeTempPath(alloc);
    defer alloc.free(tmp);
    var storage = try Storage.init(tmp, alloc);
    defer storage.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = makeExec(&storage, &sr, &reg, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const arg = try makeStrLit(a, "HELLO");
    const args = try a.dupe(*plan_mod.PlanExpr, &.{arg});
    const fn_e = try makeFnCall(a, "lower", args);

    const result = try evalExpr(&exec, fn_e, a);
    try std.testing.expectEqualStrings("hello", result.?.string);
}

test "upper converts to uppercase" {
    const alloc = std.testing.allocator;
    const tmp = try makeTempPath(alloc);
    defer alloc.free(tmp);
    var storage = try Storage.init(tmp, alloc);
    defer storage.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = makeExec(&storage, &sr, &reg, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const arg = try makeStrLit(a, "world");
    const args = try a.dupe(*plan_mod.PlanExpr, &.{arg});
    const fn_e = try makeFnCall(a, "upper", args);

    const result = try evalExpr(&exec, fn_e, a);
    try std.testing.expectEqualStrings("WORLD", result.?.string);
}

// ─── Builtin: TRIM ────────────────────────────────────────────────────────────

test "trim removes surrounding whitespace" {
    const alloc = std.testing.allocator;
    const tmp = try makeTempPath(alloc);
    defer alloc.free(tmp);
    var storage = try Storage.init(tmp, alloc);
    defer storage.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = makeExec(&storage, &sr, &reg, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const arg = try makeStrLit(a, "  hello  ");
    const args = try a.dupe(*plan_mod.PlanExpr, &.{arg});
    const fn_e = try makeFnCall(a, "trim", args);

    const result = try evalExpr(&exec, fn_e, a);
    try std.testing.expectEqualStrings("hello", result.?.string);
}

// ─── Builtin: SUBSTR ─────────────────────────────────────────────────────────

test "substr with start and length" {
    const alloc = std.testing.allocator;
    const tmp = try makeTempPath(alloc);
    defer alloc.free(tmp);
    var storage = try Storage.init(tmp, alloc);
    defer storage.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = makeExec(&storage, &sr, &reg, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const str_arg   = try makeStrLit(a, "hello world");
    const start_arg = try makeIntLit(a, 1); // 1-based
    const len_arg   = try makeIntLit(a, 5);
    const args = try a.dupe(*plan_mod.PlanExpr, &.{ str_arg, start_arg, len_arg });
    const fn_e = try makeFnCall(a, "substr", args);

    const result = try evalExpr(&exec, fn_e, a);
    try std.testing.expectEqualStrings("hello", result.?.string);
}

test "substr from middle" {
    const alloc = std.testing.allocator;
    const tmp = try makeTempPath(alloc);
    defer alloc.free(tmp);
    var storage = try Storage.init(tmp, alloc);
    defer storage.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = makeExec(&storage, &sr, &reg, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const str_arg   = try makeStrLit(a, "hello world");
    const start_arg = try makeIntLit(a, 7); // 1-based → position 6
    const args = try a.dupe(*plan_mod.PlanExpr, &.{ str_arg, start_arg });
    const fn_e = try makeFnCall(a, "substr", args);

    const result = try evalExpr(&exec, fn_e, a);
    try std.testing.expectEqualStrings("world", result.?.string);
}

// ─── Builtin: REPLACE ────────────────────────────────────────────────────────

test "replace substitutes all occurrences" {
    const alloc = std.testing.allocator;
    const tmp = try makeTempPath(alloc);
    defer alloc.free(tmp);
    var storage = try Storage.init(tmp, alloc);
    defer storage.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = makeExec(&storage, &sr, &reg, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const s  = try makeStrLit(a, "foo bar foo");
    const fr = try makeStrLit(a, "foo");
    const to = try makeStrLit(a, "baz");
    const args = try a.dupe(*plan_mod.PlanExpr, &.{ s, fr, to });
    const fn_e = try makeFnCall(a, "replace", args);

    const result = try evalExpr(&exec, fn_e, a);
    try std.testing.expectEqualStrings("baz bar baz", result.?.string);
}

// ─── Builtin: NULLIF ─────────────────────────────────────────────────────────

test "nullif returns null when values equal" {
    const alloc = std.testing.allocator;
    const tmp = try makeTempPath(alloc);
    defer alloc.free(tmp);
    var storage = try Storage.init(tmp, alloc);
    defer storage.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = makeExec(&storage, &sr, &reg, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ae = try makeIntLit(a, 5);
    const be = try makeIntLit(a, 5);
    const args = try a.dupe(*plan_mod.PlanExpr, &.{ ae, be });
    const fn_e = try makeFnCall(a, "nullif", args);

    const result = try evalExpr(&exec, fn_e, a);
    try std.testing.expect(result == null);
}

test "nullif returns value when different" {
    const alloc = std.testing.allocator;
    const tmp = try makeTempPath(alloc);
    defer alloc.free(tmp);
    var storage = try Storage.init(tmp, alloc);
    defer storage.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = makeExec(&storage, &sr, &reg, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ae = try makeIntLit(a, 5);
    const be = try makeIntLit(a, 6);
    const args = try a.dupe(*plan_mod.PlanExpr, &.{ ae, be });
    const fn_e = try makeFnCall(a, "nullif", args);

    const result = try evalExpr(&exec, fn_e, a);
    try std.testing.expectEqual(@as(i64, 5), result.?.int64);
}

// ─── Builtin: GREATEST / LEAST ───────────────────────────────────────────────

test "greatest returns max value" {
    const alloc = std.testing.allocator;
    const tmp = try makeTempPath(alloc);
    defer alloc.free(tmp);
    var storage = try Storage.init(tmp, alloc);
    defer storage.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = makeExec(&storage, &sr, &reg, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const e1 = try makeIntLit(a, 3);
    const e2 = try makeIntLit(a, 7);
    const e3 = try makeIntLit(a, 2);
    const args = try a.dupe(*plan_mod.PlanExpr, &.{ e1, e2, e3 });
    const fn_e = try makeFnCall(a, "greatest", args);

    const result = try evalExpr(&exec, fn_e, a);
    try std.testing.expectEqual(@as(i64, 7), result.?.int64);
}

test "least returns min value" {
    const alloc = std.testing.allocator;
    const tmp = try makeTempPath(alloc);
    defer alloc.free(tmp);
    var storage = try Storage.init(tmp, alloc);
    defer storage.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = makeExec(&storage, &sr, &reg, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const e1 = try makeIntLit(a, 3);
    const e2 = try makeIntLit(a, 7);
    const e3 = try makeIntLit(a, 2);
    const args = try a.dupe(*plan_mod.PlanExpr, &.{ e1, e2, e3 });
    const fn_e = try makeFnCall(a, "least", args);

    const result = try evalExpr(&exec, fn_e, a);
    try std.testing.expectEqual(@as(i64, 2), result.?.int64);
}

// ─── Builtin: COALESCE ───────────────────────────────────────────────────────

test "coalesce returns first non-null" {
    const alloc = std.testing.allocator;
    const tmp = try makeTempPath(alloc);
    defer alloc.free(tmp);
    var storage = try Storage.init(tmp, alloc);
    defer storage.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = makeExec(&storage, &sr, &reg, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const null_e = try makeNullLit(a);
    const val_e  = try makeIntLit(a, 42);
    const args = try a.dupe(*plan_mod.PlanExpr, &.{ null_e, val_e });
    const fn_e = try makeFnCall(a, "coalesce", args);

    const result = try evalExpr(&exec, fn_e, a);
    try std.testing.expectEqual(@as(i64, 42), result.?.int64);
}

test "coalesce returns null when all null" {
    const alloc = std.testing.allocator;
    const tmp = try makeTempPath(alloc);
    defer alloc.free(tmp);
    var storage = try Storage.init(tmp, alloc);
    defer storage.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = makeExec(&storage, &sr, &reg, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const n1 = try makeNullLit(a);
    const n2 = try makeNullLit(a);
    const args = try a.dupe(*plan_mod.PlanExpr, &.{ n1, n2 });
    const fn_e = try makeFnCall(a, "coalesce", args);

    const result = try evalExpr(&exec, fn_e, a);
    try std.testing.expect(result == null);
}

// ─── Builtin: LENGTH ─────────────────────────────────────────────────────────

test "length returns character count" {
    const alloc = std.testing.allocator;
    const tmp = try makeTempPath(alloc);
    defer alloc.free(tmp);
    var storage = try Storage.init(tmp, alloc);
    defer storage.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = makeExec(&storage, &sr, &reg, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const arg = try makeStrLit(a, "hello");
    const args = try a.dupe(*plan_mod.PlanExpr, &.{arg});
    const fn_e = try makeFnCall(a, "length", args);

    const result = try evalExpr(&exec, fn_e, a);
    try std.testing.expectEqual(@as(i64, 5), result.?.int64);
}

// ─── Literal arithmetic ───────────────────────────────────────────────────────

test "binary add two integers" {
    const alloc = std.testing.allocator;
    const tmp = try makeTempPath(alloc);
    defer alloc.free(tmp);
    var storage = try Storage.init(tmp, alloc);
    defer storage.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = makeExec(&storage, &sr, &reg, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const left  = try makeIntLit(a, 10);
    const right = try makeIntLit(a, 32);
    const add   = try a.create(plan_mod.PlanExpr);
    add.* = .{ .binary = .{ .op = .add, .left = left, .right = right } };

    const result = try evalExpr(&exec, add, a);
    try std.testing.expectEqual(@as(i64, 42), result.?.int64);
}

test "CASE WHEN false THEN x ELSE y returns y" {
    const alloc = std.testing.allocator;
    const tmp = try makeTempPath(alloc);
    defer alloc.free(tmp);
    var storage = try Storage.init(tmp, alloc);
    defer storage.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = makeExec(&storage, &sr, &reg, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const cond = try a.create(plan_mod.PlanExpr);
    cond.* = .{ .bool_literal = false };
    const yes = try makeStrLit(a, "yes");
    const no  = try makeStrLit(a, "no");
    const whens = try a.dupe(plan_mod.PlanCaseWhen, &.{.{ .cond = cond, .result = yes }});
    const case_pe = try a.create(plan_mod.PlanExpr);
    case_pe.* = .{ .case_searched = .{ .whens = whens, .else_expr = no } };

    const result = try evalExpr(&exec, case_pe, a);
    try std.testing.expectEqualStrings("no", result.?.string);
}

// ─── hash_agg: COUNT on empty returns 0 ─────────────────────────────────────

test "hash_agg COUNT star on empty returns 0" {
    const alloc = std.testing.allocator;
    const tmp = try makeTempPath(alloc);
    defer alloc.free(tmp);
    var storage = try Storage.init(tmp, alloc);
    defer storage.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = makeExec(&storage, &sr, &reg, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const empty_node = try a.create(plan_mod.PlanNode);
    empty_node.* = .empty;

    const agg_exprs = try a.dupe(plan_mod.AggExpr, &.{.{
        .fn_name  = "count",
        .arg      = null,
        .distinct = false,
        .alias    = "cnt",
    }});
    const agg_node = try a.create(plan_mod.PlanNode);
    agg_node.* = .{ .hash_agg = .{
        .input      = empty_node,
        .group_keys = &.{},
        .agg_exprs  = agg_exprs,
    }};

    // Project column 0 (the count result)
    const col_pe = try a.create(plan_mod.PlanExpr);
    col_pe.* = .{ .column = 0 };
    const proj_items = try a.dupe(plan_mod.ProjectItem, &.{.{ .expr = col_pe, .alias = "cnt" }});
    const proj_node = try a.create(plan_mod.PlanNode);
    proj_node.* = .{ .project = .{ .input = agg_node, .exprs = proj_items } };

    const stmt = try a.dupe(plan_mod.StmtPlan, &.{.{ .select = proj_node }});
    const ep = plan_mod.ExecutionPlan{ .stmts = stmt, .param_types = &.{}, .nondet_count = 0 };

    var rows = try exec.querySelect(ep, &.{}, &.{}, 1, a);
    defer { for (rows.items) |r| a.free(r); rows.deinit(a); }

    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqual(@as(i64, 0), rows.items[0][0].?.int64);
}

// ─── hash_join: inner join ────────────────────────────────────────────────────

test "hash_join inner join matching rows" {
    // Build two inline row sources using single_row + project (simulating a table with one row)
    const alloc = std.testing.allocator;
    const tmp = try makeTempPath(alloc);
    defer alloc.free(tmp);
    var storage = try Storage.init(tmp, alloc);
    defer storage.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = makeExec(&storage, &sr, &reg, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Left side: single row with value 42 (column 0)
    const left_single = try a.create(plan_mod.PlanNode);
    left_single.* = .single_row;
    const left_val = try makeIntLit(a, 42);
    const left_items = try a.dupe(plan_mod.ProjectItem, &.{.{ .expr = left_val, .alias = "k" }});
    const left_proj = try a.create(plan_mod.PlanNode);
    left_proj.* = .{ .project = .{ .input = left_single, .exprs = left_items } };

    // Right side: single row with value 42 (column 0)
    const right_single = try a.create(plan_mod.PlanNode);
    right_single.* = .single_row;
    const right_val = try makeIntLit(a, 42);
    const right_items = try a.dupe(plan_mod.ProjectItem, &.{.{ .expr = right_val, .alias = "k" }});
    const right_proj = try a.create(plan_mod.PlanNode);
    right_proj.* = .{ .project = .{ .input = right_single, .exprs = right_items } };

    // Join condition: left.column[0] = right.column[1] (combined row: left=0, right=1)
    const left_col = try a.create(plan_mod.PlanExpr);
    left_col.* = .{ .column = 0 };
    const right_col = try a.create(plan_mod.PlanExpr);
    right_col.* = .{ .column = 1 };
    const cond = try a.create(plan_mod.PlanExpr);
    cond.* = .{ .binary = .{ .op = .eq, .left = left_col, .right = right_col } };

    const join_node = try a.create(plan_mod.PlanNode);
    join_node.* = .{ .hash_join = .{
        .left      = left_proj,
        .right     = right_proj,
        .kind      = .inner,
        .condition = cond,
    }};

    const stmt = try a.dupe(plan_mod.StmtPlan, &.{.{ .select = join_node }});
    const ep = plan_mod.ExecutionPlan{ .stmts = stmt, .param_types = &.{}, .nondet_count = 0 };

    var rows = try exec.querySelect(ep, &.{}, &.{}, 1, a);
    defer { for (rows.items) |r| a.free(r); rows.deinit(a); }

    // One matching row: combined = [42, 42]
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqual(@as(usize, 2), rows.items[0].len);
    try std.testing.expectEqual(@as(i64, 42), rows.items[0][0].?.int64);
    try std.testing.expectEqual(@as(i64, 42), rows.items[0][1].?.int64);
}

test "hash_join inner join no match yields empty result" {
    const alloc = std.testing.allocator;
    const tmp = try makeTempPath(alloc);
    defer alloc.free(tmp);
    var storage = try Storage.init(tmp, alloc);
    defer storage.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = makeExec(&storage, &sr, &reg, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Left: row [1], Right: row [2] — no match on equality
    const left_node = try a.create(plan_mod.PlanNode);
    left_node.* = .single_row;
    const left_val = try makeIntLit(a, 1);
    const left_items = try a.dupe(plan_mod.ProjectItem, &.{.{ .expr = left_val, .alias = "" }});
    const left_proj = try a.create(plan_mod.PlanNode);
    left_proj.* = .{ .project = .{ .input = left_node, .exprs = left_items } };

    const right_node = try a.create(plan_mod.PlanNode);
    right_node.* = .single_row;
    const right_val = try makeIntLit(a, 2);
    const right_items = try a.dupe(plan_mod.ProjectItem, &.{.{ .expr = right_val, .alias = "" }});
    const right_proj = try a.create(plan_mod.PlanNode);
    right_proj.* = .{ .project = .{ .input = right_node, .exprs = right_items } };

    const lc = try a.create(plan_mod.PlanExpr); lc.* = .{ .column = 0 };
    const rc = try a.create(plan_mod.PlanExpr); rc.* = .{ .column = 1 };
    const cond = try a.create(plan_mod.PlanExpr);
    cond.* = .{ .binary = .{ .op = .eq, .left = lc, .right = rc } };

    const join_node = try a.create(plan_mod.PlanNode);
    join_node.* = .{ .hash_join = .{ .left = left_proj, .right = right_proj, .kind = .inner, .condition = cond } };

    const stmt = try a.dupe(plan_mod.StmtPlan, &.{.{ .select = join_node }});
    const ep = plan_mod.ExecutionPlan{ .stmts = stmt, .param_types = &.{}, .nondet_count = 0 };

    var rows = try exec.querySelect(ep, &.{}, &.{}, 1, a);
    defer { for (rows.items) |r| a.free(r); rows.deinit(a); }

    try std.testing.expectEqual(@as(usize, 0), rows.items.len);
}
