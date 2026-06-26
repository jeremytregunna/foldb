const std = @import("std");
const testing = std.testing;
const storage = @import("storage.zig");

const SSTableWriter = storage.SSTableWriter;
const SSTableReader = storage.SSTableReader;
const Row = storage.Row;

test "sstable: create and read back" {
    const alloc = testing.allocator;
    const path = "/tmp/foldb_sst_test";
    var writer = try SSTableWriter.create(path, 0, alloc);
    defer writer.deinit();
    try writer.append("a", 1, "1");
    try writer.append("b", 2, "2");
    try writer.append("c", 3, "3");
    try writer.finish();

    var reader = try SSTableReader.open(path, alloc);
    defer reader.deinit();

    const r1 = try reader.get("a", 3);
    try testing.expect(r1 != null);
    if (r1) |row| row.deinit(alloc);

    const r2 = try reader.get("z", 3);
    try testing.expect(r2 == null);
}

test "sstable: meta info" {
    const alloc = testing.allocator;
    const path = "/tmp/foldb_sst_meta";
    var writer = try SSTableWriter.create(path, 1, alloc);
    defer writer.deinit();
    try writer.append("x", 10, "v1");
    try writer.append("y", 11, "v2");
    try writer.finish();

    var reader = try SSTableReader.open(path, alloc);
    defer reader.deinit();
    try testing.expectEqual(@as(u8, 1), reader.header.level);
    try testing.expectEqual(@as(u64, 10), reader.header.seq_min);
    try testing.expectEqual(@as(u64, 11), reader.header.seq_max);
}

test "sstable: many rows" {
    const alloc = testing.allocator;
    const path = "/tmp/foldb_sst_many";
    var writer = try SSTableWriter.create(path, 0, alloc);
    defer writer.deinit();
    var i: u64 = 0;
    while (i < 600) : (i += 1) {
        var key_buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key_{d:04}", .{i}) catch unreachable;
        try writer.append(key, i, "v");
    }
    try writer.finish();

    var reader = try SSTableReader.open(path, alloc);
    defer reader.deinit();

    const r = try reader.get("key_0000", 600);
    try testing.expect(r != null);
    if (r) |row| row.deinit(alloc);

    { const r2 = try reader.get("key_0300", 600); try testing.expect(r2 != null); if (r2) |row| row.deinit(alloc); }
    { const r3 = try reader.get("key_0599", 600); try testing.expect(r3 != null); if (r3) |row| row.deinit(alloc); }
}
