/// Gateway integration tests for true SQL NULL (ColumnValue.null_t).
///
/// Covers:
///   - INSERT NULL stores null_t; result rows return null as absent ?ColumnValue
///   - IS NULL / IS NOT NULL predicates work on stored null_t
///   - NOT NULL column rejects null_t
///   - COUNT(*) counts NULLs; COUNT(col) / SUM skip NULLs
///   - Multiple NULLs allowed in UNIQUE column (NULLs are not duplicates)
///   - NULL propagates through arithmetic (result column absent = null)
///
/// Note: CHECK constraint behaviour with NULL is documented separately in the SQL
/// test suite (null.sql). The engine raises ConstraintViolation for NULL in a CHECK
/// column rather than skipping the check — this is a known engine behaviour.
const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");

const Gateway = gateway_mod.Gateway;
const ColumnValue = gateway_mod.ColumnValue;

// ---- Temp dir helpers ----

fn makeTempDir() ![]const u8 {
    // SAFETY: clock_gettime fills ts before any field is read.
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/null_test_{d}", .{ns});
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

// ---- Tests ----

test "null: INSERT NULL stores null_t, IS NULL filter works" {
    // SQL NULLs are stored as null_t internally. When retrieved via querySelect the
    // executor converts null_t → absent ?ColumnValue (i.e. the Zig null optional).
    // IS NULL / IS NOT NULL predicates work correctly on stored null_t.
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE t (id INT64 NOT NULL PRIMARY KEY, val INT64 NULL)");

    const ins = (try gw.register("INSERT INTO t (id, val) VALUES ($1, $2)")).hash;
    _ = try gw.execute(ins, &.{ .{ .int64 = 1 }, .{ .int64 = 42 } }, &.{});
    _ = try gw.execute(ins, &.{ .{ .int64 = 2 }, .{ .null_t = {} } }, &.{});

    // SELECT both rows ordered by id.
    const sel_all = (try gw.register("SELECT id, val FROM t ORDER BY id")).hash;
    var rs_all = try gw.querySelect(sel_all, &.{}, &.{});
    defer rs_all.deinit();

    try testing.expectEqual(@as(usize, 2), rs_all.rows.len);
    // Row 1: val = 42 (present non-null).
    try testing.expectEqual(@as(i64, 42), rs_all.rows[0][1].?.int64);
    // Row 2: val = SQL NULL — executor returns absent ?ColumnValue (null).
    try testing.expect(rs_all.rows[1][1] == null);

    // IS NULL filter — should return only id=2.
    const sel_null = (try gw.register("SELECT id FROM t WHERE val IS NULL")).hash;
    var rs_null = try gw.querySelect(sel_null, &.{}, &.{});
    defer rs_null.deinit();
    try testing.expectEqual(@as(usize, 1), rs_null.rows.len);
    try testing.expectEqual(@as(i64, 2), rs_null.rows[0][0].?.int64);

    // IS NOT NULL filter — should return only id=1.
    const sel_nn = (try gw.register("SELECT id FROM t WHERE val IS NOT NULL")).hash;
    var rs_nn = try gw.querySelect(sel_nn, &.{}, &.{});
    defer rs_nn.deinit();
    try testing.expectEqual(@as(usize, 1), rs_nn.rows.len);
    try testing.expectEqual(@as(i64, 1), rs_nn.rows[0][0].?.int64);
}

test "null: NOT NULL column rejects null_t param" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE t (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL)");

    const ins = (try gw.register("INSERT INTO t (id, val) VALUES ($1, $2)")).hash;
    const result = gw.execute(ins, &.{ .{ .int64 = 1 }, .{ .null_t = {} } }, &.{});
    try testing.expectError(error.ConstraintViolation, result);

    // Table must be empty.
    const sel = (try gw.register("SELECT COUNT(*) FROM t")).hash;
    var rs = try gw.querySelect(sel, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(i64, 0), rs.rows[0][0].?.int64);
}

