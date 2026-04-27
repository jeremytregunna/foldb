/// Core types for the fold executor: TxnIntent wire format, ExecResult, AbortCode, ResolvedValue.
const std = @import("std");
const assert = std.debug.assert;

pub const QueryHash = [32]u8;
pub const Seq = u64;
pub const PartitionId = u32;

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

pub const AbortCode = enum(u8) {
    constraint_violation = 1,
    missing_query = 2,
    bad_params = 3,
    retry = 4,
};

pub const ExecResult = union(enum) {
    ok: struct { rows_affected: u64 },
    abort: struct { code: AbortCode, detail: []const u8 },
};


// --- TxnIntent wire format ---
//
// Embedded in LogEntry.payload for kind = .txn_intent.
//
// Layout:
//   TxnIntentHeader (72 bytes)
//   read_set_hint: [read_count]PartitionId (4 bytes each)
//   write_set_hint: [write_count]PartitionId (4 bytes each)
//   params: [params_len]u8
//   nondet: [nondet_count]ResolvedValueRecord (each 17 bytes)
//
// ResolvedValueRecord: tag(u8) + data([16]u8)

pub const TxnIntentHeader = extern struct {
    query_hash: [32]u8, // 0-31
    client_id: u64, // 32-39
    client_seq: u64, // 40-47
    read_count: u32, // 48-51
    write_count: u32, // 52-55
    params_len: u32, // 56-59
    nondet_count: u32, // 60-63
    recon_seq: u64, // 64-71: seq at which reconnaissance was performed (0 = no recon)

    comptime {
        std.debug.assert(@sizeOf(TxnIntentHeader) == 72);
        std.debug.assert(@offsetOf(TxnIntentHeader, "read_count") == 48);
        std.debug.assert(@offsetOf(TxnIntentHeader, "write_count") == 52);
        std.debug.assert(@offsetOf(TxnIntentHeader, "params_len") == 56);
        std.debug.assert(@offsetOf(TxnIntentHeader, "nondet_count") == 60);
        std.debug.assert(@offsetOf(TxnIntentHeader, "recon_seq") == 64);
    }
};

pub const resolved_record_size: u32 = 17; // tag(1) + data(16)

/// A txn_intent LogEntry that has passed CRC verification and payload decoding at the domain
/// boundary. The Executor core accepts only this type — never raw bytes for txn_intent entries.
/// Lifetime: query_hash and params are slices into the source LogEntry payload; the source
/// entry must remain alive for the duration of this struct's use.
pub const ValidatedTxnEntry = struct {
    seq: Seq,
    epoch: u64,
    decoded: TxnIntentDecoded,
};

pub const TxnIntentDecoded = struct {
    query_hash: *const [32]u8, // points into original payload
    client_id: u64,
    client_seq: u64,
    recon_seq: Seq, // seq at which reconnaissance was performed (0 = no recon)
    read_set_hint: []const PartitionId, // allocated
    write_set_hint: []const PartitionId, // allocated
    params: []const u8, // slice into original payload
    nondet: []ResolvedValue, // allocated
    alloc: std.mem.Allocator,

    pub fn deinit(self: *TxnIntentDecoded) void {
        self.alloc.free(self.read_set_hint);
        self.alloc.free(self.write_set_hint);
        self.alloc.free(self.nondet);
    }
};

