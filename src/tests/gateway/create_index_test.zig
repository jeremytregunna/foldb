/// Gateway integration tests for CREATE INDEX.
const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");

const Gateway = gateway_mod.Gateway;
const ColumnValue = gateway_mod.ColumnValue;

fn makeTempDir() ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/create_index_test_{d}", .{ns});
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

test "CREATE INDEX ORDERED: index created and queries still work" {
    const dir = try makeTempDir();
    defer { removeDirRecursive(dir); testing.allocator.free(dir); }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE products (id INT64 NOT NULL, name INT64 NOT NULL, PRIMARY KEY (id))");
    try gw.applyDdl("CREATE ORDERED INDEX idx_products_name ON products (name)");

    const ins = (try gw.register("INSERT INTO products (id, name) VALUES ($1, $2)")).hash;
    _ = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 42 } }, &.{});

    const q = (try gw.register("SELECT name FROM products WHERE id = 1")).hash;
    var rs = try gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 42), rs.rows[0][0].?.int64);
}

test "CREATE INDEX HASH: index created and queries still work" {
    const dir = try makeTempDir();
    defer { removeDirRecursive(dir); testing.allocator.free(dir); }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE sessions (id INT64 NOT NULL, token INT64 NOT NULL, PRIMARY KEY (id))");
    try gw.applyDdl("CREATE HASH INDEX idx_sessions_token ON sessions (token)");

    const ins = (try gw.register("INSERT INTO sessions (id, token) VALUES ($1, $2)")).hash;
    _ = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 999 } }, &.{});

    const q = (try gw.register("SELECT token FROM sessions WHERE id = 1")).hash;
    var rs = try gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 999), rs.rows[0][0].?.int64);
}

test "CREATE INDEX: duplicate index name is rejected" {
    const dir = try makeTempDir();
    defer { removeDirRecursive(dir); testing.allocator.free(dir); }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE products (id INT64 NOT NULL, name INT64 NOT NULL, PRIMARY KEY (id))");
    try gw.applyDdl("CREATE ORDERED INDEX idx_products_name ON products (name)");
    const result = gw.applyDdl("CREATE HASH INDEX idx_products_name ON products (name)");
    try testing.expectError(error.IndexAlreadyExists, result);
}

test "CREATE INDEX: non-existent table is rejected" {
    const dir = try makeTempDir();
    defer { removeDirRecursive(dir); testing.allocator.free(dir); }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    const result = gw.applyDdl("CREATE ORDERED INDEX idx_ghost ON ghost_table (id)");
    try testing.expectError(error.TableNotFound, result);
}
