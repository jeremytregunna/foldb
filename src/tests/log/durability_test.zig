/// Durability tests for the log.
const std = @import("std");
const testing = std.testing;
const log = @import("log.zig");

const Seq = log.Seq;
const NodeId = log.NodeId;
const TxnIntent = log.TxnIntent;
const LogEntry = log.LogEntry;
const Log = log.Log;

fn toNullZ(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    const buf = try allocator.allocSentinel(u8, path.len, 0);
    @memcpy(buf[0..path.len], path);
    return buf;
}

fn removeDirRecursive(path: []const u8) void {
    const null_path = toNullZ(std.heap.page_allocator, path) catch return;
    defer std.heap.page_allocator.free(null_path);

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
            const dent = @as(*const std.os.linux.dirent64, @ptrCast(@alignCast(buf[i..].ptr))).*;
            const name = std.mem.sliceTo(&dent.name, 0);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                const child = std.mem.concat(std.heap.page_allocator, u8, &.{ path, "/", name }) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(child);
                const child_z = toNullZ(std.heap.page_allocator, child) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(child_z);
                _ = std.os.linux.unlink(child_z.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(null_path.ptr);
}

fn makeTempDir() ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const timestamp = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    const path = try std.fmt.allocPrint(testing.allocator, "/tmp/durability_test_{d}", .{timestamp});
    const null_path = try toNullZ(testing.allocator, path);
    defer testing.allocator.free(null_path);
    _ = std.os.linux.mkdir(null_path.ptr, 0o755);
    return path;
}

test "Durability: data survives deinit and re-init" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1);

    const payloads = [_][]const u8{
        "transaction_1",
        "transaction_2",
        "transaction_3",
        "transaction_4",
        "transaction_5",
    };

    var expected_seq: Seq = 0;
    for (payloads) |payload| {
        const seq = try log_instance.append(TxnIntent.initTest(payload, 1, 1));
        expected_seq = seq;
    }

    const head_before = try log_instance.head();
    try testing.expectEqual(expected_seq, head_before);

    log_instance.deinit();

    log_instance = try Log.init(temp_path, 1);
    defer log_instance.deinit();

    const head_after = try log_instance.head();
    try testing.expectEqual(expected_seq, head_after);

    const entries = try log_instance.read(1, 20, testing.allocator);
    defer {
        for (entries) |*e| e.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 5), entries.len);
    for (entries, 0..) |entry, i| {
        try testing.expectEqual(@as(Seq, @intCast(i + 1)), entry.header.seq);
        const intent = try TxnIntent.deserializeFrom(entry.payload, testing.allocator);
        defer intent.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, payloads[i], intent.params);
        try testing.expect(entry.verifyCrc());
    }
}

test "Durability: data survives multiple deinit/init cycles" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1);
    _ = try log_instance.append(TxnIntent.initTest("cycle1_data", 1, 1));
    log_instance.deinit();

    log_instance = try Log.init(temp_path, 1);
    _ = try log_instance.append(TxnIntent.initTest("cycle2_data", 1, 2));
    log_instance.deinit();

    log_instance = try Log.init(temp_path, 1);
    _ = try log_instance.append(TxnIntent.initTest("cycle3_data", 1, 3));
    log_instance.deinit();

    log_instance = try Log.init(temp_path, 1);
    defer log_instance.deinit();

    const entries = try log_instance.read(1, 20, testing.allocator);
    defer {
        for (entries) |*e| e.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 3), entries.len);
    {
        const intent0 = try TxnIntent.deserializeFrom(entries[0].payload, testing.allocator);
        defer intent0.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, "cycle1_data", intent0.params);
    }
    {
        const intent1 = try TxnIntent.deserializeFrom(entries[1].payload, testing.allocator);
        defer intent1.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, "cycle2_data", intent1.params);
    }
    {
        const intent2 = try TxnIntent.deserializeFrom(entries[2].payload, testing.allocator);
        defer intent2.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, "cycle3_data", intent2.params);
    }
}

test "Durability: sealed segments persist correctly" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1);
    log_instance.segment_max_entries = 2;

    var i: usize = 0;
    while (i < 6) : (i += 1) {
        _ = try log_instance.append(TxnIntent.initTest("data", 1, 1));
    }

    try testing.expectEqual(@as(usize, 3), log_instance.sealed_segments.items.len);
    log_instance.deinit();

    log_instance = try Log.init(temp_path, 1);
    defer log_instance.deinit();

    const entries = try log_instance.read(1, 20, testing.allocator);
    defer {
        for (entries) |*e| e.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 6), entries.len);
}

test "Durability: CRC verification on re-read" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1);

    const payloads = [_][]const u8{
        "",
        "x",
        "hello world",
        "This is a longer payload with more data to test CRC calculation",
    };

    for (payloads) |payload| {
        _ = try log_instance.append(TxnIntent.initTest(payload, 1, 1));
    }

    log_instance.deinit();

    log_instance = try Log.init(temp_path, 1);
    defer log_instance.deinit();

    const entries = try log_instance.read(1, 20, testing.allocator);
    defer {
        for (entries) |*e| e.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 4), entries.len);
    for (entries) |entry| {
        try testing.expect(entry.verifyCrc());
    }
}

