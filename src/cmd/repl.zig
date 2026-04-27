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
    buf: [4096]u8,

    pub fn print(self: *Out, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.bufPrint(&self.buf, fmt, args);
        try writeAll(s);
    }
};

fn readByte() ?u8 {
    // SAFETY: linux.read fills byte with 1 byte before it is returned.
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
    std.posix.tcsetattr(0, .FLUSH, orig) catch |err| std.log.warn("rawLeave: {}", .{err});
}

// ---- History ----

const MAX_HISTORY: u32 = 1000;

fn historyPush(history: *std.ArrayListUnmanaged([]u8), entry: []const u8, alloc: std.mem.Allocator) !void {
    assert(entry.len > 0);
    if (history.items.len > 0 and std.mem.eql(u8, history.items[history.items.len - 1], entry)) return;
    if (history.items.len >= MAX_HISTORY) {
        alloc.free(history.items[0]);
        std.mem.copyForwards([]u8, history.items[0 .. history.items.len - 1], history.items[1..]);
        history.items.len -= 1;
    }
    try history.append(alloc, try alloc.dupe(u8, entry));
}

// ---- Line editor ----

/// Redraw the prompt and line. prev_pos is the cursor's current display position
/// (prompt.len + prev_cursor) so we can move up to the prompt row when content wraps.
fn lineDraw(prompt: []const u8, line: []const u8, cursor: u32, prev_pos: u32, term_cols: u32) !void {
    assert(cursor <= line.len);
    const cols: u32 = if (term_cols > 0) term_cols else 80;
    // Move up to the prompt row if the cursor is on a wrapped row below it.
    const prev_row = prev_pos / cols;
    if (prev_row > 0) {
        var buf: [16]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[{d}A", .{prev_row}) catch unreachable;
        try writeAll(seq);
    }
    // Go to column 0 of the prompt row and clear to end of screen.
    try writeAll("\r\x1b[0J");
    try writeAll(prompt);
    try writeAll(line);
    // Reposition cursor if it isn't at the end.
    const end_display: u32 = @intCast(prompt.len + line.len);
    const cursor_display: u32 = @intCast(prompt.len + cursor);
    if (cursor_display < end_display) {
        const end_row = end_display / cols;
        const cursor_row = cursor_display / cols;
        const cursor_col = cursor_display % cols;
        if (cursor_row < end_row) {
            // Cursor is on a row above the end row: move up and set column.
            var buf: [32]u8 = undefined;
            const seq = std.fmt.bufPrint(&buf, "\x1b[{d}A\x1b[{d}G", .{ end_row - cursor_row, cursor_col + 1 }) catch unreachable;
            try writeAll(seq);
        } else {
            // Same row: move left.
            var buf: [16]u8 = undefined;
            const seq = std.fmt.bufPrint(&buf, "\x1b[{d}D", .{end_display - cursor_display}) catch unreachable;
            try writeAll(seq);
        }
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
    prev_pos: *u32,
    term_cols: u32,
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
    try lineDraw(prompt, line.items, cursor.*, prev_pos.*, term_cols);
    prev_pos.* = @intCast(prompt.len + cursor.*);
}

fn handleEscape(
    line: *std.ArrayListUnmanaged(u8),
    cursor: *u32,
    hist_pos: *u32,
    saved: *std.ArrayListUnmanaged(u8),
    history: []const []const u8,
    prompt: []const u8,
    prev_pos: *u32,
    term_cols: u32,
    alloc: std.mem.Allocator,
) !void {
    assert(cursor.* <= line.items.len);
    const b1 = readByte() orelse return;
    if (b1 != '[') return;
    const b2 = readByte() orelse return;
    switch (b2) {
        'A' => try histNav(line, cursor, hist_pos, saved, history, prompt, prev_pos, term_cols, alloc, .up),
        'B' => try histNav(line, cursor, hist_pos, saved, history, prompt, prev_pos, term_cols, alloc, .down),
        'C' => if (cursor.* < line.items.len) {
            cursor.* += 1;
            prev_pos.* = @intCast(prompt.len + cursor.*);
            try writeAll("\x1b[C");
        },
        'D' => if (cursor.* > 0) {
            cursor.* -= 1;
            prev_pos.* = @intCast(prompt.len + cursor.*);
            try writeAll("\x1b[D");
        },
        else => {},
    }
}

/// Read one line with raw-mode editing and history. Returns null on EOF.
/// Returns error.Interrupted on Ctrl-C (caller should clear any pending buffer).
fn readLineRaw(
    prompt: []const u8,
    history: []const []const u8,
    term_cols: u32,
    alloc: std.mem.Allocator,
) !?[]u8 {
    assert(prompt.len > 0);
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(alloc);
    var saved: std.ArrayListUnmanaged(u8) = .empty;
    defer saved.deinit(alloc);
    var cursor: u32 = 0;
    var hist_pos: u32 = 0;
    // Display position of cursor after the last draw (prompt.len + cursor).
    var prev_pos: u32 = @intCast(prompt.len);

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
                if (line.items.len == 0) {
                    try writeAll("\r\n");
                    return null;
                }
                if (cursor < line.items.len) {
                    _ = line.orderedRemove(cursor);
                    try lineDraw(prompt, line.items, cursor, prev_pos, term_cols);
                    prev_pos = @intCast(prompt.len + cursor);
                }
            },
            0x15 => { // Ctrl-U: clear entire line
                line.clearRetainingCapacity();
                cursor = 0;
                try lineDraw(prompt, line.items, cursor, prev_pos, term_cols);
                prev_pos = @intCast(prompt.len + cursor);
            },
            0x7f, 0x08 => { // Backspace
                if (cursor > 0) {
                    cursor -= 1;
                    _ = line.orderedRemove(cursor);
                    try lineDraw(prompt, line.items, cursor, prev_pos, term_cols);
                    prev_pos = @intCast(prompt.len + cursor);
                }
            },
            0x1b => try handleEscape(&line, &cursor, &hist_pos, &saved, history, prompt, &prev_pos, term_cols, alloc),
            else => if (byte >= 0x20 and byte < 0x7f) {
                try line.insert(alloc, cursor, byte);
                cursor += 1;
                try lineDraw(prompt, line.items, cursor, prev_pos, term_cols);
                prev_pos = @intCast(prompt.len + cursor);
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
            if (buf.items.len == 0) {
                buf.deinit(alloc);
                return null;
            }
            return try buf.toOwnedSlice(alloc);
        };
        if (byte == '\n') return try buf.toOwnedSlice(alloc);
        try buf.append(alloc, byte);
    }
}

