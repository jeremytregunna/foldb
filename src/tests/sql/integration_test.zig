const std = @import("std");
const sql = @import("sql.zig");
const registry_mod = sql.registry;
const schema_mod = sql.schema;
const ast_mod = sql.ast;

const user_cols = [_]ast_mod.ColumnDef{
    .{ .name = "id",   .typ = .{ .int64 = .error_on_overflow }, .nullable = .not_null, .span = .{ .start = 0, .end = 0 } },
    .{ .name = "name", .typ = .string, .nullable = .not_null, .span = .{ .start = 0, .end = 0 } },
};

test "register insert and select queries" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    _ = try sr.createTable(.{ .name = "users", .columns = &user_cols, .primary_key = .{ .columns = &.{"id"} } });
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();

    const insert_hash = try reg.register("INSERT INTO users (id, name) VALUES ($1, $2)");
    const select_hash = try reg.register("SELECT id, name FROM users WHERE id = $1");

    try std.testing.expect(reg.lookup(insert_hash) != null);
    try std.testing.expect(reg.lookup(select_hash) != null);
    try std.testing.expect(!std.mem.eql(u8, &insert_hash, &select_hash));
}

test "register transaction block" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    _ = try sr.createTable(.{ .name = "users", .columns = &user_cols, .primary_key = .{ .columns = &.{"id"} } });
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();

    const h = try reg.register(
        \\TRANSACTION (uid INT64, uname STRING) {
        \\  INSERT INTO users (id, name) VALUES ($1, $2);
        \\}
    );
    const rq = reg.lookup(h);
    try std.testing.expect(rq != null);
    try std.testing.expectEqual(@as(u32, 0), rq.?.nondet_count);
}

test "DDL via applyDdl updates schema" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    _ = try sr.createTable(.{ .name = "users", .columns = &user_cols, .primary_key = .{ .columns = &.{"id"} } });
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();

    try reg.applyDdl(.{ .create_table = .{
        .name = "orders",
        .columns = &[_]ast_mod.ColumnDef{
            .{ .name = "id", .typ = .{ .int64 = .error_on_overflow }, .nullable = .not_null, .span = .{ .start = 0, .end = 0 } },
        },
        .primary_key = .{ .columns = &.{"id"} },
    }});

    const h = try reg.register("SELECT id FROM orders WHERE id = $1");
    try std.testing.expect(reg.lookup(h) != null);
}

test "whitespace-normalized queries share hash" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    _ = try sr.createTable(.{ .name = "users", .columns = &user_cols, .primary_key = .{ .columns = &.{"id"} } });
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();

    const h1 = try reg.register("SELECT id FROM users WHERE id = $1");
    const h2 = try reg.register("SELECT  id  FROM  users  WHERE  id = $1");
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}
