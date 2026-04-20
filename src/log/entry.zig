/// Log entry types and serialization for Foldb's write-ahead log.
const std = @import("std");
const crc = @import("crc.zig");

/// Sequence number type - monotonically increasing per node.
pub const Seq = u64;

/// Epoch type - identifies the current leader/epoch.
pub const Epoch = u64;

/// Node identifier type.
pub const NodeId = u64;

/// Partition identifier type - 0..N-1, fixed at cluster creation.
pub const PartitionId = u32;

/// Query hash type - BLAKE3 of canonicalized query AST.
pub const QueryHash = [32]u8;

/// Type of log entry.
pub const EntryKind = enum(u8) {
    txn_intent = 1,
    schema_change = 2,
    config_change = 3,
    noop = 4,
    snapshot_marker = 5,
    epoch_decision = 6,

    pub fn fromByte(byte: u8) !EntryKind {
        return switch (byte) {
            1 => .txn_intent,
            2 => .schema_change,
            3 => .config_change,
            4 => .noop,
            5 => .snapshot_marker,
            6 => .epoch_decision,
            else => error.InvalidEntryKind,
        };
    }
};

/// Kind of resolved nondeterministic value.
pub const ResolvedKind = enum(u8) {
    now = 0,
    random = 1,
    uuid_v7 = 2,
};

/// Resolved nondeterministic value - computed by gateway at submission time.
pub const ResolvedValue = union(ResolvedKind) {
    now: i64, // unix micros, resolved by gateway
    random: [16]u8, // 128-bit, resolved by gateway
    uuid_v7: [16]u8, // resolved by gateway
};

/// Read set hint - partitions that may be read by this transaction.
pub const ReadSetHint = []const PartitionId;

/// Write set hint - partitions that will be written by this transaction.
pub const WriteSetHint = []const PartitionId;

