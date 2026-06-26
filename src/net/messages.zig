/// Per-kind message payload encode/decode for the FoldDB wire protocol.
/// KV protocol: GET, SET, DELETE, RANGE, BATCH.
const std = @import("std");
const codec = @import("codec.zig");

const assert = std.debug.assert;

pub const TypedValue = codec.TypedValue;

// Encode helpers shared with codec.
const appendU8 = codec.appendU8;
const appendU16Le = codec.appendU16Le;
const appendU32Le = codec.appendU32Le;
const appendU64Le = codec.appendU64Le;

// ---- Auth methods ----

pub const AuthMethod = enum(u8) {
    none = 0x00,
    token = 0x02,
    _,
};

// ---- Hello (S→C, stream 0) ----

pub const Hello = struct {
    server_version: []const u8,
    auth_methods: []const u8,
    max_frame_payload_size: u32,
};

pub fn encodeHello(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, h: Hello) !void {
    assert(h.server_version.len <= 255);
    assert(h.auth_methods.len <= 255);
    try appendU8(out, alloc, @intCast(h.server_version.len));
    try out.appendSlice(alloc, h.server_version);
    try appendU8(out, alloc, @intCast(h.auth_methods.len));
    try out.appendSlice(alloc, h.auth_methods);
    try appendU32Le(out, alloc, h.max_frame_payload_size);
}

pub fn decodeHello(cur: *codec.Cursor, alloc: std.mem.Allocator) !Hello {
    const ver = try cur.readU8LenPrefixedAlloc(alloc);
    errdefer alloc.free(ver);
    const method_count = try cur.readU8();
    const methods_raw = try cur.readSlice(method_count);
    const methods = try alloc.dupe(u8, methods_raw);
    errdefer alloc.free(methods);
    const max_payload = try cur.readU32Le();
    return .{ .server_version = ver, .auth_methods = methods, .max_frame_payload_size = max_payload };
}

pub fn freeHello(h: Hello, alloc: std.mem.Allocator) void {
    alloc.free(h.server_version);
    alloc.free(h.auth_methods);
}

// ---- Auth (C→S, stream 0) ----

pub const AuthToken = struct {
    token: []const u8,
};

pub const AuthPayload = union(AuthMethod) {
    none: void,
    token: AuthToken,
};

pub const Auth = struct {
    method: AuthMethod,
    client_max_frame_size: u32,
    payload: AuthPayload,
    database_name: []const u8 = "",
};

pub fn encodeAuth(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, a: Auth) !void {
    try appendU8(out, alloc, @intFromEnum(a.method));
    try appendU32Le(out, alloc, a.client_max_frame_size);
    switch (a.payload) {
        .none => {},
        .token => |t| {
            assert(t.token.len <= std.math.maxInt(u16));
            try appendU16Le(out, alloc, @intCast(t.token.len));
            try out.appendSlice(alloc, t.token);
        },
    }
    assert(a.database_name.len <= 255);
    try appendU8(out, alloc, @intCast(a.database_name.len));
    try out.appendSlice(alloc, a.database_name);
}

pub fn decodeAuth(cur: *codec.Cursor, alloc: std.mem.Allocator) !Auth {
    const method_byte = try cur.readU8();
    const method_raw: AuthMethod = @enumFromInt(method_byte);
    const method = switch (method_raw) {
        .none, .token => method_raw,
        _ => return error.ProtocolError,
    };
    const client_max = try cur.readU32Le();
    const payload: AuthPayload = switch (method) {
        .none => .none,
        .token => blk: {
            const tok_len = try cur.readU16Le();
            const tok_raw = try cur.readSlice(tok_len);
            const tok = try alloc.dupe(u8, tok_raw);
            break :blk .{ .token = .{ .token = tok } };
        },
        _ => unreachable,
    };
    const database_name: []const u8 = if (cur.remaining() > 0) blk: {
        const name_len = try cur.readU8();
        const name_raw = try cur.readSlice(name_len);
        break :blk try alloc.dupe(u8, name_raw);
    } else "";
    return .{ .method = method, .client_max_frame_size = client_max, .payload = payload, .database_name = database_name };
}

