/// Tests for ExecutorDriver: drainAll and drainOnce behavior.
const std = @import("std");
const testing = std.testing;
const executor_mod = @import("executor.zig");
const storage_mod = @import("storage.zig");
const log_mod = @import("log.zig");

const Executor = executor_mod.Executor;
const ExecutorDriver = executor_mod.ExecutorDriver;
const Storage = executor_mod.Storage;
const LogEntry = executor_mod.LogEntry;
const EntryKind = executor_mod.EntryKind;
const Mutation = executor_mod.Mutation;
const QueryContext = executor_mod.QueryContext;
const serializeTxnIntent = executor_mod.serializeTxnIntent;
const ResolvedValue = executor_mod.ResolvedValue;
const Log = log_mod.Log;

const TableSchema = storage_mod.TableSchema;
const ColumnSchema = storage_mod.ColumnSchema;
const ColumnValue = storage_mod.ColumnValue;

fn makeSchema() TableSchema {
    return .{
        .table_id = 1,
        .columns = &.{
            .{ .col_type = .string, .nullable = false },
            .{ .col_type = .int64, .nullable = false },
        },
    };
}

fn makeTempDir(alloc: std.mem.Allocator, suffix: []const u8) ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const path = try std.fmt.allocPrint(alloc, "/tmp/driver_test_{s}_{d}", .{ suffix, ns });
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

const HASH_INSERT: [32]u8 = [_]u8{1} ++ [_]u8{0} ** 31;

fn handlerInsert(ctx: QueryContext, _: *Storage, mutations: *std.ArrayList(Mutation)) !void {
    if (ctx.params.len < 2) return error.BadParams;
    const key_len = std.mem.readInt(u16, ctx.params[0..2], .little);
    if (ctx.params.len < 2 + key_len + 8) return error.BadParams;
    const key = ctx.params[2 .. 2 + key_len];
    const value = std.mem.readInt(i64, ctx.params[2 + key_len ..][0..8], .little);
    const key_copy = try ctx.alloc.dupe(u8, key);
    errdefer ctx.alloc.free(key_copy);
    const vals = try ctx.alloc.alloc(ColumnValue, 2);
    errdefer ctx.alloc.free(vals);
    vals[0] = .{ .string = try ctx.alloc.dupe(u8, key) };
    vals[1] = .{ .int64 = value };
    try mutations.append(ctx.alloc, .{ .kind = .insert, .table_id = 1, .key = key_copy, .values = vals });
}

fn makeEntry(alloc: std.mem.Allocator, seq: u64, key: []const u8, value: i64) !LogEntry {
    var params = try alloc.alloc(u8, 2 + key.len + 8);
    defer alloc.free(params);
    std.mem.writeInt(u16, params[0..2], @intCast(key.len), .little);
    @memcpy(params[2 .. 2 + key.len], key);
    std.mem.writeInt(i64, params[2 + key.len ..][0..8], value, .little);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    try serializeTxnIntent(&HASH_INSERT, 0, seq, &.{}, &.{}, params, &.{}, &payload, alloc);
    const payload_copy = try alloc.dupe(u8, payload.items);
    return LogEntry.create(seq, 1, .txn_intent, payload_copy);
}

test "driver: drainAll processes all committed entries" {
    const alloc = testing.allocator;
    const storage_dir = try makeTempDir(alloc, "drain");
    defer alloc.free(storage_dir);
    defer removeDir(storage_dir);

    const log_dir = try makeTempDir(alloc, "log");
    defer alloc.free(log_dir);
    defer removeDir(log_dir);

    var log = try Log.init(log_dir, 1);
    defer log.deinit();

    const storage = try alloc.create(Storage);
    storage.* = try Storage.init(storage_dir, alloc);
    defer {
        storage.deinit();
        alloc.destroy(storage);
    }
    try storage.registerTable(makeSchema());

    var exec = Executor.init(storage, alloc);
    defer exec.deinit();
    try exec.register(HASH_INSERT, handlerInsert);

    // Append 10 entries to log
    for (1..11) |i| {
        var buf: [8]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch unreachable;
        var e = try makeEntry(alloc, @intCast(i), key, @intCast(i * 10));
        defer e.deinit(alloc);
        try log.appendEntryAt(e);
    }

    var driver = ExecutorDriver{
        .log = &log,
        .executor = &exec,
        .alloc = alloc,
    };
    try driver.drainAll();

    try testing.expectEqual(@as(u64, 10), exec.committed_seq);
}

test "driver: drainOnce is idempotent at head" {
    const alloc = testing.allocator;
    const storage_dir = try makeTempDir(alloc, "idem");
    defer alloc.free(storage_dir);
    defer removeDir(storage_dir);

    const log_dir = try makeTempDir(alloc, "ilog");
    defer alloc.free(log_dir);
    defer removeDir(log_dir);

    var log = try Log.init(log_dir, 1);
    defer log.deinit();

    const storage = try alloc.create(Storage);
    storage.* = try Storage.init(storage_dir, alloc);
    defer {
        storage.deinit();
        alloc.destroy(storage);
    }
    try storage.registerTable(makeSchema());

    var exec = Executor.init(storage, alloc);
    defer exec.deinit();
    try exec.register(HASH_INSERT, handlerInsert);

    var e = try makeEntry(alloc, 1, "only", 42);
    defer e.deinit(alloc);
    try log.appendEntryAt(e);

    var driver = ExecutorDriver{
        .log = &log,
        .executor = &exec,
        .alloc = alloc,
    };

    const n1 = try driver.drainOnce();
    try testing.expectEqual(@as(usize, 1), n1);
    try testing.expectEqual(@as(u64, 1), exec.committed_seq);

    // Second drainOnce at head returns 0
    const n2 = try driver.drainOnce();
    try testing.expectEqual(@as(usize, 0), n2);
    try testing.expectEqual(@as(u64, 1), exec.committed_seq);
}
