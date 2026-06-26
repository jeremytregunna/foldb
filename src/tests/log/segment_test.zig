/// Unit tests for segment file handling.
const std = @import("std");
const testing = std.testing;
const log = @import("log.zig");

const Seq = log.Seq;
const NodeId = log.NodeId;
const LogEntry = log.LogEntry;
const EntryKind = log.EntryKind;
const TxnIntent = log.TxnIntent;
const SegmentHeader = log.SegmentHeader;
const SegmentFooter = log.SegmentFooter;
const IndexEntry = log.IndexEntry;
const header_size = log.header_size;
const footer_size = log.footer_size;

test "Segment: header fields are correct" {
    const base_seq: Seq = 42;
    const node_id: NodeId = 1;

    const created_at: i64 = 1_000_000;
    const header = SegmentHeader.init(base_seq, node_id, created_at);

    // Validate header fields
    try testing.expectEqualSlices(u8, &log.magic, &header.magic);
    try testing.expectEqual(@as(u32, 1), header.version);
    try testing.expectEqual(base_seq, header.base_seq);
    try testing.expectEqual(node_id, header.node_id);
    try testing.expect(header.part_id == 0);
    try testing.expectEqual(created_at, header.created_at);
}

test "Segment: footer fields are correct" {
    const entry_count: u32 = 100;
    const last_seq: Seq = 200;
    const index_offset: u64 = 1024;

    const footer = SegmentFooter.init(entry_count, last_seq, index_offset);

    // Validate footer fields
    try testing.expectEqual(entry_count, footer.entry_count);
    try testing.expectEqual(last_seq, footer.last_seq);
    try testing.expectEqual(index_offset, footer.index_offset);
}

test "Segment: index entry fields are correct" {
    const seq: Seq = 12345;
    const file_offset: u64 = 2048;

    const index_entry = IndexEntry{ .seq = seq, .file_offset = file_offset };

    try testing.expectEqual(seq, index_entry.seq);
    try testing.expectEqual(file_offset, index_entry.file_offset);
}

test "Segment: LogEntry creation" {
    const seq: Seq = 1;
    const epoch: u64 = 0;
    const payload = "test data";

    const entry = LogEntry.create(seq, epoch, .txn_intent, payload);

    try testing.expectEqual(seq, entry.header.seq);
    try testing.expectEqual(epoch, entry.header.epoch);
    try testing.expectEqual(@as(u32, @intCast(payload.len)), entry.header.payload_len);
    try testing.expectEqualSlices(u8, payload, entry.payload);
    try testing.expect(entry.verify_crc());
}

test "Segment: LogEntry sizes" {
    const payload = "hello";
    const entry = LogEntry.create(1, 0, .txn_intent, payload);

    const total_size = entry.total_size();
    try testing.expectEqual(@as(usize, 25) + payload.len, total_size);
}

test "Segment: CRC verification" {
    const payload = "test data for CRC verification";
    const entry = LogEntry.create(1, 0, .txn_intent, payload);

    try testing.expect(entry.verify_crc());
}

test "Segment: different entry kinds" {
    const txn_entry = LogEntry.create(1, 0, .txn_intent, "txn");
    const noop_entry = LogEntry.create(2, 0, .noop, "");
    const snapshot_entry = LogEntry.create(3, 0, .snapshot_marker, "snapshot");

    try testing.expectEqual(@as(u8, 1), @intFromEnum(txn_entry.header.kind));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(noop_entry.header.kind));
    try testing.expectEqual(@as(u8, 5), @intFromEnum(snapshot_entry.header.kind));
}

test "Segment: EntryKind fromByte" {
    const txn_kind = try EntryKind.fromByte(1);
    const noop_kind = try EntryKind.fromByte(4);
    const snapshot_kind = try EntryKind.fromByte(5);

    try testing.expectEqual(.txn_intent, txn_kind);
    try testing.expectEqual(.noop, noop_kind);
    try testing.expectEqual(.snapshot_marker, snapshot_kind);

    // Invalid kind should error
    const invalid_result = EntryKind.fromByte(99);
    try testing.expectError(error.InvalidEntryKind, invalid_result);
}

test "Segment: TxnIntent" {
    const payload = "transaction payload";
    const intent = TxnIntent.init_test(payload, 1, 1);

    try testing.expectEqualSlices(u8, payload, intent.ops[0].set.value);
}

test "Segment: IndexEntry size" {
    try testing.expectEqual(@sizeOf(Seq) + @sizeOf(u64), IndexEntry.entry_size);
}

test "Segment: header size constant" {
    try testing.expectEqual(@as(usize, 64), header_size);
}

test "Segment: footer size constant" {
    try testing.expectEqual(@as(usize, 64), footer_size);
}

test "Segment: SegmentFooter serialization round-trip" {
    const original = SegmentFooter.init(42, 999, 8192);
    var buf: [footer_size]u8 = undefined;
    original.serialize_to(&buf);
    const recovered = try SegmentFooter.deserialize_from(&buf);
    try testing.expectEqual(original.entry_count, recovered.entry_count);
    try testing.expectEqual(original.last_seq, recovered.last_seq);
    try testing.expectEqual(original.index_offset, recovered.index_offset);
    try testing.expectEqual(original.footer_crc, recovered.footer_crc);
}

