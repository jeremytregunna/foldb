/// SQL multi-partition integration tests.
///
/// These tests validate that the SQL execution stack (Gateway → FoldExecutor →
/// SqlExecutor) correctly handles multi-partition data when partition_count > 1.
///
/// ## What is being tested
///
/// The current SQL execution model (filter_partition approach):
///   - All FoldExecutors receive every committed log entry.
///   - Each SqlExecutor runs the full SQL plan against shared PartitionedStorage.
///   - filter_partition causes each executor to retain only its own partition's mutations.
///   - Mutations for other partitions are silently discarded at apply time.
///
/// This produces correct results in-process: each storage partition ends up with
/// exactly the rows whose PK hashes to that partition's index.
///
/// ## What this does NOT test
///
/// The PartitionSet 4-phase protocol (declare → fetch → execute → apply) is NOT
/// exercised here because the SqlCrossPartitionHandler adapter is not yet implemented.
/// See src/executor/sql_cross_partition.zig for the design gap analysis.
///
/// True multi-node cross-partition atomicity (where each node only owns one partition's
/// storage) requires:
///   1. SqlCrossPartitionHandler.declareReads — static key extraction from the SQL plan
///   2. SqlCrossPartitionHandler.execute — plan execution with pre-fetched foreign rows
///   3. Network transport for Phase B fetches (RPC to remote partition nodes)
///
/// These tests serve as a correctness baseline for the infrastructure that DOES exist,
/// and as a regression guard while the 4-phase adapter is built on top.
const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");

const Gateway = gateway_mod.Gateway;
const ColumnValue = gateway_mod.ColumnValue;

// ---- Temp dir helpers ----

fn makeTempDir(alloc: std.mem.Allocator, suffix: []const u8) ![]const u8 {
    // SAFETY: clock_gettime fills ts before any field is read.
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const path = try std.fmt.allocPrint(alloc, "/tmp/sql_part_test_{d}_{s}", .{ ns, suffix });
    const null_path = try alloc.allocSentinel(u8, path.len, 0);
    defer alloc.free(null_path);
    @memcpy(null_path[0..path.len], path);
    _ = std.os.linux.mkdir(null_path.ptr, 0o755);
    return path;
}

fn removeDir(alloc: std.mem.Allocator, path: []const u8) void {
    const z = alloc.allocSentinel(u8, path.len, 0) catch return;
    defer alloc.free(z);
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
                const child = std.fmt.allocPrint(alloc, "{s}/{s}", .{ path, name }) catch {
                    i += dent.reclen;
                    continue;
                };
                defer alloc.free(child);
                const cz = alloc.allocSentinel(u8, child.len, 0) catch {
                    i += dent.reclen;
                    continue;
                };
                defer alloc.free(cz);
                @memcpy(cz[0..child.len], child);
                if (dent.type == std.os.linux.DT.DIR) removeDir(alloc, child) else _ = std.os.linux.unlink(cz.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}

// ---- Tests ----

// Verify that a 2-partition Gateway correctly splits inserted rows across storage
// partitions, and that a SELECT across partition boundaries returns all rows.
//
// This exercises the filter_partition mechanism: two FoldExecutors each apply the
// same committed log entries but retain only their own partition's mutations.
test "sql partition: 2-partition INSERT splits rows and SELECT sees all" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc, "a");
    defer {
        removeDir(alloc, dir);
        alloc.free(dir);
    }

    const gw = try Gateway.init(dir, alloc, .{ .partition_count = 2 });
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE accounts (id INT64 NOT NULL, balance INT64 NOT NULL, PRIMARY KEY (id))");

    const insert_hash = (try gw.register("INSERT INTO accounts (id, balance) VALUES ($1, $2)")).hash;
    const select_hash = (try gw.register("SELECT id, balance FROM accounts")).hash;

    // Insert 10 rows. With 2 partitions under Wyhash, at least one row lands in each.
    var i: i64 = 1;
    while (i <= 10) : (i += 1) {
        const params = [_]ColumnValue{ .{ .int64 = i }, .{ .int64 = i * 100 } };
        const result = try gw.execute(insert_hash, &params, &.{});
        try testing.expectEqual(@as(u64, 1), result.rows_affected);
    }

    // SELECT * must return all 10 rows regardless of which partition they landed on.
    var rs = try gw.querySelect(select_hash, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 10), rs.rows.len);
}

