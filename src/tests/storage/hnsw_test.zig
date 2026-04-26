const std = @import("std");
const storage = @import("storage.zig");

const Storage = storage.Storage;
const Mutation = storage.Mutation;
const ColumnValue = storage.ColumnValue;

fn makeTempDir(alloc: std.mem.Allocator) ![]u8 {
    // SAFETY: clock_gettime fills ts before any field is read.
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const path = try std.fmt.allocPrint(alloc, "/tmp/foldb_hnsw_test_{d}", .{ns});
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

fn encodeVec(vec: []const f32, alloc: std.mem.Allocator) ![]u8 {
    return storage.vector_codec.encode(vec, alloc);
}

test "hnsw insert and exact search" {
    const alloc = std.testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer rmDir(dir, alloc);

    var stor = try Storage.init(dir, alloc);
    defer stor.deinit();

    // Base table: 1 column (VECTOR stored as bytes)
    try stor.registerTable(.{
        .table_id = 1,
        .columns = &.{.{ .col_type = .bytes, .nullable = false }},
    });

    // Register HNSW vector index, dim=4
    try stor.registerIndex(.{
        .id = 200,
        .table_id = 1,
        .column_idx = 0,
        .spec = .{ .vector = 4 },
    });

    // Insert three 4-d vectors
    const v1: []const f32 = &.{ 1.0, 0.0, 0.0, 0.0 };
    const v2: []const f32 = &.{ 0.0, 1.0, 0.0, 0.0 };
    const v3: []const f32 = &.{ 0.0, 0.0, 1.0, 0.0 };

    const b1 = try encodeVec(v1, alloc);
    defer alloc.free(b1);
    const b2 = try encodeVec(v2, alloc);
    defer alloc.free(b2);
    const b3 = try encodeVec(v3, alloc);
    defer alloc.free(b3);

    try stor.apply(&.{Mutation{ .kind = .insert, .table_id = 1, .key = "a", .values = &.{ColumnValue{ .bytes = b1 }} }}, 1);
    try stor.apply(&.{Mutation{ .kind = .insert, .table_id = 1, .key = "b", .values = &.{ColumnValue{ .bytes = b2 }} }}, 2);
    try stor.apply(&.{Mutation{ .kind = .insert, .table_id = 1, .key = "c", .values = &.{ColumnValue{ .bytes = b3 }} }}, 3);

    // Search for nearest to v1: should return "a" first
    const query: []const f32 = &.{ 1.0, 0.0, 0.0, 0.0 };
    const matches = try stor.vectorSearch(200, query, 1, 4, alloc);
    defer {
        for (matches) |m| alloc.free(m.pk);
        alloc.free(matches);
    }

    try std.testing.expect(matches.len >= 1);
    try std.testing.expectEqualStrings("a", matches[0].pk);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), matches[0].distance, 1e-5);
}

test "hnsw delete excludes tombstoned vectors" {
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

    try stor.registerIndex(.{
        .id = 201,
        .table_id = 1,
        .column_idx = 0,
        .spec = .{ .vector = 2 },
    });

    const va: []const f32 = &.{ 1.0, 0.0 };
    const vb: []const f32 = &.{ 0.0, 1.0 };

    const ba = try encodeVec(va, alloc);
    defer alloc.free(ba);
    const bb = try encodeVec(vb, alloc);
    defer alloc.free(bb);

    try stor.apply(&.{Mutation{ .kind = .insert, .table_id = 1, .key = "a", .values = &.{ColumnValue{ .bytes = ba }} }}, 1);
    try stor.apply(&.{Mutation{ .kind = .insert, .table_id = 1, .key = "b", .values = &.{ColumnValue{ .bytes = bb }} }}, 2);

    // Delete "a"
    try stor.apply(&.{Mutation{ .kind = .delete, .table_id = 1, .key = "a", .values = null }}, 3);

    // Search near [1,0]: "a" is deleted, should return "b"
    const query: []const f32 = &.{ 1.0, 0.0 };
    const matches = try stor.vectorSearch(201, query, 2, 4, alloc);
    defer {
        for (matches) |m| alloc.free(m.pk);
        alloc.free(matches);
    }

    for (matches) |m| {
        try std.testing.expect(!std.mem.eql(u8, "a", m.pk));
    }
}

