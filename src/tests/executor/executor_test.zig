const std = @import("std");
const testing = std.testing;
const executor_mod = @import("executor.zig");
const storage_mod = @import("storage.zig");

const Executor = executor_mod.Executor;
const AbortCode = executor_mod.AbortCode;
const QueryContext = executor_mod.QueryContext;
const ResolvedValue = executor_mod.ResolvedValue;
const Mutation = executor_mod.Mutation;
const Storage = executor_mod.Storage;
const LogEntry = executor_mod.LogEntry;
const EntryKind = executor_mod.EntryKind;
const serialize_txn_intent = executor_mod.serialize_txn_intent;

const TableSchema = storage_mod.TableSchema;
const ColumnValue = storage_mod.ColumnValue;

// --- Schema ---

fn makeSchema() TableSchema {
    return .{
        .table_id = 1,
        .columns = &.{
            .{ .col_type = .string, .nullable = false },
            .{ .col_type = .int64, .nullable = false },
        },
    };
}

// --- Temp dir helpers ---

fn makeTempDir(alloc: std.mem.Allocator) ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const path = try std.fmt.allocPrint(alloc, "/tmp/exec_test_{d}", .{ns});
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

// --- Hand-crafted query handlers ---
//
// Param encoding (all handlers use the same simple scheme):
//   key_len: u16 (little-endian)
//   key:     [key_len]u8
//   value:   i64 (little-endian, only for insert/update handlers)

const HASH_INSERT: [32]u8 = [_]u8{1} ++ [_]u8{0} ** 31;
const HASH_DELETE: [32]u8 = [_]u8{2} ++ [_]u8{0} ** 31;
const HASH_UPDATE: [32]u8 = [_]u8{3} ++ [_]u8{0} ** 31;
const HASH_INSERT_IF_NEW: [32]u8 = [_]u8{4} ++ [_]u8{0} ** 31;
const HASH_WRITE_NOW: [32]u8 = [_]u8{5} ++ [_]u8{0} ** 31;
const HASH_MULTI_INSERT: [32]u8 = [_]u8{6} ++ [_]u8{0} ** 31;
const HASH_WRITE_RANDOM: [32]u8 = [_]u8{7} ++ [_]u8{0} ** 31;
const HASH_WRITE_UUID: [32]u8 = [_]u8{8} ++ [_]u8{0} ** 31;

fn readKey(params: []const u8) !struct { key: []const u8, rest: []const u8 } {
    if (params.len < 2) return error.BadParams;
    const key_len = std.mem.readInt(u16, params[0..2], .little);
    if (params.len < 2 + key_len) return error.BadParams;
    return .{ .key = params[2 .. 2 + key_len], .rest = params[2 + key_len ..] };
}

fn encodeInsertParams(alloc: std.mem.Allocator, key: []const u8, value: i64) ![]u8 {
    var buf = try alloc.alloc(u8, 2 + key.len + 8);
    std.mem.writeInt(u16, buf[0..2], @intCast(key.len), .little);
    @memcpy(buf[2 .. 2 + key.len], key);
    std.mem.writeInt(i64, buf[2 + key.len ..][0..8], value, .little);
    return buf;
}

