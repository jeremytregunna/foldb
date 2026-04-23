const std = @import("std");

/// Parsed S3 endpoint: hostname and port extracted from the endpoint URL.
pub const ParsedS3Endpoint = struct {
    /// Hostname or IPv4 literal — passed directly to the S3 client for both
    /// TCP connection and the HTTP Host header.
    host: []const u8,
    port: u16,
};

/// Parse an S3 endpoint URL into host and port.
///
///   "http://127.0.0.1:9000"   → host="127.0.0.1"       port=9000
///   "https://s3.example.com"  → host="s3.example.com"  port=443
///   "http://minio:9000"       → host="minio"            port=9000
///
/// The S3 client handles hostname resolution at connect time.
pub fn parseS3Endpoint(endpoint: []const u8) !ParsedS3Endpoint {
    var rest = endpoint;
    var default_port: u16 = 443;
    if (std.mem.startsWith(u8, rest, "https://")) {
        rest = rest[8..];
    } else if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest[7..];
        default_port = 80;
    }
    var host = rest;
    var port = default_port;
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
        host = rest[0..colon];
        port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch return error.InvalidS3Endpoint;
    }
    if (host.len == 0) return error.InvalidS3Endpoint;
    return .{ .host = host, .port = port };
}

/// A user credential stored in the config. `token` is the HMAC-SHA256 of
/// (name + ":" + password) under the server's auth_secret, base64-encoded.
pub const UserEntry = struct {
    name: []const u8,
    token: []const u8,
};

pub const Config = struct {
    node_id: u64 = 1,
    storage_dir: []const u8 = "/var/lib/foldb",
    partition_count: u32 = 1,
    listen_addr: []const u8 = "0.0.0.0",
    listen_port: u16 = 7432,
    peers: []const []const u8 = &.{},
    max_epoch_size: usize = 10_000,
    election_timeout_min_ms: u32 = 150,
    election_timeout_max_ms: u32 = 300,
    heartbeat_interval_ms: u32 = 50,
    s3_endpoint: []const u8 = "",
    s3_bucket: []const u8 = "",
    s3_access_key: []const u8 = "",
    s3_secret_key: []const u8 = "",
    s3_region: []const u8 = "",
    /// Server-side secret used only by the `add-user` CLI to derive tokens.
    /// Never sent over the wire. Empty = no secret configured.
    auth_secret: []const u8 = "",
    /// Registered users. Empty = open access (no auth required).
    users: []const UserEntry = &.{},
};

pub const ParsedConfig = struct {
    value: Config,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ParsedConfig) void {
        self.arena.deinit();
    }
};

pub fn fromFile(path: []const u8, alloc: std.mem.Allocator) !ParsedConfig {
    const null_path = try alloc.allocSentinel(u8, path.len, 0);
    defer alloc.free(null_path);
    @memcpy(null_path[0..path.len], path);

    const raw_fd = std.os.linux.open(null_path.ptr, .{ .ACCMODE = .RDONLY }, 0);
    const fd: std.posix.fd_t = @intCast(@as(isize, @bitCast(raw_fd)));
    if (fd < 0) return error.FileOpenError;
    defer _ = std.os.linux.close(@intCast(fd));

    const size_raw = std.os.linux.lseek(@intCast(fd), 0, std.os.linux.SEEK.END);
    const size_signed: isize = @bitCast(size_raw);
    if (size_signed < 0) return error.SeekError;
    _ = std.os.linux.lseek(@intCast(fd), 0, std.os.linux.SEEK.SET);
    const size: usize = @intCast(size_signed);
    if (size > 1 << 20) return error.ConfigFileTooLarge;

    const bytes = try alloc.alloc(u8, size);
    defer alloc.free(bytes);
    var total: usize = 0;
    while (total < size) {
        const n = std.os.linux.read(@intCast(fd), bytes.ptr + total, size - total);
        const ni: isize = @bitCast(n);
        if (ni <= 0) return error.ReadError;
        total += @intCast(ni);
    }

    return fromSlice(bytes, alloc);
}