test "Segment: SegmentFooter rejects corrupt data" {
    const footer = SegmentFooter.init(1, 1, 80);
    var buf: [footer_size]u8 = undefined;
    footer.serialize_to(&buf);
    buf[0] ^= 0xFF;
    try testing.expectError(error.CorruptSegmentFooter, SegmentFooter.deserialize_from(&buf));
}

test "Segment: IndexEntry serialization round-trip" {
    const ie = IndexEntry{ .seq = 12345, .file_offset = 9876543 };
    var buf: [IndexEntry.entry_size]u8 = undefined;
    ie.serialize_to(&buf);
    const recovered = IndexEntry.deserialize_from(&buf);
    try testing.expectEqual(ie.seq, recovered.seq);
    try testing.expectEqual(ie.file_offset, recovered.file_offset);
}

test "Segment: LogEntryHeader serialization round-trip" {
    const payload = "round-trip payload";
    const header = log.LogEntryHeader.init(7, 3, .txn_intent, payload);
    var buf: [log.LogEntryHeader.header_size]u8 = undefined;
    header.serialize_to(&buf);
    const recovered = try log.LogEntryHeader.deserialize_from(&buf);
    try testing.expectEqual(header.seq, recovered.seq);
    try testing.expectEqual(header.epoch, recovered.epoch);
    try testing.expectEqual(header.kind, recovered.kind);
    try testing.expectEqual(header.payload_len, recovered.payload_len);
    try testing.expectEqual(header.payload_crc, recovered.payload_crc);
}

test "Segment: SegmentHeader isValid rejects corruption" {
    var header = SegmentHeader.init(1, 42, 0);
    try testing.expect(header.is_valid());
    header.base_seq ^= 0xDEAD;
    try testing.expect(!header.is_valid());
}

test "Segment: SegmentHeader created_at is stored verbatim" {
    const ts: i64 = 42_000;
    const header = SegmentHeader.init(1, 99, ts);
    try testing.expectEqual(ts, header.created_at);
    try testing.expect(header.is_valid());
}

// Helpers for disk-level segment tests
fn toNullZSeg(path: []const u8) ![:0]u8 {
    const buf = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    @memcpy(buf[0..path.len], path);
    return buf;
}

fn makeSegPath() ![]u8 {
    // SAFETY: clock_gettime fills ts before any field is read.
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/seg_test_{d}.seg", .{ns});
}

fn removeFileSeg(path: []const u8) void {
    const z = toNullZSeg(path) catch return;
    defer std.heap.page_allocator.free(z);
    _ = std.os.linux.unlink(z.ptr);
}

test "Segment: disk round-trip (init, append, seal, open, read)" {
    const path = try makeSegPath();
    const path_for_cleanup = try std.heap.page_allocator.dupe(u8, path);
    defer {
        removeFileSeg(path_for_cleanup);
        std.heap.page_allocator.free(path_for_cleanup);
    }

    const payloads = [_][]const u8{ "alpha", "beta", "gamma" };

    {
        var seg = try log.Segment.init(path, 1, 99, 0, testing.allocator);
        for (payloads, 0..) |payload, i| {
            const entry = LogEntry.create(@intCast(i + 1), 0, .txn_intent, payload);
            try seg.append(entry);
        }
        try seg.seal();
        seg.deinit();
    }

    const path2 = try testing.allocator.dupe(u8, path_for_cleanup);
    var seg2 = try log.Segment.open(path2, testing.allocator);
    defer seg2.deinit();

    try testing.expectEqual(@as(u32, 3), seg2.entry_count);
    try testing.expectEqual(@as(Seq, 3), seg2.last_seq);
    try testing.expect(seg2.sealed);

    const entries = try seg2.read(1, 10, testing.allocator);
    defer {
        for (entries) |*e| e.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 3), entries.len);
    for (entries, 0..) |entry, i| {
        try testing.expectEqual(@as(Seq, @intCast(i + 1)), entry.header.seq);
        try testing.expectEqualSlices(u8, payloads[i], entry.payload);
        try testing.expect(entry.verify_crc());
    }
}

test "Segment: open unsealed segment recovers gracefully" {
    const path = try makeSegPath();
    const path_for_cleanup = try std.heap.page_allocator.dupe(u8, path);
    defer {
        removeFileSeg(path_for_cleanup);
        std.heap.page_allocator.free(path_for_cleanup);
    }

    {
        // Write header only — simulate crash before any entries or seal
        var seg = try log.Segment.init(path, 1, 1, 0, testing.allocator);
        // Do not seal, just deinit (simulates abrupt close)
        seg.deinit();
    }

    const path2 = try testing.allocator.dupe(u8, path_for_cleanup);
    var seg2 = try log.Segment.open(path2, testing.allocator);
    defer seg2.deinit();

    // Should open as unsealed with no entries
    try testing.expectEqual(@as(u32, 0), seg2.entry_count);
    try testing.expect(!seg2.sealed);
}

test "Segment: sealed segment rejects further appends" {
    const path = try makeSegPath();
    const path_for_cleanup = try std.heap.page_allocator.dupe(u8, path);
    defer {
        removeFileSeg(path_for_cleanup);
        std.heap.page_allocator.free(path_for_cleanup);
    }
    var seg = try log.Segment.init(path, 1, 1, 0, testing.allocator);
    defer seg.deinit();

    const first = LogEntry.create(1, 0, .txn_intent, "first entry");
    try seg.append(first);
    try seg.seal();
    const entry = LogEntry.create(2, 0, .txn_intent, "too late");
    try testing.expectError(error.SegmentSealed, seg.append(entry));
}
