/// Transport abstraction for Raft message delivery.
///
/// The Transport interface separates the Raft state machine from network I/O,
/// enabling deterministic simulation testing (InProcessTransport) alongside
/// production TCP usage (TcpTransport).
///
/// Simulation design: InProcessTransport queues messages in memory.
/// The simulation driver controls delivery order, drops, and partitions.
/// This gives full deterministic control over network behavior.
const std = @import("std");
const rpc = @import("rpc.zig");

pub const NodeId = rpc.NodeId;
pub const Message = rpc.Message;
pub const Envelope = rpc.Envelope;

// ---------------------------------------------------------------------------
// InProcessTransport — for simulation and testing.
//
// All nodes share a single InProcessBus. Messages are queued and delivered
// by the simulation driver in a controlled order. Partitions are implemented
// by checking a drop-set before delivering.
// ---------------------------------------------------------------------------

pub const InProcessBus = struct {
    allocator: std.mem.Allocator,
    queue: std.ArrayList(Envelope),
    // Nodes in this set have outbound messages dropped (partition simulation).
    partitioned_from: std.AutoHashMap(NodeId, void),

    pub fn init(allocator: std.mem.Allocator) InProcessBus {
        return .{
            .allocator = allocator,
            .queue = .empty,
            .partitioned_from = .init(allocator),
        };
    }

    pub fn deinit(self: *InProcessBus) void {
        self.queue.deinit(self.allocator);
        self.partitioned_from.deinit();
    }

    /// Queue a message. Silently drops it if sender is partitioned.
    pub fn send(self: *InProcessBus, from: NodeId, to: NodeId, msg: Message) !void {
        if (self.partitioned_from.contains(from)) return;
        try self.queue.append(self.allocator, .{ .from = from, .to = to, .msg = msg });
    }

    /// Deliver the oldest pending message. Returns null if queue is empty.
    pub fn deliverOne(self: *InProcessBus) ?Envelope {
        if (self.queue.items.len == 0) return null;
        const env = self.queue.items[0];
        std.mem.copyForwards(Envelope, self.queue.items[0..], self.queue.items[1..]);
        self.queue.items.len -= 1;
        return env;
    }

    /// Return count of pending messages.
    pub fn pending(self: *const InProcessBus) usize {
        return self.queue.items.len;
    }

    /// Partition: messages from any node in `node_ids` will be dropped.
    pub fn partition(self: *InProcessBus, node_ids: []const NodeId) !void {
        for (node_ids) |id| {
            try self.partitioned_from.put(id, {});
        }
    }

    /// Heal all partitions.
    pub fn healAll(self: *InProcessBus) void {
        self.partitioned_from.clearRetainingCapacity();
    }

    /// Drop all messages currently in the queue (simulates message loss).
    pub fn dropAll(self: *InProcessBus) void {
        self.queue.items.len = 0;
    }
};

// ---------------------------------------------------------------------------
// TcpTransport — production TCP transport for Raft inter-node messaging.
//
// Connects lazily to peers on first send. Accepts inbound connections
// non-blocking via pollOnce. Thread-safety: not thread-safe; use from
// a single driver thread (the sequencer tick loop).
// ---------------------------------------------------------------------------

const AF_INET: u32 = 2;
const SOCK_STREAM: u32 = 1;
const SOCK_NONBLOCK: u32 = 0o4000;
const SOCK_CLOEXEC: u32 = 0o2000000;
const SOL_SOCKET: u32 = 1;
const SO_REUSEADDR: u32 = 2;
const EAGAIN: isize = -11;
const EWOULDBLOCK: isize = -11;

const PeerConn = struct {
    ip: u32,   // network byte order (big-endian)
    port: u16, // host byte order
    fd: std.posix.fd_t, // -1 = not connected
};

