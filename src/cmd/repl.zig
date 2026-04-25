const std = @import("std");
const client_mod = @import("client.zig");
const messages = @import("messages.zig");

const assert = std.debug.assert;

// ---- I/O helpers (raw Linux syscalls) ----

fn writeAll(data: []const u8) !void {
    assert(data.len <= std.math.maxInt(usize));
    var written: usize = 0;
    while (written < data.len) {
        const n = std.os.linux.write(1, data.ptr + written, data.len - written);
        const ni: isize = @bitCast(n);
        if (ni <= 0) return error.WriteError;
        written += @intCast(ni);
    }
}

const Out = struct {
    buf: [4096]u8 = undefined,

    pub fn print(self: *Out, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.bufPrint(&self.buf, fmt, args);
        try writeAll(s);
    }
};

fn readByte() ?u8 {
    var byte: u8 = undefined;
    const n = std.os.linux.read(0, @as([*]u8, @ptrCast(&byte)), 1);
    if (@as(isize, @bitCast(n)) <= 0) return null;
    return byte;
}

// ---- Terminal raw mode ----

fn rawEnter() !std.posix.termios {
    const orig = try std.posix.tcgetattr(0);
    var raw = orig;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(0, .FLUSH, raw);
    return orig;
}

fn rawLeave(orig: std.posix.termios) void {
    std.posix.tcsetattr(0, .FLUSH, orig) catch {};
}

// ---- History ----

const MAX_HISTORY: u32 = 1000;

fn historyPush(history: *std.ArrayListUnmanaged([]u8), entry: []const u8, alloc: std.mem.Allocator) !void {
    assert(entry.len > 0);
    if (history.items.len > 0 and std.mem.eql(u8, history.items[history.items.len - 1], entry)) return;
    if (history.items.len >= MAX_HISTORY) {
        alloc.free(history.items[0]);
        std.mem.copyForwards([]u8, history.items[0..history.items.len - 1], history.items[1..]);
        history.items.len -= 1;
    }
    try history.append(alloc, try alloc.dupe(u8, entry));
}

// ---- Line editor ----

fn lineDraw(prompt: []const u8, line: []const u8, cursor: u32) !void {
    assert(cursor <= line.len);
    try writeAll("\r");
    try writeAll(prompt);
    try writeAll(line);
    try writeAll("\x1b[K"); // clear to end of line
    if (cursor < line.len) {
        var seq_buf: [16]u8 = undefined;
        const seq = std.fmt.bufPrint(&seq_buf, "\x1b[{d}D", .{line.len - cursor}) catch unreachable;
        try writeAll(seq);
    }
}

const NavDir = enum { up, down };

fn histNav(
    line: *std.ArrayListUnmanaged(u8),
    cursor: *u32,
    hist_pos: *u32,
    saved: *std.ArrayListUnmanaged(u8),
    history: []const []const u8,
    prompt: []const u8,
    alloc: std.mem.Allocator,
    dir: NavDir,
) !void {
    assert(hist_pos.* <= history.len);
    assert(cursor.* <= line.items.len);
    switch (dir) {
        .up => {
            if (hist_pos.* >= history.len) return;
            if (hist_pos.* == 0) {
                saved.clearRetainingCapacity();
                try saved.appendSlice(alloc, line.items);
            }
            hist_pos.* += 1;
            line.clearRetainingCapacity();
            try line.appendSlice(alloc, history[history.len - hist_pos.*]);
        },
        .down => {
            if (hist_pos.* == 0) return;
            hist_pos.* -= 1;
            line.clearRetainingCapacity();
            const src = if (hist_pos.* == 0) saved.items else history[history.len - hist_pos.*];
            try line.appendSlice(alloc, src);
        },
    }
    cursor.* = @intCast(line.items.len);
    try lineDraw(prompt, line.items, cursor.*);
}

fn handleEscape(
    line: *std.ArrayListUnmanaged(u8),
    cursor: *u32,
    hist_pos: *u32,
    saved: *std.ArrayListUnmanaged(u8),
    history: []const []const u8,
    prompt: []const u8,
    alloc: std.mem.Allocator,
) !void {
    assert(cursor.* <= line.items.len);
    const b1 = readByte() orelse return;
    if (b1 != '[') return;
    const b2 = readByte() orelse return;
    switch (b2) {
        'A' => try histNav(line, cursor, hist_pos, saved, history, prompt, alloc, .up),
        'B' => try histNav(line, cursor, hist_pos, saved, history, prompt, alloc, .down),
        'C' => if (cursor.* < line.items.len) { cursor.* += 1; try writeAll("\x1b[C"); },
        'D' => if (cursor.* > 0) { cursor.* -= 1; try writeAll("\x1b[D"); },
        else => {},
    }
}

