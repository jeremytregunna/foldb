/// Recovery property test.
///
/// Verifies two recovery scenarios:
///
/// 1. Clean shutdown: commit N transactions, flush + deinit, restart — all
///    committed data must be present.
///
/// 2. Crash (no flush): commit N transactions, abandon without deinit —
///    schema must be intact on restart; data that was explicitly flushed to
///    SSTables before the "crash" must survive; memtable data is acknowledged
///    as lost (full log replay is a future milestone).
const std = @import("std");
const testing = std.testing;
const sim = @import("sim.zig");
const gateway_mod = @import("gateway.zig");
const wl = sim.workload;

const Gateway = gateway_mod.Gateway;
const ColumnValue = gateway_mod.ColumnValue;

// ---- Temp dir helpers (shared with determinism_test pattern) ----

fn makeTempDir(tag: []const u8, id: u64, alloc: std.mem.Allocator) ![]u8 {
    const path = try std.fmt.allocPrint(alloc, "/tmp/sim_rec_{s}_{d}", .{ tag, id });
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
                const child = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ path, name }) catch {
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

// ---- Helpers ----

fn runWorkload(
    gw: *Gateway,
    insert_hash: [32]u8,
    update_hash: [32]u8,
    delete_hash: [32]u8,
    ops: []const wl.Op,
) void {
    for (ops) |op| {
        switch (op.kind) {
            .insert => {
                const params = [_]ColumnValue{ .{ .int64 = op.id }, .{ .int64 = op.value } };
                _ = gw.execute(std.testing.io, insert_hash, &params, &.{}) catch {};
            },
            .update => {
                const params = [_]ColumnValue{ .{ .int64 = op.id }, .{ .int64 = op.value } };
                _ = gw.execute(std.testing.io, update_hash, &params, &.{}) catch {};
            },
            .delete => {
                const params = [_]ColumnValue{.{ .int64 = op.id }};
                _ = gw.execute(std.testing.io, delete_hash, &params, &.{}) catch {};
            },
            .select => {},
        }
    }
}

fn scanRows(gw: *Gateway, scan_hash: [32]u8, alloc: std.mem.Allocator) ![]i64 {
    var rs = try gw.querySelect(scan_hash, &.{}, &.{});
    defer rs.deinit();
    const ids = try alloc.alloc(i64, rs.rows.len);
    for (rs.rows, 0..) |row, i| {
        ids[i] = if (row.len > 0) blk: {
            break :blk if (row[0]) |cell| switch (cell) {
                .int64 => |v| v,
                else => -1,
            } else -1;
        } else -1;
    }
    std.mem.sort(i64, ids, {}, std.sort.asc(i64));
    return ids;
}

// ---- Test 1: clean shutdown recovery ----

test "sim: recovery — all committed data survives clean shutdown" {
    const alloc = testing.allocator;
    const id: u64 = 1001;

    const dir = try makeTempDir("clean", id, alloc);
    defer { removeDirRecursive(dir); alloc.free(dir); }

    var sched = sim.SimScheduler.init(0xFEED_FACE);
    var workload = try wl.generate(&sched, 80, alloc);
    defer workload.deinit();

    var pre_scan_ids: []i64 = &.{};
    defer alloc.free(pre_scan_ids);

    // Phase 1: run workload and record final state before shutdown.
    {
        const gw = try Gateway.init(dir, alloc, .{});
        try gw.applyDdl(wl.TABLE_DDL);
        const ins = (try gw.register(wl.INSERT_SQL)).hash;
        const upd = (try gw.register(wl.UPDATE_SQL)).hash;
        const del = (try gw.register(wl.DELETE_SQL)).hash;
        const scan = (try gw.register(wl.SCAN_SQL)).hash;
        runWorkload(gw, ins, upd, del, workload.ops);
        pre_scan_ids = try scanRows(gw, scan, alloc);
        gw.deinit(); // clean shutdown — flushes memtable to SSTables
    }

    // Phase 2: restart on same dir and verify state is identical.
    {
        const gw = try Gateway.init(dir, alloc, .{});
        defer gw.deinit();
        const scan = (try gw.register(wl.SCAN_SQL)).hash;
        const post_scan_ids = try scanRows(gw, scan, alloc);
        defer alloc.free(post_scan_ids);
        try testing.expectEqualSlices(i64, pre_scan_ids, post_scan_ids);
    }
}

// ---- Test 2: crash recovery ----
//
// Simulate a crash by explicitly flushing a "durable" batch, then committing
// more rows WITHOUT flushing, then abandoning the gateway. On restart:
//   - Schema must be intact (rebuilt from log).
//   - Durable rows (flushed to SSTs) must be present.
//   - Unflushed rows may be absent — this is expected until full log replay lands.

test "sim: recovery — schema and flushed data survive crash" {
    const alloc = testing.allocator;
    const id: u64 = 1002;

    const dir = try makeTempDir("crash", id, alloc);
    defer { removeDirRecursive(dir); alloc.free(dir); }

    // Insert rows 1..10, flush (durable batch), then insert rows 11..20 without flush.
    // Use page_allocator for the crash phase — intentional leak, no deinit.
    {
        const gw = try Gateway.init(dir, std.heap.page_allocator, .{});
        try gw.applyDdl(wl.TABLE_DDL);
        const ins = (try gw.register(wl.INSERT_SQL)).hash;

        var i: i64 = 1;
        while (i <= 10) : (i += 1) {
            const params = [_]ColumnValue{ .{ .int64 = i }, .{ .int64 = i * 100 } };
            _ = try gw.execute(std.testing.io, ins, &params, &.{});
        }
        // Flush to SSTables — this batch is durable.
        try gw.flushAll();

        // Unflushed batch — lost on crash.
        while (i <= 20) : (i += 1) {
            const params = [_]ColumnValue{ .{ .int64 = i }, .{ .int64 = i * 100 } };
            _ = gw.execute(std.testing.io, ins, &params, &.{}) catch {};
        }

        // Simulate crash: abandon gateway without deinit.
    }

    // Restart on same dir.
    {
        const gw = try Gateway.init(dir, alloc, .{});
        defer gw.deinit();

        // Schema must have survived (rebuilt from log).
        const scan = (try gw.register(wl.SCAN_SQL)).hash;
        const ids = try scanRows(gw, scan, alloc);
        defer alloc.free(ids);

        // All 20 rows must be present — flushed rows from SSTables, unflushed rows
        // recovered via DML replay from the partition log.
        try testing.expectEqual(@as(usize, 20), ids.len);
        for (ids, 0..) |row_id, i| {
            try testing.expectEqual(@as(i64, @intCast(i + 1)), row_id);
        }
    }
}
