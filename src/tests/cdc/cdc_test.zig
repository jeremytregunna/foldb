/// Unit tests for the CDC module (M10).
const std = @import("std");
const testing = std.testing;
const cdc_mod = @import("cdc.zig");
const storage_mod = @import("storage.zig");
const executor_mod = @import("executor.zig");
const partition_set_mod = @import("partition_set.zig");
const log_mod = @import("log.zig");

const CdcManager = cdc_mod.CdcManager;
const CdcEvent = cdc_mod.CdcEvent;
const CdcOperation = cdc_mod.CdcOperation;
const Executor = executor_mod.Executor;
const Storage = storage_mod.Storage;
const TableSchema = storage_mod.TableSchema;
const ColumnValue = storage_mod.ColumnValue;
const Mutation = storage_mod.Mutation;
const Log = log_mod.Log;
const LogEntry = log_mod.LogEntry;
const EntryKind = log_mod.EntryKind;
const Seq = log_mod.Seq;

fn makeTempDir() ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/cdc_test_{d}", .{ns});
}

fn removeDirRecursive(path: []const u8) void {
    const z = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(z);
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
                _ = std.os.linux.unlink(cz.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}

const TABLE_ID: u32 = 1;

fn makeSchema() TableSchema {
    return .{
        .table_id = TABLE_ID,
        .columns = &.{
            .{ .col_type = .int64, .nullable = false },
            .{ .col_type = .int64, .nullable = false },
        },
    };
}

fn makeKey(id: i64, alloc: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "key_{d}", .{id});
}

fn makeInsertMutation(id: i64, val: i64, alloc: std.mem.Allocator) !Mutation {
    const key = try makeKey(id, alloc);
    const values = try alloc.alloc(ColumnValue, 2);
    values[0] = .{ .int64 = id };
    values[1] = .{ .int64 = val };
    return .{ .kind = .insert, .table_id = TABLE_ID, .key = key, .values = values };
}

fn makeUpdateMutation(id: i64, new_val: i64, alloc: std.mem.Allocator) !Mutation {
    const key = try makeKey(id, alloc);
    const values = try alloc.alloc(ColumnValue, 2);
    values[0] = .{ .int64 = id };
    values[1] = .{ .int64 = new_val };
    return .{ .kind = .update, .table_id = TABLE_ID, .key = key, .values = values };
}

fn makeDeleteMutation(id: i64, alloc: std.mem.Allocator) !Mutation {
    const key = try makeKey(id, alloc);
    return .{ .kind = .delete, .table_id = TABLE_ID, .key = key, .values = null };
}

fn freeMutation(m: Mutation, alloc: std.mem.Allocator) void {
    alloc.free(m.key);
    if (m.values) |vs| {
        for (vs) |v| v.freeIfOwned(alloc);
        alloc.free(vs);
    }
}

fn makeTxnEntry(seq: Seq, epoch: u64) LogEntry {
    const header = log_mod.LogEntryHeader{
        .seq = seq,
        .epoch = epoch,
        .kind = .txn_intent,
        .payload_len = 0,
        .payload_crc = 0,
    };
    return .{ .header = header, .payload = &.{} };
}

// Helper: apply mutations directly to storage and dispatch CDC events.
fn applyWithCdc(
    mgr: *CdcManager,
    storage: *Storage,
    mutations: []const Mutation,
    seq: Seq,
    epoch: u64,
    alloc: std.mem.Allocator,
) !void {
    const pre_seq: Seq = if (seq > 0) seq - 1 else 0;
    var bi = try mgr.capture_before_images(mutations, storage, pre_seq, alloc);
    defer bi.deinit();
    try storage.apply(mutations, seq);
    try mgr.dispatch(seq, epoch, log_mod.EntryKind.txn_intent, mutations, bi, alloc);
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "CdcManager: init and deinit" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();
    try testing.expectEqual(@as(u32, 0), mgr.subscription_count);
}

