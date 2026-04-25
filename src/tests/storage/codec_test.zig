const std = @import("std");
const testing = std.testing;
const storage = @import("storage.zig");

const ColumnValue = storage.ColumnValue;
const ColumnType = storage.ColumnType;
const CodecId = storage.CodecId;

fn roundTrip(col_type: ColumnType, values: []const ColumnValue, expected_codec: CodecId) !void {
    const alloc = testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    const chosen = storage.chooseCodec(col_type, values);
    try testing.expectEqual(expected_codec, chosen);

    try storage.encodeCol(chosen, col_type, values, &buf, alloc);

    const out = try alloc.alloc(ColumnValue, values.len);
    defer {
        for (out) |v| v.freeIfOwned(alloc);
        alloc.free(out);
    }

    try storage.decodeCol(chosen, col_type, buf.items, @intCast(values.len), out, alloc);

    for (values, out) |expected, actual| {
        try testing.expect(expected.eql(actual));
    }
}

test "Raw: int64 round-trip" {
    const vals = [_]ColumnValue{
        .{ .int64 = 100 },
        .{ .int64 = -200 },
        .{ .int64 = 0 },
        .{ .int64 = std.math.maxInt(i64) },
    };
    // int64 range > 65535 → raw
    try roundTrip(.int64, &vals, .raw);
}

test "FOR: uint32 small range" {
    const vals = [_]ColumnValue{
        .{ .uint32 = 1000 },
        .{ .uint32 = 1001 },
        .{ .uint32 = 1002 },
        .{ .uint32 = 1050 },
        .{ .uint32 = 1000 },
    };
    try roundTrip(.uint32, &vals, .for_);
}

test "RLE: repeated values" {
    const vals = [_]ColumnValue{
        .{ .int32 = 42 },
        .{ .int32 = 42 },
        .{ .int32 = 42 },
        .{ .int32 = 42 },
        .{ .int32 = 7 },
        .{ .int32 = 7 },
        .{ .int32 = 7 },
    };
    // 5/6 pairs equal → RLE
    try roundTrip(.int32, &vals, .rle);
}

test "Dict or FOR: low cardinality uint8" {
    const vals = [_]ColumnValue{
        .{ .uint8 = 1 },
        .{ .uint8 = 2 },
        .{ .uint8 = 1 },
        .{ .uint8 = 3 },
        .{ .uint8 = 2 },
        .{ .uint8 = 1 },
    };
    // range = 2 ≤ 65535 → FOR wins
    const alloc = testing.allocator;
    const chosen = storage.chooseCodec(.uint8, &vals);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try storage.encodeCol(chosen, .uint8, &vals, &buf, alloc);
    const out = try alloc.alloc(ColumnValue, vals.len);
    defer alloc.free(out);
    try storage.decodeCol(chosen, .uint8, buf.items, @intCast(vals.len), out, alloc);
    for (vals, out) |e, a| try testing.expect(e.eql(a));
}

test "Raw: string values" {
    const alloc = testing.allocator;
    const vals = [_]ColumnValue{
        .{ .string = "hello" },
        .{ .string = "world" },
        .{ .string = "foo" },
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try storage.encodeCol(.raw, .string, &vals, &buf, alloc);
    const out = try alloc.alloc(ColumnValue, vals.len);
    defer {
        for (out) |v| v.freeIfOwned(alloc);
        alloc.free(out);
    }
    try storage.decodeCol(.raw, .string, buf.items, @intCast(vals.len), out, alloc);
    for (vals, out) |e, a| try testing.expect(e.eql(a));
}

test "FOR: encode then decode uint64" {
    const vals = [_]ColumnValue{
        .{ .uint64 = 500 },
        .{ .uint64 = 501 },
        .{ .uint64 = 600 },
        .{ .uint64 = 500 },
    };
    try roundTrip(.uint64, &vals, .for_);
}

test "Dict: string low cardinality" {
    // 12 strings cycling 3 distinct values with no adjacent runs → dict
    const vals = [_]ColumnValue{
        .{ .string = "alpha" }, .{ .string = "beta" },  .{ .string = "gamma" },
        .{ .string = "alpha" }, .{ .string = "gamma" }, .{ .string = "beta" },
        .{ .string = "gamma" }, .{ .string = "alpha" }, .{ .string = "beta" },
        .{ .string = "gamma" }, .{ .string = "alpha" }, .{ .string = "gamma" },
    };
    // 0/11 adjacent pairs equal → not RLE; string not integer → not FOR; 3 distinct ≤ 256 → dict
    try roundTrip(.string, &vals, .dict);
}

test "Dict: bool values" {
    const vals = [_]ColumnValue{
        .{ .bool_t = true },  .{ .bool_t = false }, .{ .bool_t = true }, .{ .bool_t = false },
        .{ .bool_t = false }, .{ .bool_t = true },
    };
    // 1/5 adjacent pairs equal = 20% < 50% → not RLE; not integer → not FOR; 2 distinct ≤ 256 → dict
    try roundTrip(.bool_t, &vals, .dict);
}

test "Dict: decimal values" {
    const vals = [_]ColumnValue{
        .{ .decimal = .{ .coefficient = 100, .scale = 2 } },
        .{ .decimal = .{ .coefficient = 250, .scale = 2 } },
        .{ .decimal = .{ .coefficient = 100, .scale = 2 } },
        .{ .decimal = .{ .coefficient = 314, .scale = 2 } },
        .{ .decimal = .{ .coefficient = 250, .scale = 2 } },
        .{ .decimal = .{ .coefficient = 100, .scale = 2 } },
    };
    // 2/5 adjacent equal = 40% < 50% → not RLE; not integer → not FOR; 3 distinct ≤ 256 → dict
    try roundTrip(.decimal, &vals, .dict);
}

test "RLE: bool all same" {
    const vals = [_]ColumnValue{
        .{ .bool_t = true }, .{ .bool_t = true }, .{ .bool_t = true }, .{ .bool_t = true },
        .{ .bool_t = true }, .{ .bool_t = true }, .{ .bool_t = true }, .{ .bool_t = true },
    };
    // 7/7 adjacent pairs equal = 100% ≥ 50% → RLE wins before Dict
    try roundTrip(.bool_t, &vals, .rle);
}

test "FOR: int32 small range" {
    const vals = [_]ColumnValue{
        .{ .int32 = 100 }, .{ .int32 = 110 }, .{ .int32 = 105 }, .{ .int32 = 103 }, .{ .int32 = 100 },
    };
    // range = 10 ≤ 65535; no RLE (0/4 pairs equal) → FOR
    try roundTrip(.int32, &vals, .for_);
}
