/// Gateway integration tests for bitwise operators (&, |, ^, ~, <<, >>).
const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");

const Gateway = gateway_mod.Gateway;

fn makeTempDir() ![]const u8 {
    // SAFETY: clock_gettime fills ts before any field is read.
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/bitwise_test_{d}", .{ns});
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

const FLAGS_DDL = "CREATE TABLE flags (id INT64 NOT NULL, mask INT64 NOT NULL, PRIMARY KEY (id))";

fn setupGateway() !struct { gw: *Gateway, dir: []const u8 } {
    const dir = try makeTempDir();
    const gw = try Gateway.init(dir, testing.allocator, .{});
    try gw.applyDdl(FLAGS_DDL);
    return .{ .gw = gw, .dir = dir };
}

fn teardown(gw: *Gateway, dir: []const u8) void {
    gw.deinit();
    removeDirRecursive(dir);
    testing.allocator.free(dir);
}

fn insertRow(gw: *Gateway, id: i64, mask: i64) !void {
    const h = (try gw.register("INSERT INTO flags (id, mask) VALUES ($1, $2)")).hash;
    _ = try gw.execute(h, &.{ .{ .int64 = id }, .{ .int64 = mask } }, &.{});
}

test "bitwise AND selects matching bits" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);
    try insertRow(s.gw, 1, 15); // 0b1111

    const q = (try s.gw.register("SELECT mask & 6 FROM flags WHERE id = 1")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 6), rs.rows[0][0].?.int64); // 0b1111 & 0b0110 = 6
}

test "bitwise OR combines bits" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);
    try insertRow(s.gw, 1, 5); // 0b0101

    const q = (try s.gw.register("SELECT mask | 2 FROM flags WHERE id = 1")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 7), rs.rows[0][0].?.int64); // 0b0101 | 0b0010 = 7
}

test "bitwise XOR flips bits" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);
    try insertRow(s.gw, 1, 12); // 0b1100

    const q = (try s.gw.register("SELECT mask ^ 10 FROM flags WHERE id = 1")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 6), rs.rows[0][0].?.int64); // 0b1100 ^ 0b1010 = 6
}

test "bitwise NOT inverts all bits" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);
    try insertRow(s.gw, 1, 0);

    const q = (try s.gw.register("SELECT ~mask FROM flags WHERE id = 1")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, -1), rs.rows[0][0].?.int64);
}

test "left shift doubles value" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);
    try insertRow(s.gw, 1, 1);

    const q = (try s.gw.register("SELECT mask << 3 FROM flags WHERE id = 1")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 8), rs.rows[0][0].?.int64);
}

test "right shift halves value" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);
    try insertRow(s.gw, 1, 16);

    const q = (try s.gw.register("SELECT mask >> 2 FROM flags WHERE id = 1")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 4), rs.rows[0][0].?.int64);
}

test "bitwise AND in WHERE clause filters rows" {
    const s = try setupGateway();
    defer teardown(s.gw, s.dir);
    try insertRow(s.gw, 1, 7); // bit 0 set
    try insertRow(s.gw, 2, 8); // bit 0 not set

    const q = (try s.gw.register("SELECT id FROM flags WHERE mask & 1 = 1")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 1), rs.rows[0][0].?.int64);
}
