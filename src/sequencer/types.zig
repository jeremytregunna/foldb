/// Core types for the Sequencer: epoch decisions, ordering entries, submit results.
const std = @import("std");
const log_mod = @import("log.zig");

pub const Seq = log_mod.Seq;
pub const PartitionId = log_mod.PartitionId;

pub const EpochNum = u64;

/// One entry in an epoch: a single TxnIntent assigned a global seq and routed to a partition.
pub const OrderingEntry = struct {
    seq: Seq,
    partition: PartitionId,
    client_id: u64,
    client_seq: u64,
};

/// The ordering decision for one epoch — what the Sequencer replicates via Raft.
pub const EpochDecision = struct {
    epoch_num: EpochNum,
    entries: []const OrderingEntry,
};

/// A gateway-submitted TxnIntent that has crossed the sequencer's input boundary.
/// The intent_payload is opaque to the sequencer — its content was validated by the
/// gateway before submission. The sequencer treats it as an ordered, opaque blob.
pub const ValidatedSubmit = struct {
    client_id: u64,
    client_seq: u64,
    intent_payload: []const u8,
};

/// Committed position of a submitted intent.
pub const SubmitResult = struct {
    seq: Seq,
    partition: PartitionId,
};

/// Handle returned by Sequencer.submitBytes(). submit() is infallible; errors surface on
/// awaitCommit(). For M7 single-node, io.async executes synchronously so await returns
/// immediately. Multi-node Raft will block here until the ordering decision is durable.
pub const SubmitHandle = struct {
    future: std.Io.Future(anyerror!SubmitResult),

    pub fn awaitCommit(self: *SubmitHandle, io: std.Io) !SubmitResult {
        return self.future.await(io);
    }
};

// --- EpochDecision wire format ---
//
// Layout:
//   epoch_num: u64 (8 bytes)
//   entry_count: u32 (4 bytes)
//   entries: [entry_count]OrderingEntryRecord (each 24 bytes)
//
// OrderingEntryRecord: seq(8) + partition(4) + client_id(8) + client_seq(8) = 28 bytes

pub const ORDERING_ENTRY_SIZE: usize = 28;

pub fn serializeEpochDecision(
    decision: EpochDecision,
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
) !void {
    var epoch_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &epoch_buf, decision.epoch_num, .little);
    try out.appendSlice(alloc, &epoch_buf);

    var count_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_buf, @intCast(decision.entries.len), .little);
    try out.appendSlice(alloc, &count_buf);

    for (decision.entries) |e| {
        var seq_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq_buf, e.seq, .little);
        try out.appendSlice(alloc, &seq_buf);

        var part_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &part_buf, e.partition, .little);
        try out.appendSlice(alloc, &part_buf);

        var cid_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &cid_buf, e.client_id, .little);
        try out.appendSlice(alloc, &cid_buf);

        var cseq_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &cseq_buf, e.client_seq, .little);
        try out.appendSlice(alloc, &cseq_buf);
    }
}

/// Domain boundary — deserializes Raft-replicated ordering decision bytes into a
/// proven-valid EpochDecision. Called when applying committed Raft entries; validates
/// structure and length before the sequencer core acts on the decision.
pub fn deserializeEpochDecision(payload: []const u8, alloc: std.mem.Allocator) !EpochDecision {
    if (payload.len < 12) return error.InvalidPayload;

    const epoch_num = std.mem.readInt(u64, payload[0..8], .little);
    const entry_count = std.mem.readInt(u32, payload[8..12], .little);

    const required_len = 12 + @as(usize, entry_count) * ORDERING_ENTRY_SIZE;
    if (payload.len < required_len) return error.InvalidPayload;

    const entries = try alloc.alloc(OrderingEntry, entry_count);
    errdefer alloc.free(entries);

    for (0..entry_count) |i| {
        const base = 12 + i * ORDERING_ENTRY_SIZE;
        entries[i] = .{
            .seq = std.mem.readInt(u64, payload[base..][0..8], .little),
            .partition = std.mem.readInt(u32, payload[base + 8 ..][0..4], .little),
            .client_id = std.mem.readInt(u64, payload[base + 12 ..][0..8], .little),
            .client_seq = std.mem.readInt(u64, payload[base + 20 ..][0..8], .little),
        };
    }

    return .{ .epoch_num = epoch_num, .entries = entries };
}
