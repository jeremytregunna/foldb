const std = @import("std");
const storage = @import("storage.zig");

const codec = storage.vector_codec;

test "vector codec round-trip" {
    const alloc = std.testing.allocator;
    const original: []const f32 = &.{ 1.0, -2.5, 0.0, 3.14, -0.001 };

    const encoded = try codec.encode(original, alloc);
    defer alloc.free(encoded);

    try std.testing.expectEqual(original.len * 4, encoded.len);
    try std.testing.expectEqual(@as(u32, @intCast(original.len)), codec.dimension(encoded));

    const decoded = try codec.decode(encoded, alloc);
    defer alloc.free(decoded);

    try std.testing.expectEqual(original.len, decoded.len);
    for (original, decoded) |a, b| {
        try std.testing.expectApproxEqAbs(a, b, 1e-6);
    }
}

test "vector codec single element" {
    const alloc = std.testing.allocator;
    const v: []const f32 = &.{42.0};
    const enc = try codec.encode(v, alloc);
    defer alloc.free(enc);
    const dec = try codec.decode(enc, alloc);
    defer alloc.free(dec);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), dec[0], 1e-6);
}

test "vector codec empty" {
    const alloc = std.testing.allocator;
    const v: []const f32 = &.{};
    const enc = try codec.encode(v, alloc);
    defer alloc.free(enc);
    try std.testing.expectEqual(@as(usize, 0), enc.len);
    const dec = try codec.decode(enc, alloc);
    defer alloc.free(dec);
    try std.testing.expectEqual(@as(usize, 0), dec.len);
}

test "vector codec invalid data returns error" {
    const alloc = std.testing.allocator;
    const bad: []const u8 = &.{ 0, 1, 2 }; // not a multiple of 4
    try std.testing.expectError(error.InvalidVectorData, codec.decode(bad, alloc));
}
