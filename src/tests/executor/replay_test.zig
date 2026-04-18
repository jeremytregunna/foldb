/// DST: two Executor instances fed identical LogEntries must produce byte-equal SSTables.
/// Tests cover: normal workload, abort-heavy workload, and compaction-triggering load.
const std = @import("std");
const testing = std.testing;
const executor_mod = @import("executor.zig");
const storage_mod = @import("storage.zig");
const log_mod = @import("log.zig");

const Executor = executor_mod.Executor;
const QueryContext = executor_mod.QueryContext;
const ResolvedValue = executor_mod.ResolvedValue;
const Mutation = executor_mod.Mutation;
const Storage = executor_mod.Storage;
const LogEntry = executor_mod.LogEntry;
const serializeTxnIntent = executor_mod.serializeTxnIntent;

const TableSchema = storage_mod.TableSchema;
const ColumnValue = storage_mod.ColumnValue;

// --- Schema (two columns: string key label + int64 value) ---

fn makeSchema() TableSchema {
    return .{
        .table_id = 1,
        .columns = &.{
            .{ .col_type = .string, .nullable = false },
            .{ .col_type = .int64, .nullable = false },
        },
    };
}

// --- Temp dir / file helpers ---

fn makeTempDir(alloc: std.mem.Allocator, suffix: u64) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "/tmp/exec_replay_{d}", .{suffix});
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
    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    var total: usize = 0;
    while (total < size) {
        const n = std.os.linux.read(@intCast(fd), buf.ptr + total, size - total);
        const ni: isize = @bitCast(n);
        if (ni <= 0) return error.ReadError;
        total += @intCast(ni);
    }
    return buf;
}

// --- Query handlers (same as executor_test) ---

const HASH_INSERT: [32]u8 = [_]u8{1} ++ [_]u8{0} ** 31;
const HASH_DELETE: [32]u8 = [_]u8{2} ++ [_]u8{0} ** 31;
const HASH_UPDATE: [32]u8 = [_]u8{3} ++ [_]u8{0} ** 31;
const HASH_INSERT_IF_NEW: [32]u8 = [_]u8{4} ++ [_]u8{0} ** 31;
const HASH_UNKNOWN: [32]u8 = [_]u8{0xFF} ** 32;

fn readKey(params: []const u8) !struct { key: []const u8, rest: []const u8 } {
    if (params.len < 2) return error.BadParams;
    const key_len = std.mem.readInt(u16, params[0..2], .little);
    if (params.len < 2 + key_len) return error.BadParams;
    return .{ .key = params[2 .. 2 + key_len], .rest = params[2 + key_len ..] };
}

fn handlerInsert(ctx: QueryContext, _: *Storage, mutations: *std.ArrayList(Mutation)) !void {
    const kv = try readKey(ctx.params);
    if (kv.rest.len < 8) return error.BadParams;
    const value = std.mem.readInt(i64, kv.rest[0..8], .little);
    const key_copy = try ctx.alloc.dupe(u8, kv.key);
    errdefer ctx.alloc.free(key_copy);
    const vals = try ctx.alloc.alloc(ColumnValue, 2);
    errdefer ctx.alloc.free(vals);
    vals[0] = .{ .string = try ctx.alloc.dupe(u8, kv.key) };
    vals[1] = .{ .int64 = value };
    try mutations.append(ctx.alloc, .{ .kind = .insert, .table_id = 1, .key = key_copy, .values = vals });
}

fn handlerDelete(ctx: QueryContext, _: *Storage, mutations: *std.ArrayList(Mutation)) !void {
    const kv = try readKey(ctx.params);
    const key_copy = try ctx.alloc.dupe(u8, kv.key);
    try mutations.append(ctx.alloc, .{ .kind = .delete, .table_id = 1, .key = key_copy, .values = null });
}

