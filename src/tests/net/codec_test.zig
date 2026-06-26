/// Tests for the wire protocol codec layer.
const std = @import("std");
const testing = std.testing;
const codec = @import("codec.zig");

const TypedValue = codec.TypedValue;
const Cursor = codec.Cursor;

fn roundTrip(alloc: std.mem.Allocator, v: TypedValue) !TypedValue {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try codec.encode(&out, alloc, v);
    var cur = Cursor{ .data = out.items };
    return try codec.decode(&cur, alloc);
}

test "null round-trip" {
    var result = try roundTrip(testing.allocator, TypedValue{ .null = {} });
    try testing.expect(result == .null);
    result.deinit(testing.allocator);
}

test "bool round-trip" {
    var result = try roundTrip(testing.allocator, TypedValue{ .bool = true });
    try testing.expect(result == .bool);
    try testing.expect(result.bool);
    result.deinit(testing.allocator);

    result = try roundTrip(testing.allocator, TypedValue{ .bool = false });
    try testing.expect(result == .bool);
    try testing.expect(!result.bool);
    result.deinit(testing.allocator);
}

test "integer round-trip" {
    const val: i64 = -42;
    var result = try roundTrip(testing.allocator, TypedValue{ .integer = val });
    try testing.expect(result == .integer);
    try testing.expectEqual(val, result.integer);
    result.deinit(testing.allocator);
}

test "float round-trip" {
    const val: f64 = 3.14;
    var result = try roundTrip(testing.allocator, TypedValue{ .float = val });
    try testing.expect(result == .float);
    try testing.expectEqual(val, result.float);
    result.deinit(testing.allocator);
}

test "bytes round-trip" {
    const data = try testing.allocator.alloc(u8, 5);
    @memcpy(data, &[5]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x01 });
    defer testing.allocator.free(data);

    var result = try roundTrip(testing.allocator, TypedValue{ .bytes = data });
    try testing.expect(result == .bytes);
    try testing.expectEqualSlices(u8, data, result.bytes);
    result.deinit(testing.allocator);
}

test "text round-trip" {
    const text = "hello foldb";
    var result = try roundTrip(testing.allocator, TypedValue{ .text = text });
    try testing.expect(result == .text);
    try testing.expectEqualStrings(text, result.text);
    result.deinit(testing.allocator);
}

test "Cursor basics" {
    const data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var cur = Cursor{ .data = &data };

    try testing.expectEqual(@as(u8, 1), cur.readU8());
    try testing.expectEqual(@as(u16, std.mem.readInt(u16, &.{ 2, 3 }, .little)), cur.readU16Le());
    try testing.expectEqual(@as(u32, std.mem.readInt(u32, &.{ 4, 5, 6, 7 }, .little)), cur.readU32Le());
    try testing.expectEqual(@as(usize, 1), cur.remaining());
    try testing.expectEqual(@as(u8, 8), cur.readU8());
    try testing.expectEqual(@as(usize, 0), cur.remaining());

    try testing.expectError(error.EndOfStream, cur.readU8());
    try testing.expectError(error.EndOfStream, cur.readU64Le());
}

test "Cursor readSlice" {
    const data = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
    var cur = Cursor{ .data = &data };
    const slice = try cur.readSlice(3);
    try testing.expectEqualStrings("abc", slice);
    try testing.expectEqual(@as(usize, 2), cur.remaining());
}

test "Cursor readLenPrefixedAlloc" {
    // u32 length prefix (4 bytes: 0,0,0,3) + 3 bytes payload
    const data = [_]u8{ 3, 0, 0, 0, 'a', 'b', 'c' };
    var cur = Cursor{ .data = &data };
    const slice = try cur.readLenPrefixedAlloc(testing.allocator);
    defer testing.allocator.free(slice);
    try testing.expectEqualStrings("abc", slice);
}

test "Cursor readU8LenPrefixedAlloc" {
    const data = [_]u8{ 3, 'a', 'b', 'c', 'd', 'e' };
    var cur = Cursor{ .data = &data };
    const slice = try cur.readU8LenPrefixedAlloc(testing.allocator);
    defer testing.allocator.free(slice);
    try testing.expectEqualStrings("abc", slice);
    try testing.expectEqual(@as(usize, 2), cur.remaining());
}
