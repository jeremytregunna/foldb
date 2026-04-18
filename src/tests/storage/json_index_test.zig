const std = @import("std");
const storage = @import("storage.zig");

const Storage = storage.Storage;
const Mutation = storage.Mutation;
const ColumnValue = storage.ColumnValue;
const KeyRange = storage.KeyRange;

fn makeTempDir(alloc: std.mem.Allocator) ![]u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const path = try std.fmt.allocPrint(alloc, "/tmp/folddb_json_idx_test_{d}", .{ns});
    const null_path = try alloc.allocSentinel(u8, path.len, 0);
    defer alloc.free(null_path);
    @memcpy(null_path[0..path.len], path);
    _ = std.os.linux.mkdir(null_path.ptr, 0o755);
    return path;
}

fn rmDir(path: []const u8, alloc: std.mem.Allocator) void {
    const null_path = alloc.allocSentinel(u8, path.len, 0) catch return;
    defer alloc.free(null_path);
    @memcpy(null_path[0..path.len], path);
    _ = std.os.linux.rmdir(null_path.ptr);
}

test "json index insert and lookup" {
    const alloc = std.testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer rmDir(dir, alloc);

    var stor = try Storage.init(dir, alloc);
    defer stor.deinit();

    // Register base table: table_id=1, 1 column (JSON stored as bytes)
    try stor.registerTable(.{
        .table_id = 1,
        .columns = &.{.{ .col_type = .bytes, .nullable = false }},
    });

    // Register JSON path index
    const paths: []const []const u8 = &.{"$.city"};
    try stor.registerIndex(.{
        .id = 100,
        .table_id = 1,
        .column_idx = 0,
        .kind = .json_path,
        .json_paths = paths,
        .vector_dim = 0,
    });

    // Insert a row
    const json1: []const u8 = "{\"city\": \"toronto\", \"zip\": \"M5A\"}";
    try stor.apply(&.{Mutation{
        .kind = .insert,
        .table_id = 1,
        .key = "row1",
        .values = &.{ColumnValue{ .bytes = json1 }},
    }}, 1);

    const json2: []const u8 = "{\"city\": \"montreal\", \"zip\": \"H3A\"}";
    try stor.apply(&.{Mutation{
        .kind = .insert,
        .table_id = 1,
        .key = "row2",
        .values = &.{ColumnValue{ .bytes = json2 }},
    }}, 2);

    // Lookup by city=toronto
    var result = try stor.indexLookup(100, "$.city", "toronto", 3, alloc);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.pks.len);
    try std.testing.expectEqualStrings("row1", result.pks[0]);
}

test "json index delete removes entry" {
    const alloc = std.testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer rmDir(dir, alloc);

    var stor = try Storage.init(dir, alloc);
    defer stor.deinit();

    try stor.registerTable(.{
        .table_id = 1,
        .columns = &.{.{ .col_type = .bytes, .nullable = false }},
    });

    const paths: []const []const u8 = &.{"$.status"};
    try stor.registerIndex(.{
        .id = 101,
        .table_id = 1,
        .column_idx = 0,
        .kind = .json_path,
        .json_paths = paths,
        .vector_dim = 0,
    });

    const json: []const u8 = "{\"status\": \"active\"}";
    try stor.apply(&.{Mutation{
        .kind = .insert,
        .table_id = 1,
        .key = "row1",
        .values = &.{ColumnValue{ .bytes = json }},
    }}, 1);

    // Verify present
    {
        var r = try stor.indexLookup(101, "$.status", "active", 2, alloc);
        defer r.deinit();
        try std.testing.expectEqual(@as(usize, 1), r.pks.len);
    }

    // Delete the row
    try stor.apply(&.{Mutation{
        .kind = .delete,
        .table_id = 1,
        .key = "row1",
        .values = null,
    }}, 2);

    // Should no longer appear
    var r2 = try stor.indexLookup(101, "$.status", "active", 3, alloc);
    defer r2.deinit();
    try std.testing.expectEqual(@as(usize, 0), r2.pks.len);
}

test "json index lookup survives memtable flush to SSTable" {
    const alloc = std.testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer rmDir(dir, alloc);

    var stor = try Storage.init(dir, alloc);
    defer stor.deinit();

    try stor.registerTable(.{
        .table_id = 1,
        .columns = &.{.{ .col_type = .bytes, .nullable = false }},
    });

    const paths: []const []const u8 = &.{"$.tag"};
    try stor.registerIndex(.{
        .id = 102,
        .table_id = 1,
        .column_idx = 0,
        .kind = .json_path,
        .json_paths = paths,
        .vector_dim = 0,
    });

    const json: []const u8 = "{\"tag\": \"urgent\"}";
    try stor.apply(&.{Mutation{
        .kind = .insert,
        .table_id = 1,
        .key = "row1",
        .values = &.{ColumnValue{ .bytes = json }},
    }}, 1);

    // Flush both base table and index LSMs to SSTables
    try stor.flushAll();
    try stor.flushIndexes();

    // Lookup must still find the entry via SSTable scan
    var result = try stor.indexLookup(102, "$.tag", "urgent", 2, alloc);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.pks.len);
    try std.testing.expectEqualStrings("row1", result.pks[0]);
}

test "json index delete removes entry after flush" {
    const alloc = std.testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer rmDir(dir, alloc);

    var stor = try Storage.init(dir, alloc);
    defer stor.deinit();

    try stor.registerTable(.{
        .table_id = 1,
        .columns = &.{.{ .col_type = .bytes, .nullable = false }},
    });

    const paths: []const []const u8 = &.{"$.color"};
    try stor.registerIndex(.{
        .id = 103,
        .table_id = 1,
        .column_idx = 0,
        .kind = .json_path,
        .json_paths = paths,
        .vector_dim = 0,
    });

    const json: []const u8 = "{\"color\": \"red\"}";
    try stor.apply(&.{Mutation{
        .kind = .insert,
        .table_id = 1,
        .key = "row1",
        .values = &.{ColumnValue{ .bytes = json }},
    }}, 1);

    // Flush, then delete
    try stor.flushAll();
    try stor.flushIndexes();
    try stor.apply(&.{Mutation{
        .kind = .delete,
        .table_id = 1,
        .key = "row1",
        .values = null,
    }}, 2);

    // Entry must be gone (tombstone in memtable wins over SSTable entry)
    var result = try stor.indexLookup(103, "$.color", "red", 3, alloc);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.pks.len);
}
