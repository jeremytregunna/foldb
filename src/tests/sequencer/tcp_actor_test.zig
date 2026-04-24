/// 3-node Sequencer cluster over real TCP using the actor (start/submitBytes) path.
///
/// Complements tcp_cluster_test.zig, which tests the Raft layer with manual tickOnce.
/// This file tests the production path: start() spawns the owner thread, submitBytes
/// enqueues via the MPSC queue, awaitCommit() spins until the owner thread has driven
/// Raft to quorum and written the partition log.
const std = @import("std");
const testing = std.testing;
const sequencer_mod = @import("sequencer.zig");

const Sequencer = sequencer_mod.Sequencer;
const Config = sequencer_mod.Config;
const PeerAddr = sequencer_mod.PeerAddr;
const PendingSubmit = sequencer_mod.PendingSubmit;

// ---------------------------------------------------------------------------
// Temp dir helpers (same as tcp_cluster_test.zig)
// ---------------------------------------------------------------------------

fn makeTempDir(suffix: []const u8) ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/tcp_actor_{s}_{d}", .{ suffix, ns });
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
                if (dent.type == DT_DIR) removeDirRecursive(child) else _ = std.os.linux.unlink(cz.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}

// ---------------------------------------------------------------------------
// 3-node actor cluster setup
// ---------------------------------------------------------------------------

const NODE_IDS = [3]u64{ 1, 2, 3 };

const TestCluster = struct {
    nodes: [3]Sequencer,
    inited: usize,
    base: []const u8,
    alloc: std.mem.Allocator,

    fn deinit(self: *TestCluster) void {
        for (self.nodes[0..self.inited]) |*n| n.deinit();
        removeDirRecursive(self.base);
        self.alloc.free(self.base);
    }

    fn ptrs(self: *TestCluster) [3]*Sequencer {
        return .{ &self.nodes[0], &self.nodes[1], &self.nodes[2] };
    }
};

fn initCluster(tag: []const u8, alloc: std.mem.Allocator) !TestCluster {
    const base = try makeTempDir(tag);
    errdefer {
        removeDirRecursive(base);
        alloc.free(base);
    }

    {
        const basez = try alloc.allocSentinel(u8, base.len, 0);
        defer alloc.free(basez);
        @memcpy(basez[0..base.len], base);
        _ = std.os.linux.mkdir(basez.ptr, 0o755);
    }

    var tc = TestCluster{ .nodes = undefined, .inited = 0, .base = base, .alloc = alloc };

    for (0..3) |i| {
        const dir = try std.fmt.allocPrint(alloc, "{s}/node{d}", .{ base, i });
        defer alloc.free(dir);

        var peer_slice: [2]PeerAddr = undefined;
        var pi: usize = 0;
        for (NODE_IDS) |pid| {
            if (pid != NODE_IDS[i]) {
                peer_slice[pi] = .{ .id = pid, .addr = "127.0.0.1:1" };
                pi += 1;
            }
        }

        tc.nodes[i] = try Sequencer.init(dir, .{
            .node_id = NODE_IDS[i],
            .partition_count = 1,
            .tick_interval_ms = 5,
            .election_timeout_min_ms = 50,
            .election_timeout_max_ms = 100,
            .heartbeat_interval_ms = 20,
            .listen_port = 0,
            .peers = &peer_slice,
        }, alloc);
        tc.inited += 1;
    }

    // Fix up actual OS-assigned ports.
    var ports: [3]u16 = undefined;
    for (0..3) |i| ports[i] = try tc.nodes[i].boundPort();

    for (0..3) |i| {
        for (0..3) |j| {
            if (j == i) continue;
            const addr = try std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{ports[j]});
            defer alloc.free(addr);
            try tc.nodes[i].addTransportPeer(NODE_IDS[j], addr);
        }
    }

    return tc;
}

