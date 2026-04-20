/// Params wire-format codec: encode/decode ColumnValues for log entries.
/// Format: [u16 count] [for each: u8 type_tag, value bytes]
const std = @import("std");
const storage_mod = @import("storage.zig");
const ast = @import("ast.zig");

pub const ColumnValue = storage_mod.ColumnValue;
pub const ColumnType = storage_mod.ColumnType;

/// Serialize ColumnValues into the params wire format.
pub fn encodeParams(values: []const ColumnValue, alloc: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var count_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &count_buf, @intCast(values.len), .little);
    try buf.appendSlice(alloc, &count_buf);
    for (values) |v| {
        try encodeParamValue(&buf, v, alloc);
    }
    return buf.toOwnedSlice(alloc);
}

fn encodeParamValue(buf: *std.ArrayList(u8), v: ColumnValue, alloc: std.mem.Allocator) !void {
    const tag: u8 = @intFromEnum(@as(ColumnType, v));
    try buf.append(alloc, tag);
    switch (v) {
        .bool_t => |b| try buf.append(alloc, if (b) 1 else 0),
        .int8 => |n| try buf.append(alloc, @bitCast(n)),
        .int16 => |n| {
            var b: [2]u8 = undefined;
            std.mem.writeInt(i16, &b, n, .little);
            try buf.appendSlice(alloc, &b);
        },
        .int32 => |n| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(i32, &b, n, .little);
            try buf.appendSlice(alloc, &b);
        },
        .int64 => |n| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(i64, &b, n, .little);
            try buf.appendSlice(alloc, &b);
        },
        .uint8 => |n| try buf.append(alloc, n),
        .uint16 => |n| {
            var b: [2]u8 = undefined;
            std.mem.writeInt(u16, &b, n, .little);
            try buf.appendSlice(alloc, &b);
        },
        .uint32 => |n| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, n, .little);
            try buf.appendSlice(alloc, &b);
        },
        .uint64 => |n| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, n, .little);
            try buf.appendSlice(alloc, &b);
        },
        .float32 => |n| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, @bitCast(n), .little);
            try buf.appendSlice(alloc, &b);
        },
        .float64 => |n| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, @bitCast(n), .little);
            try buf.appendSlice(alloc, &b);
        },
        .string => |s| {
            var lb: [4]u8 = undefined;
            std.mem.writeInt(u32, &lb, @intCast(s.len), .little);
            try buf.appendSlice(alloc, &lb);
            try buf.appendSlice(alloc, s);
        },
        .bytes => |s| {
            var lb: [4]u8 = undefined;
            std.mem.writeInt(u32, &lb, @intCast(s.len), .little);
            try buf.appendSlice(alloc, &lb);
            try buf.appendSlice(alloc, s);
        },
    }
}

/// Decode params wire format into ColumnValues using declared types.
/// When types is empty (non-TRANSACTION queries), falls back to tag-based decoding.
pub fn decodeParams(data: []const u8, types: []const ast.SqlType, alloc: std.mem.Allocator) ![]ColumnValue {
    if (data.len < 2) {
        if (types.len == 0) return &.{};
        return error.TypeMismatch;
    }
    const count = std.mem.readInt(u16, data[0..2], .little);
    if (count == 0) return &.{};
    if (types.len > 0 and count != types.len) return error.TypeMismatch;
    const values = try alloc.alloc(ColumnValue, count);
    var pos: usize = 2;
    for (0..count) |i| {
        if (pos >= data.len) return error.TypeMismatch;
        const tag_byte = data[pos];
        pos += 1;
        if (types.len > 0) {
            values[i] = try decodeParamValue(data, &pos, types[i], alloc);
        } else {
            values[i] = try decodeParamValueByTag(data, &pos, tag_byte, alloc);
        }
    }
    return values;
}

