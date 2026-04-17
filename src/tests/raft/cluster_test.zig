/// In-process 3-node Raft cluster simulation tests.
///
/// Uses SimCluster(3) with InProcessBus — fully deterministic, no TCP.
/// Partition injection and tick control give complete scenario coverage.
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
                // Recurse for subdirs (node0/, node1/, node2/).
                _ = std.os.linux.rmdir(cz.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}

fn initCluster(base_dir: []const u8) !SimCluster3 {
    const cfg = Config{
        .election_timeout_min = 5,
        .election_timeout_max = 10,
        .heartbeat_interval = 2,
        .max_append_batch = 64,
    };
    return SimCluster3.init(testing.allocator, base_dir, cfg, .{ 1, 2, 3 });
}

/// Drive the cluster until a leader emerges or we hit max_steps.
fn waitForLeader(cluster: *SimCluster3, max_steps: usize) !usize {
    var steps: usize = 0;
    while (steps < max_steps) : (steps += 1) {
        try cluster.step();
        if (cluster.leader()) |idx| return idx;
    }
    return error.NoLeaderElected;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Cluster: leader is elected" {
    const dir = try makeTempDir("cl_elect");
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    var cluster = try initCluster(dir);
    defer cluster.deinit();

    const leader_idx = try waitForLeader(&cluster, 50);
    try testing.expect(leader_idx < 3);
    try testing.expectEqual(raft.RaftRole.leader, cluster.nodes[leader_idx].role);
}

test "Cluster: single append commits on majority" {
    const dir = try makeTempDir("cl_append");
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    var cluster = try initCluster(dir);
    defer cluster.deinit();

    _ = try waitForLeader(&cluster, 50);

    const seq = try cluster.propose("hello raft", 100);
    try testing.expectEqual(@as(u64, 1), seq);
    try testing.expect(try cluster.isCommitted(seq));
}

test "Cluster: multiple sequential appends all commit" {
    const dir = try makeTempDir("cl_multi");
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    var cluster = try initCluster(dir);
    defer cluster.deinit();

    _ = try waitForLeader(&cluster, 50);

    const payloads = [_][]const u8{ "one", "two", "three", "four", "five" };
    for (payloads, 1..) |payload, expected_seq| {
        const seq = try cluster.propose(payload, 100);
        try testing.expectEqual(@as(u64, expected_seq), seq);
    }
    try testing.expect(try cluster.isCommitted(5));
}

test "Cluster: all nodes have consistent log after appends" {
    const dir = try makeTempDir("cl_consistent");
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    var cluster = try initCluster(dir);
    defer cluster.deinit();

    _ = try waitForLeader(&cluster, 50);

    _ = try cluster.propose("alpha", 100);
    _ = try cluster.propose("beta", 100);
    _ = try cluster.propose("gamma", 100);

    // Drive a few more steps so followers catch up.
    try cluster.stepN(20);

    // All nodes should have at least 3 entries in their logs.
    for (0..3) |i| {
        const head = try cluster.logs[i].head();
        try testing.expectEqual(@as(u64, 3), head);
    }
}

test "Cluster: leader failure triggers re-election" {
    const dir = try makeTempDir("cl_failover");
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    var cluster = try initCluster(dir);
    defer cluster.deinit();

    const old_leader = try waitForLeader(&cluster, 50);
    const old_term = cluster.nodes[old_leader].current_term;

    // Commit one entry.
    _ = try cluster.propose("before_partition", 100);

    // Partition the old leader (drop its outbound messages).
    try cluster.partitionNode(old_leader);

    // Drive until a new leader is elected in the remaining two nodes.
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
    try testing.expect(new_leader.? != old_leader);
    try testing.expect(cluster.nodes[new_leader.?].current_term > old_term);
}

test "Cluster: appends continue after re-election" {
    const dir = try makeTempDir("cl_continue");
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    var cluster = try initCluster(dir);
    defer cluster.deinit();

    const old_leader = try waitForLeader(&cluster, 50);
    _ = try cluster.propose("before", 100);

    // Partition old leader.
    try cluster.partitionNode(old_leader);

    // Wait for new leader among remaining two nodes.
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

    // Propose to new leader.
    const seq = try cluster.propose("after", 100);
    try testing.expect(seq >= 2);
    try testing.expect(try cluster.isCommitted(seq));
}

test "Cluster: partition heal — old leader rejoins and converges" {
    const dir = try makeTempDir("cl_heal");
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    var cluster = try initCluster(dir);
    defer cluster.deinit();

    const old_leader = try waitForLeader(&cluster, 50);
    _ = try cluster.propose("before_partition", 100);

    try cluster.partitionNode(old_leader);

    // Elect a new leader.
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
    _ = try cluster.propose("during_partition", 100);

    // Heal partition.
    cluster.heal(false);

    // Drive until old leader steps down and all nodes agree.
    try cluster.stepN(50);

    // All nodes should be followers or the same leader, with consistent log.
    const final_head = try cluster.logs[new_leader.?].head();
    for (0..3) |i| {
        const h = try cluster.logs[i].head();
        try testing.expectEqual(final_head, h);
    }
}
