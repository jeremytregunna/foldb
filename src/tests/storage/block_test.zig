const std = @import("std");
const testing = std.testing;
const storage = @import("storage.zig");

const Seq = storage.Seq;
const HEADER_SIZE = storage.HEADER_SIZE;
const FOOTER_SIZE = storage.FOOTER_SIZE;
const MAX_ROWS_PER_BLOCK = storage.MAX_ROWS_PER_BLOCK;

pub const Row = struct { key: []const u8, seq: Seq, value: ?[]const u8 };

fn writeBlock(alloc: std.mem.Allocator, rows: []const Row) ![]u8 {
    var writer = storage.BlockWriter.init(alloc);
    errdefer writer.deinit(alloc);
    for (rows) |r| {
        try writer.append(alloc, r.key, r.seq, r.value);
    }
    const result = try writer.flush(alloc);
    writer.deinit(alloc);
    return result;
}

test "block: single row round-trip" {
    const alloc = testing.allocator;
    const data = try writeBlock(alloc, &.{ .{ .key = "hello", .seq = 42, .value = "world" } });
    defer alloc.free(data);
    const reader = try storage.BlockReader.init(data);
    try testing.expectEqual(@as(u32, 1), reader.row_count);

    const kv = try reader.readKey(0);
    try testing.expectEqualSlices(u8, "hello", kv.key);
    try testing.expectEqual(@as(u64, 42), kv.seq);
    try testing.expect(!kv.is_tombstone);

    const val = try reader.readValue(0, alloc);
    defer alloc.free(val);
    try testing.expectEqualSlices(u8, "world", val);
}

test "block: multiple rows round-trip" {
    const alloc = testing.allocator;
    const rows = [_]Row {
        .{ .key = "a", .seq = 1, .value = "1" },
        .{ .key = "b", .seq = 2, .value = "2" },
        .{ .key = "c", .seq = 3, .value = "3" },
        .{ .key = "d", .seq = 4, .value = "4" },
    };
    const data = try writeBlock(alloc, &rows);
    defer alloc.free(data);
    const reader = try storage.BlockReader.init(data);
    try testing.expectEqual(@as(u32, 4), reader.row_count);
    var i: u32 = 0;
    while (i < reader.row_count) : (i += 1) {
        const kv = try reader.readKey(i);
        try testing.expectEqualSlices(u8, rows[i].key, kv.key);
        try testing.expectEqual(rows[i].seq, kv.seq);
        try testing.expect(!kv.is_tombstone);
    }
}

test "block: tombstone row" {
    const alloc = testing.allocator;
    const data = try writeBlock(alloc, &.{
        .{ .key = "alive", .seq = 1, .value = "data" },
        .{ .key = "dead", .seq = 2, .value = null },
        .{ .key = "also_alive", .seq = 3, .value = "more" },
    });
    defer alloc.free(data);
    const reader = try storage.BlockReader.init(data);
    const kv0 = try reader.readKey(0);
    try testing.expect(!kv0.is_tombstone);
    const kv1 = try reader.readKey(1);
    try testing.expect(kv1.is_tombstone);
    const kv2 = try reader.readKey(2);
    try testing.expect(!kv2.is_tombstone);
}

test "block: all tombstones" {
    const alloc = testing.allocator;
    const data = try writeBlock(alloc, &.{
        .{ .key = "a", .seq = 1, .value = null },
        .{ .key = "b", .seq = 2, .value = null },
    });
    defer alloc.free(data);
    const reader = try storage.BlockReader.init(data);
    try testing.expectEqual(@as(u32, 2), reader.row_count);
    var i: u32 = 0;
    while (i < reader.row_count) : (i += 1) {
        const kv = try reader.readKey(i);
        try testing.expect(kv.is_tombstone);
    }
}

test "block: findKey exact match" {
    const alloc = testing.allocator;
    const data = try writeBlock(alloc, &.{
        .{ .key = "apple", .seq = 1, .value = "1" },
        .{ .key = "banana", .seq = 2, .value = "2" },
        .{ .key = "cherry", .seq = 3, .value = "3" },
    });
    defer alloc.free(data);
    const reader = try storage.BlockReader.init(data);
    try testing.expectEqual(@as(?u32, 0), try reader.findKey("apple"));
    try testing.expectEqual(@as(?u32, 1), try reader.findKey("banana"));
    try testing.expectEqual(@as(?u32, 2), try reader.findKey("cherry"));
}

