/// Log entry types and serialization for Foldb's write-ahead log.
const std = @import("std");
const crc = @import("crc.zig");

pub const Seq = u64;
pub const Epoch = u64;
pub const NodeId = u64;
pub const PartitionId = u32;
pub const QueryHash = [32]u8;
pub const ReadSetHint = []const PartitionId;
pub const WriteSetHint = []const PartitionId;

pub const payload_len_max: u32 = 1 << 20;

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

pub const ResolvedKind = enum(u8) {
    now = 0,
    random = 1,
    uuid_v7 = 2,
};

pub const ResolvedValue = union(ResolvedKind) {
    now: i64,
    random: [16]u8,
    uuid_v7: [16]u8,
};

pub const TxnIntent = struct {
    query_hash: QueryHash,
    params: []const u8,
    read_set_hint: ReadSetHint,
    write_set_hint: WriteSetHint,
    resolved_nondet: []const ResolvedValue,
    client_id: u64,
    client_seq: u64,
    recon_seq: Seq = 0,

    pub const resolved_record_size: u32 = 17; // tag(1) + data(16)
    pub const header_size: u32 = 72;

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

    /// Serializes TxnIntent to an owned slice.
    /// Format: header(72) + read_set_hint + write_set_hint + params + resolved_nondet
    pub fn serialize_to(self: TxnIntent, alloc: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(alloc);

        const read_count: u32 = @intCast(self.read_set_hint.len);
        const write_count: u32 = @intCast(self.write_set_hint.len);
        const params_len: u32 = @intCast(self.params.len);
        const nondet_count: u32 = @intCast(self.resolved_nondet.len);
        std.debug.assert(read_count == self.read_set_hint.len);
        std.debug.assert(write_count == self.write_set_hint.len);

        try out.appendSlice(alloc, &self.query_hash);
        try out.appendSlice(alloc, std.mem.asBytes(&self.client_id));
        try out.appendSlice(alloc, std.mem.asBytes(&self.client_seq));
        try out.appendSlice(alloc, std.mem.asBytes(&read_count));
        try out.appendSlice(alloc, std.mem.asBytes(&write_count));
        try out.appendSlice(alloc, std.mem.asBytes(&params_len));
        try out.appendSlice(alloc, std.mem.asBytes(&nondet_count));
        try out.appendSlice(alloc, std.mem.asBytes(&self.recon_seq));

        for (self.read_set_hint) |partition_id| {
            try out.appendSlice(alloc, std.mem.asBytes(&partition_id));
        }
        for (self.write_set_hint) |partition_id| {
            try out.appendSlice(alloc, std.mem.asBytes(&partition_id));
        }

        try out.appendSlice(alloc, self.params);

        for (self.resolved_nondet) |resolved_value| {
            const tag: u8 = @intFromEnum(@as(ResolvedKind, resolved_value));
            try out.append(alloc, tag);
            var data: [16]u8 = std.mem.zeroes([16]u8);
            switch (resolved_value) {
                .now => |timestamp| std.mem.writeInt(i64, @ptrCast(@alignCast(&data)), timestamp, .little),
                .random => |bytes| @memcpy(&data, &bytes),
                .uuid_v7 => |bytes| @memcpy(&data, &bytes),
            }
            try out.appendSlice(alloc, &data);
        }

        return out.toOwnedSlice(alloc);
    }

    const Offsets = struct {
        query_hash: QueryHash,
        client_id: u64,
        client_seq: u64,
        recon_seq: Seq,
        read_count: u32,
        write_count: u32,
        params_len: u32,
        nondet_count: u32,
        read_set_start: usize,
        read_set_end: usize,
        write_set_start: usize,
        write_set_end: usize,
        params_start: usize,
        params_end: usize,
        nondet_start: usize,
        nondet_end: usize,
    };

    fn deserialize_from_offsets(payload: []const u8) !Offsets {
        if (payload.len < header_size) return error.InvalidPayload;
        const payload_ptr = payload.ptr;

        var query_hash: QueryHash = undefined;
        @memcpy(&query_hash, payload_ptr[0..32]);

        const client_id = std.mem.readInt(u64, @ptrCast(@alignCast(payload_ptr + 32)), .little);
        const client_seq = std.mem.readInt(u64, @ptrCast(@alignCast(payload_ptr + 40)), .little);
        const read_count = std.mem.readInt(u32, @ptrCast(@alignCast(payload_ptr + 48)), .little);
        const write_count = std.mem.readInt(u32, @ptrCast(@alignCast(payload_ptr + 52)), .little);
        const params_len = std.mem.readInt(u32, @ptrCast(@alignCast(payload_ptr + 56)), .little);
        const nondet_count = std.mem.readInt(u32, @ptrCast(@alignCast(payload_ptr + 60)), .little);
        const recon_seq = std.mem.readInt(u64, @ptrCast(@alignCast(payload_ptr + 64)), .little);

        const read_set_start: usize = header_size;
        const read_set_end: usize = read_set_start + @as(usize, read_count) * @sizeOf(PartitionId);
        if (read_set_end > payload.len) return error.InvalidPayload;
        std.debug.assert(read_set_end >= read_set_start);

        const write_set_start: usize = read_set_end;
        const write_set_end: usize = write_set_start + @as(usize, write_count) * @sizeOf(PartitionId);
        if (write_set_end > payload.len) return error.InvalidPayload;
        std.debug.assert(write_set_end >= write_set_start);

        const params_start: usize = write_set_end;
        const params_end: usize = params_start + @as(usize, params_len);
        if (params_end > payload.len) return error.InvalidPayload;
        std.debug.assert(params_end >= params_start);

        const nondet_start: usize = params_end;
        const nondet_end: usize = nondet_start + @as(usize, nondet_count) * resolved_record_size;
        if (nondet_end > payload.len) return error.InvalidPayload;
        std.debug.assert(nondet_end >= nondet_start);

        return .{
            .query_hash = query_hash,
            .client_id = client_id,
            .client_seq = client_seq,
            .recon_seq = recon_seq,
            .read_count = read_count,
            .write_count = write_count,
            .params_len = params_len,
            .nondet_count = nondet_count,
            .read_set_start = read_set_start,
            .read_set_end = read_set_end,
            .write_set_start = write_set_start,
            .write_set_end = write_set_end,
            .params_start = params_start,
            .params_end = params_end,
            .nondet_start = nondet_start,
            .nondet_end = nondet_end,
        };
    }

    fn deserialize_from_nondet(
        payload: []const u8,
        base: usize,
        count: u32,
        alloc: std.mem.Allocator,
    ) ![]ResolvedValue {
        const resolved_nondet = try alloc.alloc(ResolvedValue, count);
        errdefer alloc.free(resolved_nondet);
        for (0..count) |i| {
            const record_base = base + i * resolved_record_size;
            const tag_byte = payload[record_base];
            const bytes = payload[record_base + 1 .. record_base + 17][0..16];
            resolved_nondet[i] = switch (tag_byte) {
                @intFromEnum(ResolvedKind.now) => blk: {
                    const timestamp = std.mem.readInt(i64, bytes[0..8], .little);
                    break :blk .{ .now = timestamp };
                },
                @intFromEnum(ResolvedKind.random) => blk: {
                    var d: [16]u8 = undefined;
                    @memcpy(&d, bytes);
                    break :blk .{ .random = d };
                },
                @intFromEnum(ResolvedKind.uuid_v7) => blk: {
                    var d: [16]u8 = undefined;
                    @memcpy(&d, bytes);
                    break :blk .{ .uuid_v7 = d };
                },
                else => return error.InvalidPayload,
            };
        }
        std.debug.assert(resolved_nondet.len == count);
        return resolved_nondet;
    }

    pub fn deserialize_from(payload: []const u8, alloc: std.mem.Allocator) !TxnIntent {
        const offsets = try deserialize_from_offsets(payload);

        const read_set_hint = try alloc.alloc(PartitionId, offsets.read_count);
        errdefer alloc.free(read_set_hint);
        for (0..offsets.read_count) |i| {
            const offset = offsets.read_set_start + i * @sizeOf(PartitionId);
            read_set_hint[i] = std.mem.readInt(u32, @ptrCast(@alignCast(payload.ptr + offset)), .little);
        }
        std.debug.assert(read_set_hint.len == offsets.read_count);

        const write_set_hint = try alloc.alloc(PartitionId, offsets.write_count);
        errdefer alloc.free(write_set_hint);
        for (0..offsets.write_count) |i| {
            const offset = offsets.write_set_start + i * @sizeOf(PartitionId);
            write_set_hint[i] = std.mem.readInt(u32, @ptrCast(@alignCast(payload.ptr + offset)), .little);
        }
        std.debug.assert(write_set_hint.len == offsets.write_count);

        const params = try alloc.dupe(u8, payload[offsets.params_start..offsets.params_end]);
        errdefer alloc.free(params);

        const resolved_nondet = try deserialize_from_nondet(
            payload,
            offsets.nondet_start,
            offsets.nondet_count,
            alloc,
        );

        return .{
            .query_hash = offsets.query_hash,
            .params = params,
            .read_set_hint = read_set_hint,
            .write_set_hint = write_set_hint,
            .resolved_nondet = resolved_nondet,
            .client_id = offsets.client_id,
            .client_seq = offsets.client_seq,
            .recon_seq = offsets.recon_seq,
        };
    }

    pub fn deinit(self: TxnIntent, alloc: std.mem.Allocator) void {
        alloc.free(self.read_set_hint);
        alloc.free(self.write_set_hint);
        alloc.free(self.params);
        alloc.free(self.resolved_nondet);
    }

    pub fn init_test(payload: []const u8, client_id: u64, client_seq: u64) TxnIntent {
        return .{
            .query_hash = std.mem.zeroes(QueryHash),
            .params = payload,
            .read_set_hint = &.{},
            .write_set_hint = &.{},
            .resolved_nondet = &.{},
            .client_id = client_id,
            .client_seq = client_seq,
        };
    }
};