fn handlerUpdate(ctx: QueryContext, storage: *Storage, mutations: *std.ArrayList(Mutation)) !void {
    const kv = try readKey(ctx.params);
    if (kv.rest.len < 8) return error.BadParams;
    const delta = std.mem.readInt(i64, kv.rest[0..8], .little);
    const row = try storage.get(1, kv.key, ctx.seq - 1);
    if (row == null) return error.ConstraintViolation;
    var r = row.?;
    defer r.deinit(ctx.alloc);
    const key_copy = try ctx.alloc.dupe(u8, kv.key);
    errdefer ctx.alloc.free(key_copy);
    const vals = try ctx.alloc.alloc(ColumnValue, 2);
    errdefer ctx.alloc.free(vals);
    vals[0] = .{ .string = try ctx.alloc.dupe(u8, kv.key) };
    vals[1] = .{ .int64 = r.values[1].int64 + delta };
    try mutations.append(ctx.alloc, .{ .kind = .update, .table_id = 1, .key = key_copy, .values = vals });
}

fn handlerInsertIfNew(ctx: QueryContext, storage: *Storage, mutations: *std.ArrayList(Mutation)) !void {
    const kv = try readKey(ctx.params);
    if (kv.rest.len < 8) return error.BadParams;
    const existing = try storage.get(1, kv.key, ctx.seq - 1);
    if (existing != null) {
        var e = existing.?;
        e.deinit(ctx.alloc);
        return error.ConstraintViolation;
    }
    const value = std.mem.readInt(i64, kv.rest[0..8], .little);
    const key_copy = try ctx.alloc.dupe(u8, kv.key);
    errdefer ctx.alloc.free(key_copy);
    const vals = try ctx.alloc.alloc(ColumnValue, 2);
    errdefer ctx.alloc.free(vals);
    vals[0] = .{ .string = try ctx.alloc.dupe(u8, kv.key) };
    vals[1] = .{ .int64 = value };
    try mutations.append(ctx.alloc, .{ .kind = .insert, .table_id = 1, .key = key_copy, .values = vals });
}

// --- Entry builders ---

fn encodeKV(alloc: std.mem.Allocator, key: []const u8, value: i64) ![]u8 {
    const buf = try alloc.alloc(u8, 2 + key.len + 8);
    std.mem.writeInt(u16, buf[0..2], @intCast(key.len), .little);
    @memcpy(buf[2 .. 2 + key.len], key);
    std.mem.writeInt(i64, buf[2 + key.len ..][0..8], value, .little);
    return buf;
}

fn encodeKey(alloc: std.mem.Allocator, key: []const u8) ![]u8 {
    const buf = try alloc.alloc(u8, 2 + key.len);
    std.mem.writeInt(u16, buf[0..2], @intCast(key.len), .little);
    @memcpy(buf[2..], key);
    return buf;
}

fn makeEntry(alloc: std.mem.Allocator, seq: u64, hash: *const [32]u8, params: []const u8) !LogEntry {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    try serializeTxnIntent(hash, 0, seq, &.{}, &.{}, params, &.{}, &payload, alloc);
    const copy = try alloc.dupe(u8, payload.items);
    return LogEntry.create(seq, 1, .txn_intent, copy);
}

fn makeNoop(seq: u64) LogEntry {
    return LogEntry.create(seq, 1, .noop, &.{});
}

fn setupExecutor(alloc: std.mem.Allocator, dir: []const u8) !Executor {
    const storage = try alloc.create(Storage);
    storage.* = try Storage.init(dir, alloc);
    try storage.registerTable(makeSchema());
    var exec = Executor.init(storage, alloc);
    try exec.register(HASH_INSERT, handlerInsert);
    try exec.register(HASH_DELETE, handlerDelete);
    try exec.register(HASH_UPDATE, handlerUpdate);
    try exec.register(HASH_INSERT_IF_NEW, handlerInsertIfNew);
    return exec;
}

fn teardownExecutor(exec: *Executor, alloc: std.mem.Allocator) void {
    exec.deinit();
    exec.storage.deinit();
    alloc.destroy(exec.storage);
}

