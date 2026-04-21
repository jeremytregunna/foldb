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

/// A message in flight between two Raft nodes.
pub const Envelope = struct {
    from: NodeId,
    to: NodeId,
    msg: Message,
};

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

// ---------------------------------------------------------------------------
// Full message encode/decode for TCP transport.
//
// Wire layout:
//   u32 total_len  (LE, does NOT include itself; covers from_id + kind + payload)
//   u64 from_id    (LE)
//   u8  kind       (MessageKind)
//   ... payload    (little-endian fields)
//
// AppendEntries payload:
//   u8[40]  header fields
//   u32     entry_count
//   for each entry: u8[25] LogEntryHeader + u32 payload_len + u8[payload_len] payload
// ---------------------------------------------------------------------------

/// Serialize a Message into `buf`, prepending a 4-byte length prefix, 8-byte from_id,
/// and 1-byte kind tag. Allocates entry payloads via `alloc` only for AppendEntries.
pub fn encodeMessage(from_id: NodeId, msg: Message, buf: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    // Reserve 4 bytes for length prefix (filled in at the end).
    const len_pos = buf.items.len;
    try buf.appendNTimes(alloc, 0, 4);

    // from_id
    var from_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &from_buf, from_id, .little);
    try buf.appendSlice(alloc, &from_buf);

    // kind + payload
    switch (msg) {
        .request_vote => |a| {
            try buf.append(alloc, @intFromEnum(MessageKind.request_vote));
            var payload: [32]u8 = undefined;
            serializeRequestVoteArgs(a, &payload);
            try buf.appendSlice(alloc, &payload);
        },
        .request_vote_result => |r| {
            try buf.append(alloc, @intFromEnum(MessageKind.request_vote_result));
            var payload: [9]u8 = undefined;
            serializeRequestVoteResult(r, &payload);
            try buf.appendSlice(alloc, &payload);
        },
        .append_entries_result => |r| {
            try buf.append(alloc, @intFromEnum(MessageKind.append_entries_result));
            var payload: [17]u8 = undefined;
            serializeAppendEntriesResult(r, &payload);
            try buf.appendSlice(alloc, &payload);
        },
        .append_entries => |a| {
            try buf.append(alloc, @intFromEnum(MessageKind.append_entries));
            var hdr: [40]u8 = undefined;
            serializeAppendEntriesHeader(a, &hdr);
            try buf.appendSlice(alloc, &hdr);
            var entry_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &entry_count_buf, @intCast(a.entries.len), .little);
            try buf.appendSlice(alloc, &entry_count_buf);
            for (a.entries) |entry| {
                var eh: [ENTRY_HEADER_SIZE]u8 = undefined;
                entry.header.serializeTo(&eh);
                try buf.appendSlice(alloc, &eh);
                var pl_len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &pl_len_buf, @intCast(entry.payload.len), .little);
                try buf.appendSlice(alloc, &pl_len_buf);
                try buf.appendSlice(alloc, entry.payload);
            }
        },
    }

    // Fill in length prefix (total_len = everything after the 4-byte prefix).
    const total_len: u32 = @intCast(buf.items.len - len_pos - 4);
    std.mem.writeInt(u32, buf.items[len_pos..][0..4], total_len, .little);
}

/// Decode a Message from a raw byte slice (not including the 4-byte length prefix).
/// Layout: u64 from_id | u8 kind | ... payload
/// Caller owns any allocated entry payloads.
pub fn decodeMessage(data: []const u8, alloc: std.mem.Allocator) !Envelope {
    if (data.len < 9) return error.MessageTooShort;
    const from_id = std.mem.readInt(u64, data[0..8], .little);
    const kind_byte = data[8];
    const payload = data[9..];

    const msg: Message = switch (kind_byte) {
        @intFromEnum(MessageKind.request_vote) => blk: {
            if (payload.len < 32) return error.MessageTooShort;
            break :blk .{ .request_vote = deserializeRequestVoteArgs(payload[0..32]) };
        },
        @intFromEnum(MessageKind.request_vote_result) => blk: {
            if (payload.len < 9) return error.MessageTooShort;
            break :blk .{ .request_vote_result = deserializeRequestVoteResult(payload[0..9]) };
        },
        @intFromEnum(MessageKind.append_entries_result) => blk: {
            if (payload.len < 17) return error.MessageTooShort;
            break :blk .{ .append_entries_result = deserializeAppendEntriesResult(payload[0..17]) };
        },
        @intFromEnum(MessageKind.append_entries) => blk: {
            if (payload.len < 44) return error.MessageTooShort;
            var args = deserializeAppendEntriesHeader(payload[0..40]);
            const entry_count = std.mem.readInt(u32, payload[40..44], .little);
            const entries = try alloc.alloc(LogEntry, entry_count);
            errdefer alloc.free(entries);
            var pos: usize = 44;
            var n_init: usize = 0;
            errdefer for (entries[0..n_init]) |*e| e.deinit(alloc);
            for (0..entry_count) |i| {
                if (pos + ENTRY_HEADER_SIZE + 4 > payload.len) return error.MessageTooShort;
                const eh = try LogEntryHeader.deserializeFrom(payload[pos..][0..ENTRY_HEADER_SIZE]);
                pos += ENTRY_HEADER_SIZE;
                const pl_len = std.mem.readInt(u32, payload[pos..][0..4], .little);
                pos += 4;
                if (pos + pl_len > payload.len) return error.MessageTooShort;
                const ep = try alloc.dupe(u8, payload[pos..][0..pl_len]);
                pos += pl_len;
                entries[i] = .{ .header = eh, .payload = ep };
                n_init += 1;
            }
            args.entries = entries;
            break :blk .{ .append_entries = args };
        },
        else => return error.UnknownMessageKind,
    };
    return .{ .from = from_id, .to = 0, .msg = msg };
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
