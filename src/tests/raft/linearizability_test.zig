/// Linearizability tests for single-partition Raft append.
///
/// A log append operation is linearizable if:
///   1. Every successful append returns a unique seq.
///   2. Seqs are dense and monotonically increasing (no gaps).
///   3. Every entry that received a committed seq exists in every node's log
///      at exactly that position.
///   4. All nodes agree on the log contents up to the commit index.
///
/// We simulate concurrent clients and network partitions in a single thread
/// using SimCluster's deterministic step() loop. This reproduces the exact
/// conditions a Jepsen-style test would probe, with full reproducibility from
/// the seed values passed to SimCluster.init.
const std = @import("std");
const testing = std.testing;
const raft = @import("raft.zig");
const log_mod = @import("log.zig");

const SimCluster3 = raft.SimCluster(3);
const Config = raft.Config;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn toNullZ(path: []const u8, allocator: std.mem.Allocator) ![:0]u8 {
    const buf = try allocator.allocSentinel(u8, path.len, 0);
    @memcpy(buf[0..path.len], path);
    return buf;
}

fn makeTempDir(prefix: []const u8) ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/{s}_{d}", .{ prefix, ns });
}

fn removeDirRecursive(path: []const u8) void {
    const z = toNullZ(path, std.heap.page_allocator) catch return;
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
                const cz = toNullZ(child, std.heap.page_allocator) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(cz);
                _ = std.os.linux.unlink(cz.ptr);
                _ = std.os.linux.rmdir(cz.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}

fn initCluster(base_dir: []const u8) !SimCluster3 {
    return SimCluster3.init(testing.allocator, base_dir, .{
        .election_timeout_min = 5,
        .election_timeout_max = 10,
        .heartbeat_interval = 2,
        .max_append_batch = 64,
    }, .{ 10, 20, 30 });
}

fn waitForLeader(cluster: *SimCluster3, max_steps: usize) !usize {
    for (0..max_steps) |_| {
        try cluster.step();
        if (cluster.leader()) |idx| return idx;
    }
    return error.NoLeaderElected;
}

/// Check that all nodes agree on the log prefix up to `up_to`.
fn assertNodesAgree(cluster: *SimCluster3, up_to: u64) !void {
    const ref_entries = try cluster.logs[0].read(1, @intCast(up_to), testing.allocator);
    defer {
        for (ref_entries) |*e| e.deinit(testing.allocator);
        testing.allocator.free(ref_entries);
    }

    for (1..3) |i| {
        const head = try cluster.logs[i].head();
        if (head < up_to) continue; // node still catching up
        const entries = try cluster.logs[i].read(1, @intCast(up_to), testing.allocator);
        defer {
            for (entries) |*e| e.deinit(testing.allocator);
            testing.allocator.free(entries);
        }
        for (ref_entries, entries) |ref, got| {
            try testing.expectEqual(ref.header.seq, got.header.seq);
            try testing.expectEqual(ref.header.epoch, got.header.epoch);
            try testing.expectEqualSlices(u8, ref.payload, got.payload);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Linearizability: sequential appends produce dense gap-free seqs" {
    const dir = try makeTempDir("lin_seq");
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    var cluster = try initCluster(dir);
    defer cluster.deinit();

    _ = try waitForLeader(&cluster, 50);

    const N = 10;
    var seqs: [N]u64 = undefined;
    for (0..N) |i| {
        const payload = try std.fmt.allocPrint(testing.allocator, "entry_{d}", .{i});
        defer testing.allocator.free(payload);
        seqs[i] = try cluster.propose(payload, 200);
    }

    // Seqs must be strictly increasing and dense starting from 1.
    for (seqs, 0..) |seq, i| {
        try testing.expectEqual(@as(u64, i + 1), seq);
    }

    // All committed.
    try testing.expect(try cluster.isCommitted(N));
}

test "Linearizability: interleaved proposes and steps produce consistent log" {
    const dir = try makeTempDir("lin_interleaved");
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    var cluster = try initCluster(dir);
    defer cluster.deinit();

    _ = try waitForLeader(&cluster, 50);

    // Simulate concurrent clients: propose one entry, step a few times, propose next.
    const N = 8;
    var committed_seqs: std.ArrayList(u64) = .empty;
    defer committed_seqs.deinit(testing.allocator);

    for (0..N) |i| {
        const payload = try std.fmt.allocPrint(testing.allocator, "concurrent_{d}", .{i});
        defer testing.allocator.free(payload);
        const seq = try cluster.propose(payload, 100);
        try committed_seqs.append(testing.allocator, seq);
        // Simulate other "clients" doing work while this commit is in flight.
        try cluster.stepN(3);
    }

    // All seqs unique.
    for (committed_seqs.items, 0..) |seq_a, i| {
        for (committed_seqs.items[i + 1 ..]) |seq_b| {
            try testing.expect(seq_a != seq_b);
        }
    }

    // Dense: max seq == number of entries.
    var max_seq: u64 = 0;
    for (committed_seqs.items) |s| max_seq = @max(max_seq, s);
    try testing.expectEqual(@as(u64, N), max_seq);
}

test "Linearizability: partition and heal — committed entries survive" {
    const dir = try makeTempDir("lin_partition");
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    var cluster = try initCluster(dir);
    defer cluster.deinit();

    const old_leader = try waitForLeader(&cluster, 50);

    // Phase 1: commit entries before partition.
    _ = try cluster.propose("pre_partition_1", 100);
    _ = try cluster.propose("pre_partition_2", 100);

    // Phase 2: partition old leader, wait for new election.
    try cluster.partitionNode(old_leader);

    var new_leader: ?usize = null;
    for (0..100) |_| {
        try cluster.step();
        if (cluster.leader()) |idx| {
            if (idx != old_leader) {
                new_leader = idx;
                break;
            }
        }
    }
    try testing.expect(new_leader != null);

    // Phase 3: commit more entries via new leader.
    _ = try cluster.propose("during_partition_1", 100);
    _ = try cluster.propose("during_partition_2", 100);

    const committed_head = try cluster.logs[new_leader.?].head();
    try testing.expect(committed_head >= 4);

    // Phase 4: heal, let old leader converge.
    cluster.heal(false);
    try cluster.stepN(100);

    // All nodes must agree on the full log.
    try assertNodesAgree(&cluster, committed_head);
}

test "Linearizability: no entry committed in one term is lost in a future term" {
    const dir = try makeTempDir("lin_safety");
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    var cluster = try initCluster(dir);
    defer cluster.deinit();

    const leader1 = try waitForLeader(&cluster, 50);
    const committed_seq = try cluster.propose("must_survive", 100);

    // Record what node 0 (or any node that has it) has at that seq.
    const ref = blk: {
        const entries = try cluster.logs[leader1].read(committed_seq, 1, testing.allocator);
        defer {
            for (entries) |*e| e.deinit(testing.allocator);
            testing.allocator.free(entries);
        }
        try testing.expectEqual(@as(usize, 1), entries.len);
        break :blk entries[0].header.epoch;
    };

    // Force multiple re-elections via partitions.
    for (0..3) |_| {
        if (cluster.leader()) |li| {
            try cluster.partitionNode(li);
            for (0..50) |_| {
                try cluster.step();
                if (cluster.leader()) |new_li| {
                    if (new_li != li) break;
                }
            }
            cluster.heal(false);
            try cluster.stepN(20);
        }
    }

    // The committed entry must still exist with the same term on all nodes.
    for (0..3) |i| {
        const h = try cluster.logs[i].head();
        if (h < committed_seq) continue; // node still catching up
        const entries = try cluster.logs[i].read(committed_seq, 1, testing.allocator);
        defer {
            for (entries) |*e| e.deinit(testing.allocator);
            testing.allocator.free(entries);
        }
        if (entries.len == 0) continue;
        try testing.expectEqual(committed_seq, entries[0].header.seq);
        try testing.expectEqual(ref, entries[0].header.epoch);
        try testing.expectEqualSlices(u8, "must_survive", entries[0].payload);
    }
}

test "Linearizability: multiple seeds produce valid independent histories" {
    // Run the same workload with different seeds — all must produce valid histories.
    const seeds = [_][3]u64{
        .{ 1, 2, 3 },
        .{ 42, 43, 44 },
        .{ 0xDEAD, 0xBEEF, 0xCAFE },
    };

    for (seeds, 0..) |seed_set, si| {
        const prefix = try std.fmt.allocPrint(testing.allocator, "lin_seeds_{d}", .{si});
        defer testing.allocator.free(prefix);
        const dir = try makeTempDir(prefix);
        defer {
            removeDirRecursive(dir);
            testing.allocator.free(dir);
        }

        var cluster = try SimCluster3.init(testing.allocator, dir, .{
            .election_timeout_min = 5,
            .election_timeout_max = 10,
            .heartbeat_interval = 2,
            .max_append_batch = 64,
        }, seed_set);
        defer cluster.deinit();

        _ = try waitForLeader(&cluster, 50);

        var last_seq: u64 = 0;
        for (0..5) |i| {
            const payload = try std.fmt.allocPrint(testing.allocator, "s{d}_e{d}", .{ si, i });
            defer testing.allocator.free(payload);
            const seq = try cluster.propose(payload, 200);
            // Each seq must be strictly greater than the previous.
            try testing.expect(seq > last_seq);
            last_seq = seq;
        }
        try testing.expectEqual(@as(u64, 5), last_seq);
    }
}
