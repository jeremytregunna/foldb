/// DST property tests for subquery execution.
///
/// Covers two properties:
///
/// 1. Determinism: two independent gateways driven through the same workload
///    of INSERT + subquery-guarded transactions produce bit-identical state.
///
/// 2. Crash recovery: transactions that contain subquery-based ASSERTs and are
///    committed to the log (but not flushed) survive a crash and are correctly
///    recovered via log replay.
const std = @import("std");
const testing = std.testing;
const sim = @import("sim.zig");
const gateway_mod = @import("gateway.zig");

const Gateway = gateway_mod.Gateway;
const ColumnValue = gateway_mod.ColumnValue;
const ClockSource = gateway_mod.ClockSource;

// ---- VirtualClock adapter ----

fn virtualNowMicros(ptr: ?*anyopaque) i64 {
    const vc: *sim.VirtualClock = @ptrCast(@alignCast(ptr.?));
    return vc.now() * 1_000_000;
}

fn clockSourceFrom(vc: *sim.VirtualClock) ClockSource {
    return .{ .ptr = vc, .now_micros_fn = virtualNowMicros };
}

// ---- Temp dir helpers ----

fn makeTempDir(tag: []const u8, id: u64, alloc: std.mem.Allocator) ![]u8 {
    const path = try std.fmt.allocPrint(alloc, "/tmp/sim_subq_{s}_{d}", .{ tag, id });
    removeDirRecursive(path);
    const zpath = try alloc.allocSentinel(u8, path.len, 0);
    defer alloc.free(zpath);
    @memcpy(zpath[0..path.len], path);
    _ = std.os.linux.mkdir(zpath.ptr, 0o755);
    return path;
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

// ---- Schema + SQL ----

const USERS_DDL = "CREATE TABLE users (id INT64 NOT NULL, balance INT64 NOT NULL, PRIMARY KEY (id))";
const ORDERS_DDL = "CREATE TABLE orders (id INT64 NOT NULL, user_id INT64 NOT NULL, amount INT64 NOT NULL, PRIMARY KEY (id))";

const SEED_USER_SQL = "INSERT INTO users (id, balance) VALUES ($1, $2)";

// Insert an order only when the user's order count is below the cap.
// The ASSERT uses a scalar COUNT subquery — the core DST invariant.
const INSERT_ORDER_SQL =
    \\TRANSACTION (oid INT64, uid INT64, amt INT64, cap INT64) {
    \\  ASSERT (SELECT COUNT(*) FROM orders WHERE user_id = $uid) < $cap;
    \\  INSERT INTO orders (id, user_id, amount) VALUES ($oid, $uid, $amt);
    \\  UPDATE users SET balance = balance - $amt WHERE id = $uid;
    \\}
;

const SCAN_USERS_SQL = "SELECT id, balance FROM users";
const SCAN_ORDERS_SQL = "SELECT id, user_id, amount FROM orders";

// ---- State hash ----

// Scan order is deterministic: identical op sequences produce identical storage layout.
fn hashResultSet(gw: *Gateway, hash: [32]u8) ![32]u8 {
    var rs = try gw.querySelect(hash, &.{}, &.{});
    defer rs.deinit();

    var h = std.crypto.hash.Blake3.init(.{});
    var count_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &count_buf, rs.rows.len, .little);
    h.update(&count_buf);
    for (rs.rows) |row| {
        for (row) |maybe_cell| {
            if (maybe_cell) |cell| switch (cell) {
                .int64 => |v| {
                    var vb: [8]u8 = undefined;
                    std.mem.writeInt(i64, &vb, v, .little);
                    h.update(&vb);
                },
                else => {
                    var tmp: [64]u8 = undefined;
                    const s = std.fmt.bufPrint(&tmp, "{any}", .{cell}) catch continue;
                    h.update(s);
                },
            } else h.update(&[_]u8{0xFE});
        }
    }
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

// ---- DST 1: Determinism ----
//
// Two independent gateways are seeded identically and driven through the same
// sequence of INSERT_ORDER transactions (some will abort due to the ASSERT).
// Final state must be bit-identical on both.

fn runSubqueryDeterminismTest(seed: u64, n_ops: usize, alloc: std.mem.Allocator) !void {
    const dir_a = try makeTempDir("det_a", seed, alloc);
    defer {
        removeDirRecursive(dir_a);
        alloc.free(dir_a);
    }
    const dir_b = try makeTempDir("det_b", seed, alloc);
    defer {
        removeDirRecursive(dir_b);
        alloc.free(dir_b);
    }

    var clock = sim.VirtualClock.zero();
    const gw_a = try Gateway.init(dir_a, alloc, .{ .clock = clockSourceFrom(&clock) });
    defer gw_a.deinit();
    const gw_b = try Gateway.init(dir_b, alloc, .{ .clock = clockSourceFrom(&clock) });
    defer gw_b.deinit();

    try gw_a.applyDdl(USERS_DDL);
    try gw_a.applyDdl(ORDERS_DDL);
    try gw_b.applyDdl(USERS_DDL);
    try gw_b.applyDdl(ORDERS_DDL);

    const seed_a = (try gw_a.register(SEED_USER_SQL)).hash;
    const seed_b = (try gw_b.register(SEED_USER_SQL)).hash;
    const ins_a = (try gw_a.register(INSERT_ORDER_SQL)).hash;
    const ins_b = (try gw_b.register(INSERT_ORDER_SQL)).hash;
    const scan_users_a = (try gw_a.register(SCAN_USERS_SQL)).hash;
    const scan_users_b = (try gw_b.register(SCAN_USERS_SQL)).hash;
    const scan_orders_a = (try gw_a.register(SCAN_ORDERS_SQL)).hash;
    const scan_orders_b = (try gw_b.register(SCAN_ORDERS_SQL)).hash;

    // Seed 4 users each with 10000.
    var uid: i64 = 1;
    while (uid <= 4) : (uid += 1) {
        _ = try gw_a.execute(seed_a, &.{ .{ .int64 = uid }, .{ .int64 = 10_000 } }, &.{});
        _ = try gw_b.execute(seed_b, &.{ .{ .int64 = uid }, .{ .int64 = 10_000 } }, &.{});
        clock.advance(1);
    }

    // Drive identical INSERT_ORDER operations. Cap=2 so some will abort.
    var rng = std.Random.Xoroshiro128.init(seed ^ 0xDEAD_BEEF);
    var i: usize = 0;
    while (i < n_ops) : (i += 1) {
        const order_id: i64 = @intCast(100 + i);
        const user_id: i64 = @intCast(rng.random().intRangeAtMost(u32, 1, 4));
        const amount: i64 = @intCast(rng.random().intRangeAtMost(u32, 10, 500));
        const cap: i64 = 2;

        _ = gw_a.execute(ins_a, &.{
            .{ .int64 = order_id }, .{ .int64 = user_id },
            .{ .int64 = amount },   .{ .int64 = cap },
        }, &.{}) catch {};
        _ = gw_b.execute(ins_b, &.{
            .{ .int64 = order_id }, .{ .int64 = user_id },
            .{ .int64 = amount },   .{ .int64 = cap },
        }, &.{}) catch {};
        clock.advance(1);
    }

    const users_hash_a = try hashResultSet(gw_a, scan_users_a);
    const users_hash_b = try hashResultSet(gw_b, scan_users_b);
    try testing.expectEqualSlices(u8, &users_hash_a, &users_hash_b);

    const orders_hash_a = try hashResultSet(gw_a, scan_orders_a);
    const orders_hash_b = try hashResultSet(gw_b, scan_orders_b);
    try testing.expectEqualSlices(u8, &orders_hash_a, &orders_hash_b);
}

test "dst: subquery determinism — identical workload with COUNT ASSERT produces identical state (multi-seed)" {
    const seeds = [_]u64{ 1, 7, 42, 0xCAFE_BABE, 0x1234_5678 };
    for (seeds) |s| {
        try runSubqueryDeterminismTest(s, 30, testing.allocator);
    }
}

// ---- DST 2: Crash recovery ----
//
// Commits several subquery-guarded INSERT_ORDER transactions without flushing,
// then crashes. On restart, log replay must recover the correct final state.

test "dst: subquery crash recovery — COUNT-guarded inserts survive log replay" {
    const alloc = testing.allocator;
    const dir = try makeTempDir("crash", 0xB0BB_DEAF, alloc);
    defer {
        removeDirRecursive(dir);
        alloc.free(dir);
    }

    // Phase 1: seed + commit transactions, crash without flush.
    {
        const gw = try Gateway.init(dir, std.heap.page_allocator, .{});
        try gw.applyDdl(USERS_DDL);
        try gw.applyDdl(ORDERS_DDL);

        const seed = (try gw.register(SEED_USER_SQL)).hash;
        const ins = (try gw.register(INSERT_ORDER_SQL)).hash;

        _ = try gw.execute(seed, &.{ .{ .int64 = 1 }, .{ .int64 = 5_000 } }, &.{});
        _ = try gw.execute(seed, &.{ .{ .int64 = 2 }, .{ .int64 = 5_000 } }, &.{});

        // Flush seed so the baseline is in SSTables.
        try gw.flushAll();

        // Three INSERT_ORDER transactions committed to log but NOT flushed.
        // cap=3 so all pass. order_ids: 10, 11, 12.
        _ = try gw.execute(ins, &.{ .{ .int64 = 10 }, .{ .int64 = 1 }, .{ .int64 = 100 }, .{ .int64 = 3 } }, &.{});
        _ = try gw.execute(ins, &.{ .{ .int64 = 11 }, .{ .int64 = 1 }, .{ .int64 = 200 }, .{ .int64 = 3 } }, &.{});
        _ = try gw.execute(ins, &.{ .{ .int64 = 12 }, .{ .int64 = 2 }, .{ .int64 = 300 }, .{ .int64 = 3 } }, &.{});

        // Crash — no deinit.
    }

    // Phase 2: restart and verify all three orders survived.
    {
        const gw = try Gateway.init(dir, alloc, .{});
        defer gw.deinit();

        const scan_users = (try gw.register(SCAN_USERS_SQL)).hash;
        const scan_orders = (try gw.register(SCAN_ORDERS_SQL)).hash;

        var users_rs = try gw.querySelect(scan_users, &.{}, &.{});
        defer users_rs.deinit();
        var orders_rs = try gw.querySelect(scan_orders, &.{}, &.{});
        defer orders_rs.deinit();

        try testing.expectEqual(@as(usize, 2), users_rs.rows.len);
        try testing.expectEqual(@as(usize, 3), orders_rs.rows.len);

        // Build balance map.
        var balances = std.AutoHashMap(i64, i64).init(alloc);
        defer balances.deinit();
        for (users_rs.rows) |row| {
            if (row.len >= 2) try balances.put((row[0] orelse continue).int64, (row[1] orelse continue).int64);
        }

        // user 1: 5000 - 100 - 200 = 4700
        try testing.expectEqual(@as(i64, 4_700), balances.get(1).?);
        // user 2: 5000 - 300 = 4700
        try testing.expectEqual(@as(i64, 4_700), balances.get(2).?);
    }
}

// ---- DST 3: ASSERT abort is not replayed ----
//
// Verifies that a transaction aborted by a subquery ASSERT leaves no trace
// after crash recovery — the abort is not mistakenly re-applied.

test "dst: subquery ASSERT abort leaves no state after crash recovery" {
    const alloc = testing.allocator;
    const dir = try makeTempDir("abort", 0xAB04_DEAD, alloc);
    defer {
        removeDirRecursive(dir);
        alloc.free(dir);
    }

    {
        const gw = try Gateway.init(dir, std.heap.page_allocator, .{});
        try gw.applyDdl(USERS_DDL);
        try gw.applyDdl(ORDERS_DDL);

        const seed = (try gw.register(SEED_USER_SQL)).hash;
        const ins = (try gw.register(INSERT_ORDER_SQL)).hash;

        _ = try gw.execute(seed, &.{ .{ .int64 = 1 }, .{ .int64 = 1_000 } }, &.{});
        try gw.flushAll();

        // Insert one order successfully.
        _ = try gw.execute(ins, &.{ .{ .int64 = 1 }, .{ .int64 = 1 }, .{ .int64 = 100 }, .{ .int64 = 1 } }, &.{});

        // This must abort: cap=1 and user 1 already has 1 order.
        _ = gw.execute(ins, &.{ .{ .int64 = 2 }, .{ .int64 = 1 }, .{ .int64 = 50 }, .{ .int64 = 1 } }, &.{}) catch {};

        // Crash — no deinit.
    }

    {
        const gw = try Gateway.init(dir, alloc, .{});
        defer gw.deinit();

        const scan_orders = (try gw.register(SCAN_ORDERS_SQL)).hash;
        var rs = try gw.querySelect(scan_orders, &.{}, &.{});
        defer rs.deinit();

        // Only the first (successful) order should exist.
        try testing.expectEqual(@as(usize, 1), rs.rows.len);
        try testing.expectEqual(@as(i64, 1), rs.rows[0][0].?.int64);
    }
}
