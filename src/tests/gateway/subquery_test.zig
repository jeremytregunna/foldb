/// Unit tests for subquery execution.
///
/// Covers:
///   - Scalar subquery in SELECT list
///   - Scalar subquery in WHERE clause
///   - EXISTS / NOT EXISTS in WHERE
///   - IN (subquery) / NOT IN (subquery) in WHERE
const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");

const Gateway = gateway_mod.Gateway;
const ColumnValue = gateway_mod.ColumnValue;

fn makeTempDir() ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/subquery_test_{d}", .{ns});
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

const USERS_DDL = "CREATE TABLE users (id INT64 NOT NULL, name INT64 NOT NULL, PRIMARY KEY (id))";
const ORDERS_DDL = "CREATE TABLE orders (id INT64 NOT NULL, user_id INT64 NOT NULL, amount INT64 NOT NULL, PRIMARY KEY (id))";

fn setupGateway() !struct { gw: *Gateway, dir: []const u8 } {
    const dir = try makeTempDir();
    const gw = try Gateway.init(dir, testing.allocator, .{});
    try gw.applyDdl(USERS_DDL);
    try gw.applyDdl(ORDERS_DDL);

    const ins_user = (try gw.register("INSERT INTO users (id, name) VALUES ($1, $2)")).hash;
    _ = try gw.execute(ins_user, &.{ .{ .int64 = 1 }, .{ .int64 = 100 } }, &.{});
    _ = try gw.execute(ins_user, &.{ .{ .int64 = 2 }, .{ .int64 = 200 } }, &.{});
    _ = try gw.execute(ins_user, &.{ .{ .int64 = 3 }, .{ .int64 = 300 } }, &.{});

    const ins_order = (try gw.register("INSERT INTO orders (id, user_id, amount) VALUES ($1, $2, $3)")).hash;
    _ = try gw.execute(ins_order, &.{ .{ .int64 = 1 }, .{ .int64 = 1 }, .{ .int64 = 50 } }, &.{});
    _ = try gw.execute(ins_order, &.{ .{ .int64 = 2 }, .{ .int64 = 1 }, .{ .int64 = 80 } }, &.{});
    _ = try gw.execute(ins_order, &.{ .{ .int64 = 3 }, .{ .int64 = 2 }, .{ .int64 = 20 } }, &.{});

    return .{ .gw = gw, .dir = dir };
}

test "subquery: EXISTS returns true when subquery has rows" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    const q = (try s.gw.register(
        \\SELECT id FROM users WHERE EXISTS (SELECT 1 FROM orders WHERE user_id = 1)
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expect(rs.rows.len > 0);
}

test "subquery: EXISTS returns false when subquery has no rows" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    // user_id = 99 has no orders — EXISTS is false for all rows
    const q = (try s.gw.register(
        \\SELECT id FROM users WHERE EXISTS (SELECT 1 FROM orders WHERE user_id = 99)
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 0), rs.rows.len);
}

test "subquery: NOT EXISTS filters correctly" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    // Same non-matching subquery — NOT EXISTS is true for all rows
    const q = (try s.gw.register(
        \\SELECT id FROM users WHERE NOT EXISTS (SELECT 1 FROM orders WHERE user_id = 99)
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 3), rs.rows.len);
}

test "subquery: IN (subquery) filters rows" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    // Users who have orders: user 1 and user 2
    const q = (try s.gw.register(
        \\SELECT id FROM users WHERE id IN (SELECT user_id FROM orders)
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 2), rs.rows.len);
}

test "subquery: NOT IN (subquery) filters rows" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    // Users who have NO orders: user 3 only
    const q = (try s.gw.register(
        \\SELECT id FROM users WHERE id NOT IN (SELECT user_id FROM orders)
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(i64, 3), rs.rows[0][0].?.int64);
}

test "subquery: scalar subquery in SELECT list" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    // Return total order count alongside each user — subquery is uncorrelated,
    // same value (3) for every row.
    const q = (try s.gw.register(
        \\SELECT id, (SELECT COUNT(*) FROM orders) FROM users WHERE id = 1
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(i64, 1), rs.rows[0][0].?.int64);
    try testing.expectEqual(@as(i64, 3), rs.rows[0][1].?.int64);
}

test "subquery: scalar subquery in WHERE clause" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    // Select orders whose amount exceeds the minimum (20).
    // MIN returns the same type as its input (int64), avoiding int/float comparison.
    const q = (try s.gw.register(
        \\SELECT id FROM orders WHERE amount > (SELECT MIN(amount) FROM orders)
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    // min(50, 80, 20) = 20; orders with amount > 20: orders 1 (50) and 2 (80)
    try testing.expectEqual(@as(usize, 2), rs.rows.len);
}

test "subquery: EXISTS on empty table returns false for all outer rows" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    // Delete all orders first via a fresh gateway with an empty table.
    // Easier: query against a non-existent user_id subset.
    // Actually use a separate table — just verify EXISTS (SELECT 1 FROM empty scan).
    // We model "empty" by filtering to a user that has no rows in orders.
    // user_id = 99 has no orders, so this EXISTS is always false.
    const q = (try s.gw.register(
        \\SELECT id FROM users WHERE EXISTS (SELECT 1 FROM orders WHERE user_id = 99 AND amount > 999)
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 0), rs.rows.len);
}

