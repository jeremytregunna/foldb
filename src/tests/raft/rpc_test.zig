/// Serialization round-trip tests for Raft RPC message types.
const std = @import("std");
const testing = std.testing;
const raft = @import("raft.zig");

test "RPC: RequestVoteArgs round-trip" {
    const original = raft.RequestVoteArgs{
        .term = 7,
        .candidate_id = 3,
        .last_log_index = 42,
        .last_log_term = 6,
    };
    var buf: [32]u8 = undefined;
    raft.serializeRequestVoteArgs(original, &buf);
    const recovered = raft.deserializeRequestVoteArgs(&buf);
    try testing.expectEqual(original.term, recovered.term);
    try testing.expectEqual(original.candidate_id, recovered.candidate_id);
    try testing.expectEqual(original.last_log_index, recovered.last_log_index);
    try testing.expectEqual(original.last_log_term, recovered.last_log_term);
}

test "RPC: RequestVoteResult granted" {
    const original = raft.RequestVoteResult{ .term = 5, .vote_granted = true };
    var buf: [9]u8 = undefined;
    raft.serializeRequestVoteResult(original, &buf);
    const recovered = raft.deserializeRequestVoteResult(&buf);
    try testing.expectEqual(original.term, recovered.term);
    try testing.expect(recovered.vote_granted);
}

test "RPC: RequestVoteResult denied" {
    const original = raft.RequestVoteResult{ .term = 3, .vote_granted = false };
    var buf: [9]u8 = undefined;
    raft.serializeRequestVoteResult(original, &buf);
    const recovered = raft.deserializeRequestVoteResult(&buf);
    try testing.expectEqual(original.term, recovered.term);
    try testing.expect(!recovered.vote_granted);
}

test "RPC: AppendEntriesResult success" {
    const original = raft.AppendEntriesResult{ .term = 2, .success = true, .match_index = 100 };
    var buf: [17]u8 = undefined;
    raft.serializeAppendEntriesResult(original, &buf);
    const recovered = raft.deserializeAppendEntriesResult(&buf);
    try testing.expectEqual(original.term, recovered.term);
    try testing.expect(recovered.success);
    try testing.expectEqual(original.match_index, recovered.match_index);
}

test "RPC: AppendEntriesResult failure" {
    const original = raft.AppendEntriesResult{ .term = 4, .success = false, .match_index = 5 };
    var buf: [17]u8 = undefined;
    raft.serializeAppendEntriesResult(original, &buf);
    const recovered = raft.deserializeAppendEntriesResult(&buf);
    try testing.expectEqual(original.term, recovered.term);
    try testing.expect(!recovered.success);
    try testing.expectEqual(original.match_index, recovered.match_index);
}

test "RPC: AppendEntriesArgs header round-trip" {
    const original = raft.AppendEntriesArgs{
        .term = 9,
        .leader_id = 1,
        .prev_log_index = 50,
        .prev_log_term = 8,
        .entries = &.{},
        .leader_commit = 48,
    };
    var buf: [40]u8 = undefined;
    raft.serializeAppendEntriesHeader(original, &buf);
    const recovered = raft.deserializeAppendEntriesHeader(&buf);
    try testing.expectEqual(original.term, recovered.term);
    try testing.expectEqual(original.leader_id, recovered.leader_id);
    try testing.expectEqual(original.prev_log_index, recovered.prev_log_index);
    try testing.expectEqual(original.prev_log_term, recovered.prev_log_term);
    try testing.expectEqual(original.leader_commit, recovered.leader_commit);
}

test "RPC: MessageKind tag values are stable" {
    try testing.expectEqual(@as(u8, 1), @intFromEnum(raft.MessageKind.append_entries));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(raft.MessageKind.append_entries_result));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(raft.MessageKind.request_vote));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(raft.MessageKind.request_vote_result));
}
