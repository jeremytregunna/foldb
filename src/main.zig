const std = @import("std");
const gateway_mod = @import("gateway.zig");
const server = @import("server.zig");
const config_mod = @import("config.zig");
const sequencer_mod = @import("sequencer.zig");

const version = "0.1.0";

const help_root =
    \\foldb v{s} — replicated deterministic database
    \\
    \\Usage: foldb <command> [options]
    \\
    \\Commands:
    \\  serve       Start the database server (default)
    \\  gen-secret  Generate an auth_secret for token-based auth
    \\  add-user    Derive a user token and print the config snippet
    \\
    \\Options:
    \\  -h, --help     Show this help
    \\  -V, --version  Print version
    \\
    \\Run 'foldb <command> --help' for command-specific options.
    \\
;

const help_serve =
    \\Usage: foldb serve [options]
    \\
    \\Start the database server. All options can also be set via a config file.
    \\
    \\Options:
    \\  --config <path>       JSON config file (see docs/internal/config.md)
    \\  --storage-dir <path>  Override storage directory from config
    \\  --port <port>         Override listen port from config
    \\  -h, --help            Show this help
    \\
    \\Defaults (no config file): storage=/var/lib/foldb port=7432 node_id=1
    \\
;

const help_gen_secret =
    \\Usage: foldb gen-secret
    \\
    \\Generate a random auth_secret and print the config snippet to add.
    \\Run this once, then add the printed value to your config file.
    \\
    \\Options:
    \\  -h, --help  Show this help
    \\
;

const help_add_user =
    \\Usage: foldb add-user --config <path> --name <name> --password <password>
    \\
    \\Derive a token for a user and print the config snippet to add.
    \\Requires auth_secret to already be set in the config (see gen-secret).
    \\
    \\Options:
    \\  --config <path>      Config file containing auth_secret
    \\  --name <name>        Username
    \\  --password <secret>  Password (used to derive token; not stored)
    \\  -h, --help           Show this help
    \\
;

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

fn isVersion(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version");
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip(); // skip argv[0]

    const subcommand = it.next() orelse {
        std.debug.print(help_root, .{version});
        return;
    };

    if (isHelp(subcommand) or std.mem.eql(u8, subcommand, "help")) {
        std.debug.print(help_root, .{version});
        return;
    }

    if (isVersion(subcommand)) {
        std.debug.print("{s}\n", .{version});
        return;
    }

    if (std.mem.eql(u8, subcommand, "gen-secret")) {
        return cmdGenSecret(&it);
    }

    if (std.mem.eql(u8, subcommand, "add-user")) {
        return cmdAddUser(alloc, &it);
    }

    if (std.mem.eql(u8, subcommand, "serve")) {
        return cmdServe(io, alloc, &it);
    }

    // Unknown subcommand — check if it looks like a flag for bare `foldb --flag` usage,
    // otherwise error rather than silently falling through to serve.
    if (std.mem.startsWith(u8, subcommand, "-")) {
        // Re-parse all args including the first one we consumed.
        var it2 = std.process.Args.Iterator.init(init.minimal.args);
        _ = it2.skip();
        return cmdServe(io, alloc, &it2);
    }

    std.debug.print("error: unknown command '{s}'\n\n", .{subcommand});
    std.debug.print(help_root, .{version});
    std.process.exit(1);
}

// ---------------------------------------------------------------------------
// gen-secret: generate a random auth_secret and print it
// ---------------------------------------------------------------------------

fn cmdGenSecret(it: *std.process.Args.Iterator) !void {
    while (it.next()) |arg| {
        if (isHelp(arg)) {
            std.debug.print(help_gen_secret, .{});
            return;
        }
        std.debug.print("error: unknown argument '{s}'\n\n", .{arg});
        std.debug.print(help_gen_secret, .{});
        std.process.exit(1);
    }
    var secret: [32]u8 = undefined;
    _ = std.os.linux.getrandom(&secret, secret.len, 0);
    var encoded_buf: [std.base64.standard.Encoder.calcSize(32)]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&encoded_buf, &secret);
    std.debug.print(
        "Add this to your config:\n  \"auth_secret\": \"{s}\"\n\nKeep auth_secret secure -- anyone with it can derive valid tokens.\n",
        .{encoded},
    );
}

// ---------------------------------------------------------------------------
// add-user: derive a token for a user and print the config snippet
// ---------------------------------------------------------------------------

fn cmdAddUser(alloc: std.mem.Allocator, it: *std.process.Args.Iterator) !void {
    var config_path: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var password: ?[]const u8 = null;

    while (it.next()) |arg| {
        if (isHelp(arg)) {
            std.debug.print(help_add_user, .{});
            return;
        } else if (std.mem.eql(u8, arg, "--config")) {
            config_path = it.next();
        } else if (std.mem.eql(u8, arg, "--name")) {
            name = it.next();
        } else if (std.mem.eql(u8, arg, "--password")) {
            password = it.next();
        } else {
            std.debug.print("error: unknown argument '{s}'\n\n", .{arg});
            std.debug.print(help_add_user, .{});
            std.process.exit(1);
        }
    }

    const cfg_path = config_path orelse {
        std.debug.print(help_add_user, .{});
        std.process.exit(1);
    };
    const user_name = name orelse {
        std.debug.print("error: --name is required\n\n", .{});
        std.debug.print(help_add_user, .{});
        std.process.exit(1);
    };
    const user_pw = password orelse {
        std.debug.print("error: --password is required\n\n", .{});
        std.debug.print(help_add_user, .{});
        std.process.exit(1);
    };

    var pc = config_mod.from_file(cfg_path, alloc) catch |e| {
        std.debug.print("error: could not read config: {s}\n", .{@errorName(e)});
        return e;
    };
    defer pc.deinit();

    if (pc.value.auth_secret.len == 0) {
        std.debug.print(
            "error: auth_secret is not set in config.\n" ++
                "Run `foldb gen-secret` to generate one.\n",
            .{},
        );
        return error.NoAuthSecret;
    }

    // Derive token: HMAC-SHA256(key=auth_secret, msg=name + ":" + password)
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    const hmac_input = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ user_name, user_pw });
    defer alloc.free(hmac_input);
    HmacSha256.create(&mac, hmac_input, pc.value.auth_secret);

    var token_buf: [std.base64.standard.Encoder.calcSize(32)]u8 = undefined;
    const token = std.base64.standard.Encoder.encode(&token_buf, &mac);

    std.debug.print(
        "Token for '{s}': {s}\n\nAdd this entry to your config's \"users\" array:\n  {{\"name\": \"{s}\", \"token\": \"{s}\"}}\n\nGive the token to the client. It will not be shown again.\n",
        .{ user_name, token, user_name, token },
    );
}

