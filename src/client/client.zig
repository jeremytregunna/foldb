const std = @import("std");
const frame = @import("frame.zig");
const codec = @import("codec.zig");
const messages = @import("messages.zig");

pub const QueryHash = [32]u8;

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
        for (self.rows) |row| {
            for (row) |v| v.deinit(self.alloc);
            self.alloc.free(row);
        }
        self.alloc.free(self.rows);
        for (self.columns) |cd| codec.freeColumnDesc(cd, self.alloc);
        self.alloc.free(self.columns);
    }
};

pub const Client = struct {
    fd: std.posix.fd_t,
    alloc: std.mem.Allocator,
    next_stream_id: u64,
    last_error: [256]u8 = undefined,
    last_error_len: usize = 0,

    pub fn init(fd: std.posix.fd_t, alloc: std.mem.Allocator) Client {
        return .{ .fd = fd, .alloc = alloc, .next_stream_id = 1 };
    }

    pub fn deinit(self: *Client) void {
        _ = std.os.linux.close(@intCast(self.fd));
    }

    fn nextStreamId(self: *Client) u64 {
        const id = self.next_stream_id;
        self.next_stream_id += 1;
        return id;
    }

    fn storeError(self: *Client, payload: []const u8) void {
        if (payload.len < 7) return;
        var cur = codec.Cursor.init(payload);
        cur.pos += 3; // skip code(2) + severity(1)
        const msg_len = cur.readU32Le() catch return;
        const msg = cur.readSlice(@min(msg_len, self.last_error.len)) catch return;
        @memcpy(self.last_error[0..msg.len], msg);
        self.last_error_len = msg.len;
    }

    pub fn lastError(self: *const Client) []const u8 {
        return self.last_error[0..self.last_error_len];
    }

    pub fn close(self: *Client) void {
        frame.sendFrame(self.fd, 0, .goodbye, frame.Flags.final_only, null, &.{}) catch {};
        _ = std.os.linux.close(@intCast(self.fd));
    }

    // ---- Handshake ----

    pub fn handshake(self: *Client) !void {
        while (true) {
            const hdr = try frame.readHeader(self.fd);
            const kind: frame.Kind = @enumFromInt(hdr.kind);
            if (@as(frame.Flags, @bitCast(hdr.flags)).trace) _ = try frame.readTraceExt(self.fd);
            const payload = try frame.readPayload(self.fd, hdr.payload_len, self.alloc);
            defer self.alloc.free(payload);
            switch (kind) {
                .hello => {
                    var cur = codec.Cursor.init(payload);
                    const hello = try messages.decodeHello(&cur, self.alloc);
                    messages.freeHello(hello, self.alloc);
                    break;
                },
                .err => return error.ServerError,
                else => {},
            }
        }

        var auth_payload: std.ArrayListUnmanaged(u8) = .empty;
        defer auth_payload.deinit(self.alloc);
        try messages.encodeAuth(&auth_payload, self.alloc, .{
            .method = .none,
            .client_max_frame_size = frame.DEFAULT_MAX_PAYLOAD,
            .payload = .none,
        });
        try frame.sendFrameList(self.fd, 0, .auth, frame.Flags.final_only, null, auth_payload);

        while (true) {
            const hdr = try frame.readHeader(self.fd);
            const kind: frame.Kind = @enumFromInt(hdr.kind);
            if (@as(frame.Flags, @bitCast(hdr.flags)).trace) _ = try frame.readTraceExt(self.fd);
            const payload = try frame.readPayload(self.fd, hdr.payload_len, self.alloc);
            defer self.alloc.free(payload);
            switch (kind) {
                .auth_ok => return,
                .err => {
                    self.storeError(payload);
                    return error.AuthFailed;
                },
                else => {},
            }
        }
    }

    // ---- Register ----

    pub fn register(self: *Client, sql: []const u8) !QueryHash {
        const stream_id = self.nextStreamId();

        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(self.alloc);
        try messages.encodeRegisterQuery(&payload, self.alloc, .{ .sql = sql });
        try frame.sendFrameList(self.fd, stream_id, .register, frame.Flags.final_only, null, payload);

        return self.readRegistered(stream_id);
    }

    fn readRegistered(self: *Client, stream_id: u64) !QueryHash {
        while (true) {
            const hdr = try frame.readHeader(self.fd);
            const kind: frame.Kind = @enumFromInt(hdr.kind);
            if (@as(frame.Flags, @bitCast(hdr.flags)).trace) _ = try frame.readTraceExt(self.fd);
            const payload = try frame.readPayload(self.fd, hdr.payload_len, self.alloc);
            defer self.alloc.free(payload);
            if (hdr.stream_id != stream_id) continue;
            switch (kind) {
                .registered => {
                    var cur = codec.Cursor.init(payload);
                    const reg = try messages.decodeRegistered(&cur, self.alloc);
                    messages.freeRegistered(reg, self.alloc);
                    return reg.query_hash;
                },
                .err => {
                    self.storeError(payload);
                    return error.ServerError;
                },
                else => {},
            }
        }
    }

    // ---- Execute ----

    pub fn execute(self: *Client, hash: QueryHash, params: []const messages.TypedValue) !ExecResult {
        const stream_id = self.nextStreamId();

        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(self.alloc);
        try messages.encodeExecute(&payload, self.alloc, .{ .query_hash = hash, .params = params });
        try frame.sendFrameList(self.fd, stream_id, .execute, frame.Flags.final_only, null, payload);

        return self.readExecOk(stream_id);
    }

    fn readExecOk(self: *Client, stream_id: u64) !ExecResult {
        while (true) {
            const hdr = try frame.readHeader(self.fd);
            const kind: frame.Kind = @enumFromInt(hdr.kind);
            if (@as(frame.Flags, @bitCast(hdr.flags)).trace) _ = try frame.readTraceExt(self.fd);
            const payload = try frame.readPayload(self.fd, hdr.payload_len, self.alloc);
            defer self.alloc.free(payload);
            if (hdr.stream_id != stream_id) continue;
            switch (kind) {
                .exec_ok => {
                    var cur = codec.Cursor.init(payload);
                    const ok = try messages.decodeExecOk(&cur);
                    return .{ .rows_affected = ok.rows_affected, .committed_seq = ok.committed_seq };
                },
                .err => {
                    self.storeError(payload);
                    return error.ServerError;
                },
                else => {},
            }
        }
    }

    // ---- Query ----

    pub fn query(self: *Client, hash: QueryHash, params: []const messages.TypedValue) !ResultSet {
        const stream_id = self.nextStreamId();

        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(self.alloc);
        try messages.encodeExecute(&payload, self.alloc, .{ .query_hash = hash, .params = params });
        try frame.sendFrameList(self.fd, stream_id, .execute, frame.Flags.final_only, null, payload);

        return self.readResultSet(stream_id);
    }

    fn readResultSet(self: *Client, stream_id: u64) !ResultSet {
        var columns: []messages.ColumnDesc = &.{};
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        errdefer {
            for (rows.items) |row| {
                for (row) |v| v.deinit(self.alloc);
                self.alloc.free(row);
            }
            rows.deinit(self.alloc);
            for (columns) |cd| codec.freeColumnDesc(cd, self.alloc);
            if (columns.len > 0) self.alloc.free(columns);
        }

        while (true) {
            const hdr = try frame.readHeader(self.fd);
            const kind: frame.Kind = @enumFromInt(hdr.kind);
            if (@as(frame.Flags, @bitCast(hdr.flags)).trace) _ = try frame.readTraceExt(self.fd);
            const p = try frame.readPayload(self.fd, hdr.payload_len, self.alloc);
            defer self.alloc.free(p);
            if (hdr.stream_id != stream_id) continue;
            switch (kind) {
                .rows_begin => {
                    var cur = codec.Cursor.init(p);
                    const col_count = try cur.readU16Le();
                    columns = try self.alloc.alloc(messages.ColumnDesc, col_count);
                    for (columns, 0..) |*cd, i| {
                        cd.* = codec.decodeColumnDesc(&cur, self.alloc) catch {
                            for (columns[0..i]) |c| codec.freeColumnDesc(c, self.alloc);
                            self.alloc.free(columns);
                            columns = &.{};
                            return error.ProtocolError;
                        };
                    }
                },
                .rows_batch => {
                    var cur = codec.Cursor.init(p);
                    const row_count = try cur.readU32Le();
                    const col_count = columns.len;
                    for (0..row_count) |_| {
                        const row = try self.alloc.alloc(messages.TypedValue, col_count);
                        var decoded: usize = 0;
                        errdefer {
                            for (row[0..decoded]) |v| v.deinit(self.alloc);
                            self.alloc.free(row);
                        }
                        while (decoded < col_count) : (decoded += 1) {
                            row[decoded] = try codec.decode(&cur, self.alloc);
                        }
                        try rows.append(self.alloc, row);
                    }
                },
                .exec_ok => {
                    return ResultSet{
                        .columns = columns,
                        .rows = try rows.toOwnedSlice(self.alloc),
                        .alloc = self.alloc,
                    };
                },
                .err => {
                    self.storeError(p);
                    return error.ServerError;
                },
                else => {},
            }
        }
    }
};

