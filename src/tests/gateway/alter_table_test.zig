/// Gateway integration tests for ALTER TABLE ADD COLUMN and DROP COLUMN.
const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");

const Gateway = gateway_mod.Gateway;
const ColumnValue = gateway_mod.ColumnValue;

fn makeTempDir() ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/alter_table_test_{d}", .{ns});
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

test "ALTER TABLE ADD COLUMN: new column readable on subsequent inserts" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE items (id INT64 NOT NULL, price INT64 NOT NULL, PRIMARY KEY (id))");
    try gw.applyDdl("ALTER TABLE items ADD COLUMN discount INT64 NULL");

    const ins = (try gw.register("INSERT INTO items (id, price, discount) VALUES ($1, $2, $3)")).hash;
    _ = try gw.execute(ins, &.{ .{ .int64 = 1 }, .{ .int64 = 100 }, .{ .int64 = 10 } }, &.{});

    const q = (try gw.register("SELECT discount FROM items WHERE id = 1")).hash;
    var rs = try gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 10), rs.rows[0][0].?.int64);
}

test "ALTER TABLE ADD COLUMN: existing rows return null for new column" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE items (id INT64 NOT NULL, price INT64 NOT NULL, PRIMARY KEY (id))");

    const ins_old = (try gw.register("INSERT INTO items (id, price) VALUES ($1, $2)")).hash;
    _ = try gw.execute(ins_old, &.{ .{ .int64 = 1 }, .{ .int64 = 50 } }, &.{});

    try gw.applyDdl("ALTER TABLE items ADD COLUMN discount INT64 NULL");

    const q = (try gw.register("SELECT discount FROM items WHERE id = 1")).hash;
    var rs = try gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    // Old row has no discount value — should be null
    try testing.expect(rs.rows[0][0] == null);
}

test "ALTER TABLE DROP COLUMN: column no longer accessible" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE items (id INT64 NOT NULL, price INT64 NOT NULL, extra INT64 NULL, PRIMARY KEY (id))");
    try gw.applyDdl("ALTER TABLE items DROP COLUMN extra");

    // Selecting the dropped column should fail — column no longer exists
    const result = gw.register("SELECT extra FROM items WHERE id = 1");
    try testing.expectError(error.ColumnNotFound, result);
}

test "ALTER TABLE ADD COLUMN: duplicate column name is rejected" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE items (id INT64 NOT NULL, price INT64 NOT NULL, PRIMARY KEY (id))");
    const result = gw.applyDdl("ALTER TABLE items ADD COLUMN price INT64 NULL");
    try testing.expectError(error.ColumnAlreadyExists, result);
}
