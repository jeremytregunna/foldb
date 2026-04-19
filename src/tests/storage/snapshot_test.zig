const std = @import("std");
const testing = std.testing;
const storage = @import("storage.zig");

const TableSchema = storage.TableSchema;
const ColumnValue = storage.ColumnValue;
const Mutation = storage.Mutation;
const LSM = storage.LSM;
const MemoryObjectStore = storage.MemoryObjectStore;
const SnapshotManifest = storage.SnapshotManifest;

fn makeSchema() TableSchema {
    return .{
        .table_id = 99,
        .columns = &.{
            .{ .col_type = .string, .nullable = false },
            .{ .col_type = .int64, .nullable = false },
        },
    };
}

fn makeTempDir(alloc: std.mem.Allocator, tag: []const u8) ![]const u8 {
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

test "manifest_encode_decode" {
    const alloc = testing.allocator;

    const keys = [_][]const u8{ "snapshots/1/100/L0_0.sst", "snapshots/1/100/L1_1.sst" };
    const keys_owned = try alloc.alloc([]const u8, keys.len);
    for (keys, 0..) |k, i| keys_owned[i] = try alloc.dupe(u8, k);

    var m = SnapshotManifest{
        .seq = 100,
        .partition_id = 1,
        .sstable_keys = keys_owned,
        .manifest_key = try alloc.dupe(u8, "snapshots/1/100/manifest"),
        .alloc = alloc,
    };
    defer m.deinit();

    const bytes = try storage.manifestToBytes(&m, alloc);
    defer alloc.free(bytes);

    var m2 = try storage.manifestFromBytes(bytes, "snapshots/1/100/manifest", alloc);
    defer m2.deinit();

    try testing.expectEqual(m.seq, m2.seq);
    try testing.expectEqual(m.partition_id, m2.partition_id);
    try testing.expectEqual(m.sstable_keys.len, m2.sstable_keys.len);
    for (m.sstable_keys, m2.sstable_keys) |a, b| {
        try testing.expectEqualSlices(u8, a, b);
    }
}

test "take_and_restore" {
    const alloc = testing.allocator;

    const dir = try makeTempDir(alloc, "snap_take");
    defer alloc.free(dir);
    defer cleanDir(dir);

    const restore_dir = try std.fmt.allocPrint(alloc, "{s}_r", .{dir});
    defer alloc.free(restore_dir);
    defer cleanDir(restore_dir);

    const schema = makeSchema();
    var lsm = try LSM.init(schema, dir, alloc);
    defer lsm.deinit();

    var obj_store = MemoryObjectStore.init(alloc);
    defer obj_store.deinit();

    // Insert 100 rows
    var seq: u64 = 1;
    var ki: usize = 0;
    while (ki < 100) : (ki += 1) {
        const key = try std.fmt.allocPrint(alloc, "row_{d:04}", .{ki});
        defer alloc.free(key);
        const vals = [_]ColumnValue{
            .{ .string = key },
            .{ .int64 = @intCast(ki) },
        };
        const mut = Mutation{
            .table_id = schema.table_id,
            .key = key,
            .kind = .insert,
            .values = &vals,
        };
        try lsm.apply(&.{mut}, seq);
        seq += 1;
        // Flush every 20 inserts to create SSTable files
        if (ki % 20 == 19) try lsm.flushMemtable();
    }
    // Final flush to persist remaining memtable entries
    try lsm.flushMemtable();

    const at_seq = seq - 1;
    var manifest = try storage.takeSnapshot(&lsm, at_seq, 0, obj_store.objectStore(), storage.noop_snapshot_log_writer, alloc);
    defer manifest.deinit();

    try testing.expect(manifest.sstable_keys.len > 0);

    // Restore
    var lsm2 = try storage.restoreFromSnapshot(&manifest, restore_dir, obj_store.objectStore(), schema, alloc);
    defer lsm2.deinit();

    // Verify all 100 rows are readable
    ki = 0;
    while (ki < 100) : (ki += 1) {
        const key = try std.fmt.allocPrint(alloc, "row_{d:04}", .{ki});
        defer alloc.free(key);
        const row = try lsm2.get(key, std.math.maxInt(u64));
        try testing.expect(row != null);
        if (row) |r| {
            defer alloc.free(r.key);
            defer alloc.free(r.values);
            for (r.values) |v| v.freeIfOwned(alloc);
        }
    }
}