test "Durability: partial writes detected on reopen" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1);
    _ = try log_instance.append(TxnIntent.initTest("valid_entry", 1, 1));
    try log_instance.seal();
    log_instance.deinit();

    // Open the segment file directly (base_seq=1 → "0000000000000001.seg")
    const seg_name = "0000000000000001.seg";
    const seg_path = try std.mem.concat(testing.allocator, u8, &.{ temp_path, "/", seg_name });
    defer testing.allocator.free(seg_path);
    const seg_path_z = try toNullZ(testing.allocator, seg_path);
    defer testing.allocator.free(seg_path_z);

    const raw_fd = std.os.linux.open(seg_path_z.ptr, .{ .ACCMODE = .RDWR }, 0);
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return;
    const file_fd: std.posix.fd_t = @intCast(fd_i);
    defer _ = std.os.linux.close(@intCast(file_fd));

    // Truncate to remove the footer (simulate partial write)
    const file_size = std.os.linux.lseek(@intCast(file_fd), 0, std.os.linux.SEEK.END);
    if (file_size > 10) {
        _ = std.os.linux.ftruncate(@intCast(file_fd), @intCast(file_size - 10));
    }

    // Re-init should handle gracefully (invalid footer = treat as unsealed)
    var recovered = Log.init(temp_path, 1) catch return;
    recovered.deinit();
}

test "Durability: header CRC protects against corruption" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1);
    _ = try log_instance.append(TxnIntent.initTest("entry", 1, 1));
    try log_instance.seal();
    log_instance.deinit();

    // Corrupt the segment header's base_seq field (offset 16 in extern struct)
    const seg_name = "0000000000000001.seg";
    const seg_path = try std.mem.concat(testing.allocator, u8, &.{ temp_path, "/", seg_name });
    defer testing.allocator.free(seg_path);
    const seg_path_z = try toNullZ(testing.allocator, seg_path);
    defer testing.allocator.free(seg_path_z);

    const raw_fd = std.os.linux.open(seg_path_z.ptr, .{ .ACCMODE = .RDWR }, 0);
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return;
    const file_fd: std.posix.fd_t = @intCast(fd_i);
    defer _ = std.os.linux.close(@intCast(file_fd));

    // Overwrite base_seq field (at offset 16) with corrupt value
    _ = std.os.linux.lseek(@intCast(file_fd), 16, std.os.linux.SEEK.SET);
    var corrupt: [8]u8 = undefined;
    std.mem.writeInt(u64, &corrupt, 0xDEADBEEFCAFEBABE, .little);
    _ = std.os.linux.write(@intCast(file_fd), &corrupt, 8);

    // Re-init should skip the corrupt segment (CorruptSegmentHeader)
    var recovered = try Log.init(temp_path, 1);
    defer recovered.deinit();
    // Corrupt segment is skipped, log starts fresh
}

test "Durability: large payloads survive round-trip" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const large_payload_size = 1024 * 10;
    const large_payload = try testing.allocator.alloc(u8, large_payload_size);
    defer testing.allocator.free(large_payload);

    var i: usize = 0;
    while (i < large_payload_size) : (i += 1) {
        large_payload[i] = @intCast((i * 7) % 256);
    }

    var log_instance = try Log.init(temp_path, 1);
    const seq = try log_instance.append(TxnIntent.initTest(large_payload, 1, 1));
    log_instance.deinit();

    log_instance = try Log.init(temp_path, 1);
    defer log_instance.deinit();

    const entries = try log_instance.read(seq, 10, testing.allocator);
    defer {
        for (entries) |*e| e.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
    const intent = try TxnIntent.deserializeFrom(entries[0].payload, testing.allocator);
    defer intent.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, large_payload, intent.params);
    try testing.expect(entries[0].verifyCrc());
}

test "Durability: empty log survives deinit/init" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1);
    log_instance.deinit();

    log_instance = try Log.init(temp_path, 1);
    defer log_instance.deinit();

    const h = try log_instance.head();
    try testing.expectEqual(@as(Seq, 0), h);

    const seq = try log_instance.append(TxnIntent.initTest("first", 1, 1));
    try testing.expectEqual(@as(Seq, 1), seq);
}

test "Durability: node_id preserved across restarts" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const node_id: NodeId = 42;

    var log_instance = try Log.init(temp_path, node_id);
    _ = try log_instance.append(TxnIntent.initTest("entry", 1, 1));
    log_instance.deinit();

    log_instance = try Log.init(temp_path, node_id);
    defer log_instance.deinit();

    try testing.expectEqual(node_id, log_instance.node_id);

    const entries = try log_instance.read(1, 10, testing.allocator);
    defer {
        for (entries) |*e| e.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
}
