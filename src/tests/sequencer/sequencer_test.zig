/// Integration tests for the Sequencer module (M7).
const std = @import("std");
const testing = std.testing;
const sequencer_mod = @import("sequencer.zig");

const Sequencer = sequencer_mod.Sequencer;
const Config = sequencer_mod.Config;

fn makeTempDir(suffix: []const u8) ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/seq_test_{s}_{d}", .{ suffix, ns });
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
                const DT_DIR: u8 = 4;
                if (dent.type == DT_DIR) {
                    removeDirRecursive(child);
                } else {
                    _ = std.os.linux.unlink(cz.ptr);
                }
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}

fn minimalIntentPayload(alloc: std.mem.Allocator) ![]u8 {
    const buf = try alloc.alloc(u8, 64);
    @memset(buf, 0);
    return buf;
}

test "Sequencer: init and deinit" {
    const path = try makeTempDir("init");
    defer {
        removeDirRecursive(path);
        testing.allocator.free(path);
    }

    var seq = try Sequencer.init(path, .{}, testing.allocator);
    defer seq.deinit();

    try testing.expectEqual(@as(u64, 0), seq.currentSeq());
}

test "Sequencer: submit assigns dense increasing seqs" {
    const path = try makeTempDir("dense");
    defer {
        removeDirRecursive(path);
        testing.allocator.free(path);
    }

    var seq = try Sequencer.init(path, .{}, testing.allocator);
    defer seq.deinit();

    const payload = try minimalIntentPayload(testing.allocator);
    defer testing.allocator.free(payload);

    const io = std.testing.io;

    var h1 = seq.submitBytes(io, payload, 1, 1);
    defer if (h1.future.cancel(io)) |_| {} else |_| {};
    const r1 = try h1.awaitCommit(io);

    var h2 = seq.submitBytes(io, payload, 1, 2);
    defer if (h2.future.cancel(io)) |_| {} else |_| {};
    const r2 = try h2.awaitCommit(io);

    var h3 = seq.submitBytes(io, payload, 1, 3);
    defer if (h3.future.cancel(io)) |_| {} else |_| {};
    const r3 = try h3.awaitCommit(io);

    try testing.expectEqual(@as(u64, 1), r1.seq);
    try testing.expectEqual(@as(u64, 2), r2.seq);
    try testing.expectEqual(@as(u64, 3), r3.seq);
    try testing.expectEqual(@as(u64, 3), seq.currentSeq());
}

test "Sequencer: idempotent submit returns same seq" {
    const path = try makeTempDir("idem");
    defer {
        removeDirRecursive(path);
        testing.allocator.free(path);
    }

    var seq = try Sequencer.init(path, .{}, testing.allocator);
    defer seq.deinit();

    const payload = try minimalIntentPayload(testing.allocator);
    defer testing.allocator.free(payload);

    const io = std.testing.io;

    var h1 = seq.submitBytes(io, payload, 42, 7);
    defer if (h1.future.cancel(io)) |_| {} else |_| {};
    const r1 = try h1.awaitCommit(io);

    var h2 = seq.submitBytes(io, payload, 42, 7);
    defer if (h2.future.cancel(io)) |_| {} else |_| {};
    const r2 = try h2.awaitCommit(io);

    try testing.expectEqual(r1.seq, r2.seq);
    try testing.expectEqual(r1.partition, r2.partition);
    try testing.expectEqual(@as(u64, 1), seq.currentSeq());
}

test "Sequencer: multi-partition routing distributes round-robin" {
    const path = try makeTempDir("multipart");
    defer {
        removeDirRecursive(path);
        testing.allocator.free(path);
    }

    var seq = try Sequencer.init(path, .{ .partition_count = 2 }, testing.allocator);
    defer seq.deinit();

    const payload = try minimalIntentPayload(testing.allocator);
    defer testing.allocator.free(payload);

    const io = std.testing.io;

    var h1 = seq.submitBytes(io, payload, 1, 1);
    defer if (h1.future.cancel(io)) |_| {} else |_| {};
    const r1 = try h1.awaitCommit(io);

    var h2 = seq.submitBytes(io, payload, 1, 2);
    defer if (h2.future.cancel(io)) |_| {} else |_| {};
    const r2 = try h2.awaitCommit(io);

    var h3 = seq.submitBytes(io, payload, 1, 3);
    defer if (h3.future.cancel(io)) |_| {} else |_| {};
    const r3 = try h3.awaitCommit(io);

    var h4 = seq.submitBytes(io, payload, 1, 4);
    defer if (h4.future.cancel(io)) |_| {} else |_| {};
    const r4 = try h4.awaitCommit(io);

    // seq 1 → 1%2=1, seq 2 → 2%2=0, seq 3 → 3%2=1, seq 4 → 4%2=0
    try testing.expectEqual(@as(u32, 1), r1.partition);
    try testing.expectEqual(@as(u32, 0), r2.partition);
    try testing.expectEqual(@as(u32, 1), r3.partition);
    try testing.expectEqual(@as(u32, 0), r4.partition);
}

test "Sequencer: committed entry readable from partition log" {
    const path = try makeTempDir("readable");
    defer {
        removeDirRecursive(path);
        testing.allocator.free(path);
    }

    var seq = try Sequencer.init(path, .{}, testing.allocator);
    defer seq.deinit();

    const payload = try minimalIntentPayload(testing.allocator);
    defer testing.allocator.free(payload);

    const io = std.testing.io;

    var handle = seq.submitBytes(io, payload, 1, 1);
    defer if (handle.future.cancel(io)) |_| {} else |_| {};
    const result = try handle.awaitCommit(io);

    const partition_log = seq.partitionLog(result.partition);
    const entries = try partition_log.read(result.seq, 1, testing.allocator);
    defer {
        for (entries) |*e| e.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(result.seq, entries[0].header.seq);
}