test "block: findKey not found" {
    const alloc = testing.allocator;
    const data = try writeBlock(alloc, &.{
        .{ .key = "apple", .seq = 1, .value = "1" },
        .{ .key = "cherry", .seq = 3, .value = "3" },
    });
    defer alloc.free(data);
    const reader = try storage.BlockReader.init(data);
    try testing.expectEqual(@as(?u32, null), try reader.findKey("banana"));
    try testing.expectEqual(@as(?u32, null), try reader.findKey("zebra"));
}

test "block: lowerBound exact" {
    const alloc = testing.allocator;
    const data = try writeBlock(alloc, &.{
        .{ .key = "a", .seq = 1, .value = "1" },
        .{ .key = "c", .seq = 2, .value = "2" },
        .{ .key = "e", .seq = 3, .value = "3" },
    });
    defer alloc.free(data);
    const reader = try storage.BlockReader.init(data);
    try testing.expectEqual(@as(u32, 0), try reader.lowerBound("a"));
    try testing.expectEqual(@as(u32, 1), try reader.lowerBound("c"));
    try testing.expectEqual(@as(u32, 2), try reader.lowerBound("e"));
}

test "block: lowerBound between keys" {
    const alloc = testing.allocator;
    const data = try writeBlock(alloc, &.{
        .{ .key = "a", .seq = 1, .value = "1" },
        .{ .key = "c", .seq = 2, .value = "2" },
        .{ .key = "e", .seq = 3, .value = "3" },
    });
    defer alloc.free(data);
    const reader = try storage.BlockReader.init(data);
    try testing.expectEqual(@as(u32, 1), try reader.lowerBound("b"));
    try testing.expectEqual(@as(u32, 2), try reader.lowerBound("d"));
}

test "block: lowerBound before/after" {
    const alloc = testing.allocator;
    const data = try writeBlock(alloc, &.{
        .{ .key = "c", .seq = 1, .value = "1" },
        .{ .key = "e", .seq = 2, .value = "2" },
    });
    defer alloc.free(data);
    const reader = try storage.BlockReader.init(data);
    try testing.expectEqual(@as(u32, 0), try reader.lowerBound("a"));
    try testing.expectEqual(@as(u32, 2), try reader.lowerBound("z"));
}

test "block: isEmpty initially" {
    const alloc = testing.allocator;
    var writer = storage.BlockWriter.init(alloc);
    defer writer.deinit(alloc);
    try testing.expect(writer.isEmpty());
    try testing.expect(!writer.isFull());
}

test "block: isFull after many rows" {
    const alloc = testing.allocator;
    var writer = storage.BlockWriter.init(alloc);
    defer writer.deinit(alloc);
    var i: usize = 0;
    while (i < MAX_ROWS_PER_BLOCK) : (i += 1) {
        try writer.append(alloc, "k", @as(Seq, @intCast(i)), "v");
    }
    try testing.expect(writer.isFull());
}

test "block: CRC mismatch" {
    const alloc = testing.allocator;
    const data = try writeBlock(alloc, &.{ .{ .key = "key", .seq = 1, .value = "value" } });
    defer alloc.free(data);
    var corrupted = try alloc.dupe(u8, data);
    defer alloc.free(corrupted);
    corrupted[10] ^= 0xFF;
    const err = storage.BlockReader.init(corrupted);
    try testing.expectError(error.CrcMismatch, err);
}

test "block: invalid magic" {
    var buf: [HEADER_SIZE + FOOTER_SIZE]u8 = undefined;
    @memcpy(buf[0..4], &[_]u8{ 'B', 'A', 'D', '!' });
    const err = storage.BlockReader.init(&buf);
    try testing.expectError(error.InvalidMagic, err);
}

test "block: block too small" {
    var buf: [20]u8 = undefined;
    const err = storage.BlockReader.init(&buf);
    try testing.expectError(error.BlockTooSmall, err);
}

test "block: out-of-bounds" {
    const alloc = testing.allocator;
    const data = try writeBlock(alloc, &.{ .{ .key = "only", .seq = 1, .value = "row" } });
    defer alloc.free(data);
    const reader = try storage.BlockReader.init(data);
    try testing.expectError(error.OutOfBounds, reader.readKey(1));
    try testing.expectError(error.OutOfBounds, reader.readRow(1, alloc));
}
