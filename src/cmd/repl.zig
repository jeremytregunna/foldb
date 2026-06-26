/// Foldb REPL — interactive KV shell.
const std = @import("std");
const posix = std.posix;
const client_mod = @import("client.zig");

const Client = client_mod.Client;
const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_PORT = 7432;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(alloc);
    var it = std.process.Args.Iterator.init(init.minimal.args);
    while (it.next()) |arg| {
        try args_list.append(alloc, try alloc.dupe(u8, arg));
    }
    defer {
        for (args_list.items) |a| alloc.free(a);
    }
    return run(io, alloc, args_list.items);
}

pub fn run(io: std.Io, alloc: std.mem.Allocator, args: []const []const u8) !void {
    var host: []const u8 = DEFAULT_HOST;
    var port: u16 = DEFAULT_PORT;
    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        if (std.mem.eql(u8, args[idx], "--host") and idx + 1 < args.len) {
            host = args[idx + 1];
            idx += 1;
        } else if (std.mem.eql(u8, args[idx], "--port") and idx + 1 < args.len) {
            port = std.fmt.parseUnsigned(u16, args[idx + 1], 10) catch 7432;
            idx += 1;
        }
    }

    const stream = try client_mod.connect_stream(io, host, port);
    var cl = try Client.init(io, stream, alloc);
    defer cl.deinit();
    try cl.handshake("default");

    try outPrint( "foldb v0.1.0 — KV shell ({s}:{d})\nType HELP for commands.\n", .{ host, port });
    try outPrint( "foldb> ", .{});

    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    var len: usize = 0;
    while (true) {
        // Ensure we have data in buf[pos..len]
        if (pos >= len) {
            const rc = posix.read(posix.STDIN_FILENO, &buf) catch |err| return err;
            if (rc == 0) break;
            pos = 0;
            len = rc;
        }

        // Find next newline in buf[pos..len]
        const line_start = pos;
        var found: ?usize = null;
        var i: usize = pos;
        while (i < len) : (i += 1) {
            if (buf[i] == '\n' or buf[i] == '\r') {
                found = i;
                break;
            }
        }

        if (found) |nl| {
            pos = nl + 1;
            const line = buf[line_start..nl];
            const cmd = std.mem.trim(u8, line, " \r\t");
            if (cmd.len == 0) {
                try outPrint( "foldb> ", .{});
                continue;
            }

            execute( &cl, cmd) catch |err| {
                try outPrint( "error: {}\n", .{err});
            };
            try outPrint( "foldb> ", .{});
        } else {
            // No newline found, treat entire buffer as one line
            pos = len;
            const line = buf[line_start..len];
            const cmd = std.mem.trim(u8, line, " \r\t");
            if (cmd.len == 0) {
                try outPrint( "foldb> ", .{});
                continue;
            }

            execute( &cl, cmd) catch |err| {
                try outPrint( "error: {}\n", .{err});
            };
            try outPrint( "foldb> ", .{});
        }
    }
}

fn outPrint(comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const data = try std.fmt.bufPrint(&buf, fmt, args);
    _ = std.os.linux.write(std.posix.STDOUT_FILENO, data.ptr, data.len);
}

fn execute(cl: *Client, cmd: []const u8) !void {
    const sp = std.mem.indexOfAny(u8, cmd, " \t");
    const verb = if (sp) |s| cmd[0..s] else cmd;
    const rest = if (sp) |s| std.mem.trim(u8, cmd[s..], " \t") else &.{};

    if (std.ascii.eqlIgnoreCase(verb, "EXIT") or std.ascii.eqlIgnoreCase(verb, "QUIT")) {
        cl.close();
        std.process.exit(0);
    } else if (std.ascii.eqlIgnoreCase(verb, "HELP")) {
        try outPrint( "Commands:\n  GET key              — fetch value\n  SET key value        — store value\n  DELETE key           — delete key\n  RANGE start end      — scan range\n  RANGE start end N    — scan range (max N)\n  PING                 — latency check\n  EXIT / QUIT          — exit\n  HELP                 — this message\n", .{});
    } else if (std.ascii.eqlIgnoreCase(verb, "GET")) {
        if (rest.len == 0) return error.MissingKey;
        var res = try cl.get(rest);
        defer res.deinit();
        if (res.value) |v| {
            try outPrint( "{s} (seq: {d})\n", .{ v, res.committed_seq });
        } else {
            try outPrint( "(null)\n", .{});
        }
    } else if (std.ascii.eqlIgnoreCase(verb, "SET")) {
        const kv = splitFirstSpace(rest) orelse return error.UsageError;
        const res = try cl.set(kv.key, kv.value);
        try outPrint( "seq: {d}\n", .{res.committed_seq});
    } else if (std.ascii.eqlIgnoreCase(verb, "DELETE")) {
        if (rest.len == 0) return error.MissingKey;
        const res = try cl.delete(rest);
        try outPrint( "seq: {d}\n", .{res.committed_seq});
    } else if (std.ascii.eqlIgnoreCase(verb, "RANGE")) {
        const parts = splitRangeArgs(rest) orelse return error.UsageError;
        const limit: u32 = if (parts.limit) |n| std.fmt.parseUnsigned(u32, n, 10) catch 0 else 0;
        var res = try cl.range_limit(parts.start, parts.end, limit);
        defer res.deinit();
        for (res.entries) |e| {
            try outPrint( "{s}\t{s}\n", .{ e.key, e.value });
        }
        try outPrint( "{d} entries (seq: {d})\n", .{res.entries.len, res.committed_seq});
    } else if (std.ascii.eqlIgnoreCase(verb, "PING")) {
        const t = try cl.ping();
        try outPrint( "pong ({d}us)\n", .{t});
    } else {
        try outPrint( "unknown command: {s}\n", .{verb});
    }
}

fn splitFirstSpace(s: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const sp = std.mem.indexOfAny(u8, s, " \t") orelse return null;
    return .{ .key = s[0..sp], .value = std.mem.trim(u8, s[sp..], " \t") };
}

fn splitRangeArgs(s: []const u8) ?struct { start: []const u8, end: []const u8, limit: ?[]const u8 } {
    var it = std.mem.tokenizeAny(u8, s, " \t");
    const start = it.next() orelse return null;
    const end = it.next() orelse return null;
    const limit = it.next();
    return .{ .start = start, .end = end, .limit = limit };
}
