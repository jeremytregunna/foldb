/// Gateway integration tests for ON CONFLICT DO NOTHING / DO UPDATE.
const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");

const Gateway = gateway_mod.Gateway;
const ColumnValue = gateway_mod.ColumnValue;

fn makeTempDir() ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/on_conflict_test_{d}", .{ns});
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

const COUNTERS_DDL = "CREATE TABLE counters (id INT64 NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))";

fn setupGateway() !struct { gw: *Gateway, dir: []const u8 } {
    const dir = try makeTempDir();
    const gw = try Gateway.init(dir, testing.allocator, .{});
    try gw.applyDdl(COUNTERS_DDL);
    return .{ .gw = gw, .dir = dir };
}

fn queryVal(gw: *Gateway, id: i64) !?i64 {
    const q = (try gw.register("SELECT val FROM counters WHERE id = $1")).hash;
    var rs = try gw.querySelect(q, &.{.{ .int64 = id }}, &.{});
    defer rs.deinit();
    if (rs.rows.len == 0) return null;
    return rs.rows[0][0].?.int64;
}

// ---- ON CONFLICT DO NOTHING ----

test "on conflict do nothing: non-conflicting insert succeeds normally" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    const ins = (try s.gw.register("INSERT INTO counters (id, val) VALUES ($1, $2) ON CONFLICT DO NOTHING")).hash;
    _ = try s.gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});

    try testing.expectEqual(@as(?i64, 10), try queryVal(s.gw, 1));
}

test "on conflict do nothing: conflicting insert leaves original row unchanged" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    const ins = (try s.gw.register("INSERT INTO counters (id, val) VALUES ($1, $2) ON CONFLICT DO NOTHING")).hash;
    _ = try s.gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});
    _ = try s.gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 99 } }, &.{});

    // Original val=10 must be preserved.
    try testing.expectEqual(@as(?i64, 10), try queryVal(s.gw, 1));
}

test "on conflict do nothing: conflicting insert still returns rows_affected 0" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    const ins = (try s.gw.register("INSERT INTO counters (id, val) VALUES ($1, $2) ON CONFLICT DO NOTHING")).hash;
    _ = try s.gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});
    const result = try s.gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 99 } }, &.{});

    // Conflict was skipped — no mutation appended.
    try testing.expectEqual(@as(u64, 0), result.rows_affected);
}

test "on conflict do nothing: only the conflicting row is skipped, others are inserted" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    const plain = (try s.gw.register("INSERT INTO counters (id, val) VALUES ($1, $2)")).hash;
    _ = try s.gw.execute(std.testing.io, plain, &.{ .{ .int64 = 1 }, .{ .int64 = 5 } }, &.{});

    // Multi-row insert: id=1 conflicts, id=2 is new.
    const ins2 = (try s.gw.register(
        \\TRANSACTION (a_id INT64, a_val INT64, b_id INT64, b_val INT64) {
        \\  INSERT INTO counters (id, val) VALUES ($a_id, $a_val) ON CONFLICT DO NOTHING;
        \\  INSERT INTO counters (id, val) VALUES ($b_id, $b_val) ON CONFLICT DO NOTHING;
        \\}
    )).hash;
    _ = try s.gw.execute(std.testing.io, ins2, &.{
        .{ .int64 = 1 }, .{ .int64 = 99 },
        .{ .int64 = 2 }, .{ .int64 = 20 },
    }, &.{});

    try testing.expectEqual(@as(?i64, 5), try queryVal(s.gw, 1)); // unchanged
    try testing.expectEqual(@as(?i64, 20), try queryVal(s.gw, 2)); // inserted
}

// ---- ON CONFLICT DO UPDATE ----

test "on conflict do update: non-conflicting insert succeeds normally" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    const ins = (try s.gw.register("INSERT INTO counters (id, val) VALUES ($1, $2) ON CONFLICT DO UPDATE SET val = $2")).hash;
    _ = try s.gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});

    try testing.expectEqual(@as(?i64, 10), try queryVal(s.gw, 1));
}

test "on conflict do update: conflicting insert updates the existing row" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    const ins = (try s.gw.register("INSERT INTO counters (id, val) VALUES ($1, $2) ON CONFLICT DO UPDATE SET val = $2")).hash;
    _ = try s.gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});
    _ = try s.gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 42 } }, &.{});

    try testing.expectEqual(@as(?i64, 42), try queryVal(s.gw, 1));
}

