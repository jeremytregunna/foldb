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