/// Transaction intent - the core type submitted to the sequencer and logged.
pub const TxnIntent = struct {
    query_hash: QueryHash, // references a registered query
    params: []const u8, // length-prefixed, typed, canonical encoding
    read_set_hint: ReadSetHint, // partitions touched, for routing
    write_set_hint: WriteSetHint, // partitions touched, for routing
    resolved_nondet: []const ResolvedValue, // nondeterminism resolved by gateway
    client_id: u64, // client identifier for idempotency
    client_seq: u64, // client sequence for idempotency
    recon_seq: Seq = 0, // seq at which reconnaissance was performed (0 = no recon)

    /// Creates a new TxnIntent with the given fields.
    pub fn init(
        query_hash: QueryHash,
        params: []const u8,
        read_set_hint: ReadSetHint,
        write_set_hint: WriteSetHint,
        resolved_nondet: []const ResolvedValue,
        client_id: u64,
        client_seq: u64,
    ) TxnIntent {
        return .{
            .query_hash = query_hash,
            .params = params,
            .read_set_hint = read_set_hint,
            .write_set_hint = write_set_hint,
            .resolved_nondet = resolved_nondet,
            .client_id = client_id,
            .client_seq = client_seq,
        };
    }

    /// Serializes TxnIntent to an ArrayList.
    /// Format:
    ///   - header (72 bytes): query_hash(32) + client_id(8) + client_seq(8) +
    ///                         read_count(4) + write_count(4) + params_len(4) + nondet_count(4) +
    ///                         recon_seq(8)
    ///   - read_set_hint: read_count * 4 bytes
    ///   - write_set_hint: write_count * 4 bytes
    ///   - params: params_len bytes
    ///   - resolved_nondet: nondet_count * 17 bytes (tag(1) + data(16))
    pub fn serializeTo(self: TxnIntent, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);

        // Write header
        const read_count: u32 = @intCast(self.read_set_hint.len);
        const write_count: u32 = @intCast(self.write_set_hint.len);
        const params_len: u32 = @intCast(self.params.len);
        const nondet_count: u32 = @intCast(self.resolved_nondet.len);

        // query_hash: 32 bytes
        try out.appendSlice(allocator, &self.query_hash);
        // client_id: 8 bytes
        try out.appendSlice(allocator, std.mem.asBytes(&self.client_id));
        // client_seq: 8 bytes
        try out.appendSlice(allocator, std.mem.asBytes(&self.client_seq));
        // read_count: 4 bytes
        try out.appendSlice(allocator, std.mem.asBytes(&read_count));
        // write_count: 4 bytes
        try out.appendSlice(allocator, std.mem.asBytes(&write_count));
        // params_len: 4 bytes
        try out.appendSlice(allocator, std.mem.asBytes(&params_len));
        // nondet_count: 4 bytes
        try out.appendSlice(allocator, std.mem.asBytes(&nondet_count));
        // recon_seq: 8 bytes
        try out.appendSlice(allocator, std.mem.asBytes(&self.recon_seq));

        // Write read_set_hint
        for (self.read_set_hint) |pid| {
            try out.appendSlice(allocator, std.mem.asBytes(&pid));
        }

        // Write write_set_hint
        for (self.write_set_hint) |pid| {
            try out.appendSlice(allocator, std.mem.asBytes(&pid));
        }

        // Write params
        try out.appendSlice(allocator, self.params);

        // Write resolved_nondet (17 bytes each: tag(1) + data(16))
        for (self.resolved_nondet) |rv| {
            const tag: u8 = @intFromEnum(@as(ResolvedKind, rv));
            try out.append(allocator, tag);
            var data: [16]u8 = std.mem.zeroes([16]u8);
            switch (rv) {
                .now => |v| std.mem.writeInt(i64, @ptrCast(@alignCast(&data)), v, .little),
                .random => |v| @memcpy(&data, &v),
                .uuid_v7 => |v| @memcpy(&data, &v),
            }
            try out.appendSlice(allocator, &data);
        }

        return out.toOwnedSlice(allocator);
    }

    /// Constant for the size of a resolved value record on wire.
    pub const RESOLVED_RECORD_SIZE: usize = 17; // tag(1) + data(16)

    /// Constant for the size of the TxnIntent header on wire.
    pub const HEADER_SIZE: usize = 72;

    /// Deserializes TxnIntent from a byte slice.
    pub fn deserializeFrom(payload: []const u8, allocator: std.mem.Allocator) !TxnIntent {
        if (payload.len < HEADER_SIZE) return error.InvalidPayload;

        const ptr = payload.ptr;

        // Read header fields
        var query_hash: QueryHash = undefined;
        @memcpy(&query_hash, ptr[0..32]);

        const client_id = std.mem.readInt(u64, @ptrCast(@alignCast(ptr + 32)), .little);
        const client_seq = std.mem.readInt(u64, @ptrCast(@alignCast(ptr + 40)), .little);
        const read_count = std.mem.readInt(u32, @ptrCast(@alignCast(ptr + 48)), .little);
        const write_count = std.mem.readInt(u32, @ptrCast(@alignCast(ptr + 52)), .little);
        const params_len = std.mem.readInt(u32, @ptrCast(@alignCast(ptr + 56)), .little);
        const nondet_count = std.mem.readInt(u32, @ptrCast(@alignCast(ptr + 60)), .little);
        const recon_seq = std.mem.readInt(u64, @ptrCast(@alignCast(ptr + 64)), .little);

        // Calculate offsets
        const read_set_start = HEADER_SIZE;
        const read_set_end = read_set_start + @as(usize, read_count) * @sizeOf(PartitionId);
        if (read_set_end > payload.len) return error.InvalidPayload;

        const write_set_start = read_set_end;
        const write_set_end = write_set_start + @as(usize, write_count) * @sizeOf(PartitionId);
        if (write_set_end > payload.len) return error.InvalidPayload;

        const params_start = write_set_end;
        const params_end = params_start + @as(usize, params_len);
        if (params_end > payload.len) return error.InvalidPayload;

        const nondet_start = params_end;
        const nondet_end = nondet_start + @as(usize, nondet_count) * RESOLVED_RECORD_SIZE;
        if (nondet_end > payload.len) return error.InvalidPayload;

        // Allocate and copy read_set_hint
        const read_set_hint = try allocator.alloc(PartitionId, read_count);
        errdefer allocator.free(read_set_hint);
        for (0..read_count) |i| {
            const offset = read_set_start + i * 4;
            read_set_hint[i] = std.mem.readInt(u32, @ptrCast(@alignCast(payload.ptr + offset)), .little);
        }

        // Allocate and copy write_set_hint
        const write_set_hint = try allocator.alloc(PartitionId, write_count);
        errdefer allocator.free(write_set_hint);
        for (0..write_count) |i| {
            const offset = write_set_start + i * 4;
            write_set_hint[i] = std.mem.readInt(u32, @ptrCast(@alignCast(payload.ptr + offset)), .little);
        }

        // Copy params
        const params = try allocator.dupe(u8, payload[params_start..params_end]);
        errdefer allocator.free(params);

        // Allocate and decode resolved_nondet
        const resolved_nondet = try allocator.alloc(ResolvedValue, nondet_count);
        errdefer allocator.free(resolved_nondet);
        for (0..nondet_count) |i| {
            const base = nondet_start + i * RESOLVED_RECORD_SIZE;
            const tag_byte = payload[base];
            const data = payload[base + 1 .. base + 17][0..16];
            resolved_nondet[i] = switch (tag_byte) {
                @intFromEnum(ResolvedKind.now) => blk: {
                    const v = std.mem.readInt(i64, data[0..8], .little);
                    break :blk .{ .now = v };
                },
                @intFromEnum(ResolvedKind.random) => blk: {
                    var d: [16]u8 = undefined;
                    @memcpy(&d, data);
                    break :blk .{ .random = d };
                },
                @intFromEnum(ResolvedKind.uuid_v7) => blk: {
                    var d: [16]u8 = undefined;
                    @memcpy(&d, data);
                    break :blk .{ .uuid_v7 = d };
                },
                else => {
                    allocator.free(read_set_hint);
                    allocator.free(write_set_hint);
                    allocator.free(params);
                    return error.InvalidPayload;
                },
            };
        }

        return .{
            .query_hash = query_hash,
            .params = params,
            .read_set_hint = read_set_hint,
            .write_set_hint = write_set_hint,
            .resolved_nondet = resolved_nondet,
            .client_id = client_id,
            .client_seq = client_seq,
            .recon_seq = recon_seq,
        };
    }

    /// Frees allocated memory in the TxnIntent.
    pub fn deinit(self: TxnIntent, allocator: std.mem.Allocator) void {
        allocator.free(self.read_set_hint);
        allocator.free(self.write_set_hint);
        allocator.free(self.params);
        allocator.free(self.resolved_nondet);
    }

    /// Creates a minimal TxnIntent for testing purposes.
    /// All optional fields are set to empty/zero values.
    pub fn initTest(payload: []const u8, client_id: u64, client_seq: u64) TxnIntent {
        const query_hash: QueryHash = std.mem.zeroes(QueryHash);
        return .{
            .query_hash = query_hash,
            .params = payload,
            .read_set_hint = &.{},
            .write_set_hint = &.{},
            .resolved_nondet = &.{},
            .client_id = client_id,
            .client_seq = client_seq,
        };
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
