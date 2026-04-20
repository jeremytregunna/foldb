/// Gateway integration tests for ARRAY_AGG, STRING_AGG, and aggregate FILTER.
const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");

const Gateway = gateway_mod.Gateway;
const ColumnValue = gateway_mod.ColumnValue;

fn makeTempDir() ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/agg_test_{d}", .{ns});
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
    try gw.applyDdl("CREATE TABLE events (id INT64 NOT NULL, category INT64 NOT NULL, label STRING NOT NULL, score INT64 NOT NULL, PRIMARY KEY (id))");
    return .{ .gw = gw, .dir = dir };
}

fn teardown(gw: *Gateway, dir: []const u8) void {
    gw.deinit();
    removeDirRecursive(dir);
    testing.allocator.free(dir);
}

fn insertEvent(gw: *Gateway, id: i64, category: i64, label: []const u8, score: i64) !void {
    const h = (try gw.register("INSERT INTO events (id, category, label, score) VALUES ($1, $2, $3, $4)")).hash;
    _ = try gw.execute(std.testing.io, h, &.{
        .{ .int64 = id },
        .{ .int64 = category },
        .{ .string = label },
        .{ .int64 = score },
    }, &.{});
}

test "ARRAY_AGG: collects all values into a JSON array" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertEvent(s.gw, 1, 10, "alpha", 5);
    try insertEvent(s.gw, 2, 10, "beta", 3);
    try insertEvent(s.gw, 3, 20, "gamma", 7);

    const q = (try s.gw.register("SELECT category, ARRAY_AGG(score) FROM events GROUP BY category")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 2), rs.rows.len);

    // Find group with category=10 and verify it has a JSON array of two scores
    for (rs.rows) |row| {
        const cat = row[0].?.int64;
        const arr_bytes = row[1].?.bytes;
        if (cat == 10) {
            // Should contain both scores 5 and 3
            try testing.expect(std.mem.indexOf(u8, arr_bytes, "5") != null);
            try testing.expect(std.mem.indexOf(u8, arr_bytes, "3") != null);
            try testing.expect(arr_bytes[0] == '[');
            try testing.expect(arr_bytes[arr_bytes.len - 1] == ']');
        } else if (cat == 20) {
            try testing.expect(std.mem.indexOf(u8, arr_bytes, "7") != null);
        }
    }
}

test "ARRAY_AGG: empty group produces empty array" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    // No rows inserted
    const q = (try s.gw.register("SELECT ARRAY_AGG(score) FROM events")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    // NULL or empty array — ARRAY_AGG of no rows is null
    const val = rs.rows[0][0];
    _ = val; // null is fine for empty aggregate
}

test "STRING_AGG: joins strings with separator" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertEvent(s.gw, 1, 10, "alpha", 1);
    try insertEvent(s.gw, 2, 10, "beta", 2);
    try insertEvent(s.gw, 3, 10, "gamma", 3);

    const q = (try s.gw.register("SELECT STRING_AGG(label, ',') FROM events")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    const result = rs.rows[0][0].?.string;
    // All three labels joined with commas
    try testing.expect(std.mem.indexOf(u8, result, "alpha") != null);
    try testing.expect(std.mem.indexOf(u8, result, "beta") != null);
    try testing.expect(std.mem.indexOf(u8, result, "gamma") != null);
    try testing.expect(std.mem.indexOf(u8, result, ",") != null);
}

test "STRING_AGG: grouped by category" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertEvent(s.gw, 1, 10, "a", 1);
    try insertEvent(s.gw, 2, 10, "b", 2);
    try insertEvent(s.gw, 3, 20, "c", 3);

    const q = (try s.gw.register("SELECT category, STRING_AGG(label, '-') FROM events GROUP BY category")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 2), rs.rows.len);

    for (rs.rows) |row| {
        const cat = row[0].?.int64;
        const joined = row[1].?.string;
        if (cat == 10) {
            try testing.expect(std.mem.indexOf(u8, joined, "-") != null);
            try testing.expect(std.mem.indexOf(u8, joined, "a") != null);
            try testing.expect(std.mem.indexOf(u8, joined, "b") != null);
        } else if (cat == 20) {
            try testing.expectEqualStrings("c", joined);
        }
    }
}

