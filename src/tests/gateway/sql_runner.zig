/// SQL test file runner: parses SQL test files and runs them through the Gateway.
///
/// File format:
///   - Regular SQL terminated by `;`
///   - `--` comment lines are ignored unless they start with `-- @`
///   - `-- @rows N`    after DML: expect N rows affected
///   - `-- @error TEXT` after any statement: expect error containing TEXT (case-insensitive)
///   - `-- @result`    after SELECT: starts result block
///   - `-- @  val | val` lines: expected rows (after `-- @result`)
///   - `-- @call (v1, v2, ...)` after TRANSACTION registration: call with those params
///   - `-- @ok`        just expect success (default)
const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");

const Gateway = gateway_mod.Gateway;
const ColumnValue = gateway_mod.ColumnValue;
const QueryHash = gateway_mod.QueryHash;

// ---- Temp dir helpers (same pattern as on_conflict_test.zig) ----

fn makeTempDir(alloc: std.mem.Allocator) ![]const u8 {
    // SAFETY: clock_gettime fills ts before any field is read.
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(alloc, "/tmp/sql_runner_{d}", .{ns});
}

fn removeDirRecursive(path: []const u8) void {
    const z = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(z);
    @memcpy(z[0..path.len], path);
    const raw_fd = std.os.linux.open(z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return;
    const fd: std.posix.fd_t = @intCast(fd_i);
    defer _ = std.os.linux.close(@intCast(fd));
    var buf: [4096]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    while (true) {
        const ret = std.os.linux.getdents64(@intCast(fd), &buf, buf.len);
        const n: isize = @bitCast(ret);
        if (n <= 0) break;
        var i: usize = 0;
        while (i < @as(usize, @intCast(n))) {
            const dent: *const std.os.linux.dirent64 = @ptrCast(@alignCast(buf[i..].ptr));
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&dent.name)));
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                const child = std.mem.concat(std.heap.page_allocator, u8, &.{ path, "/", name }) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(child);
                const cz = std.heap.page_allocator.allocSentinel(u8, child.len, 0) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(cz);
                @memcpy(cz[0..child.len], child);
                if (dent.type == std.os.linux.DT.DIR) removeDirRecursive(child) else _ = std.os.linux.unlink(cz.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}

// ---- Statement classification ----

const StmtKind = enum { ddl, dml, select, txn };

fn classifyStmt(sql: []const u8) StmtKind {
    var i: usize = 0;
    while (i < sql.len and (sql[i] == ' ' or sql[i] == '\t' or sql[i] == '\n' or sql[i] == '\r')) i += 1;
    var end = i;
    while (end < sql.len and sql[end] != ' ' and sql[end] != '\t' and sql[end] != '\n' and sql[end] != '\r' and sql[end] != '(') end += 1;
    const word = sql[i..end];

    var buf: [16]u8 = undefined;
    const lower_len = @min(word.len, buf.len);
    for (word[0..lower_len], 0..) |c, j| buf[j] = std.ascii.toLower(c);
    const lower = buf[0..lower_len];

    if (std.mem.eql(u8, lower, "create") or
        std.mem.eql(u8, lower, "drop") or
        std.mem.eql(u8, lower, "alter")) return .ddl;

    if (std.mem.eql(u8, lower, "insert") or
        std.mem.eql(u8, lower, "update") or
        std.mem.eql(u8, lower, "delete") or
        std.mem.eql(u8, lower, "merge")) return .dml;

    if (std.mem.eql(u8, lower, "select") or
        std.mem.eql(u8, lower, "with") or
        std.mem.eql(u8, lower, "describe")) return .select;

    if (std.mem.eql(u8, lower, "transaction")) return .txn;

    return .dml;
}

// ---- Directive types ----

const Directive = union(enum) {
    rows: u64,
    err: []const u8,
    result: void,
    result_row: []const u8,
    call: []const u8,
    ok: void,
};

fn parseDirective(line: []const u8) ?Directive {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "-- @")) return null;
    const after_at = trimmed[4..]; // skip "-- @"

    // `-- @  val | val` — result row (starts with whitespace after @)
    if (after_at.len > 0 and (after_at[0] == ' ' or after_at[0] == '\t')) {
        return .{ .result_row = std.mem.trim(u8, after_at, " \t") };
    }

    if (std.mem.startsWith(u8, after_at, "rows ")) {
        const num_str = std.mem.trim(u8, after_at[5..], " \t");
        const n = std.fmt.parseInt(u64, num_str, 10) catch return null;
        return .{ .rows = n };
    }

    if (std.mem.startsWith(u8, after_at, "error ")) {
        const text = std.mem.trim(u8, after_at[6..], " \t");
        return .{ .err = text };
    }

    if (std.mem.eql(u8, after_at, "result")) return .{ .result = {} };

    if (std.mem.startsWith(u8, after_at, "call ")) {
        const args = std.mem.trim(u8, after_at[5..], " \t");
        return .{ .call = args };
    }

    if (std.mem.eql(u8, after_at, "ok")) return .{ .ok = {} };

    return null;
}