/// Fault injection hook: return true to drop the send silently.
/// ctx is caller-supplied; to is the destination NodeId.
pub const SendFaultHook = struct {
    ctx: ?*anyopaque = null,
    drop_fn: ?*const fn (?*anyopaque, NodeId) bool = null,

    pub fn shouldDrop(self: SendFaultHook, to: NodeId) bool {
        const f = self.drop_fn orelse return false;
        return f(self.ctx, to);
    }
};

pub const TcpTransport = struct {
    peers: std.AutoHashMap(NodeId, PeerConn),
    inbox: std.ArrayList(Envelope),
    listen_fd: std.posix.fd_t,
    self_id: NodeId,
    alloc: std.mem.Allocator,
    fault_hook: SendFaultHook = .{},

    pub fn init(alloc: std.mem.Allocator, self_id: NodeId) TcpTransport {
        return .{
            .peers = std.AutoHashMap(NodeId, PeerConn).init(alloc),
            .inbox = .empty,
            .listen_fd = -1,
            .self_id = self_id,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *TcpTransport) void {
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.fd >= 0) _ = std.os.linux.close(@intCast(entry.value_ptr.fd));
        }
        self.peers.deinit();
        self.inbox.deinit(self.alloc);
        if (self.listen_fd >= 0) _ = std.os.linux.close(@intCast(self.listen_fd));
    }

    /// Register a peer. Parses "host:port"; does not connect yet.
    pub fn addPeer(self: *TcpTransport, id: NodeId, addr: []const u8) !void {
        const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse return error.InvalidAddr;
        const host = addr[0..colon];
        const port_str = addr[colon + 1 ..];
        const port = try std.fmt.parseInt(u16, port_str, 10);
        const ip = try parseIpv4(host);
        try self.peers.put(id, .{ .ip = ip, .port = port, .fd = -1 });
    }

    /// Send a message to a peer. Connects lazily; silently drops on failure.
    pub fn send(self: *TcpTransport, to: NodeId, msg: Message) void {
        if (self.fault_hook.shouldDrop(to)) return;
        const entry = self.peers.getPtr(to) orelse return;
        // Lazy connect
        if (entry.fd < 0) {
            entry.fd = tcpConnect(entry.ip, entry.port) catch return;
        }
        // Encode
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);
        rpc.encodeMessage(self.self_id, msg, &buf, self.alloc) catch {
            _ = std.os.linux.close(@intCast(entry.fd));
            entry.fd = -1;
            return;
        };
        // Encoding succeeded — now write and close.
        // Write then close — each message is a short-lived connection so
        // pollOnce's accept-one-read-one design sees one message per accept.
        writeAll(entry.fd, buf.items) catch {};
        _ = std.os.linux.close(@intCast(entry.fd));
        entry.fd = -1;
    }

    /// Return the actual port the listen socket is bound to (useful when port=0).
    pub fn boundPort(self: *const TcpTransport) !u16 {
        if (self.listen_fd < 0) return error.NotListening;
        var addr_buf: [16]u8 align(4) = std.mem.zeroes([16]u8);
        var addr_len: u32 = 16;
        const rc = std.os.linux.getsockname(@intCast(self.listen_fd), @ptrCast(@alignCast(&addr_buf)), &addr_len);
        if (@as(isize, @bitCast(rc)) < 0) return error.GetsocknameError;
        return std.mem.readInt(u16, addr_buf[2..4], .big);
    }

    /// Bind and listen on the given port.
    pub fn listen(self: *TcpTransport, port: u16) !void {
        // SOCK_NONBLOCK so accept4 returns EAGAIN when no connection is pending.
        const raw_fd = std.os.linux.socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
        const fd_i: isize = @bitCast(raw_fd);
        if (fd_i < 0) return error.SocketError;
        const fd: std.posix.fd_t = @intCast(fd_i);
        errdefer _ = std.os.linux.close(@intCast(fd));

        const opt: u32 = 1;
        _ = std.os.linux.setsockopt(@intCast(fd), SOL_SOCKET, SO_REUSEADDR, @ptrCast(&opt), @sizeOf(u32));

        var addr_buf: [16]u8 align(4) = std.mem.zeroes([16]u8);
        std.mem.writeInt(u16, addr_buf[0..2], AF_INET, .little);
        std.mem.writeInt(u16, addr_buf[2..4], port, .big);

        const bind_rc = std.os.linux.bind(fd, @ptrCast(@alignCast(&addr_buf)), 16);
        if (@as(isize, @bitCast(bind_rc)) < 0) return error.BindError;

        const listen_rc = std.os.linux.listen(@intCast(fd), 32);
        if (@as(isize, @bitCast(listen_rc)) < 0) return error.ListenError;

        self.listen_fd = fd;
    }

    /// Accept one pending connection and read one message. Non-blocking.
    /// Returns true if a message was appended to inbox.
    pub fn pollOnce(self: *TcpTransport, alloc: std.mem.Allocator) !bool {
        if (self.listen_fd < 0) return false;
        // Non-blocking accept
        const raw = std.os.linux.accept4(@intCast(self.listen_fd), null, null, SOCK_NONBLOCK | SOCK_CLOEXEC);
        const ri: isize = @bitCast(raw);
        if (ri == EAGAIN) return false;
        if (ri < 0) return false;
        const client_fd: std.posix.fd_t = @intCast(ri);
        defer _ = std.os.linux.close(@intCast(client_fd));

        // Read 4-byte length prefix (blocking on the already-connected fd)
        var len_buf: [4]u8 = undefined;
        readExact(client_fd, &len_buf) catch return false;
        const total_len = std.mem.readInt(u32, &len_buf, .little);
        if (total_len == 0 or total_len > 1 << 20) return false;

        // Read payload
        const data = alloc.alloc(u8, total_len) catch return false;
        defer alloc.free(data);
        readExact(client_fd, data) catch return false;

        // Decode
        var env = rpc.decodeMessage(data, alloc) catch return false;
        env.to = self.self_id;
        try self.inbox.append(alloc, env);
        return true;
    }

    /// Move all inbox items into `out`. Caller takes ownership.
    pub fn drainInbox(self: *TcpTransport, out: *std.ArrayList(Envelope), alloc: std.mem.Allocator) !void {
        try out.appendSlice(alloc, self.inbox.items);
        self.inbox.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn parseIpv4(host: []const u8) !u32 {
    var octets: [4]u8 = undefined;
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |part| {
        if (i >= 4) return error.InvalidAddr;
        octets[i] = try std.fmt.parseInt(u8, part, 10);
        i += 1;
    }
    if (i != 4) return error.InvalidAddr;
    // Return in network byte order (big-endian) as a u32
    return std.mem.readInt(u32, &octets, .big);
}

fn tcpConnect(ip: u32, port: u16) !std.posix.fd_t {
    const raw_fd = std.os.linux.socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return error.SocketError;
    const fd: std.posix.fd_t = @intCast(fd_i);
    errdefer _ = std.os.linux.close(@intCast(fd));

    var addr_buf: [16]u8 align(4) = std.mem.zeroes([16]u8);
    std.mem.writeInt(u16, addr_buf[0..2], AF_INET, .little);
    std.mem.writeInt(u16, addr_buf[2..4], port, .big);
    std.mem.writeInt(u32, addr_buf[4..8], ip, .big);

    const rc = std.os.linux.connect(fd, @ptrCast(@alignCast(&addr_buf)), 16);
    if (@as(isize, @bitCast(rc)) < 0) return error.ConnectError;
    return fd;
}

fn readExact(fd: std.posix.fd_t, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.os.linux.read(@intCast(fd), buf.ptr + total, buf.len - total);
        const ni: isize = @bitCast(n);
        if (ni <= 0) return error.ReadError;
        total += @intCast(ni);
    }
}

fn writeAll(fd: std.posix.fd_t, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        const n = std.os.linux.write(@intCast(fd), data.ptr + sent, data.len - sent);
        const ni: isize = @bitCast(n);
        if (ni <= 0) return error.WriteError;
        sent += @intCast(ni);
    }
}
