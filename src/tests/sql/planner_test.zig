/// Tests for the query planner — verifies correct plan node generation.
const std = @import("std");
const sql = @import("sql.zig");
const schema_mod = sql.schema;
const ast_mod = sql.ast;
const plan_mod = sql.plan;
const parser_mod = sql.parser;

const zero_span: ast_mod.Span = .{ .start = 0, .end = 0 };

fn makeSchema(alloc: std.mem.Allocator) !schema_mod.SchemaRegistry {
    var sr = schema_mod.SchemaRegistry.init(alloc);
    _ = try sr.createTable(.{
        .name = "users",
        .columns = &[_]ast_mod.ColumnDef{
            .{ .name = "id", .typ = .{ .int64 = .error_on_overflow }, .nullable = .not_null, .span = zero_span },
            .{ .name = "name", .typ = .string, .nullable = .not_null, .span = zero_span },
            .{ .name = "score", .typ = .float64, .nullable = .nullable, .span = zero_span },
        },
        .primary_key = .{ .columns = &.{"id"} },
    });
    _ = try sr.createTable(.{
        .name = "orders",
        .columns = &[_]ast_mod.ColumnDef{
            .{ .name = "id", .typ = .{ .int64 = .error_on_overflow }, .nullable = .not_null, .span = zero_span },
            .{ .name = "user_id", .typ = .{ .int64 = .error_on_overflow }, .nullable = .not_null, .span = zero_span },
            .{ .name = "amount", .typ = .float64, .nullable = .not_null, .span = zero_span },
        },
        .primary_key = .{ .columns = &.{"id"} },
    });
    return sr;
}

fn plan(sr: *schema_mod.SchemaRegistry, sql_text: []const u8, alloc: std.mem.Allocator) !plan_mod.ExecutionPlan {
    var arena = std.heap.ArenaAllocator.init(alloc);
    const arena_alloc = arena.allocator();
    const parsed = try parser_mod.parse(sql_text, arena_alloc);
    var planner = plan_mod.Planner.init(arena_alloc, sr);
    return planner.planStmt(parsed.stmts[0], &.{});
}

// ─── Column ref resolution ────────────────────────────────────────────────────

test "column ref in WHERE resolves to .column index" {
    const alloc = std.testing.allocator;
    var sr = try makeSchema(alloc);
    defer sr.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try parser_mod.parse(
        "SELECT id FROM users WHERE id = $1",
        arena_alloc,
    );
    var planner = plan_mod.Planner.init(arena_alloc, &sr);
    const ep = try planner.planStmt(parsed.stmts[0], &.{});

    // Plan: project → filter → scan
    const select_node = ep.stmts[0].select;
    try std.testing.expect(select_node.* == .project);

    const filter_node = select_node.project.input;
    try std.testing.expect(filter_node.* == .filter);

    // Filter predicate: id = $1 → binary(.eq, .column{0}, .param{0})
    const pred = filter_node.filter.predicate;
    try std.testing.expect(pred.* == .binary);
    try std.testing.expect(pred.binary.left.* == .column);
    try std.testing.expectEqual(@as(u32, 0), pred.binary.left.column); // id is at position 0

    // Project: SELECT id → .column{0}
    const proj = select_node.project;
    try std.testing.expectEqual(@as(usize, 1), proj.exprs.len);
    try std.testing.expect(proj.exprs[0].expr.* == .column);
    try std.testing.expectEqual(@as(u32, 0), proj.exprs[0].expr.column);
}

test "column ref SELECT name resolves to position 1" {
    const alloc = std.testing.allocator;
    var sr = try makeSchema(alloc);
    defer sr.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try parser_mod.parse(
        "SELECT id, name, score FROM users",
        arena_alloc,
    );
    var planner = plan_mod.Planner.init(arena_alloc, &sr);
    const ep = try planner.planStmt(parsed.stmts[0], &.{});

    const select_node = ep.stmts[0].select;
    try std.testing.expect(select_node.* == .project);
    const proj = select_node.project;
    try std.testing.expectEqual(@as(usize, 3), proj.exprs.len);

    // id=0, name=1, score=2
    try std.testing.expect(proj.exprs[0].expr.* == .column);
    try std.testing.expectEqual(@as(u32, 0), proj.exprs[0].expr.column);
    try std.testing.expect(proj.exprs[1].expr.* == .column);
    try std.testing.expectEqual(@as(u32, 1), proj.exprs[1].expr.column);
    try std.testing.expect(proj.exprs[2].expr.* == .column);
    try std.testing.expectEqual(@as(u32, 2), proj.exprs[2].expr.column);
}

