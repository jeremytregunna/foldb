/// DST: two Gateway instances fed identical DDL + DML sequences must produce byte-equal SSTables.
/// Covers: normal INSERT/UPDATE/DELETE workload, multi-table operations, compaction-triggering load.
const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");
const storage_mod = @import("storage.zig");

const Gateway = gateway_mod.Gateway;
const ColumnValue = gateway_mod.ColumnValue;

// ─── Temp dir / file helpers ──────────────────────────────────────────────────

fn makeTempDir(alloc: std.mem.Allocator, suffix: u64) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "/tmp/gw_replay_{d}", .{suffix});
    const null_path = try alloc.allocSentinel(u8, path.len, 0);
    defer alloc.free(null_path);
    @memcpy(null_path[0..path.len], path);
    _ = std.os.linux.mkdir(null_path.ptr, 0o755);
    return path;
}

fn removeDir(path: []const u8) void {
    const null_path = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(null_path);
    @memcpy(null_path[0..path.len], path);
    const raw_fd = std.os.linux.open(null_path.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    const fd: std.posix.fd_t = @intCast(@as(isize, @bitCast(raw_fd)));
    if (fd < 0) return;
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
                const child = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ path, name }) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(child);
                const null_child = std.heap.page_allocator.allocSentinel(u8, child.len, 0) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(null_child);
                @memcpy(null_child[0..child.len], child);
                if (dent.type == std.os.linux.DT.DIR) removeDir(child) else _ = std.os.linux.unlink(null_child.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(null_path.ptr);
}

fn listSstFiles(dir: []const u8, alloc: std.mem.Allocator) ![][]const u8 {
    const null_path = try std.heap.page_allocator.allocSentinel(u8, dir.len, 0);
    defer std.heap.page_allocator.free(null_path);
    @memcpy(null_path[0..dir.len], dir);
    const raw_fd = std.os.linux.open(null_path.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    const fd: std.posix.fd_t = @intCast(@as(isize, @bitCast(raw_fd)));
    if (fd < 0) return &.{};
    defer _ = std.os.linux.close(@intCast(fd));
    var files: std.ArrayList([]const u8) = .empty;
    var buf: [4096]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    while (true) {
        const ret = std.os.linux.getdents64(@intCast(fd), &buf, buf.len);
        const n: isize = @bitCast(ret);
        if (n <= 0) break;
        var i: usize = 0;
        while (i < @as(usize, @intCast(n))) {
            const dent: *const std.os.linux.dirent64 = @ptrCast(@alignCast(buf[i..].ptr));
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&dent.name)));
            if (std.mem.endsWith(u8, name, ".sst")) {
                const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
                try files.append(alloc, full);
            }
            i += dent.reclen;
        }
    }
    const result = try files.toOwnedSlice(alloc);
    std.mem.sort([]const u8, result, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return result;
}

fn readFileBytes(path: []const u8, alloc: std.mem.Allocator) ![]u8 {
    const null_path = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    defer std.heap.page_allocator.free(null_path);
    @memcpy(null_path[0..path.len], path);
    const raw_fd = std.os.linux.open(null_path.ptr, .{ .ACCMODE = .RDONLY }, 0);
    const fd: std.posix.fd_t = @intCast(@as(isize, @bitCast(raw_fd)));
    if (fd < 0) return error.FileOpenError;
    defer _ = std.os.linux.close(@intCast(fd));
    const size_raw = std.os.linux.lseek(@intCast(fd), 0, std.os.linux.SEEK.END);
    const size_signed: isize = @bitCast(size_raw);
    if (size_signed < 0) return error.SeekError;
    _ = std.os.linux.lseek(@intCast(fd), 0, std.os.linux.SEEK.SET);
    const size: usize = @intCast(size_signed);
    const bytes = try alloc.alloc(u8, size);
    errdefer alloc.free(bytes);
    var total: usize = 0;
    while (total < size) {
        const n = std.os.linux.read(@intCast(fd), bytes.ptr + total, size - total);
        const ni: isize = @bitCast(n);
        if (ni <= 0) return error.ReadError;
        total += @intCast(ni);
    }
    return bytes;
}

fn assertBytEqualSsts(dir_a: []const u8, dir_b: []const u8, table_id: u32, alloc: std.mem.Allocator) !void {
    const tdir_a = try std.fmt.allocPrint(alloc, "{s}/t{d}", .{ dir_a, table_id });
    defer alloc.free(tdir_a);
    const tdir_b = try std.fmt.allocPrint(alloc, "{s}/t{d}", .{ dir_b, table_id });
    defer alloc.free(tdir_b);

    const files_a = try listSstFiles(tdir_a, alloc);
    defer {
        for (files_a) |f| alloc.free(f);
        alloc.free(files_a);
    }
    const files_b = try listSstFiles(tdir_b, alloc);
    defer {
        for (files_b) |f| alloc.free(f);
        alloc.free(files_b);
    }

    try testing.expectEqual(files_a.len, files_b.len);
    try testing.expect(files_a.len > 0);

    for (0..files_a.len) |i| {
        const bytes_a = try readFileBytes(files_a[i], alloc);
        defer alloc.free(bytes_a);
        const bytes_b = try readFileBytes(files_b[i], alloc);
        defer alloc.free(bytes_b);
        try testing.expectEqualSlices(u8, bytes_a, bytes_b);
    }
}

