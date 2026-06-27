const std = @import("std");
const testing = std.testing;
const storage = @import("storage.zig");

const LSM = storage.LSM;
const Mutation = storage.Mutation;
const KeyRange = storage.KeyRange;
const Seq = storage.Seq;

test "lsm: apply and get" {
    const alloc = testing.allocator;
    const path = "/tmp/foldb_lsm_1";
    var lsm = try LSM.init(path, alloc);
    defer lsm.deinit();

    const mutations = [_]Mutation{
        .{ .kind = .insert, .table_id = 1, .key = "key1", .value = "val1" },
        .{ .kind = .insert, .table_id = 1, .key = "key2", .value = "val2" },
    };
    try lsm.apply(&mutations, 1);

    const r = try lsm.get("key1", 1);
    try testing.expect(r != null);
    var row = r.?;
    defer row.deinit(alloc);
    try testing.expectEqualSlices(u8, "val1", row.value);
}

test "lsm: delete" {
    const alloc = testing.allocator;
    const path = "/tmp/foldb_lsm_2";
    var lsm = try LSM.init(path, alloc);
    defer lsm.deinit();

    try lsm.apply(&[_]Mutation{.{ .kind = .insert, .table_id = 1, .key = "k", .value = "v" }}, 1);
    try lsm.apply(&[_]Mutation{.{ .kind = .delete, .table_id = 1, .key = "k", .value = null }}, 2);
    const r = try lsm.get("k", 2);
    try testing.expect(r == null);
}

test "lsm: many inserts" {
    const alloc = testing.allocator;
    const path = "/tmp/foldb_lsm_3";
    var lsm = try LSM.init(path, alloc);
    defer lsm.deinit();

    var i: Seq = 1;
    while (i <= 200) : (i += 1) {
        var buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "k_{d:03}", .{i}) catch unreachable;
        try lsm.apply(&[_]Mutation{.{ .kind = .insert, .table_id = 1, .key = key, .value = "v" }}, i);
    }
    {
        const r1 = try lsm.get("k_001", 200);
        try testing.expect(r1 != null);
        if (r1) |r| r.deinit(alloc);
    }
    {
        const r2 = try lsm.get("k_100", 200);
        try testing.expect(r2 != null);
        if (r2) |r| r.deinit(alloc);
    }
    {
        const r3 = try lsm.get("k_200", 200);
        try testing.expect(r3 != null);
        if (r3) |r| r.deinit(alloc);
    }
}

test "lsm: scan" {
    const alloc = testing.allocator;
    const path = "/tmp/foldb_lsm_4";
    var lsm = try LSM.init(path, alloc);
    defer lsm.deinit();

    var i: Seq = 1;
    const keys = [_][]const u8{ "a", "b", "c", "d", "e" };
    for (keys) |k| {
        try lsm.apply(&[_]Mutation{.{ .kind = .insert, .table_id = 1, .key = k, .value = "v" }}, i);
        i += 1;
    }

    const range = KeyRange{ .start = "b", .end = "d", .start_inclusive = true };
    const rows = try lsm.scan(range, i - 1, alloc);
    defer {
        for (rows) |r| r.deinit(alloc);
        alloc.free(rows);
    }
    try testing.expect(rows.len >= 2);
}

test "lsm: scan suppresses tombstoned keys across memtable and sstables" {
    const alloc = testing.allocator;
    const path = "/tmp/foldb_lsm_tombstone_range";
    var lsm = try LSM.init(path, alloc);
    defer lsm.deinit();

    try lsm.apply(&[_]Mutation{
        .{ .kind = .insert, .table_id = 1, .key = "a", .value = "one" },
        .{ .kind = .insert, .table_id = 1, .key = "b", .value = "two" },
        .{ .kind = .insert, .table_id = 1, .key = "c", .value = "three" },
    }, 1);
    try lsm.flushMemtable();
    try lsm.apply(&[_]Mutation{
        .{ .kind = .delete, .table_id = 1, .key = "b", .value = null },
    }, 2);

    const rows = try lsm.scan(KeyRange.all(), 2, alloc);
    defer {
        for (rows) |r| r.deinit(alloc);
        alloc.free(rows);
    }

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("a", rows[0].key);
    try testing.expectEqualStrings("c", rows[1].key);
}

test "lsm: natural string keys do not require insertion-order padding" {
    const alloc = testing.allocator;
    const path = "/tmp/foldb_lsm_natural_string_keys";
    var lsm = try LSM.init(path, alloc);
    defer lsm.deinit();

    const keys = [_][]const u8{ "bench:1", "bench:10", "bench:100", "bench:2" };
    for (keys, 1..) |key, seq| {
        const value = try std.fmt.allocPrint(alloc, "v{d}", .{seq});
        defer alloc.free(value);
        try lsm.apply(&[_]Mutation{.{ .kind = .insert, .table_id = 1, .key = key, .value = value }}, @intCast(seq));
    }

    {
        const row = try lsm.get("bench:100", 4);
        try testing.expect(row != null);
        var r = row.?;
        defer r.deinit(alloc);
        try testing.expectEqualStrings("v3", r.value);
    }

    const rows = try lsm.scan(KeyRange{ .start = "bench:", .end = "bench;", .start_inclusive = true }, 4, alloc);
    defer {
        for (rows) |r| r.deinit(alloc);
        alloc.free(rows);
    }
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expectEqualStrings("bench:1", rows[0].key);
    try testing.expectEqualStrings("bench:10", rows[1].key);
    try testing.expectEqualStrings("bench:100", rows[2].key);
    try testing.expectEqualStrings("bench:2", rows[3].key);

    try lsm.flushMemtable();
    const flushed = try lsm.get("bench:10", 4);
    try testing.expect(flushed != null);
    var flushed_row = flushed.?;
    defer flushed_row.deinit(alloc);
    try testing.expectEqualStrings("v2", flushed_row.value);
}