// --- DST test ---

test "Replay: executor produces byte-equal SSTables" {
    const alloc = testing.allocator;

    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const base = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));

    const dir_a = try makeTempDir(alloc, base);
    defer alloc.free(dir_a);
    defer removeDir(dir_a);
    const dir_b = try makeTempDir(alloc, base + 1);
    defer alloc.free(dir_b);
    defer removeDir(dir_b);

    var exec_a = try setupExecutor(alloc, dir_a);
    defer teardownExecutor(&exec_a, alloc);
    var exec_b = try setupExecutor(alloc, dir_b);
    defer teardownExecutor(&exec_b, alloc);

    var seq: u64 = 1;

    // 20 inserts across 10 keys (2 versions each)
    var ki: u64 = 0;
    while (ki < 20) : (ki += 1) {
        const key = try std.fmt.allocPrint(alloc, "key{d:03}", .{ki % 10});
        defer alloc.free(key);
        const params = try encodeKV(alloc, key, @intCast(ki));
        defer alloc.free(params);
        var e = try makeEntry(alloc, seq, &HASH_INSERT, params);
        defer e.deinit(alloc);
        _ = try exec_a.run(e);
        _ = try exec_b.run(e);
        seq += 1;
    }

    // 5 deletes (keys 0–4)
    ki = 0;
    while (ki < 5) : (ki += 1) {
        const key = try std.fmt.allocPrint(alloc, "key{d:03}", .{ki});
        defer alloc.free(key);
        const params = try encodeKey(alloc, key);
        defer alloc.free(params);
        var e = try makeEntry(alloc, seq, &HASH_DELETE, params);
        defer e.deinit(alloc);
        _ = try exec_a.run(e);
        _ = try exec_b.run(e);
        seq += 1;
    }

    // 5 conditional inserts (keys 10–14, first attempt succeeds, second aborts)
    ki = 10;
    while (ki < 15) : (ki += 1) {
        const key = try std.fmt.allocPrint(alloc, "key{d:03}", .{ki});
        defer alloc.free(key);
        const params1 = try encodeKV(alloc, key, @intCast(ki));
        defer alloc.free(params1);
        var e1 = try makeEntry(alloc, seq, &HASH_INSERT_IF_NEW, params1);
        defer e1.deinit(alloc);
        _ = try exec_a.run(e1);
        _ = try exec_b.run(e1);
        seq += 1;

        // Second attempt: same key → abort
        const params2 = try encodeKV(alloc, key, 999);
        defer alloc.free(params2);
        var e2 = try makeEntry(alloc, seq, &HASH_INSERT_IF_NEW, params2);
        defer e2.deinit(alloc);
        _ = try exec_a.run(e2);
        _ = try exec_b.run(e2);
        seq += 1;
    }

    // 5 updates on keys 5–9 (which were not deleted)
    ki = 5;
    while (ki < 10) : (ki += 1) {
        const key = try std.fmt.allocPrint(alloc, "key{d:03}", .{ki});
        defer alloc.free(key);
        const params = try encodeKV(alloc, key, 1);
        defer alloc.free(params);
        var e = try makeEntry(alloc, seq, &HASH_UPDATE, params);
        defer e.deinit(alloc);
        _ = try exec_a.run(e);
        _ = try exec_b.run(e);
        seq += 1;
    }

    // 5 noops
    var ni: u64 = 0;
    while (ni < 5) : (ni += 1) {
        const e = makeNoop(seq);
        _ = try exec_a.run(e);
        _ = try exec_b.run(e);
        seq += 1;
    }

    try exec_a.storage.flushAll();
    try exec_b.storage.flushAll();

    const table_dir_a = try std.fmt.allocPrint(alloc, "{s}/t1", .{dir_a});
    defer alloc.free(table_dir_a);
    const table_dir_b = try std.fmt.allocPrint(alloc, "{s}/t1", .{dir_b});
    defer alloc.free(table_dir_b);

    const files_a = try listSstFiles(table_dir_a, alloc);
    defer {
        for (files_a) |f| alloc.free(f);
        alloc.free(files_a);
    }
    const files_b = try listSstFiles(table_dir_b, alloc);
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

