/// DST for OCC read-write conflict detection.
///
/// Tests two properties:
///
/// 1. Determinism: two independent executor instances driven through identical
///    entry sequences (including stale-recon entries) produce bit-identical
///    ExecResults at every step.
///
/// 2. Fidelity: entries whose recon_seq predates a key write correctly return
///    .abort{.retry}; entries whose recon_seq is current correctly return .ok.
const std = @import("std");
const testing = std.testing;
const sim = @import("sim.zig");
const executor_mod = @import("executor.zig");
const storage_mod = @import("storage.zig");
const log_mod = @import("log.zig");

const Executor = executor_mod.Executor;
const ExecResult = executor_mod.ExecResult;
const AbortCode = executor_mod.AbortCode;
const QueryContext = executor_mod.QueryContext;
const Mutation = executor_mod.Mutation;
const Storage = executor_mod.Storage;
const LogEntry = executor_mod.LogEntry;
const Seq = executor_mod.Seq;
const serializeTxnIntent = executor_mod.serializeTxnIntent;
const ColumnValue = storage_mod.ColumnValue;

// ---- Temp dir helpers ----

fn makeTempDir(tag: []const u8, id: u64, alloc: std.mem.Allocator) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "/tmp/occ_dst_{s}_{d}", .{ tag, id });
    removeDirRecursive(path);
    const zpath = try alloc.allocSentinel(u8, path.len, 0);
    defer alloc.free(zpath);
    @memcpy(zpath[0..path.len], path);
    _ = std.os.linux.mkdir(zpath.ptr, 0o755);
    return path;
}

