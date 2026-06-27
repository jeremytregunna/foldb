const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");
const frame = @import("frame.zig");
const codec = @import("codec.zig");
const messages = @import("messages.zig");

const Gateway = gateway_mod.Gateway;

const DecodedFrame = struct {
    stream_id: u64,
    kind: frame.Kind,
    payload: []const u8,
};

fn makeTempDir(alloc: std.mem.Allocator, comptime name: []const u8) ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const path = try std.fmt.allocPrint(alloc, "/tmp/foldb_gateway_{s}_{d}", .{ name, ns });
    const z = try alloc.allocSentinel(u8, path.len, 0);
    defer alloc.free(z);
    @memcpy(z[0..path.len], path);
    _ = std.os.linux.mkdir(z.ptr, 0o755);
    return path;
}

fn removeTree(path: []const u8) void {
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
            const entry_name = std.mem.span(@as([*:0]const u8, @ptrCast(&dent.name)));
            if (!std.mem.eql(u8, entry_name, ".") and !std.mem.eql(u8, entry_name, "..")) {
                const child = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ path, entry_name }) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(child);
                const child_z = std.heap.page_allocator.allocSentinel(u8, child.len, 0) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(child_z);
                @memcpy(child_z[0..child.len], child);
                if (dent.type == std.os.linux.DT.DIR) {
                    removeTree(child);
                } else {
                    _ = std.os.linux.unlink(child_z.ptr);
                }
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}

fn expectResponse(bytes: []const u8, stream_id: u64) !DecodedFrame {
    try testing.expect(bytes.len >= frame.FRAME_HEADER_SIZE);
    const hdr = frame.FrameHeader{
        .stream_id = std.mem.readInt(u64, bytes[0..8], .little),
        .payload_len = std.mem.readInt(u32, bytes[8..12], .little),
        .version = std.mem.readInt(u16, bytes[12..14], .little),
        .kind = bytes[14],
        .flags = bytes[15],
    };
    try testing.expectEqual(stream_id, hdr.stream_id);
    try testing.expectEqual(frame.PROTOCOL_VERSION, hdr.version);
    try testing.expectEqual(frame.Kind.response, @as(frame.Kind, @enumFromInt(hdr.kind)));
    try testing.expect(@as(frame.Flags, @bitCast(hdr.flags)).final);
    const payload_start: usize = frame.FRAME_HEADER_SIZE;
    const payload_end = payload_start + hdr.payload_len;
    try testing.expect(bytes.len >= payload_end);
    return .{
        .stream_id = hdr.stream_id,
        .kind = @enumFromInt(hdr.kind),
        .payload = bytes[payload_start..payload_end],
    };
}

fn writer() std.Io.Writer.Allocating {
    return .init(testing.allocator);
}

fn decodeMutate(out: *std.Io.Writer.Allocating, stream_id: u64) !messages.MutateResponse {
    const f = try expectResponse(out.written(), stream_id);
    var cur = codec.Cursor{ .data = f.payload };
    return messages.decodeMutateResponse(&cur);
}

fn decodeGet(out: *std.Io.Writer.Allocating, stream_id: u64) !messages.GetResponse {
    const f = try expectResponse(out.written(), stream_id);
    var cur = codec.Cursor{ .data = f.payload };
    return messages.decodeGetResponse(&cur, testing.allocator);
}

fn decodeRange(out: *std.Io.Writer.Allocating, stream_id: u64) !messages.RangeResponse {
    const f = try expectResponse(out.written(), stream_id);
    var cur = codec.Cursor{ .data = f.payload };
    return messages.decodeRangeResponse(&cur, testing.allocator);
}

fn decodeBatch(out: *std.Io.Writer.Allocating, stream_id: u64) ![]messages.BatchResult {
    const f = try expectResponse(out.written(), stream_id);
    var cur = codec.Cursor{ .data = f.payload };
    return messages.decodeBatchResponse(&cur, testing.allocator);
}

fn shutdownWithoutStorageFlush(gw: *Gateway) void {
    gw.executor_shutdown.store(true, .release);
    for (gw.sequencer.logPartitionLogs()) |*log| log.notifyAppend();
    if (gw.executor_thread) |thread| thread.join();
    gw.executor.deinit();
    gw.sequencer.deinit();
    gw.storage.deinit();
    gw.alloc.destroy(gw);
}

