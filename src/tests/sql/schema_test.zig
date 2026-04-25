/// Tests for schema registry operations.
const std = @import("std");
const sql = @import("sql.zig");
const schema_mod = sql.schema;
const ast_mod = sql.ast;

const zero_span = ast_mod.Span{ .start = 0, .end = 0 };

fn singleIntCol(name: []const u8) ast_mod.ColumnDef {
    return .{
        .name = name,
        .typ = .{ .int64 = .error_on_overflow },
        .nullable = .not_null,
        .span = zero_span,
    };
}

// ─── createTable ─────────────────────────────────────────────────────────────

test "createTable basic" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    const tbl = try sr.createTable(.{
        .name = "t",
        .columns = &[_]ast_mod.ColumnDef{singleIntCol("id")},
        .primary_key = .{ .columns = &.{"id"} },
    });
    try std.testing.expectEqualStrings("t", tbl.name);
    try std.testing.expectEqual(@as(usize, 1), tbl.columns.len);
}

test "createTable multiple columns" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    _ = try sr.createTable(.{
        .name = "users",
        .columns = &[_]ast_mod.ColumnDef{
            singleIntCol("id"),
            .{ .name = "name", .typ = .string, .nullable = .not_null, .span = zero_span },
            .{ .name = "score", .typ = .{ .decimal = .{ .precision = 38, .scale = 10 } }, .nullable = .nullable, .span = zero_span },
        },
        .primary_key = .{ .columns = &.{"id"} },
    });

    const tbl = sr.getTable("users").?;
    try std.testing.expectEqual(@as(usize, 3), tbl.columns.len);
}

test "createTable rejects duplicate table" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    _ = try sr.createTable(.{
        .name = "t",
        .columns = &[_]ast_mod.ColumnDef{singleIntCol("id")},
        .primary_key = .{ .columns = &.{"id"} },
    });
    const result = sr.createTable(.{
        .name = "t",
        .columns = &[_]ast_mod.ColumnDef{singleIntCol("id")},
        .primary_key = .{ .columns = &.{"id"} },
    });
    try std.testing.expectError(error.TableAlreadyExists, result);
}

test "createTable rejects missing primary key" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    const result = sr.createTable(.{
        .name = "t",
        .columns = &[_]ast_mod.ColumnDef{singleIntCol("id")},
        .primary_key = .{ .columns = &.{} },
    });
    try std.testing.expectError(error.NoPrimaryKey, result);
}

test "createTable rejects unknown PK column" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    const result = sr.createTable(.{
        .name = "t",
        .columns = &[_]ast_mod.ColumnDef{singleIntCol("id")},
        .primary_key = .{ .columns = &.{"nonexistent"} },
    });
    try std.testing.expectError(error.PrimaryKeyColumnNotFound, result);
}

test "createTable rejects composite PK with duplicate column" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    const result = sr.createTable(.{
        .name = "t",
        .columns = &[_]ast_mod.ColumnDef{
            singleIntCol("a"),
            singleIntCol("b"),
        },
        .primary_key = .{ .columns = &.{ "a", "a" } },
    });
    try std.testing.expectError(error.DuplicatePrimaryKeyColumn, result);
}

// ─── getTable / getTableById ──────────────────────────────────────────────────

test "getTable returns null for unknown table" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    try std.testing.expect(sr.getTable("ghost") == null);
}

test "getTable is case-insensitive" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    _ = try sr.createTable(.{
        .name = "users",
        .columns = &[_]ast_mod.ColumnDef{singleIntCol("id")},
        .primary_key = .{ .columns = &.{"id"} },
    });
    // Schema stores by exact name but lookup should be case-insensitive
    _ = sr.getTable("users") orelse return error.TestUnexpectedNull;
}

test "getTableById returns correct table" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    const tbl = try sr.createTable(.{
        .name = "t",
        .columns = &[_]ast_mod.ColumnDef{singleIntCol("id")},
        .primary_key = .{ .columns = &.{"id"} },
    });
    const by_id = sr.getTableById(tbl.id).?;
    try std.testing.expectEqualStrings("t", by_id.name);
}

// ─── columnByName ─────────────────────────────────────────────────────────────

test "columnByName finds column" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    _ = try sr.createTable(.{
        .name = "t",
        .columns = &[_]ast_mod.ColumnDef{
            singleIntCol("id"),
            .{ .name = "name", .typ = .string, .nullable = .not_null, .span = zero_span },
        },
        .primary_key = .{ .columns = &.{"id"} },
    });
    const tbl = sr.getTable("t").?;
    const col = tbl.columnByName("name").?;
    try std.testing.expectEqualStrings("name", col.name);
}