// ─── DST: INSERT / UPDATE / DELETE normal workload ────────────────────────────

test "Gateway Replay: INSERT UPDATE DELETE produces byte-equal SSTables" {
    const alloc = testing.allocator;

    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const base = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));

    const dir_a = try makeTempDir(alloc, base);
    defer {
        removeDir(dir_a);
        alloc.free(dir_a);
    }
    const dir_b = try makeTempDir(alloc, base + 1);
    defer {
        removeDir(dir_b);
        alloc.free(dir_b);
    }

    const gw_a = try Gateway.init(dir_a, alloc);
    defer gw_a.deinit();
    const gw_b = try Gateway.init(dir_b, alloc);
    defer gw_b.deinit();

    const ddl = "CREATE TABLE accounts (id INT64 NOT NULL, balance INT64 NOT NULL, PRIMARY KEY (id))";
    try gw_a.applyDdl(ddl);
    try gw_b.applyDdl(ddl);

    const insert_hash_a = (try gw_a.register("INSERT INTO accounts (id, balance) VALUES ($1, $2)")).hash;
    const insert_hash_b = (try gw_b.register("INSERT INTO accounts (id, balance) VALUES ($1, $2)")).hash;
    try testing.expectEqualSlices(u8, &insert_hash_a, &insert_hash_b);

    const update_hash_a = (try gw_a.register("UPDATE accounts SET balance = $2 WHERE id = $1")).hash;
    const update_hash_b = (try gw_b.register("UPDATE accounts SET balance = $2 WHERE id = $1")).hash;
    try testing.expectEqualSlices(u8, &update_hash_a, &update_hash_b);

    const delete_hash_a = (try gw_a.register("DELETE FROM accounts WHERE id = $1")).hash;
    const delete_hash_b = (try gw_b.register("DELETE FROM accounts WHERE id = $1")).hash;
    try testing.expectEqualSlices(u8, &delete_hash_a, &delete_hash_b);

    // 10 INSERTs
    var i: i64 = 1;
    while (i <= 10) : (i += 1) {
        const params = [_]ColumnValue{ .{ .int64 = i }, .{ .int64 = i * 100 } };
        _ = try gw_a.execute(insert_hash_a, &params, &.{});
        _ = try gw_b.execute(insert_hash_b, &params, &.{});
    }

    // 5 UPDATEs (ids 1–5, new balance = id * 200)
    i = 1;
    while (i <= 5) : (i += 1) {
        const params = [_]ColumnValue{ .{ .int64 = i }, .{ .int64 = i * 200 } };
        _ = try gw_a.execute(update_hash_a, &params, &.{});
        _ = try gw_b.execute(update_hash_b, &params, &.{});
    }

    // 3 DELETEs (ids 8–10)
    i = 8;
    while (i <= 10) : (i += 1) {
        const params = [_]ColumnValue{.{ .int64 = i }};
        _ = try gw_a.execute(delete_hash_a, &params, &.{});
        _ = try gw_b.execute(delete_hash_b, &params, &.{});
    }

    try gw_a.flushAll();
    try gw_b.flushAll();

    try assertBytEqualSsts(dir_a, dir_b, 1, alloc);
}

// ─── DST: multi-table workload ────────────────────────────────────────────────