fn encodeKeyParams(alloc: std.mem.Allocator, key: []const u8) ![]u8 {
    var buf = try alloc.alloc(u8, 2 + key.len);
    std.mem.writeInt(u16, buf[0..2], @intCast(key.len), .little);
    @memcpy(buf[2..], key);
    return buf;
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
    const new_val = r.values[1].int64 + delta;
    const key_copy = try ctx.alloc.dupe(u8, kv.key);
    errdefer ctx.alloc.free(key_copy);
    const vals = try ctx.alloc.alloc(ColumnValue, 2);
    errdefer ctx.alloc.free(vals);
    vals[0] = .{ .string = try ctx.alloc.dupe(u8, kv.key) };
    vals[1] = .{ .int64 = new_val };
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

// Inserts two rows: key and key+"_b" with successive values.
fn handlerMultiInsert(ctx: QueryContext, _: *Storage, mutations: *std.ArrayList(Mutation)) !void {
    const kv = try readKey(ctx.params);
    if (kv.rest.len < 8) return error.BadParams;
    const value = std.mem.readInt(i64, kv.rest[0..8], .little);

    const suffixes = [_][]const u8{ "", "_b" };
    const deltas = [_]i64{ 0, 1 };
    for (suffixes, deltas) |suffix, delta| {
        const full_key = try std.fmt.allocPrint(ctx.alloc, "{s}{s}", .{ kv.key, suffix });
        errdefer ctx.alloc.free(full_key);
        const vals = try ctx.alloc.alloc(ColumnValue, 2);
        errdefer ctx.alloc.free(vals);
        vals[0] = .{ .string = try ctx.alloc.dupe(u8, full_key) };
        vals[1] = .{ .int64 = value + delta };
        try mutations.append(ctx.alloc, .{ .kind = .insert, .table_id = 1, .key = full_key, .values = vals });
    }
}

// Writes ctx.resolved[0].random as the int64 column (first 8 bytes, little-endian).
fn handlerWriteRandom(ctx: QueryContext, _: *Storage, mutations: *std.ArrayList(Mutation)) !void {
    const kv = try readKey(ctx.params);
    if (ctx.resolved.len == 0) return error.BadParams;
    const rnd_val = std.mem.readInt(i64, ctx.resolved[0].random[0..8], .little);
    const key_copy = try ctx.alloc.dupe(u8, kv.key);
    errdefer ctx.alloc.free(key_copy);
    const vals = try ctx.alloc.alloc(ColumnValue, 2);
    errdefer ctx.alloc.free(vals);
    vals[0] = .{ .string = try ctx.alloc.dupe(u8, kv.key) };
    vals[1] = .{ .int64 = rnd_val };
    try mutations.append(ctx.alloc, .{ .kind = .insert, .table_id = 1, .key = key_copy, .values = vals });
}

// Writes ctx.resolved[0].uuid_v7 first 8 bytes as int64 column.
fn handlerWriteUuid(ctx: QueryContext, _: *Storage, mutations: *std.ArrayList(Mutation)) !void {
    const kv = try readKey(ctx.params);
    if (ctx.resolved.len == 0) return error.BadParams;
    const uuid_val = std.mem.readInt(i64, ctx.resolved[0].uuid_v7[0..8], .little);
    const key_copy = try ctx.alloc.dupe(u8, kv.key);
    errdefer ctx.alloc.free(key_copy);
    const vals = try ctx.alloc.alloc(ColumnValue, 2);
    errdefer ctx.alloc.free(vals);
    vals[0] = .{ .string = try ctx.alloc.dupe(u8, kv.key) };
    vals[1] = .{ .int64 = uuid_val };
    try mutations.append(ctx.alloc, .{ .kind = .insert, .table_id = 1, .key = key_copy, .values = vals });
}

// Writes ctx.resolved[0].now as the int64 column value.
fn handlerWriteNow(ctx: QueryContext, _: *Storage, mutations: *std.ArrayList(Mutation)) !void {
    const kv = try readKey(ctx.params);
    if (ctx.resolved.len == 0) return error.BadParams;
    const now_val = ctx.resolved[0].now;
    const key_copy = try ctx.alloc.dupe(u8, kv.key);
    errdefer ctx.alloc.free(key_copy);
    const vals = try ctx.alloc.alloc(ColumnValue, 2);
    errdefer ctx.alloc.free(vals);
    vals[0] = .{ .string = try ctx.alloc.dupe(u8, kv.key) };
    vals[1] = .{ .int64 = now_val };
    try mutations.append(ctx.alloc, .{ .kind = .insert, .table_id = 1, .key = key_copy, .values = vals });
}

// --- Helper: build a LogEntry with a serialized TxnIntent ---

fn makeEntry(
    alloc: std.mem.Allocator,
    seq: u64,
    hash: *const [32]u8,
    params: []const u8,
    nondet: []const ResolvedValue,
) !LogEntry {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    try serialize_txn_intent(hash, 0, seq, 0, &.{}, &.{}, params, nondet, &payload, alloc);
    const payload_copy = try alloc.dupe(u8, payload.items);
    return LogEntry.create(seq, 1, .txn_intent, payload_copy);
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
    try exec.register(HASH_WRITE_NOW, handlerWriteNow);
    try exec.register(HASH_MULTI_INSERT, handlerMultiInsert);
    try exec.register(HASH_WRITE_RANDOM, handlerWriteRandom);
    try exec.register(HASH_WRITE_UUID, handlerWriteUuid);
    return exec;
}

fn teardownExecutor(exec: *Executor, alloc: std.mem.Allocator) void {
    exec.deinit();
    exec.storage.deinit();
    alloc.destroy(exec.storage);
}

// --- Tests ---

test "basic insert and get" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var exec = try setupExecutor(alloc, dir);
    defer teardownExecutor(&exec, alloc);

    const params = try encodeInsertParams(alloc, "alice", 42);
    defer alloc.free(params);
    var entry = try makeEntry(alloc, 1, &HASH_INSERT, params, &.{});
    defer entry.deinit(alloc);

    const result = try exec.run(entry);
    try testing.expectEqual(@as(u64, 1), result.ok.rows_affected);
    try testing.expectEqual(@as(u64, 1), exec.current_seq());

    const row = try exec.storage.get(1, "alice", 1);
    try testing.expect(row != null);
    var r = row.?;
    defer r.deinit(alloc);
    try testing.expectEqual(@as(i64, 42), r.values[1].int64);
}

