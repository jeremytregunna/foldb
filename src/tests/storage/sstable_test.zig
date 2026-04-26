const std = @import("std");
const testing = std.testing;
const storage = @import("storage.zig");

const TableSchema = storage.TableSchema;
const ColumnValue = storage.ColumnValue;
const SSTableWriter = storage.SSTableWriter;
const SSTableReader = storage.SSTableReader;

fn makeSchema() TableSchema {
    return .{
        .table_id = 1,
        .columns = &.{
            .{ .col_type = .string, .nullable = false },
            .{ .col_type = .uint64, .nullable = false },
        },
    };
}

fn makeTempPath(alloc: std.mem.Allocator) ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(alloc, "/tmp/sst_test_{d}.sst", .{ns});
}

fn deletePath(path: []const u8) void {
    const null_path = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(null_path);
    @memcpy(null_path[0..path.len], path);
    _ = std.os.linux.unlink(null_path.ptr);
}

test "SSTable: write and read back" {
    const alloc = testing.allocator;
    const schema = makeSchema();
    const path = try makeTempPath(alloc);
    defer alloc.free(path);
    defer deletePath(path);

    {
        var writer = try SSTableWriter.create(path, schema, 0, alloc);
        defer writer.deinit();

        const v0 = [_]ColumnValue{ .{ .string = "alice" }, .{ .uint64 = 42 } };
        const v1 = [_]ColumnValue{ .{ .string = "bob" }, .{ .uint64 = 99 } };
        try writer.append("key0", 1, &v0);
        try writer.append("key1", 2, &v1);
        try writer.finish();
    }

    var reader = try SSTableReader.open(path, schema, alloc);
    defer reader.deinit();

    try testing.expectEqual(@as(u32, 1), reader.header.block_count);

    if (try reader.get("key0", 10)) |row| {
        var r = row;
        defer r.deinit(alloc);
        try testing.expectEqualSlices(u8, "key0", r.key);
        try testing.expectEqual(@as(u64, 42), r.values[1].uint64);
    } else {
        return error.RowNotFound;
    }
}

test "SSTable: MVCC get at specific seq" {
    const alloc = testing.allocator;
    const schema = makeSchema();
    const path = try makeTempPath(alloc);
    defer alloc.free(path);
    defer deletePath(path);

    {
        var writer = try SSTableWriter.create(path, schema, 0, alloc);
        defer writer.deinit();
        // Two versions of "key0" — seq 10 first (newest), seq 5 second
        const v10 = [_]ColumnValue{ .{ .string = "v10" }, .{ .uint64 = 10 } };
        const v5 = [_]ColumnValue{ .{ .string = "v5" }, .{ .uint64 = 5 } };
        try writer.append("key0", 10, &v10);
        try writer.append("key0", 5, &v5);
        try writer.finish();
    }

    var reader = try SSTableReader.open(path, schema, alloc);
    defer reader.deinit();

    // At seq=10: should see v10
    if (try reader.get("key0", 10)) |row| {
        var r = row;
        defer r.deinit(alloc);
        try testing.expectEqual(@as(u64, 10), r.seq);
    } else return error.Expected_v10;

    // At seq=7: should see v5
    if (try reader.get("key0", 7)) |row| {
        var r = row;
        defer r.deinit(alloc);
        try testing.expectEqual(@as(u64, 5), r.seq);
    } else return error.Expected_v5;

    // At seq=4: nothing (before any write)
    const none = try reader.get("key0", 4);
    try testing.expectEqual(@as(?storage.Row, null), none);
}

test "SSTable: tombstone hides row" {
    const alloc = testing.allocator;
    const schema = makeSchema();
    const path = try makeTempPath(alloc);
    defer alloc.free(path);
    defer deletePath(path);

    {
        var writer = try SSTableWriter.create(path, schema, 0, alloc);
        defer writer.deinit();
        try writer.append("key0", 5, null); // tombstone
        try writer.append("key0", 3, &[_]ColumnValue{ .{ .string = "old" }, .{ .uint64 = 1 } });
        try writer.finish();
    }

    var reader = try SSTableReader.open(path, schema, alloc);
    defer reader.deinit();

    const row = try reader.get("key0", 10);
    try testing.expectEqual(@as(?storage.Row, null), row);
}

test "SSTable: key not found returns null" {
    const alloc = testing.allocator;
    const schema = makeSchema();
    const path = try makeTempPath(alloc);
    defer alloc.free(path);
    defer deletePath(path);

    {
        var writer = try SSTableWriter.create(path, schema, 0, alloc);
        defer writer.deinit();
        try writer.append("key0", 1, &[_]ColumnValue{ .{ .string = "x" }, .{ .uint64 = 0 } });
        try writer.finish();
    }

    var reader = try SSTableReader.open(path, schema, alloc);
    defer reader.deinit();

    const row = try reader.get("key999", 100);
    try testing.expectEqual(@as(?storage.Row, null), row);
}

test "SSTable: at_seq exact boundary" {
    const alloc = testing.allocator;
    const schema = makeSchema();
    const path = try makeTempPath(alloc);
    defer alloc.free(path);
    defer deletePath(path);

    {
        var writer = try SSTableWriter.create(path, schema, 0, alloc);
        defer writer.deinit();
        const v = [_]ColumnValue{ .{ .string = "exact" }, .{ .uint64 = 7 } };
        try writer.append("boundary", 42, &v);
        try writer.finish();
    }

    var reader = try SSTableReader.open(path, schema, alloc);
    defer reader.deinit();

    // at_seq == write_seq: visible
    if (try reader.get("boundary", 42)) |row| {
        var r = row;
        defer r.deinit(alloc);
        try testing.expectEqual(@as(u64, 42), r.seq);
    } else return error.ExpectedRowAtExactSeq;

    // at_seq == write_seq - 1: not visible
    const none = try reader.get("boundary", 41);
    try testing.expectEqual(@as(?storage.Row, null), none);
}

test "SSTable: multi-block file (600 rows)" {
    const alloc = testing.allocator;
    const schema = makeSchema();
    const path = try makeTempPath(alloc);
    defer alloc.free(path);
    defer deletePath(path);

    // Write 600 rows — forces at least 2 blocks (512 rows per block max)
    {
        var writer = try SSTableWriter.create(path, schema, 0, alloc);
        defer writer.deinit();
        var ki: u32 = 0;
        while (ki < 600) : (ki += 1) {
            const key = try std.fmt.allocPrint(alloc, "row{d:04}", .{ki});
            defer alloc.free(key);
            const v = [_]ColumnValue{ .{ .string = "v" }, .{ .uint64 = ki } };
            try writer.append(key, ki + 1, &v);
        }
        try writer.finish();
    }

    var reader = try SSTableReader.open(path, schema, alloc);
    defer reader.deinit();

    // Must span at least 2 blocks
    try testing.expect(reader.header.block_count >= 2);

    // First row
    if (try reader.get("row0000", 1)) |row| {
        var r = row;
        defer r.deinit(alloc);
        try testing.expectEqual(@as(u64, 0), r.values[1].uint64);
    } else return error.FirstRowMissing;

    // Last row (second block)
    if (try reader.get("row0599", 600)) |row| {
        var r = row;
        defer r.deinit(alloc);
        try testing.expectEqual(@as(u64, 599), r.values[1].uint64);
    } else return error.LastRowMissing;

    // Middle row — straddles block boundary
    if (try reader.get("row0511", 512)) |row| {
        var r = row;
        defer r.deinit(alloc);
        try testing.expectEqual(@as(u64, 511), r.values[1].uint64);
    } else return error.MiddleRowMissing;
}
