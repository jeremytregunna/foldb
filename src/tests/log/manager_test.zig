/// Unit tests for log manager.
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
    // SAFETY: clock_gettime fills ts before any field is read.
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const timestamp = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    const path = try std.fmt.allocPrint(testing.allocator, "/tmp/log_test_{d}", .{timestamp});
    const null_path = try toNullZ(testing.allocator, path);
    defer testing.allocator.free(null_path);
    _ = std.os.linux.mkdir(null_path.ptr, 0o755);
    return path;
}

// This is the domain boundary for tests — serializes a TxnIntent before handing
// pre-built LogEntry bytes to the log core via appendEntryAt.
fn appendTestIntent(log_inst: *Log, alloc: std.mem.Allocator, params: []const u8) !Seq {
    const intent = TxnIntent.init_test(params, 1, 1);
    const payload = try intent.serialize_to(alloc);
    defer alloc.free(payload);
    const seq = log_inst.current_seq + 1;
    const entry = LogEntry.create(seq, 0, .txn_intent, payload);
    try log_inst.append_entry_at(entry);
    return seq;
}

test "Log: initialization creates directory and segment" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const node_id: NodeId = 1;
    var log_instance = try Log.init(temp_path, node_id, testing.allocator);
    defer log_instance.deinit();

    try testing.expectEqual(@as(Seq, 0), log_instance.current_seq);
    try testing.expectEqual(node_id, log_instance.node_id);
    try testing.expect(!log_instance.sealed);
    try testing.expect(log_instance.sealed_segments.items.len == 0);
}

test "Log: append assigns sequence numbers" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1, testing.allocator);
    defer log_instance.deinit();

    const seq1 = try appendTestIntent(&log_instance, testing.allocator, "first");
    const seq2 = try appendTestIntent(&log_instance, testing.allocator, "second");
    const seq3 = try appendTestIntent(&log_instance, testing.allocator, "third");

    try testing.expectEqual(@as(Seq, 1), seq1);
    try testing.expectEqual(@as(Seq, 2), seq2);
    try testing.expectEqual(@as(Seq, 3), seq3);
    try testing.expectEqual(@as(Seq, 3), log_instance.current_seq);
}

test "Log: read returns entries in order" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1, testing.allocator);
    defer log_instance.deinit();

    const payloads = [_][]const u8{ "entry1", "entry2", "entry3", "entry4", "entry5" };
    for (payloads) |payload| {
        _ = try appendTestIntent(&log_instance, testing.allocator, payload);
    }

    const entries = try log_instance.read(1, 10, testing.allocator);
    defer {
        for (entries) |*e| e.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 5), entries.len);
    for (entries, 0..) |entry, i| {
        try testing.expectEqual(@as(Seq, @intCast(i + 1)), entry.header.seq);
        const intent = try TxnIntent.deserialize_from(entry.payload, testing.allocator);
        defer intent.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, payloads[i], intent.params);
    }
}

test "Log: read with from_seq filters correctly" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1, testing.allocator);
    defer log_instance.deinit();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = try appendTestIntent(&log_instance, testing.allocator, "data");
    }

    const entries = try log_instance.read(5, 10, testing.allocator);
    defer {
        for (entries) |*e| e.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 6), entries.len);
    try testing.expectEqual(@as(Seq, 5), entries[0].header.seq);
    try testing.expectEqual(@as(Seq, 10), entries[5].header.seq);
}

test "Log: head returns last sequence" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1, testing.allocator);
    defer log_instance.deinit();

    const empty_head = try log_instance.head();
    try testing.expectEqual(@as(Seq, 0), empty_head);

    _ = try appendTestIntent(&log_instance, testing.allocator, "first");
    _ = try appendTestIntent(&log_instance, testing.allocator, "second");
    _ = try appendTestIntent(&log_instance, testing.allocator, "third");

    const h = try log_instance.head();
    try testing.expectEqual(@as(Seq, 3), h);
}

test "Log: segment rotation when max entries reached" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1, testing.allocator);
    defer log_instance.deinit();

    log_instance.segment_max_entries = 3;

    _ = try appendTestIntent(&log_instance, testing.allocator, "1");
    _ = try appendTestIntent(&log_instance, testing.allocator, "2");
    _ = try appendTestIntent(&log_instance, testing.allocator, "3");

    try testing.expectEqual(@as(usize, 1), log_instance.sealed_segments.items.len);

    _ = try appendTestIntent(&log_instance, testing.allocator, "4");
    _ = try appendTestIntent(&log_instance, testing.allocator, "5");
    _ = try appendTestIntent(&log_instance, testing.allocator, "6");

    try testing.expectEqual(@as(usize, 2), log_instance.sealed_segments.items.len);

    const entries = try log_instance.read(1, 20, testing.allocator);
    defer {
        for (entries) |*e| e.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 6), entries.len);
}

