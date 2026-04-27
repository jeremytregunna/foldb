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

test "get finds key after second L2-to-L3 compaction cycle" {
    // Regression: without L3 consolidation, a key written only in cycle 1 becomes
    // invisible to get() after cycle 2 because findFileForKey returns only the
    // newest L3 file, which doesn't contain keys not updated in cycle 2.
    const alloc = testing.allocator;

    const dir = try makeTempDir(alloc, "tiered_l3_regression");
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

    // Cycle 1: write key_stable (never updated again) and key_updated.
    // 44 single-row flushes drives 11 L0→L1 compactions; maybeCompact() then
    // triggers L1→L2. Five cycles fills L2 to >4 files so maybeCompact() fires
    // L2→L3 on the 5th call, producing L3 file #1 containing both keys.
    const ROWS_PER_CYCLE = 44;
    var seq: u64 = 1;

    // Cycle 1: write both keys among 44 rows.
    var i: usize = 0;
    while (i < ROWS_PER_CYCLE) : (i += 1) {
        const key = try std.fmt.allocPrint(alloc, "key_{d:06}", .{i});
        defer alloc.free(key);
        try insertRow(&lsm, key, @intCast(i), seq);
        seq += 1;
        try lsm.flushMemtable();
    }
    try lsm.maybeCompact(); // L0→L1, L1 has 11 files → L1→L2; L2 has 1 file

    // Cycles 2–4: write 44 new rows each cycle, accumulating L2 to 4 files.
    var cycle: usize = 1;
    while (cycle < 4) : (cycle += 1) {
        i = 0;
        while (i < ROWS_PER_CYCLE) : (i += 1) {
            const key = try std.fmt.allocPrint(alloc, "key_{d:06}", .{cycle * ROWS_PER_CYCLE + i});
            defer alloc.free(key);
            try insertRow(&lsm, key, @intCast(i), seq);
            seq += 1;
            try lsm.flushMemtable();
        }
        try lsm.maybeCompact();
    }

    // Cycle 5: write only NEW keys (not key_000000). This triggers L2→L3 (L3 file #1).
    i = 0;
    while (i < ROWS_PER_CYCLE) : (i += 1) {
        const key = try std.fmt.allocPrint(alloc, "key_{d:06}", .{4 * ROWS_PER_CYCLE + i});
        defer alloc.free(key);
        try insertRow(&lsm, key, @intCast(i), seq);
        seq += 1;
        try lsm.flushMemtable();
    }
    try lsm.maybeCompact(); // produces L3 file #1, L2 cleared

    // Verify L3 file #1 exists and key_000000 is readable.
    try testing.expect(lsm.levels[3].files.items.len == 1);
    {
        const row = try lsm.get("key_000000", std.math.maxInt(u64));
        try testing.expect(row != null);
        if (row) |r| {
            var mr = r;
            mr.deinit(alloc);
        }
    }

    // Second L2→L3 cycle: write 5*44 more new keys (not key_000000), producing L3 file #2.
    cycle = 0;
    while (cycle < 5) : (cycle += 1) {
        i = 0;
        while (i < ROWS_PER_CYCLE) : (i += 1) {
            const key = try std.fmt.allocPrint(alloc, "new_{d:06}", .{cycle * ROWS_PER_CYCLE + i});
            defer alloc.free(key);
            try insertRow(&lsm, key, @intCast(i), seq);
            seq += 1;
            try lsm.flushMemtable();
        }
        try lsm.maybeCompact();
    }

    // L3 must stay consolidated at exactly one file.
    try testing.expect(lsm.levels[3].files.items.len == 1);

    // key_000000 was NOT updated in cycle 2; it must still be readable.
    const row = try lsm.get("key_000000", std.math.maxInt(u64));
    try testing.expect(row != null);
    if (row) |r| {
        var mr = r;
        mr.deinit(alloc);
    }
}

test "scan returns rows from remote-only L3 files" {
    const alloc = testing.allocator;

    const dir = try makeTempDir(alloc, "tiered_scan_test");
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

    // Drive the full compaction cascade to L3.
    //
    // Thresholds: L0→L1 at 4 L0 files, L1→L2 at >10 L1 files, L2→L3 at >4 L2 files.
    // Each cycle: 44 one-row flushes accumulate 10 L0 files before the final flush reaches
    // 4 again; maybeCompact() then runs L0→L1 (→L1 hits 11), L1→L2 (→L2 grows by 1).
    // After 5 cycles L2 has 5 files; the 5th maybeCompact() also fires L2→L3.
    const CYCLES = 5;
    const ROWS_PER_CYCLE = 44;
    var seq: u64 = 1;
    var cycle: usize = 0;
    while (cycle < CYCLES) : (cycle += 1) {
        var i: usize = 0;
        while (i < ROWS_PER_CYCLE) : (i += 1) {
            const key = try std.fmt.allocPrint(alloc, "key_{d:06}", .{cycle * ROWS_PER_CYCLE + i});
            defer alloc.free(key);
            try insertRow(&lsm, key, @intCast(i), seq);
            seq += 1;
            try lsm.flushMemtable();
        }
        try lsm.maybeCompact();
    }

    // Verify that L3 was actually populated (sanity guard).
    var l3_remote_count: usize = 0;
    for (lsm.levels[3].files.items) |meta| {
        if (meta.remote_key != null) l3_remote_count += 1;
    }
    try testing.expect(l3_remote_count > 0);

    // Delete local L3 files — only the remote copies in the object store remain.
    for (lsm.levels[3].files.items) |*meta| {
        if (meta.remote_key == null) continue;
        const null_path = try alloc.allocSentinel(u8, meta.path.len, 0);
        defer alloc.free(null_path);
        @memcpy(null_path[0..meta.path.len], meta.path);
        _ = std.os.linux.unlink(null_path.ptr);
    }

    // Scan must return all rows by fetching from the object store.
    const rows = try lsm.scan(storage.KeyRange.all(), std.math.maxInt(u64), alloc);
    defer {
        for (rows) |*r| {
            var mr = r.*;
            mr.deinit(alloc);
        }
        alloc.free(rows);
    }
    try testing.expect(rows.len == CYCLES * ROWS_PER_CYCLE);
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
