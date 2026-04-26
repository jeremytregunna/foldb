const std = @import("std");
const testing = std.testing;
const storage = @import("storage.zig");

const TableSchema = storage.TableSchema;
const ColumnValue = storage.ColumnValue;
const Mutation = storage.Mutation;
const LSM = storage.LSM;
const MemoryObjectStore = storage.MemoryObjectStore;

fn makeSchema() TableSchema {
    return .{
        .table_id = 42,
        .columns = &.{
            .{ .col_type = .string, .nullable = false },
            .{ .col_type = .int64, .nullable = false },
        },
    };
}

fn makeTempDir(alloc: std.mem.Allocator, tag: []const u8) ![]const u8 {
    // SAFETY: clock_gettime fills ts before any field is read.
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const path = try std.fmt.allocPrint(alloc, "/tmp/{s}_{d}", .{ tag, ns });
    const null_path = try alloc.allocSentinel(u8, path.len, 0);
    defer alloc.free(null_path);
    @memcpy(null_path[0..path.len], path);
    _ = std.os.linux.mkdir(null_path.ptr, 0o755);
    return path;
}

fn cleanDir(path: []const u8) void {
    const alloc = std.heap.page_allocator;
    const null_path = alloc.allocSentinel(u8, path.len, 0) catch return;
    defer alloc.free(null_path);
    @memcpy(null_path[0..path.len], path);

    const raw_fd = std.os.linux.open(null_path.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
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
                const null_child = alloc.allocSentinel(u8, child.len, 0) catch {
                    i += dent.reclen;
                    continue;
                };
                defer alloc.free(null_child);
                @memcpy(null_child[0..child.len], child);
                _ = std.os.linux.unlink(null_child.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(null_path.ptr);
}

fn insertRow(lsm: *LSM, key: []const u8, val: i64, seq: u64) !void {
    const schema = makeSchema();
    const vals = [_]ColumnValue{
        .{ .string = key },
        .{ .int64 = val },
    };
    const m = Mutation{
        .table_id = schema.table_id,
        .key = key,
        .kind = .insert,
        .values = &vals,
    };
    try lsm.apply(&.{m}, seq);
}

test "tiered_write_and_read" {
    const alloc = testing.allocator;

    const dir = try makeTempDir(alloc, "tiered_test");
    defer alloc.free(dir);
    defer cleanDir(dir);

    const cache_dir = try std.fmt.allocPrint(alloc, "{s}/cache", .{dir});
    defer alloc.free(cache_dir);

    const schema = makeSchema();
    var lsm = try LSM.init(schema, dir, alloc);
    defer lsm.deinit();

    var obj_store = MemoryObjectStore.init(alloc);
    defer obj_store.deinit();

    try lsm.withObjectStore(obj_store.objectStore(), cache_dir);

    // Insert enough rows to trigger L0→L1→L2→L3 compaction
    // L0 triggers at 4 files; each flush = 1 file
    // Insert rows in batches to force flushes
    var seq: u64 = 1;
    var ki: usize = 0;
    while (ki < 20) : (ki += 1) {
        const key = try std.fmt.allocPrint(alloc, "key_{d:04}", .{ki});
        defer alloc.free(key);
        try insertRow(&lsm, key, @intCast(ki * 100), seq);
        seq += 1;
        // Force flush after every 2 inserts to accumulate L0 files
        if (ki % 2 == 1) try lsm.flushMemtable();
    }

    // Trigger compaction cascade
    try lsm.maybeCompact();
    try lsm.maybeCompact();
    try lsm.maybeCompact();

    // Verify reads work (may come from any level including L3)
    const row = try lsm.get("key_0000", std.math.maxInt(u64));
    try testing.expect(row != null);
    if (row) |r| {
        defer alloc.free(r.key);
        defer alloc.free(r.values);
        for (r.values) |v| v.freeIfOwned(alloc);
    }
}

test "snapshot_round_trip" {
    const alloc = testing.allocator;

    const dir = try makeTempDir(alloc, "snapshot_test");
    defer alloc.free(dir);
    defer cleanDir(dir);

    const restore_dir = try std.fmt.allocPrint(alloc, "{s}_restore", .{dir});
    defer alloc.free(restore_dir);
    defer cleanDir(restore_dir);

    const schema = makeSchema();
    var lsm = try LSM.init(schema, dir, alloc);
    defer lsm.deinit();

    var obj_store = MemoryObjectStore.init(alloc);
    defer obj_store.deinit();

    // Insert rows
    var seq: u64 = 1;
    var ki: usize = 0;
    while (ki < 5) : (ki += 1) {
        const key = try std.fmt.allocPrint(alloc, "snap_key_{d}", .{ki});
        defer alloc.free(key);
        try insertRow(&lsm, key, @intCast(ki * 10), seq);
        seq += 1;
    }

    const at_seq: u64 = seq - 1;
    var manifest = try storage.takeSnapshot(&lsm, at_seq, 1, obj_store.objectStore(), storage.noop_snapshot_log_writer, alloc);
    defer manifest.deinit();

    try testing.expect(manifest.seq == at_seq);
    try testing.expect(manifest.partition_id == 1);
    try testing.expect(manifest.sstable_keys.len > 0);

    // Restore into fresh LSM
    var lsm2 = try storage.restoreFromSnapshot(&manifest, restore_dir, obj_store.objectStore(), schema, alloc);
    defer lsm2.deinit();

    // Verify at least one row is readable
    const row = try lsm2.get("snap_key_0", std.math.maxInt(u64));
    try testing.expect(row != null);
    if (row) |r| {
        defer alloc.free(r.key);
        defer alloc.free(r.values);
        for (r.values) |v| v.freeIfOwned(alloc);
    }
}