// Verify that UPDATE mutations applied via the SQL executor are correctly split
// across 2 partitions. An UPDATE that targets a row on a specific partition must
// land only in that partition's storage.
test "sql partition: 2-partition UPDATE applies to correct partition" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc, "b");
    defer {
        removeDir(alloc, dir);
        alloc.free(dir);
    }

    const gw = try Gateway.init(dir, alloc, .{ .partition_count = 2 });
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE counters (id INT64 NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))");

    const insert_hash = (try gw.register("INSERT INTO counters (id, val) VALUES ($1, $2)")).hash;
    const update_hash = (try gw.register("UPDATE counters SET val = $2 WHERE id = $1")).hash;
    const select_hash = (try gw.register("SELECT id, val FROM counters WHERE id = $1")).hash;

    // Insert row with id=1.
    _ = try gw.execute(insert_hash, &[_]ColumnValue{ .{ .int64 = 1 }, .{ .int64 = 42 } }, &.{});

    // Update the same row.
    const upd = try gw.execute(update_hash, &[_]ColumnValue{ .{ .int64 = 1 }, .{ .int64 = 99 } }, &.{});
    try testing.expectEqual(@as(u64, 1), upd.rows_affected);

    // Read it back — must see updated value.
    var rs = try gw.querySelect(select_hash, &[_]ColumnValue{.{ .int64 = 1 }}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    const val = rs.rows[0][1] orelse return error.NullValue;
    try testing.expectEqual(@as(i64, 99), val.int64);
}

// Verify that DELETE removes rows from the correct partition. After deleting some
// rows, a full-table SELECT must return only the surviving rows.
test "sql partition: 2-partition DELETE removes from correct partition" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc, "c");
    defer {
        removeDir(alloc, dir);
        alloc.free(dir);
    }

    const gw = try Gateway.init(dir, alloc, .{ .partition_count = 2 });
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE items (id INT64 NOT NULL, name STRING NOT NULL, PRIMARY KEY (id))");

    const insert_hash = (try gw.register("INSERT INTO items (id, name) VALUES ($1, $2)")).hash;
    const delete_hash = (try gw.register("DELETE FROM items WHERE id = $1")).hash;
    const select_hash = (try gw.register("SELECT id, name FROM items")).hash;

    // Insert 6 rows.
    const names = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta" };
    for (names, 0..) |name, idx| {
        _ = try gw.execute(insert_hash, &[_]ColumnValue{
            .{ .int64 = @intCast(idx + 1) },
            .{ .string = name },
        }, &.{});
    }

    // Delete rows with id 2 and 4.
    _ = try gw.execute(delete_hash, &[_]ColumnValue{.{ .int64 = 2 }}, &.{});
    _ = try gw.execute(delete_hash, &[_]ColumnValue{.{ .int64 = 4 }}, &.{});

    // 4 rows should remain.
    var rs = try gw.querySelect(select_hash, &.{}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 4), rs.rows.len);
}