// ---- SQL classification ----

const SqlKind = enum { ddl, dml, select, unknown };

fn containsWordIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn classify(sql: []const u8) SqlKind {
    const s = std.mem.trimStart(u8, sql, " \t\r\n");
    var end: usize = 0;
    while (end < s.len and s[end] != ' ' and s[end] != '\t' and s[end] != '(' and s[end] != ';') : (end += 1) {}
    if (end == 0) return .unknown;
    const kw = s[0..end];
    if (std.ascii.eqlIgnoreCase(kw, "select") or
        std.ascii.eqlIgnoreCase(kw, "with") or
        std.ascii.eqlIgnoreCase(kw, "describe") or
        std.ascii.eqlIgnoreCase(kw, "show")) return .select;
    if (std.ascii.eqlIgnoreCase(kw, "insert") or
        std.ascii.eqlIgnoreCase(kw, "update") or
        std.ascii.eqlIgnoreCase(kw, "delete") or
        std.ascii.eqlIgnoreCase(kw, "merge"))
    {
        // DML with RETURNING produces a result set — route through the query path
        if (containsWordIgnoreCase(s, "returning")) return .select;
        return .dml;
    }
    if (std.ascii.eqlIgnoreCase(kw, "create") or
        std.ascii.eqlIgnoreCase(kw, "drop") or
        std.ascii.eqlIgnoreCase(kw, "alter")) return .ddl;
    if (std.ascii.eqlIgnoreCase(kw, "use")) return .ddl;
    return .unknown;
}

// ---- Result display ----