/// Log entry header — 25 bytes on disk (little-endian):
/// seq(8) epoch(8) kind(1) payload_len(4) payload_crc(4)
pub const LogEntryHeader = struct {
    seq: Seq,
    epoch: Epoch,
    kind: EntryKind,
    payload_len: u32,
    payload_crc: u32,

    pub const header_size: u32 = 8 + 8 + 1 + 4 + 4; // 25

    pub fn init(seq: Seq, epoch: Epoch, kind: EntryKind, payload: []const u8) LogEntryHeader {
        return .{
            .seq = seq,
            .epoch = epoch,
            .kind = kind,
            .payload_len = @intCast(payload.len),
            .payload_crc = crc.crc32c(payload),
        };
    }

    pub fn serialize_to(self: LogEntryHeader, buf: []u8) void {
        std.debug.assert(buf.len >= header_size);
        std.mem.writeInt(u64, buf[0..8], self.seq, .little);
        std.mem.writeInt(u64, buf[8..16], self.epoch, .little);
        buf[16] = @intFromEnum(self.kind);
        std.mem.writeInt(u32, buf[17..21], self.payload_len, .little);
        std.mem.writeInt(u32, buf[21..25], self.payload_crc, .little);
    }

    pub fn deserialize_from(buf: []const u8) !LogEntryHeader {
        if (buf.len < header_size) return error.EndOfStream;
        const seq = std.mem.readInt(u64, buf[0..8], .little);
        const epoch = std.mem.readInt(u64, buf[8..16], .little);
        const kind = try EntryKind.fromByte(buf[16]);
        const payload_len = std.mem.readInt(u32, buf[17..21], .little);
        const payload_crc = std.mem.readInt(u32, buf[21..25], .little);
        return .{ .seq = seq, .epoch = epoch, .kind = kind, .payload_len = payload_len, .payload_crc = payload_crc };
    }
};

