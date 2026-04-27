/// Tests for decimal type: literal parsing, arithmetic, comparison, and storage codec.
const std = @import("std");
const testing = std.testing;
const sql = @import("sql.zig");
const storage_mod = @import("storage.zig");

const plan_mod = sql.plan;
const eb = sql.executor_bridge;
const parser_mod = sql.parser;
const ast_mod = sql.ast;
const schema_mod = sql.schema;
const registry_mod = sql.registry;

const ColumnValue = eb.ColumnValue;
const Storage = eb.Storage;

// ─── Helpers ──────────────────────────────────────────────────────────────────

fn makeTempPath(alloc: std.mem.Allocator) ![]const u8 {
    // SAFETY: clock_gettime fills ts before any field is read.
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(alloc, "/tmp/decimal_test_{d}", .{ns});
}

fn makeDecLit(alloc: std.mem.Allocator, coeff: i128, scale: u8) !*plan_mod.PlanExpr {
    const pe = try alloc.create(plan_mod.PlanExpr);
    pe.* = .{ .decimal_literal = .{ .coefficient = coeff, .scale = scale } };
    return pe;
}

fn makeIntLit(alloc: std.mem.Allocator, n: i64) !*plan_mod.PlanExpr {
    const pe = try alloc.create(plan_mod.PlanExpr);
    pe.* = .{ .int_literal = n };
    return pe;
}

fn makeBinary(alloc: std.mem.Allocator, op: ast_mod.BinOp, l: *plan_mod.PlanExpr, r: *plan_mod.PlanExpr) !*plan_mod.PlanExpr {
    const pe = try alloc.create(plan_mod.PlanExpr);
    pe.* = .{ .binary = .{ .op = op, .left = l, .right = r } };
    return pe;
}

fn makeUnary(alloc: std.mem.Allocator, op: ast_mod.UnaryOp, expr: *plan_mod.PlanExpr) !*plan_mod.PlanExpr {
    const pe = try alloc.create(plan_mod.PlanExpr);
    pe.* = .{ .unary = .{ .op = op, .expr = expr } };
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
    defer {
        for (rows.items) |r| alloc.free(r);
        rows.deinit(alloc);
    }
    if (rows.items.len == 0 or rows.items[0][0] == null) return null;
    return rows.items[0][0];
}

fn evalDecimal(exec: *eb.SqlExecutor, expr: *plan_mod.PlanExpr, alloc: std.mem.Allocator) !f64 {
    const cv = (try evalExpr(exec, expr, alloc)) orelse return error.NullResult;
    if (cv != .decimal) return error.NotDecimal;
    return @as(f64, @floatFromInt(cv.decimal.coefficient)) /
        std.math.pow(f64, 10.0, @floatFromInt(cv.decimal.scale));
}

// ─── Literal parsing ──────────────────────────────────────────────────────────

test "decimal literal: 3.14 parses to exact coefficient" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const q = try parser_mod.parse("SELECT 3.14", arena.allocator());
    const d = q.stmts[0].select.items[0].expr.expr.lit_float;
    try testing.expectEqual(@as(i128, 314), d.coefficient);
    try testing.expectEqual(@as(u8, 2), d.scale);
}

test "decimal literal: 100.0 retains trailing zero in scale" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const q = try parser_mod.parse("SELECT 100.0", arena.allocator());
    const d = q.stmts[0].select.items[0].expr.expr.lit_float;
    try testing.expectEqual(@as(i128, 1000), d.coefficient);
    try testing.expectEqual(@as(u8, 1), d.scale);
}

test "decimal literal: 0.001 has scale 3" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const q = try parser_mod.parse("SELECT 0.001", arena.allocator());
    const d = q.stmts[0].select.items[0].expr.expr.lit_float;
    try testing.expectEqual(@as(i128, 1), d.coefficient);
    try testing.expectEqual(@as(u8, 3), d.scale);
}

// ─── Type alias parsing ───────────────────────────────────────────────────────

test "float type alias maps to decimal(38,10)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const q = try parser_mod.parse("CREATE TABLE t (x float NOT NULL, PRIMARY KEY (x))", arena.allocator());
    const col_typ = q.stmts[0].create_table.columns[0].typ;
    try testing.expect(col_typ == .decimal);
    try testing.expectEqual(@as(u8, 38), col_typ.decimal.precision);
    try testing.expectEqual(@as(u8, 10), col_typ.decimal.scale);
}