/// Read one line with raw-mode editing and history. Returns null on EOF.
/// Returns error.Interrupted on Ctrl-C (caller should clear any pending buffer).
fn readLineRaw(
    prompt: []const u8,
    history: []const []const u8,
    alloc: std.mem.Allocator,
) !?[]u8 {
    assert(prompt.len > 0);
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(alloc);
    var saved: std.ArrayListUnmanaged(u8) = .empty;
    defer saved.deinit(alloc);
    var cursor: u32 = 0;
    var hist_pos: u32 = 0;

    try writeAll(prompt);

    while (true) {
        const byte = readByte() orelse {
            if (line.items.len == 0) return null;
            return try line.toOwnedSlice(alloc);
        };
        switch (byte) {
            0x0d, 0x0a => { // Enter
                try writeAll("\r\n");
                return try line.toOwnedSlice(alloc);
            },
            0x03 => { // Ctrl-C
                try writeAll("^C\r\n");
                return error.Interrupted;
            },
            0x04 => { // Ctrl-D: EOF if line empty, else delete-forward
                if (line.items.len == 0) { try writeAll("\r\n"); return null; }
                if (cursor < line.items.len) {
                    _ = line.orderedRemove(cursor);
                    try lineDraw(prompt, line.items, cursor);
                }
            },
            0x7f, 0x08 => { // Backspace
                if (cursor > 0) {
                    cursor -= 1;
                    _ = line.orderedRemove(cursor);
                    try lineDraw(prompt, line.items, cursor);
                }
            },
            0x1b => try handleEscape(&line, &cursor, &hist_pos, &saved, history, prompt, alloc),
            else => if (byte >= 0x20 and byte < 0x7f) {
                try line.insert(alloc, cursor, byte);
                cursor += 1;
                try lineDraw(prompt, line.items, cursor);
            },
        }
    }
}

/// Fallback for non-tty stdin (pipes, scripts). No editing, no history.
fn readLinePlain(alloc: std.mem.Allocator) !?[]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    while (true) {
        const byte = readByte() orelse {
            if (buf.items.len == 0) { buf.deinit(alloc); return null; }
            return try buf.toOwnedSlice(alloc);
        };
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
    const kw = s[0..end];
    if (std.ascii.eqlIgnoreCase(kw, "select") or
        std.ascii.eqlIgnoreCase(kw, "with") or
        std.ascii.eqlIgnoreCase(kw, "describe")) return .select;
    if (std.ascii.eqlIgnoreCase(kw, "insert") or
        std.ascii.eqlIgnoreCase(kw, "update") or
        std.ascii.eqlIgnoreCase(kw, "delete") or
        std.ascii.eqlIgnoreCase(kw, "merge")) return .dml;
    if (std.ascii.eqlIgnoreCase(kw, "create") or
        std.ascii.eqlIgnoreCase(kw, "drop") or
        std.ascii.eqlIgnoreCase(kw, "alter")) return .ddl;
    return .unknown;
}

// ---- Result display ----

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
    var tmp: [40]u8 = undefined;
    const frac_str = std.fmt.bufPrint(&tmp, "{d}", .{frac_part}) catch unreachable;
    const leading: usize = d.scale - frac_str.len;
    var frac_buf: [40]u8 = undefined;
    @memset(frac_buf[0..leading], '0');
    @memcpy(frac_buf[leading .. leading + frac_str.len], frac_str);
    const full_frac = frac_buf[0 .. leading + frac_str.len];
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

// ---- Dispatch ----

fn dispatch(c: *client_mod.Client, sql_with_semi: []const u8, out: *Out) !void {
    assert(sql_with_semi.len > 0);
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
        .select, .unknown => {
            var rs = c.query(hash, &.{}) catch |e| {
                if (isConnError(e)) return e;
                const msg = c.last_error_msg();
                if (msg.len > 0) try out.print("error: {s}\n", .{msg}) else try out.print("error: {}\n", .{e});
                return;
            };
            defer rs.deinit();
            printTable(&rs, out) catch {};
        },
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

    var ws: std.posix.winsize = undefined;
    const is_tty = @as(isize, @bitCast(std.os.linux.ioctl(0, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws)))) >= 0;
    const orig_termios: ?std.posix.termios = if (is_tty) rawEnter() catch null else null;
    defer if (orig_termios) |orig| rawLeave(orig);

    var history: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (history.items) |h| alloc.free(h);
        history.deinit(alloc);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    while (true) {
        const prompt = if (buf.items.len == 0) "foldb> " else "   ...> ";

        const line_or_null: ?[]u8 = if (is_tty and orig_termios != null)
            readLineRaw(prompt, history.items, alloc) catch |e| {
                if (e == error.Interrupted) { buf.clearRetainingCapacity(); continue; }
                return e;
            }
        else blk: {
            if (buf.items.len == 0) try out.print("{s}", .{prompt});
            break :blk try readLinePlain(alloc);
        };

        const line = line_or_null orelse break;
        defer alloc.free(line);

        const trimmed = std.mem.trimEnd(u8, line, "\r ");

        if (std.mem.eql(u8, trimmed, "\\q") or
            std.mem.eql(u8, trimmed, "quit") or
            std.mem.eql(u8, trimmed, "quit;"))
        {
            break;
        }

        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "\\d ")) {
            const tname = std.mem.trim(u8, trimmed[3..], " \t");
            if (tname.len > 0) {
                const sql = try std.fmt.allocPrint(alloc, "describe {s};", .{tname});
                defer alloc.free(sql);
                historyPush(&history, sql, alloc) catch {};
                dispatch(&c, sql, &out) catch |e| try out.print("error: {}\n", .{e});
                continue;
            }
        }

        if (buf.items.len > 0) try buf.append(alloc, ' ');
        try buf.appendSlice(alloc, trimmed);

        if (std.mem.endsWith(u8, buf.items, ";")) {
            if (buf.items.len > 1) historyPush(&history, buf.items, alloc) catch {};

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