test "CdcManager: subscribe and unsubscribe" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const sub = try mgr.subscribe(null, 0);
    try testing.expectEqual(@as(u32, 1), mgr.subscription_count);
    try testing.expectEqual(@as(u64, 1), sub.id);

    mgr.unsubscribe(sub.id);
    try testing.expectEqual(@as(u32, 0), mgr.subscription_count);
}

test "CDC: insert produces event with no before and correct after" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    var storage = try Storage.init(dir, testing.allocator);
    defer storage.deinit();
    try storage.registerTable(makeSchema());

    const sub = try mgr.subscribe(null, 0);

    const m = try makeInsertMutation(1, 100, testing.allocator);
    defer freeMutation(m, testing.allocator);

    try applyWithCdc(&mgr, &storage, &.{m}, 1, 0, testing.allocator);

    var buf: [1]CdcEvent = undefined;
    const n = sub.next(&buf);
    defer buf[0].deinit();
    try testing.expectEqual(@as(usize, 1), n);

    const ev = buf[0];
    try testing.expectEqual(@as(Seq, 1), ev.seq);
    try testing.expectEqual(@as(usize, 1), ev.effects.len);

    const ef = ev.effects[0];
    try testing.expectEqual(CdcOperation.insert, ef.op);
    try testing.expect(ef.before == null);
    try testing.expect(ef.after != null);
    try testing.expectEqual(@as(i64, 100), ef.after.?[1].int64);
}

test "CDC: update produces event with before and after" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    var storage = try Storage.init(dir, testing.allocator);
    defer storage.deinit();
    try storage.registerTable(makeSchema());

    const sub = try mgr.subscribe(null, 0);

    // Insert first
    const ins = try makeInsertMutation(1, 100, testing.allocator);
    defer freeMutation(ins, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{ins}, 1, 0, testing.allocator);
    var drain1: [1]CdcEvent = undefined;
    const nd1 = sub.next(&drain1);
    if (nd1 > 0) drain1[0].deinit();

    // Now update
    const upd = try makeUpdateMutation(1, 200, testing.allocator);
    defer freeMutation(upd, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{upd}, 2, 0, testing.allocator);

    var buf: [1]CdcEvent = undefined;
    const n = sub.next(&buf);
    defer buf[0].deinit();
    try testing.expectEqual(@as(usize, 1), n);

    const ef = buf[0].effects[0];
    try testing.expectEqual(CdcOperation.update, ef.op);
    try testing.expect(ef.before != null);
    try testing.expect(ef.after != null);
    try testing.expectEqual(@as(i64, 100), ef.before.?[1].int64);
    try testing.expectEqual(@as(i64, 200), ef.after.?[1].int64);
}

test "CDC: delete produces event with before and no after" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    var storage = try Storage.init(dir, testing.allocator);
    defer storage.deinit();
    try storage.registerTable(makeSchema());

    const sub = try mgr.subscribe(null, 0);

    const ins = try makeInsertMutation(1, 42, testing.allocator);
    defer freeMutation(ins, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{ins}, 1, 0, testing.allocator);
    var drain2: [1]CdcEvent = undefined;
    const nd2 = sub.next(&drain2);
    if (nd2 > 0) drain2[0].deinit();

    const del = try makeDeleteMutation(1, testing.allocator);
    defer freeMutation(del, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{del}, 2, 0, testing.allocator);

    var buf: [1]CdcEvent = undefined;
    const n = sub.next(&buf);
    defer buf[0].deinit();
    try testing.expectEqual(@as(usize, 1), n);

    const ef = buf[0].effects[0];
    try testing.expectEqual(CdcOperation.delete, ef.op);
    try testing.expect(ef.before != null);
    try testing.expectEqual(@as(i64, 42), ef.before.?[1].int64);
    try testing.expect(ef.after == null);
}