pub fn freeAuth(a: Auth, alloc: std.mem.Allocator) void {
    switch (a.payload) {
        .none => {},
        .token => |t| alloc.free(t.token),
    }
    if (a.database_name.len > 0) alloc.free(a.database_name);
}

// ---- Ping / Pong ----

pub const Ping = struct { client_wall_micros: u64 };

pub fn encodePing(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, p: Ping) !void {
    try appendU64Le(out, alloc, p.client_wall_micros);
}

pub fn decodePing(cur: *codec.Cursor) !Ping {
    return .{ .client_wall_micros = try cur.readU64Le() };
}

pub const Pong = struct {
    client_wall_micros: u64,
    server_wall_micros: u64,
};

pub fn encodePong(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, p: Pong) !void {
    try appendU64Le(out, alloc, p.client_wall_micros);
    try appendU64Le(out, alloc, p.server_wall_micros);
}

pub fn decodePong(cur: *codec.Cursor) !Pong {
    return .{
        .client_wall_micros = try cur.readU64Le(),
        .server_wall_micros = try cur.readU64Le(),
    };
}

// ──────────────────────────────────────────────────────────────
// KV Operations
// ──────────────────────────────────────────────────────────────

// ---- Get (C→S) ----

pub const GetRequest = struct {
    key: []const u8,
    /// If non-zero, read at this committed sequence number (historical read).
    at_seq: u64 = 0,
};

pub fn encodeGetRequest(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, r: GetRequest) !void {
    assert(r.key.len <= std.math.maxInt(u32));
    try appendU32Le(out, alloc, @intCast(r.key.len));
    try out.appendSlice(alloc, r.key);
    try appendU64Le(out, alloc, r.at_seq);
}

pub fn decodeGetRequest(cur: *codec.Cursor, alloc: std.mem.Allocator) !GetRequest {
    const key = try cur.readLenPrefixedAlloc(alloc);
    errdefer alloc.free(key);
    const at_seq = try cur.readU64Le();
    return .{ .key = key, .at_seq = at_seq };
}

pub fn freeGetRequest(r: GetRequest, alloc: std.mem.Allocator) void {
    alloc.free(r.key);
}

// ---- GetResponse (S→C) ----

pub const GetResponse = struct {
    /// null if key not found.
    value: ?[]const u8,
    committed_seq: u64,
};

pub fn encodeGetResponse(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, r: GetResponse) !void {
    try appendU64Le(out, alloc, r.committed_seq);
    if (r.value) |v| {
        assert(v.len <= std.math.maxInt(u32));
        try appendU8(out, alloc, 1);
        try appendU32Le(out, alloc, @intCast(v.len));
        try out.appendSlice(alloc, v);
    } else {
        try appendU8(out, alloc, 0);
    }
}

pub fn decodeGetResponse(cur: *codec.Cursor, alloc: std.mem.Allocator) !GetResponse {
    const committed_seq = try cur.readU64Le();
    const present = try cur.readU8();
    const value: ?[]const u8 = if (present != 0) try cur.readLenPrefixedAlloc(alloc) else null;
    return .{ .value = value, .committed_seq = committed_seq };
}

pub fn freeGetResponse(r: GetResponse, alloc: std.mem.Allocator) void {
    if (r.value) |v| alloc.free(v);
}

// ---- Set (C→S) ----

pub const SetRequest = struct {
    key: []const u8,
    value: []const u8,
    /// If non-zero, only set if current seq == expected_seq (compare-and-swap).
    expected_seq: u64 = 0,
};

pub fn encodeSetRequest(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, r: SetRequest) !void {
    assert(r.key.len <= std.math.maxInt(u32));
    assert(r.value.len <= std.math.maxInt(u32));
    try appendU32Le(out, alloc, @intCast(r.key.len));
    try out.appendSlice(alloc, r.key);
    try appendU32Le(out, alloc, @intCast(r.value.len));
    try out.appendSlice(alloc, r.value);
    try appendU64Le(out, alloc, r.expected_seq);
}

