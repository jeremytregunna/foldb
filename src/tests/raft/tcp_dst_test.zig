/// DST: TcpTransport correctness under seeded fault injection.
///
/// Properties verified:
/// 1. Safety: every message that arrives decodes without error (no corruption)
/// 2. Liveness: with no fault hook, every sent message is received
/// 3. Fault fidelity: fault hook drops exactly those messages where drop_fn returns true
/// 4. Determinism: identical seeds produce identical drop sequences and receive counts
const std = @import("std");
const testing = std.testing;
const raft = @import("raft.zig");

// ---------------------------------------------------------------------------
// Fault hook infrastructure
// ---------------------------------------------------------------------------

const FaultCtx = struct {
    prng: std.Random.Xoroshiro128,
    drop_prob: f64,
};

fn dropHook(ctx: ?*anyopaque, _: raft.NodeId) bool {
    const fc: *FaultCtx = @ptrCast(@alignCast(ctx.?));
    return fc.prng.random().float(f64) < fc.drop_prob;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Send `count` distinct RequestVote messages from `sender` to `target_id`,
/// then drain `receiver` inbox. Returns number of messages actually received.
fn sendAndDrain(
    sender: *raft.TcpTransport,
    receiver: *raft.TcpTransport,
    target_id: raft.NodeId,
    count: usize,
    alloc: std.mem.Allocator,
) !usize {
    for (0..count) |i| {
        const msg = raft.Message{ .request_vote = .{
            .term = @intCast(i + 1),
            .candidate_id = sender.self_id,
            .last_log_index = @intCast(i),
            .last_log_term = 0,
        } };
        sender.send(target_id, msg);
    }

    var received: usize = 0;
    // Poll until we stop finding messages (or hit 2×count as a safety ceiling).
    const max_polls = count * 2 + 4;
    for (0..max_polls) |_| {
        if (try receiver.pollOnce(alloc)) {
            received += 1;
        } else {
            break;
        }
    }
    return received;
}

/// Verify that all messages currently in `t.inbox` are valid RequestVote messages
/// with term > 0. Clears the inbox as a side-effect.
fn assertInboxValid(t: *raft.TcpTransport) !void {
    for (t.inbox.items) |env| {
        try testing.expect(env.msg == .request_vote);
        try testing.expect(env.msg.request_vote.term > 0);
    }
    t.inbox.clearRetainingCapacity();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "TcpTransport DST: no fault hook — all messages delivered" {
    const alloc = testing.allocator;

    var a = raft.TcpTransport.init(alloc, 1);
    defer a.deinit();
    var b = raft.TcpTransport.init(alloc, 2);
    defer b.deinit();

    try b.listen(0);
    try a.listen(0);
    const port_b = try b.boundPort();
    const addr_b = try std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{port_b});
    defer alloc.free(addr_b);
    try a.addPeer(2, addr_b);

    const N = 8;
    const received = try sendAndDrain(&a, &b, 2, N, alloc);
    try testing.expectEqual(@as(usize, N), received);
    try assertInboxValid(&b);
}

test "TcpTransport DST: fault hook drops all — no messages delivered" {
    const alloc = testing.allocator;

    var a = raft.TcpTransport.init(alloc, 1);
    defer a.deinit();
    var b = raft.TcpTransport.init(alloc, 2);
    defer b.deinit();

    try b.listen(0);
    try a.listen(0);
    const port_b = try b.boundPort();
    const addr_b = try std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{port_b});
    defer alloc.free(addr_b);
    try a.addPeer(2, addr_b);

    var ctx = FaultCtx{ .prng = std.Random.Xoroshiro128.init(0xDEAD), .drop_prob = 1.0 };
    a.fault_hook = .{ .ctx = &ctx, .drop_fn = dropHook };

    const received = try sendAndDrain(&a, &b, 2, 16, alloc);
    try testing.expectEqual(@as(usize, 0), received);
}

test "TcpTransport DST: partial fault — received count is deterministic per seed" {
    const alloc = testing.allocator;

    // Run the same seed twice. We cannot assert the exact count without computing it,
    // but we CAN assert both runs produce the same count (determinism invariant).
    const N = 20;
    const seed: u64 = 0xCAFE_BABE;
    const drop_prob: f64 = 0.4;

    var counts: [2]usize = undefined;

    for (0..2) |run| {
        var a = raft.TcpTransport.init(alloc, 1);
        defer a.deinit();
        var b = raft.TcpTransport.init(alloc, 2);
        defer b.deinit();

        try b.listen(0);
        try a.listen(0);
        const port_b = try b.boundPort();
        const addr_b = try std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{port_b});
        defer alloc.free(addr_b);
        try a.addPeer(2, addr_b);

        var ctx = FaultCtx{
            .prng = std.Random.Xoroshiro128.init(seed),
            .drop_prob = drop_prob,
        };
        a.fault_hook = .{ .ctx = &ctx, .drop_fn = dropHook };

        counts[run] = try sendAndDrain(&a, &b, 2, N, alloc);
        try assertInboxValid(&b);
    }

    try testing.expectEqual(counts[0], counts[1]);
    // Sanity: some messages should have been dropped, some delivered.
    try testing.expect(counts[0] > 0);
    try testing.expect(counts[0] < N);
}