// ---- Value rendering ----

fn renderValue(val: ?ColumnValue, buf: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    if (val == null) {
        try buf.appendSlice(alloc, "NULL");
        return;
    }
    switch (val.?) {
        .bool_t => |v| try buf.appendSlice(alloc, if (v) "true" else "false"),
        .int8 => |v| try buf.print(alloc, "{d}", .{v}),
        .int16 => |v| try buf.print(alloc, "{d}", .{v}),
        .int32 => |v| try buf.print(alloc, "{d}", .{v}),
        .int64 => |v| try buf.print(alloc, "{d}", .{v}),
        .uint8 => |v| try buf.print(alloc, "{d}", .{v}),
        .uint16 => |v| try buf.print(alloc, "{d}", .{v}),
        .uint32 => |v| try buf.print(alloc, "{d}", .{v}),
        .uint64 => |v| try buf.print(alloc, "{d}", .{v}),
        .string => |v| try buf.appendSlice(alloc, v),
        .bytes => |v| try buf.print(alloc, "<bytes:{d}>", .{v.len}),
        .decimal => |v| {
            if (v.scale == 0) {
                try buf.print(alloc, "{d}", .{v.coefficient});
            } else {
                var scale_div: i128 = 1;
                var s: u8 = 0;
                while (s < v.scale) : (s += 1) scale_div *= 10;
                const integer_part = @divTrunc(v.coefficient, scale_div);
                const frac_part = @mod(v.coefficient, scale_div);
                const abs_frac = if (frac_part < 0) -frac_part else frac_part;
                try buf.print(alloc, "{d}.{d}", .{ integer_part, abs_frac });
            }
        },
        .null_t => try buf.appendSlice(alloc, "NULL"),
    }
}

fn renderRow(row: []const ?ColumnValue, alloc: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (row, 0..) |val, i| {
        if (i > 0) try buf.appendSlice(alloc, " | ");
        try renderValue(val, &buf, alloc);
    }
    return buf.toOwnedSlice(alloc);
}

// ---- Param parsing for @call ----

fn parseCallParams(args_str: []const u8, alloc: std.mem.Allocator) ![]ColumnValue {
    const trimmed = std.mem.trim(u8, args_str, " \t");
    if (trimmed.len < 2 or trimmed[0] != '(' or trimmed[trimmed.len - 1] != ')') {
        return error.InvalidCallParams;
    }
    const inner = trimmed[1 .. trimmed.len - 1];

    var params: std.ArrayList(ColumnValue) = .empty;
    errdefer params.deinit(alloc);

    var i: usize = 0;
    while (i <= inner.len) {
        var in_quote = false;
        var j = i;
        while (j < inner.len) : (j += 1) {
            if (inner[j] == '\'' and !in_quote) { in_quote = true; continue; }
            if (inner[j] == '\'' and in_quote) { in_quote = false; continue; }
            if (inner[j] == ',' and !in_quote) break;
        }
        const token = std.mem.trim(u8, inner[i..j], " \t");
        if (token.len > 0) {
            const cv = try parseCallToken(token);
            try params.append(alloc, cv);
        }
        i = j + 1;
    }

    return params.toOwnedSlice(alloc);
}

fn parseCallToken(token: []const u8) !ColumnValue {
    if (token.len == 0) return error.InvalidToken;
    if (token[0] == '\'' and token[token.len - 1] == '\'') {
        return .{ .string = token[1 .. token.len - 1] };
    }
    if (std.mem.eql(u8, token, "true")) return .{ .bool_t = true };
    if (std.mem.eql(u8, token, "false")) return .{ .bool_t = false };
    const n = std.fmt.parseInt(i64, token, 10) catch return error.InvalidToken;
    return .{ .int64 = n };
}

// ---- Statement structure ----

const Step = struct {
    sql: []const u8,
    kind: StmtKind,
    directives: []Directive,
};