test "float32 type alias maps to decimal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const q = try parser_mod.parse("CREATE TABLE t (x float32 NOT NULL, PRIMARY KEY (x))", arena.allocator());
    try testing.expect(q.stmts[0].create_table.columns[0].typ == .decimal);
}

test "double type alias maps to decimal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const q = try parser_mod.parse("CREATE TABLE t (x double NOT NULL, PRIMARY KEY (x))", arena.allocator());
    try testing.expect(q.stmts[0].create_table.columns[0].typ == .decimal);
}

test "real type alias maps to decimal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const q = try parser_mod.parse("CREATE TABLE t (x real NOT NULL, PRIMARY KEY (x))", arena.allocator());
    try testing.expect(q.stmts[0].create_table.columns[0].typ == .decimal);
}

// ─── plan.Value decimal comparison ───────────────────────────────────────────

test "decimal eql: same scale" {
    const a: plan_mod.Value = .{ .decimal_val = .{ .coefficient = 314, .scale = 2 } };
    const b: plan_mod.Value = .{ .decimal_val = .{ .coefficient = 314, .scale = 2 } };
    try testing.expect(a.eql(b));
}

test "decimal eql: different scales same value" {
    // 3.14 == 3.140
    const a: plan_mod.Value = .{ .decimal_val = .{ .coefficient = 314, .scale = 2 } };
    const b: plan_mod.Value = .{ .decimal_val = .{ .coefficient = 3140, .scale = 3 } };
    try testing.expect(a.eql(b));
}

test "decimal lessThan: 1.5 < 2.5" {
    const a: plan_mod.Value = .{ .decimal_val = .{ .coefficient = 15, .scale = 1 } };
    const b: plan_mod.Value = .{ .decimal_val = .{ .coefficient = 25, .scale = 1 } };
    try testing.expect(a.lessThan(b));
    try testing.expect(!b.lessThan(a));
}

test "decimal lessThan: negative < positive" {
    const neg: plan_mod.Value = .{ .decimal_val = .{ .coefficient = -1, .scale = 0 } };
    const pos: plan_mod.Value = .{ .decimal_val = .{ .coefficient = 1, .scale = 0 } };
    try testing.expect(neg.lessThan(pos));
    try testing.expect(!pos.lessThan(neg));
}

test "decimal lessThan: cross-scale equal values are not less" {
    // 1.5 vs 1.50
    const a: plan_mod.Value = .{ .decimal_val = .{ .coefficient = 15, .scale = 1 } };
    const b: plan_mod.Value = .{ .decimal_val = .{ .coefficient = 150, .scale = 2 } };
    try testing.expect(!a.lessThan(b));
    try testing.expect(!b.lessThan(a));
}

// ─── Arithmetic via executor ──────────────────────────────────────────────────

