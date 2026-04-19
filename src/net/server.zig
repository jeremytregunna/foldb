/// TCP server: bind, listen, accept loop with per-connection async tasks.
const std = @import("std");
const frame = @import("frame.zig");
const conn_mod = @import("conn.zig");
const gateway_mod = @import("gateway.zig");

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

/// Connection task: runs the full connection lifecycle for a single client.
fn handleConn(
    io: std.Io,
    client_fd: std.posix.fd_t,
    gw: *gateway_mod.Gateway,
    alloc: std.mem.Allocator,
) !void {
    _ = io;
    try conn_mod.Conn.run(client_fd, gw, alloc);
}

/// Main server loop. Accepts connections and spawns a concurrent task per connection.
/// Returns only on unrecoverable error or if the server fd is closed.
pub fn serve(
    io: std.Io,
    port: u16,
    gw: *gateway_mod.Gateway,
    alloc: std.mem.Allocator,
) !void {
    const server_fd = try bindListen(port);
    defer _ = std.os.linux.close(@intCast(server_fd));

    var group: std.Io.Group = .{ .token = .init(null), .state = 0 };
    defer group.cancel(io);

    while (true) {
        const client_fd = acceptOne(server_fd) catch continue;

        group.async(io, handleConn, .{ io, client_fd, gw, alloc });
    }
}