test "hnsw at_seq hides insertions newer than query seq" {
    const alloc = std.testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer rmDir(dir, alloc);

    var stor = try Storage.init(dir, alloc);
    defer stor.deinit();

    try stor.registerTable(.{ .table_id = 1, .columns = &.{.{ .col_type = .bytes, .nullable = false }} });
    try stor.registerIndex(.{ .id = 203, .table_id = 1, .column_idx = 0, .spec = .{ .vector = 2 } });

    const v: []const f32 = &.{ 1.0, 0.0 };
    const bv = try encodeVec(v, alloc);
    defer alloc.free(bv);

    // Inserted at seq=10, search at seq=5 — must not appear
    try stor.apply(&.{Mutation{ .kind = .insert, .table_id = 1, .key = "future", .values = &.{ColumnValue{ .bytes = bv }} }}, 10);

    const query: []const f32 = &.{ 1.0, 0.0 };
    const matches = try stor.vectorSearch(203, query, 5, 5, alloc);
    defer {
        for (matches) |m| alloc.free(m.pk);
        alloc.free(matches);
    }
    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "hnsw at_seq sees insertion at or before query seq" {
    const alloc = std.testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer rmDir(dir, alloc);

    var stor = try Storage.init(dir, alloc);
    defer stor.deinit();

    try stor.registerTable(.{ .table_id = 1, .columns = &.{.{ .col_type = .bytes, .nullable = false }} });
    try stor.registerIndex(.{ .id = 204, .table_id = 1, .column_idx = 0, .spec = .{ .vector = 2 } });

    const v: []const f32 = &.{ 1.0, 0.0 };
    const bv = try encodeVec(v, alloc);
    defer alloc.free(bv);

    // Inserted at seq=3, search at seq=5 — must appear
    try stor.apply(&.{Mutation{ .kind = .insert, .table_id = 1, .key = "visible", .values = &.{ColumnValue{ .bytes = bv }} }}, 3);

    const query: []const f32 = &.{ 1.0, 0.0 };
    const matches = try stor.vectorSearch(204, query, 5, 5, alloc);
    defer {
        for (matches) |m| alloc.free(m.pk);
        alloc.free(matches);
    }
    try std.testing.expect(matches.len >= 1);
    try std.testing.expectEqualStrings("visible", matches[0].pk);
}

test "hnsw pruneDeleted preserves correct search results" {
    const alloc = std.testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer rmDir(dir, alloc);

    var stor = try Storage.init(dir, alloc);
    defer stor.deinit();

    try stor.registerTable(.{ .table_id = 1, .columns = &.{.{ .col_type = .bytes, .nullable = false }} });
    try stor.registerIndex(.{ .id = 205, .table_id = 1, .column_idx = 0, .spec = .{ .vector = 3 } });

    const va: []const f32 = &.{ 1.0, 0.0, 0.0 };
    const vb: []const f32 = &.{ 0.0, 1.0, 0.0 };
    const vc: []const f32 = &.{ 0.0, 0.0, 1.0 };

    const ba = try encodeVec(va, alloc);
    defer alloc.free(ba);
    const bb = try encodeVec(vb, alloc);
    defer alloc.free(bb);
    const bc = try encodeVec(vc, alloc);
    defer alloc.free(bc);

    try stor.apply(&.{Mutation{ .kind = .insert, .table_id = 1, .key = "a", .values = &.{ColumnValue{ .bytes = ba }} }}, 1);
    try stor.apply(&.{Mutation{ .kind = .insert, .table_id = 1, .key = "b", .values = &.{ColumnValue{ .bytes = bb }} }}, 2);
    try stor.apply(&.{Mutation{ .kind = .insert, .table_id = 1, .key = "c", .values = &.{ColumnValue{ .bytes = bc }} }}, 3);
    try stor.apply(&.{Mutation{ .kind = .delete, .table_id = 1, .key = "a", .values = null }}, 4);

    try stor.pruneVectorIndexes();

    // After pruning: "a" is gone, "b" and "c" remain with intact neighbor links
    const query: []const f32 = &.{ 1.0, 0.0, 0.0 };
    const matches = try stor.vectorSearch(205, query, 3, 10, alloc);
    defer {
        for (matches) |m| alloc.free(m.pk);
        alloc.free(matches);
    }
    for (matches) |m| {
        try std.testing.expect(!std.mem.eql(u8, "a", m.pk));
    }
    try std.testing.expect(matches.len >= 1);
}

test "hnsw search empty index returns empty" {
    const alloc = std.testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer rmDir(dir, alloc);

    var stor = try Storage.init(dir, alloc);
    defer stor.deinit();

    try stor.registerTable(.{ .table_id = 1, .columns = &.{.{ .col_type = .bytes, .nullable = false }} });
    try stor.registerIndex(.{ .id = 202, .table_id = 1, .column_idx = 0, .spec = .{ .vector = 3 } });

    const query: []const f32 = &.{ 1.0, 0.0, 0.0 };
    const matches = try stor.vectorSearch(202, query, 5, 4, alloc);
    defer {
        for (matches) |m| alloc.free(m.pk);
        alloc.free(matches);
    }
    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "PartitionedStorage.vectorSearch merges results from multiple partitions" {
    const alloc = std.testing.allocator;

    const dir0 = try makeTempDir(alloc);
    defer alloc.free(dir0);
    defer rmDir(dir0, alloc);
    const dir1 = try makeTempDir(alloc);
    defer alloc.free(dir1);
    defer rmDir(dir1, alloc);

    var s0 = try Storage.init(dir0, alloc);
    defer s0.deinit();
    var s1 = try Storage.init(dir1, alloc);
    defer s1.deinit();

    const schema = storage.TableSchema{
        .table_id = 1,
        .columns = &.{.{ .col_type = .bytes, .nullable = false }},
    };
    const idx_desc = storage.IndexDesc{
        .id = 300,
        .table_id = 1,
        .column_idx = 0,
        .spec = .{ .vector = 4 },
    };
    try s0.registerTable(schema);
    try s0.registerIndex(idx_desc);
    try s1.registerTable(schema);
    try s1.registerIndex(idx_desc);

    // Partition 0 holds a vector near the x-axis; partition 1 holds one near the y-axis.
    const vx: []const f32 = &.{ 1.0, 0.0, 0.0, 0.0 };
    const vy: []const f32 = &.{ 0.0, 1.0, 0.0, 0.0 };
    const bx = try encodeVec(vx, alloc);
    defer alloc.free(bx);
    const by = try encodeVec(vy, alloc);
    defer alloc.free(by);

    try s0.apply(&.{.{ .kind = .insert, .table_id = 1, .key = "p0", .values = &.{.{ .bytes = bx }} }}, 1);
    try s1.apply(&.{.{ .kind = .insert, .table_id = 1, .key = "p1", .values = &.{.{ .bytes = by }} }}, 1);

    var parts = [_]*Storage{ &s0, &s1 };
    var ps = storage.PartitionedStorage{ .partitions = &parts, .alloc = alloc };

    // Query near x-axis with k=2 — should get both results, x-axis entry first.
    const matches = try ps.vectorSearch(300, vx, 2, 1, alloc);
    defer {
        for (matches) |m| alloc.free(m.pk);
        alloc.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("p0", matches[0].pk);
    try std.testing.expect(matches[0].distance < matches[1].distance);
}
