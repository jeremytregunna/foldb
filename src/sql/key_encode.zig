/// Storage key encoding: primary key, foreign key lookups, virtual rows, and row key serialization.
const std = @import("std");
const storage_mod = @import("storage.zig");
const schema_mod = @import("schema.zig");

pub const ColumnValue = storage_mod.ColumnValue;

pub fn buildPrimaryKey(
    tbl: *const schema_mod.TableSchema,
    col_ids: []const schema_mod.ColumnId,
    values: []const ColumnValue,
    alloc: std.mem.Allocator,
) ![]const u8 {
    var key_buf: std.ArrayList(u8) = .empty;
    for (tbl.primary_key) |pk_col_id| {
        for (col_ids, 0..) |cid, i| {
            if (cid == pk_col_id and i < values.len) {
                try encodeKeyComponent(&key_buf, values[i], alloc);
                break;
            }
        }
    }
    return key_buf.toOwnedSlice(alloc);
}

/// Build the storage key for a referenced table row given FK column values.
/// ref_col_ids are the referenced table's column IDs in FK order; fk_vals are the matching values.
pub fn buildForeignKeyLookup(
    ref_tbl: *const schema_mod.TableSchema,
    ref_col_ids: []const schema_mod.ColumnId,
    fk_vals: []const ColumnValue,
    alloc: std.mem.Allocator,
) ![]const u8 {
    var key_buf: std.ArrayList(u8) = .empty;
    for (ref_tbl.primary_key) |pk_col_id| {
        for (ref_col_ids, 0..) |ref_cid, i| {
            if (ref_cid == pk_col_id and i < fk_vals.len) {
                try encodeKeyComponent(&key_buf, fk_vals[i], alloc);
                break;
            }
        }
    }
    return key_buf.toOwnedSlice(alloc);
}

pub fn encodeKeyComponent(buf: *std.ArrayList(u8), v: ColumnValue, alloc: std.mem.Allocator) !void {
    switch (v) {
        .bool_t => |b| try buf.append(alloc, if (b) 1 else 0),
        .int8 => |n| try buf.append(alloc, @bitCast(n)),
        .int16 => |n| {
            var b: [2]u8 = undefined;
            std.mem.writeInt(i16, &b, n, .big);
            try buf.appendSlice(alloc, &b);
        },
        .int32 => |n| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(i32, &b, n, .big);
            try buf.appendSlice(alloc, &b);
        },
        .int64 => |n| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(i64, &b, n, .big);
            try buf.appendSlice(alloc, &b);
        },
        .uint8 => |n| try buf.append(alloc, n),
        .uint16 => |n| {
            var b: [2]u8 = undefined;
            std.mem.writeInt(u16, &b, n, .big);
            try buf.appendSlice(alloc, &b);
        },
        .uint32 => |n| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, n, .big);
            try buf.appendSlice(alloc, &b);
        },
        .uint64 => |n| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, n, .big);
            try buf.appendSlice(alloc, &b);
        },
        .float32 => |n| {
            const bits = @as(u32, @bitCast(n));
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, bits, .big);
            try buf.appendSlice(alloc, &b);
        },
        .float64 => |n| {
            const bits = @as(u64, @bitCast(n));
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, bits, .big);
            try buf.appendSlice(alloc, &b);
        },
        .string => |s| {
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @intCast(s.len), .big);
            try buf.appendSlice(alloc, &len_buf);
            try buf.appendSlice(alloc, s);
        },
        .bytes => |b| {
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @intCast(b.len), .big);
            try buf.appendSlice(alloc, &len_buf);
            try buf.appendSlice(alloc, b);
        },
    }
}

pub fn pkColumnIds(tbl: *const schema_mod.TableSchema) []const schema_mod.ColumnId {
    return tbl.primary_key;
}

pub fn buildVirtualRow(
    n_cols: usize,
    col_ids: []const schema_mod.ColumnId,
    values: []const ColumnValue,
    alloc: std.mem.Allocator,
) ![]const ?ColumnValue {
    const virtual = try alloc.alloc(?ColumnValue, n_cols);
    @memset(virtual, null);
    for (col_ids, values) |col_id, val| {
        const pos: usize = @intCast(col_id);
        if (pos < virtual.len) virtual[pos] = val;
    }
    return virtual;
}

pub fn serializeRowKey(row: []const ?ColumnValue, alloc: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (row) |maybe_val| {
        if (maybe_val) |cv| {
            try buf.append(alloc, 1);
            switch (cv) {
                .bool_t => |b| try buf.append(alloc, if (b) 1 else 0),
                .int8 => |v| {
                    var tmp: [1]u8 = undefined;
                    std.mem.writeInt(i8, &tmp, v, .little);
                    try buf.appendSlice(alloc, &tmp);
                },
                .int16 => |v| {
                    var tmp: [2]u8 = undefined;
                    std.mem.writeInt(i16, &tmp, v, .little);
                    try buf.appendSlice(alloc, &tmp);
                },
                .int32 => |v| {
                    var tmp: [4]u8 = undefined;
                    std.mem.writeInt(i32, &tmp, v, .little);
                    try buf.appendSlice(alloc, &tmp);
                },
                .int64 => |v| {
                    var tmp: [8]u8 = undefined;
                    std.mem.writeInt(i64, &tmp, v, .little);
                    try buf.appendSlice(alloc, &tmp);
                },
                .uint8 => |v| try buf.append(alloc, v),
                .uint16 => |v| {
                    var tmp: [2]u8 = undefined;
                    std.mem.writeInt(u16, &tmp, v, .little);
                    try buf.appendSlice(alloc, &tmp);
                },
                .uint32 => |v| {
                    var tmp: [4]u8 = undefined;
                    std.mem.writeInt(u32, &tmp, v, .little);
                    try buf.appendSlice(alloc, &tmp);
                },
                .uint64 => |v| {
                    var tmp: [8]u8 = undefined;
                    std.mem.writeInt(u64, &tmp, v, .little);
                    try buf.appendSlice(alloc, &tmp);
                },
                .float32 => |v| {
                    var tmp: [4]u8 = undefined;
                    std.mem.writeInt(u32, &tmp, @bitCast(v), .little);
                    try buf.appendSlice(alloc, &tmp);
                },
                .float64 => |v| {
                    var tmp: [8]u8 = undefined;
                    std.mem.writeInt(u64, &tmp, @bitCast(v), .little);
                    try buf.appendSlice(alloc, &tmp);
                },
                .string => |s| {
                    var tmp: [4]u8 = undefined;
                    std.mem.writeInt(u32, &tmp, @intCast(s.len), .little);
                    try buf.appendSlice(alloc, &tmp);
                    try buf.appendSlice(alloc, s);
                },
                .bytes => |b| {
                    var tmp: [4]u8 = undefined;
                    std.mem.writeInt(u32, &tmp, @intCast(b.len), .little);
                    try buf.appendSlice(alloc, &tmp);
                    try buf.appendSlice(alloc, b);
                },
            }
        } else {
            try buf.append(alloc, 0);
        }
        try buf.append(alloc, 0xFF);
    }
    return buf.toOwnedSlice(alloc);
}
