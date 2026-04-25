/// Per-connection handler for the FoldDB wire protocol.
/// Handles one TCP connection: TLS negotiation → auth → request dispatch loop.
const std = @import("std");
const frame = @import("frame.zig");
const codec = @import("codec.zig");
const msg = @import("messages.zig");
const gateway_mod = @import("gateway.zig");
const errors = @import("errors.zig");
const config_mod = @import("config.zig");

const assert = std.debug.assert;

const FrameHeader = frame.FrameHeader;
const Kind = frame.Kind;
const Flags = frame.Flags;
const TypedValue = codec.TypedValue;
const ColumnDesc = codec.ColumnDesc;
const Cursor = codec.Cursor;

pub const SERVER_VERSION = "1.0.0-dev";

// ---- socket flag constants ----

/// recvfrom(2) flags: MSG_PEEK (0x02) | MSG_DONTWAIT (0x40).
const MSG_PEEK_DONTWAIT: u32 = 0x42;
/// recvfrom(2) flag: MSG_DONTWAIT (0x40).
const MSG_DONTWAIT: u32 = 0x40;

/// Subscription drain poll sleep when no CDC events are ready (1 ms in nanoseconds).
const DRAIN_POLL_SLEEP_NS: u64 = 1_000_000;

/// Microseconds per second, for converting CLOCK_REALTIME tv_sec → µs.
const US_PER_SEC: u64 = 1_000_000;
/// Nanoseconds per microsecond, for converting tv_nsec → µs.
const NS_PER_US: u64 = 1_000;

comptime {
    assert(US_PER_SEC == 1_000_000);
    assert(NS_PER_US == 1_000);
    assert(US_PER_SEC / NS_PER_US == 1_000);
}

// ---- per-stream state ----

const StreamKind = enum { one_shot, subscription };

const StreamState = struct {
    kind: StreamKind,
    canceled: bool = false,
    sub_id: u64 = 0,
    credits: u64 = 0,
};

