const std = @import("std");
const testing = std.testing;
const storage = @import("storage.zig");

const TableSchema = storage.TableSchema;
const ColumnSchema = storage.ColumnSchema;
const ColumnValue = storage.ColumnValue;
const Mutation = storage.Mutation;
const Storage = storage.Storage;

fn makeSchema(table_id: storage.TableId) TableSchema {
    return .{
        .table_id = table_id,
        .columns = &.{
            .{ .col_type = .string, .nullable = false },
            .{ .col_type = .int64, .nullable = false },
        },
    };
}

fn makeTempDir(alloc: std.mem.Allocator) ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const path = try std.fmt.allocPrint(alloc, "/tmp/lsm_test_{d}", .{ns});
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
                const child_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ path, name }) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(child_path);
                const null_child = std.heap.page_allocator.allocSentinel(u8, child_path.len, 0) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(null_child);
                @memcpy(null_child[0..child_path.len], child_path);
                if (dent.type == std.os.linux.DT.DIR) {
                    removeDir(child_path);
                } else {
                    _ = std.os.linux.unlink(null_child.ptr);
                }
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(null_path.ptr);
}

test "LSM: basic apply and get" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var store = try Storage.init(dir, alloc);
    defer store.deinit();

    const schema = makeSchema(1);
    try store.registerTable(schema);

    const vals = [_]ColumnValue{ .{ .string = "alice" }, .{ .int64 = 42 } };
    const mutations = [_]Mutation{.{
        .kind = .insert,
        .table_id = 1,
        .key = "user:1",
        .values = &vals,
    }};
    try store.apply(&mutations, 1);

    const row = try store.get(1, "user:1", 1);
    try testing.expect(row != null);
    var r = row.?;
    defer r.deinit(alloc);
    try testing.expectEqualSlices(u8, "user:1", r.key);
    try testing.expectEqual(@as(i64, 42), r.values[1].int64);
}

test "LSM: MVCC - reads at different seqs" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var store = try Storage.init(dir, alloc);
    defer store.deinit();
    try store.registerTable(makeSchema(1));

    const v1 = [_]ColumnValue{ .{ .string = "v1" }, .{ .int64 = 1 } };
    const v2 = [_]ColumnValue{ .{ .string = "v2" }, .{ .int64 = 2 } };

    try store.apply(&.{.{ .kind = .insert, .table_id = 1, .key = "k", .values = &v1 }}, 5);
    try store.apply(&.{.{ .kind = .update, .table_id = 1, .key = "k", .values = &v2 }}, 10);

    // At seq 5: see v1
    if (try store.get(1, "k", 5)) |row| {
        var r = row;
        defer r.deinit(alloc);
        try testing.expectEqual(@as(i64, 1), r.values[1].int64);
    } else return error.MissingAtSeq5;

    // At seq 10: see v2
    if (try store.get(1, "k", 10)) |row| {
        var r = row;
        defer r.deinit(alloc);
        try testing.expectEqual(@as(i64, 2), r.values[1].int64);
    } else return error.MissingAtSeq10;

    // At seq 4: nothing
    const none = try store.get(1, "k", 4);
    try testing.expectEqual(@as(?storage.Row, null), none);
}

test "LSM: delete hides row" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var store = try Storage.init(dir, alloc);
    defer store.deinit();
    try store.registerTable(makeSchema(1));

    const v = [_]ColumnValue{ .{ .string = "x" }, .{ .int64 = 1 } };
    try store.apply(&.{.{ .kind = .insert, .table_id = 1, .key = "k", .values = &v }}, 1);
    try store.apply(&.{.{ .kind = .delete, .table_id = 1, .key = "k", .values = null }}, 2);

    // After delete at seq 2, not visible
    const row = try store.get(1, "k", 2);
    try testing.expectEqual(@as(?storage.Row, null), row);

    // Still visible at seq 1
    if (try store.get(1, "k", 1)) |row2| {
        var r = row2;
        defer r.deinit(alloc);
        try testing.expectEqual(@as(i64, 1), r.values[1].int64);
    } else return error.MissingAtSeq1;
}