test "gateway kv: set get delete and range through handlers" {
    const alloc = testing.allocator;
    const path = try makeTempDir(alloc, "basic");
    defer {
        removeTree(path);
        alloc.free(path);
    }

    const gw = try Gateway.init(path, alloc, .{});
    defer gw.deinit();

    var out = writer();
    defer out.deinit();

    try gateway_mod.handleSet(&out.writer, alloc, 1, .{ .key = "b", .value = "two" }, gw);
    const set_b = try decodeMutate(&out, 1);
    try testing.expect(set_b.committed_seq > 0);
    out.clearRetainingCapacity();

    try gateway_mod.handleSet(&out.writer, alloc, 2, .{ .key = "a", .value = "one" }, gw);
    _ = try decodeMutate(&out, 2);
    out.clearRetainingCapacity();

    try gateway_mod.handleGet(&out.writer, alloc, 3, .{ .key = "b", .at_seq = std.math.maxInt(u64) }, gw);
    const got_b = try decodeGet(&out, 3);
    defer messages.freeGetResponse(got_b, alloc);
    try testing.expect(got_b.value != null);
    try testing.expectEqualStrings("two", got_b.value.?);
    out.clearRetainingCapacity();

    try gateway_mod.handleRange(&out.writer, alloc, 4, .{ .start = "a", .end = "z", .limit = 0 }, gw);
    const range = try decodeRange(&out, 4);
    defer messages.freeRangeResponse(range, alloc);
    try testing.expectEqual(@as(usize, 2), range.entries.len);
    try testing.expectEqualStrings("a", range.entries[0].key);
    try testing.expectEqualStrings("one", range.entries[0].value);
    try testing.expectEqualStrings("b", range.entries[1].key);
    try testing.expectEqualStrings("two", range.entries[1].value);
    out.clearRetainingCapacity();

    try gateway_mod.handleDelete(&out.writer, alloc, 5, .{ .key = "b" }, gw);
    _ = try decodeMutate(&out, 5);
    out.clearRetainingCapacity();

    try gateway_mod.handleGet(&out.writer, alloc, 6, .{ .key = "b", .at_seq = std.math.maxInt(u64) }, gw);
    const deleted = try decodeGet(&out, 6);
    defer messages.freeGetResponse(deleted, alloc);
    try testing.expect(deleted.value == null);
}

test "gateway kv: restart replays committed unflushed set from log" {
    const alloc = testing.allocator;
    const path = try makeTempDir(alloc, "replay_unflushed");
    defer {
        removeTree(path);
        alloc.free(path);
    }

    {
        const gw = try Gateway.init(path, alloc, .{});
        var out = writer();
        defer out.deinit();

        try gateway_mod.handleSet(&out.writer, alloc, 1, .{ .key = "last", .value = "persisted" }, gw);
        _ = try decodeMutate(&out, 1);

        shutdownWithoutStorageFlush(gw);
    }

    const recovered = try Gateway.init(path, alloc, .{});
    defer recovered.deinit();

    var out = writer();
    defer out.deinit();
    try gateway_mod.handleGet(&out.writer, alloc, 2, .{ .key = "last", .at_seq = std.math.maxInt(u64) }, recovered);
    const got = try decodeGet(&out, 2);
    defer messages.freeGetResponse(got, alloc);
    try testing.expect(got.value != null);
    try testing.expectEqualStrings("persisted", got.value.?);
}

test "gateway kv: restart replays entries spread across log partitions" {
    const alloc = testing.allocator;
    const path = try makeTempDir(alloc, "replay_partitions");
    defer {
        removeTree(path);
        alloc.free(path);
    }

    {
        const gw = try Gateway.init(path, alloc, .{ .partition_count = 1, .log_partition_count = 4 });
        var out = writer();
        defer out.deinit();

        for (0..12) |i| {
            const key = try std.fmt.allocPrint(alloc, "k{d:02}", .{i});
            defer alloc.free(key);
            const value = try std.fmt.allocPrint(alloc, "v{d:02}", .{i});
            defer alloc.free(value);
            try gateway_mod.handleSet(&out.writer, alloc, @intCast(i + 1), .{ .key = key, .value = value }, gw);
            _ = try decodeMutate(&out, @intCast(i + 1));
            out.clearRetainingCapacity();
        }

        shutdownWithoutStorageFlush(gw);
    }

    const recovered = try Gateway.init(path, alloc, .{ .partition_count = 1, .log_partition_count = 4 });
    defer recovered.deinit();

    var out = writer();
    defer out.deinit();
    try gateway_mod.handleRange(&out.writer, alloc, 99, .{ .start = "k", .end = "l", .limit = 0 }, recovered);
    const range = try decodeRange(&out, 99);
    defer messages.freeRangeResponse(range, alloc);
    try testing.expectEqual(@as(usize, 12), range.entries.len);
    for (range.entries, 0..) |entry, i| {
        const expected_key = try std.fmt.allocPrint(alloc, "k{d:02}", .{i});
        defer alloc.free(expected_key);
        const expected_value = try std.fmt.allocPrint(alloc, "v{d:02}", .{i});
        defer alloc.free(expected_value);
        try testing.expectEqualStrings(expected_key, entry.key);
        try testing.expectEqualStrings(expected_value, entry.value);
    }
}