fn parseSteps(sql_text: []const u8, alloc: std.mem.Allocator) ![]Step {
    var steps: std.ArrayList(Step) = .empty;
    errdefer {
        for (steps.items) |s| {
            alloc.free(s.sql);
            alloc.free(s.directives);
        }
        steps.deinit(alloc);
    }

    var line_iter = std.mem.splitScalar(u8, sql_text, '\n');
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    while (line_iter.next()) |line| try lines.append(alloc, line);

    var li: usize = 0;
    while (li < lines.items.len) {
        const line = lines.items[li];
        const trimmed = std.mem.trim(u8, line, " \t\r\n");

        if (trimmed.len == 0) { li += 1; continue; }
        // Skip comments (plain and directives) at the top level.
        if (std.mem.startsWith(u8, trimmed, "--")) { li += 1; continue; }

        // Accumulate SQL until `;` outside strings/braces.
        var stmt_buf: std.ArrayList(u8) = .empty;
        errdefer stmt_buf.deinit(alloc);

        var in_quote = false;
        var brace_depth: u32 = 0;
        var found_semi = false;

        stmt_loop: while (li < lines.items.len) {
            const cur = lines.items[li];
            const cur_trimmed = std.mem.trim(u8, cur, " \t\r\n");

            // Skip comment lines inside a statement.
            if (std.mem.startsWith(u8, cur_trimmed, "--")) {
                li += 1;
                continue;
            }

            if (stmt_buf.items.len > 0) try stmt_buf.append(alloc, '\n');
            try stmt_buf.appendSlice(alloc, cur);
            li += 1;

            for (cur) |c| {
                if (in_quote) {
                    if (c == '\'') in_quote = false;
                    continue;
                }
                switch (c) {
                    '\'' => in_quote = true,
                    '{' => brace_depth += 1,
                    '}' => if (brace_depth > 0) { brace_depth -= 1; },
                    ';' => if (brace_depth == 0) {
                        found_semi = true;
                        break :stmt_loop;
                    },
                    else => {},
                }
            }
        }

        if (!found_semi and std.mem.trim(u8, stmt_buf.items, " \t\r\n").len == 0) {
            stmt_buf.deinit(alloc);
            continue;
        }

        const sql_raw = try stmt_buf.toOwnedSlice(alloc);

        // Strip trailing semicolons and whitespace.
        var sql_end = sql_raw.len;
        while (sql_end > 0) {
            const c = sql_raw[sql_end - 1];
            if (c == ';' or c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                sql_end -= 1;
            } else break;
        }
        const sql = try alloc.realloc(sql_raw, sql_end);

        const kind = classifyStmt(sql);

        // Collect directives after this statement.
        var directives: std.ArrayList(Directive) = .empty;
        errdefer directives.deinit(alloc);

        while (li < lines.items.len) {
            const dl = lines.items[li];
            const dt = std.mem.trim(u8, dl, " \t\r\n");
            if (dt.len == 0) { li += 1; continue; }
            if (!std.mem.startsWith(u8, dt, "--")) break;
            if (!std.mem.startsWith(u8, dt, "-- @")) break;
            if (parseDirective(dl)) |d| try directives.append(alloc, d);
            li += 1;
        }

        try steps.append(alloc, .{
            .sql = sql,
            .kind = kind,
            .directives = try directives.toOwnedSlice(alloc),
        });
    }

    return steps.toOwnedSlice(alloc);
}

// ---- Error helpers ----

fn errorNameContains(err: anyerror, text: []const u8) bool {
    return containsCaseInsensitive(@errorName(err), text);
}