pub fn decodeSetRequest(cur: *codec.Cursor, alloc: std.mem.Allocator) !SetRequest {
    const key = try cur.readLenPrefixedAlloc(alloc);
    errdefer alloc.free(key);
    const value = try cur.readLenPrefixedAlloc(alloc);
    errdefer alloc.free(value);
    const expected_seq = try cur.readU64Le();
    return .{ .key = key, .value = value, .expected_seq = expected_seq };
}

pub fn freeSetRequest(r: SetRequest, alloc: std.mem.Allocator) void {
    alloc.free(r.key);
    alloc.free(r.value);
}

// ---- Delete (C→S) ----

pub const DeleteRequest = struct {
    key: []const u8,
};

pub fn encodeDeleteRequest(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, r: DeleteRequest) !void {
    assert(r.key.len <= std.math.maxInt(u32));
    try appendU32Le(out, alloc, @intCast(r.key.len));
    try out.appendSlice(alloc, r.key);
}

pub fn decodeDeleteRequest(cur: *codec.Cursor, alloc: std.mem.Allocator) !DeleteRequest {
    return .{ .key = try cur.readLenPrefixedAlloc(alloc) };
}

pub fn freeDeleteRequest(r: DeleteRequest, alloc: std.mem.Allocator) void {
    alloc.free(r.key);
}

// ---- MutateResponse (S→C, for Set/Delete) ----

pub const MutateResponse = struct {
    committed_seq: u64,
    /// If expected_seq was set and CAS failed, this is the current seq.
    cas_failed: ?u64 = null,
};

pub fn encodeMutateResponse(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, r: MutateResponse) !void {
    try appendU64Le(out, alloc, r.committed_seq);
    if (r.cas_failed) |current| {
        try appendU8(out, alloc, 1);
        try appendU64Le(out, alloc, current);
    } else {
        try appendU8(out, alloc, 0);
    }
}

pub fn decodeMutateResponse(cur: *codec.Cursor) !MutateResponse {
    const committed_seq = try cur.readU64Le();
    const cas = try cur.readU8();
    const cas_failed: ?u64 = if (cas != 0) try cur.readU64Le() else null;
    return .{ .committed_seq = committed_seq, .cas_failed = cas_failed };
}

// ---- Range (C→S) ----

pub const RangeRequest = struct {
    start: []const u8,
    end: []const u8,
    /// Maximum number of keys to return. 0 = unlimited (server default).
    limit: u32 = 0,
};

pub fn encodeRangeRequest(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, r: RangeRequest) !void {
    assert(r.start.len <= std.math.maxInt(u32));
    assert(r.end.len <= std.math.maxInt(u32));
    try appendU32Le(out, alloc, @intCast(r.start.len));
    try out.appendSlice(alloc, r.start);
    try appendU32Le(out, alloc, @intCast(r.end.len));
    try out.appendSlice(alloc, r.end);
    try appendU32Le(out, alloc, r.limit);
}

pub fn decodeRangeRequest(cur: *codec.Cursor, alloc: std.mem.Allocator) !RangeRequest {
    const start = try cur.readLenPrefixedAlloc(alloc);
    errdefer alloc.free(start);
    const end = try cur.readLenPrefixedAlloc(alloc);
    errdefer alloc.free(end);
    const limit = try cur.readU32Le();
    return .{ .start = start, .end = end, .limit = limit };
}

pub fn freeRangeRequest(r: RangeRequest, alloc: std.mem.Allocator) void {
    alloc.free(r.start);
    alloc.free(r.end);
}

// ---- RangeEntry / RangeResponse (S→C) ----

pub const RangeEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub const RangeResponse = struct {
    entries: []const RangeEntry,
    committed_seq: u64,
};