/// State machine for a single connection.
pub const Conn = struct {
    fd: std.posix.fd_t,
    max_payload: u32,
    negotiated: bool,
    streams: std.AutoHashMap(u64, StreamState),
    ddl_hashes: std.AutoHashMap([32]u8, void),
    alloc: std.mem.Allocator,
    gw: *gateway_mod.Gateway,
    users: []const config_mod.UserEntry,

    fn init(fd: std.posix.fd_t, gw: *gateway_mod.Gateway, users: []const config_mod.UserEntry, alloc: std.mem.Allocator) Conn {
        assert(fd >= 0);
        return .{
            .fd = fd,
            .max_payload = frame.PRE_HELLO_CAP,
            .negotiated = false,
            .streams = std.AutoHashMap(u64, StreamState).init(alloc),
            .ddl_hashes = std.AutoHashMap([32]u8, void).init(alloc),
            .alloc = alloc,
            .gw = gw,
            .users = users,
        };
    }

    fn deinit(self: *Conn) void {
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind == .subscription) {
                self.gw.unsubscribeCdc(entry.value_ptr.sub_id);
            }
        }
        self.streams.deinit();
        self.ddl_hashes.deinit();
    }

    fn cap(self: *const Conn) u32 {
        return if (self.negotiated) self.max_payload else frame.PRE_HELLO_CAP;
    }

    // ---- send helpers ----

    fn sendError(self: *Conn, stream_id: u64, code: msg.ErrorCode, severity: msg.Severity, text: []const u8) void {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.alloc);
        msg.encodeError(&out, self.alloc, code, severity, text, "") catch return;
        const flags: Flags = if (stream_id != 0) .final_only else .none;
        frame.sendFrame(self.fd, stream_id, .err, flags, null, out.items) catch {};
    }

    fn sendFatalError(self: *Conn, code: msg.ErrorCode, text: []const u8) void {
        self.sendError(0, code, .fatal, text);
    }

    fn sendStreamError(self: *Conn, stream_id: u64, code: msg.ErrorCode, text: []const u8) void {
        self.sendError(stream_id, code, .@"error", text);
    }

    fn sendPong(self: *Conn, client_wall_micros: u64) !void {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
        const server_us: u64 = @as(u64, @intCast(ts.sec)) * US_PER_SEC +
            @as(u64, @intCast(@divTrunc(ts.nsec, 1_000))); // 1_000 == NS_PER_US
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.alloc);
        try msg.encodePong(&out, self.alloc, .{
            .client_wall_micros = client_wall_micros,
            .server_wall_micros = server_us,
        });
        try frame.sendFrame(self.fd, 0, .pong, .none, null, out.items);
    }

    // ---- TLS negotiation ----

    fn handleTlsNegotiation(self: *Conn) !void {
        var peek: [4]u8 = undefined;
        const n = std.os.linux.recvfrom(@intCast(self.fd), &peek, peek.len, MSG_PEEK_DONTWAIT, null, null);
        const ni: isize = @bitCast(n);
        if (ni < 4) return;
        if (std.mem.eql(u8, &peek, "FDBT")) {
            var consume: [4]u8 = undefined;
            try frame.readExact(self.fd, &consume);
            try frame.writeAll(self.fd, "N");
        }
    }

    // ---- handshake ----

    fn sendHello(self: *Conn) !void {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.alloc);
        const auth_methods: []const u8 = if (self.users.len > 0)
            &[_]u8{0x02}
        else
            &[_]u8{ 0x00, 0x02 };
        try msg.encodeHello(&out, self.alloc, .{
            .server_version = SERVER_VERSION,
            .auth_methods = auth_methods,
            .max_frame_payload_size = frame.DEFAULT_MAX_PAYLOAD,
        });
        try frame.sendFrame(self.fd, 0, .hello, .none, null, out.items);
    }

    fn receiveAuth(self: *Conn) !void {
        const hdr = try frame.readHeader(self.fd);
        if (hdr.payload_len > frame.PRE_HELLO_CAP) {
            self.sendFatalError(.frame_too_large, "Auth frame too large");
            return error.ProtocolError;
        }
        const kind: Kind = @enumFromInt(hdr.kind);
        if (kind != .auth) {
            self.sendFatalError(.protocol_error, "expected Auth frame");
            return error.ProtocolError;
        }
        const payload = try frame.readPayload(self.fd, hdr.payload_len, self.alloc);
        defer self.alloc.free(payload);
        var cur = Cursor.init(payload);
        const auth = msg.decodeAuth(&cur, self.alloc) catch {
            self.sendFatalError(.protocol_error, "malformed Auth payload");
            return error.ProtocolError;
        };
        defer msg.freeAuth(auth, self.alloc);
        const effective = if (auth.client_max_frame_size == 0xFFFF_FFFF)
            frame.DEFAULT_MAX_PAYLOAD
        else
            @min(auth.client_max_frame_size, frame.DEFAULT_MAX_PAYLOAD);
        self.max_payload = effective;
        self.negotiated = true;
        const auth_ok = switch (auth.payload) {
            .none => self.users.len == 0,
            .token => |t| blk: {
                if (self.users.len == 0) break :blk true;
                var matched = false;
                for (self.users) |u| {
                    if (tokenEql(t.token, u.token)) matched = true;
                }
                break :blk matched;
            },
        };
        if (!auth_ok) {
            self.sendFatalError(.auth_failed, "authentication failed");
            return error.ProtocolError;
        }
        try frame.sendFrame(self.fd, 0, .auth_ok, .none, null, &.{});
    }

    // ---- main dispatch loop ----

    pub fn run(fd: std.posix.fd_t, gw: *gateway_mod.Gateway, users: []const config_mod.UserEntry, alloc: std.mem.Allocator) !void {
        assert(fd >= 0);
        var conn = Conn.init(fd, gw, users, alloc);
        defer conn.deinit();
        defer _ = std.os.linux.close(@intCast(fd));
        conn.handleTlsNegotiation() catch {};
        conn.sendHello() catch return;
        conn.receiveAuth() catch return;
        conn.loop() catch {};
    }

    fn loop(self: *Conn) !void {
        // Non-terminating event loop: exits when the connection closes or a fatal
        // protocol error is detected. Each iteration reads one complete frame from
        // the wire, so progress is guaranteed — we never spin without I/O.
        while (true) {
            const hdr = frame.readHeader(self.fd) catch |e| switch (e) {
                error.ConnectionClosed => return,
                else => return e,
            };
            if (hdr.payload_len > self.cap()) {
                self.sendFatalError(.frame_too_large, "frame exceeds cap");
                return;
            }
            const flags: Flags = @bitCast(hdr.flags);
            if (flags.trace) {
                _ = try frame.readTraceExt(self.fd); // consume but not yet echoed
            }
            const payload = try frame.readPayload(self.fd, hdr.payload_len, self.alloc);
            defer self.alloc.free(payload);
            const kind: Kind = @enumFromInt(hdr.kind);
            self.dispatch(hdr.stream_id, kind, payload) catch |e| switch (e) {
                error.ConnectionClosed, error.Goodbye => return,
                else => |err| return err,
            };
        }
    }

    fn dispatch(self: *Conn, stream_id: u64, kind: Kind, payload: []const u8) !void {
        var cur = Cursor.init(payload);
        switch (kind) {
            .ping => try self.handlePing(stream_id, &cur),
            .goodbye => try self.handleGoodbye(stream_id),
            .cancel => try self.handleCancel(stream_id, &cur),
            .register => try self.handleRegister(stream_id, &cur),
            .execute => try self.handleExecute(stream_id, &cur),
            .read_at => try self.handleReadAt(stream_id, &cur),
            .subscribe => try self.handleSubscribe(stream_id, &cur),
            .ack_cdc => try self.handleAckCdc(stream_id, &cur),
            .unsubscribe => try self.handleUnsubscribe(stream_id),
            else => {
                self.sendFatalError(.protocol_error, "unexpected frame kind from client");
                return error.ConnectionClosed;
            },
        }
    }

    fn handlePing(self: *Conn, stream_id: u64, cur: *Cursor) !void {
        if (stream_id != 0) {
            self.sendFatalError(.protocol_error, "Ping must be on stream 0");
            return error.ConnectionClosed;
        }
        const ping = msg.decodePing(cur) catch {
            self.sendFatalError(.protocol_error, "malformed Ping");
            return error.ConnectionClosed;
        };
        try self.sendPong(ping.client_wall_micros);
    }

    fn handleGoodbye(self: *Conn, stream_id: u64) !void {
        if (stream_id != 0) {
            self.sendFatalError(.protocol_error, "Goodbye must be on stream 0");
            return error.ConnectionClosed;
        }
        try frame.sendFrame(self.fd, 0, .goodbye, .none, null, &.{});
        return error.Goodbye;
    }

    fn handleCancel(self: *Conn, stream_id: u64, cur: *Cursor) !void {
        if (stream_id != 0) {
            self.sendFatalError(.protocol_error, "Cancel must be on stream 0");
            return error.ConnectionClosed;
        }
        const target = msg.decodeCancel(cur) catch {
            self.sendFatalError(.protocol_error, "malformed Cancel");
            return;
        };
        if (target == 0) {
            self.sendFatalError(.protocol_error, "Cancel target_stream_id=0");
            return error.ConnectionClosed;
        }
        if (self.streams.getPtr(target)) |state| {
            if (state.kind == .subscription) self.gw.unsubscribeCdc(state.sub_id);
            state.canceled = true;
        }
        self.sendStreamError(target, .canceled, "stream canceled");
    }

    // ---- RegisterQuery ----

    fn handleRegister(self: *Conn, stream_id: u64, cur: *Cursor) !void {
        const rq = msg.decodeRegisterQuery(cur, self.alloc) catch {
            self.sendStreamError(stream_id, .parse_error, "malformed RegisterQuery");
            return;
        };
        defer self.alloc.free(rq.sql);
        if (isDdl(rq.sql)) {
            try self.handleRegisterDdl(stream_id, rq.sql);
            return;
        }
        const result = self.gw.register(rq.sql) catch |e| {
            const code: msg.ErrorCode = switch (e) {
                error.ParseError => .parse_error,
                error.TypeCheckError => .type_error,
                else => .server_error,
            };
            var emsg_buf: [256]u8 = undefined;
            const detail = self.gw.lastDetail();
            const emsg = if (detail.len > 0)
                std.fmt.bufPrint(&emsg_buf, "register failed: {s}", .{detail}) catch "register failed"
            else
                std.fmt.bufPrint(&emsg_buf, "register failed: {s}", .{errors.humanize(e)}) catch "register failed";
            self.sendStreamError(stream_id, code, emsg);
            return;
        };
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.alloc);
        try msg.encodeRegistered(&out, self.alloc, .{ .query_hash = result.hash, .param_tags = &.{}, .columns = &.{} });
        try frame.sendFrame(self.fd, stream_id, .registered, .final_only, null, out.items);
    }

    fn handleRegisterDdl(self: *Conn, stream_id: u64, sql: []const u8) !void {
        self.gw.applyDdl(sql) catch |e| {
            const code: msg.ErrorCode = switch (e) {
                error.ParseError, error.MissingNullability => .parse_error,
                error.TypeCheckError => .type_error,
                else => .server_error,
            };
            var emsg_buf: [256]u8 = undefined;
            const detail = self.gw.lastDetail();
            const emsg = if (detail.len > 0)
                std.fmt.bufPrint(&emsg_buf, "DDL failed: {s}", .{detail}) catch "DDL failed"
            else
                std.fmt.bufPrint(&emsg_buf, "DDL failed: {s}", .{errors.humanize(e)}) catch "DDL failed";
            self.sendStreamError(stream_id, code, emsg);
            return;
        };
        var hash: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(sql, &hash, .{});
        try self.ddl_hashes.put(hash, {});
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.alloc);
        try msg.encodeRegistered(&out, self.alloc, .{ .query_hash = hash, .param_tags = &.{}, .columns = &.{} });
        try frame.sendFrame(self.fd, stream_id, .registered, .final_only, null, out.items);
    }

    // ---- Execute ----

    fn handleExecute(self: *Conn, stream_id: u64, cur: *Cursor) !void {
        const ex = msg.decodeExecute(cur, self.alloc) catch {
            self.sendStreamError(stream_id, .protocol_error, "malformed Execute");
            return;
        };
        defer msg.freeExecute(ex, self.alloc);
        if (self.ddl_hashes.contains(ex.query_hash)) {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            defer out.deinit(self.alloc);
            try msg.encodeExecOk(&out, self.alloc, .{ .rows_affected = 0, .committed_seq = self.gw.currentSeq() });
            try frame.sendFrame(self.fd, stream_id, .exec_ok, .final_only, null, out.items);
            return;
        }
        const params = try self.typedValuesToColumnValues(ex.params);
        defer self.alloc.free(params);
        assert(params.len == ex.params.len);
        if (self.gw.isSelectQuery(ex.query_hash)) {
            const sel_result = self.gw.querySelect(ex.query_hash, params, &.{}) catch |e| {
                self.sendStreamError(stream_id, gatewayErrToCode(e), "query failed");
                return;
            };
            try self.sendResultSet(stream_id, sel_result);
            return;
        }
        const exec_result = self.gw.execute(ex.query_hash, params, &.{}) catch |e| {
            const code = gatewayErrToCode(e);
            var emsg_buf: [256]u8 = undefined;
            const detail = self.gw.lastDetail();
            const emsg = if (detail.len > 0)
                std.fmt.bufPrint(&emsg_buf, "execute failed: {s}", .{detail}) catch "execute failed"
            else
                std.fmt.bufPrint(&emsg_buf, "execute failed: {s}", .{errors.humanize(e)}) catch "execute failed";
            self.sendStreamError(stream_id, code, emsg);
            return;
        };
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.alloc);
        try msg.encodeExecOk(&out, self.alloc, .{ .rows_affected = exec_result.rows_affected, .committed_seq = self.gw.currentSeq() });
        try frame.sendFrame(self.fd, stream_id, .exec_ok, .final_only, null, out.items);
    }

    // ---- ReadAt ----

    fn handleReadAt(self: *Conn, stream_id: u64, cur: *Cursor) !void {
        const ra = msg.decodeReadAt(cur, self.alloc) catch {
            self.sendStreamError(stream_id, .protocol_error, "malformed ReadAt");
            return;
        };
        defer msg.freeReadAt(ra, self.alloc);
        const params = try self.typedValuesToColumnValues(ra.params);
        defer self.alloc.free(params);
        const result = self.gw.readAt(ra.query_hash, params, ra.at_seq) catch |e| {
            self.sendStreamError(stream_id, gatewayErrToCode(e), "readAt failed");
            return;
        };
        try self.sendResultSet(stream_id, result);
    }

    // ---- Subscribe ----

    fn handleSubscribe(self: *Conn, stream_id: u64, cur: *Cursor) !void {
        const sub_req = msg.decodeSubscribe(cur, self.alloc) catch {
            self.sendStreamError(stream_id, .protocol_error, "malformed Subscribe");
            return;
        };
        defer msg.freeSubscribe(sub_req, self.alloc);
        var resolved: std.ArrayListUnmanaged(msg.ResolvedName) = .empty;
        defer {
            for (resolved.items) |r| self.alloc.free(r.name);
            resolved.deinit(self.alloc);
        }
        var table_filter: ?u32 = null;
        for (sub_req.filters) |f| {
            switch (f) {
                .by_id => |id| {
                    if (!self.gw.tableIdExists(id)) {
                        self.sendStreamError(stream_id, .query_not_found, "unknown table id");
                        return;
                    }
                    table_filter = id;
                },
                .by_name => |name| {
                    const tid = self.gw.resolveTableName(name) orelse {
                        self.sendStreamError(stream_id, .query_not_found, "unknown table name");
                        return;
                    };
                    table_filter = tid;
                    const name_copy = self.alloc.dupe(u8, name) catch return;
                    resolved.append(self.alloc, .{ .name = name_copy, .table_id = tid }) catch {
                        self.alloc.free(name_copy);
                        return;
                    };
                },
            }
        }
        const sub = self.gw.subscribeCdc(table_filter, sub_req.from_seq) catch {
            self.sendStreamError(stream_id, .server_error, "subscribe failed");
            return;
        };
        try self.streams.put(stream_id, .{ .kind = .subscription, .sub_id = sub.id, .credits = sub_req.initial_credits });
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.alloc);
        try msg.encodeSubscribeAck(&out, self.alloc, resolved.items);
        try frame.sendFrame(self.fd, stream_id, .subscribe_ack, .more_only, null, out.items);
        try self.drainSubscription(stream_id, sub);
    }

    fn drainSubscription(self: *Conn, stream_id: u64, sub: *gateway_mod.CdcSubscription) !void {
        const state = self.streams.getPtr(stream_id) orelse return;
        assert(state.kind == .subscription);
        var buf: [16]gateway_mod.CdcEvent = undefined;
        // Non-terminating loop: exits on unsubscribe, cancel, goodbye, or I/O error.
        // Progress guaranteed: each iteration either flushes CDC events or performs
        // one blocking or non-blocking socket read, or sleeps 1 ms before retrying.
        while (true) {
            try self.flushCdcCredits(stream_id, sub, state, &buf);
            if (state.canceled) return;
            var hdr_buf: [@sizeOf(FrameHeader)]u8 = undefined;
            const recv_n = std.os.linux.recvfrom(@intCast(self.fd), &hdr_buf, hdr_buf.len, MSG_DONTWAIT, null, null);
            const recv_ni: isize = @bitCast(recv_n);
            if (recv_ni < 0) {
                const errno = std.os.linux.errno(recv_n);
                if (errno == .AGAIN) {
                    var ts = std.os.linux.timespec{ .sec = 0, .nsec = @intCast(DRAIN_POLL_SLEEP_NS) };
                    _ = std.os.linux.nanosleep(&ts, null);
                    continue;
                }
                return;
            }
            if (recv_ni == 0) return;
            if (recv_ni < @sizeOf(FrameHeader)) {
                try frame.readExact(self.fd, hdr_buf[@intCast(recv_ni)..]);
            }
            const client_hdr: FrameHeader = @bitCast(hdr_buf);
            if (client_hdr.payload_len > self.cap()) {
                self.sendFatalError(.frame_too_large, "frame exceeds cap");
                return;
            }
            const client_payload = try frame.readPayload(self.fd, client_hdr.payload_len, self.alloc);
            defer self.alloc.free(client_payload);
            const client_kind: Kind = @enumFromInt(client_hdr.kind);
            const should_exit = try self.handleSubscriptionClientFrame(stream_id, state, sub, client_kind, client_payload);
            if (should_exit) return;
        }
    }

    fn flushCdcCredits(
        self: *Conn,
        stream_id: u64,
        sub: *gateway_mod.CdcSubscription,
        state: *StreamState,
        buf: *[16]gateway_mod.CdcEvent,
    ) !void {
        while (state.credits > 0 and !state.canceled) {
            const n = sub.next(buf);
            if (n == 0) break;
            for (buf[0..n]) |*ev| {
                defer ev.deinit();
                if (state.credits == 0) break;
                try self.sendCdcEvent(stream_id, ev);
                state.credits -= 1;
            }
        }
    }

    /// Handle one client frame received during a subscription drain.
    /// Returns true when the subscription should end (unsubscribe/cancel/goodbye).
    fn handleSubscriptionClientFrame(
        self: *Conn,
        stream_id: u64,
        state: *StreamState,
        sub: *gateway_mod.CdcSubscription,
        client_kind: Kind,
        client_payload: []const u8,
    ) !bool {
        switch (client_kind) {
            .ack_cdc => {
                var cur = Cursor.init(client_payload);
                const ack = msg.decodeAckCdc(&cur) catch {
                    self.sendStreamError(stream_id, .protocol_error, "malformed AckCdc");
                    return true;
                };
                sub.ack(ack.acked_seq);
                const new_credits: u64 = @min(std.math.maxInt(u64) - state.credits, ack.add_credits);
                state.credits +|= new_credits;
                return false;
            },
            .unsubscribe => {
                self.gw.unsubscribeCdc(state.sub_id);
                _ = self.streams.remove(stream_id);
                var out: std.ArrayListUnmanaged(u8) = .empty;
                defer out.deinit(self.alloc);
                try msg.encodeExecOk(&out, self.alloc, .{ .rows_affected = 0, .committed_seq = frame.NO_COMMIT_SEQ });
                try frame.sendFrame(self.fd, stream_id, .exec_ok, .final_only, null, out.items);
                return true;
            },
            .cancel => {
                var cur = Cursor.init(client_payload);
                const target = msg.decodeCancel(&cur) catch return false;
                if (target == stream_id) {
                    self.gw.unsubscribeCdc(state.sub_id);
                    state.canceled = true;
                    self.sendStreamError(stream_id, .canceled, "stream canceled");
                    return true;
                }
                return false;
            },
            .ping => {
                var cur = Cursor.init(client_payload);
                const ping = msg.decodePing(&cur) catch return false;
                self.sendPong(ping.client_wall_micros) catch {};
                return false;
            },
            .goodbye => return true,
            else => return false,
        }
    }

    fn sendCdcEvent(self: *Conn, stream_id: u64, ev: *gateway_mod.CdcEvent) !void {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.alloc);
        var wire_effects: std.ArrayListUnmanaged(msg.WireCdcEffect) = .empty;
        defer {
            for (wire_effects.items) |we| {
                for (we.before) |v| v.deinit(self.alloc);
                self.alloc.free(we.before);
                for (we.after) |v| v.deinit(self.alloc);
                self.alloc.free(we.after);
            }
            wire_effects.deinit(self.alloc);
        }
        for (ev.effects) |*effect| {
            const op: msg.CdcOp = switch (effect.op) {
                .insert => .insert,
                .update => .update,
                .delete => .delete,
            };
            const before = if (effect.before) |b| try self.columnValuesToTypedValues(b) else try self.alloc.alloc(TypedValue, 0);
            errdefer { for (before) |v| v.deinit(self.alloc); self.alloc.free(before); }
            const after = if (effect.after) |a| try self.columnValuesToTypedValues(a) else try self.alloc.alloc(TypedValue, 0);
            errdefer { for (after) |v| v.deinit(self.alloc); self.alloc.free(after); }
            try wire_effects.append(self.alloc, .{ .table_id = effect.table_id, .key = effect.key, .op = op, .before = before, .after = after });
        }
        try msg.encodeCdcEvent(&out, self.alloc, ev.seq, ev.epoch, wire_effects.items);
        try frame.sendFrame(self.fd, stream_id, .cdc_event, .none, null, out.items);
    }

    // ---- AckCdc (outside subscription drain) ----

    fn handleAckCdc(self: *Conn, stream_id: u64, cur: *Cursor) !void {
        const ack = msg.decodeAckCdc(cur) catch {
            self.sendStreamError(stream_id, .protocol_error, "malformed AckCdc");
            return;
        };
        const state = self.streams.getPtr(stream_id) orelse return;
        if (state.kind != .subscription) return;
        const sub = self.gw.getCdcSub(state.sub_id) orelse return;
        sub.ack(ack.acked_seq);
        const new_credits: u64 = @min(std.math.maxInt(u64) - state.credits, ack.add_credits);
        state.credits +|= new_credits;
    }

    // ---- Unsubscribe ----

    fn handleUnsubscribe(self: *Conn, stream_id: u64) !void {
        if (self.streams.fetchRemove(stream_id)) |entry| {
            if (entry.value.kind == .subscription) self.gw.unsubscribeCdc(entry.value.sub_id);
        }
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.alloc);
        try msg.encodeExecOk(&out, self.alloc, .{ .rows_affected = 0, .committed_seq = frame.NO_COMMIT_SEQ });
        try frame.sendFrame(self.fd, stream_id, .exec_ok, .final_only, null, out.items);
    }

    // ---- result encoding ----

    fn sendResultSet(self: *Conn, stream_id: u64, result: gateway_mod.ResultSet) !void {
        var rs = result;
        defer rs.deinit();
        try self.sendRowsBeginFrame(stream_id, &rs);
        try self.sendRowsBatchFrame(stream_id, rs);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.alloc);
        try msg.encodeExecOk(&out, self.alloc, .{ .rows_affected = @intCast(rs.rows.len), .committed_seq = frame.NO_COMMIT_SEQ });
        try frame.sendFrame(self.fd, stream_id, .exec_ok, .final_only, null, out.items);
    }

    fn sendRowsBeginFrame(self: *Conn, stream_id: u64, rs: *gateway_mod.ResultSet) !void {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.alloc);
        const col_count: u16 = if (rs.rows.len > 0) @intCast(rs.rows[0].len) else @intCast(rs.columns.len);
        const cds = try self.alloc.alloc(ColumnDesc, col_count);
        defer {
            for (cds) |cd| self.alloc.free(cd.name);
            self.alloc.free(cds);
        }
        for (cds, 0..) |*cd, i| {
            const name = if (i < rs.columns.len)
                try self.alloc.dupe(u8, rs.columns[i])
            else blk: {
                var tmp_buf: [16]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp_buf, "col{d}", .{i}) catch "col";
                break :blk try self.alloc.dupe(u8, s);
            };
            cd.* = .{ .name = name, .type_tag = 0x00, .nullable = true };
        }
        try msg.encodeRowsBegin(&out, self.alloc, .{ .columns = cds });
        try frame.sendFrame(self.fd, stream_id, .rows_begin, .more_only, null, out.items);
    }

    fn sendRowsBatchFrame(self: *Conn, stream_id: u64, rs: gateway_mod.ResultSet) !void {
        if (rs.rows.len == 0) return;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.alloc);
        var wire_rows: std.ArrayListUnmanaged([]TypedValue) = .empty;
        defer {
            for (wire_rows.items) |row| self.alloc.free(row);
            wire_rows.deinit(self.alloc);
        }
        for (rs.rows) |row| {
            const wire_row = try self.alloc.alloc(TypedValue, row.len);
            errdefer self.alloc.free(wire_row);
            for (row, 0..) |cell_opt, ci| {
                wire_row[ci] = if (cell_opt) |cell| columnValueToTypedValue(cell) else .null_val;
            }
            try wire_rows.append(self.alloc, wire_row);
        }
        const const_rows = try self.alloc.alloc([]const TypedValue, wire_rows.items.len);
        defer self.alloc.free(const_rows);
        for (wire_rows.items, 0..) |row, i| const_rows[i] = row;
        try msg.encodeRowsBatch(&out, self.alloc, const_rows);
        try frame.sendFrame(self.fd, stream_id, .rows_batch, .more_only, null, out.items);
    }

    // ---- type conversion helpers ----

    fn typedValuesToColumnValues(self: *Conn, values: []const TypedValue) ![]gateway_mod.ColumnValue {
        const out = try self.alloc.alloc(gateway_mod.ColumnValue, values.len);
        for (values, 0..) |v, i| {
            out[i] = typedValueToColumnValue(v) catch .{ .bytes = "" };
        }
        return out;
    }

    fn columnValuesToTypedValues(self: *Conn, values: []const gateway_mod.ColumnValue) ![]TypedValue {
        const out = try self.alloc.alloc(TypedValue, values.len);
        for (values, 0..) |v, i| {
            out[i] = columnValueToTypedValue(v);
        }
        return out;
    }
};

