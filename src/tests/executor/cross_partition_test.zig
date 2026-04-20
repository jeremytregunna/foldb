/// M8 cross-partition execution tests.
///
/// Tests the dataflow exchange protocol where a single TxnIntent spans two partitions:
///   - Phase A: each partition declares which foreign rows it needs
///   - Phase B: fetch foreign rows at seq-1
///   - Phase C: execute local slice with foreign context
///   - Phase D: apply local mutations atomically
const std = @import("std");
const testing = std.testing;
const executor_mod = @import("executor.zig");
const partition_set_mod = @import("partition_set.zig");
const storage_mod = @import("storage.zig");
const log_mod = @import("log.zig");

const PartitionSet = partition_set_mod.PartitionSet;
const PartitionExecResult = partition_set_mod.PartitionExecResult;
const CrossPartitionQueryHandler = executor_mod.CrossPartitionQueryHandler;
const QueryContext = executor_mod.QueryContext;
const ForeignReadRequest = executor_mod.ForeignReadRequest;
const ForeignRow = executor_mod.ForeignRow;
const Storage = executor_mod.Storage;
const Mutation = executor_mod.Mutation;
const ExecResult = executor_mod.ExecResult;
const AbortCode = executor_mod.AbortCode;
const LogEntry = executor_mod.LogEntry;
const EntryKind = executor_mod.EntryKind;
const serializeTxnIntent = executor_mod.serializeTxnIntent;
const ResolvedValue = executor_mod.ResolvedValue;

const TableSchema = storage_mod.TableSchema;
const ColumnSchema = storage_mod.ColumnSchema;
const ColumnValue = storage_mod.ColumnValue;
const KeyRange = storage_mod.KeyRange;

// --- Table schema: table_id=1, columns=[string key, int64 balance] ---

const ACCOUNTS_TABLE: u32 = 1;

fn accountsSchema() TableSchema {
    return .{
        .table_id = ACCOUNTS_TABLE,
        .columns = &.{
            .{ .col_type = .string, .nullable = false },
            .{ .col_type = .int64, .nullable = false },
        },
    };
}

// --- Hashes ---

const HASH_SETUP: [32]u8 = [_]u8{0x10} ++ [_]u8{0} ** 31;
const HASH_TRANSFER: [32]u8 = [_]u8{0x20} ++ [_]u8{0} ** 31;

// --- Temp dir helpers (copied from executor_test.zig) ---

fn makeTempDir(alloc: std.mem.Allocator, suffix: []const u8) ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const path = try std.fmt.allocPrint(alloc, "/tmp/xpart_test_{d}_{s}", .{ ns, suffix });
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

// --- Param encoding ---
//
// Setup params:  key_len(u16) key[key_len] balance(i64)
// Transfer params: sender_key_len(u16) sender_key[n] receiver_key_len(u16) receiver_key[m] amount(i64)

fn encodeSetupParams(alloc: std.mem.Allocator, key: []const u8, balance: i64) ![]u8 {
    var buf = try alloc.alloc(u8, 2 + key.len + 8);
    std.mem.writeInt(u16, buf[0..2], @intCast(key.len), .little);
    @memcpy(buf[2 .. 2 + key.len], key);
    std.mem.writeInt(i64, buf[2 + key.len ..][0..8], balance, .little);
    return buf;
}

fn encodeTransferParams(alloc: std.mem.Allocator, sender_key: []const u8, receiver_key: []const u8, amount: i64) ![]u8 {
    const total = 2 + sender_key.len + 2 + receiver_key.len + 8;
    var buf = try alloc.alloc(u8, total);
    var off: usize = 0;
    std.mem.writeInt(u16, buf[off..][0..2], @intCast(sender_key.len), .little);
    off += 2;
    @memcpy(buf[off .. off + sender_key.len], sender_key);
    off += sender_key.len;
    std.mem.writeInt(u16, buf[off..][0..2], @intCast(receiver_key.len), .little);
    off += 2;
    @memcpy(buf[off .. off + receiver_key.len], receiver_key);
    off += receiver_key.len;
    std.mem.writeInt(i64, buf[off..][0..8], amount, .little);
    return buf;
}

fn decodeTransferParams(params: []const u8) !struct { sender_key: []const u8, receiver_key: []const u8, amount: i64 } {
    if (params.len < 2) return error.BadParams;
    const sk_len = std.mem.readInt(u16, params[0..2], .little);
    if (params.len < 2 + sk_len + 2) return error.BadParams;
    const sender_key = params[2 .. 2 + sk_len];
    const off = 2 + sk_len;
    const rk_len = std.mem.readInt(u16, params[off..][0..2], .little);
    if (params.len < off + 2 + rk_len + 8) return error.BadParams;
    const receiver_key = params[off + 2 .. off + 2 + rk_len];
    const amount = std.mem.readInt(i64, params[off + 2 + rk_len ..][0..8], .little);
    return .{ .sender_key = sender_key, .receiver_key = receiver_key, .amount = amount };
}