pub fn encodeRangeResponse(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, r: RangeResponse) !void {
    try appendU64Le(out, alloc, r.committed_seq);
    assert(r.entries.len <= std.math.maxInt(u32));
    try appendU32Le(out, alloc, @intCast(r.entries.len));
    for (r.entries) |e| {
        assert(e.key.len <= std.math.maxInt(u32));
        assert(e.value.len <= std.math.maxInt(u32));
        try appendU32Le(out, alloc, @intCast(e.key.len));
        try out.appendSlice(alloc, e.key);
        try appendU32Le(out, alloc, @intCast(e.value.len));
        try out.appendSlice(alloc, e.value);
    }
}

pub fn decodeRangeResponse(cur: *codec.Cursor, alloc: std.mem.Allocator) !RangeResponse {
    const committed_seq = try cur.readU64Le();
    const entry_count = try cur.readU32Le();
    const entries = try alloc.alloc(RangeEntry, entry_count);
    var decoded: u32 = 0;
    errdefer {
        for (entries[0..decoded]) |e| {
            alloc.free(e.key);
            alloc.free(e.value);
        }
        alloc.free(entries);
    }
    while (decoded < entry_count) : (decoded += 1) {
        const key = try cur.readLenPrefixedAlloc(alloc);
        const value = try cur.readLenPrefixedAlloc(alloc);
        entries[decoded] = .{ .key = key, .value = value };
    }
    return .{ .entries = entries, .committed_seq = committed_seq };
}

pub fn freeRangeResponse(r: RangeResponse, alloc: std.mem.Allocator) void {
    for (r.entries) |e| {
        alloc.free(e.key);
        alloc.free(e.value);
    }
    alloc.free(r.entries);
}

// ──────────────────────────────────────────────────────────────
// Batch
// ──────────────────────────────────────────────────────────────

/// A single operation within a batch.
pub const BatchOp = union(enum) {
    get: GetRequest,
    set: SetRequest,
    delete: DeleteRequest,
    range: RangeRequest,

    pub fn deinit(self: BatchOp, alloc: std.mem.Allocator) void {
        switch (self) {
            .get => |r| freeGetRequest(r, alloc),
            .set => |r| freeSetRequest(r, alloc),
            .delete => |r| freeDeleteRequest(r, alloc),
            .range => |r| freeRangeRequest(r, alloc),
        }
    }
};

pub fn encodeBatchOp(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, op: BatchOp) !void {
    switch (op) {
        .get => |r| {
            try appendU8(out, alloc, 0);
            try encodeGetRequest(out, alloc, r);
        },
        .set => |r| {
            try appendU8(out, alloc, 1);
            try encodeSetRequest(out, alloc, r);
        },
        .delete => |r| {
            try appendU8(out, alloc, 2);
            try encodeDeleteRequest(out, alloc, r);
        },
        .range => |r| {
            try appendU8(out, alloc, 3);
            try encodeRangeRequest(out, alloc, r);
        },
    }
}

pub fn decodeBatchOp(cur: *codec.Cursor, alloc: std.mem.Allocator) !BatchOp {
    const tag = try cur.readU8();
    return switch (tag) {
        0 => .{ .get = try decodeGetRequest(cur, alloc) },
        1 => .{ .set = try decodeSetRequest(cur, alloc) },
        2 => .{ .delete = try decodeDeleteRequest(cur, alloc) },
        3 => .{ .range = try decodeRangeRequest(cur, alloc) },
        else => return error.ProtocolError,
    };
}

/// A single result within a batch response.
pub const BatchResult = union(enum) {
    get: GetResponse,
    mutate: MutateResponse,
    range: RangeResponse,

    pub fn deinit(self: BatchResult, alloc: std.mem.Allocator) void {
        switch (self) {
            .get => |r| freeGetResponse(r, alloc),
            .mutate => {},
            .range => |r| freeRangeResponse(r, alloc),
        }
    }
};

pub fn encodeBatchResult(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, res: BatchResult) !void {
    switch (res) {
        .get => |r| {
            try appendU8(out, alloc, 0);
            try encodeGetResponse(out, alloc, r);
        },
        .mutate => |r| {
            try appendU8(out, alloc, 1);
            try encodeMutateResponse(out, alloc, r);
        },
        .range => |r| {
            try appendU8(out, alloc, 2);
            try encodeRangeResponse(out, alloc, r);
        },
    }
}

