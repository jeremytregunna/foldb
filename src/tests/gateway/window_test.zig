/// Gateway integration tests for LAG, LEAD, FIRST_VALUE, LAST_VALUE, NTH_VALUE.
const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");

const Gateway = gateway_mod.Gateway;
const ColumnValue = gateway_mod.ColumnValue;

fn makeTempDir() ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/window_test_{d}", .{ns});
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

fn setup() !struct { gw: *Gateway, dir: []const u8 } {
    const dir = try makeTempDir();
    const gw = try Gateway.init(dir, testing.allocator, .{});
    try gw.applyDdl("CREATE TABLE sales (id INT64 NOT NULL, dept INT64 NOT NULL, amount INT64 NOT NULL, PRIMARY KEY (id))");
    return .{ .gw = gw, .dir = dir };
}

fn teardown(gw: *Gateway, dir: []const u8) void {
    gw.deinit();
    removeDirRecursive(dir);
    testing.allocator.free(dir);
}

fn insertSale(gw: *Gateway, id: i64, dept: i64, amount: i64) !void {
    const h = (try gw.register("INSERT INTO sales (id, dept, amount) VALUES ($1, $2, $3)")).hash;
    _ = try gw.execute(h, &.{
        .{ .int64 = id },
        .{ .int64 = dept },
        .{ .int64 = amount },
    }, &.{});
}

fn rowById(rows: []const []const ?ColumnValue, id_col: usize, id: i64) ?[]const ?ColumnValue {
    for (rows) |row| {
        if (row[id_col]) |cv| {
            if (cv.int64 == id) return row;
        }
    }
    return null;
}

// ─── LAG ─────────────────────────────────────────────────────────────────────

test "LAG: returns previous row value within partition" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertSale(s.gw, 1, 10, 100);
    try insertSale(s.gw, 2, 10, 200);
    try insertSale(s.gw, 3, 10, 300);

    const q = (try s.gw.register(
        "SELECT id, LAG(amount) OVER (PARTITION BY dept ORDER BY id) FROM sales",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 3), rs.rows.len);

    const r1 = rowById(rs.rows, 0, 1).?;
    const r2 = rowById(rs.rows, 0, 2).?;
    const r3 = rowById(rs.rows, 0, 3).?;

    try testing.expect(r1[1] == null); // first row has no previous
    try testing.expectEqual(@as(i64, 100), r2[1].?.int64); // previous of row 2 = row 1
    try testing.expectEqual(@as(i64, 200), r3[1].?.int64); // previous of row 3 = row 2
}