test "Replay: abort-heavy workload produces byte-equal SSTables" {
    const alloc = testing.allocator;

    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const base = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));

    const dir_a = try makeTempDir(alloc, base + 100);
    defer alloc.free(dir_a);
    defer removeDir(dir_a);
    const dir_b = try makeTempDir(alloc, base + 101);
    defer alloc.free(dir_b);
    defer removeDir(dir_b);

    var exec_a = try setupExecutor(alloc, dir_a);
    defer teardownExecutor(&exec_a, alloc);
    var exec_b = try setupExecutor(alloc, dir_b);
    defer teardownExecutor(&exec_b, alloc);

    var seq: u64 = 1;

    // Insert 10 keys
    var ki: u64 = 0;
    while (ki < 10) : (ki += 1) {
        const key = try std.fmt.allocPrint(alloc, "row{d:02}", .{ki});
        defer alloc.free(key);
        const params = try encodeKV(alloc, key, @intCast(ki * 10));
        defer alloc.free(params);
        var e = try makeEntry(alloc, seq, &HASH_INSERT, params);
        defer e.deinit(alloc);
        _ = try exec_a.run(e);
        _ = try exec_b.run(e);
        seq += 1;
    }

    // CRC-corrupted entries (should abort, seq still advances)
    ki = 0;
    while (ki < 5) : (ki += 1) {
        const key = try std.fmt.allocPrint(alloc, "bad{d}", .{ki});
        defer alloc.free(key);
        const params = try encodeKV(alloc, key, 1);
        defer alloc.free(params);
        var e = try makeEntry(alloc, seq, &HASH_INSERT, params);
        defer e.deinit(alloc);
        e.header.payload_crc ^= 0xDEAD;
        _ = try exec_a.run(e);
        _ = try exec_b.run(e);
        seq += 1;
    }

    // Unknown query hash entries (abort with missing_query)
    ki = 0;
    while (ki < 5) : (ki += 1) {
        const params = try encodeKV(alloc, "ignored", 0);
        defer alloc.free(params);
        var e = try makeEntry(alloc, seq, &HASH_UNKNOWN, params);
        defer e.deinit(alloc);
        _ = try exec_a.run(e);
        _ = try exec_b.run(e);
        seq += 1;
    }

    // Truncated payload (abort with bad_params)
    ki = 0;
    while (ki < 3) : (ki += 1) {
        const short = try alloc.dupe(u8, "too_short");
        var e = executor_mod.LogEntry.create(seq, 1, executor_mod.EntryKind.txn_intent, short);
        defer e.deinit(alloc);
        _ = try exec_a.run(e);
        _ = try exec_b.run(e);
        seq += 1;
    }

    // Constraint-violation aborts: duplicate insert_if_new
    ki = 0;
    while (ki < 5) : (ki += 1) {
        const key = try std.fmt.allocPrint(alloc, "row{d:02}", .{ki}); // already exists
        defer alloc.free(key);
        const params = try encodeKV(alloc, key, 999);
        defer alloc.free(params);
        var e = try makeEntry(alloc, seq, &HASH_INSERT_IF_NEW, params);
        defer e.deinit(alloc);
        _ = try exec_a.run(e);
        _ = try exec_b.run(e);
        seq += 1;
    }

    // 5 more good inserts to ensure the abort noise didn't corrupt state
    ki = 20;
    while (ki < 25) : (ki += 1) {
        const key = try std.fmt.allocPrint(alloc, "ok{d:02}", .{ki});
        defer alloc.free(key);
        const params = try encodeKV(alloc, key, @intCast(ki));
        defer alloc.free(params);
        var e = try makeEntry(alloc, seq, &HASH_INSERT, params);
        defer e.deinit(alloc);
        _ = try exec_a.run(e);
        _ = try exec_b.run(e);
        seq += 1;
    }

    try exec_a.storage.flushAll();
    try exec_b.storage.flushAll();

    const table_dir_a = try std.fmt.allocPrint(alloc, "{s}/t1", .{dir_a});
    defer alloc.free(table_dir_a);
    const table_dir_b = try std.fmt.allocPrint(alloc, "{s}/t1", .{dir_b});
    defer alloc.free(table_dir_b);

    const files_a = try listSstFiles(table_dir_a, alloc);
    defer {
        for (files_a) |f| alloc.free(f);
        alloc.free(files_a);
    }
    const files_b = try listSstFiles(table_dir_b, alloc);
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