// ---------------------------------------------------------------------------
// serve: main server loop
// ---------------------------------------------------------------------------

fn cmdServe(io: std.Io, alloc: std.mem.Allocator, it: *std.process.Args.Iterator) !void {
    var config_path: ?[]const u8 = null;
    var storage_dir_override: ?[]const u8 = null;
    var port_override: ?u16 = null;

    while (it.next()) |arg| {
        if (isHelp(arg)) {
            std.debug.print(help_serve, .{});
            return;
        } else if (std.mem.eql(u8, arg, "--config")) {
            if (it.next()) |val| config_path = val;
        } else if (std.mem.eql(u8, arg, "--storage-dir")) {
            if (it.next()) |val| storage_dir_override = val;
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (it.next()) |val| port_override = try std.fmt.parseInt(u16, val, 10);
        } else {
            std.debug.print("error: unknown argument '{s}'\n\n", .{arg});
            std.debug.print(help_serve, .{});
            std.process.exit(1);
        }
    }

    if (config_path == null and storage_dir_override == null) {
        std.debug.print(help_serve, .{});
        std.process.exit(1);
    }

    var parsed: ?config_mod.ParsedConfig = null;
    defer if (parsed) |*p| p.deinit();

    const cfg: config_mod.Config = if (config_path) |path| blk: {
        parsed = try config_mod.from_file(path, alloc);
        break :blk parsed.?.value;
    } else config_mod.Config{};

    const storage_dir = storage_dir_override orelse cfg.storage_dir;
    const port = port_override orelse cfg.listen_port;

    // Validate S3 config: all-or-nothing. Partial configuration is a mistake.
    const s3_fields_set = @as(u8, if (cfg.s3_endpoint.len > 0) 1 else 0) +
        @as(u8, if (cfg.s3_bucket.len > 0) 1 else 0) +
        @as(u8, if (cfg.s3_access_key.len > 0) 1 else 0) +
        @as(u8, if (cfg.s3_secret_key.len > 0) 1 else 0);
    const s3_enabled = s3_fields_set == 4;
    if (s3_fields_set > 0 and s3_fields_set < 4) {
        std.debug.print("error: S3 is partially configured — set all of s3_endpoint, s3_bucket, s3_access_key, s3_secret_key or none of them.\n", .{});
        return error.InvalidConfig;
    }
    if (s3_enabled and cfg.s3_region.len == 0) {
        std.debug.print("error: s3_region is required when S3 is configured.\n", .{});
        return error.InvalidConfig;
    }

    const s3ep: config_mod.ParsedS3Endpoint = if (s3_enabled)
        config_mod.parse_s3_endpoint(cfg.s3_endpoint) catch {
            std.debug.print("error: could not parse s3_endpoint — expected http[s]://host[:port]\n", .{});
            return error.InvalidConfig;
        }
    else
        .{ .host = "", .port = 0 };

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

    std.debug.print("foldb starting: storage={s} port={d} node_id={d} partitions={d} peers={d} auth={s} s3={s}\n", .{
        storage_dir,
        port,
        cfg.node_id,
        cfg.partition_count,
        cfg.peers.len,
        if (cfg.users.len > 0) "token" else "open",
        if (s3_enabled) "enabled" else "disabled",
    });

    if (!s3_enabled) {
        std.debug.print("warning: S3 is not configured. Snapshots and log truncation are disabled. " ++
            "Recovery requires full log replay from the beginning. " ++
            "See docs/internal/config.md for S3 setup.\n", .{});
    }

    const gw = try gateway_mod.Gateway.init(storage_dir, alloc, .{
        .partition_count = cfg.partition_count,
        .node_id = cfg.node_id,
        .tick_interval_ms = 10,
        .election_timeout_min_ms = cfg.election_timeout_min_ms,
        .election_timeout_max_ms = cfg.election_timeout_max_ms,
        .heartbeat_interval_ms = cfg.heartbeat_interval_ms,
        .peers = peer_addrs,
        .s3_io = if (s3_enabled) io else null,
        .s3_endpoint_host = s3ep.host,
        .s3_endpoint_port = s3ep.port,
        .s3_access_key = cfg.s3_access_key,
        .s3_secret_key = cfg.s3_secret_key,
        .s3_region = cfg.s3_region,
        .s3_bucket = cfg.s3_bucket,
    });
    defer gw.deinit();

    try server.serve(io, port, gw, cfg.users, alloc);
}
