/// Foldb Gateway — KV RPC handler.
/// Routes decoded wire protocol messages → sequencer → executor → storage → response.
const std = @import("std");
const executor_mod = @import("executor.zig");
const storage_mod = @import("storage.zig");
const log_mod = @import("log.zig");
const sequencer_mod = @import("sequencer.zig");
const codec = @import("codec.zig");
const frame = @import("frame.zig");
const messages = @import("messages.zig");
const entry_mod = log_mod.entry;

const Executor = executor_mod.Executor;
const Storage = storage_mod.Storage;
const LogEntry = log_mod.LogEntry;
const KvOp = entry_mod.KvOp;
const TxnIntent = entry_mod.TxnIntent;
const Sequencer = sequencer_mod.Sequencer;
const PendingSubmit = sequencer_mod.PendingSubmit;
const Mutation = storage_mod.Mutation;
const Row = storage_mod.Row;
const KeyRange = storage_mod.KeyRange;
const LogMux = log_mod.LogMux;

const assert = std.debug.assert;

pub const default_table_id: storage_mod.TableId = 1;

pub const Options = struct {
    io: ?std.Io = null,
    partition_count: u32 = 1,
    node_id: u64 = 1,
    tick_interval_ms: u32 = 10,
    election_timeout_min_ms: u32 = 150,
    election_timeout_max_ms: u32 = 300,
    heartbeat_interval_ms: u32 = 50,
    peers: []const sequencer_mod.PeerAddr = &.{},
    s3_io: ?std.Io = null,
    s3_endpoint_host: []const u8 = "",
    s3_endpoint_port: u16 = 0,
    s3_access_key: []const u8 = "",
    s3_secret_key: []const u8 = "",
    s3_region: []const u8 = "",
    s3_bucket: []const u8 = "",
};

pub const Gateway = struct {
    storage: Storage,
    sequencer: Sequencer,
    executor: Executor,
    alloc: std.mem.Allocator,

    pub fn init(storage_dir: []const u8, alloc: std.mem.Allocator, opts: Options) !*Gateway {
        assert(storage_dir.len > 0);
        const gw = try alloc.create(Gateway);
        errdefer alloc.destroy(gw);

        var storage = try Storage.init(storage_dir, alloc);
        errdefer storage.deinit();
        try storage.registerTable(default_table_id);

        var sequencer = try Sequencer.init(storage_dir, .{
            .partition_count = opts.partition_count,
            .node_id = opts.node_id,
            .tick_interval_ms = opts.tick_interval_ms,
            .election_timeout_min_ms = opts.election_timeout_min_ms,
            .election_timeout_max_ms = opts.election_timeout_max_ms,
            .heartbeat_interval_ms = opts.heartbeat_interval_ms,
            .peers = opts.peers,
        }, alloc);
        errdefer sequencer.deinit();

        gw.* = .{
            .storage = storage,
            .sequencer = sequencer,
            .executor = Executor.init(&gw.storage, alloc),
            .alloc = alloc,
        };

        try gw.replayLogs();
        try gw.sequencer.start();
        return gw;
    }

    pub fn deinit(self: *Gateway) void {
        self.replayLogs() catch |err| std.log.warn("gateway replay during shutdown: {}", .{err});
        self.storage.flushAll() catch |err| std.log.warn("gateway flush during shutdown: {}", .{err});
        self.executor.deinit();
        self.sequencer.deinit();
        self.storage.deinit();
        self.alloc.destroy(self);
    }

    fn replayLogs(self: *Gateway) !void {
        const logs = self.sequencer.logPartitionLogs();
        const ptrs = try self.alloc.alloc(*log_mod.Log, logs.len);
        defer self.alloc.free(ptrs);
        for (logs, 0..) |*log, i| ptrs[i] = log;

        var mux = LogMux.init(try self.alloc.dupe(*log_mod.Log, ptrs), self.alloc);
        defer mux.deinit();

        var from_seq: u64 = 1;
        while (true) {
            const entries = try mux.read(from_seq, 256, self.alloc);
            defer {
                for (entries) |*entry| entry.deinit(self.alloc);
                self.alloc.free(entries);
            }
            if (entries.len == 0) break;
            for (entries) |entry| {
                _ = try self.executor.run(entry);
            }
            from_seq = entries[entries.len - 1].header.seq + 1;
            if (entries.len < 256) break;
        }
    }
};

