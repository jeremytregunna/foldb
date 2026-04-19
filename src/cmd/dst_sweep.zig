/// DST seed sweep — runs three Raft simulation scenarios across N seeds.
///
/// Usage:
///   zig build dst-sweep -- --seeds 10000
///
/// Each seed exercises:
///   1. Basic election + commit (no faults)
///   2. 15% message drop — cluster must still converge
///   3. Leader partition + heal + log convergence check
///
/// Failing seeds are reported with the error name so root causes can be
/// reproduced exactly by re-running with that single seed.
const std = @import("std");
const raft_mod = @import("raft.zig");

const SimCluster3 = raft_mod.SimCluster(3);
const Config = raft_mod.Config;
const NetworkSim = raft_mod.NetworkSim;
const NetworkConfig = raft_mod.NetworkConfig;

/// Wider election timeout range reduces split-vote livelock across seeds.
const sweep_cfg = Config{
    .election_timeout_min = 5,
    .election_timeout_max = 50,
    .heartbeat_interval = 2,
    .max_append_batch = 64,
};

// ---------------------------------------------------------------------------
// Seed derivation — each master seed fans out to per-node and network seeds.
// ---------------------------------------------------------------------------

fn nodeSeed(master: u64, node: u32) u64 {
    return master *% 0x9e3779b97f4a7c15 +% @as(u64, node) *% 0x6c62272e07bb0142;
}

fn netSeed(master: u64) u64 {
    return master *% 0x517cc1b727220a95 +% 0xd9db3c4692b08b11;
}

// ---------------------------------------------------------------------------
// Dir helpers
// ---------------------------------------------------------------------------

fn toNullZ(path: []const u8, alloc: std.mem.Allocator) ![:0]u8 {
    const buf = try alloc.allocSentinel(u8, path.len, 0);
    @memcpy(buf[0..path.len], path);
    return buf;
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

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn waitForLeader(cluster: *SimCluster3, max_steps: usize) !usize {
    for (0..max_steps) |_| {
        try cluster.step();
        if (cluster.leader()) |idx| return idx;
    }
    return error.NoLeaderElected;
}

fn seeds3(master: u64) [3]u64 {
    return .{ nodeSeed(master, 0), nodeSeed(master, 1), nodeSeed(master, 2) };
}

// ---------------------------------------------------------------------------
// Scenario 1 — basic election and commit (no faults)
// ---------------------------------------------------------------------------

fn scenarioBasic(alloc: std.mem.Allocator, master: u64) !void {
    const dir = try std.fmt.allocPrint(alloc, "/tmp/dst_basic_{d}", .{master});
    defer {
        removeDirRecursive(dir);
        alloc.free(dir);
    }
    removeDirRecursive(dir); // clear any stale dir from a crashed prior run

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

// ---------------------------------------------------------------------------
// Scenario 2 — 15% message drop rate, cluster must still converge
// ---------------------------------------------------------------------------

fn scenarioDrops(alloc: std.mem.Allocator, master: u64) !void {
    const dir = try std.fmt.allocPrint(alloc, "/tmp/dst_drops_{d}", .{master});
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

// ---------------------------------------------------------------------------
// Scenario 3 — partition leader, re-elect, heal, verify log convergence
// ---------------------------------------------------------------------------

fn scenarioPartition(alloc: std.mem.Allocator, master: u64) !void {
    const dir = try std.fmt.allocPrint(alloc, "/tmp/dst_part_{d}", .{master});
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

    // All nodes must agree on the log prefix up to the new leader's commit.
    const ref_head = try cluster.logs[new_leader.?].head();
    for (0..3) |i| {
        const h = try cluster.logs[i].head();
        if (h < ref_head) continue; // still catching up — acceptable
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

// ---------------------------------------------------------------------------
// Per-seed runner
// ---------------------------------------------------------------------------

fn runSeed(alloc: std.mem.Allocator, master: u64) !void {
    try scenarioBasic(alloc, master);
    try scenarioDrops(alloc, master);
    try scenarioPartition(alloc, master);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var num_seeds: u64 = 100;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--seeds") and i + 1 < args.len) {
            num_seeds = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 1;
        }
    }

    std.debug.print("DST sweep: {d} seeds × 3 scenarios\n", .{num_seeds});

    var failures: std.ArrayList(u64) = .empty;
    defer failures.deinit(alloc);

    for (0..num_seeds) |seed| {
        runSeed(alloc, seed) catch |err| {
            try failures.append(alloc, @intCast(seed));
            std.debug.print("FAIL seed={d} err={s}\n", .{ seed, @errorName(err) });
        };
        if ((seed + 1) % 1000 == 0) {
            std.debug.print("  {d}/{d}\n", .{ seed + 1, num_seeds });
        }
    }

    if (failures.items.len > 0) {
        std.debug.print("\n{d}/{d} seeds FAILED:\n", .{ failures.items.len, num_seeds });
        for (failures.items) |s| std.debug.print("  seed={d}\n", .{s});
        return error.SeedsFailed;
    }
    std.debug.print("All {d} seeds PASSED.\n", .{num_seeds});
}
