/// Unit tests for the CDC module (M10).
const std = @import("std");
const testing = std.testing;
const cdc_mod = @import("cdc.zig");
const storage_mod = @import("storage.zig");
const executor_mod = @import("executor.zig");
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
    var bi = try mgr.captureBeforeImages(mutations, storage, pre_seq, alloc);
    defer bi.deinit();
    try storage.apply(mutations, seq);
    try mgr.dispatch(seq, epoch, mutations, bi, alloc);
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "CdcManager: init and deinit" {
    var mgr = CdcManager.init(testing.allocator);
    defer mgr.deinit();
    try testing.expectEqual(@as(usize, 0), mgr.subscriptions.items.len);
}

test "CdcManager: subscribe and unsubscribe" {
    var mgr = CdcManager.init(testing.allocator);
    defer mgr.deinit();

    const sub = try mgr.subscribe(null, 0);
    try testing.expectEqual(@as(usize, 1), mgr.subscriptions.items.len);
    try testing.expectEqual(@as(u64, 1), sub.id);

    mgr.unsubscribe(sub.id);
    try testing.expectEqual(@as(usize, 0), mgr.subscriptions.items.len);
}

test "CDC: insert produces event with no before and correct after" {
    var mgr = CdcManager.init(testing.allocator);
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
    const n = try sub.next(&buf);
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
    var mgr = CdcManager.init(testing.allocator);
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
    const nd1 = try sub.next(&drain1);
    if (nd1 > 0) drain1[0].deinit();

    // Now update
    const upd = try makeUpdateMutation(1, 200, testing.allocator);
    defer freeMutation(upd, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{upd}, 2, 0, testing.allocator);

    var buf: [1]CdcEvent = undefined;
    const n = try sub.next(&buf);
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
    var mgr = CdcManager.init(testing.allocator);
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
    const nd2 = try sub.next(&drain2);
    if (nd2 > 0) drain2[0].deinit();

    const del = try makeDeleteMutation(1, testing.allocator);
    defer freeMutation(del, testing.allocator);
    try applyWithCdc(&mgr, &storage, &.{del}, 2, 0, testing.allocator);

    var buf: [1]CdcEvent = undefined;
    const n = try sub.next(&buf);
    defer buf[0].deinit();
    try testing.expectEqual(@as(usize, 1), n);

    const ef = buf[0].effects[0];
    try testing.expectEqual(CdcOperation.delete, ef.op);
    try testing.expect(ef.before != null);
    try testing.expectEqual(@as(i64, 42), ef.before.?[1].int64);
    try testing.expect(ef.after == null);
}

test "CDC: table_filter excludes non-matching tables" {
    var mgr = CdcManager.init(testing.allocator);
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
    const n = try sub.next(&buf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "CDC: multiple subscribers each receive the event" {
    var mgr = CdcManager.init(testing.allocator);
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
    const n1 = try sub1.next(&buf1);
    defer buf1[0].deinit();
    const n2 = try sub2.next(&buf2);
    defer buf2[0].deinit();

    try testing.expectEqual(@as(usize, 1), n1);
    try testing.expectEqual(@as(usize, 1), n2);
    try testing.expectEqual(@as(Seq, 1), buf1[0].seq);
    try testing.expectEqual(@as(Seq, 1), buf2[0].seq);
}

test "CDC: ack advances cursor" {
    var mgr = CdcManager.init(testing.allocator);
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

    try testing.expectEqual(@as(Seq, 0), sub.cursor);

    var buf: [2]CdcEvent = undefined;
    const n = try sub.next(&buf);
    try testing.expectEqual(@as(usize, 2), n);
    buf[0].deinit();
    buf[1].deinit();

    try sub.ack(2);
    try testing.expectEqual(@as(Seq, 2), sub.cursor);
}

test "CDC: no events for empty mutation list" {
    var mgr = CdcManager.init(testing.allocator);
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
    const n = try sub.next(&buf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "CDC: Executor.withCdc routes events through executor" {
    var mgr = CdcManager.init(testing.allocator);
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
    const n = try sub.next(&buf);
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

fn buildTestPayload(id: i64, val: i64, alloc: std.mem.Allocator) ![]u8 {
    _ = id;
    _ = val;
    // Build a minimal TxnIntent payload with hash=[0xAB]*32 and no params/nondet
    const hash: [32]u8 = [_]u8{0xAB} ** 32;
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(alloc);
    // Header: query_hash(32) + client_id(8) + client_seq(8) + read_count(4) + write_count(4) + params_len(4) + nondet_count(4) = 64 bytes
    try buf.appendSlice(alloc, &hash);
    const zero8: [8]u8 = std.mem.zeroes([8]u8);
    const zero4: [4]u8 = std.mem.zeroes([4]u8);
    try buf.appendSlice(alloc, &zero8); // client_id
    try buf.appendSlice(alloc, &zero8); // client_seq
    try buf.appendSlice(alloc, &zero4); // read_count
    try buf.appendSlice(alloc, &zero4); // write_count
    try buf.appendSlice(alloc, &zero4); // params_len
    try buf.appendSlice(alloc, &zero4); // nondet_count
    return buf.toOwnedSlice(alloc);
}
