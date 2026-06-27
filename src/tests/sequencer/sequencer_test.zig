/// Integration tests for the Sequencer module (M7).
const std = @import("std");
const testing = std.testing;
const sequencer_mod = @import("sequencer.zig");

const Sequencer = sequencer_mod.Sequencer;
const Config = sequencer_mod.Config;
const PendingSubmit = sequencer_mod.PendingSubmit;

fn makeTempDir(suffix: []const u8) ![]const u8 {
    // SAFETY: clock_gettime fills ts before any field is read.
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
    try seq.start();

    const payload = try minimalIntentPayload(testing.allocator);
    defer testing.allocator.free(payload);

    // SAFETY: submitBytes writes to pending before awaitCommit is called on the returned handle.

    var p1: PendingSubmit = undefined;
    const r1 = try seq.submitBytes(&p1, payload, 1, 1, .txn_intent).awaitCommit(null);

    // SAFETY: submitBytes writes to pending before awaitCommit is called on the returned handle.

    var p2: PendingSubmit = undefined;
    const r2 = try seq.submitBytes(&p2, payload, 1, 2, .txn_intent).awaitCommit(null);

    // SAFETY: submitBytes writes to pending before awaitCommit is called on the returned handle.

    var p3: PendingSubmit = undefined;
    const r3 = try seq.submitBytes(&p3, payload, 1, 3, .txn_intent).awaitCommit(null);

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
    try seq.start();

    const payload = try minimalIntentPayload(testing.allocator);
    defer testing.allocator.free(payload);

    // SAFETY: submitBytes writes to pending before awaitCommit is called on the returned handle.

    var p1: PendingSubmit = undefined;
    const r1 = try seq.submitBytes(&p1, payload, 42, 7, .txn_intent).awaitCommit(null);

    // SAFETY: submitBytes writes to pending before awaitCommit is called on the returned handle.

    var p2: PendingSubmit = undefined;
    const r2 = try seq.submitBytes(&p2, payload, 42, 7, .txn_intent).awaitCommit(null);

    try testing.expectEqual(r1.seq, r2.seq);
    try testing.expectEqual(r1.partition, r2.partition);
    try testing.expectEqual(@as(u64, 1), seq.currentSeq());
}

test "Sequencer: multi-partition routing assigns one seq per txn round-robin" {
    const path = try makeTempDir("multipart");
    defer {
        removeDirRecursive(path);
        testing.allocator.free(path);
    }

    var seq = try Sequencer.init(path, .{ .partition_count = 2 }, testing.allocator);
    defer seq.deinit();
    try seq.start();

    const payload = try minimalIntentPayload(testing.allocator);
    defer testing.allocator.free(payload);

    // SAFETY: submitBytes writes to pending before awaitCommit is called on the returned handle.

    var p1: PendingSubmit = undefined;
    const r1 = try seq.submitBytes(&p1, payload, 1, 1, .txn_intent).awaitCommit(null);

    // SAFETY: submitBytes writes to pending before awaitCommit is called on the returned handle.

    var p2: PendingSubmit = undefined;
    const r2 = try seq.submitBytes(&p2, payload, 1, 2, .txn_intent).awaitCommit(null);

    // SAFETY: submitBytes writes to pending before awaitCommit is called on the returned handle.

    var p3: PendingSubmit = undefined;
    const r3 = try seq.submitBytes(&p3, payload, 1, 3, .txn_intent).awaitCommit(null);

    // SAFETY: submitBytes writes to pending before awaitCommit is called on the returned handle.

    var p4: PendingSubmit = undefined;
    const r4 = try seq.submitBytes(&p4, payload, 1, 4, .txn_intent).awaitCommit(null);

    // commitRoute: one seq per txn, partition = seq % 2.
    // seq 1 % 2 = 1, seq 2 % 2 = 0, seq 3 % 2 = 1, seq 4 % 2 = 0.
    try testing.expectEqual(@as(u64, 1), r1.seq);
    try testing.expectEqual(@as(u32, 1), r1.partition);
    try testing.expectEqual(@as(u64, 2), r2.seq);
    try testing.expectEqual(@as(u32, 0), r2.partition);
    try testing.expectEqual(@as(u64, 3), r3.seq);
    try testing.expectEqual(@as(u32, 1), r3.partition);
    try testing.expectEqual(@as(u64, 4), r4.seq);
    try testing.expectEqual(@as(u32, 0), r4.partition);
}