// --- Setup handler: inserts a row (key, balance) on the local partition ---

fn handlerSetup(ctx: QueryContext, _: *Storage, mutations: *std.ArrayList(Mutation)) !void {
    if (ctx.params.len < 2) return error.ConstraintViolation;
    const key_len = std.mem.readInt(u16, ctx.params[0..2], .little);
    if (ctx.params.len < 2 + key_len + 8) return error.ConstraintViolation;
    const key = ctx.params[2 .. 2 + key_len];
    const balance = std.mem.readInt(i64, ctx.params[2 + key_len ..][0..8], .little);
    const key_copy = try ctx.alloc.dupe(u8, key);
    errdefer ctx.alloc.free(key_copy);
    const vals = try ctx.alloc.alloc(ColumnValue, 2);
    errdefer ctx.alloc.free(vals);
    vals[0] = .{ .string = try ctx.alloc.dupe(u8, key) };
    vals[1] = .{ .int64 = balance };
    try mutations.append(ctx.alloc, .{ .kind = .insert, .table_id = ACCOUNTS_TABLE, .key = key_copy, .values = vals });
}

// --- Transfer handler (cross-partition) ---
//
// Partition 0 (sender):
//   declareReads: nothing (reads sender from local storage in execute)
//   execute: read sender balance locally, check >= amount, debit
//
// Partition 1 (receiver):
//   declareReads: request sender row from partition 0
//   execute: read sender balance from foreign_rows, check >= amount, credit receiver

fn transferDeclareReads(ctx: QueryContext, local_partition: u32, out: *std.ArrayList(ForeignReadRequest)) !void {
    if (local_partition != 1) return; // only receiver partition needs a foreign read
    const p = try decodeTransferParams(ctx.params);
    const sender_key_copy = try ctx.alloc.dupe(u8, p.sender_key);
    try out.append(ctx.alloc, .{
        .from_partition = 0,
        .table_id = ACCOUNTS_TABLE,
        .key = sender_key_copy,
    });
}

fn transferExecute(
    ctx: QueryContext,
    local_partition: u32,
    storage: *Storage,
    foreign: []const ForeignRow,
    mutations: *std.ArrayList(Mutation),
) !void {
    const p = try decodeTransferParams(ctx.params);

    if (local_partition == 0) {
        // Sender partition: read local balance, check, debit.
        const row = try storage.get(ACCOUNTS_TABLE, p.sender_key, ctx.seq - 1);
        if (row == null) return error.ConstraintViolation;
        var r = row.?;
        defer r.deinit(ctx.alloc);
        const balance = r.values[1].int64;
        if (balance < p.amount) return error.ConstraintViolation;

        const key_copy = try ctx.alloc.dupe(u8, p.sender_key);
        errdefer ctx.alloc.free(key_copy);
        const vals = try ctx.alloc.alloc(ColumnValue, 2);
        errdefer ctx.alloc.free(vals);
        vals[0] = .{ .string = try ctx.alloc.dupe(u8, p.sender_key) };
        vals[1] = .{ .int64 = balance - p.amount };
        try mutations.append(ctx.alloc, .{ .kind = .update, .table_id = ACCOUNTS_TABLE, .key = key_copy, .values = vals });
    } else {
        // Receiver partition: verify sender balance via foreign rows (same constraint check),
        // then credit receiver.
        var sender_balance: i64 = 0;
        var found_foreign = false;
        for (foreign) |fr| {
            if (fr.from_partition == 0 and std.mem.eql(u8, fr.key, p.sender_key)) {
                if (fr.row) |r| {
                    sender_balance = r.values[1].int64;
                    found_foreign = true;
                }
                break;
            }
        }
        if (!found_foreign) return error.ConstraintViolation;
        if (sender_balance < p.amount) return error.ConstraintViolation;

        // Read current receiver balance (or default to 0).
        const recv_row = try storage.get(ACCOUNTS_TABLE, p.receiver_key, ctx.seq - 1);
        var current_recv: i64 = 0;
        if (recv_row) |rr| {
            var rrr = rr;
            defer rrr.deinit(ctx.alloc);
            current_recv = rrr.values[1].int64;
        }

        const key_copy = try ctx.alloc.dupe(u8, p.receiver_key);
        errdefer ctx.alloc.free(key_copy);
        const vals = try ctx.alloc.alloc(ColumnValue, 2);
        errdefer ctx.alloc.free(vals);
        vals[0] = .{ .string = try ctx.alloc.dupe(u8, p.receiver_key) };
        vals[1] = .{ .int64 = current_recv + p.amount };
        const kind: storage_mod.MutationKind = if (recv_row != null) .update else .insert;
        try mutations.append(ctx.alloc, .{ .kind = kind, .table_id = ACCOUNTS_TABLE, .key = key_copy, .values = vals });
    }
}