pub fn serialize_txn_intent(
    hash: *const [32]u8,
    client_id: u64,
    client_seq: u64,
    recon_seq: Seq,
    read_set_hint: []const PartitionId,
    write_set_hint: []const PartitionId,
    params: []const u8,
    nondet: []const ResolvedValue,
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
) !void {
    assert(hash.len == 32);
    const header = TxnIntentHeader{
        .query_hash = hash.*,
        .client_id = client_id,
        .client_seq = client_seq,
        .read_count = @intCast(read_set_hint.len),
        .write_count = @intCast(write_set_hint.len),
        .params_len = @intCast(params.len),
        .nondet_count = @intCast(nondet.len),
        .recon_seq = recon_seq,
    };
    assert(header.read_count == read_set_hint.len);
    assert(header.write_count == write_set_hint.len);
    try out.appendSlice(alloc, std.mem.asBytes(&header));

    for (read_set_hint) |partition_id| {
        try out.appendSlice(alloc, std.mem.asBytes(&partition_id));
    }
    for (write_set_hint) |partition_id| {
        try out.appendSlice(alloc, std.mem.asBytes(&partition_id));
    }

    try out.appendSlice(alloc, params);
    for (nondet) |resolved_value| {
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
}

pub fn deserialize_txn_intent(payload: []const u8, alloc: std.mem.Allocator) !TxnIntentDecoded {
    if (payload.len < @sizeOf(TxnIntentHeader)) return error.InvalidPayload;
    const header: *const TxnIntentHeader = @ptrCast(@alignCast(payload.ptr));
    const offsets = try deserialize_txn_intent_offsets(payload.len, header);

    const read_set_hint = try alloc.alloc(PartitionId, header.read_count);
    errdefer alloc.free(read_set_hint);
    for (0..header.read_count) |i| {
        const offset = offsets.read_set_start + i * @sizeOf(PartitionId);
        read_set_hint[i] = std.mem.readInt(u32, @ptrCast(@alignCast(payload.ptr + offset)), .little);
    }
    assert(read_set_hint.len == header.read_count);

    const write_set_hint = try alloc.alloc(PartitionId, header.write_count);
    errdefer alloc.free(write_set_hint);
    for (0..header.write_count) |i| {
        const offset = offsets.write_set_start + i * @sizeOf(PartitionId);
        write_set_hint[i] = std.mem.readInt(u32, @ptrCast(@alignCast(payload.ptr + offset)), .little);
    }
    assert(write_set_hint.len == header.write_count);

    const nondet = try deserialize_txn_intent_nondet(payload, offsets.nondet_start, header.nondet_count, alloc);
    errdefer alloc.free(nondet);
    assert(nondet.len == header.nondet_count);

    return .{
        .query_hash = &header.query_hash,
        .client_id = header.client_id,
        .client_seq = header.client_seq,
        .recon_seq = header.recon_seq,
        .read_set_hint = read_set_hint,
        .write_set_hint = write_set_hint,
        .params = payload[offsets.params_start..offsets.params_end],
        .nondet = nondet,
        .alloc = alloc,
    };
}

const TxnIntentOffsets = struct {
    read_set_start: usize,
    write_set_start: usize,
    params_start: usize,
    params_end: usize,
    nondet_start: usize,
};

fn deserialize_txn_intent_offsets(payload_len: usize, header: *const TxnIntentHeader) !TxnIntentOffsets {
    const read_set_start = @sizeOf(TxnIntentHeader);
    const write_set_start = read_set_start + @as(usize, header.read_count) * @sizeOf(PartitionId);
    if (write_set_start > payload_len) return error.InvalidPayload;
    assert(write_set_start <= payload_len);

    const params_start = write_set_start + @as(usize, header.write_count) * @sizeOf(PartitionId);
    if (params_start > payload_len) return error.InvalidPayload;
    assert(params_start <= payload_len);

    const params_end = params_start + @as(usize, header.params_len);
    if (params_end > payload_len) return error.InvalidPayload;
    assert(params_end <= payload_len);

    const nondet_start = params_end;
    const nondet_end = nondet_start + @as(usize, header.nondet_count) * resolved_record_size;
    if (nondet_end > payload_len) return error.InvalidPayload;
    assert(nondet_end <= payload_len);

    return .{
        .read_set_start = read_set_start,
        .write_set_start = write_set_start,
        .params_start = params_start,
        .params_end = params_end,
        .nondet_start = nondet_start,
    };
}

fn deserialize_txn_intent_nondet(
    payload: []const u8,
    start: usize,
    count: u32,
    alloc: std.mem.Allocator,
) ![]ResolvedValue {
    assert(start + @as(usize, count) * resolved_record_size <= payload.len);
    const nondet = try alloc.alloc(ResolvedValue, count);
    errdefer alloc.free(nondet);
    for (0..count) |i| {
        const base = start + i * resolved_record_size;
        const tag_byte = payload[base];
        const data = payload[base + 1 .. base + 1 + 16][0..16];
        nondet[i] = switch (tag_byte) {
            @intFromEnum(ResolvedKind.now) => blk: {
                const timestamp = std.mem.readInt(i64, data[0..@sizeOf(i64)], .little);
                break :blk .{ .now = timestamp };
            },
            @intFromEnum(ResolvedKind.random) => blk: {
                var bytes: [16]u8 = undefined;
                @memcpy(&bytes, data);
                break :blk .{ .random = bytes };
            },
            @intFromEnum(ResolvedKind.uuid_v7) => blk: {
                var bytes: [16]u8 = undefined;
                @memcpy(&bytes, data);
                break :blk .{ .uuid_v7 = bytes };
            },
            else => return error.InvalidPayload,
        };
    }
    assert(nondet.len == count);
    return nondet;
}