fn detailContains(gw: *Gateway, text: []const u8) bool {
    return containsCaseInsensitive(gw.lastDetail(), text);
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

// ---- Directive lookup helpers ----

fn findErrDirective(directives: []const Directive) ?[]const u8 {
    for (directives) |d| {
        if (d == .err) return d.err;
    }
    return null;
}

fn findRowsDirective(directives: []const Directive) ?u64 {
    for (directives) |d| {
        if (d == .rows) return d.rows;
    }
    return null;
}

fn collectResultRows(directives: []const Directive, alloc: std.mem.Allocator) ![][]const u8 {
    var rows: std.ArrayList([]const u8) = .empty;
    errdefer rows.deinit(alloc);
    var in_result = false;
    for (directives) |d| {
        switch (d) {
            .result => { in_result = true; },
            .result_row => |row| { if (in_result) try rows.append(alloc, row); },
            else => { if (in_result) break; },
        }
    }
    return rows.toOwnedSlice(alloc);
}

// ---- Main run function ----

pub fn run(sql_text: []const u8, alloc: std.mem.Allocator) !void {
    const dir = try makeTempDir(alloc);
    defer {
        removeDirRecursive(dir);
        alloc.free(dir);
    }

    const gw = try Gateway.init(dir, alloc, .{});
    defer gw.deinit();

    const steps = try parseSteps(sql_text, alloc);
    defer {
        for (steps) |step| {
            alloc.free(step.sql);
            alloc.free(step.directives);
        }
        alloc.free(steps);
    }

    for (steps) |step| {
        try executeStep(gw, step, alloc);
    }
}

fn executeStep(gw: *Gateway, step: Step, alloc: std.mem.Allocator) !void {
    switch (step.kind) {
        .ddl => try executeDdl(gw, step),
        .dml => try executeDml(gw, step),
        .select => try executeSelect(gw, step, alloc),
        .txn => try executeTxn(gw, step, alloc),
    }
}

fn executeDdl(gw: *Gateway, step: Step) !void {
    const expected_error = findErrDirective(step.directives);

    if (expected_error) |text| {
        gw.applyDdl(step.sql) catch |err| {
            if (!errorNameContains(err, text) and !detailContains(gw, text)) {
                std.debug.print("Expected error containing '{s}' but got '{}' (detail: '{s}') for:\n  {s}\n", .{
                    text, err, gw.lastDetail(), step.sql,
                });
                return error.TestWrongError;
            }
            return;
        };
        std.debug.print("Expected error '{s}' from DDL but got success:\n  {s}\n", .{ text, step.sql });
        return error.TestUnexpectedSuccess;
    }

    gw.applyDdl(step.sql) catch |err| {
        std.debug.print("DDL failed with '{}' (detail: '{s}') for:\n  {s}\n", .{ err, gw.lastDetail(), step.sql });
        return err;
    };
}

fn executeDml(gw: *Gateway, step: Step) !void {
    const expected_error = findErrDirective(step.directives);
    const expected_rows = findRowsDirective(step.directives);

    const reg_result = gw.register(step.sql) catch |err| {
        if (expected_error) |text| {
            if (!errorNameContains(err, text) and !detailContains(gw, text)) {
                std.debug.print("Expected error containing '{s}' at register but got '{}' for:\n  {s}\n", .{
                    text, err, step.sql,
                });
                return error.TestWrongError;
            }
            return;
        }
        std.debug.print("DML register failed with '{}' (detail: '{s}') for:\n  {s}\n", .{ err, gw.lastDetail(), step.sql });
        return err;
    };

    if (expected_error) |text| {
        const exec_r = gw.execute(reg_result.hash, &.{}, &.{});
        if (exec_r) |ok| {
            var r = ok;
            if (r.result_set) |*rs| rs.deinit();
            std.debug.print("Expected error '{s}' from DML but got success:\n  {s}\n", .{ text, step.sql });
            return error.TestUnexpectedSuccess;
        } else |err| {
            if (!errorNameContains(err, text) and !detailContains(gw, text)) {
                std.debug.print("Expected error containing '{s}' but got '{}' (detail: '{s}') for:\n  {s}\n", .{
                    text, err, gw.lastDetail(), step.sql,
                });
                return error.TestWrongError;
            }
            return;
        }
    }

    const res = gw.execute(reg_result.hash, &.{}, &.{}) catch |err| {
        std.debug.print("DML execute failed with '{}' (detail: '{s}') for:\n  {s}\n", .{ err, gw.lastDetail(), step.sql });
        return err;
    };
    var result = res;
    if (result.result_set) |*rs| rs.deinit();

    if (expected_rows) |n| {
        if (result.rows_affected != n) {
            std.debug.print("Expected {d} rows affected but got {d} for:\n  {s}\n", .{ n, result.rows_affected, step.sql });
            return error.TestRowsMismatch;
        }
    }
}

fn executeSelect(gw: *Gateway, step: Step, alloc: std.mem.Allocator) !void {
    const expected_error = findErrDirective(step.directives);
    const expected_rows = try collectResultRows(step.directives, alloc);
    defer alloc.free(expected_rows);

    const reg_result = gw.register(step.sql) catch |err| {
        if (expected_error) |text| {
            if (!errorNameContains(err, text) and !detailContains(gw, text)) {
                std.debug.print("Expected error containing '{s}' at register but got '{}' for:\n  {s}\n", .{
                    text, err, step.sql,
                });
                return error.TestWrongError;
            }
            return;
        }
        std.debug.print("SELECT register failed with '{}' (detail: '{s}') for:\n  {s}\n", .{ err, gw.lastDetail(), step.sql });
        return err;
    };

    if (expected_error) |text| {
        const sel_r = gw.querySelect(reg_result.hash, &.{}, &.{});
        if (sel_r) |ok| {
            var mut_rs = ok;
            mut_rs.deinit();
            std.debug.print("Expected error '{s}' from SELECT but got success:\n  {s}\n", .{ text, step.sql });
            return error.TestUnexpectedSuccess;
        } else |err| {
            if (!errorNameContains(err, text) and !detailContains(gw, text)) {
                std.debug.print("Expected error containing '{s}' but got '{}' (detail: '{s}') for:\n  {s}\n", .{
                    text, err, gw.lastDetail(), step.sql,
                });
                return error.TestWrongError;
            }
            return;
        }
    }

    var rs = gw.querySelect(reg_result.hash, &.{}, &.{}) catch |err| {
        std.debug.print("SELECT failed with '{}' (detail: '{s}') for:\n  {s}\n", .{ err, gw.lastDetail(), step.sql });
        return err;
    };
    defer rs.deinit();

    if (expected_rows.len > 0) {
        if (rs.rows.len != expected_rows.len) {
            std.debug.print("Expected {d} rows but got {d} for:\n  {s}\n", .{
                expected_rows.len, rs.rows.len, step.sql,
            });
            return error.TestRowCountMismatch;
        }
        for (expected_rows, rs.rows, 0..) |expected, actual_row, idx| {
            const rendered = try renderRow(actual_row, alloc);
            defer alloc.free(rendered);
            if (!std.mem.eql(u8, std.mem.trim(u8, expected, " \t"), std.mem.trim(u8, rendered, " \t"))) {
                std.debug.print("Row {d} mismatch:\n  expected: '{s}'\n  got:      '{s}'\nfor:\n  {s}\n", .{
                    idx, expected, rendered, step.sql,
                });
                return error.TestResultMismatch;
            }
        }
    }
}

fn executeTxn(gw: *Gateway, step: Step, alloc: std.mem.Allocator) !void {
    const expected_reg_error = findErrDirective(step.directives);

    const reg_result = gw.register(step.sql) catch |err| {
        if (expected_reg_error) |text| {
            if (!errorNameContains(err, text) and !detailContains(gw, text)) {
                std.debug.print("Expected error containing '{s}' at TXN register but got '{}' for:\n  {s}\n", .{
                    text, err, step.sql,
                });
                return error.TestWrongError;
            }
            return;
        }
        std.debug.print("TRANSACTION register failed with '{}' (detail: '{s}') for:\n  {s}\n", .{ err, gw.lastDetail(), step.sql });
        return err;
    };

    // Process @call directives.
    var di: usize = 0;
    while (di < step.directives.len) : (di += 1) {
        const d = step.directives[di];
        if (d != .call) continue;

        const params = try parseCallParams(d.call, alloc);
        defer alloc.free(params);

        // Peek at next directive for outcome check.
        var outcome_rows: ?u64 = null;
        var outcome_error: ?[]const u8 = null;
        if (di + 1 < step.directives.len) {
            switch (step.directives[di + 1]) {
                .rows => |n| { outcome_rows = n; di += 1; },
                .err => |text| { outcome_error = text; di += 1; },
                else => {},
            }
        }

        if (outcome_error) |text| {
            const call_r = gw.execute(reg_result.hash, params, &.{});
            if (call_r) |ok| {
                var r = ok;
                if (r.result_set) |*rs| rs.deinit();
                std.debug.print("Expected error '{s}' from @call but got success:\n  {s}\n", .{ text, step.sql });
                return error.TestUnexpectedSuccess;
            } else |err| {
                if (!errorNameContains(err, text) and !detailContains(gw, text)) {
                    std.debug.print("Expected error containing '{s}' but got '{}' (detail: '{s}') for @call on:\n  {s}\n", .{
                        text, err, gw.lastDetail(), step.sql,
                    });
                    return error.TestWrongError;
                }
                continue;
            }
        }

        const res = gw.execute(reg_result.hash, params, &.{}) catch |err| {
            std.debug.print("@call failed with '{}' (detail: '{s}') for:\n  {s}\n", .{ err, gw.lastDetail(), step.sql });
            return err;
        };
        var result = res;
        if (result.result_set) |*rs| rs.deinit();

        if (outcome_rows) |n| {
            if (result.rows_affected != n) {
                std.debug.print("@call expected {d} rows affected but got {d} for:\n  {s}\n", .{
                    n, result.rows_affected, step.sql,
                });
                return error.TestRowsMismatch;
            }
        }
    }
}