test "LSM: get unknown key returns null" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var store = try Storage.init(dir, alloc);
    defer store.deinit();
    try store.registerTable(makeSchema(1));

    const v = [_]ColumnValue{ .{ .string = "x" }, .{ .int64 = 1 } };
    try store.apply(&.{.{ .kind = .insert, .table_id = 1, .key = "exists", .values = &v }}, 1);

    const none = try store.get(1, "does-not-exist", 100);
    try testing.expectEqual(@as(?storage.Row, null), none);
}

test "LSM: flush memtable and read from SSTable" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var store = try Storage.init(dir, alloc);
    defer store.deinit();
    try store.registerTable(makeSchema(1));

    const v = [_]ColumnValue{ .{ .string = "hello" }, .{ .int64 = 99 } };
    try store.apply(&.{.{ .kind = .insert, .table_id = 1, .key = "flushed_key", .values = &v }}, 7);
    try store.flushAll();

    if (try store.get(1, "flushed_key", 7)) |row| {
        var r = row;
        defer r.deinit(alloc);
        try testing.expectEqual(@as(i64, 99), r.values[1].int64);
    } else return error.NotFoundAfterFlush;
}

test "LSM: compaction L0 to L1 preserves reads" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var store = try Storage.init(dir, alloc);
    defer store.deinit();
    try store.registerTable(makeSchema(1));

    // Write 4 distinct keys and flush each to L0 separately
    const keys = [_][]const u8{ "ka", "kb", "kc", "kd" };
    for (keys, 0..) |key, i| {
        const seq: u64 = @intCast(i + 1);
        const v = [_]ColumnValue{ .{ .string = "v" }, .{ .int64 = @intCast(i) } };
        try store.apply(&.{.{ .kind = .insert, .table_id = 1, .key = key, .values = &v }}, seq);
        try store.flushAll();
    }
    // L0 now has 4 files — next apply triggers compaction
    const v5 = [_]ColumnValue{ .{ .string = "v" }, .{ .int64 = 99 } };
    try store.apply(&.{.{ .kind = .insert, .table_id = 1, .key = "ke", .values = &v5 }}, 5);

    // All 4 L0 keys must still be readable from L1
    for (keys, 0..) |key, i| {
        const seq: u64 = @intCast(i + 1);
        const row = try store.get(1, key, seq);
        if (row == null) return error.MissingAfterCompaction;
        var r = row.?;
        defer r.deinit(alloc);
        try testing.expectEqual(@as(i64, @intCast(i)), r.values[1].int64);
    }

    // The in-memtable write is also readable
    if (try store.get(1, "ke", 5)) |row| {
        var r = row;
        defer r.deinit(alloc);
        try testing.expectEqual(@as(i64, 99), r.values[1].int64);
    } else return error.MemtableKeyMissing;
}

test "LSM: multiple tables are isolated" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var store = try Storage.init(dir, alloc);
    defer store.deinit();
    try store.registerTable(makeSchema(1));
    try store.registerTable(makeSchema(2));

    const v1 = [_]ColumnValue{ .{ .string = "table-one" }, .{ .int64 = 111 } };
    const v2 = [_]ColumnValue{ .{ .string = "table-two" }, .{ .int64 = 222 } };
    try store.apply(&.{.{ .kind = .insert, .table_id = 1, .key = "shared-key", .values = &v1 }}, 1);
    try store.apply(&.{.{ .kind = .insert, .table_id = 2, .key = "shared-key", .values = &v2 }}, 1);

    if (try store.get(1, "shared-key", 1)) |row| {
        var r = row;
        defer r.deinit(alloc);
        try testing.expectEqual(@as(i64, 111), r.values[1].int64);
    } else return error.Table1Missing;

    if (try store.get(2, "shared-key", 1)) |row| {
        var r = row;
        defer r.deinit(alloc);
        try testing.expectEqual(@as(i64, 222), r.values[1].int64);
    } else return error.Table2Missing;
}
