/// Raft RPC message types and binary serialization.
///
/// Wire format for each message:
///   u32 total_len  (excludes this 4-byte length field)
///   u8  kind       (MessageKind tag)
///   ... fields     (little-endian)
///
/// AppendEntries entries are serialized as:
///   u32 entry_count
///   for each entry: u8[ENTRY_HEADER_SIZE] header | u32 payload_len | u8[payload_len] payload
const std = @import("std");
const log_mod = @import("log.zig");
const types = @import("types.zig");

pub const Term = types.Term;
pub const NodeId = log_mod.NodeId;
pub const Seq = log_mod.Seq;
pub const LogEntry = log_mod.LogEntry;
pub const LogEntryHeader = log_mod.LogEntryHeader;
pub const ENTRY_HEADER_SIZE = log_mod.ENTRY_HEADER_SIZE;

pub const MessageKind = enum(u8) {
    append_entries = 1,
    append_entries_result = 2,
    request_vote = 3,
    request_vote_result = 4,
};

pub const AppendEntriesArgs = struct {
    term: Term,
    leader_id: NodeId,
    prev_log_index: Seq,
    prev_log_term: Term,
    entries: []const LogEntry,
    leader_commit: Seq,
};

pub const AppendEntriesResult = struct {
    term: Term,
    success: bool,
    match_index: Seq,
};

pub const RequestVoteArgs = struct {
    term: Term,
    candidate_id: NodeId,
    last_log_index: Seq,
    last_log_term: Term,
};

pub const RequestVoteResult = struct {
    term: Term,
    vote_granted: bool,
};

pub const Message = union(MessageKind) {
    append_entries: AppendEntriesArgs,
    append_entries_result: AppendEntriesResult,
    request_vote: RequestVoteArgs,
    request_vote_result: RequestVoteResult,
};

// ---------------------------------------------------------------------------
// Fixed-size serialization for message types that carry no entries.
// AppendEntriesArgs with entries is handled separately by the cluster driver.
// ---------------------------------------------------------------------------

pub fn serializeRequestVoteArgs(args: RequestVoteArgs, buf: *[32]u8) void {
    std.mem.writeInt(u64, buf[0..8], args.term, .little);
    std.mem.writeInt(u64, buf[8..16], args.candidate_id, .little);
    std.mem.writeInt(u64, buf[16..24], args.last_log_index, .little);
    std.mem.writeInt(u64, buf[24..32], args.last_log_term, .little);
}

pub fn deserializeRequestVoteArgs(buf: *const [32]u8) RequestVoteArgs {
    return .{
        .term = std.mem.readInt(u64, buf[0..8], .little),
        .candidate_id = std.mem.readInt(u64, buf[8..16], .little),
        .last_log_index = std.mem.readInt(u64, buf[16..24], .little),
        .last_log_term = std.mem.readInt(u64, buf[24..32], .little),
    };
}

pub fn serializeRequestVoteResult(result: RequestVoteResult, buf: *[9]u8) void {
    std.mem.writeInt(u64, buf[0..8], result.term, .little);
    buf[8] = if (result.vote_granted) 1 else 0;
}

pub fn deserializeRequestVoteResult(buf: *const [9]u8) RequestVoteResult {
    return .{
        .term = std.mem.readInt(u64, buf[0..8], .little),
        .vote_granted = buf[8] != 0,
    };
}

pub fn serializeAppendEntriesResult(result: AppendEntriesResult, buf: *[17]u8) void {
    std.mem.writeInt(u64, buf[0..8], result.term, .little);
    buf[8] = if (result.success) 1 else 0;
    std.mem.writeInt(u64, buf[9..17], result.match_index, .little);
}

pub fn deserializeAppendEntriesResult(buf: *const [17]u8) AppendEntriesResult {
    return .{
        .term = std.mem.readInt(u64, buf[0..8], .little),
        .success = buf[8] != 0,
        .match_index = std.mem.readInt(u64, buf[9..17], .little),
    };
}

/// Serialize AppendEntriesArgs header fields (40 bytes, excluding entries).
pub fn serializeAppendEntriesHeader(args: AppendEntriesArgs, buf: *[40]u8) void {
    std.mem.writeInt(u64, buf[0..8], args.term, .little);
    std.mem.writeInt(u64, buf[8..16], args.leader_id, .little);
    std.mem.writeInt(u64, buf[16..24], args.prev_log_index, .little);
    std.mem.writeInt(u64, buf[24..32], args.prev_log_term, .little);
    std.mem.writeInt(u64, buf[32..40], args.leader_commit, .little);
}

pub fn deserializeAppendEntriesHeader(buf: *const [40]u8) AppendEntriesArgs {
    return .{
        .term = std.mem.readInt(u64, buf[0..8], .little),
        .leader_id = std.mem.readInt(u64, buf[8..16], .little),
        .prev_log_index = std.mem.readInt(u64, buf[16..24], .little),
        .prev_log_term = std.mem.readInt(u64, buf[24..32], .little),
        .leader_commit = std.mem.readInt(u64, buf[32..40], .little),
        .entries = &.{},
    };
}
