/// FoldDB client — KV wire protocol (GET, SET, DELETE, RANGE, BATCH).
const std = @import("std");
const assert = std.debug.assert;
const frame = @import("frame.zig");
const codec = @import("codec.zig");
const messages = @import("messages.zig");

const net = std.Io.net;

/// Maximum frames consumed per response before treating the connection as broken.
const frames_per_response_max: u32 = 1 << 20;

pub const MutateResult = struct {
    committed_seq: u64,
    cas_failed: ?u64 = null,
};

pub const RangeEntry = messages.RangeEntry;

pub const RangeResult = struct {
    entries: []const RangeEntry,
    committed_seq: u64,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *RangeResult) void {
        for (self.entries) |*e| {
            self.alloc.free(e.key);
            self.alloc.free(e.value);
        }
        self.alloc.free(self.entries);
    }
};

pub const GetResult = struct {
    value: ?[]const u8,
    committed_seq: u64,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *GetResult) void {
        if (self.value) |v| self.alloc.free(v);
    }
};

/// A single decoded frame from the server. The payload slice is caller-owned.
const Frame = struct {
    kind: frame.Kind,
    stream_id: u64,
    payload: []u8,
};

pub const Client = struct {
    io: std.Io,
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    read_buf: []u8,
    write_buf: []u8,
    alloc: std.mem.Allocator,
    stream_id_next: u64,
    last_error: [256]u8,
    last_error_len: u32 = 0,

    pub fn init(io: std.Io, stream: net.Stream, alloc: std.mem.Allocator) !Client {
        const read_buf = try alloc.alloc(u8, 8192);
        errdefer alloc.free(read_buf);
        const write_buf = try alloc.alloc(u8, 8192);
        return .{
            .io = io,
            .stream = stream,
            .reader = stream.reader(io, read_buf),
            .writer = stream.writer(io, write_buf),
            .read_buf = read_buf,
            .write_buf = write_buf,
            .alloc = alloc,
            .stream_id_next = 1,
            .last_error = undefined,
            .last_error_len = 0,
        };
    }

    pub fn deinit(self: *Client) void {
        self.stream.close(self.io);
        self.alloc.free(self.read_buf);
        self.alloc.free(self.write_buf);
    }

    fn alloc_stream_id(self: *Client) u64 {
        assert(self.stream_id_next > 0);
        const id = self.stream_id_next;
        self.stream_id_next += 1;
        assert(id > 0);
        return id;
    }

    fn store_error(self: *Client, payload: []const u8) void {
        if (payload.len < 7) return;
        var cursor = codec.Cursor{ .data = payload };
        cursor.pos += 3; // skip code(2) + severity(1)
        const msg_len = cursor.readU32Le() catch return;
        const msg = cursor.readSlice(@min(msg_len, self.last_error.len)) catch return;
        assert(msg.len <= self.last_error.len);
        @memcpy(self.last_error[0..msg.len], msg);
        self.last_error_len = @intCast(msg.len);
    }

    pub fn last_error_msg(self: *const Client) []const u8 {
        assert(self.last_error_len <= self.last_error.len);
        return self.last_error[0..self.last_error_len];
    }

    pub fn close(self: *Client) void {
        frame.sendFrame(&self.writer.interface, 0, .goodbye, frame.Flags.final_only, null, &.{}) catch |err| std.log.warn("close goodbye: {}", .{err});
        self.stream.close(self.io);
        self.alloc.free(self.read_buf);
        self.alloc.free(self.write_buf);
    }

    fn read_frame(self: *Client) !Frame {
        const header = try frame.readHeader(&self.reader.interface);
        const kind: frame.Kind = @enumFromInt(header.kind);
        if (@as(frame.Flags, @bitCast(header.flags)).trace) {
            _ = try frame.readTraceExt(&self.reader.interface);
        }
        const payload = try frame.readPayload(&self.reader.interface, header.payload_len, self.alloc);
        return .{ .kind = kind, .stream_id = header.stream_id, .payload = payload };
    }

    /// Wait for a response frame on the given stream_id.
    fn read_response(self: *Client, stream_id: u64) !Frame {
        assert(stream_id > 0);
        for (0..frames_per_response_max) |_| {
            const f = try self.read_frame();
            if (f.stream_id != stream_id) continue;
            switch (f.kind) {
                .response => return f,
                .range_rows => return f,
                .err => {
                    self.store_error(f.payload);
                    self.alloc.free(f.payload);
                    return error.ServerError;
                },
                else => continue,
            }
        }
        return error.TooManyFrames;
    }

    pub fn handshake(self: *Client, database_name: []const u8) !void {
        hello_wait: {
            for (0..frames_per_response_max) |_| {
                const f = try self.read_frame();
                defer self.alloc.free(f.payload);
                switch (f.kind) {
                    .hello => {
                        var cursor = codec.Cursor{ .data = f.payload };
                        const hello = try messages.decodeHello(&cursor, self.alloc);
                        messages.freeHello(hello, self.alloc);
                        break :hello_wait;
                    },
                    .err => return error.ServerError,
                    else => {},
                }
            }
            return error.TooManyFrames;
        }

        var auth_payload: std.ArrayListUnmanaged(u8) = .empty;
        defer auth_payload.deinit(self.alloc);
        try messages.encodeAuth(&auth_payload, self.alloc, .{
            .method = .none,
            .client_max_frame_size = frame.DEFAULT_MAX_PAYLOAD,
            .payload = .none,
            .database_name = database_name,
        });
        try frame.sendFrameList(&self.writer.interface, 0, .auth, frame.Flags.final_only, null, auth_payload);

        for (0..frames_per_response_max) |_| {
            const f = try self.read_frame();
            defer self.alloc.free(f.payload);
            switch (f.kind) {
                .auth_ok => return,
                .err => {
                    self.store_error(f.payload);
                    return error.AuthFailed;
                },
                else => {},
            }
        }
        return error.TooManyFrames;
    }

    // ─── KV Operations ───

    /// GET key → value | null
    pub fn get(self: *Client, key: []const u8) !GetResult {
        return self.get_at(key, std.math.maxInt(u64));
    }

    /// GET key at specific sequence (historical read).
    pub fn get_at(self: *Client, key: []const u8, at_seq: u64) !GetResult {
        const stream_id = self.alloc_stream_id();
        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(self.alloc);
        try messages.encodeGetRequest(&payload, self.alloc, .{ .key = key, .at_seq = at_seq });
        try frame.sendFrameList(&self.writer.interface, stream_id, .get, frame.Flags.final_only, null, payload);

        const f = try self.read_response(stream_id);
        defer self.alloc.free(f.payload);
        var cursor = codec.Cursor{ .data = f.payload };
        const res = try messages.decodeGetResponse(&cursor, self.alloc);
        return .{ .value = res.value, .committed_seq = res.committed_seq, .alloc = self.alloc };
    }

    /// SET key value → committed sequence number.
    pub fn set(self: *Client, key: []const u8, value: []const u8) !MutateResult {
        return self.set_cas(key, value, 0);
    }

    /// SET key value if current seq == expected_seq (compare-and-swap).
    pub fn set_cas(self: *Client, key: []const u8, value: []const u8, expected_seq: u64) !MutateResult {
        const stream_id = self.alloc_stream_id();
        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(self.alloc);
        try messages.encodeSetRequest(&payload, self.alloc, .{
            .key = key,
            .value = value,
            .expected_seq = expected_seq,
        });
        try frame.sendFrameList(&self.writer.interface, stream_id, .set, frame.Flags.final_only, null, payload);

        const f = try self.read_response(stream_id);
        defer self.alloc.free(f.payload);
        var cursor = codec.Cursor{ .data = f.payload };
        const res = try messages.decodeMutateResponse(&cursor);
        return .{ .committed_seq = res.committed_seq, .cas_failed = res.cas_failed };
    }

    /// DELETE key → committed sequence number.
    pub fn delete(self: *Client, key: []const u8) !MutateResult {
        const stream_id = self.alloc_stream_id();
        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(self.alloc);
        try messages.encodeDeleteRequest(&payload, self.alloc, .{ .key = key });
        try frame.sendFrameList(&self.writer.interface, stream_id, .delete, frame.Flags.final_only, null, payload);

        const f = try self.read_response(stream_id);
        defer self.alloc.free(f.payload);
        var cursor = codec.Cursor{ .data = f.payload };
        const res = try messages.decodeMutateResponse(&cursor);
        return .{ .committed_seq = res.committed_seq, .cas_failed = null };
    }

    /// RANGE start end → slice of (key, value) pairs.
    pub fn range(self: *Client, start: []const u8, end: []const u8) !RangeResult {
        return self.range_limit(start, end, 0);
    }

    /// RANGE start end with max limit.
    pub fn range_limit(self: *Client, start: []const u8, end: []const u8, limit: u32) !RangeResult {
        const stream_id = self.alloc_stream_id();
        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(self.alloc);
        try messages.encodeRangeRequest(&payload, self.alloc, .{
            .start = start,
            .end = end,
            .limit = limit,
        });
        try frame.sendFrameList(&self.writer.interface, stream_id, .range, frame.Flags.final_only, null, payload);

        const f = try self.read_response(stream_id);
        defer self.alloc.free(f.payload);
        var cursor = codec.Cursor{ .data = f.payload };
        const res = try messages.decodeRangeResponse(&cursor, self.alloc);
        return .{ .entries = res.entries, .committed_seq = res.committed_seq, .alloc = self.alloc };
    }

    /// BATCH []op → []result.
    pub fn batch(self: *Client, ops: []const messages.BatchOp) ![]messages.BatchResult {
        const stream_id = self.alloc_stream_id();
        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(self.alloc);
        try messages.encodeBatch(&payload, self.alloc, ops);
        try frame.sendFrameList(&self.writer.interface, stream_id, .batch, frame.Flags.final_only, null, payload);

        const f = try self.read_response(stream_id);
        defer self.alloc.free(f.payload);
        var cursor = codec.Cursor{ .data = f.payload };
        return try messages.decodeBatchResponse(&cursor, self.alloc);
    }

    // ─── Ping ───

    pub fn ping(self: *Client) !u64 {
        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(self.alloc);
        try messages.encodePing(&payload, self.alloc, .{
            .client_wall_micros = blk: { var tv: std.os.linux.timeval = undefined; _ = std.os.linux.gettimeofday(&tv, null); break :blk @as(u64, @intCast(tv.sec)) * 1000000 + @as(u64, @intCast(tv.usec)); }
        });
        try frame.sendFrameList(&self.writer.interface, 0, .ping, frame.Flags.final_only, null, payload);

        for (0..frames_per_response_max) |_| {
            const f = try self.read_frame();
            defer self.alloc.free(f.payload);
            switch (f.kind) {
                .pong => {
                    const now_micros: u64 = blk: { var tv: std.os.linux.timeval = undefined; _ = std.os.linux.gettimeofday(&tv, null); break :blk @as(u64, @intCast(tv.sec)) * 1000000 + @as(u64, @intCast(tv.usec)); };
                    var cursor = codec.Cursor{ .data = f.payload };
                    const pong = try messages.decodePong(&cursor);
                    return now_micros - pong.client_wall_micros;
                },
                .err => {
                    self.store_error(f.payload);
                    return error.ServerError;
                },
                else => {},
            }
        }
        return error.TooManyFrames;
    }
};

// ─── Connection helpers ───

fn setNoDelay(fd: std.posix.fd_t) void {
    const one: u32 = 1;
    _ = std.os.linux.setsockopt(
        fd,
        std.os.linux.IPPROTO.TCP,
        std.os.linux.TCP.NODELAY,
        @ptrCast(&one),
        @sizeOf(u32),
    );
}

pub fn connect_stream(io: std.Io, host: []const u8, port: u16) !net.Stream {
    assert(host.len > 0);
    assert(port > 0);
    const address = try net.IpAddress.parse(host, port);
    const stream = try address.connect(io, .{ .mode = .stream });
    setNoDelay(stream.socket.handle);
    return stream;
}

/// Connect to host:port and complete the Hello → Auth(none) → AuthOk handshake.
pub fn connect(io: std.Io, host: []const u8, port: u16, database_name: []const u8, alloc: std.mem.Allocator) !Client {
    assert(host.len > 0);
    assert(port > 0);
    const stream = try connect_stream(io, host, port);
    var client = try Client.init(io, stream, alloc);
    errdefer client.deinit();
    try client.handshake(database_name);
    return client;
}