test "CDC: table_filter excludes non-matching tables" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    var storage = try Storage.init(dir, testing.allocator);
    defer storage.deinit();
    try storage.registerTable(makeSchema());

    // Subscribe to table 99 (not TABLE_ID=1)
    const sub = try mgr.subscribe(99, 0);

    const m = try makeInsertMutation(1, 10, testing.allocator);
    defer freeMutation(m, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{m}, 1, 0, testing.allocator);

    var buf: [1]CdcEvent = undefined;
    const n = sub.next(&buf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "CDC: multiple subscribers each receive the event" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    var storage = try Storage.init(dir, testing.allocator);
    defer storage.deinit();
    try storage.registerTable(makeSchema());

    const sub1 = try mgr.subscribe(null, 0);
    const sub2 = try mgr.subscribe(null, 0);

    const m = try makeInsertMutation(1, 7, testing.allocator);
    defer freeMutation(m, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{m}, 1, 0, testing.allocator);

    var buf1: [1]CdcEvent = undefined;
    var buf2: [1]CdcEvent = undefined;
    const n1 = sub1.next(&buf1);
    defer buf1[0].deinit();
    const n2 = sub2.next(&buf2);
    defer buf2[0].deinit();

    try testing.expectEqual(@as(usize, 1), n1);
    try testing.expectEqual(@as(usize, 1), n2);
    try testing.expectEqual(@as(Seq, 1), buf1[0].seq);
    try testing.expectEqual(@as(Seq, 1), buf2[0].seq);
}

test "CDC: ack advances cursor" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    var storage = try Storage.init(dir, testing.allocator);
    defer storage.deinit();
    try storage.registerTable(makeSchema());

    const sub = try mgr.subscribe(null, 0);

    const m1 = try makeInsertMutation(1, 1, testing.allocator);
    defer freeMutation(m1, testing.allocator);
    const m2 = try makeInsertMutation(2, 2, testing.allocator);
    defer freeMutation(m2, testing.allocator);

    try applyWithCdc(&mgr, &storage, &.{m1}, 1, 0, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{m2}, 2, 0, testing.allocator);

    try testing.expectEqual(@as(Seq, 0), sub.cursor.load(.monotonic));

    var buf: [2]CdcEvent = undefined;
    const n = sub.next(&buf);
    try testing.expectEqual(@as(usize, 2), n);
    buf[0].deinit();
    buf[1].deinit();

    sub.ack(2);
    try testing.expectEqual(@as(Seq, 2), sub.cursor.load(.monotonic));
}

test "CDC: no events for empty mutation list" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    var storage = try Storage.init(dir, testing.allocator);
    defer storage.deinit();
    try storage.registerTable(makeSchema());

    const sub = try mgr.subscribe(null, 0);
    try applyWithCdc(&mgr, &storage, &.{}, 1, 0, testing.allocator);

    var buf: [1]CdcEvent = undefined;
    const n = sub.next(&buf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "CDC: Executor.withCdc routes events through executor" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    var storage = try Storage.init(dir, testing.allocator);
    defer storage.deinit();
    try storage.registerTable(makeSchema());

    var executor = Executor.init(&storage, testing.allocator);
    defer executor.deinit();
    executor.withCdc(&mgr);

    const sub = try mgr.subscribe(null, 0);

    // Register a handler that inserts a row
    const hash: [32]u8 = [_]u8{0xAB} ** 32;
    try executor.register(hash, testInsertHandler);

    const intent_payload = try buildTestPayload(1, 42, testing.allocator);
    defer testing.allocator.free(intent_payload);

    const entry = LogEntry.create(1, 0, .txn_intent, intent_payload);
    const result = try executor.run(entry);
    try testing.expect(result == .ok);

    var buf: [1]CdcEvent = undefined;
    const n = sub.next(&buf);
    defer buf[0].deinit();
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(CdcOperation.insert, buf[0].effects[0].op);
}

// ─── Helpers for executor test ────────────────────────────────────────────────

