/// Gateway integration tests for JSON operators (@>, <@, ->, ->>).
const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");

const Gateway = gateway_mod.Gateway;

fn makeTempDir() ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/json_test_{d}", .{ns});
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

const DDL = "CREATE TABLE docs (id INT64 NOT NULL, data JSON NOT NULL, PRIMARY KEY (id))";

fn setupGateway() !struct { gw: *Gateway, dir: []const u8 } {
    const dir = try makeTempDir();
    const gw = try Gateway.init(dir, testing.allocator, .{});
    try gw.applyDdl(DDL);
    return .{ .gw = gw, .dir = dir };
}

fn teardown(gw: *Gateway, dir: []const u8) void {
    gw.deinit();
    removeDirRecursive(dir);
    testing.allocator.free(dir);
}

fn insertDoc(gw: *Gateway, id: i64, json: []const u8) !void {
    const h = (try gw.register("INSERT INTO docs (id, data) VALUES ($1, $2)")).hash;
    _ = try gw.execute(h, &.{ .{ .int64 = id }, .{ .bytes = json } }, &.{});
}

test "arrow extracts JSON sub-object" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);
    try insertDoc(s.gw, 1, "{\"addr\":{\"city\":\"Toronto\"}}");

    const q = (try s.gw.register("SELECT data->'addr' FROM docs WHERE id = 1")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    const val = rs.rows[0][0].?.bytes;
    try testing.expect(std.mem.indexOf(u8, val, "Toronto") != null);
}

test "darrow extracts JSON field as text" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);
    try insertDoc(s.gw, 1, "{\"name\":\"Alice\",\"age\":30}");

    const q = (try s.gw.register("SELECT data->>'name' FROM docs WHERE id = 1")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqualStrings("Alice", rs.rows[0][0].?.string);
}

test "darrow on integer field returns text representation" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);
    try insertDoc(s.gw, 1, "{\"count\":42}");

    const q = (try s.gw.register("SELECT data->>'count' FROM docs WHERE id = 1")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqualStrings("42", rs.rows[0][0].?.string);
}

test "darrow on missing key returns null" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);
    try insertDoc(s.gw, 1, "{\"x\":1}");

    const q = (try s.gw.register("SELECT data->>'missing' FROM docs WHERE id = 1")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expect(rs.rows[0][0] == null);
}

test "contains returns true when left contains right" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);
    try insertDoc(s.gw, 1, "{\"a\":1,\"b\":2,\"c\":3}");

    const q = (try s.gw.register("SELECT id FROM docs WHERE data @> '{\"b\":2}'")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 1), rs.rows[0][0].?.int64);
}

test "contains returns false when left does not contain right" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);
    try insertDoc(s.gw, 1, "{\"a\":1}");

    const q = (try s.gw.register("SELECT id FROM docs WHERE data @> '{\"b\":2}'")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 0), rs.rows.len);
}

test "contained returns true when left is subset of right" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);
    try insertDoc(s.gw, 1, "{\"a\":1}");

    const q = (try s.gw.register("SELECT id FROM docs WHERE data <@ '{\"a\":1,\"b\":2}'")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 1), rs.rows[0][0].?.int64);
}

test "contained returns false when left is not subset of right" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);
    try insertDoc(s.gw, 1, "{\"a\":1,\"c\":3}");

    const q = (try s.gw.register("SELECT id FROM docs WHERE data <@ '{\"a\":1,\"b\":2}'")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 0), rs.rows.len);
}

test "arrow then darrow chains field access" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);
    try insertDoc(s.gw, 1, "{\"user\":{\"name\":\"Bob\"}}");

    const q = (try s.gw.register("SELECT data->'user'->>'name' FROM docs WHERE id = 1")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqualStrings("Bob", rs.rows[0][0].?.string);
}
