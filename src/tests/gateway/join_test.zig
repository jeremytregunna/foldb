/// Gateway integration tests for all join kinds (INNER, LEFT, RIGHT, FULL, CROSS).
const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");

const Gateway = gateway_mod.Gateway;
const ColumnValue = gateway_mod.ColumnValue;

fn makeTempDir() ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/join_test_{d}", .{ns});
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

// Schema: employees(id, dept_id), departments(id, name_int)
// dept_id=3 has no matching department; dept id=99 has no employees.
fn setupGateway() !struct { gw: *Gateway, dir: []const u8 } {
    const dir = try makeTempDir();
    const gw = try Gateway.init(dir, testing.allocator, .{});

    try gw.applyDdl("CREATE TABLE employees (id INT64 NOT NULL, dept_id INT64 NOT NULL, PRIMARY KEY (id))");
    try gw.applyDdl("CREATE TABLE departments (id INT64 NOT NULL, budget INT64 NOT NULL, PRIMARY KEY (id))");

    const ins_e = (try gw.register("INSERT INTO employees (id, dept_id) VALUES ($1, $2)")).hash;
    _ = try gw.execute(std.testing.io, ins_e, &.{ .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});
    _ = try gw.execute(std.testing.io, ins_e, &.{ .{ .int64 = 2 }, .{ .int64 = 10 } }, &.{});
    _ = try gw.execute(std.testing.io, ins_e, &.{ .{ .int64 = 3 }, .{ .int64 = 99 } }, &.{}); // no matching dept

    const ins_d = (try gw.register("INSERT INTO departments (id, budget) VALUES ($1, $2)")).hash;
    _ = try gw.execute(std.testing.io, ins_d, &.{ .{ .int64 = 10 }, .{ .int64 = 1000 } }, &.{});
    _ = try gw.execute(std.testing.io, ins_d, &.{ .{ .int64 = 20 }, .{ .int64 = 500 } }, &.{}); // no matching employees

    return .{ .gw = gw, .dir = dir };
}

fn teardown(gw: *Gateway, dir: []const u8) void {
    gw.deinit();
    removeDirRecursive(dir);
    testing.allocator.free(dir);
}

test "INNER JOIN: only rows with matching dept_id returned" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);

    const q = (try s.gw.register("SELECT employees.id FROM employees INNER JOIN departments ON employees.dept_id = departments.id")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // employees 1 and 2 match dept 10; employee 3 (dept 99) has no match
    try testing.expectEqual(@as(usize, 2), rs.rows.len);
}

test "LEFT JOIN: all employees returned, unmatched get null dept" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);

    const q = (try s.gw.register("SELECT employees.id FROM employees LEFT JOIN departments ON employees.dept_id = departments.id")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // All 3 employees returned, including employee 3 with no matching dept
    try testing.expectEqual(@as(usize, 3), rs.rows.len);
}

test "RIGHT JOIN: all departments returned, unmatched get null employee" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);

    const q = (try s.gw.register("SELECT departments.id FROM employees RIGHT JOIN departments ON employees.dept_id = departments.id")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // dept 10 matches 2 employees (2 rows), dept 20 has no employees (1 NULL-padded row) = 3
    try testing.expectEqual(@as(usize, 3), rs.rows.len);
}

test "FULL JOIN: all employees and all departments, NULLs where no match" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);

    const q = (try s.gw.register("SELECT employees.id FROM employees FULL JOIN departments ON employees.dept_id = departments.id")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // matched: emp1+dept10, emp2+dept10 (2 rows)
    // unmatched left:  emp3/dept99 (1 row, right side null)
    // unmatched right: dept20 (1 row, left side null → employees.id is null)
    try testing.expectEqual(@as(usize, 4), rs.rows.len);
}

test "FULL JOIN: unmatched right row has null left column" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);

    const q = (try s.gw.register("SELECT employees.id, departments.id FROM employees FULL JOIN departments ON employees.dept_id = departments.id")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    var found_null_emp = false;
    for (rs.rows) |row| {
        // The row where departments.id = 20 has no matching employee
        if (row[1] != null and row[1].?.int64 == 20) {
            try testing.expect(row[0] == null);
            found_null_emp = true;
        }
    }
    try testing.expect(found_null_emp);
}

