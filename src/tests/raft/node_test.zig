/// Pure Raft state machine tests — no network, controlled ticks.
///
/// Each test creates real Log instances (disk-backed) and drives RaftNode
/// state transitions directly. The simulation design means all behaviour
/// is fully deterministic given the same sequence of inputs.
const std = @import("std");
const testing = std.testing;
const raft = @import("raft.zig");
const log_mod = @import("log.zig");

const RaftNode = raft.RaftNode;
const Config = raft.Config;
const Output = raft.Output;
const Log = log_mod.Log;
const TxnIntent = log_mod.TxnIntent;

// ---------------------------------------------------------------------------
// Test helpers
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
            const dent: *const std.os.linux.dirent64 = @alignCast(@ptrCast(buf[i..].ptr));
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
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}

const TEST_CFG = Config{
    .election_timeout_min = 5,
    .election_timeout_max = 10,
    .heartbeat_interval = 2,
    .max_append_batch = 64,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Node: starts as follower with zero term" {
    const node = try RaftNode.init(testing.allocator, 1, &.{ 2, 3 }, TEST_CFG, 0);
    defer @constCast(&node).deinit();
    try testing.expectEqual(raft.RaftRole.follower, node.role);
    try testing.expectEqual(@as(raft.Term, 0), node.current_term);
    try testing.expect(node.voted_for == null);
    try testing.expectEqual(@as(u32, 0), node.commit_index);
}

test "Node: election timeout triggers candidacy" {
    const dir = try makeTempDir("node_elect");
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    var log = try Log.init(dir, 1);
    defer log.deinit();

    var node = try RaftNode.init(testing.allocator, 1, &.{ 2, 3 }, TEST_CFG, 42);
    defer node.deinit();

    var out: std.ArrayList(Output) = .empty;
    defer out.deinit(testing.allocator);

    // Tick past election_timeout_max (10).
    for (0..11) |_| try node.tick(&log, &out);

    try testing.expectEqual(raft.RaftRole.candidate, node.role);
    try testing.expectEqual(@as(raft.Term, 1), node.current_term);
    try testing.expectEqual(@as(u32, 1), node.votes_for_me);

    // Should have emitted persist + 2 RequestVote messages.
    var persist_count: usize = 0;
    var rv_count: usize = 0;
    for (out.items) |o| switch (o) {
        .persist => persist_count += 1,
        .send => |s| if (s.msg == .request_vote) { rv_count += 1; },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), persist_count);
    try testing.expectEqual(@as(usize, 2), rv_count);
}

test "Node: wins election on majority vote" {
    const dir = try makeTempDir("node_win");
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    var log = try Log.init(dir, 1);
    defer log.deinit();

    var node = try RaftNode.init(testing.allocator, 1, &.{ 2, 3 }, TEST_CFG, 1);
    defer node.deinit();

    // Force candidacy.
    var out: std.ArrayList(Output) = .empty;
    defer out.deinit(testing.allocator);
    for (0..11) |_| try node.tick(&log, &out);
    out.clearRetainingCapacity();
    try testing.expectEqual(raft.RaftRole.candidate, node.role);

    // One vote granted → still candidate (need 2 out of 3).
    try node.handleRequestVoteResult(&log, 2, .{ .term = 1, .vote_granted = true }, &out);
    try testing.expectEqual(raft.RaftRole.leader, node.role);
}

test "Node: split vote — second election resolves" {
    const dir = try makeTempDir("node_split");
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    var log = try Log.init(dir, 1);
    defer log.deinit();

    var node = try RaftNode.init(testing.allocator, 1, &.{ 2, 3 }, TEST_CFG, 99);
    defer node.deinit();

    var out: std.ArrayList(Output) = .empty;
    defer out.deinit(testing.allocator);

    // First election — both peers deny.
    for (0..11) |_| try node.tick(&log, &out);
    out.clearRetainingCapacity();
    try node.handleRequestVoteResult(&log, 2, .{ .term = 1, .vote_granted = false }, &out);
    try node.handleRequestVoteResult(&log, 3, .{ .term = 1, .vote_granted = false }, &out);
    try testing.expectEqual(raft.RaftRole.candidate, node.role);

    // Second election after timeout — term increments.
    for (0..11) |_| try node.tick(&log, &out);
    try testing.expect(node.current_term >= 2);
    out.clearRetainingCapacity();

    // Now one peer grants.
    try node.handleRequestVoteResult(&log, 2, .{ .term = node.current_term, .vote_granted = true }, &out);
    try testing.expectEqual(raft.RaftRole.leader, node.role);
}

test "Node: steps down when receiving higher term" {
    const dir = try makeTempDir("node_step");
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    var log = try Log.init(dir, 1);
    defer log.deinit();

    var node = try RaftNode.init(testing.allocator, 1, &.{ 2, 3 }, TEST_CFG, 7);
    defer node.deinit();

    var out: std.ArrayList(Output) = .empty;
    defer out.deinit(testing.allocator);

    // Become leader.
    for (0..11) |_| try node.tick(&log, &out);
    out.clearRetainingCapacity();
    try node.handleRequestVoteResult(&log, 2, .{ .term = 1, .vote_granted = true }, &out);
    try testing.expectEqual(raft.RaftRole.leader, node.role);
    out.clearRetainingCapacity();

    // Receive AppendEntries with higher term.
    try node.handleAppendEntries(&log, .{
        .term = 5,
        .leader_id = 2,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &.{},
        .leader_commit = 0,
    }, &out);

    try testing.expectEqual(raft.RaftRole.follower, node.role);
    try testing.expectEqual(@as(raft.Term, 5), node.current_term);
}