pub fn fromSlice(json_text: []const u8, alloc: std.mem.Allocator) !ParsedConfig {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, a, json_text, .{});
    const root = parsed.value;

    if (root != .object) return error.InvalidConfig;
    const obj = root.object;

    var cfg = Config{};

    if (obj.get("node_id")) |v| cfg.node_id = switch (v) {
        .integer => |i| @intCast(i),
        else => return error.InvalidConfig,
    };
    if (obj.get("storage_dir")) |v| cfg.storage_dir = switch (v) {
        .string => |s| try a.dupe(u8, s),
        else => return error.InvalidConfig,
    };
    if (obj.get("partition_count")) |v| cfg.partition_count = switch (v) {
        .integer => |i| @intCast(i),
        else => return error.InvalidConfig,
    };
    if (obj.get("listen_addr")) |v| cfg.listen_addr = switch (v) {
        .string => |s| try a.dupe(u8, s),
        else => return error.InvalidConfig,
    };
    if (obj.get("listen_port")) |v| cfg.listen_port = switch (v) {
        .integer => |i| @intCast(i),
        else => return error.InvalidConfig,
    };
    if (obj.get("peers")) |v| switch (v) {
        .array => |arr| {
            const peers = try a.alloc([]const u8, arr.items.len);
            for (arr.items, 0..) |item, i| {
                peers[i] = switch (item) {
                    .string => |s| try a.dupe(u8, s),
                    else => return error.InvalidConfig,
                };
            }
            cfg.peers = peers;
        },
        else => return error.InvalidConfig,
    };
    if (obj.get("max_epoch_size")) |v| cfg.max_epoch_size = switch (v) {
        .integer => |i| @intCast(i),
        else => return error.InvalidConfig,
    };
    if (obj.get("election_timeout_min_ms")) |v| cfg.election_timeout_min_ms = switch (v) {
        .integer => |i| @intCast(i),
        else => return error.InvalidConfig,
    };
    if (obj.get("election_timeout_max_ms")) |v| cfg.election_timeout_max_ms = switch (v) {
        .integer => |i| @intCast(i),
        else => return error.InvalidConfig,
    };
    if (obj.get("heartbeat_interval_ms")) |v| cfg.heartbeat_interval_ms = switch (v) {
        .integer => |i| @intCast(i),
        else => return error.InvalidConfig,
    };
    if (obj.get("s3_endpoint")) |v| cfg.s3_endpoint = switch (v) {
        .string => |s| try a.dupe(u8, s),
        else => return error.InvalidConfig,
    };
    if (obj.get("s3_bucket")) |v| cfg.s3_bucket = switch (v) {
        .string => |s| try a.dupe(u8, s),
        else => return error.InvalidConfig,
    };
    if (obj.get("s3_access_key")) |v| cfg.s3_access_key = switch (v) {
        .string => |s| try a.dupe(u8, s),
        else => return error.InvalidConfig,
    };
    if (obj.get("s3_secret_key")) |v| cfg.s3_secret_key = switch (v) {
        .string => |s| try a.dupe(u8, s),
        else => return error.InvalidConfig,
    };
    if (obj.get("s3_region")) |v| cfg.s3_region = switch (v) {
        .string => |s| try a.dupe(u8, s),
        else => return error.InvalidConfig,
    };
    if (obj.get("auth_secret")) |v| cfg.auth_secret = switch (v) {
        .string => |s| try a.dupe(u8, s),
        else => return error.InvalidConfig,
    };
    if (obj.get("users")) |v| switch (v) {
        .array => |arr| {
            const users = try a.alloc(UserEntry, arr.items.len);
            for (arr.items, 0..) |item, i| {
                switch (item) {
                    .object => |o| {
                        const name = switch (o.get("name") orelse return error.InvalidConfig) {
                            .string => |s| try a.dupe(u8, s),
                            else => return error.InvalidConfig,
                        };
                        const token = switch (o.get("token") orelse return error.InvalidConfig) {
                            .string => |s| try a.dupe(u8, s),
                            else => return error.InvalidConfig,
                        };
                        users[i] = .{ .name = name, .token = token };
                    },
                    else => return error.InvalidConfig,
                }
            }
            cfg.users = users;
        },
        else => return error.InvalidConfig,
    };

    return .{ .value = cfg, .arena = arena };
}