/// Poll until one node is leader or timeout_ms elapses. Returns the leader index.
fn waitForLeader(ps: [3]*Sequencer, timeout_ms: u64) !usize {
    const deadline_ns = blk: {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.MONOTONIC, &ts);
        break :blk @as(u64, @intCast(ts.sec)) * 1_000_000_000 +
            @as(u64, @intCast(ts.nsec)) + timeout_ms * 1_000_000;
    };

    const sleep_ts = std.os.linux.timespec{ .sec = 0, .nsec = 5_000_000 }; // 5ms
    while (true) {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.MONOTONIC, &ts);
        const now = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
        if (now >= deadline_ns) return error.NoLeaderElected;

        var found: ?usize = null;
        for (ps, 0..) |n, i| {
            if (n.isLeader()) {
                if (found != null) return error.TwoLeaders;
                found = i;
            }
        }
        if (found) |idx| return idx;

        _ = std.os.linux.nanosleep(&sleep_ts, null);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "3-node actor cluster: leader election via owner threads" {
    const alloc = testing.allocator;
    var tc = try initCluster("elect", alloc);
    defer tc.deinit();
    for (&tc.nodes) |*n| try n.start();

    const ps = tc.ptrs();
    const leader_idx = try waitForLeader(ps, 2000);

    try testing.expect(leader_idx < 3);
    var leader_count: usize = 0;
    for (&tc.nodes) |*n| {
        if (n.isLeader()) leader_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), leader_count);
}

test "3-node actor cluster: submitBytes commits and is readable" {
    const alloc = testing.allocator;
    var tc = try initCluster("commit", alloc);
    defer tc.deinit();
    for (&tc.nodes) |*n| try n.start();

    const ps = tc.ptrs();
    const leader_idx = try waitForLeader(ps, 2000);

    var pending: PendingSubmit = undefined;
    const result = try tc.nodes[leader_idx].submitBytes(
        &pending,
        "actor_commit_test",
        1,
        1,
        .txn_intent,
    ).awaitCommit();

    try testing.expect(result.seq >= 1);

    // Entry must be readable from the leader's partition log.
    const log = tc.nodes[leader_idx].partitionLog(result.partition);
    const entries = try log.read(result.seq, 1, alloc);
    defer {
        for (entries) |*e| e.deinit(alloc);
        alloc.free(entries);
    }
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(result.seq, entries[0].header.seq);
}

test "3-node actor cluster: majority commits ordering decision" {
    const alloc = testing.allocator;
    var tc = try initCluster("majority", alloc);
    defer tc.deinit();
    for (&tc.nodes) |*n| try n.start();

    const ps = tc.ptrs();
    const leader_idx = try waitForLeader(ps, 2000);

    var pending: PendingSubmit = undefined;
    const result = try tc.nodes[leader_idx].submitBytes(
        &pending,
        "majority_test",
        1,
        1,
        .txn_intent,
    ).awaitCommit();

    // awaitCommit returned — the leader committed. Give followers a moment to catch up.
    const sleep_ts = std.os.linux.timespec{ .sec = 0, .nsec = 100_000_000 }; // 100ms
    _ = std.os.linux.nanosleep(&sleep_ts, null);

    var committed: usize = 0;
    for (&tc.nodes) |*n| {
        if (n.commitIndex() >= result.seq) committed += 1;
    }
    try testing.expect(committed >= 2);
}

test "3-node actor cluster: multiple sequential commits" {
    const alloc = testing.allocator;
    var tc = try initCluster("multi", alloc);
    defer tc.deinit();
    for (&tc.nodes) |*n| try n.start();

    const ps = tc.ptrs();
    const leader_idx = try waitForLeader(ps, 2000);

    var last_seq: sequencer_mod.Seq = 0;
    for (1..4) |i| {
        var pending: PendingSubmit = undefined;
        const result = try tc.nodes[leader_idx].submitBytes(
            &pending,
            "sequential",
            1,
            @intCast(i),
            .txn_intent,
        ).awaitCommit();

        try testing.expect(result.seq > last_seq);
        last_seq = result.seq;
    }
    try testing.expectEqual(@as(u64, 3), last_seq);
}