test "Sequencer: committed entry becomes readable after catch-up" {
    const path = try makeTempDir("readable");
    defer {
        removeDirRecursive(path);
        testing.allocator.free(path);
    }

    var seq = try Sequencer.init(path, .{}, testing.allocator);
    defer seq.deinit();
    try seq.start();

    const payload = try minimalIntentPayload(testing.allocator);
    defer testing.allocator.free(payload);

    // SAFETY: submitBytes writes to pending before awaitCommit is called on the returned handle.

    var pending: PendingSubmit = undefined;
    const result = try seq.submitBytes(&pending, payload, 1, 1, .txn_intent).awaitCommit(null);
    try seq.catchUpCommitted();

    const partition_log = seq.partitionLog(result.partition);
    const entries = try partition_log.read(result.seq, 1, testing.allocator);
    defer {
        for (entries) |*e| e.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(result.seq, entries[0].header.seq);
}

test "Sequencer: config derives tick counts correctly" {
    // 150ms / 10ms = 15 ticks min, 300ms / 10ms = 30 ticks max, 50ms / 10ms = 5 heartbeat
    const cfg = Config{
        .tick_interval_ms = 10,
        .election_timeout_min_ms = 150,
        .election_timeout_max_ms = 300,
        .heartbeat_interval_ms = 50,
    };
    const tick_ms = cfg.tick_interval_ms;
    try testing.expectEqual(@as(u32, 15), cfg.election_timeout_min_ms / tick_ms);
    try testing.expectEqual(@as(u32, 30), cfg.election_timeout_max_ms / tick_ms);
    try testing.expectEqual(@as(u32, 5), cfg.heartbeat_interval_ms / tick_ms);

    // Verify a sequencer initialised with these values starts correctly
    const path = try makeTempDir("ticks");
    defer {
        removeDirRecursive(path);
        testing.allocator.free(path);
    }
    var seq = try Sequencer.init(path, cfg, testing.allocator);
    defer seq.deinit();
    // Single-node with these tick ratios must still elect itself
    try testing.expect(seq.raft.role == .leader);
}

test "Sequencer: log_partition_count is independent of partition_count" {
    const path = try makeTempDir("logpc");
    defer {
        removeDirRecursive(path);
        testing.allocator.free(path);
    }
    // log_partition_count = 0 defaults to partition_count
    var s1 = try Sequencer.init(path, .{ .partition_count = 2 }, testing.allocator);
    defer s1.deinit();
    try testing.expectEqual(@as(u32, 2), s1.logPartitionCount());
    try testing.expectEqual(@as(u32, 2), s1.partitionCount());
}

test "Sequencer: explicit log_partition_count is stored independently" {
    const path = try makeTempDir("logpc2");
    defer {
        removeDirRecursive(path);
        testing.allocator.free(path);
    }
    // log_partition_count overrides the default when non-zero
    var s2 = try Sequencer.init(path, .{ .partition_count = 2, .log_partition_count = 4 }, testing.allocator);
    defer s2.deinit();
    try testing.expectEqual(@as(u32, 4), s2.logPartitionCount());
    try testing.expectEqual(@as(u32, 2), s2.partitionCount());
}

test "Sequencer: config with peers registers peer IDs in RaftNode" {
    const path = try makeTempDir("peers");
    defer {
        removeDirRecursive(path);
        testing.allocator.free(path);
    }
    const peers = [_]sequencer_mod.PeerAddr{
        .{ .id = 2, .addr = "127.0.0.1:7434" },
        .{ .id = 3, .addr = "127.0.0.1:7435" },
    };
    const cfg = Config{
        .node_id = 1,
        .peers = &peers,
    };
    var seq = try Sequencer.init(path, cfg, testing.allocator);
    defer seq.deinit();
    // 2 peers registered in RaftNode
    try testing.expectEqual(@as(usize, 2), seq.raft.peers.len);
    try testing.expectEqual(@as(u64, 2), seq.raft.peers[0].id);
    try testing.expectEqual(@as(u64, 3), seq.raft.peers[1].id);
    // Multi-node: not yet leader (needs quorum to elect)
    try testing.expect(seq.raft.role != .leader);
}

test "Sequencer: commitRoute assigns monotonic seqs one per intent" {
    const path = try makeTempDir("route_mono");
    defer {
        removeDirRecursive(path);
        testing.allocator.free(path);
    }

    var seq = try Sequencer.init(path, .{ .partition_count = 1, .log_partition_count = 1 }, testing.allocator);
    defer seq.deinit();
    try seq.start();

    const payload = try minimalIntentPayload(testing.allocator);
    defer testing.allocator.free(payload);

    const r1 = try seq.commitRoute(1, 1, .{ .client_id = 1, .client_seq = 1, .intent_payload = payload, .entry_kind = .txn_intent });
    const r2 = try seq.commitRoute(1, 2, .{ .client_id = 1, .client_seq = 2, .intent_payload = payload, .entry_kind = .txn_intent });
    const r3 = try seq.commitRoute(1, 3, .{ .client_id = 1, .client_seq = 3, .intent_payload = payload, .entry_kind = .txn_intent });

    try testing.expectEqual(@as(u64, 1), r1.seq);
    try testing.expectEqual(@as(u64, 2), r2.seq);
    try testing.expectEqual(@as(u64, 3), r3.seq);
}

test "Sequencer: commitRoute spreads load across log partitions" {
    const path = try makeTempDir("route_spread");
    defer {
        removeDirRecursive(path);
        testing.allocator.free(path);
    }

    // 4 log partitions, 1 data partition — partitions are now independent.
    var seq = try Sequencer.init(path, .{ .partition_count = 1, .log_partition_count = 4 }, testing.allocator);
    defer seq.deinit();

    const payload = try minimalIntentPayload(testing.allocator);
    defer testing.allocator.free(payload);

    // Commit 100 intents and count how many land in each log partition.
    var counts = [_]u32{0} ** 4;
    var client_seq: u64 = 1;
    while (client_seq <= 100) : (client_seq += 1) {
        const r = try seq.commitRoute(1, client_seq, .{
            .client_id = 1,
            .client_seq = client_seq,
            .intent_payload = payload,
            .entry_kind = .txn_intent,
        });
        counts[r.partition] += 1;
    }

    // With load-weighted routing no single partition should receive more than 30% of entries.
    for (counts) |c| {
        try testing.expect(c <= 30);
    }
    // And every partition must have received at least one entry.
    for (counts) |c| {
        try testing.expect(c >= 1);
    }
}
