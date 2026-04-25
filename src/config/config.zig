const std = @import("std");
const assert = std.debug.assert;

/// Maximum config file size accepted by from_file.
const config_file_size_max: u32 = 1 << 20; // 1 MiB

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
///   "minio:9000"              → host="minio"            port=9000 (bare host, default 443)
///
/// The S3 client handles hostname resolution at connect time.
pub fn parse_s3_endpoint(endpoint: []const u8) !ParsedS3Endpoint {
    assert(endpoint.len > 0);
    var remainder = endpoint;
    var port_default: u16 = 443;
    if (std.mem.startsWith(u8, remainder, "https://")) {
        remainder = remainder[8..];
    } else if (std.mem.startsWith(u8, remainder, "http://")) {
        remainder = remainder[7..];
        port_default = 80;
    }
    // No recognised scheme prefix: treat remainder as bare host[:port] with default port 443.
    var host = remainder;
    var port = port_default;
    if (std.mem.lastIndexOfScalar(u8, remainder, ':')) |colon| {
        host = remainder[0..colon];
        port = std.fmt.parseInt(u16, remainder[colon + 1 ..], 10) catch
            return error.InvalidS3Endpoint;
    }
    if (host.len == 0) return error.InvalidS3Endpoint;
    if (port == 0) return error.InvalidS3Endpoint;
    assert(host.len > 0);
    assert(port > 0);
    return .{ .host = host, .port = port };
}

/// A user credential stored in the config. token is the HMAC-SHA256 of
/// (name + ":" + password) under the server's auth_secret, base64-encoded.
pub const UserEntry = struct {
    name: []const u8,
    token: []const u8,
};

/// A peer node in the Raft group: its explicit node ID and listener address.
/// The node ID must be unique across the cluster and match the node_id that
/// peer was started with — IDs are stable identifiers for Raft term/vote state.
pub const PeerConfig = struct {
    id: u64,
    addr: []const u8, // "host:port"
};

pub const Config = struct {
    node_id: u64 = 1,
    storage_dir: []const u8 = "/var/lib/foldb",
    partition_count: u32 = 1,
    listen_addr: []const u8 = "0.0.0.0",
    listen_port: u16 = 7432,
    peers: []const PeerConfig = &.{},
    max_epoch_size: u32 = 10_000,
    election_timeout_min_ms: u32 = 150,
    election_timeout_max_ms: u32 = 300,
    heartbeat_interval_ms: u32 = 50,
    s3_endpoint: []const u8 = "",
    s3_bucket: []const u8 = "",
    s3_access_key: []const u8 = "",
    s3_secret_key: []const u8 = "",
    s3_region: []const u8 = "",
    /// Server-side secret used only by the add-user CLI to derive tokens.
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

pub fn from_file(path: []const u8, alloc: std.mem.Allocator) !ParsedConfig {
    assert(path.len > 0);
    const null_path = try alloc.allocSentinel(u8, path.len, 0);
    defer alloc.free(null_path);
    @memcpy(null_path[0..path.len], path);

    const raw_fd = std.os.linux.open(null_path.ptr, .{ .ACCMODE = .RDONLY }, 0);
    const fd: std.posix.fd_t = @intCast(@as(isize, @bitCast(raw_fd)));
    if (fd < 0) return error.FileOpenError;
    assert(fd >= 0);
    defer _ = std.os.linux.close(@intCast(fd));

    const size_raw = std.os.linux.lseek(@intCast(fd), 0, std.os.linux.SEEK.END);
    const size_signed: isize = @bitCast(size_raw);
    if (size_signed < 0) return error.SeekError;

    const rewind_rc = std.os.linux.lseek(@intCast(fd), 0, std.os.linux.SEEK.SET);
    const rewind_result: isize = @bitCast(rewind_rc);
    if (rewind_result < 0) return error.SeekError;
    assert(rewind_result == 0);

    const size: u32 = @intCast(size_signed);
    if (size > config_file_size_max) return error.ConfigFileTooLarge;
    assert(size <= config_file_size_max);

    const bytes = try alloc.alloc(u8, size);
    defer alloc.free(bytes);
    var total: u32 = 0;
    while (total < size) {
        const read_rc = std.os.linux.read(@intCast(fd), bytes.ptr + total, @as(usize, size - total));
        const read_result: isize = @bitCast(read_rc);
        if (read_result <= 0) return error.ReadError;
        total += @intCast(read_result);
    }
    assert(total == size);

    return from_slice(bytes, alloc);
}

pub fn from_slice(json_text: []const u8, alloc: std.mem.Allocator) !ParsedConfig {
    assert(json_text.len > 0);
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena_alloc, json_text, .{
        .duplicate_field_behavior = .use_last,
    });
    if (parsed.value != .object) return error.InvalidConfig;
    const root_object = parsed.value.object;

    var cfg = Config{};

    if (try parse_u64_field(root_object, "node_id")) |node_id| cfg.node_id = node_id;
    if (try parse_string_field(root_object, "storage_dir", arena_alloc)) |v| cfg.storage_dir = v;
    if (try parse_u32_field(root_object, "partition_count")) |v| cfg.partition_count = v;
    if (try parse_string_field(root_object, "listen_addr", arena_alloc)) |v| cfg.listen_addr = v;
    if (try parse_u16_field(root_object, "listen_port")) |v| cfg.listen_port = v;
    if (try parse_peers(root_object, arena_alloc)) |v| cfg.peers = v;
    if (try parse_u32_field(root_object, "max_epoch_size")) |v| cfg.max_epoch_size = v;
    if (try parse_u32_field(root_object, "election_timeout_min_ms")) |v| cfg.election_timeout_min_ms = v;
    if (try parse_u32_field(root_object, "election_timeout_max_ms")) |v| cfg.election_timeout_max_ms = v;
    if (try parse_u32_field(root_object, "heartbeat_interval_ms")) |v| cfg.heartbeat_interval_ms = v;
    if (try parse_string_field(root_object, "s3_endpoint", arena_alloc)) |v| cfg.s3_endpoint = v;
    if (try parse_string_field(root_object, "s3_bucket", arena_alloc)) |v| cfg.s3_bucket = v;
    if (try parse_string_field(root_object, "s3_access_key", arena_alloc)) |v| cfg.s3_access_key = v;
    if (try parse_string_field(root_object, "s3_secret_key", arena_alloc)) |v| cfg.s3_secret_key = v;
    if (try parse_string_field(root_object, "s3_region", arena_alloc)) |v| cfg.s3_region = v;
    if (try parse_string_field(root_object, "auth_secret", arena_alloc)) |v| cfg.auth_secret = v;
    if (try parse_users(root_object, arena_alloc)) |v| cfg.users = v;

    if (cfg.partition_count == 0) return error.InvalidConfig;
    if (cfg.listen_port == 0) return error.InvalidConfig;
    if (cfg.election_timeout_min_ms >= cfg.election_timeout_max_ms) return error.InvalidConfig;
    assert(cfg.partition_count > 0);
    assert(cfg.listen_port > 0);
    assert(cfg.election_timeout_min_ms < cfg.election_timeout_max_ms);

    return .{ .value = cfg, .arena = arena };
}

