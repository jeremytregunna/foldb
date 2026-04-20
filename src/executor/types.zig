/// Core types for the fold executor: TxnIntent wire format, ExecResult, AbortCode, ResolvedValue.
const std = @import("std");

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

pub const RESOLVED_RECORD_SIZE: usize = 17; // tag(1) + data(16)

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

pub fn serializeTxnIntent(
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
    const hdr = TxnIntentHeader{
        .query_hash = hash.*,
        .client_id = client_id,
        .client_seq = client_seq,
        .read_count = @intCast(read_set_hint.len),
        .write_count = @intCast(write_set_hint.len),
        .params_len = @intCast(params.len),
        .nondet_count = @intCast(nondet.len),
        .recon_seq = recon_seq,
    };
    try out.appendSlice(alloc, std.mem.asBytes(&hdr));

    // Write read_set_hint
    for (read_set_hint) |pid| {
        try out.appendSlice(alloc, std.mem.asBytes(&pid));
    }

    // Write write_set_hint
    for (write_set_hint) |pid| {
        try out.appendSlice(alloc, std.mem.asBytes(&pid));
    }

    try out.appendSlice(alloc, params);
    for (nondet) |rv| {
        const tag: u8 = @intFromEnum(@as(ResolvedKind, rv));
        try out.append(alloc, tag);
        var data: [16]u8 = std.mem.zeroes([16]u8);
        switch (rv) {
            .now => |v| std.mem.writeInt(i64, @ptrCast(@alignCast(&data)), v, .little),
            .random => |v| @memcpy(&data, &v),
            .uuid_v7 => |v| @memcpy(&data, &v),
        }
        try out.appendSlice(alloc, &data);
    }
}

pub fn deserializeTxnIntent(payload: []const u8, alloc: std.mem.Allocator) !TxnIntentDecoded {
    if (payload.len < @sizeOf(TxnIntentHeader)) return error.InvalidPayload;
    const hdr: *const TxnIntentHeader = @ptrCast(@alignCast(payload.ptr));

    // Calculate offsets
    const read_set_start = @sizeOf(TxnIntentHeader);
    const read_set_end = read_set_start + @as(usize, hdr.read_count) * @sizeOf(PartitionId);
    if (read_set_end > payload.len) return error.InvalidPayload;

    const write_set_start = read_set_end;
    const write_set_end = write_set_start + @as(usize, hdr.write_count) * @sizeOf(PartitionId);
    if (write_set_end > payload.len) return error.InvalidPayload;

    const params_start = write_set_end;
    const params_end = params_start + @as(usize, hdr.params_len);
    if (params_end > payload.len) return error.InvalidPayload;

    const nondet_start = params_end;
    const nondet_end = nondet_start + @as(usize, hdr.nondet_count) * RESOLVED_RECORD_SIZE;
    if (nondet_end > payload.len) return error.InvalidPayload;

    // Allocate and decode read_set_hint
    const read_set_hint = try alloc.alloc(PartitionId, hdr.read_count);
    errdefer alloc.free(read_set_hint);
    for (0..hdr.read_count) |i| {
        const offset = read_set_start + i * 4;
        read_set_hint[i] = std.mem.readInt(u32, @ptrCast(@alignCast(payload.ptr + offset)), .little);
    }

    // Allocate and decode write_set_hint
    const write_set_hint = try alloc.alloc(PartitionId, hdr.write_count);
    errdefer alloc.free(write_set_hint);
    for (0..hdr.write_count) |i| {
        const offset = write_set_start + i * 4;
        write_set_hint[i] = std.mem.readInt(u32, @ptrCast(@alignCast(payload.ptr + offset)), .little);
    }

    // Allocate and decode nondet
    const nondet = try alloc.alloc(ResolvedValue, hdr.nondet_count);
    errdefer alloc.free(nondet);

    for (0..hdr.nondet_count) |i| {
        const base = nondet_start + i * RESOLVED_RECORD_SIZE;
        const tag_byte = payload[base];
        const data = payload[base + 1 .. base + 17][0..16];
        nondet[i] = switch (tag_byte) {
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
                alloc.free(read_set_hint);
                alloc.free(write_set_hint);
                return error.InvalidPayload;
            },
        };
    }

    return .{
        .query_hash = &hdr.query_hash,
        .client_id = hdr.client_id,
        .client_seq = hdr.client_seq,
        .recon_seq = hdr.recon_seq,
        .read_set_hint = read_set_hint,
        .write_set_hint = write_set_hint,
        .params = payload[params_start..params_end],
        .nondet = nondet,
        .alloc = alloc,
    };
}
