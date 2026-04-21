const std = @import("std");
const gateway_mod = @import("gateway.zig");
const server = @import("server.zig");
const config_mod = @import("config.zig");
const sequencer_mod = @import("sequencer.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var config_path: ?[]const u8 = null;
    var storage_dir_override: ?[]const u8 = null;
    var port_override: ?u16 = null;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip(); // skip argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            if (it.next()) |val| config_path = val;
        } else if (std.mem.eql(u8, arg, "--storage-dir")) {
            if (it.next()) |val| storage_dir_override = val;
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (it.next()) |val| port_override = try std.fmt.parseInt(u16, val, 10);
        }
    }

    var parsed: ?config_mod.ParsedConfig = null;
    defer if (parsed) |*p| p.deinit();

    const cfg: config_mod.Config = if (config_path) |path| blk: {
        parsed = try config_mod.fromFile(path, alloc);
        break :blk parsed.?.value;
    } else config_mod.Config{};

    const storage_dir = storage_dir_override orelse cfg.storage_dir;
    const port = port_override orelse cfg.listen_port;

    // Build PeerAddr slice from config peer strings.
    // Peer NodeIds are assigned sequentially starting from 1, skipping self.
    const peer_addrs = try alloc.alloc(sequencer_mod.PeerAddr, cfg.peers.len);
    defer alloc.free(peer_addrs);
    var next_id: u64 = 1;
    for (cfg.peers, 0..) |addr, i| {
        while (next_id == cfg.node_id) next_id += 1;
        peer_addrs[i] = .{ .id = next_id, .addr = addr };
        next_id += 1;
    }

    std.debug.print("foldb starting: storage={s} port={d} node_id={d} partitions={d} peers={d}\n", .{
        storage_dir,
        port,
        cfg.node_id,
        cfg.partition_count,
        cfg.peers.len,
    });

    const gw = try gateway_mod.Gateway.init(storage_dir, alloc, .{
        .partition_count = cfg.partition_count,
        .node_id = cfg.node_id,
        .tick_interval_ms = 10,
        .election_timeout_min_ms = cfg.election_timeout_min_ms,
        .election_timeout_max_ms = cfg.election_timeout_max_ms,
        .heartbeat_interval_ms = cfg.heartbeat_interval_ms,
        .peers = peer_addrs,
    });
    defer gw.deinit();

    try server.serve(io, port, gw, alloc);
}