test "gateway kv: compare and swap succeeds once and reports stale seq" {
    const alloc = testing.allocator;
    const path = try makeTempDir(alloc, "cas");
    defer {
        removeTree(path);
        alloc.free(path);
    }

    const gw = try Gateway.init(path, alloc, .{});
    defer gw.deinit();

    var out = writer();
    defer out.deinit();

    try gateway_mod.handleSet(&out.writer, alloc, 1, .{ .key = "cas", .value = "v1" }, gw);
    const first = try decodeMutate(&out, 1);
    try testing.expect(first.cas_failed == null);
    out.clearRetainingCapacity();

    try gateway_mod.handleSet(&out.writer, alloc, 2, .{ .key = "cas", .value = "v2", .expected_seq = first.committed_seq }, gw);
    const second = try decodeMutate(&out, 2);
    try testing.expect(second.committed_seq > first.committed_seq);
    try testing.expect(second.cas_failed == null);
    out.clearRetainingCapacity();

    try gateway_mod.handleSet(&out.writer, alloc, 3, .{ .key = "cas", .value = "stale", .expected_seq = first.committed_seq }, gw);
    const stale = try decodeMutate(&out, 3);
    try testing.expectEqual(second.committed_seq, stale.committed_seq);
    try testing.expectEqual(second.committed_seq, stale.cas_failed.?);
    out.clearRetainingCapacity();

    try gateway_mod.handleGet(&out.writer, alloc, 4, .{ .key = "cas", .at_seq = std.math.maxInt(u64) }, gw);
    const got = try decodeGet(&out, 4);
    defer messages.freeGetResponse(got, alloc);
    try testing.expect(got.value != null);
    try testing.expectEqualStrings("v2", got.value.?);
}

const CasThreadArgs = struct {
    gw: *Gateway,
    expected_seq: u64,
    value: []const u8,
    result: ?messages.MutateResponse = null,
    err: ?anyerror = null,
};

fn casThread(args: *CasThreadArgs) void {
    var out = writer();
    defer out.deinit();
    gateway_mod.handleSet(
        &out.writer,
        testing.allocator,
        1,
        .{ .key = "race", .value = args.value, .expected_seq = args.expected_seq },
        args.gw,
    ) catch |err| {
        args.err = err;
        return;
    };
    args.result = decodeMutate(&out, 1) catch |err| {
        args.err = err;
        return;
    };
}

test "gateway kv: concurrent compare and swap allows one sequenced winner" {
    const alloc = testing.allocator;
    const path = try makeTempDir(alloc, "cas_concurrent");
    defer {
        removeTree(path);
        alloc.free(path);
    }

    const gw = try Gateway.init(path, alloc, .{});
    defer gw.deinit();

    var out = writer();
    defer out.deinit();
    try gateway_mod.handleSet(&out.writer, alloc, 1, .{ .key = "race", .value = "base" }, gw);
    const base = try decodeMutate(&out, 1);

    var a = CasThreadArgs{ .gw = gw, .expected_seq = base.committed_seq, .value = "winner-a" };
    var b = CasThreadArgs{ .gw = gw, .expected_seq = base.committed_seq, .value = "winner-b" };
    const ta = try std.Thread.spawn(.{}, casThread, .{&a});
    const tb = try std.Thread.spawn(.{}, casThread, .{&b});
    ta.join();
    tb.join();

    if (a.err) |err| return err;
    if (b.err) |err| return err;
    try testing.expect(a.result != null);
    try testing.expect(b.result != null);

    const a_ok = a.result.?.cas_failed == null;
    const b_ok = b.result.?.cas_failed == null;
    try testing.expect(a_ok != b_ok);
    const winning_seq = if (a_ok) a.result.?.committed_seq else b.result.?.committed_seq;
    const losing = if (a_ok) b.result.? else a.result.?;
    try testing.expectEqual(winning_seq, losing.committed_seq);
    try testing.expectEqual(winning_seq, losing.cas_failed.?);
}

test "gateway kv: mutating batch commits as one transaction" {
    const alloc = testing.allocator;
    const path = try makeTempDir(alloc, "batch");
    defer {
        removeTree(path);
        alloc.free(path);
    }

    const gw = try Gateway.init(path, alloc, .{});
    defer gw.deinit();

    var batch_ops = [_]messages.BatchOp{
        .{ .set = .{ .key = "k1", .value = "v1" } },
        .{ .set = .{ .key = "k2", .value = "v2" } },
        .{ .delete = .{ .key = "k1" } },
    };

    var out = writer();
    defer out.deinit();
    try gateway_mod.handleBatch(&out.writer, alloc, 1, &batch_ops, gw);
    const results = try decodeBatch(&out, 1);
    defer messages.freeBatchResponse(results, alloc);

    try testing.expectEqual(@as(usize, batch_ops.len), results.len);
    try testing.expect(results[0].mutate.committed_seq > 0);
    try testing.expectEqual(results[0].mutate.committed_seq, results[1].mutate.committed_seq);
    try testing.expectEqual(results[0].mutate.committed_seq, results[2].mutate.committed_seq);
    out.clearRetainingCapacity();

    try gw.waitCaughtUp();
    try gateway_mod.handleRange(&out.writer, alloc, 2, .{ .start = "k", .end = "l", .limit = 10 }, gw);
    const range = try decodeRange(&out, 2);
    defer messages.freeRangeResponse(range, alloc);
    try testing.expectEqual(@as(usize, 1), range.entries.len);
    try testing.expectEqualStrings("k2", range.entries[0].key);
    try testing.expectEqualStrings("v2", range.entries[0].value);
}