fn parse_string_field(
    root_object: std.json.ObjectMap,
    key: []const u8,
    alloc: std.mem.Allocator,
) !?[]const u8 {
    const json_value = root_object.get(key) orelse return null;
    return switch (json_value) {
        .string => |string| try alloc.dupe(u8, string),
        else => error.InvalidConfig,
    };
}

fn parse_u64_field(root_object: std.json.ObjectMap, key: []const u8) !?u64 {
    const json_value = root_object.get(key) orelse return null;
    return switch (json_value) {
        .integer => |integer| @intCast(integer),
        else => error.InvalidConfig,
    };
}

fn parse_u32_field(root_object: std.json.ObjectMap, key: []const u8) !?u32 {
    const json_value = root_object.get(key) orelse return null;
    return switch (json_value) {
        .integer => |integer| @intCast(integer),
        else => error.InvalidConfig,
    };
}

fn parse_u16_field(root_object: std.json.ObjectMap, key: []const u8) !?u16 {
    const json_value = root_object.get(key) orelse return null;
    return switch (json_value) {
        .integer => |integer| @intCast(integer),
        else => error.InvalidConfig,
    };
}

fn parse_peers(
    root_object: std.json.ObjectMap,
    alloc: std.mem.Allocator,
) !?[]const PeerConfig {
    const json_value = root_object.get("peers") orelse return null;
    const array = switch (json_value) {
        .array => |array| array,
        else => return error.InvalidConfig,
    };
    const peers = try alloc.alloc(PeerConfig, array.items.len);
    var committed: usize = 0;
    errdefer {
        for (peers[0..committed]) |peer| alloc.free(peer.addr);
        alloc.free(peers);
    }
    while (committed < array.items.len) : (committed += 1) {
        const peer_obj = switch (array.items[committed]) {
            .object => |obj| obj,
            else => return error.InvalidConfig,
        };
        const id = switch (peer_obj.get("id") orelse return error.InvalidConfig) {
            .integer => |n| @as(u64, @intCast(n)),
            else => return error.InvalidConfig,
        };
        const addr = switch (peer_obj.get("addr") orelse return error.InvalidConfig) {
            .string => |s| try alloc.dupe(u8, s),
            else => return error.InvalidConfig,
        };
        peers[committed] = .{ .id = id, .addr = addr };
    }
    assert(committed == array.items.len);
    return peers;
}

fn parse_users(
    root_object: std.json.ObjectMap,
    alloc: std.mem.Allocator,
) !?[]const UserEntry {
    const json_value = root_object.get("users") orelse return null;
    const array = switch (json_value) {
        .array => |array| array,
        else => return error.InvalidConfig,
    };
    const users = try alloc.alloc(UserEntry, array.items.len);
    var committed: usize = 0;
    errdefer {
        for (users[0..committed]) |user| {
            alloc.free(user.name);
            alloc.free(user.token);
        }
        alloc.free(users);
    }
    while (committed < array.items.len) : (committed += 1) {
        const user_object = switch (array.items[committed]) {
            .object => |user_object| user_object,
            else => return error.InvalidConfig,
        };
        const name = switch (user_object.get("name") orelse return error.InvalidConfig) {
            .string => |string| try alloc.dupe(u8, string),
            else => return error.InvalidConfig,
        };
        errdefer alloc.free(name);
        const token = switch (user_object.get("token") orelse return error.InvalidConfig) {
            .string => |string| try alloc.dupe(u8, string),
            else => return error.InvalidConfig,
        };
        users[committed] = .{ .name = name, .token = token };
    }
    assert(committed == array.items.len);
    return users;
}
