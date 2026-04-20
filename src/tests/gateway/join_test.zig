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

    const q = (try s.gw.register(
        "SELECT employees.id FROM employees INNER JOIN departments ON employees.dept_id = departments.id"
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // employees 1 and 2 match dept 10; employee 3 (dept 99) has no match
    try testing.expectEqual(@as(usize, 2), rs.rows.len);
}

test "LEFT JOIN: all employees returned, unmatched get null dept" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);

    const q = (try s.gw.register(
        "SELECT employees.id FROM employees LEFT JOIN departments ON employees.dept_id = departments.id"
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // All 3 employees returned, including employee 3 with no matching dept
    try testing.expectEqual(@as(usize, 3), rs.rows.len);
}

test "RIGHT JOIN: all departments returned, unmatched get null employee" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);

    const q = (try s.gw.register(
        "SELECT departments.id FROM employees RIGHT JOIN departments ON employees.dept_id = departments.id"
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // dept 10 matches 2 employees (2 rows), dept 20 has no employees (1 NULL-padded row) = 3
    try testing.expectEqual(@as(usize, 3), rs.rows.len);
}

test "FULL JOIN: all employees and all departments, NULLs where no match" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);

    const q = (try s.gw.register(
        "SELECT employees.id FROM employees FULL JOIN departments ON employees.dept_id = departments.id"
    )).hash;
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

    const q = (try s.gw.register(
        "SELECT employees.id, departments.id FROM employees FULL JOIN departments ON employees.dept_id = departments.id"
    )).hash;
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

    const q = (try s.gw.register(
        "SELECT employees.id FROM employees CROSS JOIN departments"
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // 3 employees × 2 departments = 6 rows
    try testing.expectEqual(@as(usize, 6), rs.rows.len);
}
