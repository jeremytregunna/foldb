const std = @import("std");
const client_mod = @import("client.zig");
const messages = @import("messages.zig");

// ---- I/O helpers (raw Linux syscalls, consistent with rest of codebase) ----

fn writeAll(data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const n = std.os.linux.write(1, data.ptr + written, data.len - written);
        const ni: isize = @bitCast(n);
        if (ni <= 0) return error.WriteError;
        written += @intCast(ni);
    }
}

/// Thin writer passed through dispatch/print helpers.
const Out = struct {
    buf: [4096]u8 = undefined,

    pub fn print(self: *Out, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.bufPrint(&self.buf, fmt, args);
        try writeAll(s);
    }
};

/// Read one line from stdin (fd 0). Returns null on EOF. Caller owns the slice.
fn readLine(alloc: std.mem.Allocator) !?[]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    while (true) {
        var byte: u8 = undefined;
        const n = std.os.linux.read(0, @as([*]u8, @ptrCast(&byte)), 1);
        const ni: isize = @bitCast(n);
        if (ni < 0) return error.ReadError;
        if (ni == 0) {
            if (buf.items.len == 0) {
                buf.deinit(alloc);
                return null; // EOF
            }
            return try buf.toOwnedSlice(alloc);
        }
        if (byte == '\n') return try buf.toOwnedSlice(alloc);
        try buf.append(alloc, byte);
    }
}

// ---- SQL classification ----

const SqlKind = enum { ddl, dml, select, unknown };

fn classify(sql: []const u8) SqlKind {
    const s = std.mem.trimStart(u8, sql, " \t\r\n");
    var end: usize = 0;
    while (end < s.len and s[end] != ' ' and s[end] != '\t' and s[end] != '(' and s[end] != ';') : (end += 1) {}
    if (end == 0) return .unknown;
    var token_buf: [16]u8 = undefined;
    const tok_len = @min(end, token_buf.len);
    for (s[0..tok_len], 0..) |c, i| {
        token_buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    const tok = token_buf[0..tok_len];
    if (std.mem.eql(u8, tok, "create") or std.mem.eql(u8, tok, "drop") or std.mem.eql(u8, tok, "alter")) return .ddl;
    if (std.mem.eql(u8, tok, "insert") or std.mem.eql(u8, tok, "update") or std.mem.eql(u8, tok, "delete")) return .dml;
    if (std.mem.eql(u8, tok, "select")) return .select;
    return .unknown;
}

// ---- Dispatch ----

fn dispatch(c: *client_mod.Client, sql_with_semi: []const u8, out: *Out) !void {
    const sql = std.mem.trimEnd(u8, std.mem.trimEnd(u8, sql_with_semi, " \t\r\n"), ";");
    const kind = classify(sql);

    const hash = c.register(sql) catch |e| {
        if (isConnError(e)) return e;
        const msg = c.last_error_msg();
        if (msg.len > 0) try out.print("error: {s}\n", .{msg}) else try out.print("error: {}\n", .{e});
        return;
    };

    switch (kind) {
        .ddl => {
            _ = c.execute(hash, &.{}) catch |e| {
                if (isConnError(e)) return e;
                const msg = c.last_error_msg();
                if (msg.len > 0) try out.print("error: {s}\n", .{msg}) else try out.print("error: {}\n", .{e});
                return;
            };
            try out.print("OK\n", .{});
        },
        .dml => {
            const result = c.execute(hash, &.{}) catch |e| {
                if (isConnError(e)) return e;
                const msg = c.last_error_msg();
                if (msg.len > 0) try out.print("error: {s}\n", .{msg}) else try out.print("error: {}\n", .{e});
                return;
            };
            try out.print("{d} row(s) affected\n", .{result.rows_affected});
        },
        .select => {
            var rs = c.query(hash, &.{}) catch |e| {
                if (isConnError(e)) return e;
                const msg = c.last_error_msg();
                if (msg.len > 0) try out.print("error: {s}\n", .{msg}) else try out.print("error: {}\n", .{e});
                return;
            };
            defer rs.deinit();
            printTable(&rs, out) catch {};
        },
        .unknown => try out.print("error: unrecognised statement type\n", .{}),
    }
}

fn printTable(rs: *client_mod.ResultSet, out: *Out) !void {
    for (rs.columns, 0..) |col, i| {
        if (i > 0) try out.print(" | ", .{});
        try out.print("{s}", .{col.name});
    }
    try out.print("\n", .{});
    for (rs.columns, 0..) |col, i| {
        if (i > 0) try out.print("-+-", .{});
        for (0..col.name.len) |_| try out.print("-", .{});
    }
    try out.print("\n", .{});
    for (rs.rows) |row| {
        for (row, 0..) |val, i| {
            if (i > 0) try out.print(" | ", .{});
            try printValue(val, out);
        }
        try out.print("\n", .{});
    }
    try out.print("({d} row(s))\n", .{rs.rows.len});
}

fn printDecimal(d: anytype, out: *Out) !void {
    if (d.scale == 0) {
        try out.print("{d}", .{d.coefficient});
        return;
    }
    const neg = d.coefficient < 0;
    const abs_c: u128 = if (neg) @intCast(-d.coefficient) else @intCast(d.coefficient);
    var pow: u128 = 1;
    var s: u8 = 0;
    while (s < d.scale) : (s += 1) pow *= 10;
    const int_part = abs_c / pow;
    const frac_part = abs_c % pow;

    // Build fractional digits with leading zeros to fill exactly scale positions.
    var tmp: [40]u8 = undefined;
    const frac_str = std.fmt.bufPrint(&tmp, "{d}", .{frac_part}) catch unreachable;
    const leading: usize = d.scale - frac_str.len;
    var frac_buf: [40]u8 = undefined;
    @memset(frac_buf[0..leading], '0');
    @memcpy(frac_buf[leading .. leading + frac_str.len], frac_str);
    const full_frac = frac_buf[0 .. leading + frac_str.len];

    // Trim trailing zeros.
    var trim = full_frac.len;
    while (trim > 0 and full_frac[trim - 1] == '0') trim -= 1;

    if (neg) try out.print("-", .{});
    if (trim == 0) {
        try out.print("{d}", .{int_part});
    } else {
        try out.print("{d}.{s}", .{ int_part, full_frac[0..trim] });
    }
}

fn printValue(v: messages.TypedValue, out: *Out) !void {
    switch (v) {
        .null_val => try out.print("NULL", .{}),
        .bool_val => |b| try out.print("{}", .{b}),
        .int8 => |n| try out.print("{d}", .{n}),
        .int16 => |n| try out.print("{d}", .{n}),
        .int32 => |n| try out.print("{d}", .{n}),
        .int64 => |n| try out.print("{d}", .{n}),
        .uint8 => |n| try out.print("{d}", .{n}),
        .uint16 => |n| try out.print("{d}", .{n}),
        .uint32 => |n| try out.print("{d}", .{n}),
        .uint64 => |n| try out.print("{d}", .{n}),
        .float32 => |f| try out.print("{d}", .{f}),
        .float64 => |f| try out.print("{d}", .{f}),
        .decimal => |d| try printDecimal(d, out),
        .string => |s| try out.print("{s}", .{s}),
        .bytes => |b| try out.print("<bytes:{d}>", .{b.len}),
        .timestamp => |t| try out.print("{d}", .{t}),
        .json => |j| try out.print("{s}", .{j}),
        else => try out.print("?", .{}),
    }
}

fn isConnError(e: anyerror) bool {
    return e == error.ConnectionClosed or e == error.ReadError or
        e == error.WriteError or e == error.ConnectError;
}

fn tryReconnect(
    host: []const u8,
    port: u16,
    alloc: std.mem.Allocator,
    out: *Out,
) ?client_mod.Client {
    const max_attempts = 10;
    var attempt: u32 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        if (attempt > 0) {
            var ts = std.os.linux.timespec{ .sec = 0, .nsec = 500_000_000 };
            _ = std.os.linux.nanosleep(&ts, null);
        }
        out.print("reconnecting to {s}:{d}... ({d}/{d})\n", .{ host, port, attempt + 1, max_attempts }) catch {};
        const c = client_mod.connect(host, port, alloc) catch continue;
        out.print("reconnected\n", .{}) catch {};
        return c;
    }
    out.print("error: could not reconnect after {d} attempts\n", .{max_attempts}) catch {};
    return null;
}

