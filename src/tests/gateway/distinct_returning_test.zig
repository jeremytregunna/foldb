/// Gateway integration tests for SELECT DISTINCT and RETURNING clause.
const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");

const Gateway = gateway_mod.Gateway;
const ColumnValue = gateway_mod.ColumnValue;

fn makeTempDir() ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/dr_test_{d}", .{ns});
}

fn removeDirRecursive(path: []const u8) void {
    const z = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(z);
    @memcpy(z[0..path.len], path);
    const raw_fd = std.os.linux.open(z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return;
    const fd: std.posix.fd_t = @intCast(fd_i);
    defer _ = std.os.linux.close(@intCast(fd));
    var buf: [4096]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    while (true) {
        const ret = std.os.linux.getdents64(@intCast(fd), &buf, buf.len);
        const n: isize = @bitCast(ret);
        if (n <= 0) break;
        var i: usize = 0;
        while (i < @as(usize, @intCast(n))) {
            const dent: *const std.os.linux.dirent64 = @ptrCast(@alignCast(buf[i..].ptr));
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&dent.name)));
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                const child = std.mem.concat(std.heap.page_allocator, u8, &.{ path, "/", name }) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(child);
                const cz = std.heap.page_allocator.allocSentinel(u8, child.len, 0) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(cz);
                @memcpy(cz[0..child.len], child);
                if (dent.type == std.os.linux.DT.DIR) removeDirRecursive(child) else _ = std.os.linux.unlink(cz.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}

const TAGS_DDL = "CREATE TABLE tags (id INT64 NOT NULL, item_id INT64 NOT NULL, tag INT64 NOT NULL, PRIMARY KEY (id))";

fn setupGateway() !struct { gw: *Gateway, dir: []const u8 } {
    const dir = try makeTempDir();
    const gw = try Gateway.init(dir, testing.allocator, .{});
    try gw.applyDdl(TAGS_DDL);

    const ins = (try gw.register("INSERT INTO tags (id, item_id, tag) VALUES ($1, $2, $3)")).hash;
    // item_id=1 appears with tag=10, tag=20, tag=10 (duplicate tag for item 1)
    _ = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});
    _ = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 2 }, .{ .int64 = 1 }, .{ .int64 = 20 } }, &.{});
    _ = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 3 }, .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});
    // item_id=2 with tag=30
    _ = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 4 }, .{ .int64 = 2 }, .{ .int64 = 30 } }, &.{});

    return .{ .gw = gw, .dir = dir };
}

// ---- SELECT DISTINCT ----

test "distinct: SELECT DISTINCT deduplicates rows" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    const q = (try s.gw.register("SELECT DISTINCT item_id FROM tags")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // item_id=1 and item_id=2 — exactly 2 distinct values
    try testing.expectEqual(@as(usize, 2), rs.rows.len);
}

test "distinct: SELECT DISTINCT on single column with all unique values returns same count" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    const q = (try s.gw.register("SELECT DISTINCT id FROM tags")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // id is primary key — all 4 are unique
    try testing.expectEqual(@as(usize, 4), rs.rows.len);
}

test "distinct: SELECT DISTINCT on multi-column tuple" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    const q = (try s.gw.register("SELECT DISTINCT item_id, tag FROM tags")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // (1,10), (1,20), (2,30) — 3 distinct (item_id=1,tag=10 deduplicated)
    try testing.expectEqual(@as(usize, 3), rs.rows.len);
}

test "distinct: SELECT without DISTINCT returns all rows including duplicates" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    const q = (try s.gw.register("SELECT item_id FROM tags")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // 4 rows total
    try testing.expectEqual(@as(usize, 4), rs.rows.len);
}

// ---- RETURNING ----

test "returning: INSERT RETURNING returns the inserted row values" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();
    try gw.applyDdl(TAGS_DDL);

    const ins = (try gw.register("INSERT INTO tags (id, item_id, tag) VALUES ($1, $2, $3) RETURNING id, tag")).hash;
    const result = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 7 }, .{ .int64 = 99 }, .{ .int64 = 42 } }, &.{});
    try testing.expectEqual(@as(u64, 1), result.rows_affected);
    try testing.expect(result.result_set != null);

    var rs = result.result_set.?;
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(i64, 7), rs.rows[0][0].?.int64); // id
    try testing.expectEqual(@as(i64, 42), rs.rows[0][1].?.int64); // tag
}

test "returning: INSERT without RETURNING returns null result_set" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();
    try gw.applyDdl(TAGS_DDL);

    const ins = (try gw.register("INSERT INTO tags (id, item_id, tag) VALUES ($1, $2, $3)")).hash;
    const result = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 2 }, .{ .int64 = 3 } }, &.{});
    try testing.expect(result.result_set == null);
}