test "decimal add: 1.5 + 2.5 = 4.0" {
    const alloc = testing.allocator;
    const path = try makeTempPath(alloc);
    defer alloc.free(path);
    var store = try Storage.init(path, alloc);
    defer store.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = eb.SqlExecutor.init(&store, &reg, &sr, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const expr = try makeBinary(a, .add, try makeDecLit(a, 15, 1), try makeDecLit(a, 25, 1));
    try testing.expectApproxEqAbs(@as(f64, 4.0), try evalDecimal(&exec, expr, a), 1e-9);
}

test "decimal sub: 3.0 - 1.5 = 1.5" {
    const alloc = testing.allocator;
    const path = try makeTempPath(alloc);
    defer alloc.free(path);
    var store = try Storage.init(path, alloc);
    defer store.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = eb.SqlExecutor.init(&store, &reg, &sr, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const expr = try makeBinary(a, .sub, try makeDecLit(a, 30, 1), try makeDecLit(a, 15, 1));
    try testing.expectApproxEqAbs(@as(f64, 1.5), try evalDecimal(&exec, expr, a), 1e-9);
}

test "decimal mul: 2.5 * 4.0 = 10.0" {
    const alloc = testing.allocator;
    const path = try makeTempPath(alloc);
    defer alloc.free(path);
    var store = try Storage.init(path, alloc);
    defer store.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = eb.SqlExecutor.init(&store, &reg, &sr, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const expr = try makeBinary(a, .mul, try makeDecLit(a, 25, 1), try makeDecLit(a, 40, 1));
    try testing.expectApproxEqAbs(@as(f64, 10.0), try evalDecimal(&exec, expr, a), 1e-9);
}

test "decimal div: 5.0 / 2.0 = 2.5" {
    const alloc = testing.allocator;
    const path = try makeTempPath(alloc);
    defer alloc.free(path);
    var store = try Storage.init(path, alloc);
    defer store.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = eb.SqlExecutor.init(&store, &reg, &sr, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const expr = try makeBinary(a, .div, try makeDecLit(a, 50, 1), try makeDecLit(a, 20, 1));
    try testing.expectApproxEqAbs(@as(f64, 2.5), try evalDecimal(&exec, expr, a), 1e-9);
}

test "decimal div: 1.0 / 3.0 has at least 9 correct decimal places" {
    const alloc = testing.allocator;
    const path = try makeTempPath(alloc);
    defer alloc.free(path);
    var store = try Storage.init(path, alloc);
    defer store.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = eb.SqlExecutor.init(&store, &reg, &sr, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const expr = try makeBinary(a, .div, try makeDecLit(a, 10, 1), try makeDecLit(a, 30, 1));
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), try evalDecimal(&exec, expr, a), 1e-9);
}

test "decimal div by zero returns error" {
    const alloc = testing.allocator;
    const path = try makeTempPath(alloc);
    defer alloc.free(path);
    var store = try Storage.init(path, alloc);
    defer store.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = eb.SqlExecutor.init(&store, &reg, &sr, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const expr = try makeBinary(a, .div, try makeDecLit(a, 10, 0), try makeDecLit(a, 0, 0));
    try testing.expectError(error.DivisionByZero, evalExpr(&exec, expr, a));
}

test "decimal negation: -3.14" {
    const alloc = testing.allocator;
    const path = try makeTempPath(alloc);
    defer alloc.free(path);
    var store = try Storage.init(path, alloc);
    defer store.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = eb.SqlExecutor.init(&store, &reg, &sr, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const expr = try makeUnary(a, .neg, try makeDecLit(a, 314, 2));
    const cv = (try evalExpr(&exec, expr, a)).?;
    try testing.expect(cv == .decimal);
    try testing.expectEqual(@as(i128, -314), cv.decimal.coefficient);
    try testing.expectEqual(@as(u8, 2), cv.decimal.scale);
}

test "decimal + int promotion: 1.5 + 2 = 3.5" {
    const alloc = testing.allocator;
    const path = try makeTempPath(alloc);
    defer alloc.free(path);
    var store = try Storage.init(path, alloc);
    defer store.deinit();
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    var exec = eb.SqlExecutor.init(&store, &reg, &sr, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const expr = try makeBinary(a, .add, try makeDecLit(a, 15, 1), try makeIntLit(a, 2));
    try testing.expectApproxEqAbs(@as(f64, 3.5), try evalDecimal(&exec, expr, a), 1e-9);
}

// ─── Storage codec round-trip ─────────────────────────────────────────────────

test "decimal storage codec round-trip" {
    const alloc = testing.allocator;
    const vals = [_]storage_mod.ColumnValue{
        .{ .decimal = .{ .coefficient = 314159, .scale = 5 } },
        .{ .decimal = .{ .coefficient = -100, .scale = 2 } },
        .{ .decimal = .{ .coefficient = 0, .scale = 0 } },
        .{ .decimal = .{ .coefficient = 999999999999999999, .scale = 10 } },
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    const codec_id = storage_mod.chooseCodec(.decimal, &vals);
    try storage_mod.encodeCol(codec_id, .decimal, &vals, &buf, alloc);

    const out = try alloc.alloc(storage_mod.ColumnValue, vals.len);
    defer alloc.free(out);
    try storage_mod.decodeCol(codec_id, .decimal, buf.items, @intCast(vals.len), out, alloc);

    for (vals, out) |expected, actual| {
        try testing.expect(expected.eql(actual));
    }
}