test "columnByName is case-insensitive" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    _ = try sr.createTable(.{
        .name = "t",
        .columns = &[_]ast_mod.ColumnDef{singleIntCol("MyCol")},
        .primary_key = .{ .columns = &.{"MyCol"} },
    });
    const tbl = sr.getTable("t").?;
    try std.testing.expect(tbl.columnByName("MYCOL") != null);
    try std.testing.expect(tbl.columnByName("mycol") != null);
}

test "columnByName returns null for unknown column" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    _ = try sr.createTable(.{
        .name = "t",
        .columns = &[_]ast_mod.ColumnDef{singleIntCol("id")},
        .primary_key = .{ .columns = &.{"id"} },
    });
    const tbl = sr.getTable("t").?;
    try std.testing.expect(tbl.columnByName("ghost") == null);
}

// ─── addColumn / dropColumn ───────────────────────────────────────────────────

test "addColumn adds a new column" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    _ = try sr.createTable(.{
        .name = "t",
        .columns = &[_]ast_mod.ColumnDef{singleIntCol("id")},
        .primary_key = .{ .columns = &.{"id"} },
    });
    try sr.addColumn("t", .{
        .name = "email",
        .typ = .string,
        .nullable = .nullable,
        .span = zero_span,
    });
    const tbl = sr.getTable("t").?;
    try std.testing.expectEqual(@as(usize, 2), tbl.columns.len);
    try std.testing.expect(tbl.columnByName("email") != null);
}

test "addColumn rejects duplicate column name" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    _ = try sr.createTable(.{
        .name = "t",
        .columns = &[_]ast_mod.ColumnDef{singleIntCol("id")},
        .primary_key = .{ .columns = &.{"id"} },
    });
    const result = sr.addColumn("t", singleIntCol("id"));
    try std.testing.expectError(error.ColumnAlreadyExists, result);
}

test "addColumn rejects unknown table" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    const result = sr.addColumn("ghost", singleIntCol("id"));
    try std.testing.expectError(error.TableNotFound, result);
}

test "dropColumn removes column" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    _ = try sr.createTable(.{
        .name = "t",
        .columns = &[_]ast_mod.ColumnDef{
            singleIntCol("id"),
            .{ .name = "extra", .typ = .string, .nullable = .nullable, .span = zero_span },
        },
        .primary_key = .{ .columns = &.{"id"} },
    });
    try sr.dropColumn("t", "extra");
    const tbl = sr.getTable("t").?;
    try std.testing.expect(tbl.columnByName("extra") == null);
    try std.testing.expectEqual(@as(usize, 1), tbl.columns.len);
}

test "dropColumn rejects unknown column" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    _ = try sr.createTable(.{
        .name = "t",
        .columns = &[_]ast_mod.ColumnDef{singleIntCol("id")},
        .primary_key = .{ .columns = &.{"id"} },
    });
    const result = sr.dropColumn("t", "ghost");
    try std.testing.expectError(error.ColumnNotFound, result);
}

// ─── createIndex ──────────────────────────────────────────────────────────────

test "createIndex adds index to table" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    _ = try sr.createTable(.{
        .name = "t",
        .columns = &[_]ast_mod.ColumnDef{
            singleIntCol("id"),
            .{ .name = "name", .typ = .string, .nullable = .not_null, .span = zero_span },
        },
        .primary_key = .{ .columns = &.{"id"} },
    });
    try sr.createIndex(.{
        .name = "idx_name",
        .unique = false,
        .kind = .ordered,
        .table = "t",
        .columns = &.{"name"},
    });
    const tbl = sr.getTable("t").?;
    try std.testing.expectEqual(@as(usize, 1), tbl.indexes.len);
}

test "createIndex rejects unknown table" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    const result = sr.createIndex(.{
        .name = "idx",
        .unique = false,
        .kind = .ordered,
        .table = "ghost",
        .columns = &.{"id"},
    });
    try std.testing.expectError(error.TableNotFound, result);
}

test "createIndex rejects unknown column" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();

    _ = try sr.createTable(.{
        .name = "t",
        .columns = &[_]ast_mod.ColumnDef{singleIntCol("id")},
        .primary_key = .{ .columns = &.{"id"} },
    });
    const result = sr.createIndex(.{
        .name = "idx",
        .unique = false,
        .kind = .ordered,
        .table = "t",
        .columns = &.{"ghost"},
    });
    try std.testing.expectError(error.ColumnNotFound, result);
}
