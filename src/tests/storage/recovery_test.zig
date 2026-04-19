const std = @import("std");
const testing = std.testing;
const recovery = @import("recovery.zig");
const storage_mod = @import("storage.zig");
const executor_mod = @import("executor.zig");
const log_mod = @import("log.zig");

const TableSchema = storage_mod.TableSchema;
const ColumnValue = storage_mod.ColumnValue;
const Mutation = storage_mod.Mutation;
const LSM = storage_mod.LSM;
const MemoryObjectStore = storage_mod.MemoryObjectStore;
const Storage = storage_mod.Storage;
const Executor = executor_mod.Executor;
const Log = log_mod.Log;
const LogEntry = log_mod.LogEntry;
const TxnIntent = log_mod.TxnIntent;

const TABLE_ID: u32 = 7;

fn makeSchema() TableSchema {
    return .{
        .table_id = TABLE_ID,
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
                if (dent.type == std.os.linux.DT.DIR) cleanDir(child) else _ = std.os.linux.unlink(null_child.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(null_path.ptr);
}

const HASH_INSERT: [32]u8 = [_]u8{0xAB} ++ [_]u8{0} ** 31;

fn insertHandler(ctx: executor_mod.QueryContext, store: *Storage, mutations: *std.ArrayList(Mutation)) !void {
    if (ctx.params.len < 2) return error.ConstraintViolation;
    const key_len = std.mem.readInt(u16, ctx.params[0..2], .little);
    if (ctx.params.len < 2 + key_len + 8) return error.ConstraintViolation;
    const key = ctx.params[2 .. 2 + key_len];
    const val = std.mem.readInt(i64, ctx.params[2 + key_len ..][0..8], .little);
    _ = store;
    const key_copy = try ctx.alloc.dupe(u8, key);
    errdefer ctx.alloc.free(key_copy);
    const vals = try ctx.alloc.alloc(ColumnValue, 2);
    errdefer ctx.alloc.free(vals);
    vals[0] = .{ .string = try ctx.alloc.dupe(u8, key) };
    vals[1] = .{ .int64 = val };
    try mutations.append(ctx.alloc, .{ .kind = .insert, .table_id = TABLE_ID, .key = key_copy, .values = vals });
}

fn encodeInsertParams(alloc: std.mem.Allocator, key: []const u8, val: i64) ![]u8 {
    const buf = try alloc.alloc(u8, 2 + key.len + 8);
    std.mem.writeInt(u16, buf[0..2], @intCast(key.len), .little);
    @memcpy(buf[2 .. 2 + key.len], key);
    std.mem.writeInt(i64, buf[2 + key.len ..][0..8], val, .little);
    return buf;
}

fn makeLogEntry(alloc: std.mem.Allocator, seq: u64, key: []const u8, val: i64) !LogEntry {
    const params = try encodeInsertParams(alloc, key, val);
    defer alloc.free(params);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    try executor_mod.serializeTxnIntent(&HASH_INSERT, 0, seq, &.{0}, &.{0}, params, &.{}, &payload, alloc);
    const payload_copy = try alloc.dupe(u8, payload.items);
    return LogEntry.create(seq, 1, .txn_intent, payload_copy);
}

test "recovery: no snapshot returns empty LSM with seq 0" {
    const alloc = testing.allocator;

    const lsm_dir = try makeTempDir(alloc, "rec_empty_lsm");
    defer alloc.free(lsm_dir);
    defer cleanDir(lsm_dir);

    const log_dir = try makeTempDir(alloc, "rec_empty_log");
    defer alloc.free(log_dir);
    defer cleanDir(log_dir);

    const stor_dir = try makeTempDir(alloc, "rec_empty_stor");
    defer alloc.free(stor_dir);
    defer cleanDir(stor_dir);

    var obj_store = MemoryObjectStore.init(alloc);
    defer obj_store.deinit();

    var log_inst = try Log.init(log_dir, 1);
    defer log_inst.deinit();

    var stor = try Storage.init(stor_dir, alloc);
    defer stor.deinit();
    try stor.registerTable(makeSchema());

    var exec = Executor.init(&stor, alloc);
    defer exec.deinit();
    try exec.register(HASH_INSERT, insertHandler);

    var result = try recovery.recoverLatest(
        obj_store.objectStore(),
        0,
        lsm_dir,
        makeSchema(),
        &log_inst,
        &exec,
        alloc,
    );
    defer result.lsm.deinit();

    try testing.expectEqual(@as(u64, 0), result.recovered_through_seq);
}

test "recovery: snapshot + log replay" {
    const alloc = testing.allocator;

    const snap_lsm_dir = try makeTempDir(alloc, "rec_snap_src");
    defer alloc.free(snap_lsm_dir);
    defer cleanDir(snap_lsm_dir);

    const rec_lsm_dir = try makeTempDir(alloc, "rec_snap_dst");
    defer alloc.free(rec_lsm_dir);
    defer cleanDir(rec_lsm_dir);

    const log_dir = try makeTempDir(alloc, "rec_snap_log");
    defer alloc.free(log_dir);
    defer cleanDir(log_dir);

    const stor_dir = try makeTempDir(alloc, "rec_snap_stor");
    defer alloc.free(stor_dir);
    defer cleanDir(stor_dir);

    var obj_store = MemoryObjectStore.init(alloc);
    defer obj_store.deinit();

    // Build initial LSM with some rows and take snapshot
    const schema = makeSchema();
    var src_lsm = try LSM.init(schema, snap_lsm_dir, alloc);
    defer src_lsm.deinit();

    const pre_snap_keys = [_][]const u8{ "alpha", "beta", "gamma" };
    for (pre_snap_keys, 1..) |key, seq| {
        const vals = [_]ColumnValue{
            .{ .string = key },
            .{ .int64 = @intCast(seq * 10) },
        };
        const mut = Mutation{
            .table_id = TABLE_ID,
            .key = key,
            .kind = .insert,
            .values = &vals,
        };
        try src_lsm.apply(&.{mut}, seq);
    }
    try src_lsm.flushMemtable();

    const snap_seq: u64 = pre_snap_keys.len;
    var manifest = try storage_mod.takeSnapshot(&src_lsm, snap_seq, 0, obj_store.objectStore(), storage_mod.noop_snapshot_log_writer, alloc);
    defer manifest.deinit();

    // Build a log with entries after the snapshot
    var log_inst = try Log.init(log_dir, 1);
    defer log_inst.deinit();

    const post_snap_keys = [_][]const u8{ "delta", "epsilon" };
    for (post_snap_keys, 1..) |key, off| {
        const seq = snap_seq + off;
        const entry = try makeLogEntry(alloc, seq, key, @intCast(seq * 100));
        defer alloc.free(entry.payload);
        try log_inst.appendEntryAt(entry);
    }

    // Set up recovery target: fresh storage + executor
    var stor = try Storage.init(stor_dir, alloc);
    defer stor.deinit();
    try stor.registerTable(schema);

    var exec = Executor.init(&stor, alloc);
    defer exec.deinit();
    try exec.register(HASH_INSERT, insertHandler);

    var result = try recovery.recoverLatest(
        obj_store.objectStore(),
        0,
        rec_lsm_dir,
        schema,
        &log_inst,
        &exec,
        alloc,
    );
    defer result.lsm.deinit();

    try testing.expectEqual(snap_seq + post_snap_keys.len, result.recovered_through_seq);

    // Rows inserted before snapshot are in exec.storage via replay
    for (post_snap_keys, 1..) |key, off| {
        const seq = snap_seq + off;
        const row = try exec.storage.get(TABLE_ID, key, seq);
        try testing.expect(row != null);
        if (row) |r| {
            defer alloc.free(r.key);
            defer alloc.free(r.values);
            for (r.values) |v| v.freeIfOwned(alloc);
        }
    }
}
