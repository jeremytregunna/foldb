/// Seq-based debug affordance.
///
/// Given a seq, look up the raw log entry and decode it into a human-readable
/// description. Because execution is deterministic, this is reproducible on
/// any node that has the log prefix up to seq.
///
/// Spec §13.4: "given a seq, the system can dump the exact TxnIntent, the
/// state it read, and the mutations it produced."
///
/// This module covers the first part (TxnIntent dump). Re-executing to capture
/// reads + mutations requires invoking the executor against a snapshot — that
/// path is wired in the Executor itself.
const std = @import("std");

const assert = std.debug.assert;

/// Decoded description of a single log entry at a given seq.
pub const SeqDescription = struct {
    seq: u64,
    epoch: u64,
    kind: EntryKindTag,
    /// For txn_intent entries: decoded fields.
    txn: ?TxnSummary,
    /// Raw payload bytes (allocated; caller frees).
    raw_payload: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SeqDescription) void {
        self.allocator.free(self.raw_payload);
        if (self.txn) |*t| t.deinit(self.allocator);
    }
};

/// Non-exhaustive: values 7–254 and any future kinds are held as raw integer
/// values in the enum. Use @intFromEnum / @enumFromInt at boundaries.
/// Value 255 is intentionally unassigned to avoid a common "catch-all" sentinel
/// that would silently swallow unrecognised tags.
pub const EntryKindTag = enum(u8) {
    txn_intent = 1,
    schema_change = 2,
    config_change = 3,
    noop = 4,
    snapshot_marker = 5,
    epoch_decision = 6,
    _, // non-exhaustive: future kinds are valid without an enum update
};

pub const TxnSummary = struct {
    query_hash: [32]u8,
    client_id: u64,
    client_seq: u64,
    params_len: u32,
    read_partition_count: u32,
    write_partition_count: u32,
    nondet_count: u32,

    pub fn deinit(self: *TxnSummary) void {
        _ = self;
    }

    pub fn format(
        self: TxnSummary,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            "TxnSummary{{ client={d} seq={d} params_len={d} r_parts={d} w_parts={d} nondet={d} hash={} }}",
            .{
                self.client_id,
                self.client_seq,
                self.params_len,
                self.read_partition_count,
                self.write_partition_count,
                self.nondet_count,
                std.fmt.fmtSliceHexLower(&self.query_hash),
            },
        );
    }
};

/// Log interface needed by describeSeq — avoids a hard import of the log module.
/// readFn must return entries in ascending seq order and only return an entry
/// whose seq matches the requested seq exactly.
pub const LogReader = struct {
    ptr: *anyopaque,
    readFn: *const fn (*anyopaque, seq: u64, max: u32, alloc: std.mem.Allocator) anyerror![]LogEntryOpaque,
};

/// Opaque log entry representation passed from the log module.
pub const LogEntryOpaque = struct {
    seq: u64,
    epoch: u64,
    kind_byte: u8,
    payload: []const u8,

    pub fn deinit(self: *LogEntryOpaque, alloc: std.mem.Allocator) void {
        alloc.free(self.payload);
    }
};

/// Describe a single log entry at `seq`. Returns null if seq is not found.
pub fn describeSeq(
    log: LogReader,
    seq: u64,
    allocator: std.mem.Allocator,
) !?SeqDescription {
    assert(seq > 0); // seq 0 is not a valid log position

    const entries = try log.readFn(log.ptr, seq, 1, allocator);
    defer {
        for (entries) |*e| {
            var entry = e.*;
            entry.deinit(allocator);
        }
        allocator.free(entries);
    }

    if (entries.len == 0) return null;
    // readFn contract: when it returns an entry it must match the requested seq.
    assert(entries[0].seq == seq);

    const entry = entries[0];
    const raw_payload = try allocator.dupe(u8, entry.payload);
    errdefer allocator.free(raw_payload);

    const kind_tag: EntryKindTag = @enumFromInt(entry.kind_byte);

    const txn: ?TxnSummary = if (kind_tag == .txn_intent)
        decodeTxnSummary(entry.payload)
    else
        null;

    return SeqDescription{
        .seq = entry.seq,
        .epoch = entry.epoch,
        .kind = kind_tag,
        .txn = txn,
        .raw_payload = raw_payload,
        .allocator = allocator,
    };
}

/// Decode just the header fields of a TxnIntent payload without full deserialization.
fn decodeTxnSummary(payload: []const u8) ?TxnSummary {
    // TxnIntent header layout (little-endian):
    //   query_hash(32) + client_id(8) + client_seq(8) +
    //   read_count(4) + write_count(4) + params_len(4) + nondet_count(4) = 64 bytes.
    const HEADER: u32 = 64;
    comptime {
        assert(HEADER == 32 + 8 + 8 + 4 + 4 + 4 + 4);
    }

    if (payload.len < HEADER) return null;
    assert(payload.len >= HEADER); // paired: guaranteed by the early return above

    var query_hash: [32]u8 = undefined;
    @memcpy(&query_hash, payload[0..32]);
    const client_id = std.mem.readInt(u64, payload[32..40], .little);
    const client_seq = std.mem.readInt(u64, payload[40..48], .little);
    const read_count = std.mem.readInt(u32, payload[48..52], .little);
    const write_count = std.mem.readInt(u32, payload[52..56], .little);
    const params_len = std.mem.readInt(u32, payload[56..60], .little);
    const nondet_count = std.mem.readInt(u32, payload[60..64], .little);

    return TxnSummary{
        .query_hash = query_hash,
        .client_id = client_id,
        .client_seq = client_seq,
        .params_len = params_len,
        .read_partition_count = read_count,
        .write_partition_count = write_count,
        .nondet_count = nondet_count,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "decodeTxnSummary: valid header" {
    var payload = [_]u8{0} ** 64;
    // client_id = 7
    std.mem.writeInt(u64, payload[32..40], 7, .little);
    // client_seq = 42
    std.mem.writeInt(u64, payload[40..48], 42, .little);
    // params_len = 100
    std.mem.writeInt(u32, payload[56..60], 100, .little);

    const summary = decodeTxnSummary(&payload) orelse return error.NullSummary;
    try std.testing.expectEqual(@as(u64, 7), summary.client_id);
    try std.testing.expectEqual(@as(u64, 42), summary.client_seq);
    try std.testing.expectEqual(@as(u32, 100), summary.params_len);
}

test "decodeTxnSummary: too short returns null" {
    const payload = [_]u8{0} ** 10;
    const summary = decodeTxnSummary(&payload);
    try std.testing.expect(summary == null);
}
