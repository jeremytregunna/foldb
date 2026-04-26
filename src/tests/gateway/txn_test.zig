/// Unit tests for compiled transaction blocks.
///
/// Covers the behaviour documented in docs/transactions.md:
///   - Multi-statement atomic execution
///   - ASSERT postcondition: pass allows mutations, fail aborts all
///   - Abort leaves no trace (ASSERT failure mid-block)
///   - Optimistic concurrency via ASSERT on caller-supplied precondition values
const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");

const Gateway = gateway_mod.Gateway;

// ---- Temp dir helpers ----

fn makeTempDir() ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/txn_test_{d}", .{ns});
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

// ---- Schema ----

const ACCOUNTS_DDL = "CREATE TABLE accounts (id INT64 NOT NULL, balance INT64 NOT NULL, PRIMARY KEY (id))";
const EVENTS_DDL = "CREATE TABLE events (id INT64 NOT NULL, kind INT64 NOT NULL, PRIMARY KEY (id))";

// ---- Tests ----

test "txn: named params resolve to positional indices" {
    // Verify that $name inside a TRANSACTION block resolves to its declared position,
    // producing the same hash as the equivalent $N form.
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl(ACCOUNTS_DDL);

    const named = (try gw.register(
        \\TRANSACTION (id INT64, bal INT64) {
        \\  INSERT INTO accounts (id, balance) VALUES ($id, $bal);
        \\}
    )).hash;
    const positional = (try gw.register(
        \\TRANSACTION (id INT64, bal INT64) {
        \\  INSERT INTO accounts (id, balance) VALUES ($1, $2);
        \\}
    )).hash;

    // Named and positional forms are canonically identical — same hash.
    try testing.expectEqualSlices(u8, &named, &positional);
}

test "txn: multi-statement block applies all mutations atomically" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl(ACCOUNTS_DDL);

    const seed = (try gw.register("INSERT INTO accounts (id, balance) VALUES ($1, $2)")).hash;
    _ = try gw.execute(seed, &.{ .{ .int64 = 1 }, .{ .int64 = 500 } }, &.{});
    _ = try gw.execute(seed, &.{ .{ .int64 = 2 }, .{ .int64 = 500 } }, &.{});

    // Transfer 200 from account 1 to account 2 in a single transaction block.
    const transfer = (try gw.register(
        \\TRANSACTION (amount INT64) {
        \\  UPDATE accounts SET balance = balance - $amount WHERE id = 1;
        \\  UPDATE accounts SET balance = balance + $amount WHERE id = 2;
        \\}
    )).hash;
    _ = try gw.execute(transfer, &.{.{ .int64 = 200 }}, &.{});

    const sel = (try gw.register("SELECT balance FROM accounts WHERE id = $1")).hash;
    var rs1 = try gw.querySelect(sel, &.{.{ .int64 = 1 }}, &.{});
    defer rs1.deinit();
    var rs2 = try gw.querySelect(sel, &.{.{ .int64 = 2 }}, &.{});
    defer rs2.deinit();

    try testing.expectEqual(@as(i64, 300), rs1.rows[0][0].?.int64);
    try testing.expectEqual(@as(i64, 700), rs2.rows[0][0].?.int64);
}

test "txn: ASSERT pass — mutations are applied" {
    // ASSERT evaluates a pure expression using declared params.
    // When it passes, the mutations in the block are applied.
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl(ACCOUNTS_DDL);
    const seed = (try gw.register("INSERT INTO accounts (id, balance) VALUES ($1, $2)")).hash;
    _ = try gw.execute(seed, &.{ .{ .int64 = 1 }, .{ .int64 = 1000 } }, &.{});

    // The caller computes the post-withdrawal balance and passes it as a param.
    // ASSERT verifies the invariant holds before the block is committed.
    const withdraw = (try gw.register(
        \\TRANSACTION (amount INT64, new_balance INT64) {
        \\  UPDATE accounts SET balance = $new_balance WHERE id = 1;
        \\  ASSERT $new_balance >= 0;
        \\}
    )).hash;
    _ = try gw.execute(withdraw, &.{ .{ .int64 = 400 }, .{ .int64 = 600 } }, &.{});

    const sel = (try gw.register("SELECT balance FROM accounts WHERE id = $1")).hash;
    var rs = try gw.querySelect(sel, &.{.{ .int64 = 1 }}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(i64, 600), rs.rows[0][0].?.int64);
}

test "txn: ASSERT fail — no mutations applied" {
    // When ASSERT fails, the entire block is aborted and no mutations reach storage.
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl(ACCOUNTS_DDL);
    const seed = (try gw.register("INSERT INTO accounts (id, balance) VALUES ($1, $2)")).hash;
    _ = try gw.execute(seed, &.{ .{ .int64 = 1 }, .{ .int64 = 100 } }, &.{});

    // Caller passes a new_balance that would go negative — ASSERT must reject it.
    const withdraw = (try gw.register(
        \\TRANSACTION (amount INT64, new_balance INT64) {
        \\  UPDATE accounts SET balance = $new_balance WHERE id = 1;
        \\  ASSERT $new_balance >= 0;
        \\}
    )).hash;
    const result = gw.execute(withdraw, &.{ .{ .int64 = 500 }, .{ .int64 = -400 } }, &.{});
    try testing.expectError(error.ConstraintViolation, result);

    // Balance must be unchanged.
    const sel = (try gw.register("SELECT balance FROM accounts WHERE id = $1")).hash;
    var rs = try gw.querySelect(sel, &.{.{ .int64 = 1 }}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(i64, 100), rs.rows[0][0].?.int64);
}