test "Node: follower appends entries from leader" {
    const dir = try makeTempDir("node_append");
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    var log = try Log.init(dir, 1);
    defer log.deinit();

    var node = try RaftNode.init(testing.allocator, 1, &.{ 2, 3 }, TEST_CFG, 5);
    defer node.deinit();

    var out: std.ArrayList(Output) = .empty;
    defer out.deinit(testing.allocator);

    const e1 = log_mod.LogEntry.create(1, 1, .txn_intent, "hello");
    const e2 = log_mod.LogEntry.create(2, 1, .txn_intent, "world");

    try node.handleAppendEntries(&log, .{
        .term = 1,
        .leader_id = 2,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &.{ e1, e2 },
        .leader_commit = 2,
    }, &out);

    try testing.expectEqual(@as(u64, 2), try log.head());
    try testing.expectEqual(@as(u64, 2), node.commit_index);

    // Should have emitted committed + success reply.
    var committed_seen = false;
    var success_seen = false;
    for (out.items) |o| switch (o) {
        .committed => |seq| { committed_seen = true; try testing.expectEqual(@as(u64, 2), seq); },
        .send => |s| if (s.msg == .append_entries_result) {
            success_seen = true;
            try testing.expect(s.msg.append_entries_result.success);
        },
        else => {},
    };
    try testing.expect(committed_seen);
    try testing.expect(success_seen);
}

test "Node: log conflict resolved by truncation" {
    const dir = try makeTempDir("node_conflict");
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    var log = try Log.init(dir, 1);
    defer log.deinit();

    // Pre-populate log with stale entries (term 1).
    _ = try log.append(TxnIntent.init("stale1"));
    _ = try log.append(TxnIntent.init("stale2"));
    try testing.expectEqual(@as(u64, 2), try log.head());

    var node = try RaftNode.init(testing.allocator, 1, &.{ 2, 3 }, TEST_CFG, 3);
    defer node.deinit();

    var out: std.ArrayList(Output) = .empty;
    defer out.deinit(testing.allocator);

    // New leader (term 2) sends entry at index 2, but with prev_log_index=1, prev_log_term=2.
    // Our entry at index 1 is term 0 (epoch 0), so this fails consistency check.
    // Leader then backs up to prevLogIndex=0 and sends both entries.
    const fresh1 = log_mod.LogEntry.create(1, 2, .txn_intent, "fresh1");
    const fresh2 = log_mod.LogEntry.create(2, 2, .txn_intent, "fresh2");

    try node.handleAppendEntries(&log, .{
        .term = 2,
        .leader_id = 2,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &.{ fresh1, fresh2 },
        .leader_commit = 0,
    }, &out);

    try testing.expectEqual(@as(u64, 2), try log.head());

    // Verify entries are from term 2.
    const entries = try log.read(1, 10, testing.allocator);
    defer {
        for (entries) |*e| e.deinit(testing.allocator);
        testing.allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(@as(u64, 2), entries[0].header.epoch);
    try testing.expectEqual(@as(u64, 2), entries[1].header.epoch);
}

test "Node: leader commits on majority matchIndex" {
    const dir = try makeTempDir("node_commit");
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    var log = try Log.init(dir, 1);
    defer log.deinit();

    var node = try RaftNode.init(testing.allocator, 1, &.{ 2, 3 }, TEST_CFG, 11);
    defer node.deinit();

    var out: std.ArrayList(Output) = .empty;
    defer out.deinit(testing.allocator);

    // Become leader.
    for (0..11) |_| try node.tick(&log, &out);
    out.clearRetainingCapacity();
    try node.handleRequestVoteResult(&log, 2, .{ .term = 1, .vote_granted = true }, &out);
    out.clearRetainingCapacity();

    // Leader proposes one entry.
    const seq = (try node.propose(&log, .txn_intent, "data", &out)).?;
    out.clearRetainingCapacity();

    // One peer acks with match_index = seq.
    try node.handleAppendEntriesResult(&log, 2, .{
        .term = 1,
        .success = true,
        .match_index = seq,
    }, &out);

    // Self + peer 2 = majority for 3-node cluster.
    var committed: ?u64 = null;
    for (out.items) |o| if (o == .committed) { committed = o.committed; };
    try testing.expect(committed != null);
    try testing.expectEqual(seq, committed.?);
    try testing.expectEqual(seq, node.commit_index);
}

test "Node: stale AppendEntries rejected" {
    const dir = try makeTempDir("node_stale");
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }

    var log = try Log.init(dir, 1);
    defer log.deinit();

    var node = try RaftNode.init(testing.allocator, 1, &.{ 2, 3 }, TEST_CFG, 0);
    defer node.deinit();
    node.current_term = 5;

    var out: std.ArrayList(Output) = .empty;
    defer out.deinit(testing.allocator);

    try node.handleAppendEntries(&log, .{
        .term = 3,
        .leader_id = 2,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &.{},
        .leader_commit = 0,
    }, &out);

    // Should reject and reply with current term.
    var rejected = false;
    for (out.items) |o| switch (o) {
        .send => |s| if (s.msg == .append_entries_result) {
            try testing.expect(!s.msg.append_entries_result.success);
            try testing.expectEqual(@as(raft.Term, 5), s.msg.append_entries_result.term);
            rejected = true;
        },
        else => {},
    };
    try testing.expect(rejected);
}