test "Replay: compaction-triggering load produces byte-equal SSTables" {
    const alloc = testing.allocator;

    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const base = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));

    const dir_a = try makeTempDir(alloc, base + 200);
    defer alloc.free(dir_a);
    defer removeDir(dir_a);
    const dir_b = try makeTempDir(alloc, base + 201);
    defer alloc.free(dir_b);
    defer removeDir(dir_b);

    var exec_a = try setupExecutor(alloc, dir_a);
    defer teardownExecutor(&exec_a, alloc);
    var exec_b = try setupExecutor(alloc, dir_b);
    defer teardownExecutor(&exec_b, alloc);

    var seq: u64 = 1;

    // 5 rounds of inserts, each flushed to produce L0 files.
    // After round 4 the L0 compaction trigger fires (threshold = 4).
    var round: u64 = 0;
    while (round < 5) : (round += 1) {
        var ki: u64 = 0;
        while (ki < 8) : (ki += 1) {
            const key = try std.fmt.allocPrint(alloc, "r{d}k{d:02}", .{ round, ki });
            defer alloc.free(key);
            const params = try encodeKV(alloc, key, @intCast(round * 100 + ki));
            defer alloc.free(params);
            var e = try makeEntry(alloc, seq, &HASH_INSERT, params);
            defer e.deinit(alloc);
            _ = try exec_a.run(e);
            _ = try exec_b.run(e);
            seq += 1;
        }
        // Flush to create an L0 SSTable file
        try exec_a.storage.flushAll();
        try exec_b.storage.flushAll();
    }

    // Updates on round-0 keys to create overlapping versions across levels
    var ki: u64 = 0;
    while (ki < 4) : (ki += 1) {
        const key = try std.fmt.allocPrint(alloc, "r0k{d:02}", .{ki});
        defer alloc.free(key);
        const params = try encodeKV(alloc, key, @intCast(ki + 1000));
        defer alloc.free(params);
        var e = try makeEntry(alloc, seq, &HASH_UPDATE, params);
        defer e.deinit(alloc);
        _ = try exec_a.run(e);
        _ = try exec_b.run(e);
        seq += 1;
    }

    // Delete a few round-1 keys
    ki = 0;
    while (ki < 3) : (ki += 1) {
        const key = try std.fmt.allocPrint(alloc, "r1k{d:02}", .{ki});
        defer alloc.free(key);
        const params = try encodeKey(alloc, key);
        defer alloc.free(params);
        var e = try makeEntry(alloc, seq, &HASH_DELETE, params);
        defer e.deinit(alloc);
        _ = try exec_a.run(e);
        _ = try exec_b.run(e);
        seq += 1;
    }

    try exec_a.storage.flushAll();
    try exec_b.storage.flushAll();

    const table_dir_a = try std.fmt.allocPrint(alloc, "{s}/t1", .{dir_a});
    defer alloc.free(table_dir_a);
    const table_dir_b = try std.fmt.allocPrint(alloc, "{s}/t1", .{dir_b});
    defer alloc.free(table_dir_b);

    const files_a = try listSstFiles(table_dir_a, alloc);
    defer {
        for (files_a) |f| alloc.free(f);
        alloc.free(files_a);
    }
    const files_b = try listSstFiles(table_dir_b, alloc);
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
