/// Core types for the fold executor: TxnIntent wire format, ExecResult, AbortCode, ResolvedValue.
const std = @import("std");

pub const QueryHash = [32]u8;
pub const Seq = u64;

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
//   TxnIntentHeader (56 bytes)
//   params: [params_len]u8
//   nondet: [nondet_count]ResolvedValueRecord (each 17 bytes)
//
// ResolvedValueRecord: tag(u8) + data([16]u8)

pub const TxnIntentHeader = extern struct {
    query_hash: [32]u8,
    client_id: u64,
    client_seq: u64,
    params_len: u32,
    nondet_count: u32,

    comptime {
        std.debug.assert(@sizeOf(TxnIntentHeader) == 56);
        std.debug.assert(@offsetOf(TxnIntentHeader, "params_len") == 48);
        std.debug.assert(@offsetOf(TxnIntentHeader, "nondet_count") == 52);
    }
};

pub const RESOLVED_RECORD_SIZE: usize = 17; // tag(1) + data(16)

pub const TxnIntentDecoded = struct {
    query_hash: *const [32]u8, // points into original payload
    client_id: u64,
    client_seq: u64,
    params: []const u8, // slice into original payload
    nondet: []ResolvedValue, // allocated
    alloc: std.mem.Allocator,

    pub fn deinit(self: *TxnIntentDecoded) void {
        self.alloc.free(self.nondet);
    }
};

pub fn serializeTxnIntent(
    hash: *const [32]u8,
    client_id: u64,
    client_seq: u64,
    params: []const u8,
    nondet: []const ResolvedValue,
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
) !void {
    const hdr = TxnIntentHeader{
        .query_hash = hash.*,
        .client_id = client_id,
        .client_seq = client_seq,
        .params_len = @intCast(params.len),
        .nondet_count = @intCast(nondet.len),
    };
    try out.appendSlice(alloc, std.mem.asBytes(&hdr));
    try out.appendSlice(alloc, params);
    for (nondet) |rv| {
        const tag: u8 = @intFromEnum(@as(ResolvedKind, rv));
        try out.append(alloc, tag);
        var data: [16]u8 = std.mem.zeroes([16]u8);
        switch (rv) {
            .now => |v| std.mem.writeInt(i64, data[0..8], v, .little),
            .random => |v| @memcpy(&data, &v),
            .uuid_v7 => |v| @memcpy(&data, &v),
        }
        try out.appendSlice(alloc, &data);
    }
}

pub fn deserializeTxnIntent(payload: []const u8, alloc: std.mem.Allocator) !TxnIntentDecoded {
    if (payload.len < @sizeOf(TxnIntentHeader)) return error.InvalidPayload;
    const hdr: *const TxnIntentHeader = @ptrCast(@alignCast(payload.ptr));

    const params_start = @sizeOf(TxnIntentHeader);
    const params_end = params_start + hdr.params_len;
    if (params_end > payload.len) return error.InvalidPayload;

    const nondet_start = params_end;
    const nondet_end = nondet_start + hdr.nondet_count * RESOLVED_RECORD_SIZE;
    if (nondet_end > payload.len) return error.InvalidPayload;

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
            else => return error.InvalidPayload,
        };
    }

    return .{
        .query_hash = &hdr.query_hash,
        .client_id = hdr.client_id,
        .client_seq = hdr.client_seq,
        .params = payload[params_start..params_end],
        .nondet = nondet,
        .alloc = alloc,
    };
}
