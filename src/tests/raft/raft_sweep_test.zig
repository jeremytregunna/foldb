/// Raft consensus seed sweep DST.
///
/// Runs three scenarios across N seeds (default 200, override with
/// -Ddst-seeds=N at build):
///   1. Basic election + commit (no faults)
///   2. 15% message drop — cluster must still converge
///   3. Leader partition + re-elect + heal + log convergence
///
/// Each scenario is exercised with the same master seed, fanning out to
/// per-node and network seeds via a fixed derivation so failures reproduce
/// exactly by re-running with the same -Ddst-seeds=N and seed index.
const std = @import("std");
const testing = std.testing;
const raft = @import("raft.zig");

const SimCluster3 = raft.SimCluster(3);
const Config = raft.Config;
const NetworkSim = raft.NetworkSim;
const NetworkConfig = raft.NetworkConfig;

const sweep_cfg = Config{
    .election_timeout_min = 5,
    .election_timeout_max = 50,
    .heartbeat_interval = 2,
    .max_append_batch = 64,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn toNullZ(path: []const u8, alloc: std.mem.Allocator) ![:0]u8 {
    const buf = try alloc.allocSentinel(u8, path.len, 0);
    @memcpy(buf[0..path.len], path);
    return buf;
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
                const child = std.fmt.allocPrint(alloc, "{s}/{s}", .{ path, name }) catch {
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

fn nodeSeed(master: u64, node: u32) u64 {
    return master *% 0x9e3779b97f4a7c15 +% @as(u64, node) *% 0x6c62272e07bb0142;
}

fn netSeed(master: u64) u64 {
    return master *% 0x517cc1b727220a95 +% 0xd9db3c4692b08b11;
}

fn seeds3(master: u64) [3]u64 {
    return .{ nodeSeed(master, 0), nodeSeed(master, 1), nodeSeed(master, 2) };
}

fn waitForLeader(cluster: *SimCluster3, max_steps: usize) !usize {
    for (0..max_steps) |_| {
        try cluster.step();
        if (cluster.leader()) |idx| return idx;
    }
    return error.NoLeaderElected;
}

fn seedCount() usize {
    return @import("options").dst_seeds;
}

// ---------------------------------------------------------------------------
// Scenarios
// ---------------------------------------------------------------------------

fn scenarioBasic(alloc: std.mem.Allocator, master: u64) !void {
    const dir = try std.fmt.allocPrint(alloc, "/tmp/raft_sweep_basic_{d}", .{master});
    defer {
        removeDirRecursive(dir);
        alloc.free(dir);
    }
    removeDirRecursive(dir);

    var cluster = try SimCluster3.init(alloc, dir, sweep_cfg, seeds3(master));
    defer cluster.deinit();

    _ = try waitForLeader(&cluster, 500);
    for (0..5) |i| {
        const payload = try std.fmt.allocPrint(alloc, "b_{d}_{d}", .{ master, i });
        defer alloc.free(payload);
        _ = try cluster.propose(payload, 400);
    }
    try cluster.stepN(30);
}

fn scenarioDrops(alloc: std.mem.Allocator, master: u64) !void {
    const dir = try std.fmt.allocPrint(alloc, "/tmp/raft_sweep_drops_{d}", .{master});
    defer {
        removeDirRecursive(dir);
        alloc.free(dir);
    }
    removeDirRecursive(dir);

    var cluster = try SimCluster3.init(alloc, dir, sweep_cfg, seeds3(master));
    defer cluster.deinit();
    cluster.net = NetworkSim.init(netSeed(master), NetworkConfig{ .drop_prob = 0.15 });

    _ = try waitForLeader(&cluster, 800);
    for (0..5) |i| {
        const payload = try std.fmt.allocPrint(alloc, "d_{d}_{d}", .{ master, i });
        defer alloc.free(payload);
        _ = try cluster.propose(payload, 800);
    }
    try cluster.stepN(50);
}

fn scenarioPartition(alloc: std.mem.Allocator, master: u64) !void {
    const dir = try std.fmt.allocPrint(alloc, "/tmp/raft_sweep_part_{d}", .{master});
    defer {
        removeDirRecursive(dir);
        alloc.free(dir);
    }
    removeDirRecursive(dir);

    var cluster = try SimCluster3.init(alloc, dir, sweep_cfg, seeds3(master));
    defer cluster.deinit();

    const old_leader = try waitForLeader(&cluster, 500);
    _ = try cluster.propose("pre", 400);

    try cluster.partitionNode(old_leader);

    var new_leader: ?usize = null;
    for (0..400) |_| {
        try cluster.step();
        if (cluster.leader()) |idx| {
            if (idx != old_leader) {
                new_leader = idx;
                break;
            }
        }
    }
    if (new_leader == null) return error.NoNewLeaderAfterPartition;

    _ = try cluster.propose("post", 400);
    cluster.heal(false);
    try cluster.stepN(150);

    const ref_head = try cluster.logs[new_leader.?].head();
    for (0..3) |i| {
        const h = try cluster.logs[i].head();
        if (h < ref_head) continue;
        const ref = try cluster.logs[new_leader.?].read(1, @intCast(ref_head), alloc);
        defer {
            for (ref) |*e| e.deinit(alloc);
            alloc.free(ref);
        }
        const got = try cluster.logs[i].read(1, @intCast(ref_head), alloc);
        defer {
            for (got) |*e| e.deinit(alloc);
            alloc.free(got);
        }
        for (ref, got) |re, ge| {
            if (re.header.seq != ge.header.seq or re.header.epoch != ge.header.epoch)
                return error.LogDivergence;
        }
    }
}

fn runSeed(alloc: std.mem.Allocator, master: u64) !void {
    try scenarioBasic(alloc, master);
    try scenarioDrops(alloc, master);
    try scenarioPartition(alloc, master);
}

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------

test "raft sweep: election, drops, and partition across N seeds" {
    const n = seedCount();
    for (0..n) |seed| {
        try runSeed(testing.allocator, @intCast(seed));
    }
}
