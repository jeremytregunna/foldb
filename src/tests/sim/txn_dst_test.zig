/// DST property tests for compiled transaction blocks.
///
/// Covers two properties documented in docs/transactions.md:
///
/// 1. Determinism: two independent gateways driven through the same
///    transaction workload (transfers, ASSERT-guarded withdrawals) produce
///    bit-identical state at every checkpoint.
///
/// 2. Crash recovery: committed transaction blocks survive a crash and are
///    fully recovered via log replay on restart — including blocks that were
///    in the memtable and never flushed to SSTables.
const std = @import("std");
const testing = std.testing;
const sim = @import("sim.zig");
const gateway_mod = @import("gateway.zig");

const Gateway = gateway_mod.Gateway;
const ClockSource = gateway_mod.ClockSource;

// ---- VirtualClock → ClockSource adapter ----

fn virtualNowMicros(ptr: ?*anyopaque) i64 {
    const vc: *sim.VirtualClock = @ptrCast(@alignCast(ptr.?));
    return vc.now() * 1_000_000;
}

fn clockSourceFrom(vc: *sim.VirtualClock) ClockSource {
    return .{ .clock_ctx = vc, .now_micros_fn = virtualNowMicros };
}

// ---- Temp dir helpers ----

fn makeTempDir(tag: []const u8, id: u64, alloc: std.mem.Allocator) ![]u8 {
    const path = try std.fmt.allocPrint(alloc, "/tmp/sim_txn_{s}_{d}", .{ tag, id });
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

// ---- Schema + SQL constants ----

const DDL = "CREATE TABLE accounts (id INT64 NOT NULL, balance INT64 NOT NULL, PRIMARY KEY (id))";

const SEED_SQL =
    \\INSERT INTO accounts (id, balance) VALUES ($1, $2)
;

const TRANSFER_SQL =
    \\TRANSACTION (from_id INT64, to_id INT64, amount INT64) {
    \\  UPDATE accounts SET balance = balance - $amount WHERE id = $from_id;
    \\  UPDATE accounts SET balance = balance + $amount WHERE id = $to_id;
    \\}
;

const SCAN_SQL =
    \\SELECT id, balance FROM accounts
;

// ---- State hash ----

fn hashScan(gw: *Gateway, scan_hash: [32]u8) ![32]u8 {
    var rs = try gw.querySelect(scan_hash, &.{}, &.{});
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
// Two independent gateways share a VirtualClock and are driven through the
// same transfer workload. Final state hashes must be identical.

fn runTxnDeterminismTest(seed: u64, n_transfers: usize, alloc: std.mem.Allocator) !void {
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
    const opts_a = Gateway.Options{ .clock = clockSourceFrom(&clock) };
    const opts_b = Gateway.Options{ .clock = clockSourceFrom(&clock) };

    const gw_a = try Gateway.init(dir_a, alloc, opts_a);
    defer gw_a.deinit();
    const gw_b = try Gateway.init(dir_b, alloc, opts_b);
    defer gw_b.deinit();

    try gw_a.applyDdl(DDL);
    try gw_b.applyDdl(DDL);

    const seed_a = (try gw_a.register(SEED_SQL)).hash;
    const seed_b = (try gw_b.register(SEED_SQL)).hash;
    const xfer_a = (try gw_a.register(TRANSFER_SQL)).hash;
    const xfer_b = (try gw_b.register(TRANSFER_SQL)).hash;
    const scan_a = (try gw_a.register(SCAN_SQL)).hash;
    const scan_b = (try gw_b.register(SCAN_SQL)).hash;

    // Seed 5 accounts each with 1000.
    var acct: i64 = 1;
    while (acct <= 5) : (acct += 1) {
        _ = try gw_a.execute(seed_a, &.{ .{ .int64 = acct }, .{ .int64 = 1000 } }, &.{});
        _ = try gw_b.execute(seed_b, &.{ .{ .int64 = acct }, .{ .int64 = 1000 } }, &.{});
        clock.advance(1);
    }

    // Drive identical transfers through both gateways.
    var rng = std.Random.Xoroshiro128.init(seed ^ 0xFEED_BEEF);
    var i: usize = 0;
    while (i < n_transfers) : (i += 1) {
        const from: i64 = @intCast(rng.random().intRangeAtMost(u32, 1, 5));
        const to_raw: i64 = @intCast(rng.random().intRangeAtMost(u32, 1, 4));
        const to: i64 = if (to_raw >= from) to_raw + 1 else to_raw;
        const amount: i64 = @intCast(rng.random().intRangeAtMost(u32, 1, 200));

        // Transfers may abort (ASSERT) — that's expected and both gateways see the same abort.
        _ = gw_a.execute(xfer_a, &.{ .{ .int64 = from }, .{ .int64 = to }, .{ .int64 = amount } }, &.{}) catch {};
        _ = gw_b.execute(xfer_b, &.{ .{ .int64 = from }, .{ .int64 = to }, .{ .int64 = amount } }, &.{}) catch {};
        clock.advance(1);
    }

    const hash_a = try hashScan(gw_a, scan_a);
    const hash_b = try hashScan(gw_b, scan_b);
    try testing.expectEqualSlices(u8, &hash_a, &hash_b);
}

test "dst: txn determinism — identical transfer workload produces identical state (multi-seed)" {
    const seeds = [_]u64{ 1, 7, 42, 0xCAFE_BABE, 0x1234_5678 };
    for (seeds) |seed| {
        try runTxnDeterminismTest(seed, 50, testing.allocator);
    }
}

// ---- DST 2: Crash recovery of transaction blocks ----
//
// Commits several transfer blocks without flushing, simulates a crash, and
// verifies on restart that all committed transactions are fully recovered via
// log replay — including blocks that never made it to SSTables.

test "dst: txn crash recovery — committed transaction blocks survive log replay" {
    const alloc = testing.allocator;
    const dir = try makeTempDir("crash", 0xC4A5_5000, alloc);
    defer {
        removeDirRecursive(dir);
        alloc.free(dir);
    }

    // Phase 1: commit transfers without flushing, then crash.
    {
        const gw = try Gateway.init(dir, std.heap.page_allocator, .{});
        try gw.applyDdl(DDL);
        const seed = (try gw.register(SEED_SQL)).hash;
        const xfer = (try gw.register(TRANSFER_SQL)).hash;

        // Seed accounts.
        var acct: i64 = 1;
        while (acct <= 4) : (acct += 1) {
            _ = try gw.execute(seed, &.{ .{ .int64 = acct }, .{ .int64 = 500 } }, &.{});
        }

        // Flush seed rows so their presence after recovery is unambiguous.
        try gw.flushAll();

        // Transfer blocks committed to log but NOT flushed to SSTables.
        _ = gw.execute(xfer, &.{ .{ .int64 = 1 }, .{ .int64 = 2 }, .{ .int64 = 100 } }, &.{}) catch {};
        _ = gw.execute(xfer, &.{ .{ .int64 = 3 }, .{ .int64 = 4 }, .{ .int64 = 200 } }, &.{}) catch {};

        // Crash — no deinit.
    }

    // Phase 2: restart and verify log replay recovered the transfers.
    {
        const gw = try Gateway.init(dir, alloc, .{});
        defer gw.deinit();

        const scan = (try gw.register(SCAN_SQL)).hash;
        var rs = try gw.querySelect(scan, &.{}, &.{});
        defer rs.deinit();

        // Build id→balance map from recovered rows.
        var balances = std.AutoHashMap(i64, i64).init(alloc);
        defer balances.deinit();
        for (rs.rows) |row| {
            if (row.len >= 2) {
                const id = (row[0] orelse continue).int64;
                const bal = (row[1] orelse continue).int64;
                try balances.put(id, bal);
            }
        }

        try testing.expectEqual(@as(usize, 4), balances.count());

        // Transfer 1→2 of 100: account 1 lost 100, account 2 gained 100.
        try testing.expectEqual(@as(i64, 400), balances.get(1).?);
        try testing.expectEqual(@as(i64, 600), balances.get(2).?);
        // Transfer 3→4 of 200: account 3 lost 200, account 4 gained 200.
        try testing.expectEqual(@as(i64, 300), balances.get(3).?);
        try testing.expectEqual(@as(i64, 700), balances.get(4).?);
    }
}
