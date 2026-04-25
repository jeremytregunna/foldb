/// Per-column codecs for PAX blocks: Raw, RLE, Dictionary, Frame-of-Reference.
const std = @import("std");
const types = @import("types.zig");
const ColumnValue = types.ColumnValue;
const ColumnType = types.ColumnType;

pub const CodecId = enum(u8) {
    raw = 0,
    rle = 1,
    dict = 2,
    for_ = 3,
};

// --- Codec selection heuristic ---

pub fn chooseCodec(col_type: ColumnType, values: []const ColumnValue) CodecId {
    if (values.len == 0) return .raw;

    // RLE: at least 50% of adjacent pairs are equal (beats FOR)
    if (values.len > 1) {
        var equal_pairs: usize = 0;
        for (1..values.len) |i| {
            if (values[i].eql(values[i - 1])) equal_pairs += 1;
        }
        if (equal_pairs * 2 >= values.len - 1) return .rle;
    }

    // Integer types: FOR if range fits u16, else raw (skip Dict)
    if (intMinMax(col_type, values)) |range| {
        if (range[1] -% range[0] <= 65535) return .for_;
        return .raw;
    }

    // Non-integer types: Dict if cardinality ≤ 256
    var distinct: usize = 0;
    var seen: [256]ColumnValue = undefined;
    outer: for (values) |v| {
        var found = false;
        for (seen[0..distinct]) |s| {
            if (s.eql(v)) {
                found = true;
                break;
            }
        }
        if (!found) {
            if (distinct >= 256) {
                distinct = 257;
                break :outer;
            }
            seen[distinct] = v;
            distinct += 1;
        }
    }
    if (distinct <= 256) return .dict;

    return .raw;
}

fn intMinMax(col_type: ColumnType, values: []const ColumnValue) ?[2]u64 {
    if (values.len == 0) return null;
    return switch (col_type) {
        .int8, .int16, .int32, .int64, .uint8, .uint16, .uint32, .uint64 => blk: {
            var mn = valueToU64(values[0]);
            var mx = valueToU64(values[0]);
            for (values[1..]) |v| {
                const u = valueToU64(v);
                if (u < mn) mn = u;
                if (u > mx) mx = u;
            }
            break :blk .{ mn, mx };
        },
        else => null,
    };
}

fn valueToU64(v: ColumnValue) u64 {
    return switch (v) {
        .int8 => |x| @bitCast(@as(i64, x)),
        .int16 => |x| @bitCast(@as(i64, x)),
        .int32 => |x| @bitCast(@as(i64, x)),
        .int64 => |x| @bitCast(x),
        .uint8 => |x| x,
        .uint16 => |x| x,
        .uint32 => |x| x,
        .uint64 => |x| x,
        else => 0,
    };
}

fn u64ToValue(u: u64, col_type: ColumnType) ColumnValue {
    return switch (col_type) {
        .int8 => .{ .int8 = @intCast(@as(i64, @bitCast(u))) },
        .int16 => .{ .int16 = @intCast(@as(i64, @bitCast(u))) },
        .int32 => .{ .int32 = @intCast(@as(i64, @bitCast(u))) },
        .int64 => .{ .int64 = @bitCast(u) },
        .uint8 => .{ .uint8 = @intCast(u) },
        .uint16 => .{ .uint16 = @intCast(u) },
        .uint32 => .{ .uint32 = @intCast(u) },
        .uint64 => .{ .uint64 = u },
        else => unreachable,
    };
}

// --- Unified encode / decode ---

pub fn encode(
    codec: CodecId,
    col_type: ColumnType,
    values: []const ColumnValue,
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
) !void {
    switch (codec) {
        .raw => try encodeRaw(col_type, values, out, alloc),
        .rle => try encodeRle(col_type, values, out, alloc),
        .dict => try encodeDict(col_type, values, out, alloc),
        .for_ => try encodeFor(col_type, values, out, alloc),
    }
}

pub fn decode(
    codec: CodecId,
    col_type: ColumnType,
    data: []const u8,
    count: u32,
    out: []ColumnValue,
    alloc: std.mem.Allocator,
) !void {
    switch (codec) {
        .raw => try decodeRaw(col_type, data, count, out, alloc),
        .rle => try decodeRle(col_type, data, count, out, alloc),
        .dict => try decodeDict(col_type, data, count, out, alloc),
        .for_ => try decodeFor(col_type, data, count, out),
    }
}

// --- Raw codec ---

fn encodeRaw(col_type: ColumnType, values: []const ColumnValue, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    for (values) |v| try writeValue(col_type, v, out, alloc);
}

fn decodeRaw(col_type: ColumnType, data: []const u8, count: u32, out: []ColumnValue, alloc: std.mem.Allocator) !void {
    var pos: usize = 0;
    for (0..count) |i| {
        const result = try readValue(col_type, data[pos..], alloc);
        out[i] = result.value;
        pos += result.bytes_read;
    }
}

