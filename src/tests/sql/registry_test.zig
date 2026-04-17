const std = @import("std");
const sql = @import("sql.zig");
const registry_mod = sql.registry;
const schema_mod = sql.schema;
const ast_mod = sql.ast;

fn makeUsersTable(sr: *schema_mod.SchemaRegistry) !void {
    _ = try sr.createTable(.{
        .name = "users",
        .columns = &[_]ast_mod.ColumnDef{
            .{ .name = "id",   .typ = .{ .int64 = .error_on_overflow }, .nullable = .not_null, .span = .{ .start = 0, .end = 0 } },
            .{ .name = "name", .typ = .string, .nullable = .not_null, .span = .{ .start = 0, .end = 0 } },
        },
        .primary_key = .{ .columns = &.{"id"} },
    });
}

test "register and lookup simple select" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    try makeUsersTable(&sr);

    const hash = try reg.register("SELECT id FROM users WHERE id = $1");
    const rq = reg.lookup(hash);
    try std.testing.expect(rq != null);
    try std.testing.expectEqualSlices(u8, &hash, &rq.?.hash);
}

test "register is idempotent" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();

    _ = try sr.createTable(.{
        .name = "t",
        .columns = &[_]ast_mod.ColumnDef{
            .{ .name = "id", .typ = .{ .int64 = .error_on_overflow }, .nullable = .not_null, .span = .{ .start = 0, .end = 0 } },
        },
        .primary_key = .{ .columns = &.{"id"} },
    });

    const h1 = try reg.register("SELECT id FROM t WHERE id = $1");
    const h2 = try reg.register("SELECT id FROM t WHERE id = $1");
    try std.testing.expectEqualSlices(u8, &h1, &h2);
    try std.testing.expectEqual(@as(usize, 1), reg.queries.count());
}

test "lookup unknown hash returns null" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();

    const missing: registry_mod.QueryHash = [_]u8{0} ** 32;
    try std.testing.expect(reg.lookup(missing) == null);
}

test "register rejects SELECT *" {
    const alloc = std.testing.allocator;
    var sr = schema_mod.SchemaRegistry.init(alloc);
    defer sr.deinit();
    var reg = registry_mod.SqlRegistry.init(alloc, &sr);
    defer reg.deinit();
    try makeUsersTable(&sr);

    const result = reg.register("SELECT * FROM users");
    try std.testing.expectError(error.SelectStarInRegisteredQuery, result);
}
