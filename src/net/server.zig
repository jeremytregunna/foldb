/// TCP server: bind, listen, accept loop with per-connection async tasks.
const std = @import("std");
const frame = @import("frame.zig");
const conn_mod = @import("conn.zig");
const gateway_mod = @import("gateway.zig");
const config_mod = @import("config.zig");

/// Set by SIGINT/SIGTERM/SIGHUP handlers; polled in the accept loop to trigger clean shutdown.
var shutdown_requested = std.atomic.Value(bool).init(false);

fn handleShutdown(_: std.os.linux.SIG) callconv(.c) void {
    shutdown_requested.store(true, .release);
}

/// Install signal handlers for clean shutdown and safe socket I/O.
///
///   SIGINT  — Ctrl+C; SA_RESETHAND so a second ^C kills immediately.
///   SIGTERM — systemd/Docker/Kubernetes stop; same clean shutdown path.
///   SIGHUP  — terminal hangup / daemon reload signal; treat as shutdown
///             (no hot-reload config yet).
///   SIGPIPE — broken client socket mid-write; ignored so the write syscall
///             returns EPIPE instead of killing the process.
fn installSignalHandlers() void {
    const linux = std.os.linux;
    const empty = linux.sigemptyset();

    var sa_shutdown = linux.Sigaction{
        .handler = .{ .handler = handleShutdown },
        .mask = empty,
        .flags = linux.SA.RESETHAND,
    };
    _ = linux.sigaction(linux.SIG.INT, &sa_shutdown, null);
    // SIGTERM and SIGHUP don't need RESETHAND — a second signal is fine.
    sa_shutdown.flags = 0;
    _ = linux.sigaction(linux.SIG.TERM, &sa_shutdown, null);
    _ = linux.sigaction(linux.SIG.HUP, &sa_shutdown, null);

    var sa_ignore = linux.Sigaction{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = empty,
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.PIPE, &sa_ignore, null);
}

/// Bind + listen on port. Returns the server fd.
pub fn bindListen(port: u16) !std.posix.fd_t {
    const AF_INET: u32 = 2;
    const SOCK_STREAM: u32 = 1;
    const SOCK_CLOEXEC: u32 = 0o2000000;
    const SOL_SOCKET: u32 = 1;
    const SO_REUSEADDR: u32 = 2;

    const raw_fd = std.os.linux.socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return error.SocketError;
    const fd: std.posix.fd_t = @intCast(fd_i);
    errdefer _ = std.os.linux.close(@intCast(fd));

    // SO_REUSEADDR
    const opt: u32 = 1;
    _ = std.os.linux.setsockopt(
        @intCast(fd),
        SOL_SOCKET,
        SO_REUSEADDR,
        @ptrCast(&opt),
        @sizeOf(u32),
    );

    // sockaddr_in: family(2) + port BE(2) + addr(4) + padding(8) = 16 bytes
    var addr_buf: [16]u8 align(2) = std.mem.zeroes([16]u8);
    std.mem.writeInt(u16, addr_buf[0..2], AF_INET, .little);
    std.mem.writeInt(u16, addr_buf[2..4], port, .big); // port is always BE in sockaddr
    // addr = INADDR_ANY (0.0.0.0) — already zeroed

    const bind_rc = std.os.linux.bind(fd, @ptrCast(@alignCast(&addr_buf)), 16);
    const bind_i: isize = @bitCast(bind_rc);
    if (bind_i < 0) return error.BindError;

    const listen_rc = std.os.linux.listen(@intCast(fd), 128);
    const listen_i: isize = @bitCast(listen_rc);
    if (listen_i < 0) return error.ListenError;

    return fd;
}

/// Accept one connection. Returns the client fd.
fn acceptOne(server_fd: std.posix.fd_t) !std.posix.fd_t {
    const SOCK_CLOEXEC: u32 = 0o2000000;
    const n = std.os.linux.accept4(@intCast(server_fd), null, null, SOCK_CLOEXEC);
    const ni: isize = @bitCast(n);
    if (ni < 0) return error.AcceptError;
    return @intCast(ni);
}