test "returning: UPDATE RETURNING returns updated row values" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();
    try gw.applyDdl(TAGS_DDL);

    const ins = (try gw.register("INSERT INTO tags (id, item_id, tag) VALUES ($1, $2, $3)")).hash;
    _ = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 5 }, .{ .int64 = 10 } }, &.{});

    const upd = (try gw.register("UPDATE tags SET tag = 99 WHERE id = 1 RETURNING id, tag")).hash;
    const result = try gw.execute(std.testing.io, upd, &.{}, &.{});
    try testing.expectEqual(@as(u64, 1), result.rows_affected);
    try testing.expect(result.result_set != null);

    var rs = result.result_set.?;
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(i64, 1), rs.rows[0][0].?.int64); // id
    try testing.expectEqual(@as(i64, 99), rs.rows[0][1].?.int64); // tag (new value)
}

test "returning: DELETE RETURNING returns the deleted row values" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();
    try gw.applyDdl(TAGS_DDL);

    const ins = (try gw.register("INSERT INTO tags (id, item_id, tag) VALUES ($1, $2, $3)")).hash;
    _ = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 5 }, .{ .int64 = 77 } }, &.{});

    const del = (try gw.register("DELETE FROM tags WHERE id = 1 RETURNING id, tag")).hash;
    const result = try gw.execute(std.testing.io, del, &.{}, &.{});
    try testing.expectEqual(@as(u64, 1), result.rows_affected);
    try testing.expect(result.result_set != null);

    var rs = result.result_set.?;
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(i64, 1), rs.rows[0][0].?.int64); // id
    try testing.expectEqual(@as(i64, 77), rs.rows[0][1].?.int64); // tag
}

test "returning: RETURNING column names match aliases" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();
    try gw.applyDdl(TAGS_DDL);

    const ins = (try gw.register("INSERT INTO tags (id, item_id, tag) VALUES ($1, $2, $3) RETURNING id AS row_id, tag AS t")).hash;
    const result = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 5 }, .{ .int64 = 9 }, .{ .int64 = 3 } }, &.{});
    defer {
        var opt_rs = result.result_set;
        if (opt_rs) |*rs| rs.deinit();
    }
    try testing.expect(result.result_set != null);
    const rs = result.result_set.?;
    try testing.expectEqualStrings("row_id", rs.columns[0]);
    try testing.expectEqualStrings("t", rs.columns[1]);
}

// ---- DISTINCT with NULL values ----

test "distinct: SELECT DISTINCT treats two NULLs as equal (deduplicates them)" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();
    try gw.applyDdl("CREATE TABLE nullable_tbl (id INT64 NOT NULL, v INT64, PRIMARY KEY (id))");

    const ins = (try gw.register("INSERT INTO nullable_tbl (id, v) VALUES ($1, $2)")).hash;
    _ = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});
    _ = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 2 }, .{ .int64 = 10 } }, &.{});
    _ = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 3 }, .{ .int64 = 20 } }, &.{});

    const q = (try gw.register("SELECT DISTINCT v FROM nullable_tbl")).hash;
    var rs = try gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    // v=10 appears twice, v=20 once → 2 distinct values
    try testing.expectEqual(@as(usize, 2), rs.rows.len);
}

test "distinct: SELECT DISTINCT on empty table returns no rows" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();
    try gw.applyDdl(TAGS_DDL);

    const q = (try gw.register("SELECT DISTINCT item_id FROM tags")).hash;
    var rs = try gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 0), rs.rows.len);
}

// ---- RETURNING with multiple affected rows ----

test "returning: UPDATE affecting multiple rows returns all updated rows" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();
    try gw.applyDdl(TAGS_DDL);

    const ins = (try gw.register("INSERT INTO tags (id, item_id, tag) VALUES ($1, $2, $3)")).hash;
    _ = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 1 }, .{ .int64 = 5 } }, &.{});
    _ = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 2 }, .{ .int64 = 1 }, .{ .int64 = 5 } }, &.{});
    _ = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 3 }, .{ .int64 = 2 }, .{ .int64 = 5 } }, &.{});

    const upd = (try gw.register("UPDATE tags SET tag = 99 WHERE item_id = 1 RETURNING id")).hash;
    const result = try gw.execute(std.testing.io, upd, &.{}, &.{});
    try testing.expectEqual(@as(u64, 2), result.rows_affected);
    try testing.expect(result.result_set != null);
    var rs = result.result_set.?;
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 2), rs.rows.len);
}

test "returning: DELETE affecting multiple rows returns all deleted rows" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();
    try gw.applyDdl(TAGS_DDL);

    const ins = (try gw.register("INSERT INTO tags (id, item_id, tag) VALUES ($1, $2, $3)")).hash;
    _ = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 7 }, .{ .int64 = 1 } }, &.{});
    _ = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 2 }, .{ .int64 = 7 }, .{ .int64 = 2 } }, &.{});

    const del = (try gw.register("DELETE FROM tags WHERE item_id = 7 RETURNING id, tag")).hash;
    const result = try gw.execute(std.testing.io, del, &.{}, &.{});
    try testing.expectEqual(@as(u64, 2), result.rows_affected);
    try testing.expect(result.result_set != null);
    var rs = result.result_set.?;
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 2), rs.rows.len);
}
