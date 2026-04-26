/// TCP server: async accept loop with per-connection fibers and apply coroutine.
const std = @import("std");
const conn_mod = @import("conn.zig");
const gateway_mod = @import("gateway.zig");
const config_mod = @import("config.zig");

const assert = std.debug.assert;

const LISTEN_BACKLOG: u31 = 128;

/// Apply interval for the applyEntriesLoop coroutine (5 ms).
const APPLY_INTERVAL_NS: u64 = 5_000_000;

/// POSIX shutdown(2) how=SHUT_RDWR, for the signal handler.
const SHUT_RDWR: i32 = 2;

comptime {
    assert(LISTEN_BACKLOG > 0);
    assert(APPLY_INTERVAL_NS > 0);
}

/// Set by SIGINT/SIGTERM/SIGHUP handlers; checked after accept returns.
var shutdown_requested = std.atomic.Value(bool).init(false);

/// Listening socket handle stored so the signal handler can shut it down,
/// interrupting any in-progress listener.accept() call.
var listener_handle = std.atomic.Value(std.Io.net.Socket.Handle).init(-1);

fn handleShutdown(_: std.os.linux.SIG) callconv(.c) void {
    shutdown_requested.store(true, .release);
    const h = listener_handle.load(.acquire);
    if (h >= 0) _ = std.os.linux.shutdown(@intCast(h), SHUT_RDWR);
}

/// Install signal handlers for clean shutdown and safe socket I/O.
///
///   SIGINT  — Ctrl+C; SA_RESETHAND so a second ^C kills immediately.
///   SIGTERM — systemd/Docker/Kubernetes stop; same clean shutdown path.
///   SIGHUP  — terminal hangup / daemon reload signal; treat as shutdown.
///   SIGPIPE — broken client socket mid-write; ignored so writes return EPIPE.
fn installSignalHandlers() void {
    const linux = std.os.linux;
    const empty = linux.sigemptyset();

    var sa_shutdown = linux.Sigaction{
        .handler = .{ .handler = handleShutdown },
        .mask = empty,
        .flags = linux.SA.RESETHAND,
    };
    _ = linux.sigaction(linux.SIG.INT, &sa_shutdown, null);
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

/// Cooperative coroutine that calls applyNewEntries every APPLY_INTERVAL_NS.
/// Runs as a group task alongside connection fibers, so schema/registry updates
/// happen on the same cooperative thread — no locks needed.
fn applyEntriesLoop(io: std.Io, gw: *gateway_mod.Gateway) !void {
    while (true) {
        gw.applyNewEntries() catch {};
        try io.sleep(.{ .nanoseconds = APPLY_INTERVAL_NS }, .awake);
    }
}

/// Connection task: runs the full lifecycle for one client.
fn handleConn(
    io: std.Io,
    stream: std.Io.net.Stream,
    gw: *gateway_mod.Gateway,
    users: []const config_mod.UserEntry,
    alloc: std.mem.Allocator,
) !void {
    try conn_mod.Conn.run(io, stream, gw, users, alloc);
}

/// Main server loop. Accepts connections and spawns a cooperative fiber per
/// connection. Returns cleanly when a shutdown signal is received.
pub fn serve(
    io: std.Io,
    port: u16,
    gw: *gateway_mod.Gateway,
    users: []const config_mod.UserEntry,
    alloc: std.mem.Allocator,
) !void {
    assert(port > 0);

    installSignalHandlers();

    const address = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    var listener = try address.listen(io, .{ .reuse_address = true, .kernel_backlog = LISTEN_BACKLOG });
    defer listener.deinit(io);
    listener_handle.store(listener.socket.handle, .release);
    defer listener_handle.store(-1, .release);

    var group: std.Io.Group = .init;
    group.async(io, applyEntriesLoop, .{ io, gw });

    while (true) {
        const stream = listener.accept(io) catch |e| switch (e) {
            error.Canceled, error.SocketNotListening => break,
            else => {
                if (shutdown_requested.load(.acquire)) break;
                continue;
            },
        };
        group.async(io, handleConn, .{ io, stream, gw, users, alloc });
    }

    group.cancel(io);
    group.await(io) catch {};
    std.log.info("foldb: shutting down cleanly", .{});
}