/// Spinlock-protected registry of active client fds.
/// On shutdown we close them all to unblock any blocking reads, which lets the
/// connection tasks return errors and exit — allowing group.cancel(io) to complete.
const ConnRegistry = struct {
    fds: [4096]std.posix.fd_t = undefined,
    len: u32 = 0,
    lock: std.atomic.Value(bool) = .init(false),

    fn acquire(self: *ConnRegistry) void {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
    }
    fn release(self: *ConnRegistry) void {
        self.lock.store(false, .release);
    }

    fn add(self: *ConnRegistry, fd: std.posix.fd_t) void {
        self.acquire();
        defer self.release();
        if (self.len < self.fds.len) {
            self.fds[self.len] = fd;
            self.len += 1;
        }
    }

    fn remove(self: *ConnRegistry, fd: std.posix.fd_t) void {
        self.acquire();
        defer self.release();
        for (0..self.len) |i| {
            if (self.fds[i] == fd) {
                self.len -= 1;
                self.fds[i] = self.fds[self.len];
                return;
            }
        }
    }

    /// Shutdown all tracked socket fds (SHUT_RDWR). This interrupts any blocking
    /// read/write in each connection task, causing it to return an error and exit.
    /// The actual close() remains in each task's own defer — calling close() here
    /// from a different thread does NOT interrupt a blocking read on Linux; only
    /// shutdown() reliably does.
    fn closeAll(self: *ConnRegistry) void {
        self.acquire();
        defer self.release();
        const SHUT_RDWR: i32 = 2;
        for (0..self.len) |i| {
            _ = std.os.linux.shutdown(@intCast(self.fds[i]), SHUT_RDWR);
        }
        // Do NOT reset len here. Tasks call remove() when they finish (after
        // conn.deinit()), so the caller can spin on isEmpty() to know when all
        // gw access has ceased and gw.deinit() is safe to call.
    }

    fn isEmpty(self: *ConnRegistry) bool {
        self.acquire();
        defer self.release();
        return self.len == 0;
    }
};

/// Connection task: runs the full connection lifecycle for a single client.
fn handleConn(
    io: std.Io,
    client_fd: std.posix.fd_t,
    gw: *gateway_mod.Gateway,
    users: []const config_mod.UserEntry,
    alloc: std.mem.Allocator,
    registry: *ConnRegistry,
) !void {
    _ = io;
    registry.add(client_fd);
    defer registry.remove(client_fd);
    try conn_mod.Conn.run(client_fd, gw, users, alloc);
}

/// Main server loop. Accepts connections and spawns a concurrent task per connection.
/// Returns cleanly when SIGINT is received so deferred cleanup (flush, deinit) runs.
pub fn serve(
    io: std.Io,
    port: u16,
    gw: *gateway_mod.Gateway,
    users: []const config_mod.UserEntry,
    alloc: std.mem.Allocator,
) !void {
    installSignalHandlers();

    const server_fd = try bindListen(port);
    defer _ = std.os.linux.close(@intCast(server_fd));

    var registry: ConnRegistry = .{};
    var group: std.Io.Group = .{ .token = .init(null), .state = 0 };

    while (!shutdown_requested.load(.acquire)) {
        const client_fd = acceptOne(server_fd) catch {
            // accept4 returns EINTR when interrupted by a signal; check for shutdown.
            if (shutdown_requested.load(.acquire)) break;
            continue;
        };
        group.async(io, handleConn, .{ io, client_fd, gw, users, alloc, &registry });
    }

    // Close all active client fds to unblock their blocking reads.
    registry.closeAll();

    // Spin until all tasks have finished conn.deinit() — the last point where
    // they access gw. registry.remove() is called inside handleConn's defer,
    // which runs after conn.deinit(), so isEmpty() guarantees no concurrent gw
    // access remains before we return to the caller's gw.deinit().
    //
    // Note: group.cancel(io) is intentionally NOT called. It blocks until tasks
    // acknowledge cancellation via io.checkCancel(), which connection handlers
    // never call (they use raw syscalls). Tasks have already exited by the time
    // registry is empty; the group futures are abandoned and the OS reclaims
    // thread resources on process exit.
    while (!registry.isEmpty()) {
        _ = std.os.linux.sched_yield();
    }

    std.debug.print("foldb: shutting down cleanly\n", .{});
}