// ---- module-level helpers ----

fn typedValueToColumnValue(v: TypedValue) !gateway_mod.ColumnValue {
    return switch (v) {
        .bool_val => |b| .{ .bool_t = b },
        .int8 => |n| .{ .int8 = n },
        .int16 => |n| .{ .int16 = n },
        .int32 => |n| .{ .int32 = n },
        .int64 => |n| .{ .int64 = n },
        .uint8 => |n| .{ .uint8 = n },
        .uint16 => |n| .{ .uint16 = n },
        .uint32 => |n| .{ .uint32 = n },
        .uint64 => |n| .{ .uint64 = n },
        .float32 => |f| .{ .float32 = f },
        .float64 => |f| .{ .float64 = f },
        .decimal => |d| .{ .decimal = .{ .coefficient = d.coefficient, .scale = d.scale } },
        .string => |s| .{ .string = s },
        .bytes => |b| .{ .bytes = b },
        else => return error.UnsupportedType,
    };
}

fn columnValueToTypedValue(v: gateway_mod.ColumnValue) TypedValue {
    return switch (v) {
        .bool_t => |b| .{ .bool_val = b },
        .int8 => |n| .{ .int8 = n },
        .int16 => |n| .{ .int16 = n },
        .int32 => |n| .{ .int32 = n },
        .int64 => |n| .{ .int64 = n },
        .uint8 => |n| .{ .uint8 = n },
        .uint16 => |n| .{ .uint16 = n },
        .uint32 => |n| .{ .uint32 = n },
        .uint64 => |n| .{ .uint64 = n },
        .float32 => |f| .{ .float32 = f },
        .float64 => |f| .{ .float64 = f },
        .decimal => |d| .{ .decimal = .{ .coefficient = d.coefficient, .scale = d.scale } },
        .string => |s| .{ .string = s },
        .bytes => |b| .{ .bytes = b },
    };
}