/// A single KV operation request, with metadata for encoding the response.
pub const Request = struct {
    kind: frame.Kind,
    stream_id: u64,
    get_req: ?messages.GetRequest = null,
    set_req: ?messages.SetRequest = null,
    delete_req: ?messages.DeleteRequest = null,
    range_req: ?messages.RangeRequest = null,
    batch_ops: ?[]messages.BatchOp = null,
    /// Payload memory to free after processing.
    payload_buf: ?[]u8 = null,
    /// Trace extension bytes (present when frame flags.trace = true).
    trace_id: ?[frame.TRACE_EXT_SIZE]u8 = null,

    pub fn deinit(self: Request, alloc: std.mem.Allocator) void {
        if (self.get_req) |*r| messages.freeGetRequest(r.*, alloc);
        if (self.set_req) |*r| messages.freeSetRequest(r.*, alloc);
        if (self.delete_req) |*r| messages.freeDeleteRequest(r.*, alloc);
        if (self.range_req) |*r| messages.freeRangeRequest(r.*, alloc);
        if (self.batch_ops) |ops| messages.freeBatch(ops, alloc);
        if (self.payload_buf) |buf| alloc.free(buf);
    }
};

/// Decode a frame payload into a Request. Caller must call deinit().
pub fn decodeRequest(kind: frame.Kind, stream_id: u64, payload: []const u8, alloc: std.mem.Allocator) !Request {
    var cur = codec.Cursor{ .data = payload };
    return switch (kind) {
        .get => .{
            .kind = kind,
            .stream_id = stream_id,
            .get_req = try messages.decodeGetRequest(&cur, alloc),
        },
        .set => .{
            .kind = kind,
            .stream_id = stream_id,
            .set_req = try messages.decodeSetRequest(&cur, alloc),
        },
        .delete => .{
            .kind = kind,
            .stream_id = stream_id,
            .delete_req = try messages.decodeDeleteRequest(&cur, alloc),
        },
        .range => .{
            .kind = kind,
            .stream_id = stream_id,
            .range_req = try messages.decodeRangeRequest(&cur, alloc),
        },
        .batch => .{
            .kind = kind,
            .stream_id = stream_id,
            .batch_ops = try messages.decodeBatch(&cur, alloc),
        },
        else => return error.ProtocolError,
    };
}

/// Encode an error frame payload and send it back to the client.
pub fn sendError(writer: anytype, alloc: std.mem.Allocator, stream_id: u64,
    code: messages.ErrorCode,
    severity: messages.Severity,
    message: []const u8,
    detail: []const u8,
) !void {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(alloc);
    try messages.encodeError(&payload, alloc, code, severity, message, detail);
    try frame.sendFrameList(writer, stream_id, .err, frame.Flags.final_only, null, payload);
}

/// Encode a response frame payload and send it back.
fn sendResponse(writer: anytype, stream_id: u64, kind: frame.Kind, payload: []const u8) !void {
    try frame.sendFrame(writer, stream_id, kind, frame.Flags.final_only, null, payload);
}

// ─── KV operation handlers ───

/// Handle GET request.
pub fn handleGet(writer: anytype, alloc: std.mem.Allocator, stream_id: u64,
    req: messages.GetRequest,
    storage: *Storage,
) !void {
    errdefer sendError(writer, alloc, stream_id, .server_error, .@"error", "get failed", "") catch {};
    const result = try storage.get(default_table_id, req.key, req.at_seq);
    defer if (result) |row| row.deinit(alloc);
    const row_value: ?[]const u8 = if (result) |row| blk: {
        if (row.is_tombstone) break :blk null;
        if (row.value.len == 0) break :blk null;
        break :blk row.value;
    } else null;
    const row_seq: u64 = if (result) |row| row.seq else 0;
    const res = messages.GetResponse{ .value = row_value, .committed_seq = row_seq };

    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(alloc);
    try messages.encodeGetResponse(&payload, alloc, res);
    try sendResponse(writer, stream_id, .response, payload.items);
}

