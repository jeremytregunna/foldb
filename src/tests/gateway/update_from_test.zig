/// Gateway integration tests for UPDATE...FROM.
const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");

const Gateway = gateway_mod.Gateway;
const ColumnValue = gateway_mod.ColumnValue;

fn makeTempDir() ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/update_from_test_{d}", .{ns});
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
    try gw.applyDdl("CREATE TABLE orders (id INT64 NOT NULL, status INT64 NOT NULL, customer_id INT64 NOT NULL, PRIMARY KEY (id))");
    try gw.applyDdl("CREATE TABLE customers (id INT64 NOT NULL, tier INT64 NOT NULL, PRIMARY KEY (id))");
    return .{ .gw = gw, .dir = dir };
}

fn teardown(gw: *Gateway, dir: []const u8) void {
    gw.deinit();
    removeDirRecursive(dir);
    testing.allocator.free(dir);
}

fn insertOrder(gw: *Gateway, id: i64, status: i64, customer_id: i64) !void {
    const h = (try gw.register("INSERT INTO orders (id, status, customer_id) VALUES ($1, $2, $3)")).hash;
    _ = try gw.execute(std.testing.io, h, &.{ .{ .int64 = id }, .{ .int64 = status }, .{ .int64 = customer_id } }, &.{});
}

fn insertCustomer(gw: *Gateway, id: i64, tier: i64) !void {
    const h = (try gw.register("INSERT INTO customers (id, tier) VALUES ($1, $2)")).hash;
    _ = try gw.execute(std.testing.io, h, &.{ .{ .int64 = id }, .{ .int64 = tier } }, &.{});
}

test "UPDATE FROM: updates rows matched by join condition" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertOrder(s.gw, 1, 0, 10);
    try insertOrder(s.gw, 2, 0, 20);
    try insertCustomer(s.gw, 10, 1); // tier=1 (gold)
    try insertCustomer(s.gw, 20, 2); // tier=2 (silver)

    // Mark orders for gold-tier customers as status=1
    const upd = (try s.gw.register(
        "UPDATE orders SET status = 1 FROM customers WHERE orders.customer_id = customers.id AND customers.tier = 1",
    )).hash;
    const r = try s.gw.execute(std.testing.io, upd, &.{}, &.{});
    try testing.expectEqual(@as(u64, 1), r.rows_affected);

    const q = (try s.gw.register("SELECT id, status FROM orders")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 2), rs.rows.len);

    // Find each row and check status
    for (rs.rows) |row| {
        const id = row[0].?.int64;
        const status = row[1].?.int64;
        if (id == 1) try testing.expectEqual(@as(i64, 1), status); // updated
        if (id == 2) try testing.expectEqual(@as(i64, 0), status); // unchanged
    }
}

test "UPDATE FROM: no matching join leaves rows unchanged" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertOrder(s.gw, 1, 0, 10);
    try insertCustomer(s.gw, 99, 1); // no customer with id=10

    const upd = (try s.gw.register(
        "UPDATE orders SET status = 1 FROM customers WHERE orders.customer_id = customers.id",
    )).hash;
    _ = try s.gw.execute(std.testing.io, upd, &.{}, &.{});

    const q = (try s.gw.register("SELECT status FROM orders WHERE id = 1")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 0), rs.rows[0][0].?.int64);
}

test "UPDATE FROM: SET value taken from FROM table column" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertOrder(s.gw, 1, 0, 10);
    try insertCustomer(s.gw, 10, 42);

    // Set order status to customer.tier value
    const upd = (try s.gw.register(
        "UPDATE orders SET status = customers.tier FROM customers WHERE orders.customer_id = customers.id",
    )).hash;
    _ = try s.gw.execute(std.testing.io, upd, &.{}, &.{});

    const q = (try s.gw.register("SELECT status FROM orders WHERE id = 1")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 42), rs.rows[0][0].?.int64);
}