const TRANSFER_HANDLER = CrossPartitionQueryHandler{
    .declareReads = transferDeclareReads,
    .execute = transferExecute,
};

// --- Test setup ---

fn makeEntry(
    alloc: std.mem.Allocator,
    seq: u64,
    hash: *const [32]u8,
    read_hint: []const u32,
    write_hint: []const u32,
    params: []const u8,
) !LogEntry {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    try serializeTxnIntent(hash, 0, seq, 0, read_hint, write_hint, params, &.{}, &payload, alloc);
    const payload_copy = try alloc.dupe(u8, payload.items);
    return LogEntry.create(seq, 1, .txn_intent, payload_copy);
}

fn setupPartitionSet(alloc: std.mem.Allocator, dirs: []const []const u8) !struct {
    ps: PartitionSet,
    storages: []*Storage,
    obj_store: *storage_mod.MemoryObjectStore,
} {
    const obj_store = try alloc.create(storage_mod.MemoryObjectStore);
    obj_store.* = storage_mod.MemoryObjectStore.init(alloc);
    errdefer {
        obj_store.deinit();
        alloc.destroy(obj_store);
    }

    const storages = try alloc.alloc(*Storage, dirs.len);
    errdefer alloc.free(storages);
    for (dirs, 0..) |dir, i| {
        storages[i] = try alloc.create(Storage);
        storages[i].* = try Storage.init(dir, alloc);
        const cache_dir = try std.fmt.allocPrint(alloc, "{s}/cache", .{dir});
        defer alloc.free(cache_dir);
        try storages[i].setObjectStore(obj_store.objectStore(), cache_dir);
        try storages[i].registerTable(accountsSchema());
    }
    var ps = try PartitionSet.init(storages, alloc);
    try ps.registerAll(HASH_SETUP, handlerSetup);
    try ps.registerCrossAll(HASH_TRANSFER, TRANSFER_HANDLER);
    return .{ .ps = ps, .storages = storages, .obj_store = obj_store };
}

fn teardownPartitionSet(ps: *PartitionSet, storages: []*Storage, obj_store: ?*storage_mod.MemoryObjectStore, alloc: std.mem.Allocator) void {
    ps.deinit();
    for (storages) |s| {
        s.deinit();
        alloc.destroy(s);
    }
    alloc.free(storages);
    if (obj_store) |os| {
        os.deinit();
        alloc.destroy(os);
    }
}

// --- Tests ---

test "cross-partition transfer: happy path" {
    const alloc = std.testing.allocator;

    const dir0 = try makeTempDir(alloc, "xp0");
    const dir1 = try makeTempDir(alloc, "xp1");
    defer {
        removeDir(dir0);
        removeDir(dir1);
        alloc.free(dir0);
        alloc.free(dir1);
    }

    var setup = try setupPartitionSet(alloc, &.{ dir0, dir1 });
    defer teardownPartitionSet(&setup.ps, setup.storages, setup.obj_store, alloc);

    // seq=1: insert sender (partition 0, balance=100)
    const p0 = try encodeSetupParams(alloc, "alice", 100);
    defer alloc.free(p0);
    const e1 = try makeEntry(alloc, 1, &HASH_SETUP, &.{0}, &.{0}, p0);
    defer alloc.free(e1.payload);
    const r1 = try setup.ps.runEntry(e1);
    defer alloc.free(r1);
    try testing.expectEqual(@as(usize, 1), r1.len);
    try testing.expect(r1[0].result == .ok);

    // seq=2: insert receiver (partition 1, balance=50)
    const p1 = try encodeSetupParams(alloc, "bob", 50);
    defer alloc.free(p1);
    const e2 = try makeEntry(alloc, 2, &HASH_SETUP, &.{1}, &.{1}, p1);
    defer alloc.free(e2.payload);
    const r2 = try setup.ps.runEntry(e2);
    defer alloc.free(r2);
    try testing.expectEqual(@as(usize, 1), r2.len);
    try testing.expect(r2[0].result == .ok);

    // seq=3: cross-partition transfer of 30 from alice (p0) to bob (p1)
    const tp = try encodeTransferParams(alloc, "alice", "bob", 30);
    defer alloc.free(tp);
    const e3 = try makeEntry(alloc, 3, &HASH_TRANSFER, &.{0}, &.{ 0, 1 }, tp);
    defer alloc.free(e3.payload);
    const r3 = try setup.ps.runEntry(e3);
    defer alloc.free(r3);

    try testing.expectEqual(@as(usize, 2), r3.len);
    try testing.expect(r3[0].result == .ok);
    try testing.expect(r3[1].result == .ok);
    try testing.expectEqual(@as(u64, 1), r3[0].result.ok.rows_affected); // debit
    try testing.expectEqual(@as(u64, 1), r3[1].result.ok.rows_affected); // credit

    // Verify partition 0: alice balance = 70
    const alice = try setup.storages[0].get(ACCOUNTS_TABLE, "alice", 3);
    try testing.expect(alice != null);
    var a = alice.?;
    defer a.deinit(alloc);
    try testing.expectEqual(@as(i64, 70), a.values[1].int64);

    // Verify partition 1: bob balance = 80
    const bob = try setup.storages[1].get(ACCOUNTS_TABLE, "bob", 3);
    try testing.expect(bob != null);
    var b = bob.?;
    defer b.deinit(alloc);
    try testing.expectEqual(@as(i64, 80), b.values[1].int64);

    // Both executors committed to seq=3
    try testing.expectEqual(@as(u64, 3), setup.ps.executors[0].committed_seq);
    try testing.expectEqual(@as(u64, 3), setup.ps.executors[1].committed_seq);
}

