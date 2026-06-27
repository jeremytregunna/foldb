/// Per-connection handler for the FoldDB KV wire protocol.
const std = @import("std");
const frame = @import("frame.zig");
const codec = @import("codec.zig");
const msg = @import("messages.zig");
const gateway_mod = @import("gateway.zig");
const config_mod = @import("config.zig");

const net = std.Io.net;

pub const SERVER_VERSION = "0.1.0";

pub const Conn = struct {
    io: std.Io,
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    read_buf: [8192]u8,
    write_buf: [8192]u8,
    max_payload: u32,
    negotiated: bool,
    alloc: std.mem.Allocator,
    gw: *gateway_mod.Gateway,
    users: []const config_mod.UserEntry,
    pending_trace: ?[frame.TRACE_EXT_SIZE]u8 = null,

    fn init(
        io: std.Io,
        stream: net.Stream,
        gw: *gateway_mod.Gateway,
        users: []const config_mod.UserEntry,
        alloc: std.mem.Allocator,
    ) Conn {
        return .{
            .io = io,
            .stream = stream,
            .reader = undefined,
            .writer = undefined,
            .read_buf = undefined,
            .write_buf = undefined,
            .max_payload = frame.PRE_HELLO_CAP,
            .negotiated = false,
            .alloc = alloc,
            .gw = gw,
            .users = users,
            .pending_trace = null,
        };
    }

    fn cap(self: *const Conn) u32 {
        return if (self.negotiated) self.max_payload else frame.PRE_HELLO_CAP;
    }

    fn tracePtr(self: *const Conn) ?*const [frame.TRACE_EXT_SIZE]u8 {
        return if (self.pending_trace) |*t| t else null;
    }

    fn sendError(self: *Conn, stream_id: u64, code: msg.ErrorCode, severity: msg.Severity, text: []const u8) void {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.alloc);
        msg.encodeError(&out, self.alloc, code, severity, text, "") catch return;
        const flags: frame.Flags = if (stream_id != 0) .final_only else .none;
        frame.sendFrame(&self.writer.interface, stream_id, .err, flags, self.tracePtr(), out.items) catch |err|
            std.log.warn("sendError: {}", .{err});
    }

    fn sendFatalError(self: *Conn, code: msg.ErrorCode, text: []const u8) void {
        self.sendError(0, code, .fatal, text);
    }

    fn sendStreamError(self: *Conn, stream_id: u64, code: msg.ErrorCode, text: []const u8) void {
        self.sendError(stream_id, code, .@"error", text);
    }

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
        try frame.sendFrame(&self.writer.interface, 0, .hello, .none, null, out.items);
    }

    fn receiveAuth(self: *Conn) !void {
        const hdr = try frame.readHeader(&self.reader.interface);
        if (hdr.payload_len > frame.PRE_HELLO_CAP) {
            self.sendFatalError(.frame_too_large, "Auth frame too large");
            return error.ProtocolError;
        }
        const kind: frame.Kind = @enumFromInt(hdr.kind);
        if (kind != .auth) {
            self.sendFatalError(.protocol_error, "expected Auth frame");
            return error.ProtocolError;
        }
        const payload = try frame.readPayload(&self.reader.interface, hdr.payload_len, self.alloc);
        defer self.alloc.free(payload);

        var cur = codec.Cursor{ .data = payload };
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
                for (self.users) |u| {
                    if (std.mem.eql(u8, t.token, u.token)) break :blk true;
                }
                break :blk false;
            },
        };
        if (!auth_ok) {
            self.sendFatalError(.auth_failed, "authentication failed");
            return error.ProtocolError;
        }

        try frame.sendFrame(&self.writer.interface, 0, .auth_ok, .none, null, &.{});
    }

    pub fn run(
        io: std.Io,
        stream: net.Stream,
        gw: *gateway_mod.Gateway,
        users: []const config_mod.UserEntry,
        alloc: std.mem.Allocator,
    ) !void {
        var conn = Conn.init(io, stream, gw, users, alloc);
        conn.reader = stream.reader(io, &conn.read_buf);
        conn.writer = stream.writer(io, &conn.write_buf);
        defer conn.stream.close(conn.io);
        try conn.sendHello();
        try conn.receiveAuth();
        conn.loop() catch |err| std.log.warn("conn loop: {}", .{err});
    }

    fn loop(self: *Conn) !void {
        while (true) {
            const hdr = frame.readHeader(&self.reader.interface) catch return;
            if (hdr.payload_len > self.cap()) {
                self.sendFatalError(.frame_too_large, "frame exceeds cap");
                return;
            }
            const flags: frame.Flags = @bitCast(hdr.flags);
            self.pending_trace = if (flags.trace) try frame.readTraceExt(&self.reader.interface) else null;
            const payload = try frame.readPayload(&self.reader.interface, hdr.payload_len, self.alloc);
            defer self.alloc.free(payload);
            const kind: frame.Kind = @enumFromInt(hdr.kind);
            self.dispatch(hdr.stream_id, kind, payload) catch |err| switch (err) {
                error.Goodbye => return,
                else => return err,
            };
        }
    }

    fn dispatch(self: *Conn, stream_id: u64, kind: frame.Kind, payload: []const u8) !void {
        switch (kind) {
            .ping => try self.handlePing(stream_id, payload),
            .goodbye => try self.handleGoodbye(stream_id),
            .get, .set, .delete, .range, .batch => try self.handleKv(stream_id, kind, payload),
            else => {
                self.sendFatalError(.protocol_error, "unexpected frame kind from client");
                return error.ProtocolError;
            },
        }
    }

    fn handlePing(self: *Conn, stream_id: u64, payload: []const u8) !void {
        if (stream_id != 0) {
            self.sendFatalError(.protocol_error, "Ping must be on stream 0");
            return error.ProtocolError;
        }
        try gateway_mod.handlePing(&self.writer.interface, self.alloc, payload);
    }

    fn handleGoodbye(self: *Conn, stream_id: u64) !void {
        if (stream_id != 0) {
            self.sendFatalError(.protocol_error, "Goodbye must be on stream 0");
            return error.ProtocolError;
        }
        try frame.sendFrame(&self.writer.interface, 0, .goodbye, .none, self.tracePtr(), &.{});
        return error.Goodbye;
    }

    fn handleKv(self: *Conn, stream_id: u64, kind: frame.Kind, payload: []const u8) !void {
        if (stream_id == 0) {
            self.sendFatalError(.protocol_error, "KV requests require a non-zero stream");
            return error.ProtocolError;
        }

        var req = gateway_mod.decodeRequest(kind, stream_id, payload, self.alloc) catch {
            self.sendStreamError(stream_id, .protocol_error, "malformed KV request");
            return;
        };
        defer req.deinit(self.alloc);

        switch (kind) {
            .get => try gateway_mod.handleGet(
                &self.writer.interface,
                self.alloc,
                stream_id,
                req.get_req.?,
                self.gw,
            ),
            .set => try gateway_mod.handleSet(
                &self.writer.interface,
                self.alloc,
                stream_id,
                req.set_req.?,
                self.gw,
            ),
            .delete => try gateway_mod.handleDelete(
                &self.writer.interface,
                self.alloc,
                stream_id,
                req.delete_req.?,
                self.gw,
            ),
            .range => try gateway_mod.handleRange(
                &self.writer.interface,
                self.alloc,
                stream_id,
                req.range_req.?,
                self.gw,
            ),
            .batch => try gateway_mod.handleBatch(
                &self.writer.interface,
                self.alloc,
                stream_id,
                req.batch_ops.?,
                self.gw,
            ),
            else => unreachable,
        }
    }
};