fn renderDecimal(d: anytype, alloc: std.mem.Allocator) ![]u8 {
    if (d.scale == 0) return std.fmt.allocPrint(alloc, "{d}", .{d.coefficient});
    const neg = d.coefficient < 0;
    const abs_c: u128 = if (neg) @intCast(-d.coefficient) else @intCast(d.coefficient);
    var pow: u128 = 1;
    var sc: u8 = 0;
    while (sc < d.scale) : (sc += 1) pow *= 10;
    const int_part = abs_c / pow;
    const frac_part = abs_c % pow;
    // SAFETY: bufPrint writes to tmp before frac_str is used; buffer is large enough.
    var tmp: [40]u8 = undefined;
    const frac_str = std.fmt.bufPrint(&tmp, "{d}", .{frac_part}) catch |err| std.debug.panic("unexpected: {}", .{err});
    const leading: usize = d.scale - frac_str.len;
    // SAFETY: @memset and @memcpy fill frac_buf up to leading+frac_str.len before it is sliced.
    var frac_buf: [40]u8 = undefined;
    @memset(frac_buf[0..leading], '0');
    @memcpy(frac_buf[leading .. leading + frac_str.len], frac_str);
    const full_frac = frac_buf[0 .. leading + frac_str.len];
    var trim = full_frac.len;
    while (trim > 0 and full_frac[trim - 1] == '0') trim -= 1;
    const sign: []const u8 = if (neg) "-" else "";
    if (trim == 0) return std.fmt.allocPrint(alloc, "{s}{d}", .{ sign, int_part });
    return std.fmt.allocPrint(alloc, "{s}{d}.{s}", .{ sign, int_part, full_frac[0..trim] });
}

fn renderValue(v: messages.TypedValue, alloc: std.mem.Allocator) ![]u8 {
    return switch (v) {
        .null_val => alloc.dupe(u8, "NULL"),
        .bool_val => |b| std.fmt.allocPrint(alloc, "{}", .{b}),
        .int8 => |n| std.fmt.allocPrint(alloc, "{d}", .{n}),
        .int16 => |n| std.fmt.allocPrint(alloc, "{d}", .{n}),
        .int32 => |n| std.fmt.allocPrint(alloc, "{d}", .{n}),
        .int64 => |n| std.fmt.allocPrint(alloc, "{d}", .{n}),
        .uint8 => |n| std.fmt.allocPrint(alloc, "{d}", .{n}),
        .uint16 => |n| std.fmt.allocPrint(alloc, "{d}", .{n}),
        .uint32 => |n| std.fmt.allocPrint(alloc, "{d}", .{n}),
        .uint64 => |n| std.fmt.allocPrint(alloc, "{d}", .{n}),
        .float32 => |f| std.fmt.allocPrint(alloc, "{d}", .{f}),
        .float64 => |f| std.fmt.allocPrint(alloc, "{d}", .{f}),
        .decimal => |d| renderDecimal(d, alloc),
        .string => |s| alloc.dupe(u8, s),
        .bytes => |b| std.fmt.allocPrint(alloc, "<bytes:{d}>", .{b.len}),
        .timestamp => |t| std.fmt.allocPrint(alloc, "{d}", .{t}),
        .json => |j| alloc.dupe(u8, j),
        else => alloc.dupe(u8, "?"),
    };
}

fn printTable(rs: *client_mod.ResultSet, alloc: std.mem.Allocator, out: *Out) !void {
    const ncols = rs.columns.len;
    const nrows = rs.rows.len;

    // Render all cell strings and compute column widths.
    const widths = try alloc.alloc(usize, ncols);
    defer alloc.free(widths);
    for (rs.columns, 0..) |col, i| widths[i] = col.name.len;

    const cells = try alloc.alloc([]u8, nrows * ncols);
    defer {
        for (cells) |c| alloc.free(c);
        alloc.free(cells);
    }
    for (rs.rows, 0..) |row, r| {
        for (row, 0..) |val, c| {
            const s = try renderValue(val, alloc);
            cells[r * ncols + c] = s;
            if (s.len > widths[c]) widths[c] = s.len;
        }
    }

    // Header row.
    for (rs.columns, 0..) |col, i| {
        if (i > 0) try out.print(" | ", .{});
        try out.print("{s}", .{col.name});
        for (0..widths[i] - col.name.len) |_| try out.print(" ", .{});
    }
    try out.print("\n", .{});

    // Separator.
    for (widths, 0..) |w, i| {
        if (i > 0) try out.print("-+-", .{});
        for (0..w) |_| try out.print("-", .{});
    }
    try out.print("\n", .{});

    // Data rows.
    for (0..nrows) |r| {
        for (0..ncols) |c| {
            if (c > 0) try out.print(" | ", .{});
            const s = cells[r * ncols + c];
            try out.print("{s}", .{s});
            for (0..widths[c] - s.len) |_| try out.print(" ", .{});
        }
        try out.print("\n", .{});
    }
    try out.print("({d} row(s))\n", .{nrows});
}

// ---- Dispatch ----

const QueryHash = [32]u8;

fn hashShort(hash: QueryHash, buf: *[16]u8) []u8 {
    for (hash[0..8], 0..) |b, i| {
        _ = std.fmt.bufPrint(buf[i * 2 .. i * 2 + 2], "{x:0>2}", .{b}) catch {};
    }
    return buf[0..16];
}