fn removeDirRecursive(path: []const u8) void {
    const z = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(z);
    @memcpy(z[0..path.len], path);
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
                if (dent.type == std.os.linux.DT.DIR) removeDirRecursive(child) else _ = std.os.linux.unlink(cz.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}

// ---- Schema ----

const TABLE_ID: u32 = 1;

fn makeSchema() storage_mod.TableSchema {
    return .{
        .table_id = TABLE_ID,
        .columns = &.{
            .{ .col_type = .string, .nullable = false },
            .{ .col_type = .int64, .nullable = false },
        },
    };
}

// ---- Query hashes ----

const HASH_INSERT: [32]u8 = [_]u8{0x10} ++ [_]u8{0} ** 31;
const HASH_UPDATE: [32]u8 = [_]u8{0x11} ++ [_]u8{0} ** 31;

// ---- Handlers ----
//
// Param layout: key_len(2) + key(key_len) + value(8, i64 little-endian)

fn decodeKeyValue(params: []const u8) !struct { key: []const u8, value: i64 } {
    if (params.len < 2) return error.BadParams;
    const kl = std.mem.readInt(u16, params[0..2], .little);
    if (params.len < 2 + kl + 8) return error.BadParams;
    const value = std.mem.readInt(i64, params[2 + kl ..][0..8], .little);
    return .{ .key = params[2 .. 2 + kl], .value = value };
}

fn handlerInsert(ctx: QueryContext, _: *Storage, mutations: *std.ArrayList(Mutation)) !void {
    const kv = try decodeKeyValue(ctx.params);
    const key_copy = try ctx.alloc.dupe(u8, kv.key);
    errdefer ctx.alloc.free(key_copy);
    const vals = try ctx.alloc.alloc(ColumnValue, 2);
    errdefer ctx.alloc.free(vals);
    vals[0] = .{ .string = try ctx.alloc.dupe(u8, kv.key) };
    vals[1] = .{ .int64 = kv.value };
    try mutations.append(ctx.alloc, .{ .kind = .insert, .table_id = TABLE_ID, .key = key_copy, .values = vals });
}

fn handlerUpdate(ctx: QueryContext, storage: *Storage, mutations: *std.ArrayList(Mutation)) !void {
    const kv = try decodeKeyValue(ctx.params);
    const row = try storage.get(TABLE_ID, kv.key, ctx.seq - 1);
    if (row == null) return; // row doesn't exist; produce no mutations (silently skip)
    var r = row.?;
    defer r.deinit(ctx.alloc);
    const key_copy = try ctx.alloc.dupe(u8, kv.key);
    errdefer ctx.alloc.free(key_copy);
    const vals = try ctx.alloc.alloc(ColumnValue, 2);
    errdefer ctx.alloc.free(vals);
    vals[0] = .{ .string = try ctx.alloc.dupe(u8, kv.key) };
    vals[1] = .{ .int64 = r.values[1].int64 + kv.value };
    try mutations.append(ctx.alloc, .{ .kind = .update, .table_id = TABLE_ID, .key = key_copy, .values = vals });
}

// ---- Entry construction ----

fn encodeParams(alloc: std.mem.Allocator, key: []const u8, value: i64) ![]u8 {
    const buf = try alloc.alloc(u8, 2 + key.len + 8);
    std.mem.writeInt(u16, buf[0..2], @intCast(key.len), .little);
    @memcpy(buf[2 .. 2 + key.len], key);
    std.mem.writeInt(i64, buf[2 + key.len ..][0..8], value, .little);
    return buf;
}

fn makeEntry(
    alloc: std.mem.Allocator,
    seq: Seq,
    recon_seq: Seq,
    hash: *const [32]u8,
    key: []const u8,
    value: i64,
) !LogEntry {
    const params = try encodeParams(alloc, key, value);
    defer alloc.free(params);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    try serializeTxnIntent(hash, 0, seq, recon_seq, &.{}, &.{}, params, &.{}, &payload, alloc);
    const payload_copy = try alloc.dupe(u8, payload.items);
    return LogEntry.create(seq, 1, .txn_intent, payload_copy);
}

// ---- Executor setup/teardown ----

const ExecPair = struct {
    storage: *Storage,
    exec: Executor,
};

fn setupExec(tag: []const u8, seed: u64, alloc: std.mem.Allocator) !ExecPair {
    const dir = try makeTempDir(tag, seed, alloc);
    defer alloc.free(dir);
    const storage = try alloc.create(Storage);
    storage.* = try Storage.init(dir, alloc);
    try storage.registerTable(makeSchema());
    var exec = Executor.init(storage, alloc);
    try exec.register(HASH_INSERT, handlerInsert);
    try exec.register(HASH_UPDATE, handlerUpdate);
    return .{ .storage = storage, .exec = exec };
}

fn teardownExec(pair: *ExecPair, alloc: std.mem.Allocator) void {
    pair.exec.deinit();
    pair.storage.deinit();
    alloc.destroy(pair.storage);
}

// ---- Comparison helpers ----

fn resultsEqual(a: ExecResult, b: ExecResult) bool {
    const tag_a = std.meta.activeTag(a);
    const tag_b = std.meta.activeTag(b);
    if (tag_a != tag_b) return false;
    return switch (a) {
        .ok => |ok_a| ok_a.rows_affected == b.ok.rows_affected,
        .abort => |ab_a| ab_a.code == b.abort.code,
    };
}

// ---- Core DST logic ----

fn runOccDst(seed: u64, alloc: std.mem.Allocator) !void {
    var pair_a = try setupExec("a", seed, alloc);
    defer teardownExec(&pair_a, alloc);
    var pair_b = try setupExec("b", seed, alloc);
    defer teardownExec(&pair_b, alloc);

    var sched = sim.SimScheduler.init(seed);

    // Phase 1: insert rows with no OCC checking (recon_seq=0).
    // Generate N_ROWS distinct keys and insert them.
    const N_ROWS = 8;
    var keys: [N_ROWS][8]u8 = undefined;
    for (&keys, 0..) |*k, i| {
        var raw: [8]u8 = undefined;
        sched.random().bytes(&raw);
        _ = std.fmt.bufPrint(k, "key{d:0>4}", .{i}) catch unreachable;
    }

    var seq: Seq = 1;
    for (keys) |key| {
        const value: i64 = @intCast(sched.random().uintLessThan(u64, 1000));
        var e = try makeEntry(alloc, seq, 0, &HASH_INSERT, &key, value);
        defer e.deinit(alloc);
        const ra = try pair_a.exec.run(e);
        const rb = try pair_b.exec.run(e);
        try testing.expect(resultsEqual(ra, rb));
        try testing.expectEqual(ExecResult{ .ok = .{ .rows_affected = 1 } }, ra);
        seq += 1;
    }

    // Phase 2: update rows with CURRENT recon_seq — no conflict expected.
    // recon_seq = seq - 1 means the recon captured the last write.
    for (keys) |key| {
        const delta: i64 = @intCast(sched.random().uintLessThan(u64, 100));
        const recon_seq = seq - 1; // current — all prior writes are visible
        var e = try makeEntry(alloc, seq, recon_seq, &HASH_UPDATE, &key, delta);
        defer e.deinit(alloc);
        const ra = try pair_a.exec.run(e);
        const rb = try pair_b.exec.run(e);
        try testing.expect(resultsEqual(ra, rb));
        // With a current recon_seq the read (row.seq <= recon_seq) — no conflict.
        try testing.expectEqual(@as(ExecResult, .{ .ok = .{ .rows_affected = 1 } }), ra);
        seq += 1;
    }

    // Phase 3: update rows with a STALE recon_seq that predates the last write.
    // The row was last written during phase 2. The stale recon points before phase 2,
    // so row.seq > recon_seq → executor returns .retry.
    const stale_recon: Seq = N_ROWS; // recon done just before phase 2 started
    for (keys) |key| {
        const delta: i64 = @intCast(sched.random().uintLessThan(u64, 50));
        var e = try makeEntry(alloc, seq, stale_recon, &HASH_UPDATE, &key, delta);
        defer e.deinit(alloc);
        const ra = try pair_a.exec.run(e);
        const rb = try pair_b.exec.run(e);
        // Both executors must agree — determinism invariant.
        try testing.expect(resultsEqual(ra, rb));
        // Stale recon: row was updated in phase 2 at seq N_ROWS+i > stale_recon=N_ROWS.
        try testing.expectEqual(AbortCode.retry, ra.abort.code);
        seq += 1;
    }

    // Phase 4: retry the updates from phase 3 with a fresh recon_seq.
    // After resetting recon_seq to cover all phase-2 writes, no conflict.
    for (keys) |key| {
        const delta: i64 = @intCast(sched.random().uintLessThan(u64, 50));
        const fresh_recon: Seq = seq - 1;
        var e = try makeEntry(alloc, seq, fresh_recon, &HASH_UPDATE, &key, delta);
        defer e.deinit(alloc);
        const ra = try pair_a.exec.run(e);
        const rb = try pair_b.exec.run(e);
        try testing.expect(resultsEqual(ra, rb));
        try testing.expectEqual(@as(ExecResult, .{ .ok = .{ .rows_affected = 1 } }), ra);
        seq += 1;
    }
}

test "OCC DST: determinism under stale recon_seq — seed 0x01" {
    try runOccDst(0x01, testing.allocator);
}

test "OCC DST: determinism under stale recon_seq — seed 0x02" {
    try runOccDst(0x02, testing.allocator);
}

test "OCC DST: determinism under stale recon_seq — seed 0xDEAD" {
    try runOccDst(0xDEAD, testing.allocator);
}

test "OCC DST: determinism under stale recon_seq — seed 0xCAFE" {
    try runOccDst(0xCAFE, testing.allocator);
}

test "OCC DST: determinism under stale recon_seq — seed 0xF00D" {
    try runOccDst(0xF00D, testing.allocator);
}