pub fn decodeBatchResult(cur: *codec.Cursor, alloc: std.mem.Allocator) !BatchResult {
    const tag = try cur.readU8();
    return switch (tag) {
        0 => .{ .get = try decodeGetResponse(cur, alloc) },
        1 => .{ .mutate = try decodeMutateResponse(cur) },
        2 => .{ .range = try decodeRangeResponse(cur, alloc) },
        else => return error.ProtocolError,
    };
}

// ---- Batch (C→S) ----

pub fn encodeBatch(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, ops: []const BatchOp) !void {
    assert(ops.len <= std.math.maxInt(u32));
    try appendU32Le(out, alloc, @intCast(ops.len));
    for (ops) |op| try encodeBatchOp(out, alloc, op);
}

pub fn decodeBatch(cur: *codec.Cursor, alloc: std.mem.Allocator) ![]BatchOp {
    const count = try cur.readU32Le();
    const ops = try alloc.alloc(BatchOp, count);
    var decoded: u32 = 0;
    errdefer {
        for (ops[0..decoded]) |op| op.deinit(alloc);
        alloc.free(ops);
    }
    while (decoded < count) : (decoded += 1) {
        ops[decoded] = try decodeBatchOp(cur, alloc);
    }
    return ops;
}

pub fn freeBatch(ops: []BatchOp, alloc: std.mem.Allocator) void {
    for (ops) |op| op.deinit(alloc);
    alloc.free(ops);
}

// ---- BatchResponse (S→C) ----

pub fn encodeBatchResponse(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, results: []const BatchResult) !void {
    assert(results.len <= std.math.maxInt(u32));
    try appendU32Le(out, alloc, @intCast(results.len));
    for (results) |res| try encodeBatchResult(out, alloc, res);
}

pub fn decodeBatchResponse(cur: *codec.Cursor, alloc: std.mem.Allocator) ![]BatchResult {
    const count = try cur.readU32Le();
    const results = try alloc.alloc(BatchResult, count);
    var decoded: u32 = 0;
    errdefer {
        for (results[0..decoded]) |res| res.deinit(alloc);
        alloc.free(results);
    }
    while (decoded < count) : (decoded += 1) {
        results[decoded] = try decodeBatchResult(cur, alloc);
    }
    return results;
}

pub fn freeBatchResponse(results: []BatchResult, alloc: std.mem.Allocator) void {
    for (results) |res| res.deinit(alloc);
    alloc.free(results);
}

// ──────────────────────────────────────────────────────────────
// CDC / Subscribe
// ──────────────────────────────────────────────────────────────

pub const CdcOp = enum(u8) {
    insert = 0x00,
    update = 0x01,
    delete = 0x02,
};

pub const WireCdcEffect = struct {
    key: []const u8,
    op: CdcOp,
    before: ?[]const u8,
    after: ?[]const u8,
};

pub fn encodeCdcEffect(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, e: WireCdcEffect) !void {
    assert(e.key.len <= std.math.maxInt(u32));
    try appendU32Le(out, alloc, @intCast(e.key.len));
    try out.appendSlice(alloc, e.key);
    try appendU8(out, alloc, @intFromEnum(e.op));
    if (e.before) |v| {
        assert(v.len <= std.math.maxInt(u32));
        try appendU8(out, alloc, 1);
        try appendU32Le(out, alloc, @intCast(v.len));
        try out.appendSlice(alloc, v);
    } else {
        try appendU8(out, alloc, 0);
    }
    if (e.after) |v| {
        assert(v.len <= std.math.maxInt(u32));
        try appendU8(out, alloc, 1);
        try appendU32Le(out, alloc, @intCast(v.len));
        try out.appendSlice(alloc, v);
    } else {
        try appendU8(out, alloc, 0);
    }
}