test "delete removes row" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var exec = try setupExecutor(alloc, dir);
    defer teardownExecutor(&exec, alloc);

    const ip = try encodeInsertParams(alloc, "bob", 99);
    defer alloc.free(ip);
    var e1 = try makeEntry(alloc, 1, &HASH_INSERT, ip, &.{});
    defer e1.deinit(alloc);
    _ = try exec.run(e1);

    const dp = try encodeKeyParams(alloc, "bob");
    defer alloc.free(dp);
    var e2 = try makeEntry(alloc, 2, &HASH_DELETE, dp, &.{});
    defer e2.deinit(alloc);
    _ = try exec.run(e2);

    const row = try exec.storage.get(1, "bob", 2);
    try testing.expectEqual(@as(?storage_mod.Row, null), row);
}

test "MVCC read at earlier seq" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var exec = try setupExecutor(alloc, dir);
    defer teardownExecutor(&exec, alloc);

    const ip = try encodeInsertParams(alloc, "k", 7);
    defer alloc.free(ip);
    var e1 = try makeEntry(alloc, 5, &HASH_INSERT, ip, &.{});
    defer e1.deinit(alloc);
    _ = try exec.run(e1);

    const dp = try encodeKeyParams(alloc, "k");
    defer alloc.free(dp);
    var e2 = try makeEntry(alloc, 10, &HASH_DELETE, dp, &.{});
    defer e2.deinit(alloc);
    _ = try exec.run(e2);

    // Visible at seq 5 and 7, gone at seq 10
    const row5 = try exec.storage.get(1, "k", 5);
    try testing.expect(row5 != null);
    var r5 = row5.?;
    defer r5.deinit(alloc);
    try testing.expectEqual(@as(i64, 7), r5.values[1].int64);

    const row10 = try exec.storage.get(1, "k", 10);
    try testing.expectEqual(@as(?storage_mod.Row, null), row10);
}

test "constraint abort does not apply mutations" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var exec = try setupExecutor(alloc, dir);
    defer teardownExecutor(&exec, alloc);

    const params = try encodeInsertParams(alloc, "unique", 1);
    defer alloc.free(params);

    var e1 = try makeEntry(alloc, 1, &HASH_INSERT_IF_NEW, params, &.{});
    defer e1.deinit(alloc);
    const r1 = try exec.run(e1);
    try testing.expectEqual(@as(u64, 1), r1.ok.rows_affected);

    var e2 = try makeEntry(alloc, 2, &HASH_INSERT_IF_NEW, params, &.{});
    defer e2.deinit(alloc);
    const r2 = try exec.run(e2);
    try testing.expectEqual(AbortCode.constraint_violation, r2.abort.code);

    // Original row unchanged
    const row = try exec.storage.get(1, "unique", 2);
    try testing.expect(row != null);
    var row_val = row.?;
    defer row_val.deinit(alloc);
    try testing.expectEqual(@as(i64, 1), row_val.values[1].int64);
}

test "unknown query hash returns abort" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var exec = try setupExecutor(alloc, dir);
    defer teardownExecutor(&exec, alloc);

    const unknown_hash: [32]u8 = [_]u8{0xff} ** 32;
    var e = try makeEntry(alloc, 1, &unknown_hash, &.{}, &.{});
    defer e.deinit(alloc);

    const result = try exec.run(e);
    try testing.expectEqual(AbortCode.missing_query, result.abort.code);
}