fn decodeParamValue(data: []const u8, pos: *usize, typ: ast.SqlType, alloc: std.mem.Allocator) !ColumnValue {
    return switch (typ) {
        .bool => blk: {
            const b = data[pos.*];
            pos.* += 1;
            break :blk .{ .bool_t = b != 0 };
        },
        .int8 => blk: {
            const n: i8 = @bitCast(data[pos.*]);
            pos.* += 1;
            break :blk .{ .int8 = n };
        },
        .int16 => blk: {
            const n = std.mem.readInt(i16, data[pos.*..][0..2], .little);
            pos.* += 2;
            break :blk .{ .int16 = n };
        },
        .int32 => blk: {
            const n = std.mem.readInt(i32, data[pos.*..][0..4], .little);
            pos.* += 4;
            break :blk .{ .int32 = n };
        },
        .int64 => blk: {
            const n = std.mem.readInt(i64, data[pos.*..][0..8], .little);
            pos.* += 8;
            break :blk .{ .int64 = n };
        },
        .uint8 => blk: {
            const n = data[pos.*];
            pos.* += 1;
            break :blk .{ .uint8 = n };
        },
        .uint16 => blk: {
            const n = std.mem.readInt(u16, data[pos.*..][0..2], .little);
            pos.* += 2;
            break :blk .{ .uint16 = n };
        },
        .uint32 => blk: {
            const n = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            break :blk .{ .uint32 = n };
        },
        .uint64 => blk: {
            const n = std.mem.readInt(u64, data[pos.*..][0..8], .little);
            pos.* += 8;
            break :blk .{ .uint64 = n };
        },
        .float32 => blk: {
            const bits = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            break :blk .{ .float32 = @bitCast(bits) };
        },
        .float64 => blk: {
            const bits = std.mem.readInt(u64, data[pos.*..][0..8], .little);
            pos.* += 8;
            break :blk .{ .float64 = @bitCast(bits) };
        },
        .string => blk: {
            const len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            const s = try alloc.dupe(u8, data[pos.* .. pos.* + len]);
            pos.* += len;
            break :blk .{ .string = s };
        },
        .bytes, .uuid, .timestamp, .interval_months, .interval_micros, .json, .vector, .decimal => blk: {
            const len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            const b = try alloc.dupe(u8, data[pos.* .. pos.* + len]);
            pos.* += len;
            break :blk .{ .bytes = b };
        },
        else => error.TypeMismatch,
    };
}

fn decodeParamValueByTag(data: []const u8, pos: *usize, tag: u8, alloc: std.mem.Allocator) !ColumnValue {
    const col_type: ColumnType = switch (tag) {
        0 => .bool_t,
        1 => .int8,
        2 => .int16,
        3 => .int32,
        4 => .int64,
        5 => .uint8,
        6 => .uint16,
        7 => .uint32,
        8 => .uint64,
        9 => .float32,
        10 => .float64,
        11 => .bytes,
        12 => .string,
        else => return error.TypeMismatch,
    };
    return switch (col_type) {
        .bool_t => blk: {
            const b = data[pos.*];
            pos.* += 1;
            break :blk .{ .bool_t = b != 0 };
        },
        .int8 => blk: {
            const n: i8 = @bitCast(data[pos.*]);
            pos.* += 1;
            break :blk .{ .int8 = n };
        },
        .int16 => blk: {
            const n = std.mem.readInt(i16, data[pos.*..][0..2], .little);
            pos.* += 2;
            break :blk .{ .int16 = n };
        },
        .int32 => blk: {
            const n = std.mem.readInt(i32, data[pos.*..][0..4], .little);
            pos.* += 4;
            break :blk .{ .int32 = n };
        },
        .int64 => blk: {
            const n = std.mem.readInt(i64, data[pos.*..][0..8], .little);
            pos.* += 8;
            break :blk .{ .int64 = n };
        },
        .uint8 => blk: {
            const n = data[pos.*];
            pos.* += 1;
            break :blk .{ .uint8 = n };
        },
        .uint16 => blk: {
            const n = std.mem.readInt(u16, data[pos.*..][0..2], .little);
            pos.* += 2;
            break :blk .{ .uint16 = n };
        },
        .uint32 => blk: {
            const n = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            break :blk .{ .uint32 = n };
        },
        .uint64 => blk: {
            const n = std.mem.readInt(u64, data[pos.*..][0..8], .little);
            pos.* += 8;
            break :blk .{ .uint64 = n };
        },
        .float32 => blk: {
            const b = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            break :blk .{ .float32 = @bitCast(b) };
        },
        .float64 => blk: {
            const b = std.mem.readInt(u64, data[pos.*..][0..8], .little);
            pos.* += 8;
            break :blk .{ .float64 = @bitCast(b) };
        },
        .string => blk: {
            const len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            const s = try alloc.dupe(u8, data[pos.* .. pos.* + len]);
            pos.* += len;
            break :blk .{ .string = s };
        },
        .bytes => blk: {
            const len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            const b = try alloc.dupe(u8, data[pos.* .. pos.* + len]);
            pos.* += len;
            break :blk .{ .bytes = b };
        },
    };
}