test "cross-partition transfer: insufficient funds aborts all partitions" {
    const alloc = std.testing.allocator;

    const dir0 = try makeTempDir(alloc, "xpa0");
    const dir1 = try makeTempDir(alloc, "xpa1");
    defer {
        removeDir(dir0);
        removeDir(dir1);
        alloc.free(dir0);
        alloc.free(dir1);
    }

    var setup = try setupPartitionSet(alloc, &.{ dir0, dir1 });
    defer teardownPartitionSet(&setup.ps, setup.storages, setup.obj_store, alloc);

    // seq=1: insert sender with only 10
    const p0 = try encodeSetupParams(alloc, "alice", 10);
    defer alloc.free(p0);
    const e1 = try makeEntry(alloc, 1, &HASH_SETUP, &.{0}, &.{0}, p0);
    defer alloc.free(e1.payload);
    const r1 = try setup.ps.runEntry(e1);
    defer alloc.free(r1);
    try testing.expect(r1[0].result == .ok);

    // seq=2: insert receiver
    const p1 = try encodeSetupParams(alloc, "bob", 0);
    defer alloc.free(p1);
    const e2 = try makeEntry(alloc, 2, &HASH_SETUP, &.{1}, &.{1}, p1);
    defer alloc.free(e2.payload);
    const r2 = try setup.ps.runEntry(e2);
    defer alloc.free(r2);
    try testing.expect(r2[0].result == .ok);

    // seq=3: transfer 50 — should abort (alice only has 10)
    const tp = try encodeTransferParams(alloc, "alice", "bob", 50);
    defer alloc.free(tp);
    const e3 = try makeEntry(alloc, 3, &HASH_TRANSFER, &.{0}, &.{ 0, 1 }, tp);
    defer alloc.free(e3.payload);
    const r3 = try setup.ps.runEntry(e3);
    defer alloc.free(r3);

    try testing.expectEqual(@as(usize, 2), r3.len);
    for (r3) |res| {
        try testing.expect(res.result == .abort);
        try testing.expectEqual(AbortCode.constraint_violation, res.result.abort.code);
    }

    // Storage unchanged: alice still has 10, bob still has 0
    const alice = try setup.storages[0].get(ACCOUNTS_TABLE, "alice", 3);
    try testing.expect(alice != null);
    var a = alice.?;
    defer a.deinit(alloc);
    try testing.expectEqual(@as(i64, 10), a.values[1].int64);

    const bob = try setup.storages[1].get(ACCOUNTS_TABLE, "bob", 3);
    try testing.expect(bob != null);
    var b = bob.?;
    defer b.deinit(alloc);
    try testing.expectEqual(@as(i64, 0), b.values[1].int64);
}

test "PartitionSet: single-partition fast path" {
    const alloc = std.testing.allocator;

    const dir0 = try makeTempDir(alloc, "xps0");
    const dir1 = try makeTempDir(alloc, "xps1");
    defer {
        removeDir(dir0);
        removeDir(dir1);
        alloc.free(dir0);
        alloc.free(dir1);
    }

    var setup = try setupPartitionSet(alloc, &.{ dir0, dir1 });
    defer teardownPartitionSet(&setup.ps, setup.storages, setup.obj_store, alloc);

    // Single-partition entry targeting partition 1 only
    const params = try encodeSetupParams(alloc, "carol", 999);
    defer alloc.free(params);
    const entry = try makeEntry(alloc, 1, &HASH_SETUP, &.{1}, &.{1}, params);
    defer alloc.free(entry.payload);

    const results = try setup.ps.runEntry(entry);
    defer alloc.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqual(@as(u32, 1), results[0].partition);
    try testing.expect(results[0].result == .ok);

    // carol exists in partition 1
    const row = try setup.storages[1].get(ACCOUNTS_TABLE, "carol", 1);
    try testing.expect(row != null);
    var r = row.?;
    defer r.deinit(alloc);
    try testing.expectEqual(@as(i64, 999), r.values[1].int64);

    // partition 0 is unaffected
    const missing = try setup.storages[0].get(ACCOUNTS_TABLE, "carol", 1);
    try testing.expect(missing == null);
}