/// Handle SET request — submits through Sequencer for global ordering.
pub fn handleSet(writer: anytype, alloc: std.mem.Allocator, stream_id: u64,
    req: messages.SetRequest,
    storage: *Storage,
    sequencer: *Sequencer,
) !void {
    errdefer sendError(writer, alloc, stream_id, .server_error, .@"error", "set failed", "") catch {};

    // CAS check
    if (req.expected_seq > 0) {
        const current = try storage.get(default_table_id, req.key, std.math.maxInt(u64));
        defer if (current) |row| row.deinit(alloc);
        if (current) |row| {
            if (row.seq != req.expected_seq) {
                const res = messages.MutateResponse{ .committed_seq = row.seq, .cas_failed = row.seq };
                var payload: std.ArrayListUnmanaged(u8) = .empty;
                defer payload.deinit(alloc);
                try messages.encodeMutateResponse(&payload, alloc, res);
                try sendResponse(writer, stream_id, .response, payload.items);
                return;
            }
        } else {
            // Key not found but expected_seq > 0 → CAS fail
            const res = messages.MutateResponse{ .committed_seq = 0, .cas_failed = null };
            var payload: std.ArrayListUnmanaged(u8) = .empty;
            defer payload.deinit(alloc);
            try messages.encodeMutateResponse(&payload, alloc, res);
            try sendResponse(writer, stream_id, .response, payload.items);
            return;
        }
    }

    // Build intent and submit through sequencer
    const ops = [_]KvOp{ .{ .set = .{ .key = req.key, .value = req.value } } };
    const seq = sequencer.currentSeq() + 1;
    const payload_bytes = try TxnIntent.init(&ops, &.{}, &.{1}, 1, seq).serialize_to(alloc);
    defer alloc.free(payload_bytes);

    var pending: PendingSubmit = undefined;
    const handle = sequencer.submitBytes(&pending, payload_bytes, 0, seq, .txn_intent);
    const result = try handle.awaitCommit(null);

    // Apply directly to storage for immediate read-after-write consistency.
    const mutations = [_]Mutation{
        .{ .kind = .update, .table_id = default_table_id, .key = req.key, .value = req.value },
    };
    try storage.apply(&mutations, result.seq);

    // Send response
    const res = messages.MutateResponse{ .committed_seq = result.seq, .cas_failed = null };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try messages.encodeMutateResponse(&out, alloc, res);
    try sendResponse(writer, stream_id, .response, out.items);
}

/// Handle DELETE request — submits through Sequencer for global ordering.
pub fn handleDelete(writer: anytype, alloc: std.mem.Allocator, stream_id: u64,
    req: messages.DeleteRequest,
    storage: *Storage,
    sequencer: *Sequencer,
) !void {
    errdefer sendError(writer, alloc, stream_id, .server_error, .@"error", "delete failed", "") catch {};

    const ops = [_]KvOp{ .{ .delete = .{ .key = req.key } } };
    const seq = sequencer.currentSeq() + 1;
    const payload_bytes = try TxnIntent.init(&ops, &.{}, &.{1}, 1, seq).serialize_to(alloc);
    defer alloc.free(payload_bytes);

    var pending: PendingSubmit = undefined;
    const handle = sequencer.submitBytes(&pending, payload_bytes, 0, seq, .txn_intent);
    const result = try handle.awaitCommit(null);

    // Apply directly to storage for immediate read-after-write consistency.
    const mutations = [_]Mutation{
        .{ .kind = .delete, .table_id = default_table_id, .key = req.key, .value = null },
    };
    try storage.apply(&mutations, result.seq);

    const res = messages.MutateResponse{ .committed_seq = result.seq, .cas_failed = null };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try messages.encodeMutateResponse(&out, alloc, res);
    try sendResponse(writer, stream_id, .response, out.items);
}