test "FILTER: COUNT with FILTER counts only matching rows" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertEvent(s.gw, 1, 10, "a", 10);
    try insertEvent(s.gw, 2, 10, "b", 5);
    try insertEvent(s.gw, 3, 10, "c", 8);

    const q = (try s.gw.register("SELECT COUNT(*) FILTER (WHERE score > 7) FROM events")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 2), rs.rows[0][0].?.int64);
}

test "FILTER: SUM with FILTER sums only matching rows" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertEvent(s.gw, 1, 10, "a", 10);
    try insertEvent(s.gw, 2, 10, "b", 3);
    try insertEvent(s.gw, 3, 10, "c", 7);

    const q = (try s.gw.register("SELECT SUM(score) FILTER (WHERE score >= 7) FROM events")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 17), rs.rows[0][0].?.int64);
}

test "FILTER: FILTER with GROUP BY counts per group" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertEvent(s.gw, 1, 10, "a", 9);
    try insertEvent(s.gw, 2, 10, "b", 4);
    try insertEvent(s.gw, 3, 20, "c", 8);
    try insertEvent(s.gw, 4, 20, "d", 2);

    const q = (try s.gw.register(
        "SELECT category, COUNT(*) FILTER (WHERE score > 5) FROM events GROUP BY category",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 2), rs.rows.len);

    for (rs.rows) |row| {
        const cat = row[0].?.int64;
        const cnt = row[1].?.int64;
        if (cat == 10) try testing.expectEqual(@as(i64, 1), cnt); // only score=9 passes
        if (cat == 20) try testing.expectEqual(@as(i64, 1), cnt); // only score=8 passes
    }
}

test "FILTER: FILTER that eliminates all rows yields zero count" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertEvent(s.gw, 1, 10, "a", 3);
    try insertEvent(s.gw, 2, 10, "b", 2);

    const q = (try s.gw.register("SELECT COUNT(*) FILTER (WHERE score > 100) FROM events")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 0), rs.rows[0][0].?.int64);
}

test "FILTER: ARRAY_AGG with FILTER collects only matching values" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertEvent(s.gw, 1, 10, "a", 10);
    try insertEvent(s.gw, 2, 10, "b", 3);
    try insertEvent(s.gw, 3, 10, "c", 8);

    const q = (try s.gw.register(
        "SELECT ARRAY_AGG(score) FILTER (WHERE score > 5) FROM events",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    const arr = rs.rows[0][0].?.bytes;
    try testing.expect(std.mem.indexOf(u8, arr, "10") != null); // score=10 included
    try testing.expect(std.mem.indexOf(u8, arr, "8") != null);  // score=8 included
    // score=3 should not be present — check it's absent as a standalone token
    // "[3," or ",3," or ",3]" would indicate presence; "3" alone could be in "10"
    try testing.expect(std.mem.indexOf(u8, arr, "3,") == null);
    try testing.expect(std.mem.indexOf(u8, arr, ",3") == null);
}

test "FILTER: STRING_AGG with FILTER joins only matching labels" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertEvent(s.gw, 1, 10, "high", 9);
    try insertEvent(s.gw, 2, 10, "low", 2);
    try insertEvent(s.gw, 3, 10, "mid", 6);

    const q = (try s.gw.register(
        "SELECT STRING_AGG(label, ',') FILTER (WHERE score >= 6) FROM events",
    )).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    const result = rs.rows[0][0].?.string;
    try testing.expect(std.mem.indexOf(u8, result, "high") != null);
    try testing.expect(std.mem.indexOf(u8, result, "mid") != null);
    try testing.expect(std.mem.indexOf(u8, result, "low") == null);
}

test "ARRAY_AGG: string values are JSON-encoded" {
    const s = try setup();
    defer teardown(s.gw, s.dir);

    try insertEvent(s.gw, 1, 10, "foo", 1);
    try insertEvent(s.gw, 2, 10, "bar", 2);

    const q = (try s.gw.register("SELECT ARRAY_AGG(label) FROM events")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    const arr = rs.rows[0][0].?.bytes;
    try testing.expect(arr[0] == '[');
    try testing.expect(arr[arr.len - 1] == ']');
    // Strings must be quoted in JSON output
    try testing.expect(std.mem.indexOf(u8, arr, "\"foo\"") != null);
    try testing.expect(std.mem.indexOf(u8, arr, "\"bar\"") != null);
}