fn gatewayErrToCode(e: anyerror) msg.ErrorCode {
    return switch (e) {
        error.QueryNotFound => .query_not_found,
        error.ConstraintViolation, error.ForeignKeyViolation => .constraint_violation,
        error.ExecutionError => .transaction_aborted,
        error.ParamDecodeError => .type_mismatch,
        error.SchemaBreakingChange => .schema_conflict,
        else => .server_error,
    };
}

/// Constant-time byte-slice equality. Returns false immediately when lengths
/// differ (length is not secret — all valid tokens are 44 bytes), then XORs
/// every byte pair without early exit to avoid timing sidechannels.
fn tokenEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var acc: u8 = 0;
    for (a, b) |x, y| acc |= x ^ y;
    // Branchless: produce 1 iff acc == 0.
    return @as(bool, @bitCast(@as(u1, @truncate((@as(u9, acc) -% 1) >> 8))));
}

fn isDdl(sql: []const u8) bool {
    const s = std.mem.trimStart(u8, sql, " \t\r\n");
    var end: usize = 0;
    while (end < s.len and s[end] != ' ' and s[end] != '\t' and s[end] != '(') : (end += 1) {}
    if (end == 0) return false;
    var buf: [6]u8 = undefined;
    const len = @min(end, buf.len);
    for (s[0..len], 0..) |c, i| buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    const tok = buf[0..len];
    return std.mem.eql(u8, tok, "create") or std.mem.eql(u8, tok, "drop") or std.mem.eql(u8, tok, "alter");
}
