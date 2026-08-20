/// Log entry types and serialization for Foldb's write-ahead log.
const std = @import("std");
const crc = @import("crc.zig");

pub const Seq = u64;
pub const Epoch = u64;
pub const NodeId = u64;
pub const PartitionId = u32;
pub const ReadSetHint = []const PartitionId;
pub const WriteSetHint = []const PartitionId;

pub const payload_len_max: u32 = 1 << 20;

pub const EntryKind = enum(u8) {
    txn_intent = 1,
    config_change = 3,
    noop = 4,
    snapshot_marker = 5,
    epoch_decision = 6,
    commit_record = 7,

    pub fn fromByte(byte: u8) !EntryKind {
        return switch (byte) {
            1 => .txn_intent,
            3 => .config_change,
            4 => .noop,
            5 => .snapshot_marker,
            6 => .epoch_decision,
            7 => .commit_record,
            else => error.InvalidEntryKind,
        };
    }
};

// ─── KV Log Operations ───

pub const KvOp = union(enum) {
    set: struct { key: []const u8, value: []const u8, expected_seq: Seq = 0 },
    delete: struct { key: []const u8 },

    pub fn deinit(self: KvOp, alloc: std.mem.Allocator) void {
        switch (self) {
            .set => |s| {
                alloc.free(s.key);
                alloc.free(s.value);
            },
            .delete => |d| alloc.free(d.key),
        }
    }
};

pub const TxnIntent = struct {
    ops: []const KvOp,
    read_set_hint: ReadSetHint = &.{},
    write_set_hint: WriteSetHint = &.{},
    client_id: u64,
    client_seq: u64,
    recon_seq: Seq = 0,

    pub fn init(
        ops: []const KvOp,
        read_set_hint: ReadSetHint,
        write_set_hint: WriteSetHint,
        client_id: u64,
        client_seq: u64,
    ) TxnIntent {
        return .{
            .ops = ops,
            .read_set_hint = read_set_hint,
            .write_set_hint = write_set_hint,
            .client_id = client_id,
            .client_seq = client_seq,
        };
    }

    pub fn serialize_to(self: TxnIntent, alloc: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(alloc);

        const read_count: u32 = @intCast(self.read_set_hint.len);
        const write_count: u32 = @intCast(self.write_set_hint.len);
        const op_count: u32 = @intCast(self.ops.len);

        // Header: client_id(8) + client_seq(8) + recon_seq(8) + counts(12) = 36 bytes
        try out.appendSlice(alloc, &std.mem.toBytes(@as(u64, self.client_id)));
        try out.appendSlice(alloc, &std.mem.toBytes(@as(u64, self.client_seq)));
        try out.appendSlice(alloc, &std.mem.toBytes(@as(u64, self.recon_seq)));
        try out.appendSlice(alloc, &std.mem.toBytes(read_count));
        try out.appendSlice(alloc, &std.mem.toBytes(write_count));
        try out.appendSlice(alloc, &std.mem.toBytes(op_count));

        for (self.read_set_hint) |pid| {
            try out.appendSlice(alloc, &std.mem.toBytes(pid));
        }
        for (self.write_set_hint) |pid| {
            try out.appendSlice(alloc, &std.mem.toBytes(pid));
        }
        for (self.ops) |op| {
            switch (op) {
                .set => |s| {
                    try out.append(alloc, 0);
                    const klen: u32 = @intCast(s.key.len);
                    try out.appendSlice(alloc, &std.mem.toBytes(klen));
                    try out.appendSlice(alloc, s.key);
                    const vlen: u32 = @intCast(s.value.len);
                    try out.appendSlice(alloc, &std.mem.toBytes(vlen));
                    try out.appendSlice(alloc, s.value);
                    try out.appendSlice(alloc, &std.mem.toBytes(@as(u64, s.expected_seq)));
                },
                .delete => |d| {
                    try out.append(alloc, 1);
                    const klen: u32 = @intCast(d.key.len);
                    try out.appendSlice(alloc, &std.mem.toBytes(klen));
                    try out.appendSlice(alloc, d.key);
                },
            }
        }

        return out.toOwnedSlice(alloc);
    }

    pub fn deserialize_from(payload: []const u8, alloc: std.mem.Allocator) !TxnIntent {
        if (payload.len < 36) return error.InvalidPayload;
        const client_id = std.mem.bytesToValue(u64, payload[0..8]);
        const client_seq = std.mem.bytesToValue(u64, payload[8..16]);
        const recon_seq = std.mem.bytesToValue(u64, payload[16..24]);
        const read_count = std.mem.bytesToValue(u32, payload[24..28]);
        const write_count = std.mem.bytesToValue(u32, payload[28..32]);
        const op_count = std.mem.bytesToValue(u32, payload[32..36]);

        var pos: usize = 36;

        const read_set = try alloc.alloc(PartitionId, read_count);
        errdefer alloc.free(read_set);
        for (0..read_count) |i| {
            read_set[i] = std.mem.bytesToValue(u32, payload[pos .. pos + 4]);
            pos += 4;
        }

        const write_set = try alloc.alloc(PartitionId, write_count);
        errdefer alloc.free(write_set);
        for (0..write_count) |i| {
            write_set[i] = std.mem.bytesToValue(u32, payload[pos .. pos + 4]);
            pos += 4;
        }

        const ops = try alloc.alloc(KvOp, op_count);
        errdefer {
            for (ops[0..]) |op| op.deinit(alloc);
            alloc.free(ops);
        }
        var idx: usize = 0;
        while (idx < op_count) : (idx += 1) {
            const tag = payload[pos];
            pos += 1;
            ops[idx] = switch (tag) {
                0 => blk: {
                    const klen = std.mem.bytesToValue(u32, payload[pos .. pos + 4]);
                    pos += 4;
                    const key = try alloc.dupe(u8, payload[pos .. pos + klen]);
                    pos += klen;
                    const vlen = std.mem.bytesToValue(u32, payload[pos .. pos + 4]);
                    pos += 4;
                    const value = try alloc.dupe(u8, payload[pos .. pos + vlen]);
                    pos += vlen;
                    const expected_seq = std.mem.bytesToValue(u64, payload[pos .. pos + 8]);
                    pos += 8;
                    break :blk .{ .set = .{ .key = key, .value = value, .expected_seq = expected_seq } };
                },
                1 => blk: {
                    const klen = std.mem.bytesToValue(u32, payload[pos .. pos + 4]);
                    pos += 4;
                    const key = try alloc.dupe(u8, payload[pos .. pos + klen]);
                    pos += klen;
                    break :blk .{ .delete = .{ .key = key } };
                },
                else => return error.InvalidPayload,
            };
        }

        return .{
            .ops = ops,
            .read_set_hint = read_set,
            .write_set_hint = write_set,
            .client_id = client_id,
            .client_seq = client_seq,
            .recon_seq = recon_seq,
        };
    }

    pub fn deinit(self: TxnIntent, alloc: std.mem.Allocator) void {
        for (self.ops) |op| op.deinit(alloc);
        alloc.free(self.ops);
        alloc.free(self.read_set_hint);
        alloc.free(self.write_set_hint);
    }

    pub fn init_test(params: []const u8, client_id: u64, client_seq: u64) TxnIntent {
        // Creates a single KvOp.set with key="test" and value=params
        // (for backward compatibility with log tests)
        return .{
            .ops = &.{.{ .set = .{ .key = "test", .value = params, .expected_seq = 0 } }},
            .read_set_hint = &.{},
            .write_set_hint = &.{},
            .client_id = client_id,
            .client_seq = client_seq,
        };
    }
};