/// Handle RANGE request.
pub fn handleRange(writer: anytype, alloc: std.mem.Allocator, stream_id: u64,
    req: messages.RangeRequest,
    storage: *Storage,
    sequencer: *Sequencer,
) !void {
    errdefer sendError(writer, alloc, stream_id, .server_error, .@"error", "range failed", "") catch {};

    const range = KeyRange{ .start = req.start, .end = req.end, .start_inclusive = true };
    var iter = try storage.scan(default_table_id, range, std.math.maxInt(u64), alloc);
    defer iter.deinit();

    var entries: std.ArrayList(messages.RangeEntry) = .empty;
    defer {
        for (entries.items) |e| {
            alloc.free(e.key);
            alloc.free(e.value);
        }
        if (entries.capacity > 0) entries.deinit(alloc);
    }

    const limit: usize = if (req.limit > 0) @intCast(req.limit) else std.math.maxInt(usize);
    while (entries.items.len < limit) {
        const row = try iter.next() orelse break;
        var entry: messages.RangeEntry = undefined;
        entry.key = try alloc.dupe(u8, row.key);
        if (row.is_tombstone) {
            entry.value = try alloc.dupe(u8, &.{});
        } else {
            entry.value = try alloc.dupe(u8, row.value);
        }
        try entries.append(alloc, entry);
    }

    const res = messages.RangeResponse{ .entries = entries.items, .committed_seq = sequencer.currentSeq() };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try messages.encodeRangeResponse(&out, alloc, res);
    try sendResponse(writer, stream_id, .response, out.items);
}