fn hashFull(hash: QueryHash, buf: *[64]u8) []u8 {
    for (hash, 0..) |b, i| {
        _ = std.fmt.bufPrint(buf[i * 2 .. i * 2 + 2], "{x:0>2}", .{b}) catch {};
    }
    return buf[0..64];
}

fn dispatch(
    c: *client_mod.Client,
    sql_with_semi: []const u8,
    hashes: *std.ArrayListUnmanaged(QueryHash),
    session_sql: *std.StringHashMapUnmanaged([]u8),
    alloc: std.mem.Allocator,
    out: *Out,
) !void {
    assert(sql_with_semi.len > 0);
    const sql = std.mem.trimEnd(u8, std.mem.trimEnd(u8, sql_with_semi, " \t\r\n"), ";");
    const kind = classify(sql);

    const hash = c.register(sql) catch |e| {
        if (isConnError(e)) return e;
        const msg = c.last_error_msg();
        if (msg.len > 0) try out.print("error: register failed: {s}\n", .{msg}) else try out.print("error: register failed: {}\n", .{e});
        return;
    };
    try hashes.append(alloc, hash);

    // Record hash → SQL text for \hashes and \lookup.
    {
        var full_buf: [64]u8 = undefined;
        const full = hashFull(hash, &full_buf);
        const gop = try session_sql.getOrPut(alloc, full);
        if (!gop.found_existing) {
            gop.key_ptr.* = try alloc.dupe(u8, full);
            gop.value_ptr.* = try alloc.dupe(u8, sql);
        }
    }

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
            printTable(&rs, alloc, out) catch |err| std.log.warn("printTable: {}", .{err});
        },
        .unknown => {
            // Parameterized query (e.g. TRANSACTION block) — cannot auto-execute.
            var full_buf: [64]u8 = undefined;
            const full = hashFull(hash, &full_buf);
            try out.print("registered: {s}\n", .{full});
            try out.print("  use: \\call {s} (val, ...)\n", .{full});
        },
    }
}

// ---- \call support ----

/// Parse a parenthesised comma-separated literal value list, e.g. (1, 'hello', true, null).
/// Caller owns the returned slice.
fn parseCallParams(text: []const u8, alloc: std.mem.Allocator) ![]messages.TypedValue {
    const s = std.mem.trim(u8, text, " \t");
    if (s.len < 2 or s[0] != '(') return error.MissingParens;
    const inner_end = std.mem.lastIndexOfScalar(u8, s, ')') orelse return error.MissingParens;
    const inner = std.mem.trim(u8, s[1..inner_end], " \t");

    var params: std.ArrayListUnmanaged(messages.TypedValue) = .empty;
    errdefer params.deinit(alloc);

    if (inner.len == 0) return params.toOwnedSlice(alloc);

    var i: usize = 0;
    while (i <= inner.len) {
        // Skip whitespace.
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t')) i += 1;
        if (i >= inner.len) break;

        // Find end of this value (comma or end, respecting string quotes).
        const val_start = i;
        if (inner[i] == '\'') {
            // Quoted string: scan to closing quote (handle '' escapes).
            i += 1;
            while (i < inner.len) {
                if (inner[i] == '\'') {
                    i += 1;
                    if (i < inner.len and inner[i] == '\'') { i += 1; continue; } // escaped ''
                    break;
                }
                i += 1;
            }
        } else {
            while (i < inner.len and inner[i] != ',') i += 1;
        }
        const raw = std.mem.trim(u8, inner[val_start..i], " \t");
        const val = try parseLiteralValue(raw, alloc);
        try params.append(alloc, val);

        // Skip comma.
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t' or inner[i] == ',')) {
            if (inner[i] == ',') { i += 1; break; }
            i += 1;
        }
    }
    return params.toOwnedSlice(alloc);
}