fn testInsertHandler(
    ctx: executor_mod.QueryContext,
    storage: *Storage,
    mutations: *std.ArrayListUnmanaged(Mutation),
) anyerror!void {
    _ = ctx;
    _ = storage;
    const key = try testing.allocator.dupe(u8, "key_1");
    errdefer testing.allocator.free(key);
    const values = try testing.allocator.alloc(ColumnValue, 2);
    errdefer testing.allocator.free(values);
    values[0] = .{ .int64 = 1 };
    values[1] = .{ .int64 = 42 };
    try mutations.append(testing.allocator, .{
        .kind = .insert,
        .table_id = TABLE_ID,
        .key = key,
        .values = values,
    });
}

test "CDC: cross-partition transaction emits events on both partitions" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    // Two storage directories for two partitions.
    const dir0 = try makeTempDir();
    defer {
        removeDirRecursive(dir0);
        testing.allocator.free(dir0);
    }
    const dir1 = try makeTempDir();
    defer {
        removeDirRecursive(dir1);
        testing.allocator.free(dir1);
    }

    var s0 = try Storage.init(dir0, testing.allocator);
    defer s0.deinit();
    var s1 = try Storage.init(dir1, testing.allocator);
    defer s1.deinit();
    try s0.registerTable(makeSchema());
    try s1.registerTable(makeSchema());

    var storages = [_]*Storage{ &s0, &s1 };
    var ps = try partition_set_mod.PartitionSet.init(&storages, testing.allocator);
    defer ps.deinit();

    ps.withCdc(&mgr);

    // Register a cross-partition handler that inserts one row per partition.
    const HASH_CROSS: [32]u8 = [_]u8{0xCC} ** 32;
    try ps.registerCrossAll(HASH_CROSS, .{
        .declareReads = crossNoDeclare,
        .execute = crossInsertExecute,
    });

    const sub = try mgr.subscribe(null, 0);

    // Build a TxnIntent with write_set_hint = [0, 1] (touches both partitions).
    const intent = log_mod.TxnIntent{
        .query_hash = HASH_CROSS,
        .params = &.{},
        .read_set_hint = &.{},
        .write_set_hint = &.{ 0, 1 },
        .resolved_nondet = &.{},
        .client_id = 1,
        .client_seq = 1,
    };
    const payload = try intent.serializeTo(testing.allocator);
    defer testing.allocator.free(payload);

    const header = log_mod.LogEntryHeader.init(1, 0, .txn_intent, payload);
    const entry = log_mod.LogEntry{ .header = header, .payload = payload };
    const results = try ps.runEntry(entry);
    defer testing.allocator.free(results);

    for (results) |r| try testing.expect(r.result == .ok);

    // Both partitions should have emitted a CDC event.
    var buf: [2]CdcEvent = undefined;
    const n = sub.next(&buf);
    defer for (buf[0..n]) |*e| e.deinit();
    try testing.expectEqual(@as(usize, 2), n);

    // Each event should have exactly one insert effect.
    for (buf[0..n]) |ev| {
        try testing.expectEqual(@as(usize, 1), ev.effects.len);
        try testing.expectEqual(CdcOperation.insert, ev.effects[0].op);
        try testing.expect(ev.effects[0].before == null);
        try testing.expect(ev.effects[0].after != null);
    }
}

fn crossNoDeclare(
    _: executor_mod.QueryContext,
    _: u32,
    _: *std.ArrayList(executor_mod.ForeignReadRequest),
) anyerror!void {}

fn crossInsertExecute(
    ctx: executor_mod.QueryContext,
    local_partition: u32,
    _: *Storage,
    _: []const executor_mod.ForeignRow,
    mutations: *std.ArrayList(Mutation),
) anyerror!void {
    const key = try std.fmt.allocPrint(ctx.alloc, "p{d}_key", .{local_partition});
    errdefer ctx.alloc.free(key);
    const vals = try ctx.alloc.alloc(ColumnValue, 2);
    errdefer ctx.alloc.free(vals);
    vals[0] = .{ .int64 = @intCast(local_partition) };
    vals[1] = .{ .int64 = 77 };
    try mutations.append(ctx.alloc, .{
        .kind = .insert,
        .table_id = TABLE_ID,
        .key = key,
        .values = vals,
    });
}

