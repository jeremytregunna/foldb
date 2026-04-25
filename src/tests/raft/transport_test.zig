const std = @import("std");
const testing = std.testing;
const raft = @import("raft.zig");

test "TcpTransport: send to non-listening addr does not panic" {
    var t = raft.TcpTransport.init(testing.allocator, 1);
    defer t.deinit();

    try t.addPeer(2, "127.0.0.1:19999");

    const msg = raft.Message{ .request_vote = .{
        .term = 1,
        .candidate_id = 1,
        .last_log_index = 0,
        .last_log_term = 0,
    } };
    t.send(2, msg); // nothing listening — must not crash
    const peer = t.peers.get(2).?;
    try testing.expectEqual(@as(std.posix.fd_t, -1), peer.fd);
}

test "TcpTransport: encodeMessage / decodeMessage round-trip" {
    const msg = raft.Message{ .request_vote = .{
        .term = 5,
        .candidate_id = 3,
        .last_log_index = 10,
        .last_log_term = 4,
    } };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try raft.encodeMessage(3, msg, &buf, testing.allocator);

    const env = try raft.decodeMessage(buf.items[4..], testing.allocator);
    try testing.expectEqual(@as(u64, 3), env.from);
    try testing.expect(env.msg == .request_vote);
    try testing.expectEqual(@as(u64, 5), env.msg.request_vote.term);
    try testing.expectEqual(@as(u64, 3), env.msg.request_vote.candidate_id);
}

test "TcpTransport: loopback send/receive" {
    const alloc = testing.allocator;

    var a = raft.TcpTransport.init(alloc, 1);
    defer a.deinit();
    var b = raft.TcpTransport.init(alloc, 2);
    defer b.deinit();

    // Let OS assign ports
    try b.listen(0);
    try a.listen(0);
    const port_b = try b.boundPort();

    const addr_b = try std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{port_b});
    defer alloc.free(addr_b);
    try a.addPeer(2, addr_b);

    const msg = raft.Message{ .request_vote = .{
        .term = 2,
        .candidate_id = 1,
        .last_log_index = 5,
        .last_log_term = 1,
    } };
    a.send(2, msg);

    const got = try b.pollOnce(alloc);
    try testing.expect(got);
    try testing.expectEqual(@as(usize, 1), b.inbox.items.len);

    const env = b.inbox.items[0];
    try testing.expectEqual(@as(u64, 1), env.from);
    try testing.expectEqual(@as(u64, 2), env.to);
    try testing.expect(env.msg == .request_vote);
    try testing.expectEqual(@as(u64, 2), env.msg.request_vote.term);
    try testing.expectEqual(@as(u64, 1), env.msg.request_vote.candidate_id);

    const got2 = try b.pollOnce(alloc);
    try testing.expect(!got2);
}

test "TcpTransport: drainInbox moves messages to caller" {
    const alloc = testing.allocator;

    var sender = raft.TcpTransport.init(alloc, 10);
    defer sender.deinit();
    var receiver = raft.TcpTransport.init(alloc, 20);
    defer receiver.deinit();

    try receiver.listen(0);
    try sender.listen(0);
    const port_r = try receiver.boundPort();

    const addr_r = try std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{port_r});
    defer alloc.free(addr_r);
    try sender.addPeer(20, addr_r);

    sender.send(20, raft.Message{ .request_vote_result = .{ .term = 3, .vote_granted = true } });

    _ = try receiver.pollOnce(alloc);
    try testing.expectEqual(@as(usize, 1), receiver.inbox.items.len);

    var out: std.ArrayList(raft.Envelope) = .empty;
    defer out.deinit(alloc);
    try receiver.drainInbox(&out, alloc);

    try testing.expectEqual(@as(usize, 0), receiver.inbox.items.len);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(out.items[0].msg == .request_vote_result);
    try testing.expect(out.items[0].msg.request_vote_result.vote_granted);
}

// ---------------------------------------------------------------------------
// Persistent-connection property tests
//
// These validate the transport rewrite: a single TCP connection carries all
// messages between a pair of nodes, and a failed connection is re-established
// transparently on the next send.
// ---------------------------------------------------------------------------