fn parseLiteralValue(raw: []const u8, alloc: std.mem.Allocator) !messages.TypedValue {
    if (std.ascii.eqlIgnoreCase(raw, "null")) return .null_val;
    if (std.ascii.eqlIgnoreCase(raw, "true")) return .{ .bool_val = true };
    if (std.ascii.eqlIgnoreCase(raw, "false")) return .{ .bool_val = false };
    if (raw.len >= 2 and raw[0] == '\'') {
        // Strip quotes and unescape ''.
        const inner = raw[1 .. raw.len - 1];
        var buf = try alloc.alloc(u8, inner.len);
        var wi: usize = 0;
        var ri: usize = 0;
        while (ri < inner.len) {
            if (inner[ri] == '\'' and ri + 1 < inner.len and inner[ri + 1] == '\'') {
                buf[wi] = '\'';
                wi += 1;
                ri += 2;
            } else {
                buf[wi] = inner[ri];
                wi += 1;
                ri += 1;
            }
        }
        return .{ .string = buf[0..wi] };
    }
    // Try integer.
    if (std.fmt.parseInt(i64, raw, 10)) |n| return .{ .int64 = n } else |_| {}
    // Try float.
    if (std.fmt.parseFloat(f64, raw)) |f| return .{ .float64 = f } else |_| {}
    return error.UnrecognisedLiteral;
}

fn isConnError(e: anyerror) bool {
    return e == error.ConnectionClosed or e == error.ReadError or
        e == error.WriteError or e == error.ConnectError;
}

fn tryReconnect(
    io: std.Io,
    host: []const u8,
    port: u16,
    database_name: []const u8,
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
        const rc = client_mod.connect(io, host, port, database_name, alloc) catch continue;
        out.print("reconnected\n", .{}) catch {};
        return rc;
    }
    out.print("error: could not reconnect after {d} attempts\n", .{max_attempts}) catch {};
    return null;
}