test "noop entry advances seq" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var exec = try setupExecutor(alloc, dir);
    defer teardownExecutor(&exec, alloc);

    try testing.expectEqual(@as(u64, 0), exec.current_seq());
    const noop = makeNoop(7);
    const result = try exec.run(noop);
    try testing.expectEqual(@as(u64, 0), result.ok.rows_affected);
    try testing.expectEqual(@as(u64, 7), exec.current_seq());

    // No storage side effect
    const row = try exec.storage.get(1, "anything", 7);
    try testing.expectEqual(@as(?storage_mod.Row, null), row);
}

test "resolved_nondet passed to handler" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var exec = try setupExecutor(alloc, dir);
    defer teardownExecutor(&exec, alloc);

    const params = try encodeKeyParams(alloc, "ts-key");
    defer alloc.free(params);
    const nondet = [_]ResolvedValue{.{ .now = 1234567890 }};
    var e = try makeEntry(alloc, 1, &HASH_WRITE_NOW, params, &nondet);
    defer e.deinit(alloc);

    _ = try exec.run(e);

    const row = try exec.storage.get(1, "ts-key", 1);
    try testing.expect(row != null);
    var r = row.?;
    defer r.deinit(alloc);
    try testing.expectEqual(@as(i64, 1234567890), r.values[1].int64);
}

test "update read-then-write composes" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var exec = try setupExecutor(alloc, dir);
    defer teardownExecutor(&exec, alloc);

    // Insert initial value 100
    const ip = try encodeInsertParams(alloc, "counter", 100);
    defer alloc.free(ip);
    var e1 = try makeEntry(alloc, 1, &HASH_INSERT, ip, &.{});
    defer e1.deinit(alloc);
    _ = try exec.run(e1);

    // Update +10
    const up1 = try encodeInsertParams(alloc, "counter", 10);
    defer alloc.free(up1);
    var e2 = try makeEntry(alloc, 2, &HASH_UPDATE, up1, &.{});
    defer e2.deinit(alloc);
    _ = try exec.run(e2);

    // Update +5
    const up2 = try encodeInsertParams(alloc, "counter", 5);
    defer alloc.free(up2);
    var e3 = try makeEntry(alloc, 3, &HASH_UPDATE, up2, &.{});
    defer e3.deinit(alloc);
    _ = try exec.run(e3);

    const row = try exec.storage.get(1, "counter", 3);
    try testing.expect(row != null);
    var r = row.?;
    defer r.deinit(alloc);
    try testing.expectEqual(@as(i64, 115), r.values[1].int64);
}

test "update aborts if key missing" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var exec = try setupExecutor(alloc, dir);
    defer teardownExecutor(&exec, alloc);

    const up = try encodeInsertParams(alloc, "ghost", 1);
    defer alloc.free(up);
    var e = try makeEntry(alloc, 1, &HASH_UPDATE, up, &.{});
    defer e.deinit(alloc);

    const result = try exec.run(e);
    try testing.expectEqual(AbortCode.constraint_violation, result.abort.code);
}

test "committed_seq advances on abort" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var exec = try setupExecutor(alloc, dir);
    defer teardownExecutor(&exec, alloc);

    // Insert so the second attempt aborts
    const params = try encodeInsertParams(alloc, "x", 1);
    defer alloc.free(params);

    var e1 = try makeEntry(alloc, 3, &HASH_INSERT_IF_NEW, params, &.{});
    defer e1.deinit(alloc);
    _ = try exec.run(e1);
    try testing.expectEqual(@as(u64, 3), exec.current_seq());

    var e2 = try makeEntry(alloc, 7, &HASH_INSERT_IF_NEW, params, &.{});
    defer e2.deinit(alloc);
    const result = try exec.run(e2);
    try testing.expectEqual(AbortCode.constraint_violation, result.abort.code);
    // seq must advance even on abort
    try testing.expectEqual(@as(u64, 7), exec.current_seq());
}

test "non-txn entry kinds advance seq without mutations" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var exec = try setupExecutor(alloc, dir);
    defer teardownExecutor(&exec, alloc);

    const kinds = [_]EntryKind{ .schema_change, .config_change, .snapshot_marker };
    for (kinds, 0..) |kind, i| {
        const e = LogEntry.create(@intCast(i + 1), 1, kind, &.{});
        const result = try exec.run(e);
        try testing.expectEqual(@as(u64, 0), result.ok.rows_affected);
        try testing.expectEqual(@as(u64, i + 1), exec.current_seq());
    }
}