pub const LogEntry = struct {
    header: LogEntryHeader,
    payload: []const u8,

    pub fn init(header: LogEntryHeader, payload: []const u8) LogEntry {
        return .{ .header = header, .payload = payload };
    }

    pub fn create(seq: Seq, epoch: Epoch, kind: EntryKind, payload: []const u8) LogEntry {
        return .{ .header = LogEntryHeader.init(seq, epoch, kind, payload), .payload = payload };
    }

    pub fn total_size(self: LogEntry) usize {
        return LogEntryHeader.header_size + self.payload.len;
    }

    pub fn serialize_to(self: LogEntry, buf: []u8) void {
        std.debug.assert(buf.len >= self.total_size());
        self.header.serialize_to(buf[0..LogEntryHeader.header_size]);
        @memcpy(buf[LogEntryHeader.header_size..][0..self.payload.len], self.payload);
    }

    pub fn deserialize_fd(fd: std.posix.fd_t, alloc: std.mem.Allocator) !LogEntry {
        var header_buf: [LogEntryHeader.header_size]u8 = undefined;
        const n = std.os.linux.read(@intCast(fd), &header_buf, LogEntryHeader.header_size);
        if (n != LogEntryHeader.header_size) return error.EndOfStream;

        const log_header = try LogEntryHeader.deserialize_from(&header_buf);
        if (log_header.payload_len > payload_len_max) return error.InvalidPayloadLength;

        const payload = try alloc.alloc(u8, log_header.payload_len);
        errdefer alloc.free(payload);

        if (log_header.payload_len > 0) {
            const pn = std.os.linux.read(@intCast(fd), payload.ptr, log_header.payload_len);
            if (pn != log_header.payload_len) return error.EndOfStream;
        }

        std.debug.assert(payload.len == log_header.payload_len);
        return .{ .header = log_header, .payload = payload };
    }

    /// Deserialize using pread with an explicit offset. Advances *offset by the bytes consumed.
    /// Safe for concurrent use with write() on the same fd (pread does not affect the fd's position).
    pub fn deserialize_pread(fd: std.posix.fd_t, offset: *i64, alloc: std.mem.Allocator) !LogEntry {
        var header_buf: [LogEntryHeader.header_size]u8 = undefined;
        const n = std.os.linux.pread(
            @intCast(fd), &header_buf, LogEntryHeader.header_size, offset.*,
        );
        if (n != LogEntryHeader.header_size) return error.EndOfStream;
        offset.* += @intCast(n);

        const log_header = try LogEntryHeader.deserialize_from(&header_buf);
        if (log_header.payload_len > payload_len_max) return error.InvalidPayloadLength;

        const payload = try alloc.alloc(u8, log_header.payload_len);
        errdefer alloc.free(payload);

        if (log_header.payload_len > 0) {
            const pn = std.os.linux.pread(
                @intCast(fd), payload.ptr, log_header.payload_len, offset.*,
            );
            if (pn != log_header.payload_len) return error.EndOfStream;
            offset.* += @intCast(pn);
        }

        std.debug.assert(payload.len == log_header.payload_len);
        return .{ .header = log_header, .payload = payload };
    }

    pub fn verify_crc(self: LogEntry) bool {
        return crc.crc32c(self.payload) == self.header.payload_crc;
    }

    pub fn deinit(self: *LogEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.payload);
    }
};