test "LAG: with explicit offset 2" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertSale(s.gw, 1, 10, 10);
    try insertSale(s.gw, 2, 10, 20);
    try insertSale(s.gw, 3, 10, 30);
    try insertSale(s.gw, 4, 10, 40);

    const q = (try s.gw.register(
        "SELECT id, LAG(amount, 2) OVER (PARTITION BY dept ORDER BY id) FROM sales",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    const r1 = rowById(rs.rows, 0, 1).?;
    const r2 = rowById(rs.rows, 0, 2).?;
    const r3 = rowById(rs.rows, 0, 3).?;
    const r4 = rowById(rs.rows, 0, 4).?;

    try testing.expect(r1[1] == null);
    try testing.expect(r2[1] == null);
    try testing.expectEqual(@as(i64, 10), r3[1].?.int64);
    try testing.expectEqual(@as(i64, 20), r4[1].?.int64);
}

test "LAG: with default value for out-of-bounds" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertSale(s.gw, 1, 10, 100);
    try insertSale(s.gw, 2, 10, 200);

    const q = (try s.gw.register(
        "SELECT id, LAG(amount, 1, -1) OVER (PARTITION BY dept ORDER BY id) FROM sales",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    const r1 = rowById(rs.rows, 0, 1).?;
    const r2 = rowById(rs.rows, 0, 2).?;

    try testing.expectEqual(@as(i64, -1), r1[1].?.int64); // default for first row
    try testing.expectEqual(@as(i64, 100), r2[1].?.int64);
}

test "LAG: partition isolation" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertSale(s.gw, 1, 10, 100);
    try insertSale(s.gw, 2, 10, 200);
    try insertSale(s.gw, 3, 20, 300); // different dept
    try insertSale(s.gw, 4, 20, 400);

    const q = (try s.gw.register(
        "SELECT id, LAG(amount) OVER (PARTITION BY dept ORDER BY id) FROM sales",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // First row of each partition should have null lag
    const r1 = rowById(rs.rows, 0, 1).?;
    const r3 = rowById(rs.rows, 0, 3).?;
    try testing.expect(r1[1] == null);
    try testing.expect(r3[1] == null); // first in dept=20 partition

    const r4 = rowById(rs.rows, 0, 4).?;
    try testing.expectEqual(@as(i64, 300), r4[1].?.int64);
}

// ─── LEAD ────────────────────────────────────────────────────────────────────

test "LEAD: returns next row value within partition" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertSale(s.gw, 1, 10, 100);
    try insertSale(s.gw, 2, 10, 200);
    try insertSale(s.gw, 3, 10, 300);

    const q = (try s.gw.register(
        "SELECT id, LEAD(amount) OVER (PARTITION BY dept ORDER BY id) FROM sales",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    const r1 = rowById(rs.rows, 0, 1).?;
    const r2 = rowById(rs.rows, 0, 2).?;
    const r3 = rowById(rs.rows, 0, 3).?;

    try testing.expectEqual(@as(i64, 200), r1[1].?.int64);
    try testing.expectEqual(@as(i64, 300), r2[1].?.int64);
    try testing.expect(r3[1] == null); // last row has no next
}

test "LEAD: with default value for out-of-bounds" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertSale(s.gw, 1, 10, 100);
    try insertSale(s.gw, 2, 10, 200);

    const q = (try s.gw.register(
        "SELECT id, LEAD(amount, 1, 0) OVER (PARTITION BY dept ORDER BY id) FROM sales",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    const r1 = rowById(rs.rows, 0, 1).?;
    const r2 = rowById(rs.rows, 0, 2).?;

    try testing.expectEqual(@as(i64, 200), r1[1].?.int64);
    try testing.expectEqual(@as(i64, 0), r2[1].?.int64); // default for last row
}

// ─── FIRST_VALUE ─────────────────────────────────────────────────────────────

test "FIRST_VALUE: returns first value in partition" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertSale(s.gw, 1, 10, 100);
    try insertSale(s.gw, 2, 10, 200);
    try insertSale(s.gw, 3, 10, 300);

    const q = (try s.gw.register(
        "SELECT id, FIRST_VALUE(amount) OVER (PARTITION BY dept ORDER BY id) FROM sales",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // Every row in the partition should see the first row's amount
    for (rs.rows) |row| {
        try testing.expectEqual(@as(i64, 100), row[1].?.int64);
    }
}

test "FIRST_VALUE: partitioned — each dept sees its own first" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertSale(s.gw, 1, 10, 100);
    try insertSale(s.gw, 2, 10, 200);
    try insertSale(s.gw, 3, 20, 50);
    try insertSale(s.gw, 4, 20, 60);

    const q = (try s.gw.register(
        "SELECT id, FIRST_VALUE(amount) OVER (PARTITION BY dept ORDER BY id) FROM sales",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    for (rs.rows) |row| {
        const id = row[0].?.int64;
        const first = row[1].?.int64;
        if (id == 1 or id == 2) try testing.expectEqual(@as(i64, 100), first);
        if (id == 3 or id == 4) try testing.expectEqual(@as(i64, 50), first);
    }
}

// ─── LAST_VALUE ──────────────────────────────────────────────────────────────

test "LAST_VALUE: returns last value in partition" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertSale(s.gw, 1, 10, 100);
    try insertSale(s.gw, 2, 10, 200);
    try insertSale(s.gw, 3, 10, 300);

    const q = (try s.gw.register(
        "SELECT id, LAST_VALUE(amount) OVER (PARTITION BY dept ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM sales",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    for (rs.rows) |row| {
        try testing.expectEqual(@as(i64, 300), row[1].?.int64);
    }
}

test "LAST_VALUE: partitioned — each dept sees its own last" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertSale(s.gw, 1, 10, 100);
    try insertSale(s.gw, 2, 10, 200);
    try insertSale(s.gw, 3, 20, 50);
    try insertSale(s.gw, 4, 20, 60);

    const q = (try s.gw.register(
        "SELECT id, LAST_VALUE(amount) OVER (PARTITION BY dept ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM sales",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    for (rs.rows) |row| {
        const id = row[0].?.int64;
        const last = row[1].?.int64;
        if (id == 1 or id == 2) try testing.expectEqual(@as(i64, 200), last);
        if (id == 3 or id == 4) try testing.expectEqual(@as(i64, 60), last);
    }
}

// ─── NTH_VALUE ───────────────────────────────────────────────────────────────

test "NTH_VALUE: returns Nth value in partition (1-indexed)" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertSale(s.gw, 1, 10, 100);
    try insertSale(s.gw, 2, 10, 200);
    try insertSale(s.gw, 3, 10, 300);

    const q = (try s.gw.register(
        "SELECT id, NTH_VALUE(amount, 2) OVER (PARTITION BY dept ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM sales",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // All rows see the 2nd row's amount in the partition
    for (rs.rows) |row| {
        try testing.expectEqual(@as(i64, 200), row[1].?.int64);
    }
}

test "NTH_VALUE: N beyond partition size returns null" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertSale(s.gw, 1, 10, 100);
    try insertSale(s.gw, 2, 10, 200);

    const q = (try s.gw.register(
        "SELECT id, NTH_VALUE(amount, 5) OVER (PARTITION BY dept ORDER BY id) FROM sales",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    for (rs.rows) |row| {
        try testing.expect(row[1] == null);
    }
}

test "NTH_VALUE: N=1 matches FIRST_VALUE" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertSale(s.gw, 1, 10, 42);
    try insertSale(s.gw, 2, 10, 99);
    try insertSale(s.gw, 3, 10, 7);

    const q = (try s.gw.register(
        "SELECT id, NTH_VALUE(amount, 1) OVER (PARTITION BY dept ORDER BY id) FROM sales",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    for (rs.rows) |row| {
        try testing.expectEqual(@as(i64, 42), row[1].?.int64);
    }
}

// ─── LEAD coverage gaps ───────────────────────────────────────────────────────

test "LEAD: with explicit offset 2" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertSale(s.gw, 1, 10, 10);
    try insertSale(s.gw, 2, 10, 20);
    try insertSale(s.gw, 3, 10, 30);
    try insertSale(s.gw, 4, 10, 40);

    const q = (try s.gw.register(
        "SELECT id, LEAD(amount, 2) OVER (PARTITION BY dept ORDER BY id) FROM sales",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    const r1 = rowById(rs.rows, 0, 1).?;
    const r2 = rowById(rs.rows, 0, 2).?;
    const r3 = rowById(rs.rows, 0, 3).?;
    const r4 = rowById(rs.rows, 0, 4).?;

    try testing.expectEqual(@as(i64, 30), r1[1].?.int64);
    try testing.expectEqual(@as(i64, 40), r2[1].?.int64);
    try testing.expect(r3[1] == null);
    try testing.expect(r4[1] == null);
}

test "LEAD: partition isolation" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertSale(s.gw, 1, 10, 100);
    try insertSale(s.gw, 2, 10, 200);
    try insertSale(s.gw, 3, 20, 300);
    try insertSale(s.gw, 4, 20, 400);

    const q = (try s.gw.register(
        "SELECT id, LEAD(amount) OVER (PARTITION BY dept ORDER BY id) FROM sales",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    // Last row of each partition must be null — not bleed into next partition
    const r2 = rowById(rs.rows, 0, 2).?;
    const r4 = rowById(rs.rows, 0, 4).?;
    try testing.expect(r2[1] == null); // last in dept=10
    try testing.expect(r4[1] == null); // last in dept=20

    const r1 = rowById(rs.rows, 0, 1).?;
    const r3 = rowById(rs.rows, 0, 3).?;
    try testing.expectEqual(@as(i64, 200), r1[1].?.int64);
    try testing.expectEqual(@as(i64, 400), r3[1].?.int64);
}

// ─── Global window (no PARTITION BY) ─────────────────────────────────────────

test "LAG: global window without PARTITION BY" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertSale(s.gw, 1, 10, 100);
    try insertSale(s.gw, 2, 20, 200);
    try insertSale(s.gw, 3, 30, 300);

    const q = (try s.gw.register(
        "SELECT id, LAG(amount) OVER (ORDER BY id) FROM sales",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 3), rs.rows.len);

    const r1 = rowById(rs.rows, 0, 1).?;
    const r2 = rowById(rs.rows, 0, 2).?;
    const r3 = rowById(rs.rows, 0, 3).?;

    try testing.expect(r1[1] == null);
    try testing.expectEqual(@as(i64, 100), r2[1].?.int64);
    try testing.expectEqual(@as(i64, 200), r3[1].?.int64);
}

test "FIRST_VALUE: global window without PARTITION BY" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertSale(s.gw, 1, 10, 55);
    try insertSale(s.gw, 2, 20, 66);
    try insertSale(s.gw, 3, 30, 77);

    const q = (try s.gw.register(
        "SELECT id, FIRST_VALUE(amount) OVER (ORDER BY id) FROM sales",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    for (rs.rows) |row| {
        try testing.expectEqual(@as(i64, 55), row[1].?.int64);
    }
}

test "LEAD: global window without PARTITION BY" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertSale(s.gw, 1, 10, 10);
    try insertSale(s.gw, 2, 20, 20);
    try insertSale(s.gw, 3, 30, 30);

    const q = (try s.gw.register(
        "SELECT id, LEAD(amount) OVER (ORDER BY id) FROM sales",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    const r1 = rowById(rs.rows, 0, 1).?;
    const r2 = rowById(rs.rows, 0, 2).?;
    const r3 = rowById(rs.rows, 0, 3).?;

    try testing.expectEqual(@as(i64, 20), r1[1].?.int64);
    try testing.expectEqual(@as(i64, 30), r2[1].?.int64);
    try testing.expect(r3[1] == null);
}
