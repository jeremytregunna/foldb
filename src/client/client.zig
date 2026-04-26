const std = @import("std");
const assert = std.debug.assert;
const frame = @import("frame.zig");
const codec = @import("codec.zig");
const messages = @import("messages.zig");

const net = std.Io.net;

pub const QueryHash = [32]u8;

/// Maximum frames consumed per response before treating the connection as broken.
const frames_per_response_max: u32 = 1 << 20;

pub const ExecResult = struct {
    rows_affected: u64,
    committed_seq: u64,
};

pub const Row = []messages.TypedValue;

pub const ResultSet = struct {
    columns: []messages.ColumnDesc,
    rows: []Row,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *ResultSet) void {
        assert(self.rows.len == 0 or self.columns.len > 0);
        for (self.rows) |row| {
            for (row) |value| value.deinit(self.alloc);
            self.alloc.free(row);
        }
        self.alloc.free(self.rows);
        for (self.columns) |column_desc| codec.freeColumnDesc(column_desc, self.alloc);
        if (self.columns.len > 0) self.alloc.free(self.columns);
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
    read_buf: [8192]u8,
    write_buf: [8192]u8,
    alloc: std.mem.Allocator,
    stream_id_next: u64,
    last_error: [256]u8,
    last_error_len: u32 = 0,

    fn init(io: std.Io, stream: net.Stream, alloc: std.mem.Allocator) Client {
        // SAFETY: reader, writer, read_buf, write_buf, and last_error are all initialized
        // in connect() before any method that reads them is called.
        return .{
            .io = io,
            .stream = stream,
            .reader = undefined,
            .writer = undefined,
            .read_buf = undefined,
            .write_buf = undefined,
            .alloc = alloc,
            .stream_id_next = 1,
            .last_error = undefined,
        };
    }

    pub fn deinit(self: *Client) void {
        self.stream.close(self.io);
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
        var cursor = codec.Cursor.init(payload);
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

    pub fn handshake(self: *Client) !void {
        hello_wait: {
            for (0..frames_per_response_max) |_| {
                const f = try self.read_frame();
                defer self.alloc.free(f.payload);
                switch (f.kind) {
                    .hello => {
                        var cursor = codec.Cursor.init(f.payload);
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

    pub fn register(self: *Client, sql: []const u8) !QueryHash {
        assert(sql.len > 0);
        const stream_id = self.alloc_stream_id();
        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(self.alloc);
        try messages.encodeRegisterQuery(&payload, self.alloc, .{ .sql = sql });
        try frame.sendFrameList(&self.writer.interface, stream_id, .register, frame.Flags.final_only, null, payload);
        return self.register_read_response(stream_id);
    }

    fn register_read_response(self: *Client, stream_id: u64) !QueryHash {
        assert(stream_id > 0);
        for (0..frames_per_response_max) |_| {
            const f = try self.read_frame();
            defer self.alloc.free(f.payload);
            if (f.stream_id != stream_id) continue;
            switch (f.kind) {
                .registered => {
                    var cursor = codec.Cursor.init(f.payload);
                    const registered = try messages.decodeRegistered(&cursor, self.alloc);
                    messages.freeRegistered(registered, self.alloc);
                    return registered.query_hash;
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

    pub fn execute(self: *Client, hash: QueryHash, params: []const messages.TypedValue) !ExecResult {
        const stream_id = self.alloc_stream_id();
        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(self.alloc);
        try messages.encodeExecute(&payload, self.alloc, .{ .query_hash = hash, .params = params });
        try frame.sendFrameList(&self.writer.interface, stream_id, .execute, frame.Flags.final_only, null, payload);
        return self.execute_read_ok(stream_id);
    }

    fn execute_read_ok(self: *Client, stream_id: u64) !ExecResult {
        assert(stream_id > 0);
        for (0..frames_per_response_max) |_| {
            const f = try self.read_frame();
            defer self.alloc.free(f.payload);
            if (f.stream_id != stream_id) continue;
            switch (f.kind) {
                .exec_ok => {
                    var cursor = codec.Cursor.init(f.payload);
                    const exec_ok = try messages.decodeExecOk(&cursor);
                    return .{
                        .rows_affected = exec_ok.rows_affected,
                        .committed_seq = exec_ok.committed_seq,
                    };
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

    pub fn query(self: *Client, hash: QueryHash, params: []const messages.TypedValue) !ResultSet {
        const stream_id = self.alloc_stream_id();
        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(self.alloc);
        try messages.encodeExecute(&payload, self.alloc, .{ .query_hash = hash, .params = params });
        try frame.sendFrameList(&self.writer.interface, stream_id, .execute, frame.Flags.final_only, null, payload);
        return self.query_read_result_set(stream_id);
    }

    fn query_read_result_set(self: *Client, stream_id: u64) !ResultSet {
        assert(stream_id > 0);
        var columns: []messages.ColumnDesc = &.{};
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        errdefer {
            for (rows.items) |row| {
                for (row) |value| value.deinit(self.alloc);
                self.alloc.free(row);
            }
            rows.deinit(self.alloc);
            for (columns) |column_desc| codec.freeColumnDesc(column_desc, self.alloc);
            if (columns.len > 0) self.alloc.free(columns);
        }

        for (0..frames_per_response_max) |_| {
            const f = try self.read_frame();
            defer self.alloc.free(f.payload);
            if (f.stream_id != stream_id) continue;
            switch (f.kind) {
                .rows_begin => {
                    assert(columns.len == 0); // protocol: rows_begin appears at most once
                    columns = try self.query_read_columns(f.payload);
                },
                .rows_batch => {
                    assert(columns.len > 0); // protocol: rows_batch must follow rows_begin
                    try self.query_read_batch(f.payload, columns, &rows);
                },
                .exec_ok => {
                    assert(rows.items.len == 0 or columns.len > 0);
                    return ResultSet{
                        .columns = columns,
                        .rows = try rows.toOwnedSlice(self.alloc),
                        .alloc = self.alloc,
                    };
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

    fn query_read_columns(self: *Client, payload: []const u8) ![]messages.ColumnDesc {
        var cursor = codec.Cursor.init(payload);
        const col_count = try cursor.readU16Le();
        assert(col_count > 0);
        const columns = try self.alloc.alloc(messages.ColumnDesc, col_count);
        var col_index: usize = 0;
        errdefer {
            for (columns[0..col_index]) |column_desc| codec.freeColumnDesc(column_desc, self.alloc);
            self.alloc.free(columns);
        }
        while (col_index < col_count) : (col_index += 1) {
            columns[col_index] = try codec.decodeColumnDesc(&cursor, self.alloc);
        }
        assert(col_index == col_count);
        return columns;
    }

    fn query_read_batch(
        self: *Client,
        payload: []const u8,
        columns: []const messages.ColumnDesc,
        rows: *std.ArrayListUnmanaged(Row),
    ) !void {
        assert(columns.len > 0);
        var cursor = codec.Cursor.init(payload);
        const row_count = try cursor.readU32Le();
        for (0..row_count) |_| {
            const row = try self.alloc.alloc(messages.TypedValue, columns.len);
            var values_decoded: usize = 0;
            errdefer {
                for (row[0..values_decoded]) |value| value.deinit(self.alloc);
                self.alloc.free(row);
            }
            while (values_decoded < columns.len) : (values_decoded += 1) {
                row[values_decoded] = try codec.decode(&cursor, self.alloc);
            }
            assert(values_decoded == columns.len);
            try rows.append(self.alloc, row);
        }
    }
};

/// Open a TCP connection to host:port using std.Io networking.
/// host must be a dotted-quad IPv4 string, e.g. "127.0.0.1".
pub fn connect_stream(io: std.Io, host: []const u8, port: u16) !net.Stream {
    assert(host.len > 0);
    assert(port > 0);
    const address = try net.IpAddress.parse(host, port);
    return address.connect(io, .{ .mode = .stream });
}

/// Connect to host:port and complete the Hello → Auth(none) → AuthOk handshake.
pub fn connect(io: std.Io, host: []const u8, port: u16, alloc: std.mem.Allocator) !Client {
    assert(host.len > 0);
    assert(port > 0);
    const stream = try connect_stream(io, host, port);
    var client = Client.init(io, stream, alloc);
    client.reader = stream.reader(io, &client.read_buf);
    client.writer = stream.writer(io, &client.write_buf);
    errdefer client.deinit();
    try client.handshake();
    return client;
}
