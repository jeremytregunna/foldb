const std = @import("std");
const config_mod = @import("config.zig");

test "Config: defaults" {
    const cfg = config_mod.Config{};
    try std.testing.expectEqual(@as(u64, 1), cfg.node_id);
    try std.testing.expectEqualStrings("/var/lib/foldb", cfg.storage_dir);
    try std.testing.expectEqual(@as(u32, 1), cfg.partition_count);
    try std.testing.expectEqual(@as(u16, 7432), cfg.listen_port);
    try std.testing.expectEqual(@as(usize, 0), cfg.peers.len);
}

test "Config: round-trip JSON" {
    const json =
        \\{
        \\  "node_id": 42,
        \\  "storage_dir": "/data/foldb",
        \\  "partition_count": 4,
        \\  "listen_addr": "127.0.0.1",
        \\  "listen_port": 9000,
        \\  "peers": ["10.0.0.1:7432", "10.0.0.2:7432"],
        \\  "max_epoch_size": 5000,
        \\  "election_timeout_min_ms": 200,
        \\  "election_timeout_max_ms": 400,
        \\  "heartbeat_interval_ms": 75,
        \\  "s3_endpoint": "https://s3.example.com",
        \\  "s3_bucket": "foldb-backup",
        \\  "s3_access_key": "AKID",
        \\  "s3_secret_key": "SECRET",
        \\  "auth_secret": "mysecret",
        \\  "users": [
        \\    {"name": "alice", "token": "tok_alice"},
        \\    {"name": "bob",   "token": "tok_bob"}
        \\  ]
        \\}
    ;

    var pc = try config_mod.fromSlice(json, std.testing.allocator);
    defer pc.deinit();
    const cfg = pc.value;

    try std.testing.expectEqual(@as(u64, 42), cfg.node_id);
    try std.testing.expectEqualStrings("/data/foldb", cfg.storage_dir);
    try std.testing.expectEqual(@as(u32, 4), cfg.partition_count);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.listen_addr);
    try std.testing.expectEqual(@as(u16, 9000), cfg.listen_port);
    try std.testing.expectEqual(@as(usize, 2), cfg.peers.len);
    try std.testing.expectEqualStrings("10.0.0.1:7432", cfg.peers[0]);
    try std.testing.expectEqualStrings("10.0.0.2:7432", cfg.peers[1]);
    try std.testing.expectEqual(@as(usize, 5000), cfg.max_epoch_size);
    try std.testing.expectEqual(@as(u32, 200), cfg.election_timeout_min_ms);
    try std.testing.expectEqual(@as(u32, 400), cfg.election_timeout_max_ms);
    try std.testing.expectEqual(@as(u32, 75), cfg.heartbeat_interval_ms);
    try std.testing.expectEqualStrings("https://s3.example.com", cfg.s3_endpoint);
    try std.testing.expectEqualStrings("foldb-backup", cfg.s3_bucket);
    try std.testing.expectEqualStrings("AKID", cfg.s3_access_key);
    try std.testing.expectEqualStrings("SECRET", cfg.s3_secret_key);
    try std.testing.expectEqualStrings("mysecret", cfg.auth_secret);
    try std.testing.expectEqual(@as(usize, 2), cfg.users.len);
    try std.testing.expectEqualStrings("alice", cfg.users[0].name);
    try std.testing.expectEqualStrings("tok_alice", cfg.users[0].token);
    try std.testing.expectEqualStrings("bob", cfg.users[1].name);
    try std.testing.expectEqualStrings("tok_bob", cfg.users[1].token);
}

test "Config: partial JSON uses defaults" {
    const json =
        \\{"storage_dir": "/custom", "listen_port": 8080}
    ;
    var pc = try config_mod.fromSlice(json, std.testing.allocator);
    defer pc.deinit();
    const cfg = pc.value;

    try std.testing.expectEqual(@as(u64, 1), cfg.node_id); // default
    try std.testing.expectEqualStrings("/custom", cfg.storage_dir);
    try std.testing.expectEqual(@as(u16, 8080), cfg.listen_port);
    try std.testing.expectEqual(@as(u32, 1), cfg.partition_count); // default
}

test "Config: invalid type returns error" {
    const json =
        \\{"node_id": "not-a-number"}
    ;
    const result = config_mod.fromSlice(json, std.testing.allocator);
    try std.testing.expectError(error.InvalidConfig, result);
}

test "Config: non-object JSON returns error" {
    const result = config_mod.fromSlice("[1,2,3]", std.testing.allocator);
    try std.testing.expectError(error.InvalidConfig, result);
}

test "Config: fromFile reads and parses JSON file" {
    const alloc = std.testing.allocator;

    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    const path = try std.fmt.allocPrint(alloc, "/tmp/foldb_config_test_{d}.json", .{ns});
    defer alloc.free(path);

    const json =
        \\{"node_id": 7, "storage_dir": "/data/test", "partition_count": 2}
    ;

    const null_path = try alloc.allocSentinel(u8, path.len, 0);
    defer alloc.free(null_path);
    @memcpy(null_path[0..path.len], path);

    const raw_fd = std.os.linux.open(null_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    const fd_i: isize = @bitCast(raw_fd);
    try std.testing.expect(fd_i >= 0);
    const fd: std.posix.fd_t = @intCast(fd_i);
    var written: usize = 0;
    while (written < json.len) {
        const n = std.os.linux.write(@intCast(fd), json.ptr + written, json.len - written);
        const ni: isize = @bitCast(n);
        try std.testing.expect(ni > 0);
        written += @intCast(ni);
    }
    _ = std.os.linux.close(@intCast(fd));
    defer _ = std.os.linux.unlink(null_path.ptr);

    var pc = try config_mod.fromFile(path, alloc);
    defer pc.deinit();

    try std.testing.expectEqual(@as(u64, 7), pc.value.node_id);
    try std.testing.expectEqualStrings("/data/test", pc.value.storage_dir);
    try std.testing.expectEqual(@as(u32, 2), pc.value.partition_count);
}