/// Open a TCP socket and connect to host:port.
/// host must be a dotted-quad IPv4 string e.g. "127.0.0.1".
pub fn connectFd(host: []const u8, port: u16) !std.posix.fd_t {
    const AF_INET: u32 = 2;
    const SOCK_STREAM: u32 = 1;
    const SOCK_CLOEXEC: u32 = 0o2000000;

    const raw_fd = std.os.linux.socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return error.SocketError;
    const fd: std.posix.fd_t = @intCast(fd_i);
    errdefer _ = std.os.linux.close(@intCast(fd));

    const addr_u32 = try parseIpv4(host);

    var addr_buf: [16]u8 align(2) = std.mem.zeroes([16]u8);
    std.mem.writeInt(u16, addr_buf[0..2], AF_INET, .little);
    std.mem.writeInt(u16, addr_buf[2..4], port, .big);
    std.mem.writeInt(u32, addr_buf[4..8], addr_u32, .big);

    const rc = std.os.linux.connect(@intCast(fd), @ptrCast(@alignCast(&addr_buf)), 16);
    const rci: isize = @bitCast(rc);
    if (rci < 0) return error.ConnectError;

    return fd;
}

fn parseIpv4(host: []const u8) !u32 {
    var it = std.mem.splitScalar(u8, host, '.');
    var addr: u32 = 0;
    var i: u4 = 0;
    while (it.next()) |octet| : (i += 1) {
        if (i >= 4) return error.InvalidAddress;
        const b = try std.fmt.parseInt(u8, octet, 10);
        addr = (addr << 8) | b;
    }
    if (i != 4) return error.InvalidAddress;
    return addr;
}

/// Connect to host:port and complete the Hello→Auth(none)→AuthOk handshake.
pub fn connect(host: []const u8, port: u16, alloc: std.mem.Allocator) !Client {
    const fd = try connectFd(host, port);
    var c = Client.init(fd, alloc);
    errdefer c.deinit();
    try c.handshake();
    return c;
}
