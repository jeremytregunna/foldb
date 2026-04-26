/// Core types for the Sequencer: epoch decisions, ordering entries, submit results.
const std = @import("std");
const log_mod = @import("log.zig");

const assert = std.debug.assert;

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
/// entry_kind and payload are included so all nodes can write to their partition
/// logs directly from the committed Raft entry without a separate data channel.
/// payload is NOT owned by this struct — it is a slice into the serialized bytes
/// when deserialized, or into the caller's buffer when constructed for serialization.
pub const EpochDecision = struct {
    epoch_num: EpochNum,
    entries: []const OrderingEntry,
    entry_kind: log_mod.EntryKind = .txn_intent,
    payload: []const u8 = &.{},
};

/// A gateway-submitted entry that has crossed the sequencer's input boundary.
/// The intent_payload is opaque to the sequencer — its content was validated by the
/// gateway before submission. entry_kind tells the sequencer what kind of partition
/// log entry to write (txn_intent for DML, schema_change for DDL).
pub const ValidatedSubmit = struct {
    client_id: u64,
    client_seq: u64,
    intent_payload: []const u8,
    entry_kind: log_mod.EntryKind = .txn_intent,
};

/// Committed position of a submitted intent.
pub const SubmitResult = struct {
    seq: Seq,
    partition: PartitionId,
};

/// In-flight submit: allocated by the caller (gateway, stack), written by the Sequencer thread.
/// The done flag is the handoff point — the Sequencer sets it only after result/err are written.
pub const PendingSubmit = struct {
    submit: ValidatedSubmit,
    result: SubmitResult,
    err: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
    /// Intrusive MPSC queue link. Written by the queue; callers must not touch this field.
    next: std.atomic.Value(?*PendingSubmit) = .init(null),
};

/// Maximum spins before returning CommitTimeout (spin-wait fallback path).
const AWAIT_MAX_SPINS: u32 = 100_000_000;
/// Maximum 1ms sleeps before CommitTimeout (async fiber path, ~30 s).
const AWAIT_MAX_RETRIES: u32 = 30_000;

/// Handle returned by Sequencer.submitBytes().
pub const SubmitHandle = struct {
    pending: *PendingSubmit,

    /// Wait for the Sequencer thread to commit this entry.
    ///
    /// When `io` is non-null the fiber suspends via io.sleep(1 ms) between
    /// checks so other connection fibers can run during the Raft round-trip.
    /// When `io` is null the function falls back to sched_yield spinning (safe
    /// on dedicated sequencer-test threads that have no fiber scheduler).
    pub fn awaitCommit(self: *const SubmitHandle, io: ?std.Io) !SubmitResult {
        if (io) |the_io| {
            var retries: u32 = 0;
            while (!self.pending.done.load(.acquire)) {
                if (retries >= AWAIT_MAX_RETRIES) return error.CommitTimeout;
                retries += 1;
                try the_io.sleep(.{ .nanoseconds = 1_000_000 }, .awake);
            }
        } else {
            var spins: u32 = 0;
            while (!self.pending.done.load(.acquire)) {
                if (spins >= AWAIT_MAX_SPINS) return error.CommitTimeout;
                spins += 1;
                _ = std.os.linux.sched_yield();
            }
        }
        if (self.pending.err) |e| return e;
        return self.pending.result;
    }
};

// --- EpochDecision wire format ---
//
// Layout:
//   epoch_num:    u64 le  (8 bytes)
//   entry_count:  u32 le  (4 bytes)
//   entries:      [entry_count]OrderingEntryRecord (each 28 bytes)
//   entry_kind:   u8      (1 byte)
//   payload_len:  u32 le  (4 bytes)
//   payload:      [payload_len]u8
//
// OrderingEntryRecord: seq(8) + partition(4) + client_id(8) + client_seq(8) = 28 bytes
//
// entry_kind and payload allow all nodes to write the data entry to their local
// partition log directly from the committed Raft entry.

pub const ORDERING_ENTRY_SIZE: u32 = 28;

comptime {
    assert(ORDERING_ENTRY_SIZE == 8 + 4 + 8 + 8);
}

pub fn serializeEpochDecision(
    decision: EpochDecision,
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
) !void {
    assert(decision.entries.len <= std.math.maxInt(u32));
    assert(decision.payload.len <= std.math.maxInt(u32));

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

    // Payload section
    try out.append(alloc, @intFromEnum(decision.entry_kind));
    var plen_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &plen_buf, @intCast(decision.payload.len), .little);
    try out.appendSlice(alloc, &plen_buf);
    try out.appendSlice(alloc, decision.payload);
}

/// Domain boundary — deserializes Raft-replicated ordering decision bytes into a
/// proven-valid EpochDecision. Called when applying committed Raft entries; validates
/// structure and length before the sequencer core acts on the decision.
/// entries is alloc-owned (caller must free); payload is a non-owned slice into bytes.
pub fn deserializeEpochDecision(bytes: []const u8, alloc: std.mem.Allocator) !EpochDecision {
    if (bytes.len < 12) return error.InvalidPayload;

    const epoch_num = std.mem.readInt(u64, bytes[0..8], .little);
    const entry_count = std.mem.readInt(u32, bytes[8..12], .little);

    const entries_end = 12 + @as(usize, entry_count) * ORDERING_ENTRY_SIZE;
    // Minimum: entries + kind(1) + payload_len(4)
    if (bytes.len < entries_end + 5) return error.InvalidPayload;

    const entries = try alloc.alloc(OrderingEntry, entry_count);
    errdefer alloc.free(entries);

    for (0..entry_count) |i| {
        const base = 12 + i * ORDERING_ENTRY_SIZE;
        entries[i] = .{
            .seq = std.mem.readInt(u64, bytes[base..][0..8], .little),
            .partition = std.mem.readInt(u32, bytes[base + 8 ..][0..4], .little),
            .client_id = std.mem.readInt(u64, bytes[base + 12 ..][0..8], .little),
            .client_seq = std.mem.readInt(u64, bytes[base + 20 ..][0..8], .little),
        };
    }

    const kind_byte = bytes[entries_end];
    const entry_kind = log_mod.EntryKind.fromByte(kind_byte) catch return error.InvalidPayload;
    const payload_len = std.mem.readInt(u32, bytes[entries_end + 1 ..][0..4], .little);
    const payload_start = entries_end + 5;
    if (bytes.len < payload_start + payload_len) return error.InvalidPayload;

    return .{
        .epoch_num = epoch_num,
        .entries = entries,
        .entry_kind = entry_kind,
        .payload = bytes[payload_start .. payload_start + payload_len],
    };
}
