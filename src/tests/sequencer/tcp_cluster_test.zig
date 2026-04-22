/// 3-node Sequencer cluster over real TCP loopback.
///
/// Verifies:
/// 1. Leader election: one node becomes leader after enough ticks
/// 2. Replication: propose on the leader, followers replicate via AppendEntries
const std = @import("std");
const testing = std.testing;
const sequencer_mod = @import("sequencer.zig");

const Sequencer = sequencer_mod.Sequencer;
const Config = sequencer_mod.Config;
const PeerAddr = sequencer_mod.PeerAddr;

// ---------------------------------------------------------------------------
// Temp dir helpers
// ---------------------------------------------------------------------------

fn makeTempDir(suffix: []const u8) ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/tcp_cluster_{s}_{d}", .{ suffix, ns });
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
                const DT_DIR: u8 = 4;
                if (dent.type == DT_DIR) removeDirRecursive(child) else _ = std.os.linux.unlink(cz.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}

// ---------------------------------------------------------------------------
// 3-node cluster setup / teardown
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

/// Build a 3-node cluster wired over TCP loopback with OS-assigned ports.
fn initCluster(tag: []const u8, alloc: std.mem.Allocator) !TestCluster {
    const base = try makeTempDir(tag);
    errdefer {
        removeDirRecursive(base);
        alloc.free(base);
    }

    // Create the base directory so node subdirs can be mkdir'd inside it.
    {
        const basez = try alloc.allocSentinel(u8, base.len, 0);
        defer alloc.free(basez);
        @memcpy(basez[0..base.len], base);
        _ = std.os.linux.mkdir(basez.ptr, 0o755);
    }

    var tc = TestCluster{ .nodes = undefined, .inited = 0, .base = base, .alloc = alloc };

    // Init each node with placeholder peer addresses (we need ports first).
    for (0..3) |i| {
        const dir = try std.fmt.allocPrint(alloc, "{s}/node{d}", .{ base, i });
        defer alloc.free(dir);

        // Collect peer IDs for this node (the other two).
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

    // Learn actual OS-assigned ports and fix up each node's transport peer table.
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

fn tickAll(ps: [3]*Sequencer, alloc: std.mem.Allocator) !void {
    for (ps) |n| try n.tickOnce(alloc);
}

fn waitForLeader(ps: [3]*Sequencer, max_ticks: usize, alloc: std.mem.Allocator) !usize {
    for (0..max_ticks) |_| {
        try tickAll(ps, alloc);
        var found: ?usize = null;
        for (ps, 0..) |n, i| {
            if (n.isLeader()) {
                if (found != null) return error.TwoLeaders;
                found = i;
            }
        }
        if (found) |idx| return idx;
    }
    return error.NoLeaderElected;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "3-node TCP cluster: leader election" {
    const alloc = testing.allocator;
    var tc = try initCluster("elect", alloc);
    defer tc.deinit();

    const ps = tc.ptrs();
    const leader_idx = try waitForLeader(ps, 300, alloc);
    try testing.expect(leader_idx < 3);
    try testing.expect(tc.nodes[leader_idx].isLeader());

    // Exactly one leader.
    var leader_count: usize = 0;
    for (&tc.nodes) |*n| {
        if (n.isLeader()) leader_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), leader_count);
}

test "3-node TCP cluster: entry replication" {
    const alloc = testing.allocator;
    var tc = try initCluster("repl", alloc);
    defer tc.deinit();

    const ps = tc.ptrs();
    const leader_idx = try waitForLeader(ps, 300, alloc);

    // Propose an entry to the leader's Raft log.
    const seq = try tc.nodes[leader_idx].proposeRaw("replication_test", alloc);
    try testing.expect(seq >= 1);

    // Drive until at least 2 of 3 nodes have committed through seq.
    const max_steps = 300;
    var committed: usize = 0;
    for (0..max_steps) |_| {
        try tickAll(ps, alloc);
        committed = 0;
        for (&tc.nodes) |*n| {
            if (n.commitIndex() >= seq) committed += 1;
        }
        if (committed >= 2) break;
    }
    try testing.expect(committed >= 2);
}

test "3-node TCP cluster: multiple entries replicate in order" {
    const alloc = testing.allocator;
    var tc = try initCluster("multi", alloc);
    defer tc.deinit();

    const ps = tc.ptrs();
    const leader_idx = try waitForLeader(ps, 300, alloc);

    const payloads = [_][]const u8{ "entry_a", "entry_b", "entry_c" };
    var last_seq: sequencer_mod.Seq = 0;
    for (payloads) |p| {
        const seq = try tc.nodes[leader_idx].proposeRaw(p, alloc);
        try testing.expect(seq > last_seq);
        last_seq = seq;
    }

    // Drive until at least 2 of 3 nodes (majority) have committed all entries.
    var majority_committed = false;
    for (0..500) |_| {
        try tickAll(ps, alloc);
        var committed: usize = 0;
        for (&tc.nodes) |*n| {
            if (n.commitIndex() >= last_seq) committed += 1;
        }
        if (committed >= 2) {
            majority_committed = true;
            break;
        }
    }
    try testing.expect(majority_committed);
}