test "CDC: event.kind is txn_intent" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    var storage = try Storage.init(dir, testing.allocator);
    defer storage.deinit();
    try storage.registerTable(makeSchema());

    const sub = try mgr.subscribe(null, 0);

    const m = try makeInsertMutation(1, 1, testing.allocator);
    defer freeMutation(m, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{m}, 1, 7, testing.allocator);

    var buf: [1]CdcEvent = undefined;
    const n = sub.next(&buf);
    defer buf[0].deinit();
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(log_mod.EntryKind.txn_intent, buf[0].kind);
    try testing.expectEqual(@as(u64, 7), buf[0].epoch);
}

test "CDC: multiple effects in one transaction" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    var storage = try Storage.init(dir, testing.allocator);
    defer storage.deinit();
    try storage.registerTable(makeSchema());

    const sub = try mgr.subscribe(null, 0);

    // Insert two rows in a single transaction.
    const m1 = try makeInsertMutation(1, 10, testing.allocator);
    defer freeMutation(m1, testing.allocator);
    const m2 = try makeInsertMutation(2, 20, testing.allocator);
    defer freeMutation(m2, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{ m1, m2 }, 1, 0, testing.allocator);

    var buf: [1]CdcEvent = undefined;
    const n = sub.next(&buf);
    defer buf[0].deinit();
    try testing.expectEqual(@as(usize, 1), n);
    // One event, two effects.
    try testing.expectEqual(@as(usize, 2), buf[0].effects.len);
    try testing.expectEqual(CdcOperation.insert, buf[0].effects[0].op);
    try testing.expectEqual(CdcOperation.insert, buf[0].effects[1].op);
}

test "CDC: table_filter passes matching table" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    var storage = try Storage.init(dir, testing.allocator);
    defer storage.deinit();
    try storage.registerTable(makeSchema());

    // Subscribe specifically to TABLE_ID.
    const sub = try mgr.subscribe(TABLE_ID, 0);

    const m = try makeInsertMutation(1, 5, testing.allocator);
    defer freeMutation(m, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{m}, 1, 0, testing.allocator);

    var buf: [1]CdcEvent = undefined;
    const n = sub.next(&buf);
    defer buf[0].deinit();
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u32, TABLE_ID), buf[0].effects[0].table_id);
}

test "CDC: unsubscribe stops delivery" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    var storage = try Storage.init(dir, testing.allocator);
    defer storage.deinit();
    try storage.registerTable(makeSchema());

    // Subscribe, deliver one event, then unsubscribe and confirm no more events.
    const sub = try mgr.subscribe(null, 0);
    const sub_id = sub.id;

    const m1 = try makeInsertMutation(1, 1, testing.allocator);
    defer freeMutation(m1, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{m1}, 1, 0, testing.allocator);

    var buf1: [1]CdcEvent = undefined;
    const n1 = sub.next(&buf1);
    // sub pointer is still valid here (manager still owns it until unsubscribe)
    try testing.expectEqual(@as(usize, 1), n1);
    buf1[0].deinit();

    mgr.unsubscribe(sub_id);

    // After unsubscribe, no further events should be pushed.
    const m2 = try makeInsertMutation(2, 2, testing.allocator);
    defer freeMutation(m2, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{m2}, 2, 0, testing.allocator);

    try testing.expectEqual(@as(u32, 0), mgr.subscription_count);
}