test "Gateway Replay: multi-table workload produces byte-equal SSTables" {
    const alloc = testing.allocator;

    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const base = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));

    const dir_a = try makeTempDir(alloc, base + 10);
    defer {
        removeDir(dir_a);
        alloc.free(dir_a);
    }
    const dir_b = try makeTempDir(alloc, base + 11);
    defer {
        removeDir(dir_b);
        alloc.free(dir_b);
    }

    const gw_a = try Gateway.init(dir_a, alloc);
    defer gw_a.deinit();
    const gw_b = try Gateway.init(dir_b, alloc);
    defer gw_b.deinit();

    const users_ddl = "CREATE TABLE users (id INT64 NOT NULL, score INT64 NOT NULL, PRIMARY KEY (id))";
    const posts_ddl = "CREATE TABLE posts (id INT64 NOT NULL, user_id INT64 NOT NULL, views INT64 NOT NULL, PRIMARY KEY (id))";
    try gw_a.applyDdl(users_ddl);
    try gw_b.applyDdl(users_ddl);
    try gw_a.applyDdl(posts_ddl);
    try gw_b.applyDdl(posts_ddl);

    const ins_user_a = (try gw_a.register("INSERT INTO users (id, score) VALUES ($1, $2)")).hash;
    const ins_user_b = (try gw_b.register("INSERT INTO users (id, score) VALUES ($1, $2)")).hash;
    const ins_post_a = (try gw_a.register("INSERT INTO posts (id, user_id, views) VALUES ($1, $2, $3)")).hash;
    const ins_post_b = (try gw_b.register("INSERT INTO posts (id, user_id, views) VALUES ($1, $2, $3)")).hash;

    const upd_score_a = (try gw_a.register("UPDATE users SET score = $2 WHERE id = $1")).hash;
    const upd_score_b = (try gw_b.register("UPDATE users SET score = $2 WHERE id = $1")).hash;
    const del_post_a = (try gw_a.register("DELETE FROM posts WHERE id = $1")).hash;
    const del_post_b = (try gw_b.register("DELETE FROM posts WHERE id = $1")).hash;

    // Insert 8 users
    var i: i64 = 1;
    while (i <= 8) : (i += 1) {
        const p = [_]ColumnValue{ .{ .int64 = i }, .{ .int64 = i * 10 } };
        _ = try gw_a.execute(ins_user_a, &p, &.{});
        _ = try gw_b.execute(ins_user_b, &p, &.{});
    }

    // Insert 12 posts
    i = 1;
    while (i <= 12) : (i += 1) {
        const p = [_]ColumnValue{ .{ .int64 = i }, .{ .int64 = @mod(i - 1, 8) + 1 }, .{ .int64 = i * 5 } };
        _ = try gw_a.execute(ins_post_a, &p, &.{});
        _ = try gw_b.execute(ins_post_b, &p, &.{});
    }

    // Update scores for users 1–4
    i = 1;
    while (i <= 4) : (i += 1) {
        const p = [_]ColumnValue{ .{ .int64 = i }, .{ .int64 = i * 100 } };
        _ = try gw_a.execute(upd_score_a, &p, &.{});
        _ = try gw_b.execute(upd_score_b, &p, &.{});
    }

    // Delete posts 9–12
    i = 9;
    while (i <= 12) : (i += 1) {
        const p = [_]ColumnValue{.{ .int64 = i }};
        _ = try gw_a.execute(del_post_a, &p, &.{});
        _ = try gw_b.execute(del_post_b, &p, &.{});
    }

    try gw_a.flushAll();
    try gw_b.flushAll();

    try assertBytEqualSsts(dir_a, dir_b, 1, alloc); // users table
    try assertBytEqualSsts(dir_a, dir_b, 2, alloc); // posts table
}

// ─── DST: compaction-triggering load ─────────────────────────────────────────

test "Gateway Replay: compaction-triggering load produces byte-equal SSTables" {
    const alloc = testing.allocator;

    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const base = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));

    const dir_a = try makeTempDir(alloc, base + 20);
    defer {
        removeDir(dir_a);
        alloc.free(dir_a);
    }
    const dir_b = try makeTempDir(alloc, base + 21);
    defer {
        removeDir(dir_b);
        alloc.free(dir_b);
    }

    const gw_a = try Gateway.init(dir_a, alloc);
    defer gw_a.deinit();
    const gw_b = try Gateway.init(dir_b, alloc);
    defer gw_b.deinit();

    const ddl = "CREATE TABLE metrics (id INT64 NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))";
    try gw_a.applyDdl(ddl);
    try gw_b.applyDdl(ddl);

    const ins_a = (try gw_a.register("INSERT INTO metrics (id, val) VALUES ($1, $2)")).hash;
    const ins_b = (try gw_b.register("INSERT INTO metrics (id, val) VALUES ($1, $2)")).hash;
    const upd_a = (try gw_a.register("UPDATE metrics SET val = $2 WHERE id = $1")).hash;
    const upd_b = (try gw_b.register("UPDATE metrics SET val = $2 WHERE id = $1")).hash;
    const del_a = (try gw_a.register("DELETE FROM metrics WHERE id = $1")).hash;
    const del_b = (try gw_b.register("DELETE FROM metrics WHERE id = $1")).hash;

    // 5 rounds of 8 inserts each, flushed between rounds to produce L0 files.
    // After round 4 the L0 compaction trigger fires (threshold = 4).
    var round: i64 = 0;
    while (round < 5) : (round += 1) {
        var j: i64 = 0;
        while (j < 8) : (j += 1) {
            const id = round * 8 + j + 1;
            const p = [_]ColumnValue{ .{ .int64 = id }, .{ .int64 = id * 3 } };
            _ = try gw_a.execute(ins_a, &p, &.{});
            _ = try gw_b.execute(ins_b, &p, &.{});
        }
        try gw_a.flushAll();
        try gw_b.flushAll();
    }

    // Updates on round-0 entries to create cross-level versions
    var j: i64 = 1;
    while (j <= 4) : (j += 1) {
        const p = [_]ColumnValue{ .{ .int64 = j }, .{ .int64 = j * 1000 } };
        _ = try gw_a.execute(upd_a, &p, &.{});
        _ = try gw_b.execute(upd_b, &p, &.{});
    }

    // Delete round-1 entries
    j = 9;
    while (j <= 11) : (j += 1) {
        const p = [_]ColumnValue{.{ .int64 = j }};
        _ = try gw_a.execute(del_a, &p, &.{});
        _ = try gw_b.execute(del_b, &p, &.{});
    }

    try gw_a.flushAll();
    try gw_b.flushAll();

    try assertBytEqualSsts(dir_a, dir_b, 1, alloc);
}