pub fn decodeCdcEffect(cur: *codec.Cursor, alloc: std.mem.Allocator) !WireCdcEffect {
    const key = try cur.readLenPrefixedAlloc(alloc);
    errdefer alloc.free(key);
    const op: CdcOp = @enumFromInt(try cur.readU8());
    const has_before = try cur.readU8();
    const before: ?[]const u8 = if (has_before != 0) try cur.readLenPrefixedAlloc(alloc) else null;
    errdefer if (before) |v| alloc.free(v);
    const has_after = try cur.readU8();
    const after: ?[]const u8 = if (has_after != 0) try cur.readLenPrefixedAlloc(alloc) else null;
    return .{ .key = key, .op = op, .before = before, .after = after };
}

pub fn freeCdcEffect(e: WireCdcEffect, alloc: std.mem.Allocator) void {
    alloc.free(e.key);
    if (e.before) |v| alloc.free(v);
    if (e.after) |v| alloc.free(v);
}

pub fn encodeCdcEvent(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    seq: u64,
    epoch: u64,
    effects: []const WireCdcEffect,
) !void {
    assert(effects.len <= std.math.maxInt(u32));
    try appendU64Le(out, alloc, seq);
    try appendU64Le(out, alloc, epoch);
    try appendU32Le(out, alloc, @intCast(effects.len));
    for (effects) |e| try encodeCdcEffect(out, alloc, e);
}

// Subscribe / AckCdc (simplified — no table filters)
pub const Subscribe = struct {
    from_seq: u64,
    initial_credits: u32,
};

pub fn encodeSubscribe(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: Subscribe) !void {
    try appendU64Le(out, alloc, s.from_seq);
    try appendU32Le(out, alloc, s.initial_credits);
}

pub fn decodeSubscribe(cur: *codec.Cursor) !Subscribe {
    return .{
        .from_seq = try cur.readU64Le(),
        .initial_credits = try cur.readU32Le(),
    };
}

pub const AckCdc = struct {
    acked_seq: u64,
    add_credits: u32,
};

pub fn decodeAckCdc(cur: *codec.Cursor) !AckCdc {
    return .{
        .acked_seq = try cur.readU64Le(),
        .add_credits = try cur.readU32Le(),
    };
}

pub fn encodeAckCdc(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, a: AckCdc) !void {
    try appendU64Le(out, alloc, a.acked_seq);
    try appendU32Le(out, alloc, a.add_credits);
}

// Cancel
pub fn decodeCancel(cur: *codec.Cursor) !u64 {
    return cur.readU64Le();
}

pub fn encodeCancel(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, target: u64) !void {
    try appendU64Le(out, alloc, target);
}

// ──────────────────────────────────────────────────────────────
// Error
// ──────────────────────────────────────────────────────────────

pub const Severity = enum(u8) {
    @"error" = 0x00,
    fatal = 0x01,
};

pub const ErrorCode = enum(u16) {
    key_not_found = 0x0001,
    type_mismatch = 0x0002,
    cas_failed = 0x0003,
    transaction_aborted = 0x0006,
    retry_required = 0x0007,
    seq_not_available = 0x0008,
    auth_failed = 0x000A,
    permission_denied = 0x000B,
    server_error = 0x000C,
    protocol_error = 0x000D,
    canceled = 0x000E,
    tls_required = 0x000F,
    rate_limited = 0x0010,
    frame_too_large = 0x0011,
    key_too_large = 0x0012,
    value_too_large = 0x0013,
    batch_too_large = 0x0014,
};

pub fn encodeError(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    code: ErrorCode,
    severity: Severity,
    message: []const u8,
    detail: []const u8,
) !void {
    assert(message.len <= std.math.maxInt(u32));
    assert(detail.len <= std.math.maxInt(u32));
    try appendU16Le(out, alloc, @intFromEnum(code));
    try appendU8(out, alloc, @intFromEnum(severity));
    try appendU32Le(out, alloc, @intCast(message.len));
    try out.appendSlice(alloc, message);
    try appendU32Le(out, alloc, @intCast(detail.len));
    try out.appendSlice(alloc, detail);
}