test "CROSS JOIN: produces cartesian product" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);

    const q = (try s.gw.register("SELECT employees.id FROM employees CROSS JOIN departments")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // 3 employees × 2 departments = 6 rows
    try testing.expectEqual(@as(usize, 6), rs.rows.len);
}

// ─── Gap 2: column-value checks for LEFT / RIGHT / CROSS ─────────────────────

test "LEFT JOIN: unmatched left row has null right-side column" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);

    const q = (try s.gw.register("SELECT employees.id, departments.budget FROM employees LEFT JOIN departments ON employees.dept_id = departments.id")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    var found = false;
    for (rs.rows) |row| {
        // Employee 3 has dept_id=99 which has no matching department
        if (row[0] != null and row[0].?.int64 == 3) {
            try testing.expect(row[1] == null); // budget should be null
            found = true;
        }
    }
    try testing.expect(found);
}

test "LEFT JOIN: matched rows have non-null right-side column" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);

    const q = (try s.gw.register("SELECT employees.id, departments.budget FROM employees LEFT JOIN departments ON employees.dept_id = departments.id")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    for (rs.rows) |row| {
        if (row[0] != null and (row[0].?.int64 == 1 or row[0].?.int64 == 2)) {
            // Employees 1 and 2 match dept 10 with budget=1000
            try testing.expect(row[1] != null);
            try testing.expectEqual(@as(i64, 1000), row[1].?.int64);
        }
    }
}

test "RIGHT JOIN: unmatched right row has null left-side column" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);

    const q = (try s.gw.register("SELECT employees.id, departments.id FROM employees RIGHT JOIN departments ON employees.dept_id = departments.id")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    var found = false;
    for (rs.rows) |row| {
        // Department 20 has no matching employees
        if (row[1] != null and row[1].?.int64 == 20) {
            try testing.expect(row[0] == null); // employees.id should be null
            found = true;
        }
    }
    try testing.expect(found);
}

test "CROSS JOIN: column values from both tables present in each row" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);

    const q = (try s.gw.register("SELECT employees.id, departments.budget FROM employees CROSS JOIN departments")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 6), rs.rows.len);
    for (rs.rows) |row| {
        // Every row should have both columns non-null
        try testing.expect(row[0] != null);
        try testing.expect(row[1] != null);
    }
}

// ─── Gap 4: chained joins (3+ tables) ────────────────────────────────────────

test "chained INNER JOINs across three tables" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE a (id INT64 NOT NULL, b_id INT64 NOT NULL, PRIMARY KEY (id))");
    try gw.applyDdl("CREATE TABLE b (id INT64 NOT NULL, c_id INT64 NOT NULL, PRIMARY KEY (id))");
    try gw.applyDdl("CREATE TABLE c (id INT64 NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))");

    const ins_a = (try gw.register("INSERT INTO a (id, b_id) VALUES ($1, $2)")).hash;
    const ins_b = (try gw.register("INSERT INTO b (id, c_id) VALUES ($1, $2)")).hash;
    const ins_c = (try gw.register("INSERT INTO c (id, val) VALUES ($1, $2)")).hash;

    _ = try gw.execute(std.testing.io, ins_a, &.{ .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});
    _ = try gw.execute(std.testing.io, ins_a, &.{ .{ .int64 = 2 }, .{ .int64 = 99 } }, &.{}); // no match in b
    _ = try gw.execute(std.testing.io, ins_b, &.{ .{ .int64 = 10 }, .{ .int64 = 100 } }, &.{});
    _ = try gw.execute(std.testing.io, ins_c, &.{ .{ .int64 = 100 }, .{ .int64 = 42 } }, &.{});

    const q = (try gw.register("SELECT a.id, c.val FROM a INNER JOIN b ON a.b_id = b.id INNER JOIN c ON b.c_id = c.id")).hash;
    var rs = try gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // Only a.id=1 → b.id=10 → c.id=100 → val=42; a.id=2 has no b match
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 1), rs.rows[0][0].?.int64);
    try testing.expectEqual(@as(?i64, 42), rs.rows[0][1].?.int64);
}

