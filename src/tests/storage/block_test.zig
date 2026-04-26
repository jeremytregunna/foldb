const std = @import("std");
const testing = std.testing;
const storage = @import("storage.zig");

const TableSchema = storage.TableSchema;
const ColumnValue = storage.ColumnValue;
const BlockWriter = storage.BlockWriter;
const BlockReader = storage.BlockReader;

fn makeSchema() TableSchema {
    return .{
        .table_id = 1,
        .columns = &.{
            .{ .col_type = .string, .nullable = false },
            .{ .col_type = .int64, .nullable = false },
        },
    };
}

test "Block: write and read back rows" {
    const alloc = testing.allocator;
    const schema = makeSchema();

    var writer = try BlockWriter.init(schema);
    defer writer.deinit(alloc);

    const vals0 = [_]ColumnValue{ .{ .string = "alice" }, .{ .int64 = 100 } };
    const vals1 = [_]ColumnValue{ .{ .string = "bob" }, .{ .int64 = 200 } };
    const vals2 = [_]ColumnValue{ .{ .string = "carol" }, .{ .int64 = 300 } };

    try writer.append(alloc, "key0", 1, &vals0);
    try writer.append(alloc, "key1", 2, &vals1);
    try writer.append(alloc, "key2", 3, &vals2);

    const data = try writer.flush(alloc);
    defer alloc.free(data);

    const reader = try BlockReader.init(data, schema);
    try testing.expectEqual(@as(u32, 3), reader.row_count);

    // Read row 0
    {
        const kv = try reader.readKey(0);
        try testing.expectEqualSlices(u8, "key0", kv.key);
        try testing.expectEqual(@as(u64, 1), kv.seq);
        try testing.expect(!kv.is_tombstone);
        const row = try reader.readRow(0, alloc);
        defer {
            var r = row;
            r.deinit(alloc);
        }
        try testing.expectEqualSlices(u8, "key0", row.key);
        try testing.expectEqual(@as(i64, 100), row.values[1].int64);
    }

    // Read row 2
    {
        const row = try reader.readRow(2, alloc);
        defer {
            var r = row;
            r.deinit(alloc);
        }
        try testing.expectEqualSlices(u8, "key2", row.key);
        try testing.expectEqual(@as(i64, 300), row.values[1].int64);
    }
}

test "Block: binary search finds key" {
    const alloc = testing.allocator;
    const schema = makeSchema();

    var writer = try BlockWriter.init(schema);
    defer writer.deinit(alloc);

    const v = [_]ColumnValue{ .{ .string = "x" }, .{ .int64 = 0 } };
    try writer.append(alloc, "aaa", 1, &v);
    try writer.append(alloc, "bbb", 1, &v);
    try writer.append(alloc, "ccc", 1, &v);
    try writer.append(alloc, "ddd", 1, &v);

    const data = try writer.flush(alloc);
    defer alloc.free(data);
    const reader = try BlockReader.init(data, schema);

    try testing.expectEqual(@as(?u32, 0), try reader.findKey("aaa"));
    try testing.expectEqual(@as(?u32, 2), try reader.findKey("ccc"));
    try testing.expectEqual(@as(?u32, null), try reader.findKey("zzz"));
}

test "Block: mixed column types (string + bool)" {
    const alloc = testing.allocator;
    const schema: storage.TableSchema = .{
        .table_id = 1,
        .columns = &.{
            .{ .col_type = .string, .nullable = false },
            .{ .col_type = .bool_t, .nullable = false },
        },
    };

    var writer = try BlockWriter.init(schema);
    defer writer.deinit(alloc);

    const v0 = [_]ColumnValue{ .{ .string = "hello" }, .{ .bool_t = true } };
    const v1 = [_]ColumnValue{ .{ .string = "world" }, .{ .bool_t = false } };
    const v2 = [_]ColumnValue{ .{ .string = "zig" }, .{ .bool_t = true } };
    try writer.append(alloc, "k0", 1, &v0);
    try writer.append(alloc, "k1", 2, &v1);
    try writer.append(alloc, "k2", 3, &v2);

    const data = try writer.flush(alloc);
    defer alloc.free(data);
    const reader = try BlockReader.init(data, schema);
    try testing.expectEqual(@as(u32, 3), reader.row_count);

    const row1 = try reader.readRow(1, alloc);
    defer {
        var r = row1;
        r.deinit(alloc);
    }
    try testing.expectEqualSlices(u8, "k1", row1.key);
    try testing.expectEqualSlices(u8, "world", row1.values[0].string);
    try testing.expectEqual(false, row1.values[1].bool_t);
}

test "Block: 100 rows round-trip" {
    const alloc = testing.allocator;
    const schema = makeSchema();

    var writer = try BlockWriter.init(schema);
    defer writer.deinit(alloc);

    const base_val = [_]ColumnValue{ .{ .string = "x" }, .{ .int64 = 0 } };
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        var key_buf: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "k{d:04}", .{i});
        var vals = base_val;
        vals[1] = .{ .int64 = @intCast(i) };
        try writer.append(alloc, key, i + 1, &vals);
    }

    const data = try writer.flush(alloc);
    defer alloc.free(data);
    const reader = try BlockReader.init(data, schema);
    try testing.expectEqual(@as(u32, 100), reader.row_count);

    // Spot-check first, middle, last
    const r0 = try reader.readRow(0, alloc);
    defer {
        var r = r0;
        r.deinit(alloc);
    }
    try testing.expectEqual(@as(i64, 0), r0.values[1].int64);

    const r50 = try reader.readRow(50, alloc);
    defer {
        var r = r50;
        r.deinit(alloc);
    }
    try testing.expectEqual(@as(i64, 50), r50.values[1].int64);

    const r99 = try reader.readRow(99, alloc);
    defer {
        var r = r99;
        r.deinit(alloc);
    }
    try testing.expectEqual(@as(i64, 99), r99.values[1].int64);
}

test "Block: tombstone row" {
    const alloc = testing.allocator;
    const schema = makeSchema();

    var writer = try BlockWriter.init(schema);
    defer writer.deinit(alloc);

    const v = [_]ColumnValue{ .{ .string = "x" }, .{ .int64 = 1 } };
    try writer.append(alloc, "key0", 10, &v);
    try writer.append(alloc, "key1", 11, null); // tombstone
    try writer.append(alloc, "key2", 12, &v);

    const data = try writer.flush(alloc);
    defer alloc.free(data);
    const reader = try BlockReader.init(data, schema);

    const kv0 = try reader.readKey(0);
    try testing.expect(!kv0.is_tombstone);
    const kv1 = try reader.readKey(1);
    try testing.expect(kv1.is_tombstone);
    const kv2 = try reader.readKey(2);
    try testing.expect(!kv2.is_tombstone);
}