test "truncated payload returns bad_params abort" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var exec = try setupExecutor(alloc, dir);
    defer teardownExecutor(&exec, alloc);

    // Build a payload shorter than TxnIntentHeader (72 bytes)
    const short_payload = try alloc.dupe(u8, "too short");
    var e = LogEntry.create(1, 1, .txn_intent, short_payload);
    defer e.deinit(alloc);

    const result = try exec.run(e);
    try testing.expectEqual(AbortCode.bad_params, result.abort.code);
    // seq still advances
    try testing.expectEqual(@as(u64, 1), exec.current_seq());
}

test "multiple mutations from one handler" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var exec = try setupExecutor(alloc, dir);
    defer teardownExecutor(&exec, alloc);

    const params = try encodeInsertParams(alloc, "base", 10);
    defer alloc.free(params);
    var e = try makeEntry(alloc, 1, &HASH_MULTI_INSERT, params, &.{});
    defer e.deinit(alloc);

    const result = try exec.run(e);
    try testing.expectEqual(@as(u64, 2), result.ok.rows_affected);

    const r1 = try exec.storage.get(1, "base", 1);
    try testing.expect(r1 != null);
    var rv1 = r1.?;
    defer rv1.deinit(alloc);
    try testing.expectEqual(@as(i64, 10), rv1.values[1].int64);

    const r2 = try exec.storage.get(1, "base_b", 1);
    try testing.expect(r2 != null);
    var rv2 = r2.?;
    defer rv2.deinit(alloc);
    try testing.expectEqual(@as(i64, 11), rv2.values[1].int64);
}

test "random resolved value passes through handler" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var exec = try setupExecutor(alloc, dir);
    defer teardownExecutor(&exec, alloc);

    const params = try encodeKeyParams(alloc, "rnd-key");
    defer alloc.free(params);
    const rnd_bytes: [16]u8 = .{ 0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 0, 0, 0, 0, 0 };
    const nondet = [_]ResolvedValue{.{ .random = rnd_bytes }};
    var e = try makeEntry(alloc, 1, &HASH_WRITE_RANDOM, params, &nondet);
    defer e.deinit(alloc);

    _ = try exec.run(e);

    const row = try exec.storage.get(1, "rnd-key", 1);
    try testing.expect(row != null);
    var r = row.?;
    defer r.deinit(alloc);
    const expected = std.mem.readInt(i64, rnd_bytes[0..8], .little);
    try testing.expectEqual(expected, r.values[1].int64);
}

test "uuid_v7 resolved value passes through handler" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var exec = try setupExecutor(alloc, dir);
    defer teardownExecutor(&exec, alloc);

    const params = try encodeKeyParams(alloc, "uuid-key");
    defer alloc.free(params);
    const uuid_bytes: [16]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const nondet = [_]ResolvedValue{.{ .uuid_v7 = uuid_bytes }};
    var e = try makeEntry(alloc, 1, &HASH_WRITE_UUID, params, &nondet);
    defer e.deinit(alloc);

    _ = try exec.run(e);

    const row = try exec.storage.get(1, "uuid-key", 1);
    try testing.expect(row != null);
    var r = row.?;
    defer r.deinit(alloc);
    const expected = std.mem.readInt(i64, uuid_bytes[0..8], .little);
    try testing.expectEqual(expected, r.values[1].int64);
}

