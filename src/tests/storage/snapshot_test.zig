const std = @import("std");
const testing = std.testing;
const storage = @import("storage.zig");

const Storage = storage.Storage;

fn makeTempDir(alloc: std.mem.Allocator, comptime name: []const u8) ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const path = try std.fmt.allocPrint(alloc, "/tmp/foldb_snapshot_{s}_{d}", .{ name, ns });
    const z = try alloc.allocSentinel(u8, path.len, 0);
    defer alloc.free(z);
    @memcpy(z[0..path.len], path);
    _ = std.os.linux.mkdir(z.ptr, 0o755);
    return path;
}

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

test "snapshot: restore KV data from object store" {
    const alloc = testing.allocator;
    const source_path = try makeTempDir(alloc, "source");
    defer alloc.free(source_path);
    const restore_path = try makeTempDir(alloc, "restore");
    defer alloc.free(restore_path);

    var object_store = storage.MemoryObjectStore.init(alloc);
    defer object_store.deinit();

    var store = try Storage.init(source_path, alloc);
    defer store.deinit();
    try store.registerTable(1);

    try store.apply(&[_]storage.Mutation{
        .{ .kind = .insert, .table_id = 1, .key = "alpha", .value = "one" },
        .{ .kind = .insert, .table_id = 1, .key = "beta", .value = "two" },
    }, 7);

    const lsm = store.tables.getPtr(1) orelse return error.TableNotFound;
    var manifest = try storage.takeSnapshot(lsm, 7, 0, object_store.objectStore(), storage.noop_snapshot_log_writer, alloc);
    defer manifest.deinit();

    var restored = try storage.restoreFromSnapshot(&manifest, restore_path, object_store.objectStore(), alloc);
    defer restored.deinit();

    const alpha = try restored.get("alpha", 7);
    try testing.expect(alpha != null);
    if (alpha) |row| {
        defer row.deinit(alloc);
        try testing.expectEqualStrings("one", row.value);
    }

    const beta = try restored.get("beta", 7);
    try testing.expect(beta != null);
    if (beta) |row| {
        defer row.deinit(alloc);
        try testing.expectEqualStrings("two", row.value);
    }
}