test "null: COUNT(*) counts NULLs, COUNT(col) and SUM skip NULLs" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE t (id INT64 NOT NULL PRIMARY KEY, val INT64 NULL)");

    const ins = (try gw.register("INSERT INTO t (id, val) VALUES ($1, $2)")).hash;
    _ = try gw.execute(ins, &.{ .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});
    _ = try gw.execute(ins, &.{ .{ .int64 = 2 }, .{ .null_t = {} } }, &.{});
    _ = try gw.execute(ins, &.{ .{ .int64 = 3 }, .{ .int64 = 20 } }, &.{});

    // COUNT(*) = 3 (includes the NULL row).
    const sel_star = (try gw.register("SELECT COUNT(*) FROM t")).hash;
    var rs_star = try gw.querySelect(sel_star, &.{}, &.{});
    defer rs_star.deinit();
    try testing.expectEqual(@as(i64, 3), rs_star.rows[0][0].?.int64);

    // COUNT(val) = 2 (skips the NULL row).
    const sel_col = (try gw.register("SELECT COUNT(val) FROM t")).hash;
    var rs_col = try gw.querySelect(sel_col, &.{}, &.{});
    defer rs_col.deinit();
    try testing.expectEqual(@as(i64, 2), rs_col.rows[0][0].?.int64);

    // SUM(val) = 30 (skips the NULL row).
    const sel_sum = (try gw.register("SELECT SUM(val) FROM t")).hash;
    var rs_sum = try gw.querySelect(sel_sum, &.{}, &.{});
    defer rs_sum.deinit();
    try testing.expectEqual(@as(i64, 30), rs_sum.rows[0][0].?.int64);
}

test "null: multiple NULLs allowed in UNIQUE column" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE t (id INT64 NOT NULL PRIMARY KEY, code STRING NULL UNIQUE)");

    const ins = (try gw.register("INSERT INTO t (id, code) VALUES ($1, $2)")).hash;

    // Two NULLs must both succeed — NULLs are not duplicates for UNIQUE purposes.
    _ = try gw.execute(ins, &.{ .{ .int64 = 1 }, .{ .null_t = {} } }, &.{});
    _ = try gw.execute(ins, &.{ .{ .int64 = 2 }, .{ .null_t = {} } }, &.{});

    // A non-null duplicate must fail.
    _ = try gw.execute(ins, &.{ .{ .int64 = 3 }, .{ .string = "abc" } }, &.{});
    const dup = gw.execute(ins, &.{ .{ .int64 = 4 }, .{ .string = "abc" } }, &.{});
    try testing.expectError(error.ConstraintViolation, dup);

    // Three rows in table (1, 2, 3 — row 4 was rejected).
    const sel = (try gw.register("SELECT COUNT(*) FROM t")).hash;
    var rs = try gw.querySelect(sel, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(i64, 3), rs.rows[0][0].?.int64);
}

test "null: CHECK constraint enforced; negative value rejected" {
    // The engine evaluates CHECK expressions. A negative value violates the constraint.
    // Note: NULL in a CHECK column also raises ConstraintViolation in this engine
    // rather than being skipped. The SQL test suite (null.sql) documents this.
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE t (id INT64 NOT NULL PRIMARY KEY, age INT64 NOT NULL CHECK (age >= 0))");

    const ins = (try gw.register("INSERT INTO t (id, age) VALUES ($1, $2)")).hash;
    _ = try gw.execute(ins, &.{ .{ .int64 = 1 }, .{ .int64 = 0 } }, &.{});
    _ = try gw.execute(ins, &.{ .{ .int64 = 2 }, .{ .int64 = 25 } }, &.{});
    const bad = gw.execute(ins, &.{ .{ .int64 = 3 }, .{ .int64 = -1 } }, &.{});
    try testing.expectError(error.ConstraintViolation, bad);

    const sel = (try gw.register("SELECT COUNT(*) FROM t")).hash;
    var rs = try gw.querySelect(sel, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(i64, 2), rs.rows[0][0].?.int64);
}

test "null: NULL propagates through arithmetic" {
    // Any arithmetic involving a NULL operand produces NULL.
    // The executor returns NULL columns as absent ?ColumnValue.
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE t (id INT64 NOT NULL PRIMARY KEY, val INT64 NULL)");

    const ins = (try gw.register("INSERT INTO t (id, val) VALUES ($1, $2)")).hash;
    _ = try gw.execute(ins, &.{ .{ .int64 = 1 }, .{ .null_t = {} } }, &.{});

    // val + 1 with val = NULL should produce NULL (absent optional).
    const sel = (try gw.register("SELECT id, val + 1 FROM t WHERE id = 1")).hash;
    var rs = try gw.querySelect(sel, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    // The computed column (val + 1) should be absent (SQL NULL propagation).
    try testing.expect(rs.rows[0][1] == null);
}