// ---- Main ----

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var out = Out{};

    var host: []const u8 = "127.0.0.1";
    var port: u16 = 7432;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host")) {
            if (it.next()) |val| host = val;
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (it.next()) |val| port = std.fmt.parseInt(u16, val, 10) catch 7432;
        }
    }

    var c = client_mod.connect(host, port, alloc) catch |e| {
        try out.print("error: could not connect to {s}:{d}: {}\n", .{ host, port, e });
        return;
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    while (true) {
        if (buf.items.len == 0) {
            try writeAll("foldb> ");
        } else {
            try writeAll("   ...> ");
        }

        const line = readLine(alloc) catch break orelse break;
        defer alloc.free(line);

        const trimmed = std.mem.trimEnd(u8, line, "\r ");

        if (std.mem.eql(u8, trimmed, "\\q") or
            std.mem.eql(u8, trimmed, "quit") or
            std.mem.eql(u8, trimmed, "quit;"))
        {
            break;
        }

        if (trimmed.len == 0) continue;

        if (buf.items.len > 0) try buf.append(alloc, ' ');
        try buf.appendSlice(alloc, trimmed);

        if (std.mem.endsWith(u8, buf.items, ";")) {
            var disconnected = false;
            dispatch(&c, buf.items, &out) catch |e| {
                if (!isConnError(e)) {
                    try out.print("error: {}\n", .{e});
                } else {
                    try out.print("connection lost\n", .{});
                    c.deinit();
                    if (tryReconnect(host, port, alloc, &out)) |new_c| {
                        c = new_c;
                        dispatch(&c, buf.items, &out) catch {};
                    } else {
                        disconnected = true;
                    }
                }
            };
            buf.clearRetainingCapacity();
            if (disconnected) break;
        }
    }

    c.close();
}