test "PartitionSet: missing cross-partition handler returns abort" {
    const alloc = std.testing.allocator;

    const dir0 = try makeTempDir(alloc, "xpm0");
    const dir1 = try makeTempDir(alloc, "xpm1");
    defer {
        removeDir(dir0);
        removeDir(dir1);
        alloc.free(dir0);
        alloc.free(dir1);
    }

    var setup = try setupPartitionSet(alloc, &.{ dir0, dir1 });
    defer teardownPartitionSet(&setup.ps, setup.storages, setup.obj_store, alloc);

    // Build a cross-partition entry using HASH_SETUP (a single-partition handler)
    const params = try encodeSetupParams(alloc, "x", 1);
    defer alloc.free(params);
    const entry = try makeEntry(alloc, 1, &HASH_SETUP, &.{}, &.{ 0, 1 }, params);
    defer alloc.free(entry.payload);

    const results = try setup.ps.runEntry(entry);
    defer alloc.free(results);

    try testing.expectEqual(@as(usize, 2), results.len);
    for (results) |res| {
        try testing.expect(res.result == .abort);
        try testing.expectEqual(AbortCode.missing_query, res.result.abort.code);
    }
}

test "cross-partition replay equivalence" {
    // Run a sequence of entries on two independent PartitionSets.
    // Both must produce identical storage state — the determinism invariant.
    const alloc = std.testing.allocator;

    const dirsA = [_][]const u8{
        try makeTempDir(alloc, "xpreA0"),
        try makeTempDir(alloc, "xpreA1"),
    };
    const dirsB = [_][]const u8{
        try makeTempDir(alloc, "xpreB0"),
        try makeTempDir(alloc, "xpreB1"),
    };
    defer {
        for (dirsA) |d| {
            removeDir(d);
            alloc.free(d);
        }
        for (dirsB) |d| {
            removeDir(d);
            alloc.free(d);
        }
    }

    var setupA = try setupPartitionSet(alloc, &dirsA);
    defer teardownPartitionSet(&setupA.ps, setupA.storages, setupA.obj_store, alloc);

    var setupB = try setupPartitionSet(alloc, &dirsB);
    defer teardownPartitionSet(&setupB.ps, setupB.storages, setupB.obj_store, alloc);

    // Build the entry sequence
    const p_alice = try encodeSetupParams(alloc, "alice", 200);
    defer alloc.free(p_alice);
    const p_bob = try encodeSetupParams(alloc, "bob", 0);
    defer alloc.free(p_bob);
    const p_xfer1 = try encodeTransferParams(alloc, "alice", "bob", 60);
    defer alloc.free(p_xfer1);
    const p_xfer2 = try encodeTransferParams(alloc, "alice", "bob", 40);
    defer alloc.free(p_xfer2);

    const entries = [_]LogEntry{
        try makeEntry(alloc, 1, &HASH_SETUP, &.{0}, &.{0}, p_alice),
        try makeEntry(alloc, 2, &HASH_SETUP, &.{1}, &.{1}, p_bob),
        try makeEntry(alloc, 3, &HASH_TRANSFER, &.{0}, &.{ 0, 1 }, p_xfer1),
        try makeEntry(alloc, 4, &HASH_TRANSFER, &.{0}, &.{ 0, 1 }, p_xfer2),
    };
    defer for (entries) |e| alloc.free(e.payload);

    // Run on both sets
    for (entries) |e| {
        const rA = try setupA.ps.runEntry(e);
        alloc.free(rA);
        const rB = try setupB.ps.runEntry(e);
        alloc.free(rB);
    }

    // Compare storage contents for each partition
    for (0..2) |pi| {
        var iterA = try setupA.storages[pi].scan(ACCOUNTS_TABLE, KeyRange.all(), 4, alloc);
        defer iterA.deinit();
        var iterB = try setupB.storages[pi].scan(ACCOUNTS_TABLE, KeyRange.all(), 4, alloc);
        defer iterB.deinit();

        while (try iterA.next()) |rowA| {
            const rowB_opt = try iterB.next();
            try testing.expect(rowB_opt != null);
            const rowB = rowB_opt.?;
            try testing.expectEqualSlices(u8, rowA.key, rowB.key);
            try testing.expectEqual(rowA.seq, rowB.seq);
            try testing.expectEqual(rowA.values.len, rowB.values.len);
            for (rowA.values, rowB.values) |va, vb| {
                try testing.expect(va.eql(vb));
            }
        }
        // Both iterators must be exhausted at the same time
        try testing.expect(try iterB.next() == null);
    }
}

// --- Additional coverage tests ---

