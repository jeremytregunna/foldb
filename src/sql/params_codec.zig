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
        .decimal => |d| {
            try buf.append(alloc, d.scale);
            var b: [16]u8 = undefined;
            std.mem.writeInt(i128, &b, d.coefficient, .little);
            try buf.appendSlice(alloc, &b);
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
    var pos: u32 = 2;
    for (0..count) |i| {
        if (pos >= data.len) return error.TypeMismatch;
        const tag_byte = data[pos];
        pos += 1;
        if (types.len > 0) {
            // Decode the wire value using its actual tag, then coerce to declared type.
            // This handles mismatches where the sender uses int64 for a declared int32.
            const wire_val = try decodeParamValueByTag(data, &pos, tag_byte, alloc);
            values[i] = coerceToSqlType(wire_val, types[i]);
        } else {
            values[i] = try decodeParamValueByTag(data, &pos, tag_byte, alloc);
        }
    }
    return values;
}

/// Coerce a decoded ColumnValue to the expected SqlType declared in the query signature.
/// Integer types are converted losslessly when the value fits; other types must match exactly.
fn coerceToSqlType(v: ColumnValue, typ: ast.SqlType) ColumnValue {
    // Extract integer value for numeric coercions.
    const as_i64: ?i64 = switch (v) {
        .int8 => |n| @intCast(n),
        .int16 => |n| @intCast(n),
        .int32 => |n| @intCast(n),
        .int64 => |n| n,
        .uint8 => |n| @intCast(n),
        .uint16 => |n| @intCast(n),
        .uint32 => |n| @intCast(n),
        .uint64 => |n| if (n <= std.math.maxInt(i64)) @intCast(n) else null,
        .bool_t => |b| if (b) 1 else 0,
        else => null,
    };
    const as_u64: ?u64 = switch (v) {
        .int8 => |n| if (n >= 0) @intCast(n) else null,
        .int16 => |n| if (n >= 0) @intCast(n) else null,
        .int32 => |n| if (n >= 0) @intCast(n) else null,
        .int64 => |n| if (n >= 0) @intCast(n) else null,
        .uint8 => |n| @intCast(n),
        .uint16 => |n| @intCast(n),
        .uint32 => |n| @intCast(n),
        .uint64 => |n| n,
        .bool_t => |b| if (b) 1 else 0,
        else => null,
    };
    return switch (typ) {
        .int8 => if (as_i64) |n| .{ .int8 = @truncate(n) } else v,
        .int16 => if (as_i64) |n| .{ .int16 = @truncate(n) } else v,
        .int32 => if (as_i64) |n| .{ .int32 = @truncate(n) } else v,
        .int64 => if (as_i64) |n| .{ .int64 = n } else v,
        .uint8 => if (as_u64) |n| .{ .uint8 = @truncate(n) } else v,
        .uint16 => if (as_u64) |n| .{ .uint16 = @truncate(n) } else v,
        .uint32 => if (as_u64) |n| .{ .uint32 = @truncate(n) } else v,
        .uint64 => if (as_u64) |n| .{ .uint64 = n } else v,
        else => v, // string, bytes, decimal, bool — pass through unchanged
    };
}

fn decodeParamValueByTag(data: []const u8, pos: *u32, tag: u8, alloc: std.mem.Allocator) !ColumnValue {
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
        11 => .bytes,
        12 => .string,
        13 => .decimal,
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
        .decimal => blk: {
            const scale = data[pos.*];
            pos.* += 1;
            const coeff = std.mem.readInt(i128, data[pos.*..][0..16], .little);
            pos.* += 16;
            break :blk .{ .decimal = .{ .coefficient = coeff, .scale = scale } };
        },
    };
}