test "on conflict do update: SET can reference old column values (increment pattern)" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    // Upsert counter: on conflict, increment by the incoming value.
    const ins = (try s.gw.register("INSERT INTO counters (id, val) VALUES ($1, $2) ON CONFLICT DO UPDATE SET val = val + $2")).hash;
    _ = try s.gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 5 } }, &.{});
    _ = try s.gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 3 } }, &.{});
    _ = try s.gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 2 } }, &.{});

    // 5 + 3 + 2 = 10
    try testing.expectEqual(@as(?i64, 10), try queryVal(s.gw, 1));
}

test "on conflict do update: row count stays the same after upsert" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    const ins = (try s.gw.register("INSERT INTO counters (id, val) VALUES ($1, $2) ON CONFLICT DO UPDATE SET val = $2")).hash;
    _ = try s.gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 1 } }, &.{});
    _ = try s.gw.execute(std.testing.io, ins, &.{ .{ .int64 = 2 }, .{ .int64 = 2 } }, &.{});
    _ = try s.gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 9 } }, &.{}); // conflict on id=1

    const q = (try s.gw.register("SELECT id FROM counters")).hash;
    var rs = try s.gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 2), rs.rows.len);
}

test "on conflict do update: RETURNING returns the updated row on conflict" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    // Seed without RETURNING so the initial insert doesn't produce a result_set to manage.
    const seed = (try s.gw.register("INSERT INTO counters (id, val) VALUES ($1, $2)")).hash;
    _ = try s.gw.execute(std.testing.io, seed, &.{ .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});

    const ins = (try s.gw.register("INSERT INTO counters (id, val) VALUES ($1, $2) ON CONFLICT DO UPDATE SET val = val + $2 RETURNING id, val")).hash;
    const result = try s.gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 5 } }, &.{});
    try testing.expect(result.result_set != null);
    var rs = result.result_set.?;
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(i64, 1), rs.rows[0][0].?.int64); // id
    try testing.expectEqual(@as(i64, 15), rs.rows[0][1].?.int64); // val = 10 + 5
}

test "on conflict do nothing: RETURNING produces no rows on conflict" {
    const s = try setupGateway();
    defer {
        s.gw.deinit();
        removeDirRecursive(s.dir);
        testing.allocator.free(s.dir);
    }

    const seed = (try s.gw.register("INSERT INTO counters (id, val) VALUES ($1, $2)")).hash;
    _ = try s.gw.execute(std.testing.io, seed, &.{ .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});

    const ins = (try s.gw.register("INSERT INTO counters (id, val) VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING id, val")).hash;
    const result = try s.gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 99 } }, &.{});
    // DO NOTHING skipped the row — RETURNING should be empty (null or zero rows).
    if (result.result_set) |rs| {
        var mut_rs = rs;
        defer mut_rs.deinit();
        try testing.expectEqual(@as(usize, 0), mut_rs.rows.len);
    }
    // Original value unchanged.
    try testing.expectEqual(@as(?i64, 10), try queryVal(s.gw, 1));
}

test "on conflict do update: multiple column updates on conflict" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();
    try gw.applyDdl("CREATE TABLE kv (id INT64 NOT NULL, v1 INT64 NOT NULL, v2 INT64 NOT NULL, PRIMARY KEY (id))");

    const seed = (try gw.register("INSERT INTO kv (id, v1, v2) VALUES ($1, $2, $3)")).hash;
    _ = try gw.execute(std.testing.io, seed, &.{ .{ .int64 = 1 }, .{ .int64 = 10 }, .{ .int64 = 20 } }, &.{});

    const ins = (try gw.register("INSERT INTO kv (id, v1, v2) VALUES ($1, $2, $3) ON CONFLICT DO UPDATE SET v1 = $2, v2 = v2 + $3")).hash;
    _ = try gw.execute(std.testing.io, ins, &.{ .{ .int64 = 1 }, .{ .int64 = 5 }, .{ .int64 = 7 } }, &.{});

    const q = (try gw.register("SELECT v1, v2 FROM kv WHERE id = 1")).hash;
    var rs = try gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(i64, 5), rs.rows[0][0].?.int64); // v1 = new $2
    try testing.expectEqual(@as(i64, 27), rs.rows[0][1].?.int64); // v2 = 20 + 7
}