test "PartitionSet: crc mismatch returns bad_params abort" {
    const alloc = std.testing.allocator;
    const dir0 = try makeTempDir(alloc, "xpcrc0");
    const dir1 = try makeTempDir(alloc, "xpcrc1");
    defer {
        removeDir(dir0);
        removeDir(dir1);
        alloc.free(dir0);
        alloc.free(dir1);
    }

    var setup = try setupPartitionSet(alloc, &.{ dir0, dir1 });
    defer teardownPartitionSet(&setup.ps, setup.storages, setup.obj_store, alloc);

    const params = try encodeSetupParams(alloc, "x", 1);
    defer alloc.free(params);
    var entry = try makeEntry(alloc, 1, &HASH_SETUP, &.{0}, &.{0}, params);
    defer alloc.free(entry.payload);
    entry.header.payload_crc = 0xDEADBEEF; // corrupt

    const results = try setup.ps.runEntry(entry);
    defer alloc.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expect(results[0].result == .abort);
    try testing.expectEqual(AbortCode.bad_params, results[0].result.abort.code);
}

test "PartitionSet: invalid payload returns bad_params abort" {
    const alloc = std.testing.allocator;
    const dir0 = try makeTempDir(alloc, "xpbad0");
    const dir1 = try makeTempDir(alloc, "xpbad1");
    defer {
        removeDir(dir0);
        removeDir(dir1);
        alloc.free(dir0);
        alloc.free(dir1);
    }

    var setup = try setupPartitionSet(alloc, &.{ dir0, dir1 });
    defer teardownPartitionSet(&setup.ps, setup.storages, setup.obj_store, alloc);

    const garbage = try alloc.dupe(u8, "not a valid txn intent payload");
    const entry = LogEntry.create(1, 1, .txn_intent, garbage);
    defer alloc.free(entry.payload);

    const results = try setup.ps.runEntry(entry);
    defer alloc.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expect(results[0].result == .abort);
    try testing.expectEqual(AbortCode.bad_params, results[0].result.abort.code);
}

test "PartitionSet: single-partition write_set_hint out of range" {
    const alloc = std.testing.allocator;
    const dir0 = try makeTempDir(alloc, "xpoor0");
    const dir1 = try makeTempDir(alloc, "xpoor1");
    defer {
        removeDir(dir0);
        removeDir(dir1);
        alloc.free(dir0);
        alloc.free(dir1);
    }

    var setup = try setupPartitionSet(alloc, &.{ dir0, dir1 });
    defer teardownPartitionSet(&setup.ps, setup.storages, setup.obj_store, alloc);

    const params = try encodeSetupParams(alloc, "x", 1);
    defer alloc.free(params);
    const entry = try makeEntry(alloc, 1, &HASH_SETUP, &.{}, &.{99}, params);
    defer alloc.free(entry.payload);

    const results = try setup.ps.runEntry(entry);
    defer alloc.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expect(results[0].result == .abort);
    try testing.expectEqual(AbortCode.bad_params, results[0].result.abort.code);
}

test "PartitionSet: cross-partition write_set_hint partition out of range" {
    const alloc = std.testing.allocator;
    const dir0 = try makeTempDir(alloc, "xpxor0");
    const dir1 = try makeTempDir(alloc, "xpxor1");
    defer {
        removeDir(dir0);
        removeDir(dir1);
        alloc.free(dir0);
        alloc.free(dir1);
    }

    var setup = try setupPartitionSet(alloc, &.{ dir0, dir1 });
    defer teardownPartitionSet(&setup.ps, setup.storages, setup.obj_store, alloc);

    const tp = try encodeTransferParams(alloc, "alice", "bob", 10);
    defer alloc.free(tp);
    // partition 99 doesn't exist
    const entry = try makeEntry(alloc, 1, &HASH_TRANSFER, &.{}, &.{ 0, 99 }, tp);
    defer alloc.free(entry.payload);

    const results = try setup.ps.runEntry(entry);
    defer alloc.free(results);

    try testing.expectEqual(@as(usize, 2), results.len);
    for (results) |r| {
        try testing.expect(r.result == .abort);
        try testing.expectEqual(AbortCode.bad_params, r.result.abort.code);
    }
}

test "PartitionSet: non-ConstraintViolation error in Phase C propagates" {
    const alloc = std.testing.allocator;
    const dir0 = try makeTempDir(alloc, "xperr0");
    const dir1 = try makeTempDir(alloc, "xperr1");
    defer {
        removeDir(dir0);
        removeDir(dir1);
        alloc.free(dir0);
        alloc.free(dir1);
    }

    const storages = try alloc.alloc(*Storage, 2);
    for (&[_][]const u8{ dir0, dir1 }, 0..) |dir, i| {
        storages[i] = try alloc.create(Storage);
        storages[i].* = try Storage.init(dir, alloc);
        try storages[i].registerTable(accountsSchema());
    }
    var ps = try PartitionSet.init(storages, alloc);
    defer teardownPartitionSet(&ps, storages, null, alloc);

    const HASH_BOOM: [32]u8 = [_]u8{0x30} ++ [_]u8{0} ** 31;
    const boom_handler = CrossPartitionQueryHandler{
        .declareReads = struct {
            fn f(_: QueryContext, _: u32, _: *std.ArrayList(ForeignReadRequest)) !void {}
        }.f,
        .execute = struct {
            fn f(_: QueryContext, _: u32, _: *Storage, _: []const ForeignRow, _: *std.ArrayList(Mutation)) !void {
                return error.DiskQuotaExceeded;
            }
        }.f,
    };
    try ps.registerCrossAll(HASH_BOOM, boom_handler);

    const params = try encodeSetupParams(alloc, "x", 1);
    defer alloc.free(params);
    const entry = try makeEntry(alloc, 1, &HASH_BOOM, &.{}, &.{ 0, 1 }, params);
    defer alloc.free(entry.payload);

    try testing.expectError(error.DiskQuotaExceeded, ps.runEntry(entry));
}