test "txn_intent round-trip preserves all fields" {
    const alloc = testing.allocator;
    const deserialize_txn_intent = executor_mod.deserialize_txn_intent;

    const hash: [32]u8 = HASH_INSERT;
    const params = "hello world";
    const nondet = [_]ResolvedValue{
        .{ .now = 999 },
        .{ .random = [_]u8{0xAA} ** 16 },
        .{ .uuid_v7 = [_]u8{0xBB} ** 16 },
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try serialize_txn_intent(&hash, 42, 7, 5, &.{}, &.{}, params, &nondet, &buf, alloc);

    var decoded = try deserialize_txn_intent(buf.items, alloc);
    defer decoded.deinit();

    try testing.expectEqualSlices(u8, &hash, decoded.query_hash);
    try testing.expectEqual(@as(u64, 42), decoded.client_id);
    try testing.expectEqual(@as(u64, 7), decoded.client_seq);
    try testing.expectEqual(@as(u64, 5), decoded.recon_seq);
    try testing.expectEqualSlices(u8, params, decoded.params);
    try testing.expectEqual(@as(usize, 3), decoded.nondet.len);
    try testing.expectEqual(@as(i64, 999), decoded.nondet[0].now);
    try testing.expectEqualSlices(u8, &([_]u8{0xAA} ** 16), &decoded.nondet[1].random);
    try testing.expectEqualSlices(u8, &([_]u8{0xBB} ** 16), &decoded.nondet[2].uuid_v7);
}

fn makeEntryWithRecon(
    alloc: std.mem.Allocator,
    seq: u64,
    hash: *const [32]u8,
    recon_seq: u64,
    params: []const u8,
    nondet: []const ResolvedValue,
) !LogEntry {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    try serialize_txn_intent(hash, 0, seq, recon_seq, &.{}, &.{}, params, nondet, &payload, alloc);
    const payload_copy = try alloc.dupe(u8, payload.items);
    return LogEntry.create(seq, 1, .txn_intent, payload_copy);
}

test "OCC: read-write conflict detected when key written after recon_seq" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var exec = try setupExecutor(alloc, dir);
    defer teardownExecutor(&exec, alloc);

    // seq=1: insert "x" = 10
    const ip = try encodeInsertParams(alloc, "x", 10);
    defer alloc.free(ip);
    var e1 = try makeEntry(alloc, 1, &HASH_INSERT, ip, &.{});
    defer e1.deinit(alloc);
    _ = try exec.run(e1);

    // seq=2: another transaction updates "x" (simulates concurrent write after recon_seq=1)
    const up2 = try encodeInsertParams(alloc, "x", 1);
    defer alloc.free(up2);
    var e2 = try makeEntry(alloc, 2, &HASH_UPDATE, up2, &.{});
    defer e2.deinit(alloc);
    _ = try exec.run(e2);

    // seq=3: our transaction runs with recon_seq=1 and tries to update "x".
    // Reads "x" → row.seq=2 > recon_seq=1 → stale read → retry.
    const up3 = try encodeInsertParams(alloc, "x", 5);
    defer alloc.free(up3);
    var e3 = try makeEntryWithRecon(alloc, 3, &HASH_UPDATE, 1, up3, &.{});
    defer e3.deinit(alloc);

    const result = try exec.run(e3);
    try testing.expectEqual(AbortCode.retry, result.abort.code);
}

test "OCC: no conflict when recon_seq covers all prior writes" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var exec = try setupExecutor(alloc, dir);
    defer teardownExecutor(&exec, alloc);

    // seq=1: insert "y" = 20
    const ip = try encodeInsertParams(alloc, "y", 20);
    defer alloc.free(ip);
    var e1 = try makeEntry(alloc, 1, &HASH_INSERT, ip, &.{});
    defer e1.deinit(alloc);
    _ = try exec.run(e1);

    // seq=2: update "y" += 3, recon_seq=1 — row was written at seq=1, not after recon_seq=1
    const up = try encodeInsertParams(alloc, "y", 3);
    defer alloc.free(up);
    var e2 = try makeEntryWithRecon(alloc, 2, &HASH_UPDATE, 1, up, &.{});
    defer e2.deinit(alloc);

    const result = try exec.run(e2);
    try testing.expectEqual(@as(u64, 1), result.ok.rows_affected);

    // Confirm the update was applied
    const row = try exec.storage.get(1, "y", 2);
    try testing.expect(row != null);
    var r = row.?;
    defer r.deinit(alloc);
    try testing.expectEqual(@as(i64, 23), r.values[1].int64);
}

test "crc mismatch returns bad_params abort" {
    const alloc = testing.allocator;
    const dir = try makeTempDir(alloc);
    defer alloc.free(dir);
    defer removeDir(dir);

    var exec = try setupExecutor(alloc, dir);
    defer teardownExecutor(&exec, alloc);

    const params = try encodeInsertParams(alloc, "crc-key", 1);
    defer alloc.free(params);
    var e = try makeEntry(alloc, 1, &HASH_INSERT, params, &.{});
    defer e.deinit(alloc);

    // Corrupt the CRC stored in the header
    e.header.payload_crc ^= 0xDEAD;

    const result = try exec.run(e);
    try testing.expectEqual(AbortCode.bad_params, result.abort.code);
    try testing.expectEqual(@as(u64, 1), exec.current_seq());
}
