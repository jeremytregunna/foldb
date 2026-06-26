/// Codec tests for opaque []const u8 value encoding/decoding.
const std = @import("std");
const testing = std.testing;
const storage = @import("storage.zig");

test "codec: encode then decode single value" {
    const alloc = testing.allocator;
    const values = [_][]const u8{ "hello" };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try storage.encodeCol(&values, &buf, alloc);

    const decoded = try storage.decodeCol(buf.items, 1, alloc);
    defer { for (decoded) |v| alloc.free(v); alloc.free(decoded); }
    try testing.expect(decoded.len == 1);
    try testing.expectEqualSlices(u8, "hello", decoded[0]);
}

test "codec: encode then decode multiple values" {
    const alloc = testing.allocator;
    const values = [_][]const u8{ "alpha", "beta", "gamma" };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try storage.encodeCol(&values, &buf, alloc);

    const decoded = try storage.decodeCol(buf.items, 3, alloc);
    defer { for (decoded) |v| alloc.free(v); alloc.free(decoded); }
    try testing.expect(decoded.len == 3);
    try testing.expectEqualSlices(u8, "alpha", decoded[0]);
    try testing.expectEqualSlices(u8, "beta", decoded[1]);
    try testing.expectEqualSlices(u8, "gamma", decoded[2]);
}

test "codec: encode empty value" {
    const alloc = testing.allocator;
    const values = [_][]const u8{ "", "x", "" };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try storage.encodeCol(&values, &buf, alloc);

    const decoded = try storage.decodeCol(buf.items, 3, alloc);
    defer { for (decoded) |v| alloc.free(v); alloc.free(decoded); }
    try testing.expect(decoded.len == 3);
    try testing.expect(decoded[0].len == 0);
    try testing.expectEqualSlices(u8, "x", decoded[1]);
    try testing.expect(decoded[2].len == 0);
}

test "codec: encode large value" {
    const alloc = testing.allocator;
    const large = try alloc.alloc(u8, 10_000);
    defer alloc.free(large);
    @memset(large, 0xAB);
    const values = [_][]const u8{ large };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try storage.encodeCol(&values, &buf, alloc);

    const decoded = try storage.decodeCol(buf.items, 1, alloc);
    defer { for (decoded) |v| alloc.free(v); alloc.free(decoded); }
    try testing.expectEqualSlices(u8, large, decoded[0]);
    try testing.expectEqualSlices(u8, large, decoded[0]);
}

test "codec: decode zero rows" {
    const alloc = testing.allocator;
    const decoded = try storage.decodeCol(&.{}, 0, alloc);
    defer { for (decoded) |v| alloc.free(v); alloc.free(decoded); }
    try testing.expect(decoded.len == 0);
}

test "codec: decode truncated data" {
    const alloc = testing.allocator;
    // Claims 16 bytes but only has 4 (the length prefix)
    const bad_data = [_]u8{ 0x10, 0x00, 0x00, 0x00 };
    const err = storage.decodeCol(&bad_data, 1, alloc);
    try testing.expectError(error.InvalidData, err);
}

test "codec: decode too few rows requested" {
    const alloc = testing.allocator;
    // Encode 3 values but only ask for 2
    const values = [_][]const u8{ "a", "b", "c" };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try storage.encodeCol(&values, &buf, alloc);

    const decoded = try storage.decodeCol(buf.items, 2, alloc);
    defer { for (decoded) |v| alloc.free(v); alloc.free(decoded); }
    try testing.expect(decoded.len == 2);
    try testing.expectEqualSlices(u8, "a", decoded[0]);
    try testing.expectEqualSlices(u8, "b", decoded[1]);
}

test "codec: binary data with nulls" {
    const alloc = testing.allocator;
    const binary = [_]u8{ 0x00, 0xFF, 0x00, 0xFF, 0x01, 0xFE };
    const values = [_][]const u8{ &binary };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try storage.encodeCol(&values, &buf, alloc);

    const decoded = try storage.decodeCol(buf.items, 1, alloc);
    defer { for (decoded) |v| alloc.free(v); alloc.free(decoded); }
    try testing.expectEqualSlices(u8, &binary, decoded[0]);
}