test "TcpTransport DST: different seeds yield different drop patterns" {
    const alloc = testing.allocator;
    const N = 30;
    const drop_prob: f64 = 0.4;

    const seeds = [_]u64{ 0x01, 0x02, 0xDEAD, 0xCAFE };
    var received_counts: [seeds.len]usize = undefined;

    for (seeds, 0..) |seed, s| {
        var a = raft.TcpTransport.init(alloc, 1);
        defer a.deinit();
        var b = raft.TcpTransport.init(alloc, 2);
        defer b.deinit();

        try b.listen(0);
        try a.listen(0);
        const port_b = try b.boundPort();
        const addr_b = try std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{port_b});
        defer alloc.free(addr_b);
        try a.addPeer(2, addr_b);

        var ctx = FaultCtx{
            .prng = std.Random.Xoroshiro128.init(seed),
            .drop_prob = drop_prob,
        };
        a.fault_hook = .{ .ctx = &ctx, .drop_fn = dropHook };

        received_counts[s] = try sendAndDrain(&a, &b, 2, N, alloc);
        try assertInboxValid(&b);
    }

    // At least two seeds must produce different counts.
    var unique = false;
    for (1..seeds.len) |i| {
        if (received_counts[i] != received_counts[0]) {
            unique = true;
            break;
        }
    }
    try testing.expect(unique);
}

test "TcpTransport DST: all message kinds survive fault-free round-trip" {
    const alloc = testing.allocator;

    var a = raft.TcpTransport.init(alloc, 10);
    defer a.deinit();
    var b = raft.TcpTransport.init(alloc, 20);
    defer b.deinit();

    try b.listen(0);
    try a.listen(0);
    const port_b = try b.boundPort();
    const addr_b = try std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{port_b});
    defer alloc.free(addr_b);
    try a.addPeer(20, addr_b);

    const msgs = [_]raft.Message{
        .{ .request_vote = .{ .term = 1, .candidate_id = 10, .last_log_index = 0, .last_log_term = 0 } },
        .{ .request_vote_result = .{ .term = 1, .vote_granted = true } },
        .{ .append_entries_result = .{ .term = 1, .success = true, .match_index = 5 } },
        .{ .append_entries = .{
            .term = 2,
            .leader_id = 10,
            .prev_log_index = 0,
            .prev_log_term = 0,
            .entries = &.{},
            .leader_commit = 0,
        } },
    };

    for (msgs) |msg| {
        a.send(20, msg);
    }

    var got: usize = 0;
    for (0..msgs.len * 2) |_| {
        if (try b.pollOnce(alloc)) got += 1 else break;
    }
    defer b.inbox.clearRetainingCapacity();

    try testing.expectEqual(@as(usize, msgs.len), got);

    // Verify each kind arrived in order.
    try testing.expect(b.inbox.items[0].msg == .request_vote);
    try testing.expect(b.inbox.items[1].msg == .request_vote_result);
    try testing.expect(b.inbox.items[2].msg == .append_entries_result);
    try testing.expect(b.inbox.items[3].msg == .append_entries);
}

test "TcpTransport DST: seed sweep — safety holds across 16 seeds" {
    const alloc = testing.allocator;
    const N = 10;
    const drop_prob: f64 = 0.35;

    var seed: u64 = 0xF001_0000;
    while (seed < 0xF001_0010) : (seed += 1) {
        var a = raft.TcpTransport.init(alloc, 1);
        defer a.deinit();
        var b = raft.TcpTransport.init(alloc, 2);
        defer b.deinit();

        try b.listen(0);
        try a.listen(0);
        const port_b = try b.boundPort();
        const addr_b = try std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{port_b});
        defer alloc.free(addr_b);
        try a.addPeer(2, addr_b);

        var ctx = FaultCtx{
            .prng = std.Random.Xoroshiro128.init(seed),
            .drop_prob = drop_prob,
        };
        a.fault_hook = .{ .ctx = &ctx, .drop_fn = dropHook };

        _ = try sendAndDrain(&a, &b, 2, N, alloc);
        // Safety: every message in the inbox must decode cleanly.
        try assertInboxValid(&b);
    }
}