// --- RLE codec ---
// Format: (run_length: u16, value_bytes)+

fn encodeRle(col_type: ColumnType, values: []const ColumnValue, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    if (values.len == 0) return;
    var run_start: usize = 0;
    var run_val = values[0];
    for (1..values.len) |i| {
        if (!values[i].eql(run_val) or i - run_start >= 65535) {
            try writeRun(col_type, @intCast(i - run_start), run_val, out, alloc);
            run_start = i;
            run_val = values[i];
        }
    }
    try writeRun(col_type, @intCast(values.len - run_start), run_val, out, alloc);
}

fn writeRun(col_type: ColumnType, count: u16, val: ColumnValue, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, count, .little);
    try out.appendSlice(alloc, &buf);
    try writeValue(col_type, val, out, alloc);
}

fn decodeRle(col_type: ColumnType, data: []const u8, count: u32, out: []ColumnValue, alloc: std.mem.Allocator) !void {
    var pos: usize = 0;
    var written: u32 = 0;
    while (written < count) {
        if (pos + 2 > data.len) return error.InvalidData;
        const run_len = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;
        const result = try readValue(col_type, data[pos..], alloc);
        const val = result.value;
        pos += result.bytes_read;
        for (0..run_len) |_| {
            if (written >= count) return error.InvalidData;
            out[written] = try val.dupe(alloc);
            written += 1;
        }
        val.freeIfOwned(alloc);
    }
}

// --- Dictionary codec ---
// Format: dict_size: u16, dict_entries (raw values), indices: [count]u8

fn encodeDict(col_type: ColumnType, values: []const ColumnValue, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    var dict: std.ArrayList(ColumnValue) = .empty;
    defer dict.deinit(alloc);
    var indices: std.ArrayList(u8) = .empty;
    defer indices.deinit(alloc);

    for (values) |v| {
        var idx: u8 = 0;
        var found = false;
        for (dict.items, 0..) |d, di| {
            if (d.eql(v)) {
                idx = @intCast(di);
                found = true;
                break;
            }
        }
        if (!found) {
            idx = @intCast(dict.items.len);
            try dict.append(alloc, v);
        }
        try indices.append(alloc, idx);
    }

    var size_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &size_buf, @intCast(dict.items.len), .little);
    try out.appendSlice(alloc, &size_buf);
    for (dict.items) |d| try writeValue(col_type, d, out, alloc);
    try out.appendSlice(alloc, indices.items);
}

fn decodeDict(col_type: ColumnType, data: []const u8, count: u32, out: []ColumnValue, alloc: std.mem.Allocator) !void {
    if (data.len < 2) return error.InvalidData;
    const dict_size = std.mem.readInt(u16, data[0..2], .little);
    var pos: usize = 2;

    const dict = try alloc.alloc(ColumnValue, dict_size);
    defer {
        for (dict) |d| d.freeIfOwned(alloc);
        alloc.free(dict);
    }

    for (0..dict_size) |i| {
        const result = try readValue(col_type, data[pos..], alloc);
        dict[i] = result.value;
        pos += result.bytes_read;
    }

    if (pos + count > data.len) return error.InvalidData;
    for (0..count) |i| {
        const idx = data[pos + i];
        if (idx >= dict_size) return error.InvalidData;
        out[i] = try dict[idx].dupe(alloc);
    }
}

// --- Frame-of-Reference codec ---
// Format: base: u64, deltas: [count]u16

fn encodeFor(col_type: ColumnType, values: []const ColumnValue, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    const range = intMinMax(col_type, values) orelse return error.InvalidType;
    const base = range[0];

    var base_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &base_buf, base, .little);
    try out.appendSlice(alloc, &base_buf);

    for (values) |v| {
        const delta: u16 = @intCast(valueToU64(v) -% base);
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, delta, .little);
        try out.appendSlice(alloc, &buf);
    }
}

fn decodeFor(col_type: ColumnType, data: []const u8, count: u32, out: []ColumnValue) !void {
    if (data.len < 8) return error.InvalidData;
    const base = std.mem.readInt(u64, data[0..8], .little);
    const delta_data = data[8..];
    if (delta_data.len < count * 2) return error.InvalidData;
    for (0..count) |i| {
        const delta = std.mem.readInt(u16, delta_data[i * 2 ..][0..2], .little);
        out[i] = u64ToValue(base +% @as(u64, delta), col_type);
    }
}

// --- Value serialization helpers ---

const ReadResult = struct { value: ColumnValue, bytes_read: usize };

