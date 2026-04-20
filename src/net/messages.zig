/// Per-kind message payload encode/decode for the FoldDB wire protocol.
const std = @import("std");
const codec = @import("codec.zig");
const frame = @import("frame.zig");

pub const TypedValue = codec.TypedValue;
pub const ColumnDesc = codec.ColumnDesc;
pub const Cursor = codec.Cursor;

// ---- Auth methods ----

pub const AuthMethod = enum(u8) {
    none = 0x00,
    plain = 0x01,
    token = 0x02,
    _,
};

// ---- Hello (S→C, stream 0) ----

pub const Hello = struct {
    server_version: []const u8,
    auth_methods: []const u8, // raw bytes: each byte is an AuthMethod value
    max_frame_payload_size: u32,
};

pub fn encodeHello(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, h: Hello) !void {
    try appendU8(out, alloc, @intCast(h.server_version.len));
    try out.appendSlice(alloc, h.server_version);
    try appendU8(out, alloc, @intCast(h.auth_methods.len));
    try out.appendSlice(alloc, h.auth_methods);
    try appendU32Le(out, alloc, h.max_frame_payload_size);
}

pub fn decodeHello(cur: *Cursor, alloc: std.mem.Allocator) !Hello {
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

pub const AuthPlain = struct {
    user: []const u8,
    password: []const u8,
};

pub const AuthToken = struct {
    token: []const u8,
};

pub const AuthPayload = union(AuthMethod) {
    none: void,
    plain: AuthPlain,
    token: AuthToken,
};

pub const Auth = struct {
    method: AuthMethod,
    client_max_frame_size: u32,
    payload: AuthPayload,
};

pub fn encodeAuth(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, a: Auth) !void {
    try appendU8(out, alloc, @intFromEnum(a.method));
    try appendU32Le(out, alloc, a.client_max_frame_size);
    switch (a.payload) {
        .none => {},
        .plain => |p| {
            try appendU8(out, alloc, @intCast(p.user.len));
            try out.appendSlice(alloc, p.user);
            try appendU16Le(out, alloc, @intCast(p.password.len));
            try out.appendSlice(alloc, p.password);
        },
        .token => |t| {
            try appendU16Le(out, alloc, @intCast(t.token.len));
            try out.appendSlice(alloc, t.token);
        },
    }
}

pub fn decodeAuth(cur: *Cursor, alloc: std.mem.Allocator) !Auth {
    const method_byte = try cur.readU8();
    const method_raw: AuthMethod = @enumFromInt(method_byte);
    const method = switch (method_raw) {
        .none, .plain, .token => method_raw,
        _ => return error.ProtocolError,
    };
    const client_max = try cur.readU32Le();
    const payload: AuthPayload = switch (method) {
        .none => .none,
        .plain => blk: {
            const user = try cur.readU8LenPrefixedAlloc(alloc);
            errdefer alloc.free(user);
            const pw_len = try cur.readU16Le();
            const pw_raw = try cur.readSlice(pw_len);
            const pw = try alloc.dupe(u8, pw_raw);
            break :blk .{ .plain = .{ .user = user, .password = pw } };
        },
        .token => blk: {
            const tok_len = try cur.readU16Le();
            const tok_raw = try cur.readSlice(tok_len);
            const tok = try alloc.dupe(u8, tok_raw);
            break :blk .{ .token = .{ .token = tok } };
        },
        _ => unreachable,
    };
    return .{ .method = method, .client_max_frame_size = client_max, .payload = payload };
}

pub fn freeAuth(a: Auth, alloc: std.mem.Allocator) void {
    switch (a.payload) {
        .none => {},
        .plain => |p| {
            alloc.free(p.user);
            alloc.free(p.password);
        },
        .token => |t| alloc.free(t.token),
    }
}

// ---- Ping (C→S / S→C, stream 0) ----

pub const Ping = struct { client_wall_micros: u64 };

pub fn encodePing(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, p: Ping) !void {
    try appendU64Le(out, alloc, p.client_wall_micros);
}

pub fn decodePing(cur: *Cursor) !Ping {
    return .{ .client_wall_micros = try cur.readU64Le() };
}

// ---- Pong (S→C, stream 0) ----

pub const Pong = struct {
    client_wall_micros: u64,
    server_wall_micros: u64,
};

pub fn encodePong(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, p: Pong) !void {
    try appendU64Le(out, alloc, p.client_wall_micros);
    try appendU64Le(out, alloc, p.server_wall_micros);
}

pub fn decodePong(cur: *Cursor) !Pong {
    return .{
        .client_wall_micros = try cur.readU64Le(),
        .server_wall_micros = try cur.readU64Le(),
    };
}

// ---- RegisterQuery (C→S) ----

pub const RegisterQuery = struct { sql: []const u8 };

pub fn encodeRegisterQuery(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, r: RegisterQuery) !void {
    try appendU32Le(out, alloc, @intCast(r.sql.len));
    try out.appendSlice(alloc, r.sql);
}

pub fn decodeRegisterQuery(cur: *Cursor, alloc: std.mem.Allocator) !RegisterQuery {
    return .{ .sql = try cur.readLenPrefixedAlloc(alloc) };
}

// ---- Registered (S→C, FINAL) ----

pub const Registered = struct {
    query_hash: [32]u8,
    param_tags: []const u8, // each byte is a TypeTag value
    columns: []const ColumnDesc,
};

pub fn encodeRegistered(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, r: Registered) !void {
    try out.appendSlice(alloc, &r.query_hash);
    try appendU8(out, alloc, @intCast(r.param_tags.len));
    try out.appendSlice(alloc, r.param_tags);
    try appendU16Le(out, alloc, @intCast(r.columns.len));
    for (r.columns) |cd| try codec.encodeColumnDesc(out, alloc, cd);
}

pub fn decodeRegistered(cur: *Cursor, alloc: std.mem.Allocator) !Registered {
    var hash: [32]u8 = undefined;
    const raw = try cur.readSlice(32);
    @memcpy(&hash, raw);
    const param_count = try cur.readU8();
    const param_raw = try cur.readSlice(param_count);
    const param_tags = try alloc.dupe(u8, param_raw);
    errdefer alloc.free(param_tags);
    const col_count = try cur.readU16Le();
    const columns = try alloc.alloc(ColumnDesc, col_count);
    var decoded: u16 = 0;
    errdefer {
        for (columns[0..decoded]) |cd| codec.freeColumnDesc(cd, alloc);
        alloc.free(columns);
    }
    while (decoded < col_count) : (decoded += 1) {
        columns[decoded] = try codec.decodeColumnDesc(cur, alloc);
    }
    return .{ .query_hash = hash, .param_tags = param_tags, .columns = columns };
}

pub fn freeRegistered(r: Registered, alloc: std.mem.Allocator) void {
    alloc.free(r.param_tags);
    for (r.columns) |cd| codec.freeColumnDesc(cd, alloc);
    alloc.free(r.columns);
}

// ---- Execute (C→S) ----

pub const Execute = struct {
    query_hash: [32]u8,
    params: []const TypedValue,
};

pub fn encodeExecute(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, e: Execute) !void {
    try out.appendSlice(alloc, &e.query_hash);
    try appendU16Le(out, alloc, @intCast(e.params.len));
    for (e.params) |p| try codec.encode(out, alloc, p);
}

pub fn decodeExecute(cur: *Cursor, alloc: std.mem.Allocator) !Execute {
    var hash: [32]u8 = undefined;
    @memcpy(&hash, try cur.readSlice(32));
    const param_count = try cur.readU16Le();
    const params = try alloc.alloc(TypedValue, param_count);
    var decoded: u16 = 0;
    errdefer {
        for (params[0..decoded]) |p| p.deinit(alloc);
        alloc.free(params);
    }
    while (decoded < param_count) : (decoded += 1) {
        params[decoded] = try codec.decode(cur, alloc);
    }
    return .{ .query_hash = hash, .params = params };
}

pub fn freeExecute(e: Execute, alloc: std.mem.Allocator) void {
    for (e.params) |p| p.deinit(alloc);
    alloc.free(e.params);
}

// ---- ReadAt (C→S) ----

pub const ReadAt = struct {
    query_hash: [32]u8,
    at_seq: u64,
    params: []const TypedValue,
};

pub fn encodeReadAt(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, r: ReadAt) !void {
    try out.appendSlice(alloc, &r.query_hash);
    try appendU64Le(out, alloc, r.at_seq);
    try appendU16Le(out, alloc, @intCast(r.params.len));
    for (r.params) |p| try codec.encode(out, alloc, p);
}

pub fn decodeReadAt(cur: *Cursor, alloc: std.mem.Allocator) !ReadAt {
    var hash: [32]u8 = undefined;
    @memcpy(&hash, try cur.readSlice(32));
    const at_seq = try cur.readU64Le();
    const param_count = try cur.readU16Le();
    const params = try alloc.alloc(TypedValue, param_count);
    var decoded: u16 = 0;
    errdefer {
        for (params[0..decoded]) |p| p.deinit(alloc);
        alloc.free(params);
    }
    while (decoded < param_count) : (decoded += 1) {
        params[decoded] = try codec.decode(cur, alloc);
    }
    return .{ .query_hash = hash, .at_seq = at_seq, .params = params };
}

pub fn freeReadAt(r: ReadAt, alloc: std.mem.Allocator) void {
    for (r.params) |p| p.deinit(alloc);
    alloc.free(r.params);
}

// ---- RowsBegin (S→C, MORE) ----

pub const RowsBegin = struct { columns: []const ColumnDesc };

pub fn encodeRowsBegin(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, r: RowsBegin) !void {
    try appendU16Le(out, alloc, @intCast(r.columns.len));
    for (r.columns) |cd| try codec.encodeColumnDesc(out, alloc, cd);
}

// ---- RowsBatch (S→C, MORE) ----
// row_count + row_count × (col_count × TypedValue)
// col_count is from the preceding RowsBegin, not carried in the frame.

pub fn encodeRowsBatch(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    rows: []const []const TypedValue,
) !void {
    try appendU32Le(out, alloc, @intCast(rows.len));
    for (rows) |row| {
        for (row) |v| try codec.encode(out, alloc, v);
    }
}

// ---- ExecOk (S→C, FINAL) ----

pub const ExecOk = struct {
    rows_affected: u64,
    committed_seq: u64,
};

pub fn encodeExecOk(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, e: ExecOk) !void {
    try appendU64Le(out, alloc, e.rows_affected);
    try appendU64Le(out, alloc, e.committed_seq);
}

pub fn decodeExecOk(cur: *Cursor) !ExecOk {
    return .{
        .rows_affected = try cur.readU64Le(),
        .committed_seq = try cur.readU64Le(),
    };
}

// ---- Subscribe (C→S) ----

pub const SubscribeScope = enum(u8) {
    all_tables = 0x00,
    filtered = 0x01,
    _,
};

pub const TableFilterKind = enum(u8) {
    by_id = 0x00,
    by_name = 0x01,
};

pub const TableFilter = union(TableFilterKind) {
    by_id: u32,
    by_name: []const u8,
};

pub const Subscribe = struct {
    from_seq: u64,
    initial_credits: u32,
    scope: SubscribeScope,
    filters: []const TableFilter, // len=0 when scope=all_tables
};

pub fn encodeSubscribe(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: Subscribe) !void {
    try appendU64Le(out, alloc, s.from_seq);
    try appendU32Le(out, alloc, s.initial_credits);
    try appendU8(out, alloc, @intFromEnum(s.scope));
    if (s.scope == .filtered) {
        try appendU16Le(out, alloc, @intCast(s.filters.len));
        for (s.filters) |f| {
            switch (f) {
                .by_id => |id| {
                    try appendU8(out, alloc, 0x00);
                    try appendU32Le(out, alloc, id);
                },
                .by_name => |name| {
                    try appendU8(out, alloc, 0x01);
                    try appendU8(out, alloc, @intCast(name.len));
                    try out.appendSlice(alloc, name);
                },
            }
        }
    }
}

pub fn decodeSubscribe(cur: *Cursor, alloc: std.mem.Allocator) !Subscribe {
    const from_seq = try cur.readU64Le();
    const credits = try cur.readU32Le();
    const scope_byte = try cur.readU8();
    const scope_raw: SubscribeScope = @enumFromInt(scope_byte);
    const scope = switch (scope_raw) {
        .all_tables, .filtered => scope_raw,
        _ => return error.ProtocolError,
    };
    var filters: []TableFilter = &.{};
    if (scope == .filtered) {
        const count = try cur.readU16Le();
        if (count == 0) return error.ProtocolError;
        filters = try alloc.alloc(TableFilter, count);
        var decoded: u16 = 0;
        errdefer {
            for (filters[0..decoded]) |f| {
                if (f == .by_name) alloc.free(f.by_name);
            }
            alloc.free(filters);
        }
        while (decoded < count) : (decoded += 1) {
            const kind_byte = try cur.readU8();
            filters[decoded] = switch (kind_byte) {
                0x00 => .{ .by_id = try cur.readU32Le() },
                0x01 => .{ .by_name = try cur.readU8LenPrefixedAlloc(alloc) },
                else => return error.ProtocolError,
            };
        }
    }
    return .{ .from_seq = from_seq, .initial_credits = credits, .scope = scope, .filters = filters };
}

pub fn freeSubscribe(s: Subscribe, alloc: std.mem.Allocator) void {
    for (s.filters) |f| {
        if (f == .by_name) alloc.free(f.by_name);
    }
    if (s.filters.len > 0) alloc.free(s.filters);
}

// ---- SubscribeAck (S→C, MORE) ----

pub const ResolvedName = struct {
    name: []const u8,
    table_id: u32,
};

pub fn encodeSubscribeAck(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    resolved: []const ResolvedName,
) !void {
    try appendU16Le(out, alloc, @intCast(resolved.len));
    for (resolved) |r| {
        try appendU8(out, alloc, @intCast(r.name.len));
        try out.appendSlice(alloc, r.name);
        try appendU32Le(out, alloc, r.table_id);
    }
}

// ---- CdcEvent (S→C, neither) ----

pub const CdcOp = enum(u8) {
    insert = 0x00,
    update = 0x01,
    delete = 0x02,
};

pub const WireCdcEffect = struct {
    table_id: u32,
    key: []const u8,
    op: CdcOp,
    before: []const TypedValue, // len=0 if absent
    after: []const TypedValue, // len=0 if absent
};

pub fn encodeCdcEffect(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, e: WireCdcEffect) !void {
    try appendU32Le(out, alloc, e.table_id);
    try appendU32Le(out, alloc, @intCast(e.key.len));
    try out.appendSlice(alloc, e.key);
    try appendU8(out, alloc, @intFromEnum(e.op));
    try appendU16Le(out, alloc, @intCast(e.before.len));
    for (e.before) |v| try codec.encode(out, alloc, v);
    try appendU16Le(out, alloc, @intCast(e.after.len));
    for (e.after) |v| try codec.encode(out, alloc, v);
}

pub fn encodeCdcEvent(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    seq: u64,
    epoch: u64,
    effects: []const WireCdcEffect,
) !void {
    try appendU64Le(out, alloc, seq);
    try appendU64Le(out, alloc, epoch);
    try appendU32Le(out, alloc, @intCast(effects.len));
    for (effects) |e| try encodeCdcEffect(out, alloc, e);
}

// ---- AckCdc (C→S) ----

pub const AckCdc = struct {
    acked_seq: u64,
    add_credits: u32,
};

pub fn decodeAckCdc(cur: *Cursor) !AckCdc {
    return .{
        .acked_seq = try cur.readU64Le(),
        .add_credits = try cur.readU32Le(),
    };
}

pub fn encodeAckCdc(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, a: AckCdc) !void {
    try appendU64Le(out, alloc, a.acked_seq);
    try appendU32Le(out, alloc, a.add_credits);
}

// ---- Cancel (C→S, stream_id=0) ----

pub fn decodeCancel(cur: *Cursor) !u64 {
    return cur.readU64Le();
}

pub fn encodeCancel(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, target: u64) !void {
    try appendU64Le(out, alloc, target);
}

// ---- Error (S→C) ----

pub const Severity = enum(u8) {
    @"error" = 0x00,
    fatal = 0x01,
};

pub const ErrorCode = enum(u16) {
    constraint_violation = 0x0001,
    type_mismatch = 0x0002,
    query_not_found = 0x0003,
    parse_error = 0x0004,
    type_error = 0x0005,
    transaction_aborted = 0x0006,
    retry_required = 0x0007,
    seq_not_available = 0x0008,
    schema_conflict = 0x0009,
    auth_failed = 0x000A,
    permission_denied = 0x000B,
    server_error = 0x000C,
    protocol_error = 0x000D,
    canceled = 0x000E,
    tls_required = 0x000F,
    rate_limited = 0x0010,
    frame_too_large = 0x0011,
};

pub fn encodeError(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    code: ErrorCode,
    severity: Severity,
    msg: []const u8,
    detail: []const u8,
) !void {
    try appendU16Le(out, alloc, @intFromEnum(code));
    try appendU8(out, alloc, @intFromEnum(severity));
    try appendU32Le(out, alloc, @intCast(msg.len));
    try out.appendSlice(alloc, msg);
    try appendU32Le(out, alloc, @intCast(detail.len));
    try out.appendSlice(alloc, detail);
}

// ---- helpers (module-local) ----

fn appendU8(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u8) !void {
    try out.append(alloc, v);
}

fn appendU16Le(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .little);
    try out.appendSlice(alloc, &buf);
}

fn appendU32Le(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try out.appendSlice(alloc, &buf);
}

fn appendU64Le(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    try out.appendSlice(alloc, &buf);
}
