const std = @import("std");
const testing = std.testing;
const storage = @import("storage.zig");

const Storage = storage.Storage;

test "snapshot: basic operations" {
    const alloc = testing.allocator;
    const path = "/tmp/foldb_snapshot";
    var store = try Storage.init(path, alloc);
    defer store.deinit();
    try store.registerTable(1);

    const mutations = [_]storage.Mutation{
        .{ .kind = .insert, .table_id = 1, .key = "key1", .value = "val1" },
    };
    try store.apply(&mutations, 1);

    const row = try store.get(1, "key1", 1);
    try testing.expect(row != null);
    if (row) |r| r.deinit(alloc);
}

test "snapshot: empty storage" {
    const alloc = testing.allocator;
    const path = "/tmp/foldb_empty";
    var store = try Storage.init(path, alloc);
    defer store.deinit();
    try store.registerTable(1);
    const row = try store.get(1, "missing", 1);
    try testing.expect(row == null);
}