fn writeValue(col_type: ColumnType, v: ColumnValue, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    switch (col_type) {
        .bool_t => try out.append(alloc, if (v.bool_t) 1 else 0),
        .int8 => try out.append(alloc, @bitCast(v.int8)),
        .int16 => {
            var b: [2]u8 = undefined;
            std.mem.writeInt(i16, &b, v.int16, .little);
            try out.appendSlice(alloc, &b);
        },
        .int32 => {
            var b: [4]u8 = undefined;
            std.mem.writeInt(i32, &b, v.int32, .little);
            try out.appendSlice(alloc, &b);
        },
        .int64 => {
            var b: [8]u8 = undefined;
            std.mem.writeInt(i64, &b, v.int64, .little);
            try out.appendSlice(alloc, &b);
        },
        .uint8 => try out.append(alloc, v.uint8),
        .uint16 => {
            var b: [2]u8 = undefined;
            std.mem.writeInt(u16, &b, v.uint16, .little);
            try out.appendSlice(alloc, &b);
        },
        .uint32 => {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v.uint32, .little);
            try out.appendSlice(alloc, &b);
        },
        .uint64 => {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, v.uint64, .little);
            try out.appendSlice(alloc, &b);
        },
        .float32 => {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, @bitCast(v.float32), .little);
            try out.appendSlice(alloc, &b);
        },
        .float64 => {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, @bitCast(v.float64), .little);
            try out.appendSlice(alloc, &b);
        },
        .bytes, .string => {
            const s = switch (v) {
                .bytes => |x| x,
                .string => |x| x,
                else => unreachable,
            };
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @intCast(s.len), .little);
            try out.appendSlice(alloc, &len_buf);
            try out.appendSlice(alloc, s);
        },
        .decimal => {
            try out.append(alloc, v.decimal.scale);
            var b: [16]u8 = undefined;
            std.mem.writeInt(i128, &b, v.decimal.coefficient, .little);
            try out.appendSlice(alloc, &b);
        },
    }
}

fn readValue(col_type: ColumnType, data: []const u8, alloc: std.mem.Allocator) !ReadResult {
    switch (col_type) {
        .bool_t => {
            if (data.len < 1) return error.EndOfData;
            return .{ .value = .{ .bool_t = data[0] != 0 }, .bytes_read = 1 };
        },
        .int8 => {
            if (data.len < 1) return error.EndOfData;
            return .{ .value = .{ .int8 = @bitCast(data[0]) }, .bytes_read = 1 };
        },
        .int16 => {
            if (data.len < 2) return error.EndOfData;
            return .{ .value = .{ .int16 = std.mem.readInt(i16, data[0..2], .little) }, .bytes_read = 2 };
        },
        .int32 => {
            if (data.len < 4) return error.EndOfData;
            return .{ .value = .{ .int32 = std.mem.readInt(i32, data[0..4], .little) }, .bytes_read = 4 };
        },
        .int64 => {
            if (data.len < 8) return error.EndOfData;
            return .{ .value = .{ .int64 = std.mem.readInt(i64, data[0..8], .little) }, .bytes_read = 8 };
        },
        .uint8 => {
            if (data.len < 1) return error.EndOfData;
            return .{ .value = .{ .uint8 = data[0] }, .bytes_read = 1 };
        },
        .uint16 => {
            if (data.len < 2) return error.EndOfData;
            return .{ .value = .{ .uint16 = std.mem.readInt(u16, data[0..2], .little) }, .bytes_read = 2 };
        },
        .uint32 => {
            if (data.len < 4) return error.EndOfData;
            return .{ .value = .{ .uint32 = std.mem.readInt(u32, data[0..4], .little) }, .bytes_read = 4 };
        },
        .uint64 => {
            if (data.len < 8) return error.EndOfData;
            return .{ .value = .{ .uint64 = std.mem.readInt(u64, data[0..8], .little) }, .bytes_read = 8 };
        },
        .float32 => {
            if (data.len < 4) return error.EndOfData;
            return .{ .value = .{ .float32 = @bitCast(std.mem.readInt(u32, data[0..4], .little)) }, .bytes_read = 4 };
        },
        .float64 => {
            if (data.len < 8) return error.EndOfData;
            return .{ .value = .{ .float64 = @bitCast(std.mem.readInt(u64, data[0..8], .little)) }, .bytes_read = 8 };
        },
        .bytes, .string => {
            if (data.len < 4) return error.EndOfData;
            const len = std.mem.readInt(u32, data[0..4], .little);
            if (data.len < 4 + len) return error.EndOfData;
            const s = try alloc.dupe(u8, data[4 .. 4 + len]);
            const value: ColumnValue = if (col_type == .bytes) .{ .bytes = s } else .{ .string = s };
            return .{ .value = value, .bytes_read = 4 + len };
        },
        .decimal => {
            if (data.len < 17) return error.EndOfData;
            return .{ .value = .{ .decimal = .{
                .scale = data[0],
                .coefficient = std.mem.readInt(i128, data[1..17], .little),
            } }, .bytes_read = 17 };
        },
    }
}