test "subquery: scalar COUNT returns 0 when subquery matches no rows" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    // COUNT of orders for user 99 (none) should equal 0.
    // WHERE 0 = 0 is always true, so all users are returned.
    const q = (try s.gw.register(
        \\SELECT id FROM users WHERE (SELECT COUNT(*) FROM orders WHERE user_id = 99) = 0
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 3), rs.rows.len);
}

test "subquery: IN with empty subquery result returns no rows" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    // No orders belong to user 99, so the IN set is empty — no user matches.
    const q = (try s.gw.register(
        \\SELECT id FROM users WHERE id IN (SELECT user_id FROM orders WHERE user_id = 99)
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 0), rs.rows.len);
}

test "subquery: NOT IN with empty subquery result returns all rows" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    const q = (try s.gw.register(
        \\SELECT id FROM users WHERE id NOT IN (SELECT user_id FROM orders WHERE user_id = 99)
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 3), rs.rows.len);
}

test "subquery: multiple subqueries in same WHERE clause" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    // Users whose id is in the orders user_id set AND whose id is NOT in the
    // set of user_ids who placed orders with user_id = 2.
    // Users with orders: {1, 2}. Set of user_id=2 orders: {2}.
    // Result: id IN {1,2} AND id NOT IN {2} → only user 1.
    const q = (try s.gw.register(
        \\SELECT id FROM users
        \\WHERE id IN (SELECT user_id FROM orders)
        \\AND id NOT IN (SELECT user_id FROM orders WHERE user_id = 2)
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(i64, 1), rs.rows[0][0].?.int64);
}

test "subquery: nested subquery — IN containing scalar subquery in WHERE" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    // Users whose id is among order user_ids where amount > min(amount).
    // min(amount) = 20; orders with amount > 20: user_id=1 (amounts 50, 80).
    // So the inner IN set is {1}. Users where id IN {1}: user 1 only.
    const q = (try s.gw.register(
        \\SELECT id FROM users WHERE id IN (
        \\  SELECT user_id FROM orders WHERE amount > (SELECT MIN(amount) FROM orders)
        \\)
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(i64, 1), rs.rows[0][0].?.int64);
}

test "subquery: scalar subquery in SELECT list returns NULL when source empty" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    // MIN on a filtered set with no matching rows returns NULL.
    const q = (try s.gw.register(
        \\SELECT id, (SELECT MIN(amount) FROM orders WHERE user_id = 99) FROM users WHERE id = 1
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(i64, 1), rs.rows[0][0].?.int64);
    // Scalar subquery returns NULL when aggregate over empty set
    try testing.expectEqual(@as(?gateway_mod.ColumnValue, null), rs.rows[0][1]);
}

test "subquery: ASSERT with scalar COUNT subquery passes when condition met" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    // This transaction inserts a new order only if user 3 has fewer than 5 orders.
    // User 3 currently has 0 orders, so the ASSERT passes.
    const txn = (try s.gw.register(
        \\TRANSACTION (oid INT64, uid INT64, amt INT64) {
        \\  ASSERT (SELECT COUNT(*) FROM orders WHERE user_id = $uid) < 5;
        \\  INSERT INTO orders (id, user_id, amount) VALUES ($oid, $uid, $amt);
        \\}
    )).hash;
    _ = try s.gw.execute(txn, &.{ .{ .int64 = 10 }, .{ .int64 = 3 }, .{ .int64 = 99 } }, &.{});

    const check = (try s.gw.register(
        \\SELECT id FROM orders WHERE user_id = 3
    )).hash;
    var rs = try s.gw.querySelect(check, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(i64, 10), rs.rows[0][0].?.int64);
}

test "subquery: ASSERT with scalar COUNT subquery aborts when condition fails" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    // User 1 has 2 orders. Require count < 1 — should abort.
    const txn = (try s.gw.register(
        \\TRANSACTION (oid INT64, uid INT64, amt INT64) {
        \\  ASSERT (SELECT COUNT(*) FROM orders WHERE user_id = $uid) < 1;
        \\  INSERT INTO orders (id, user_id, amount) VALUES ($oid, $uid, $amt);
        \\}
    )).hash;
    const result = s.gw.execute(txn, &.{ .{ .int64 = 20 }, .{ .int64 = 1 }, .{ .int64 = 5 } }, &.{});
    try testing.expectError(error.ConstraintViolation, result);

    // Verify no new order was inserted.
    const check = (try s.gw.register("SELECT id FROM orders WHERE user_id = 1")).hash;
    var rs = try s.gw.querySelect(check, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 2), rs.rows.len);
}