test "TcpTransport: N messages on one persistent connection, all received" {
    // Property: sending N messages from A to B over a persistent connection
    // delivers all N messages with correct content and order.
    // Before the rewrite each send opened and closed a separate connection,
    // so this test also validates that the inbound-fd tracking accumulates
    // exactly one persistent connection and reads all messages from it.
    const alloc = testing.allocator;
    const N = 8;

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

    // Send N messages on the same connection.
    for (0..N) |i| {
        a.send(2, raft.Message{ .request_vote = .{
            .term = @intCast(i + 1),
            .candidate_id = 1,
            .last_log_index = @intCast(i),
            .last_log_term = 0,
        } });
    }

    // A single persistent inbound connection carries all messages.
    // Drain until we have all N.
    var received: usize = 0;
    for (0..N * 4) |_| {
        if (try b.pollOnce(alloc)) received += 1;
        if (received >= N) break;
    }
    try testing.expectEqual(N, received);
    try testing.expectEqual(@as(usize, 1), b.inbound.items.len);

    // Verify terms are 1..N in order (messages are FIFO on one connection).
    for (b.inbox.items, 0..) |env, i| {
        try testing.expectEqual(@as(u64, i + 1), env.msg.request_vote.term);
    }
}

test "TcpTransport: sender reconnects after connection forced closed" {
    // Property: if the sender's persistent connection is torn down (simulated
    // by forcing fd = -1 after closing it), the next send re-establishes the
    // connection and the message is delivered.
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

    // First send — establishes the persistent connection.
    a.send(2, raft.Message{ .request_vote = .{ .term = 1, .candidate_id = 1, .last_log_index = 0, .last_log_term = 0 } });
    try testing.expect(try b.pollOnce(alloc));
    try testing.expectEqual(@as(usize, 1), b.inbox.items.len);

    // Force-close the sender's outbound fd to simulate a broken connection.
    const peer = a.peers.getPtr(2).?;
    _ = std.os.linux.close(@intCast(peer.fd));
    peer.fd = -1;

    // Second send — must reconnect transparently.
    a.send(2, raft.Message{ .request_vote = .{ .term = 2, .candidate_id = 1, .last_log_index = 1, .last_log_term = 1 } });

    // The receiver now has two inbound connections: the stale one and the new one.
    // Poll until we receive the second message.
    var got_second = false;
    for (0..16) |_| {
        if (try b.pollOnce(alloc)) {
            if (b.inbox.items.len >= 2) {
                got_second = true;
                break;
            }
        }
    }
    try testing.expect(got_second);
    try testing.expectEqual(@as(u64, 2), b.inbox.items[1].msg.request_vote.term);
}

test "TcpTransport: bidirectional persistent connections" {
    // Property: both directions of a pair use independent persistent connections.
    // A→B messages don't interfere with B→A messages.
    const alloc = testing.allocator;

    var a = raft.TcpTransport.init(alloc, 1);
    defer a.deinit();
    var b = raft.TcpTransport.init(alloc, 2);
    defer b.deinit();

    try a.listen(0);
    try b.listen(0);
    const port_a = try a.boundPort();
    const port_b = try b.boundPort();

    const addr_a = try std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{port_a});
    defer alloc.free(addr_a);
    const addr_b = try std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{port_b});
    defer alloc.free(addr_b);

    try a.addPeer(2, addr_b);
    try b.addPeer(1, addr_a);

    a.send(2, raft.Message{ .request_vote = .{ .term = 10, .candidate_id = 1, .last_log_index = 0, .last_log_term = 0 } });
    b.send(1, raft.Message{ .request_vote_result = .{ .term = 10, .vote_granted = true } });

    try testing.expect(try a.pollOnce(alloc));
    try testing.expect(try b.pollOnce(alloc));

    try testing.expectEqual(@as(usize, 1), a.inbox.items.len);
    try testing.expectEqual(@as(usize, 1), b.inbox.items.len);

    try testing.expect(a.inbox.items[0].msg == .request_vote_result);
    try testing.expect(b.inbox.items[0].msg == .request_vote);
    try testing.expectEqual(@as(u64, 10), a.inbox.items[0].msg.request_vote_result.term);
    try testing.expectEqual(@as(u64, 10), b.inbox.items[0].msg.request_vote.term);
}