/// Handle BATCH request — mutations go through Sequencer.
pub fn handleBatch(writer: anytype, alloc: std.mem.Allocator, stream_id: u64,
    ops: []messages.BatchOp,
    storage: *Storage,
    sequencer: *Sequencer,
) !void {
    errdefer sendError(writer, alloc, stream_id, .server_error, .@"error", "batch failed", "") catch {};

    var results: std.ArrayList(messages.BatchResult) = .empty;
    defer {
        for (results.items) |r| r.deinit(alloc);
        if (results.capacity > 0) results.deinit(alloc);
    }

    for (ops) |op| {
        switch (op) {
            .get => |req| {
                const result = try storage.get(default_table_id, req.key, req.at_seq);
                defer if (result) |row| row.deinit(alloc);
                const value: ?[]const u8 = if (result) |row| blk: {
                    if (row.is_tombstone) break :blk null;
                    break :blk row.value;
                } else null;
                const row_seq: u64 = if (result) |row| row.seq else 0;
                const res = messages.GetResponse{ .value = value, .committed_seq = row_seq };
                try results.append(alloc, .{ .get = res });
            },
            .set => |req| {
                const ops2 = [_]KvOp{ .{ .set = .{ .key = req.key, .value = req.value } } };
                const seq = sequencer.currentSeq() + 1;
                const payload_bytes = try TxnIntent.init(&ops2, &.{}, &.{1}, 1, seq).serialize_to(alloc);
                defer alloc.free(payload_bytes);
                var pending: PendingSubmit = undefined;
                const handle = sequencer.submitBytes(&pending, payload_bytes, 0, seq, .txn_intent);
                const result = try handle.awaitCommit(null);
                const mutations = [_]Mutation{
                    .{ .kind = .update, .table_id = default_table_id, .key = req.key, .value = req.value },
                };
                try storage.apply(&mutations, result.seq);
                try results.append(alloc, .{ .mutate = .{ .committed_seq = result.seq, .cas_failed = null } });
            },
            .delete => |req| {
                const ops2 = [_]KvOp{ .{ .delete = .{ .key = req.key } } };
                const seq = sequencer.currentSeq() + 1;
                const payload_bytes = try TxnIntent.init(&ops2, &.{}, &.{1}, 1, seq).serialize_to(alloc);
                defer alloc.free(payload_bytes);
                var pending: PendingSubmit = undefined;
                const handle = sequencer.submitBytes(&pending, payload_bytes, 0, seq, .txn_intent);
                const result = try handle.awaitCommit(null);
                const mutations = [_]Mutation{
                    .{ .kind = .delete, .table_id = default_table_id, .key = req.key, .value = null },
                };
                try storage.apply(&mutations, result.seq);
                try results.append(alloc, .{ .mutate = .{ .committed_seq = result.seq, .cas_failed = null } });
            },
            .range => |req| {
                const range = KeyRange{ .start = req.start, .end = req.end, .start_inclusive = true };
                var iter = try storage.scan(default_table_id, range, std.math.maxInt(u64), alloc);
                defer iter.deinit();
                var entries: std.ArrayList(messages.RangeEntry) = .empty;
                defer {
                    for (entries.items) |e| {
                        alloc.free(e.key);
                        alloc.free(e.value);
                    }
                    if (entries.capacity > 0) entries.deinit(alloc);
                }
                const limit: usize = if (req.limit > 0) @intCast(req.limit) else std.math.maxInt(usize);
                while (entries.items.len < limit) {
                    const row = try iter.next() orelse break;
                    var entry: messages.RangeEntry = undefined;
                    entry.key = try alloc.dupe(u8, row.key);
                    if (row.is_tombstone) {
                        entry.value = try alloc.dupe(u8, &.{});
                    } else {
                        entry.value = try alloc.dupe(u8, row.value);
                    }
                    try entries.append(alloc, entry);
                }
                try results.append(alloc, .{ .range = .{ .entries = entries.items, .committed_seq = sequencer.currentSeq() } });
            },
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try messages.encodeBatchResponse(&out, alloc, results.items);
    try sendResponse(writer, stream_id, .response, out.items);
}

// ─── Connection handler ───

/// Handle the Hello/Auth handshake on stream 0.
/// Send Hello frame to client on connection.
pub fn handleHello(writer: anytype, alloc: std.mem.Allocator) !void {
    var hello: std.ArrayListUnmanaged(u8) = .empty;
    defer hello.deinit(alloc);
    try messages.encodeHello(&hello, alloc, .{
        .server_version = "0.1.0",
        .auth_methods = "none",
        .max_frame_payload_size = frame.DEFAULT_MAX_PAYLOAD,
    });
    try frame.sendFrame(writer, 0, .hello, frame.Flags.final_only, null, hello.items);
}

/// Accept client .auth → send .auth_ok.
pub fn handleAuthResponse(writer: anytype, alloc: std.mem.Allocator,
    payload: []const u8,
) !void {
    var cur = codec.Cursor{ .data = payload };
    const auth = try messages.decodeAuth(&cur, alloc);
    defer messages.freeAuth(auth, alloc);

    // Accept no-auth connections
    var ok: std.ArrayListUnmanaged(u8) = .empty;
    defer ok.deinit(alloc);
    try frame.sendFrame(writer, 0, .auth_ok, frame.Flags.final_only, null, ok.items);
}

/// Handle Ping → Pong.
pub fn handlePing(writer: anytype, alloc: std.mem.Allocator, payload: []const u8) !void {
    var cur = codec.Cursor{ .data = payload };
    const ping = try messages.decodePing(&cur);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try messages.encodePong(&out, alloc, .{
        .client_wall_micros = ping.client_wall_micros,
        .server_wall_micros = getMicroTimestamp(),
    });
    try frame.sendFrame(writer, 0, .pong, frame.Flags.final_only, null, out.items);
}

/// Portable microsecond timestamp (Zig 0.16 has no std.time.microTimestamp).
fn getMicroTimestamp() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(@as(i32, @intCast(ts.nsec)))) / 1_000;
}