test "PartitionSet: non-txn entry advances committed_seq on all executors" {
    const alloc = std.testing.allocator;
    const dir0 = try makeTempDir(alloc, "xpntx0");
    const dir1 = try makeTempDir(alloc, "xpntx1");
    defer {
        removeDir(dir0);
        removeDir(dir1);
        alloc.free(dir0);
        alloc.free(dir1);
    }

    var setup = try setupPartitionSet(alloc, &.{ dir0, dir1 });
    defer teardownPartitionSet(&setup.ps, setup.storages, setup.obj_store, alloc);

    const empty = try alloc.dupe(u8, "");
    const entry = LogEntry.create(7, 1, .noop, empty);
    defer alloc.free(entry.payload);

    const results = try setup.ps.runEntry(entry);
    defer alloc.free(results);

    try testing.expectEqual(@as(usize, 2), results.len);
    for (results) |r| try testing.expect(r.result == .ok);
    try testing.expectEqual(@as(u64, 7), setup.ps.executors[0].committed_seq);
    try testing.expectEqual(@as(u64, 7), setup.ps.executors[1].committed_seq);
}

test "PartitionSet: write_set_hint empty defaults to partition 0" {
    const alloc = std.testing.allocator;
    const dir0 = try makeTempDir(alloc, "xpwsh0");
    const dir1 = try makeTempDir(alloc, "xpwsh1");
    defer {
        removeDir(dir0);
        removeDir(dir1);
        alloc.free(dir0);
        alloc.free(dir1);
    }

    var setup = try setupPartitionSet(alloc, &.{ dir0, dir1 });
    defer teardownPartitionSet(&setup.ps, setup.storages, setup.obj_store, alloc);

    const params = try encodeSetupParams(alloc, "zero", 42);
    defer alloc.free(params);
    // empty write_set_hint — should route to partition 0
    const entry = try makeEntry(alloc, 1, &HASH_SETUP, &.{}, &.{}, params);
    defer alloc.free(entry.payload);

    const results = try setup.ps.runEntry(entry);
    defer alloc.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqual(@as(u32, 0), results[0].partition);
    try testing.expect(results[0].result == .ok);

    const row = try setup.storages[0].get(ACCOUNTS_TABLE, "zero", 1);
    try testing.expect(row != null);
    var r = row.?;
    defer r.deinit(alloc);
    try testing.expectEqual(@as(i64, 42), r.values[1].int64);
}

// --- Three-partition test ---

fn transfer3DeclareReads(ctx: QueryContext, local_partition: u32, out: *std.ArrayList(ForeignReadRequest)) !void {
    // Partition 2 (final receiver) needs to verify sender balance via partition 0
    if (local_partition != 2) return;
    const p = try decodeTransferParams(ctx.params);
    const key = try ctx.alloc.dupe(u8, p.sender_key);
    try out.append(ctx.alloc, .{ .from_partition = 0, .table_id = ACCOUNTS_TABLE, .key = key });
}

fn transfer3Execute(
    ctx: QueryContext,
    local_partition: u32,
    storage: *Storage,
    foreign: []const ForeignRow,
    mutations: *std.ArrayList(Mutation),
) !void {
    const p = try decodeTransferParams(ctx.params);
    if (local_partition == 0) {
        // Debit sender
        const row = try storage.get(ACCOUNTS_TABLE, p.sender_key, ctx.seq - 1) orelse return error.ConstraintViolation;
        var r = row;
        defer r.deinit(ctx.alloc);
        const balance = r.values[1].int64;
        if (balance < p.amount) return error.ConstraintViolation;
        const key_copy = try ctx.alloc.dupe(u8, p.sender_key);
        errdefer ctx.alloc.free(key_copy);
        const vals = try ctx.alloc.alloc(ColumnValue, 2);
        errdefer ctx.alloc.free(vals);
        vals[0] = .{ .string = try ctx.alloc.dupe(u8, p.sender_key) };
        vals[1] = .{ .int64 = balance - p.amount };
        try mutations.append(ctx.alloc, .{ .kind = .update, .table_id = ACCOUNTS_TABLE, .key = key_copy, .values = vals });
    } else if (local_partition == 1) {
        // Relay partition: no-op (just participates in the transaction)
    } else {
        // Partition 2: credit receiver, verifying via foreign rows
        var sender_balance: i64 = 0;
        var found = false;
        for (foreign) |fr| {
            if (fr.from_partition == 0 and std.mem.eql(u8, fr.key, p.sender_key)) {
                if (fr.row) |fr_row| {
                    sender_balance = fr_row.values[1].int64;
                    found = true;
                }
            }
        }
        if (!found or sender_balance < p.amount) return error.ConstraintViolation;
        const recv_row = try storage.get(ACCOUNTS_TABLE, p.receiver_key, ctx.seq - 1);
        var current: i64 = 0;
        if (recv_row) |rr| {
            var rrr = rr;
            defer rrr.deinit(ctx.alloc);
            current = rrr.values[1].int64;
        }
        const key_copy = try ctx.alloc.dupe(u8, p.receiver_key);
        errdefer ctx.alloc.free(key_copy);
        const vals = try ctx.alloc.alloc(ColumnValue, 2);
        errdefer ctx.alloc.free(vals);
        vals[0] = .{ .string = try ctx.alloc.dupe(u8, p.receiver_key) };
        vals[1] = .{ .int64 = current + p.amount };
        const kind: storage_mod.MutationKind = if (recv_row != null) .update else .insert;
        try mutations.append(ctx.alloc, .{ .kind = kind, .table_id = ACCOUNTS_TABLE, .key = key_copy, .values = vals });
    }
}