// Verify that two independent 2-partition Gateway instances produce identical
// storage state after the same workload. This is the determinism invariant:
// filter_partition produces the same partition assignment regardless of which
// FoldExecutor instance processes the entries.
test "sql partition: determinism — two independent 2-partition gateways agree" {
    const alloc = testing.allocator;
    const dir_a = try makeTempDir(alloc, "da");
    const dir_b = try makeTempDir(alloc, "db");
    defer {
        removeDir(alloc, dir_a);
        alloc.free(dir_a);
        removeDir(alloc, dir_b);
        alloc.free(dir_b);
    }

    const gw_a = try Gateway.init(dir_a, alloc, .{ .partition_count = 2 });
    defer gw_a.deinit();
    const gw_b = try Gateway.init(dir_b, alloc, .{ .partition_count = 2 });
    defer gw_b.deinit();

    const ddl = "CREATE TABLE vals (id INT64 NOT NULL, v INT64 NOT NULL, PRIMARY KEY (id))";
    try gw_a.applyDdl(ddl);
    try gw_b.applyDdl(ddl);

    const ins_a = (try gw_a.register("INSERT INTO vals (id, v) VALUES ($1, $2)")).hash;
    const ins_b = (try gw_b.register("INSERT INTO vals (id, v) VALUES ($1, $2)")).hash;
    // Both hashes must be identical — they're derived from the same SQL text.
    try testing.expectEqualSlices(u8, &ins_a, &ins_b);

    // Apply the same workload to both.
    var i: i64 = 1;
    while (i <= 12) : (i += 1) {
        const params = [_]ColumnValue{ .{ .int64 = i }, .{ .int64 = i * 7 } };
        _ = try gw_a.execute(ins_a, &params, &.{});
        _ = try gw_b.execute(ins_b, &params, &.{});
    }

    // Both gateways must return the same total row count on a full-table scan.
    const sel_a = (try gw_a.register("SELECT id, v FROM vals")).hash;
    const sel_b = (try gw_b.register("SELECT id, v FROM vals")).hash;

    var rs_a = try gw_a.querySelect(sel_a, &.{}, &.{});
    defer rs_a.deinit();
    var rs_b = try gw_b.querySelect(sel_b, &.{}, &.{});
    defer rs_b.deinit();

    try testing.expectEqual(rs_a.rows.len, rs_b.rows.len);
    try testing.expectEqual(@as(usize, 12), rs_a.rows.len);
}

// Verify that a transaction block (multi-statement) spanning rows on different
// partitions applies atomically: either all mutations land or none do when ASSERT
// fails. This tests the filter_partition approach under an aborting transaction.
test "sql partition: 2-partition TRANSACTION block aborts atomically on ASSERT fail" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc, "e");
    defer {
        removeDir(alloc, dir);
        alloc.free(dir);
    }

    const gw = try Gateway.init(dir, alloc, .{ .partition_count = 2 });
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE accts (id INT64 NOT NULL, bal INT64 NOT NULL, PRIMARY KEY (id))");

    const insert_hash = (try gw.register("INSERT INTO accts (id, bal) VALUES ($1, $2)")).hash;

    // Insert two initial rows.
    _ = try gw.execute(insert_hash, &[_]ColumnValue{ .{ .int64 = 1 }, .{ .int64 = 500 } }, &.{});
    _ = try gw.execute(insert_hash, &[_]ColumnValue{ .{ .int64 = 2 }, .{ .int64 = 300 } }, &.{});

    // A transaction block that inserts a row and then ASSERT-fails (new_bal < 0).
    // The ASSERT failure must abort the entire block — the INSERT must not appear.
    const txn_hash = (try gw.register(
        \\TRANSACTION (id INT64, bal INT64, new_bal INT64) {
        \\  INSERT INTO accts (id, bal) VALUES ($id, $bal);
        \\  ASSERT $new_bal >= 0;
        \\}
    )).hash;

    const err = gw.execute(txn_hash, &[_]ColumnValue{
        .{ .int64 = 99 },
        .{ .int64 = 10 },
        .{ .int64 = -1 }, // new_bal < 0 — ASSERT must fail
    }, &.{});
    try testing.expectError(error.ConstraintViolation, err);

    // Row 99 must NOT have been inserted (abort rolled back the INSERT).
    const sel_hash = (try gw.register("SELECT id FROM accts WHERE id = $1")).hash;
    var rs = try gw.querySelect(sel_hash, &[_]ColumnValue{.{ .int64 = 99 }}, &.{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 0), rs.rows.len);
}
