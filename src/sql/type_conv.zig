/// Type conversion helpers: ColumnValue ↔ plan Value, cast, default, aggregate key comparison.
const std = @import("std");
const plan_mod = @import("plan.zig");
const storage_mod = @import("storage.zig");
const ast = @import("ast.zig");

pub const ColumnValue = storage_mod.ColumnValue;

pub fn columnValueToPlanValue(cv: ColumnValue) plan_mod.Value {
    return switch (cv) {
        .bool_t => |v| .{ .bool_val = v },
        .int8 => |v| .{ .int_val = v },
        .int16 => |v| .{ .int_val = v },
        .int32 => |v| .{ .int_val = v },
        .int64 => |v| .{ .int_val = v },
        .uint8 => |v| .{ .uint_val = v },
        .uint16 => |v| .{ .uint_val = v },
        .uint32 => |v| .{ .uint_val = v },
        .uint64 => |v| .{ .uint_val = v },
        .string => |v| .{ .string_val = v },
        .bytes => |v| .{ .bytes_val = v },
        .decimal => |v| .{ .decimal_val = v },
    };
}

pub fn planValueToColumnValue(v: plan_mod.Value, alloc: std.mem.Allocator) !ColumnValue {
    return switch (v) {
        .null_val => error.TypeMismatch,
        .bool_val => |b| .{ .bool_t = b },
        .int_val => |n| .{ .int64 = n },
        .uint_val => |n| .{ .uint64 = n },
        .decimal_val => |d| .{ .decimal = d },
        .string_val => |s| .{ .string = try alloc.dupe(u8, s) },
        .bytes_val => |b| .{ .bytes = try alloc.dupe(u8, b) },
        .opaque_val => |b| .{ .bytes = try alloc.dupe(u8, b) },
    };
}

pub fn planValueToTypedColumnValue(v: plan_mod.Value, typ: ast.SqlType, alloc: std.mem.Allocator) !ColumnValue {
    return switch (typ) {
        .bool => .{ .bool_t = v.toBool() orelse return error.TypeMismatch },
        .int8 => switch (v) {
            .int_val => |n| .{ .int8 = @intCast(n) },
            else => error.TypeMismatch,
        },
        .int16 => switch (v) {
            .int_val => |n| .{ .int16 = @intCast(n) },
            else => error.TypeMismatch,
        },
        .int32 => switch (v) {
            .int_val => |n| .{ .int32 = @intCast(n) },
            else => error.TypeMismatch,
        },
        .int64 => switch (v) {
            .int_val => |n| .{ .int64 = n },
            else => error.TypeMismatch,
        },
        .uint8 => switch (v) {
            .uint_val => |n| .{ .uint8 = @intCast(n) },
            else => error.TypeMismatch,
        },
        .uint16 => switch (v) {
            .uint_val => |n| .{ .uint16 = @intCast(n) },
            else => error.TypeMismatch,
        },
        .uint32 => switch (v) {
            .uint_val => |n| .{ .uint32 = @intCast(n) },
            else => error.TypeMismatch,
        },
        .uint64 => switch (v) {
            .uint_val => |n| .{ .uint64 = n },
            else => error.TypeMismatch,
        },
        .decimal => switch (v) {
            .decimal_val => |d| .{ .decimal = d },
            .int_val => |n| .{ .decimal = .{ .coefficient = n, .scale = 0 } },
            else => error.TypeMismatch,
        },
        .string => switch (v) {
            .string_val => |s| .{ .string = try alloc.dupe(u8, s) },
            else => error.TypeMismatch,
        },
        .bytes => switch (v) {
            .bytes_val => |b| .{ .bytes = try alloc.dupe(u8, b) },
            else => error.TypeMismatch,
        },
        else => planValueToColumnValue(v, alloc) catch error.TypeMismatch,
    };
}

pub fn castValue(v: plan_mod.Value, to: ast.SqlType) !plan_mod.Value {
    return switch (to) {
        .int64 => switch (v) {
            .int_val => v,
            .uint_val => |n| .{ .int_val = @intCast(n) },
            else => error.TypeMismatch,
        },
        .decimal => switch (v) {
            .decimal_val => v,
            .int_val => |n| .{ .decimal_val = .{ .coefficient = n, .scale = 0 } },
            .uint_val => |n| .{ .decimal_val = .{ .coefficient = @intCast(n), .scale = 0 } },
            else => error.TypeMismatch,
        },
        .string => switch (v) {
            .string_val => v,
            else => error.TypeMismatch,
        },
        else => v,
    };
}

pub fn defaultValue(typ: ast.SqlType) ColumnValue {
    return switch (typ) {
        .bool => .{ .bool_t = false },
        .int8 => .{ .int8 = 0 },
        .int16 => .{ .int16 = 0 },
        .int32 => .{ .int32 = 0 },
        .int64 => .{ .int64 = 0 },
        .uint8 => .{ .uint8 = 0 },
        .uint16 => .{ .uint16 = 0 },
        .uint32 => .{ .uint32 = 0 },
        .uint64 => .{ .uint64 = 0 },
        .decimal => .{ .decimal = .{ .coefficient = 0, .scale = 0 } },
        .string => .{ .string = "" },
        .bytes => .{ .bytes = "" },
        else => .{ .bytes = "" },
    };
}

pub fn aggKeyEquals(a: []const ?ColumnValue, b: []const ?ColumnValue) bool {
    if (a.len != b.len) return false;
    for (a, b) |av, bv| {
        if (av == null and bv == null) continue;
        if (av == null or bv == null) return false;
        if (!columnValueToPlanValue(av.?).eql(columnValueToPlanValue(bv.?))) return false;
    }
    return true;
}