// ─── Gap 5: join combined with WHERE / GROUP BY / ORDER BY ───────────────────

test "INNER JOIN with WHERE filter post-join" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);

    const q = (try s.gw.register("SELECT employees.id FROM employees INNER JOIN departments ON employees.dept_id = departments.id WHERE departments.budget > 600")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // Only dept 10 has budget=1000 > 600; employees 1 and 2 are in dept 10
    try testing.expectEqual(@as(usize, 2), rs.rows.len);
}

test "INNER JOIN with WHERE excludes all rows below threshold" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);

    const q = (try s.gw.register("SELECT employees.id FROM employees INNER JOIN departments ON employees.dept_id = departments.id WHERE departments.budget > 9999")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 0), rs.rows.len);
}

test "INNER JOIN with GROUP BY and COUNT" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);

    const q = (try s.gw.register("SELECT departments.id, COUNT(*) FROM employees INNER JOIN departments ON employees.dept_id = departments.id GROUP BY departments.id")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // dept 10 has employees 1 and 2 → one group with count=2
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 10), rs.rows[0][0].?.int64);
    try testing.expectEqual(@as(?i64, 2), rs.rows[0][1].?.int64);
}

test "LEFT JOIN with ORDER BY returns rows in order" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);

    const q = (try s.gw.register("SELECT employees.id FROM employees LEFT JOIN departments ON employees.dept_id = departments.id ORDER BY employees.id")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 3), rs.rows.len);
    try testing.expectEqual(@as(?i64, 1), rs.rows[0][0].?.int64);
    try testing.expectEqual(@as(?i64, 2), rs.rows[1][0].?.int64);
    try testing.expectEqual(@as(?i64, 3), rs.rows[2][0].?.int64);
}

// ─── Gap 6: USING clause ─────────────────────────────────────────────────────

test "JOIN USING: matches rows by shared column name" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE left_t (id INT64 NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))");
    try gw.applyDdl("CREATE TABLE right_t (id INT64 NOT NULL, extra INT64 NOT NULL, PRIMARY KEY (id))");

    const ins_l = (try gw.register("INSERT INTO left_t (id, val) VALUES ($1, $2)")).hash;
    const ins_r = (try gw.register("INSERT INTO right_t (id, extra) VALUES ($1, $2)")).hash;

    _ = try gw.execute(std.testing.io, ins_l, &.{ .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});
    _ = try gw.execute(std.testing.io, ins_l, &.{ .{ .int64 = 2 }, .{ .int64 = 20 } }, &.{});
    _ = try gw.execute(std.testing.io, ins_r, &.{ .{ .int64 = 1 }, .{ .int64 = 100 } }, &.{});
    // right id=2 is absent → no match for left id=2

    const q = (try gw.register("SELECT left_t.id FROM left_t JOIN right_t USING (id)")).hash;
    var rs = try gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // Only id=1 has a match on both sides
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 1), rs.rows[0][0].?.int64);
}

test "LEFT JOIN USING: unmatched left row preserved with null right side" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE left_t (id INT64 NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))");
    try gw.applyDdl("CREATE TABLE right_t (id INT64 NOT NULL, extra INT64 NOT NULL, PRIMARY KEY (id))");

    const ins_l = (try gw.register("INSERT INTO left_t (id, val) VALUES ($1, $2)")).hash;
    const ins_r = (try gw.register("INSERT INTO right_t (id, extra) VALUES ($1, $2)")).hash;

    _ = try gw.execute(std.testing.io, ins_l, &.{ .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});
    _ = try gw.execute(std.testing.io, ins_l, &.{ .{ .int64 = 2 }, .{ .int64 = 20 } }, &.{});
    _ = try gw.execute(std.testing.io, ins_r, &.{ .{ .int64 = 1 }, .{ .int64 = 100 } }, &.{});

    const q = (try gw.register("SELECT left_t.id FROM left_t LEFT JOIN right_t USING (id)")).hash;
    var rs = try gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // Both left rows returned (id=1 matched, id=2 unmatched with null right side)
    try testing.expectEqual(@as(usize, 2), rs.rows.len);
}
