/// Minimal JSON path extractor for index maintenance.
/// Supports simple dot-paths: $.field or $.a.b (no wildcards, no arrays).
const std = @import("std");

pub const JsonPathError = error{ InvalidPath, InvalidJson, OutOfMemory };

/// Parse "$.a.b" into segments ["a", "b"]. Caller owns the slice.
pub fn parseSegments(path: []const u8, alloc: std.mem.Allocator) ![]const []const u8 {
    if (!std.mem.startsWith(u8, path, "$.")) return error.InvalidPath;
    const rest = path[2..];
    if (rest.len == 0) return &.{};

    var segments: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer segments.deinit(alloc);

    var it = std.mem.splitScalar(u8, rest, '.');
    while (it.next()) |seg| {
        if (seg.len == 0) return error.InvalidPath;
        try segments.append(alloc, seg);
    }
    return segments.toOwnedSlice(alloc);
}

/// Extract the value at path from JSON bytes. Returns allocated bytes or null.
/// The returned bytes are the raw JSON value (with quotes for strings).
pub fn extract(json: []const u8, path: []const u8, alloc: std.mem.Allocator) !?[]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const segments = try parseSegments(path, arena.allocator());
    return extractSegments(json, segments, alloc);
}

fn extractSegments(json: []const u8, segments: []const []const u8, alloc: std.mem.Allocator) !?[]u8 {
    if (segments.len == 0) return try alloc.dupe(u8, json);
    const value_raw = (try findObjectField(json, segments[0])) orelse return null;
    return extractSegments(value_raw, segments[1..], alloc);
}

/// Find the raw value bytes for a named field in a JSON object.
fn findObjectField(json: []const u8, field: []const u8) !?[]const u8 {
    var pos: usize = 0;
    skipWs(json, &pos);
    if (pos >= json.len or json[pos] != '{') return null;
    pos += 1;

    while (true) {
        skipWs(json, &pos);
        if (pos >= json.len) return null;
        if (json[pos] == '}') return null;

        const key = scanString(json, &pos) catch return null;

        skipWs(json, &pos);
        if (pos >= json.len or json[pos] != ':') return null;
        pos += 1;
        skipWs(json, &pos);

        const val_start = pos;
        scanValue(json, &pos) catch return null;
        const val_end = pos;

        if (std.mem.eql(u8, key, field)) {
            return json[val_start..val_end];
        }

        skipWs(json, &pos);
        if (pos < json.len and json[pos] == ',') {
            pos += 1;
        } else {
            break;
        }
    }
    return null;
}

fn skipWs(data: []const u8, pos: *usize) void {
    while (pos.* < data.len) {
        switch (data[pos.*]) {
            ' ', '\t', '\n', '\r' => pos.* += 1,
            else => break,
        }
    }
}

/// Scan over a JSON string, returning the content between quotes (no allocation).
fn scanString(data: []const u8, pos: *usize) ![]const u8 {
    if (pos.* >= data.len or data[pos.*] != '"') return error.InvalidJson;
    pos.* += 1;
    const start = pos.*;
    while (pos.* < data.len) {
        if (data[pos.*] == '\\') {
            pos.* += 2;
        } else if (data[pos.*] == '"') {
            const content = data[start..pos.*];
            pos.* += 1;
            return content;
        } else {
            pos.* += 1;
        }
    }
    return error.InvalidJson;
}

/// Scan over a JSON value of any type, advancing pos past it.
fn scanValue(data: []const u8, pos: *usize) !void {
    if (pos.* >= data.len) return error.InvalidJson;
    switch (data[pos.*]) {
        '"' => _ = try scanString(data, pos),
        '{' => {
            pos.* += 1;
            var first = true;
            while (true) {
                skipWs(data, pos);
                if (pos.* >= data.len) return error.InvalidJson;
                if (data[pos.*] == '}') {
                    pos.* += 1;
                    return;
                }
                if (!first) {
                    if (data[pos.*] != ',') return error.InvalidJson;
                    pos.* += 1;
                    skipWs(data, pos);
                }
                first = false;
                _ = try scanString(data, pos);
                skipWs(data, pos);
                if (pos.* >= data.len or data[pos.*] != ':') return error.InvalidJson;
                pos.* += 1;
                skipWs(data, pos);
                try scanValue(data, pos);
            }
        },
        '[' => {
            pos.* += 1;
            var first = true;
            while (true) {
                skipWs(data, pos);
                if (pos.* >= data.len) return error.InvalidJson;
                if (data[pos.*] == ']') {
                    pos.* += 1;
                    return;
                }
                if (!first) {
                    if (data[pos.*] != ',') return error.InvalidJson;
                    pos.* += 1;
                    skipWs(data, pos);
                }
                first = false;
                try scanValue(data, pos);
            }
        },
        't' => {
            if (pos.* + 4 > data.len or !std.mem.eql(u8, data[pos.*..][0..4], "true")) return error.InvalidJson;
            pos.* += 4;
        },
        'f' => {
            if (pos.* + 5 > data.len or !std.mem.eql(u8, data[pos.*..][0..5], "false")) return error.InvalidJson;
            pos.* += 5;
        },
        'n' => {
            if (pos.* + 4 > data.len or !std.mem.eql(u8, data[pos.*..][0..4], "null")) return error.InvalidJson;
            pos.* += 4;
        },
        '-', '0'...'9' => {
            if (data[pos.*] == '-') pos.* += 1;
            while (pos.* < data.len and data[pos.*] >= '0' and data[pos.*] <= '9') pos.* += 1;
            if (pos.* < data.len and data[pos.*] == '.') {
                pos.* += 1;
                while (pos.* < data.len and data[pos.*] >= '0' and data[pos.*] <= '9') pos.* += 1;
            }
            if (pos.* < data.len and (data[pos.*] == 'e' or data[pos.*] == 'E')) {
                pos.* += 1;
                if (pos.* < data.len and (data[pos.*] == '+' or data[pos.*] == '-')) pos.* += 1;
                while (pos.* < data.len and data[pos.*] >= '0' and data[pos.*] <= '9') pos.* += 1;
            }
        },
        else => return error.InvalidJson,
    }
}

/// Normalize a JSON value for use as an index key.
/// Strings: content without quotes. Numbers/booleans/null: raw bytes.
pub fn normalizeValue(json_value: []const u8, alloc: std.mem.Allocator) ![]u8 {
    const trimmed = std.mem.trim(u8, json_value, " \t\n\r");
    if (trimmed.len > 0 and trimmed[0] == '"') {
        var pos: usize = 0;
        const content = try scanString(trimmed, &pos);
        return alloc.dupe(u8, content);
    }
    return alloc.dupe(u8, trimmed);
}
