const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");
const storage_mod = @import("storage.zig");

const Gateway = gateway_mod.Gateway;
const ColumnValue = gateway_mod.ColumnValue;

fn makeTempDir() ![]const u8 {
    // SAFETY: clock_gettime fills ts before any field is read.
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/gw_snap_{d}", .{ns});
}

fn removeDirRecursive(path: []const u8) void {
    const alloc = std.heap.page_allocator;
    const z = alloc.allocSentinel(u8, path.len, 0) catch return;
    defer alloc.free(z);
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
                const child = std.mem.concat(alloc, u8, &.{ path, "/", name }) catch {
                    i += dent.reclen;
                    continue;
                };
                defer alloc.free(child);
                const cz = alloc.allocSentinel(u8, child.len, 0) catch {
                    i += dent.reclen;
                    continue;
                };
                defer alloc.free(cz);
                @memcpy(cz[0..child.len], child);
                const DT_DIR: u8 = 4;
                if (dent.type == DT_DIR) removeDirRecursive(child) else _ = std.os.linux.unlink(cz.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}

test "snapshot_marker is written to partition log after interval" {
    const alloc = testing.allocator;
    const dir = try makeTempDir();
    defer alloc.free(dir);
    defer removeDirRecursive(dir);

    var obj_store = storage_mod.MemoryObjectStore.init(alloc);
    defer obj_store.deinit();

    const gw = try Gateway.init(dir, alloc, .{
        .snapshot_interval_entries = 3,
        .snapshot_store = obj_store.objectStore(),
    });
    defer gw.deinit();

    // Register a table.
    try gw.applyDdl("CREATE TABLE items (id STRING NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))");

    const insert_hash = blk: {
        const res = try gw.register("INSERT INTO items (id, val) VALUES ($1, $2)");
        break :blk res.hash;
    };

    // Insert 4 rows — snapshot fires after the 3rd mutation.
    for (0..4) |i| {
        const id_str = try std.fmt.allocPrint(alloc, "row{d}", .{i});
        defer alloc.free(id_str);
        const params = [_]ColumnValue{
            .{ .string = id_str },
            .{ .int64 = @intCast(i) },
        };
        _ = try gw.execute(insert_hash, &params, &.{});
    }

    // Scan partition log 0 for a snapshot_marker entry.
    const entries = try gw.sequencer.partition_logs[0].read(1, 200, alloc);
    defer {
        for (entries) |e| alloc.free(e.payload);
        alloc.free(entries);
    }

    var found_marker = false;
    for (entries) |e| {
        if (e.header.kind == .snapshot_marker) {
            found_marker = true;
            // Verify the payload deserializes cleanly.
            var marker = try storage_mod.SnapshotMarkerPayload.deserialize(e.payload, alloc);
            defer marker.deinit(alloc);
            try testing.expect(marker.manifest_key.len > 0);
            try testing.expectEqual(@as(u32, 0), marker.partition_id);
            break;
        }
    }
    try testing.expect(found_marker);
}

test "durable_snapshot_seq advances after snapshot fires" {
    const alloc = testing.allocator;
    const dir = try makeTempDir();
    defer alloc.free(dir);
    defer removeDirRecursive(dir);

    var obj_store = storage_mod.MemoryObjectStore.init(alloc);
    defer obj_store.deinit();

    const gw = try Gateway.init(dir, alloc, .{
        .snapshot_interval_entries = 3,
        .snapshot_store = obj_store.objectStore(),
    });
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE items (id STRING NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))");

    const insert_hash = blk: {
        const res = try gw.register("INSERT INTO items (id, val) VALUES ($1, $2)");
        break :blk res.hash;
    };

    // Before any inserts, no snapshot has fired.
    try testing.expectEqual(@as(u64, 0), gw.durable_snapshot_seq);

    // Insert enough rows to trigger the snapshot (interval = 3).
    for (0..4) |i| {
        const id_str = try std.fmt.allocPrint(alloc, "row{d}", .{i});
        defer alloc.free(id_str);
        const params = [_]ColumnValue{
            .{ .string = id_str },
            .{ .int64 = @intCast(i) },
        };
        _ = try gw.execute(insert_hash, &params, &.{});
    }

    // Hook must have advanced durable_snapshot_seq.
    try testing.expect(gw.durable_snapshot_seq > 0);

    // truncateLog must be idempotent when called again (no sealed segments to remove).
    try gw.truncateLog();
}

test "no snapshot_marker when snapshot_store is not configured" {
    const alloc = testing.allocator;
    const dir = try makeTempDir();
    defer alloc.free(dir);
    defer removeDirRecursive(dir);

    const gw = try Gateway.init(dir, alloc, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE items (id STRING NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))");
    const hash = blk: {
        const res = try gw.register("INSERT INTO items (id, val) VALUES ($1, $2)");
        break :blk res.hash;
    };
    for (0..5) |i| {
        const id_str = try std.fmt.allocPrint(alloc, "row{d}", .{i});
        defer alloc.free(id_str);
        const params = [_]ColumnValue{ .{ .string = id_str }, .{ .int64 = @intCast(i) } };
        _ = try gw.execute(hash, &params, &.{});
    }

    const entries = try gw.sequencer.partition_logs[0].read(1, 200, alloc);
    defer {
        for (entries) |e| alloc.free(e.payload);
        alloc.free(entries);
    }

    for (entries) |e| {
        try testing.expect(e.header.kind != .snapshot_marker);
    }
}