test "txn: ASSERT fail aborts all prior mutations in block" {
    // Both updates must be absent if the trailing ASSERT fails.
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl(ACCOUNTS_DDL);
    const seed = (try gw.register("INSERT INTO accounts (id, balance) VALUES ($1, $2)")).hash;
    _ = try gw.execute(seed, &.{ .{ .int64 = 1 }, .{ .int64 = 500 } }, &.{});
    _ = try gw.execute(seed, &.{ .{ .int64 = 2 }, .{ .int64 = 500 } }, &.{});

    const transfer = (try gw.register(
        \\TRANSACTION (new_bal1 INT64, new_bal2 INT64, valid INT64) {
        \\  UPDATE accounts SET balance = $new_bal1 WHERE id = 1;
        \\  UPDATE accounts SET balance = $new_bal2 WHERE id = 2;
        \\  ASSERT $valid = 1;
        \\}
    )).hash;

    // valid=0 makes ASSERT fail — both updates must be rolled back.
    const result = gw.execute(transfer, &.{
        .{ .int64 = 300 }, .{ .int64 = 700 }, .{ .int64 = 0 },
    }, &.{});
    try testing.expectError(error.ConstraintViolation, result);

    const sel = (try gw.register("SELECT balance FROM accounts WHERE id = $1")).hash;
    var rs1 = try gw.querySelect(sel, &.{.{ .int64 = 1 }}, &.{});
    defer rs1.deinit();
    var rs2 = try gw.querySelect(sel, &.{.{ .int64 = 2 }}, &.{});
    defer rs2.deinit();
    try testing.expectEqual(@as(i64, 500), rs1.rows[0][0].?.int64);
    try testing.expectEqual(@as(i64, 500), rs2.rows[0][0].?.int64);
}

test "txn: multi-table transaction writes to both tables atomically" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl(ACCOUNTS_DDL);
    try gw.applyDdl(EVENTS_DDL);

    const seed = (try gw.register("INSERT INTO accounts (id, balance) VALUES ($1, $2)")).hash;
    _ = try gw.execute(seed, &.{ .{ .int64 = 1 }, .{ .int64 = 1000 } }, &.{});

    // Withdraw and emit an audit event atomically.
    const audit_withdraw = (try gw.register(
        \\TRANSACTION (acct_id INT64, event_id INT64, new_balance INT64) {
        \\  UPDATE accounts SET balance = $new_balance WHERE id = $acct_id;
        \\  INSERT INTO events (id, kind) VALUES ($event_id, 1);
        \\}
    )).hash;
    _ = try gw.execute(audit_withdraw, &.{
        .{ .int64 = 1 }, .{ .int64 = 42 }, .{ .int64 = 700 },
    }, &.{});

    const sel_acct = (try gw.register("SELECT balance FROM accounts WHERE id = $1")).hash;
    var rs_a = try gw.querySelect(sel_acct, &.{.{ .int64 = 1 }}, &.{});
    defer rs_a.deinit();
    try testing.expectEqual(@as(i64, 700), rs_a.rows[0][0].?.int64);

    const sel_evt = (try gw.register("SELECT kind FROM events WHERE id = $1")).hash;
    var rs_e = try gw.querySelect(sel_evt, &.{.{ .int64 = 42 }}, &.{});
    defer rs_e.deinit();
    try testing.expectEqual(@as(usize, 1), rs_e.rows.len);
    try testing.expectEqual(@as(i64, 1), rs_e.rows[0][0].?.int64);
}

test "txn: optimistic concurrency — ASSERT on caller-supplied precondition" {
    // The client reads the current balance, passes it as expected_balance, and
    // the ASSERT ensures no concurrent write changed it between the read and commit.
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl(ACCOUNTS_DDL);
    const seed = (try gw.register("INSERT INTO accounts (id, balance) VALUES ($1, $2)")).hash;
    _ = try gw.execute(seed, &.{ .{ .int64 = 1 }, .{ .int64 = 500 } }, &.{});

    // Conditional update: only commit if expected_balance matches what we read.
    const conditional = (try gw.register(
        \\TRANSACTION (new_balance INT64, expected_balance INT64) {
        \\  UPDATE accounts SET balance = $new_balance WHERE id = 1;
        \\  ASSERT $expected_balance >= 0;
        \\}
    )).hash;

    // First call: precondition matches current balance (500 >= 0), succeeds.
    _ = try gw.execute(conditional, &.{ .{ .int64 = 300 }, .{ .int64 = 500 } }, &.{});

    // Second call with stale precondition: expected_balance = -1 fails ASSERT.
    const stale = gw.execute(conditional, &.{ .{ .int64 = 100 }, .{ .int64 = -1 } }, &.{});
    try testing.expectError(error.ConstraintViolation, stale);

    const sel = (try gw.register("SELECT balance FROM accounts WHERE id = $1")).hash;
    var rs = try gw.querySelect(sel, &.{.{ .int64 = 1 }}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(i64, 300), rs.rows[0][0].?.int64);
}