// ---- Main ----

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    var out = Out{ .buf = undefined };

    var host: []const u8 = "127.0.0.1";
    var port: u16 = 7432;
    var database: []const u8 = "";

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host")) {
            if (it.next()) |val| host = val;
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (it.next()) |val| port = std.fmt.parseInt(u16, val, 10) catch 7432;
        } else if (std.mem.eql(u8, arg, "--database") or std.mem.eql(u8, arg, "-d")) {
            if (it.next()) |val| database = val;
        }
    }

    var c = client_mod.connect(io, host, port, database, alloc) catch |e| {
        try out.print("error: could not connect to {s}:{d}: {}\n", .{ host, port, e });
        return;
    };

    // SAFETY: ioctl fills ws before its fields are used; if ioctl fails, is_tty is false and ws is not read.
    var ws: std.posix.winsize = undefined;
    const is_tty = @as(isize, @bitCast(std.os.linux.ioctl(0, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws)))) >= 0;
    const orig_termios: ?std.posix.termios = if (is_tty) rawEnter() catch null else null;
    defer if (orig_termios) |orig| rawLeave(orig);

    var history: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (history.items) |h| alloc.free(h);
        history.deinit(alloc);
    }

    var session_hashes: std.ArrayListUnmanaged(QueryHash) = .empty;
    defer session_hashes.deinit(alloc);

    var session_sql: std.StringHashMapUnmanaged([]u8) = .empty;
    defer {
        var sql_it = session_sql.iterator();
        while (sql_it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        session_sql.deinit(alloc);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    // Track current database name locally for the prompt. Starts with "--database" value or "default".
    var current_db_name: []u8 = try alloc.dupe(u8, if (database.len > 0) database else "default");
    defer alloc.free(current_db_name);

    var prompt_buf: [64]u8 = undefined;

    while (true) {
        const prompt = if (buf.items.len == 0)
            std.fmt.bufPrint(&prompt_buf, "foldb[{s}]> ", .{current_db_name}) catch "foldb> "
        else
            "      ...> ";

        const term_cols: u32 = if (is_tty and ws.col > 0) @intCast(ws.col) else 80;
        const line_or_null: ?[]u8 = if (is_tty and orig_termios != null)
            readLineRaw(prompt, history.items, term_cols, alloc) catch |e| {
                if (e == error.Interrupted) {
                    buf.clearRetainingCapacity();
                    continue;
                }
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
                historyPush(&history, sql, alloc) catch |err| std.log.warn("historyPush: {}", .{err});
                dispatch(&c, sql, &session_hashes, &session_sql, alloc, &out) catch |e| try out.print("error: {}\n", .{e});
                continue;
            }
        }

        if (std.mem.startsWith(u8, trimmed, "\\c ")) {
            const db_name = std.mem.trim(u8, trimmed[3..], " \t");
            if (db_name.len > 0) {
                const use_sql = try std.fmt.allocPrint(alloc, "USE DATABASE {s}", .{db_name});
                defer alloc.free(use_sql);
                const hash = c.register(use_sql) catch |e| {
                    if (isConnError(e)) return e;
                    const err_msg = c.last_error_msg();
                    if (err_msg.len > 0) try out.print("error: {s}\n", .{err_msg}) else try out.print("error: {}\n", .{e});
                    continue;
                };
                _ = c.execute(hash, &.{}) catch |e| {
                    if (isConnError(e)) return e;
                    const err_msg = c.last_error_msg();
                    if (err_msg.len > 0) try out.print("error: {s}\n", .{err_msg}) else try out.print("error: {}\n", .{e});
                    continue;
                };
                alloc.free(current_db_name);
                current_db_name = try alloc.dupe(u8, db_name);
                try out.print("You are now connected to database \"{s}\".\n", .{current_db_name});
            }
            continue;
        }

        if (std.mem.eql(u8, trimmed, "\\hashes")) {
            historyPush(&history, trimmed, alloc) catch |err| std.log.warn("historyPush: {}", .{err});
            if (session_sql.count() == 0) {
                try out.print("(no transactions registered this session)\n", .{});
            } else {
                var hash_it = session_sql.iterator();
                while (hash_it.next()) |entry| {
                    try out.print("{s}\n  {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                }
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "\\lookup ")) {
            historyPush(&history, trimmed, alloc) catch |err| std.log.warn("historyPush: {}", .{err});
            const hex_str = std.mem.trim(u8, trimmed[8..], " \t");
            if (hex_str.len != 64) {
                try out.print("error: expected 64-character hex hash\n", .{});
                continue;
            }
            if (session_sql.get(hex_str)) |sql_text| {
                try out.print("{s}\n", .{sql_text});
                continue;
            }
            // Not in session — ask the server.
            const describe_sql = try std.fmt.allocPrint(alloc, "DESCRIBE TRANSACTION '{s}';", .{hex_str});
            defer alloc.free(describe_sql);
            dispatch(&c, describe_sql, &session_hashes, &session_sql, alloc, &out) catch |e| try out.print("error: {}\n", .{e});
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "\\call ")) {
            historyPush(&history, trimmed, alloc) catch |err| std.log.warn("historyPush: {}", .{err});
            const rest = std.mem.trimStart(u8, trimmed[6..], " \t");
            // Require full 64-char hex hash.
            var hex_end: usize = 0;
            while (hex_end < rest.len and rest[hex_end] != ' ' and rest[hex_end] != '(') hex_end += 1;
            const hex_str = rest[0..hex_end];
            if (hex_str.len != 64) {
                try out.print("error: expected full 64-character hex hash (got {d} chars)\n", .{hex_str.len});
                continue;
            }
            var hash: QueryHash = undefined;
            _ = std.fmt.hexToBytes(&hash, hex_str) catch {
                try out.print("error: invalid hex hash\n", .{});
                continue;
            };
            // Parse value list.
            const param_text = std.mem.trimStart(u8, rest[hex_end..], " \t");
            const params = parseCallParams(param_text, alloc) catch |e| {
                try out.print("error: bad params: {}\n", .{e});
                continue;
            };
            defer {
                for (params) |p| if (p == .string) alloc.free(p.string);
                alloc.free(params);
            }
            // Try as DML/transaction first; if result has rows fall back to query display.
            const result = c.execute(hash, params) catch |e| {
                if (isConnError(e)) return e;
                const msg = c.last_error_msg();
                if (msg.len > 0) try out.print("error: {s}\n", .{msg}) else try out.print("error: {}\n", .{e});
                continue;
            };
            if (result.rows_affected > 0) {
                try out.print("{d} row(s) affected\n", .{result.rows_affected});
            } else {
                try out.print("OK\n", .{});
            }
            continue;
        }

        if (buf.items.len > 0) try buf.append(alloc, ' ');
        try buf.appendSlice(alloc, trimmed);

        if (std.mem.endsWith(u8, buf.items, ";")) {
            if (buf.items.len > 1) historyPush(&history, buf.items, alloc) catch |err| std.log.warn("historyPush: {}", .{err});

            var disconnected = false;
            dispatch(&c, buf.items, &session_hashes, &session_sql, alloc, &out) catch |e| {
                if (!isConnError(e)) {
                    try out.print("error: {}\n", .{e});
                } else {
                    try out.print("connection lost\n", .{});
                    c.deinit();
                    if (tryReconnect(io, host, port, current_db_name, alloc, &out)) |new_c| {
                        c = new_c;
                        dispatch(&c, buf.items, &session_hashes, &session_sql, alloc, &out) catch |err| std.log.warn("dispatch on reconnect: {}", .{err});
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
