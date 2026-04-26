/// Gateway integration tests for DELETE...USING.
const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");

const Gateway = gateway_mod.Gateway;

fn makeTempDir() ![]const u8 {
    // SAFETY: clock_gettime fills ts before any field is read.
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/delete_using_test_{d}", .{ns});
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
    try gw.applyDdl("CREATE TABLE items (id INT64 NOT NULL, category_id INT64 NOT NULL, PRIMARY KEY (id))");
    try gw.applyDdl("CREATE TABLE categories (id INT64 NOT NULL, active INT64 NOT NULL, PRIMARY KEY (id))");
    return .{ .gw = gw, .dir = dir };
}

fn teardown(gw: *Gateway, dir: []const u8) void {
    gw.deinit();
    removeDirRecursive(dir);
    testing.allocator.free(dir);
}

fn insertItem(gw: *Gateway, id: i64, category_id: i64) !void {
    const h = (try gw.register("INSERT INTO items (id, category_id) VALUES ($1, $2)")).hash;
    _ = try gw.execute(h, &.{ .{ .int64 = id }, .{ .int64 = category_id } }, &.{});
}

fn insertCategory(gw: *Gateway, id: i64, active: i64) !void {
    const h = (try gw.register("INSERT INTO categories (id, active) VALUES ($1, $2)")).hash;
    _ = try gw.execute(h, &.{ .{ .int64 = id }, .{ .int64 = active } }, &.{});
}

test "DELETE USING: deletes rows matched by join condition" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertItem(s.gw, 1, 10); // category 10 = inactive
    try insertItem(s.gw, 2, 20); // category 20 = active
    try insertCategory(s.gw, 10, 0); // inactive
    try insertCategory(s.gw, 20, 1); // active

    const del = (try s.gw.register(
        "DELETE FROM items USING categories WHERE items.category_id = categories.id AND categories.active = 0",
    )).hash;
    const r = try s.gw.execute(del, &.{}, &.{});
    try testing.expectEqual(@as(u64, 1), r.rows_affected);

    const q = (try s.gw.register("SELECT id FROM items")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 2), rs.rows[0][0].?.int64);
}

test "DELETE USING: no matching join leaves rows intact" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertItem(s.gw, 1, 10);
    try insertCategory(s.gw, 99, 0); // no category with id=10

    const del = (try s.gw.register(
        "DELETE FROM items USING categories WHERE items.category_id = categories.id",
    )).hash;
    _ = try s.gw.execute(del, &.{}, &.{});

    const q = (try s.gw.register("SELECT id FROM items")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
}

test "DELETE USING: deletes all matched rows when multiple items share a category" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertItem(s.gw, 1, 10);
    try insertItem(s.gw, 2, 10);
    try insertItem(s.gw, 3, 20);
    try insertCategory(s.gw, 10, 0); // inactive
    try insertCategory(s.gw, 20, 1); // active

    const del = (try s.gw.register(
        "DELETE FROM items USING categories WHERE items.category_id = categories.id AND categories.active = 0",
    )).hash;
    const r = try s.gw.execute(del, &.{}, &.{});
    try testing.expectEqual(@as(u64, 2), r.rows_affected);

    const q = (try s.gw.register("SELECT id FROM items")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 3), rs.rows[0][0].?.int64);
}

test "DELETE USING: two USING tables cross-product — only row matching both is deleted" {
    const dir = try makeTempDir();
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer {
        gw.deinit();
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    try gw.applyDdl("CREATE TABLE products (id INT64 NOT NULL, cat_id INT64 NOT NULL, region_id INT64 NOT NULL, PRIMARY KEY (id))");
    try gw.applyDdl("CREATE TABLE banned_cats (id INT64 NOT NULL, PRIMARY KEY (id))");
    try gw.applyDdl("CREATE TABLE banned_regions (id INT64 NOT NULL, PRIMARY KEY (id))");

    // product 1: cat=10, region=100 — both banned → DELETE
    // product 2: cat=10, region=200 — cat banned but region not → KEEP
    // product 3: cat=20, region=100 — region banned but cat not → KEEP
    const ins_prod = (try gw.register("INSERT INTO products (id, cat_id, region_id) VALUES ($1, $2, $3)")).hash;
    _ = try gw.execute(ins_prod, &.{ .{ .int64 = 1 }, .{ .int64 = 10 }, .{ .int64 = 100 } }, &.{});
    _ = try gw.execute(ins_prod, &.{ .{ .int64 = 2 }, .{ .int64 = 10 }, .{ .int64 = 200 } }, &.{});
    _ = try gw.execute(ins_prod, &.{ .{ .int64 = 3 }, .{ .int64 = 20 }, .{ .int64 = 100 } }, &.{});

    const ins_cat = (try gw.register("INSERT INTO banned_cats (id) VALUES ($1)")).hash;
    _ = try gw.execute(ins_cat, &.{.{ .int64 = 10 }}, &.{});

    const ins_reg = (try gw.register("INSERT INTO banned_regions (id) VALUES ($1)")).hash;
    _ = try gw.execute(ins_reg, &.{.{ .int64 = 100 }}, &.{});

    const del = (try gw.register(
        "DELETE FROM products USING banned_cats, banned_regions " ++
            "WHERE products.cat_id = banned_cats.id AND products.region_id = banned_regions.id",
    )).hash;
    const r = try gw.execute(del, &.{}, &.{});
    try testing.expectEqual(@as(u64, 1), r.rows_affected);

    const q = (try gw.register("SELECT id FROM products")).hash;
    var rs = try gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 2), rs.rows.len);

    // Verify products 2 and 3 survive
    var saw2 = false;
    var saw3 = false;
    for (rs.rows) |row| {
        const id = row[0].?.int64;
        if (id == 2) saw2 = true;
        if (id == 3) saw3 = true;
    }
    try testing.expect(saw2);
    try testing.expect(saw3);
}