// ─── Log Entry Header ───

pub const LogEntryHeader = struct {
    seq: Seq,
    epoch: Epoch,
    kind: EntryKind,
    payload_len: u32,
    payload_crc: u32,
    header_crc: u32,

    pub const header_size: u32 = 29;

    pub fn init(seq: Seq, epoch: Epoch, kind: EntryKind, payload: []const u8) LogEntryHeader {
        var h = LogEntryHeader{
            .seq = seq,
            .epoch = epoch,
            .kind = kind,
            .payload_len = @intCast(payload.len),
            .payload_crc = crc.crc32c(payload),
            .header_crc = 0,
        };
        h.header_crc = h.compute_header_crc();
        return h;
    }

    fn compute_header_crc(self: *const LogEntryHeader) u32 {
        var buf: [25]u8 = undefined;
        self.write_body(&buf);
        return crc.crc32c(&buf);
    }

    fn write_body(self: *const LogEntryHeader, buf: []u8) void {
        std.mem.writeInt(u64, buf[0..8], self.seq, .little);
        std.mem.writeInt(u64, buf[8..16], self.epoch, .little);
        buf[16] = @intFromEnum(self.kind);
        std.mem.writeInt(u32, buf[17..21], self.payload_len, .little);
        std.mem.writeInt(u32, buf[21..25], self.payload_crc, .little);
    }

    pub fn verify_header_crc(self: *const LogEntryHeader) bool {
        return self.compute_header_crc() == self.header_crc;
    }

    pub fn serialize_to(self: LogEntryHeader, buf: []u8) void {
        std.debug.assert(buf.len >= header_size);
        self.write_body(buf[0..25]);
        std.mem.writeInt(u32, buf[25..29], self.header_crc, .little);
    }

    pub fn deserialize_from(buf: []const u8) !LogEntryHeader {
        if (buf.len < header_size) return error.EndOfStream;
        const seq = std.mem.readInt(u64, buf[0..8], .little);
        const epoch = std.mem.readInt(u64, buf[8..16], .little);
        const kind = try EntryKind.fromByte(buf[16]);
        const payload_len = std.mem.readInt(u32, buf[17..21], .little);
        const payload_crc = std.mem.readInt(u32, buf[21..25], .little);
        const header_crc = std.mem.readInt(u32, buf[25..29], .little);
        return .{ .seq = seq, .epoch = epoch, .kind = kind, .payload_len = payload_len, .payload_crc = payload_crc, .header_crc = header_crc };
    }
};

// ─── Log Entry ───

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

        return .{ .header = log_header, .payload = payload };
    }

    pub fn deserialize_pread(fd: std.posix.fd_t, offset: *i64, alloc: std.mem.Allocator) !LogEntry {
        var header_buf: [LogEntryHeader.header_size]u8 = undefined;
        const n = std.os.linux.pread(
            @intCast(fd),
            &header_buf,
            LogEntryHeader.header_size,
            offset.*,
        );
        if (n != LogEntryHeader.header_size) return error.EndOfStream;
        offset.* += @intCast(n);

        const log_header = try LogEntryHeader.deserialize_from(&header_buf);
        if (log_header.payload_len > payload_len_max) return error.InvalidPayloadLength;

        const payload = try alloc.alloc(u8, log_header.payload_len);
        errdefer alloc.free(payload);

        if (log_header.payload_len > 0) {
            const pn = std.os.linux.pread(
                @intCast(fd),
                payload.ptr,
                log_header.payload_len,
                offset.*,
            );
            if (pn != log_header.payload_len) return error.EndOfStream;
            offset.* += @intCast(pn);
        }

        return .{ .header = log_header, .payload = payload };
    }

    pub fn verify_crc(self: LogEntry) bool {
        return crc.crc32c(self.payload) == self.header.payload_crc;
    }

    pub fn deinit(self: *LogEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.payload);
    }
};