test "qualified column ref in JOIN resolves correctly" {
    const alloc = std.testing.allocator;
    var sr = try makeSchema(alloc);
    defer sr.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try parser_mod.parse(
        "SELECT u.id, o.amount FROM users u JOIN orders o ON u.id = o.user_id",
        arena_alloc,
    );
    var planner = plan_mod.Planner.init(arena_alloc, &sr);
    const ep = try planner.planStmt(parsed.stmts[0], &.{});

    // users: id=0, name=1, score=2
    // orders: id=3, user_id=4, amount=5
    const select_node = ep.stmts[0].select;
    try std.testing.expect(select_node.* == .project);
    const proj = select_node.project;
    try std.testing.expectEqual(@as(usize, 2), proj.exprs.len);

    // u.id → column{0}
    try std.testing.expect(proj.exprs[0].expr.* == .column);
    try std.testing.expectEqual(@as(u32, 0), proj.exprs[0].expr.column);

    // o.amount → column{5}
    try std.testing.expect(proj.exprs[1].expr.* == .column);
    try std.testing.expectEqual(@as(u32, 5), proj.exprs[1].expr.column);

    // JOIN hash_join node — the condition should reference u.id=0 and o.user_id=4
    const join_node = select_node.project.input;
    try std.testing.expect(join_node.* == .hash_join);
    const cond = join_node.hash_join.condition;
    try std.testing.expect(cond.* == .binary);
    try std.testing.expect(cond.binary.left.* == .column);
    try std.testing.expectEqual(@as(u32, 0), cond.binary.left.column); // u.id
    try std.testing.expect(cond.binary.right.* == .column);
    try std.testing.expectEqual(@as(u32, 4), cond.binary.right.column); // o.user_id
}

test "GROUP BY + COUNT resolves aggregate to column position" {
    const alloc = std.testing.allocator;
    var sr = try makeSchema(alloc);
    defer sr.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try parser_mod.parse(
        "SELECT id, COUNT(*) FROM users GROUP BY id",
        arena_alloc,
    );
    var planner = plan_mod.Planner.init(arena_alloc, &sr);
    const ep = try planner.planStmt(parsed.stmts[0], &.{});

    const select_node = ep.stmts[0].select;
    try std.testing.expect(select_node.* == .project);
    const proj = select_node.project;
    try std.testing.expectEqual(@as(usize, 2), proj.exprs.len);

    // id (group key at position 0 in hash_agg output)
    try std.testing.expect(proj.exprs[0].expr.* == .column);
    try std.testing.expectEqual(@as(u32, 0), proj.exprs[0].expr.column);

    // COUNT(*) (agg result at position 1 in hash_agg output)
    try std.testing.expect(proj.exprs[1].expr.* == .column);
    try std.testing.expectEqual(@as(u32, 1), proj.exprs[1].expr.column);
}

test "hash_agg node has correct group_keys and agg_exprs" {
    const alloc = std.testing.allocator;
    var sr = try makeSchema(alloc);
    defer sr.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try parser_mod.parse(
        "SELECT name, SUM(score) FROM users GROUP BY name",
        arena_alloc,
    );
    var planner = plan_mod.Planner.init(arena_alloc, &sr);
    const ep = try planner.planStmt(parsed.stmts[0], &.{});

    // Find the hash_agg node (below project)
    const proj_node = ep.stmts[0].select;
    try std.testing.expect(proj_node.* == .project);
    const agg_node = proj_node.project.input;
    try std.testing.expect(agg_node.* == .hash_agg);
    const ha = agg_node.hash_agg;

    try std.testing.expectEqual(@as(usize, 1), ha.group_keys.len);
    try std.testing.expectEqual(@as(usize, 1), ha.agg_exprs.len);

    // group key: name (position 1 in users scan)
    try std.testing.expect(ha.group_keys[0].* == .column);
    try std.testing.expectEqual(@as(u32, 1), ha.group_keys[0].column);

    // agg: SUM(score) — score is at position 2
    try std.testing.expect(std.ascii.eqlIgnoreCase("sum", ha.agg_exprs[0].fn_name));
    const agg_arg = ha.agg_exprs[0].arg.?;
    try std.testing.expect(agg_arg.* == .column);
    try std.testing.expectEqual(@as(u32, 2), agg_arg.column);
}