const HASH_TRANSFER3: [32]u8 = [_]u8{0x40} ++ [_]u8{0} ** 31;
const TRANSFER3_HANDLER = CrossPartitionQueryHandler{
    .declareReads = transfer3DeclareReads,
    .execute = transfer3Execute,
};

test "PartitionSet: three-partition transfer" {
    const alloc = std.testing.allocator;
    const dir0 = try makeTempDir(alloc, "xp3a");
    const dir1 = try makeTempDir(alloc, "xp3b");
    const dir2 = try makeTempDir(alloc, "xp3c");
    defer {
        removeDir(dir0);
        removeDir(dir1);
        removeDir(dir2);
        alloc.free(dir0);
        alloc.free(dir1);
        alloc.free(dir2);
    }

    const storages = try alloc.alloc(*Storage, 3);
    for (&[_][]const u8{ dir0, dir1, dir2 }, 0..) |dir, i| {
        storages[i] = try alloc.create(Storage);
        storages[i].* = try Storage.init(dir, alloc);
        try storages[i].registerTable(accountsSchema());
    }
    var ps = try PartitionSet.init(storages, alloc);
    defer teardownPartitionSet(&ps, storages, null, alloc);
    try ps.registerAll(HASH_SETUP, handlerSetup);
    try ps.registerCrossAll(HASH_TRANSFER3, TRANSFER3_HANDLER);

    // Insert sender on p0 (balance=100)
    const pa = try encodeSetupParams(alloc, "alice", 100);
    defer alloc.free(pa);
    const e1 = try makeEntry(alloc, 1, &HASH_SETUP, &.{0}, &.{0}, pa);
    defer alloc.free(e1.payload);
    const r1 = try ps.runEntry(e1);
    defer alloc.free(r1);
    try testing.expect(r1[0].result == .ok);

    // Insert receiver on p2 (balance=0)
    const pb = try encodeSetupParams(alloc, "carol", 0);
    defer alloc.free(pb);
    const e2 = try makeEntry(alloc, 2, &HASH_SETUP, &.{2}, &.{2}, pb);
    defer alloc.free(e2.payload);
    const r2 = try ps.runEntry(e2);
    defer alloc.free(r2);
    try testing.expect(r2[0].result == .ok);

    // Cross-partition transfer: p0 debits, p1 relays, p2 credits
    const tp = try encodeTransferParams(alloc, "alice", "carol", 40);
    defer alloc.free(tp);
    const e3 = try makeEntry(alloc, 3, &HASH_TRANSFER3, &.{0}, &.{ 0, 1, 2 }, tp);
    defer alloc.free(e3.payload);
    const r3 = try ps.runEntry(e3);
    defer alloc.free(r3);

    try testing.expectEqual(@as(usize, 3), r3.len);
    for (r3) |r| try testing.expect(r.result == .ok);

    const alice = try storages[0].get(ACCOUNTS_TABLE, "alice", 3);
    try testing.expect(alice != null);
    var a = alice.?;
    defer a.deinit(alloc);
    try testing.expectEqual(@as(i64, 60), a.values[1].int64);

    const carol = try storages[2].get(ACCOUNTS_TABLE, "carol", 3);
    try testing.expect(carol != null);
    var c = carol.?;
    defer c.deinit(alloc);
    try testing.expectEqual(@as(i64, 40), c.values[1].int64);

    try testing.expectEqual(@as(u64, 3), ps.executors[0].committed_seq);
    try testing.expectEqual(@as(u64, 3), ps.executors[1].committed_seq);
    try testing.expectEqual(@as(u64, 3), ps.executors[2].committed_seq);
}