test "Log: cross-segment reads work correctly" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1, testing.allocator);
    defer log_instance.deinit();

    log_instance.segment_max_entries = 2;

    const expected = [_][]const u8{ "a1", "a2", "b1", "b2", "c1", "c2" };
    for (expected) |payload| {
        _ = try appendTestIntent(&log_instance, testing.allocator, payload);
    }

    try testing.expectEqual(@as(usize, 3), log_instance.sealed_segments.items.len);

    const entries = try log_instance.read(1, 20, testing.allocator);
    defer {
        for (entries) |*e| e.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 6), entries.len);
    for (entries, 0..) |entry, i| {
        try testing.expectEqual(@as(Seq, @intCast(i + 1)), entry.header.seq);
        const intent = try TxnIntent.deserialize_from(entry.payload, testing.allocator);
        defer intent.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, expected[i], intent.params);
    }
}

test "Log: append to sealed log fails" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1, testing.allocator);
    defer log_instance.deinit();

    try log_instance.seal();

    const result = log_instance.append_entry_at(LogEntry.create(1, 0, .txn_intent, "should fail"));
    try testing.expectError(error.LogSealed, result);
}

test "Log: truncate_prefix removes old segments" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1, testing.allocator);
    defer log_instance.deinit();

    log_instance.segment_max_entries = 2;

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        _ = try appendTestIntent(&log_instance, testing.allocator, "data");
    }

    try testing.expectEqual(@as(usize, 4), log_instance.sealed_segments.items.len);

    try log_instance.truncate_prefix(5);

    try testing.expectEqual(@as(usize, 2), log_instance.sealed_segments.items.len);

    const entries = try log_instance.read(5, 20, testing.allocator);
    defer {
        for (entries) |*e| e.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 4), entries.len);
    try testing.expectEqual(@as(Seq, 5), entries[0].header.seq);
}

test "Log: re-initialization recovers sequence numbers" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1, testing.allocator);

    _ = try appendTestIntent(&log_instance, testing.allocator, "first");
    _ = try appendTestIntent(&log_instance, testing.allocator, "second");
    _ = try appendTestIntent(&log_instance, testing.allocator, "third");

    const before_head = try log_instance.head();
    try testing.expectEqual(@as(Seq, 3), before_head);

    log_instance.deinit();

    log_instance = try Log.init(temp_path, 1, testing.allocator);
    defer log_instance.deinit();

    const after_head = try log_instance.head();
    try testing.expectEqual(@as(Seq, 3), after_head);

    const new_seq = try appendTestIntent(&log_instance, testing.allocator, "fourth");
    try testing.expectEqual(@as(Seq, 4), new_seq);
}

test "Log: seq is strictly monotonic across segment rotation" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1, testing.allocator);
    defer log_instance.deinit();

    log_instance.segment_max_entries = 3;

    var prev_seq: Seq = 0;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const seq = try appendTestIntent(&log_instance, testing.allocator, "data");
        try testing.expect(seq > prev_seq);
        prev_seq = seq;
    }
    try testing.expectEqual(@as(Seq, 10), prev_seq);
}

test "Log: head is correct after rotation" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1, testing.allocator);
    defer log_instance.deinit();

    log_instance.segment_max_entries = 2;

    var last_seq: Seq = 0;
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        last_seq = try appendTestIntent(&log_instance, testing.allocator, "data");
    }

    const h = try log_instance.head();
    try testing.expectEqual(last_seq, h);
}

test "Log: read beyond head returns empty" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1, testing.allocator);
    defer log_instance.deinit();

    _ = try appendTestIntent(&log_instance, testing.allocator, "a");
    _ = try appendTestIntent(&log_instance, testing.allocator, "b");

    const entries = try log_instance.read(100, 10, testing.allocator);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "Log: read with max=0 returns empty" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1, testing.allocator);
    defer log_instance.deinit();

    _ = try appendTestIntent(&log_instance, testing.allocator, "data");

    const entries = try log_instance.read(1, 0, testing.allocator);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "Log: truncate_prefix is no-op when no sealed segments" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1, testing.allocator);
    defer log_instance.deinit();

    _ = try appendTestIntent(&log_instance, testing.allocator, "a");
    try log_instance.truncate_prefix(1);
    try testing.expectEqual(@as(usize, 0), log_instance.sealed_segments.items.len);

    const h = try log_instance.head();
    try testing.expectEqual(@as(Seq, 1), h);
}

test "Log: truncate_prefix removes all sealed segments" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var log_instance = try Log.init(temp_path, 1, testing.allocator);
    defer log_instance.deinit();

    log_instance.segment_max_entries = 2;

    var i: usize = 0;
    while (i < 6) : (i += 1) {
        _ = try appendTestIntent(&log_instance, testing.allocator, "data");
    }

    try testing.expectEqual(@as(usize, 3), log_instance.sealed_segments.items.len);

    // Remove all sealed segments (before_seq > last sealed last_seq)
    try log_instance.truncate_prefix(7);
    try testing.expectEqual(@as(usize, 0), log_instance.sealed_segments.items.len);
}
