/// Log entry types and serialization for Foldb's write-ahead log.
const std = @import("std");
const crc = @import("crc.zig");

/// Sequence number type - monotonically increasing per node.
pub const Seq = u64;

/// Epoch type - identifies the current leader/epoch.
pub const Epoch = u64;

/// Node identifier type.
pub const NodeId = u64;

/// Type of log entry.
pub const EntryKind = enum(u8) {
    txn_intent = 1,
    noop = 4,
    snapshot_marker = 5,

    pub fn fromByte(byte: u8) !EntryKind {
        return switch (byte) {
            1 => .txn_intent,
            4 => .noop,
            5 => .snapshot_marker,
            else => error.InvalidEntryKind,
        };
    }
};

/// Transaction intent payload.
pub const TxnIntent = struct {
    payload: []const u8,

    pub fn init(payload: []const u8) TxnIntent {
        return .{ .payload = payload };
    }
};

/// Log entry header - fixed 25 bytes on disk (little-endian):
/// seq(8) epoch(8) kind(1) payload_len(4) payload_crc(4)
pub const LogEntryHeader = struct {
    seq: Seq,
    epoch: Epoch,
    kind: EntryKind,
    payload_len: u32,
    payload_crc: u32,

    pub const HEADER_SIZE: usize = 8 + 8 + 1 + 4 + 4; // 25

    pub fn init(seq: Seq, epoch: Epoch, kind: EntryKind, payload: []const u8) LogEntryHeader {
        return .{
            .seq = seq,
            .epoch = epoch,
            .kind = kind,
            .payload_len = @intCast(payload.len),
            .payload_crc = crc.crc32c(payload),
        };
    }

    pub fn serializeTo(self: LogEntryHeader, buf: []u8) void {
        std.mem.writeInt(u64, buf[0..8], self.seq, .little);
        std.mem.writeInt(u64, buf[8..16], self.epoch, .little);
        buf[16] = @intFromEnum(self.kind);
        std.mem.writeInt(u32, buf[17..21], self.payload_len, .little);
        std.mem.writeInt(u32, buf[21..25], self.payload_crc, .little);
    }

    pub fn deserializeFrom(buf: []const u8) !LogEntryHeader {
        if (buf.len < HEADER_SIZE) return error.EndOfStream;
        const seq = std.mem.readInt(u64, buf[0..8], .little);
        const epoch = std.mem.readInt(u64, buf[8..16], .little);
        const kind = try EntryKind.fromByte(buf[16]);
        const payload_len = std.mem.readInt(u32, buf[17..21], .little);
        const payload_crc = std.mem.readInt(u32, buf[21..25], .little);
        return .{ .seq = seq, .epoch = epoch, .kind = kind, .payload_len = payload_len, .payload_crc = payload_crc };
    }
};

/// Complete log entry including header and payload.
pub const LogEntry = struct {
    header: LogEntryHeader,
    payload: []const u8,

    pub fn init(header: LogEntryHeader, payload: []const u8) LogEntry {
        return .{ .header = header, .payload = payload };
    }

    pub fn create(seq: Seq, epoch: Epoch, kind: EntryKind, payload: []const u8) LogEntry {
        return .{ .header = LogEntryHeader.init(seq, epoch, kind, payload), .payload = payload };
    }

    pub fn totalSize(self: LogEntry) usize {
        return LogEntryHeader.HEADER_SIZE + self.payload.len;
    }

    pub fn serializeTo(self: LogEntry, buf: []u8) void {
        self.header.serializeTo(buf[0..LogEntryHeader.HEADER_SIZE]);
        @memcpy(buf[LogEntryHeader.HEADER_SIZE..][0..self.payload.len], self.payload);
    }

    /// Deserializes a complete entry from a file descriptor.
    pub fn deserializeFd(fd: std.posix.fd_t, allocator: std.mem.Allocator) !LogEntry {
        var header_buf: [LogEntryHeader.HEADER_SIZE]u8 = undefined;
        const n = std.os.linux.read(@intCast(fd), &header_buf, LogEntryHeader.HEADER_SIZE);
        if (n != LogEntryHeader.HEADER_SIZE) return error.EndOfStream;

        const header = try LogEntryHeader.deserializeFrom(&header_buf);
        if (header.payload_len > 1024 * 1024) return error.InvalidPayloadLength;

        const payload = try allocator.alloc(u8, header.payload_len);
        errdefer allocator.free(payload);

        if (header.payload_len > 0) {
            const pn = std.os.linux.read(@intCast(fd), payload.ptr, header.payload_len);
            if (pn != header.payload_len) return error.EndOfStream;
        }

        return .{ .header = header, .payload = payload };
    }

    pub fn verifyCrc(self: LogEntry) bool {
        return crc.crc32c(self.payload) == self.header.payload_crc;
    }

    pub fn deinit(self: *LogEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
    }
};