test "CDC: next with partial buffer drains incrementally" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    var storage = try Storage.init(dir, testing.allocator);
    defer storage.deinit();
    try storage.registerTable(makeSchema());

    const sub = try mgr.subscribe(null, 0);

    const m1 = try makeInsertMutation(1, 1, testing.allocator);
    defer freeMutation(m1, testing.allocator);
    const m2 = try makeInsertMutation(2, 2, testing.allocator);
    defer freeMutation(m2, testing.allocator);
    const m3 = try makeInsertMutation(3, 3, testing.allocator);
    defer freeMutation(m3, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{m1}, 1, 0, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{m2}, 2, 0, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{m3}, 3, 0, testing.allocator);

    // Read two at a time.
    var buf: [2]CdcEvent = undefined;
    const n1 = sub.next(&buf);
    try testing.expectEqual(@as(usize, 2), n1);
    try testing.expectEqual(@as(Seq, 1), buf[0].seq);
    try testing.expectEqual(@as(Seq, 2), buf[1].seq);
    buf[0].deinit();
    buf[1].deinit();

    // One remains.
    const n2 = sub.next(&buf);
    defer buf[0].deinit();
    try testing.expectEqual(@as(usize, 1), n2);
    try testing.expectEqual(@as(Seq, 3), buf[0].seq);
}

test "CDC: update on nonexistent row has null before" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    var storage = try Storage.init(dir, testing.allocator);
    defer storage.deinit();
    try storage.registerTable(makeSchema());

    const sub = try mgr.subscribe(null, 0);

    // Update a key that was never inserted.
    const m = try makeUpdateMutation(99, 55, testing.allocator);
    defer freeMutation(m, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{m}, 1, 0, testing.allocator);

    var buf: [1]CdcEvent = undefined;
    const n = sub.next(&buf);
    defer buf[0].deinit();
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(CdcOperation.update, buf[0].effects[0].op);
    try testing.expect(buf[0].effects[0].before == null);
    try testing.expect(buf[0].effects[0].after != null);
}

test "CDC: delete on nonexistent row has null before" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    var storage = try Storage.init(dir, testing.allocator);
    defer storage.deinit();
    try storage.registerTable(makeSchema());

    const sub = try mgr.subscribe(null, 0);

    const m = try makeDeleteMutation(99, testing.allocator);
    defer freeMutation(m, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{m}, 1, 0, testing.allocator);

    var buf: [1]CdcEvent = undefined;
    const n = sub.next(&buf);
    defer buf[0].deinit();
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(CdcOperation.delete, buf[0].effects[0].op);
    try testing.expect(buf[0].effects[0].before == null);
    try testing.expect(buf[0].effects[0].after == null);
}

test "CDC: aborted transaction produces no events" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    var storage = try Storage.init(dir, testing.allocator);
    defer storage.deinit();
    try storage.registerTable(makeSchema());

    var executor = Executor.init(&storage, testing.allocator);
    defer executor.deinit();
    executor.withCdc(&mgr);

    const sub = try mgr.subscribe(null, 0);

    const hash: [32]u8 = [_]u8{0xBB} ** 32;
    try executor.register(hash, testAbortingHandler);

    const payload = try buildTestPayloadWithHash(hash, testing.allocator);
    defer testing.allocator.free(payload);

    const entry = LogEntry.create(1, 0, .txn_intent, payload);
    const result = try executor.run(entry);
    try testing.expect(result == .abort);

    var buf: [1]CdcEvent = undefined;
    const n = sub.next(&buf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "CDC: non-txn log entry produces no events" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    var storage = try Storage.init(dir, testing.allocator);
    defer storage.deinit();

    var executor = Executor.init(&storage, testing.allocator);
    defer executor.deinit();
    executor.withCdc(&mgr);

    const sub = try mgr.subscribe(null, 0);

    // A noop entry should not emit any CDC event.
    const noop_entry = LogEntry.create(1, 0, .noop, &.{});
    _ = try executor.run(noop_entry);

    var buf: [1]CdcEvent = undefined;
    const n = sub.next(&buf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "CDC: push skips events at or below from_seq cursor" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    var storage = try Storage.init(dir, testing.allocator);
    defer storage.deinit();
    try storage.registerTable(makeSchema());

    // Subscribe from seq 2 — events 1 and 2 should be filtered out.
    const sub = try mgr.subscribe(null, 2);

    const m1 = try makeInsertMutation(1, 1, testing.allocator);
    defer freeMutation(m1, testing.allocator);
    const m2 = try makeInsertMutation(2, 2, testing.allocator);
    defer freeMutation(m2, testing.allocator);
    const m3 = try makeInsertMutation(3, 3, testing.allocator);
    defer freeMutation(m3, testing.allocator);

    try applyWithCdc(&mgr, &storage, &.{m1}, 1, 0, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{m2}, 2, 0, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{m3}, 3, 0, testing.allocator);

    var buf: [3]CdcEvent = undefined;
    const n = sub.next(&buf);
    defer for (buf[0..n]) |*e| e.deinit();

    // Only seq=3 should be delivered.
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(Seq, 3), buf[0].seq);
}