test "plan scan node captures all column ids" {
    const alloc = std.testing.allocator;
    var sr = try makeSchema(alloc);
    defer sr.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try parser_mod.parse("SELECT id FROM users", arena_alloc);
    var planner = plan_mod.Planner.init(arena_alloc, &sr);
    const ep = try planner.planStmt(parsed.stmts[0], &.{});

    const proj = ep.stmts[0].select;
    try std.testing.expect(proj.* == .project);
    const scan_node = proj.project.input;
    try std.testing.expect(scan_node.* == .scan);
    // users has 3 columns
    try std.testing.expectEqual(@as(usize, 3), scan_node.scan.columns.len);
}

test "INSERT plan maps column names to IDs" {
    const alloc = std.testing.allocator;
    var sr = try makeSchema(alloc);
    defer sr.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try parser_mod.parse(
        "INSERT INTO users (id, name) VALUES ($1, $2)",
        arena_alloc,
    );
    var planner = plan_mod.Planner.init(arena_alloc, &sr);
    const ep = try planner.planStmt(parsed.stmts[0], &.{});

    const ins = ep.stmts[0].insert;
    try std.testing.expectEqual(@as(usize, 2), ins.column_ids.len);
    // Values should be param refs
    const row = ins.source.values[0];
    try std.testing.expect(row[0].* == .param);
    try std.testing.expectEqual(@as(u32, 0), row[0].param);
    try std.testing.expect(row[1].* == .param);
    try std.testing.expectEqual(@as(u32, 1), row[1].param);
}

test "planner sets index_hint when table has vector index" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    _ = try sr.createTable(.{
        .name = "vecs",
        .columns = &[_]ast_mod.ColumnDef{
            .{ .name = "id", .typ = .{ .int64 = .error_on_overflow }, .nullable = .not_null, .span = zero_span },
            .{ .name = "emb", .typ = .bytes, .nullable = .not_null, .span = zero_span },
        },
        .primary_key = .{ .columns = &.{"id"} },
    });
    try sr.createIndex(.{
        .name = "emb_vec",
        .unique = false,
        .kind = .{ .vector = 4 },
        .table = "vecs",
        .columns = &.{"emb"},
    });

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try parser_mod.parse("SELECT id FROM vecs", arena_alloc);
    var planner = plan_mod.Planner.init(arena_alloc, &sr);
    const ep = try planner.planStmt(parsed.stmts[0], &.{});

    const select = ep.stmts[0].select;
    try std.testing.expect(select.* == .project);
    const scan_node = select.project.input;
    try std.testing.expect(scan_node.* == .scan);
    try std.testing.expect(scan_node.scan.index_hint != null);
}

test "planner sets index_hint when table has json_path index" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    _ = try sr.createTable(.{
        .name = "docs",
        .columns = &[_]ast_mod.ColumnDef{
            .{ .name = "id", .typ = .{ .int64 = .error_on_overflow }, .nullable = .not_null, .span = zero_span },
            .{ .name = "body", .typ = .bytes, .nullable = .not_null, .span = zero_span },
        },
        .primary_key = .{ .columns = &.{"id"} },
    });
    // Allocate paths with sr's allocator so deinit() can free them correctly
    const declared_paths = try alloc.alloc([]const u8, 1);
    declared_paths[0] = "$.status";
    try sr.createIndex(.{
        .name = "body_json",
        .unique = false,
        .kind = .{ .json_path = declared_paths },
        .table = "docs",
        .columns = &.{"body"},
    });
    // declared_paths is now owned by sr; sr.deinit() will free it

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try parser_mod.parse("SELECT id FROM docs", arena_alloc);
    var planner = plan_mod.Planner.init(arena_alloc, &sr);
    const ep = try planner.planStmt(parsed.stmts[0], &.{});

    const select = ep.stmts[0].select;
    try std.testing.expect(select.* == .project);
    const scan_node = select.project.input;
    try std.testing.expect(scan_node.* == .scan);
    try std.testing.expect(scan_node.scan.index_hint != null);
}

test "planner no index_hint without specialty index" {
    const alloc = std.testing.allocator;
    var sr = try makeSchema(alloc);
    defer sr.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try parser_mod.parse("SELECT id FROM users", arena_alloc);
    var planner = plan_mod.Planner.init(arena_alloc, &sr);
    const ep = try planner.planStmt(parsed.stmts[0], &.{});

    const select = ep.stmts[0].select;
    try std.testing.expect(select.* == .project);
    const scan_node = select.project.input;
    try std.testing.expect(scan_node.* == .scan);
    try std.testing.expectEqual(@as(?schema_mod.IndexId, null), scan_node.scan.index_hint);
}
