/// Aggregate serialization helpers: dupePlanValue, freePlanValue, serializeArrayAgg, buildStringAgg.
const std = @import("std");
const plan_mod = @import("plan.zig");

pub fn dupePlanValue(v: plan_mod.Value, alloc: std.mem.Allocator) !plan_mod.Value {
    return switch (v) {
        .string_val => |s| .{ .string_val = try alloc.dupe(u8, s) },
        .bytes_val => |b| .{ .bytes_val = try alloc.dupe(u8, b) },
        .opaque_val => |o| .{ .opaque_val = try alloc.dupe(u8, o) },
        else => v,
    };
}

pub fn freePlanValue(v: plan_mod.Value, alloc: std.mem.Allocator) void {
    switch (v) {
        .string_val => |s| alloc.free(s),
        .bytes_val => |b| alloc.free(b),
        .opaque_val => |o| alloc.free(o),
        else => {},
    }
}

pub fn serializeArrayAgg(items: []const plan_mod.Value, alloc: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (items, 0..) |v, i| {
        if (i > 0) try buf.appendSlice(alloc, ", ");
        switch (v) {
            .null_val => try buf.appendSlice(alloc, "null"),
            .bool_val => |b| try buf.appendSlice(alloc, if (b) "true" else "false"),
            .int_val => |n| {
                const s = try std.fmt.allocPrint(alloc, "{}", .{n});
                defer alloc.free(s);
                try buf.appendSlice(alloc, s);
            },
            .uint_val => |n| {
                const s = try std.fmt.allocPrint(alloc, "{}", .{n});
                defer alloc.free(s);
                try buf.appendSlice(alloc, s);
            },
            .float_val => |f| {
                const s = try std.fmt.allocPrint(alloc, "{d}", .{f});
                defer alloc.free(s);
                try buf.appendSlice(alloc, s);
            },
            .string_val => |s| {
                try buf.append(alloc, '"');
                for (s) |c| {
                    switch (c) {
                        '"' => try buf.appendSlice(alloc, "\\\""),
                        '\\' => try buf.appendSlice(alloc, "\\\\"),
                        '\n' => try buf.appendSlice(alloc, "\\n"),
                        '\r' => try buf.appendSlice(alloc, "\\r"),
                        '\t' => try buf.appendSlice(alloc, "\\t"),
                        else => try buf.append(alloc, c),
                    }
                }
                try buf.append(alloc, '"');
            },
            .decimal_val => |d| {
                const s = try std.fmt.allocPrint(alloc, "{d}", .{@as(f64, @floatFromInt(d.coefficient)) / std.math.pow(f64, 10, @floatFromInt(d.scale))});
                defer alloc.free(s);
                try buf.appendSlice(alloc, s);
            },
            .bytes_val => |b| try buf.appendSlice(alloc, b),
            .opaque_val => |o| try buf.appendSlice(alloc, o),
        }
    }
    try buf.append(alloc, ']');
    return buf.toOwnedSlice(alloc);
}

pub fn buildStringAgg(items: []const plan_mod.Value, sep: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var first = true;
    for (items) |v| {
        switch (v) {
            .string_val => |s| {
                if (!first) try buf.appendSlice(alloc, sep);
                try buf.appendSlice(alloc, s);
                first = false;
            },
            else => {},
        }
    }
    return buf.toOwnedSlice(alloc);
}