test "CDC: ack before next prunes already-queued events" {
    var mgr = try CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    var storage = try Storage.init(dir, testing.allocator);
    defer storage.deinit();
    try storage.registerTable(makeSchema());

    const sub = try mgr.subscribe(null, 0);

    const m1 = try makeInsertMutation(1, 1, testing.allocator);
    defer freeMutation(m1, testing.allocator);
    const m2 = try makeInsertMutation(2, 2, testing.allocator);
    defer freeMutation(m2, testing.allocator);
    const m3 = try makeInsertMutation(3, 3, testing.allocator);
    defer freeMutation(m3, testing.allocator);

    try applyWithCdc(&mgr, &storage, &.{m1}, 1, 0, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{m2}, 2, 0, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{m3}, 3, 0, testing.allocator);

    // Ack seq=2 before calling next() — events 1 and 2 should be pruned from pending.
    sub.ack(2);
    try testing.expectEqual(@as(Seq, 2), sub.cursor.load(.monotonic));

    var buf: [3]CdcEvent = undefined;
    const n = sub.next(&buf);
    defer for (buf[0..n]) |*e| e.deinit();

    // Only seq=3 should remain.
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(Seq, 3), buf[0].seq);
}

fn testAbortingHandler(
    _: executor_mod.QueryContext,
    _: *Storage,
    _: *std.ArrayListUnmanaged(Mutation),
) anyerror!void {
    return error.ConstraintViolation;
}

fn buildTestPayloadWithHash(hash: [32]u8, alloc: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(alloc);
    const zero8: [8]u8 = std.mem.zeroes([8]u8);
    const zero4: [4]u8 = std.mem.zeroes([4]u8);
    try buf.appendSlice(alloc, &hash);
    try buf.appendSlice(alloc, &zero8); // client_id
    try buf.appendSlice(alloc, &zero8); // client_seq
    try buf.appendSlice(alloc, &zero4); // read_count
    try buf.appendSlice(alloc, &zero4); // write_count
    try buf.appendSlice(alloc, &zero4); // params_len
    try buf.appendSlice(alloc, &zero4); // nondet_count
    try buf.appendSlice(alloc, &zero8); // recon_seq
    return buf.toOwnedSlice(alloc);
}

fn buildTestPayload(id: i64, val: i64, alloc: std.mem.Allocator) ![]u8 {
    _ = id;
    _ = val;
    // Build a minimal TxnIntent payload with hash=[0xAB]*32 and no params/nondet
    const hash: [32]u8 = [_]u8{0xAB} ** 32;
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(alloc);
    // Header: query_hash(32) + client_id(8) + client_seq(8) + read_count(4) + write_count(4) + params_len(4) + nondet_count(4) + recon_seq(8) = 72 bytes
    try buf.appendSlice(alloc, &hash);
    const zero8: [8]u8 = std.mem.zeroes([8]u8);
    const zero4: [4]u8 = std.mem.zeroes([4]u8);
    try buf.appendSlice(alloc, &zero8); // client_id
    try buf.appendSlice(alloc, &zero8); // client_seq
    try buf.appendSlice(alloc, &zero4); // read_count
    try buf.appendSlice(alloc, &zero4); // write_count
    try buf.appendSlice(alloc, &zero4); // params_len
    try buf.appendSlice(alloc, &zero4); // nondet_count
    try buf.appendSlice(alloc, &zero8); // recon_seq
    return buf.toOwnedSlice(alloc);
}
