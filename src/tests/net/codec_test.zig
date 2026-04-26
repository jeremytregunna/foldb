/// Tests for wire protocol TypedValue encode/decode round-trips.
const std = @import("std");
const testing = std.testing;
const codec = @import("codec.zig");

const TypedValue = codec.TypedValue;
const Cursor = codec.Cursor;
const Vector = codec.Vector;
const VectorElementType = codec.VectorElementType;
const StructField = codec.StructField;
const MapEntry = codec.MapEntry;

fn roundTrip(alloc: std.mem.Allocator, v: TypedValue) !TypedValue {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try codec.encode(&out, alloc, v);
    var cur = Cursor.init(out.items);
    return codec.decode(&cur, alloc);
}

test "Null round-trip" {
    const result = try roundTrip(testing.allocator, .null_val);
    try testing.expect(result == .null_val);
}

test "Bool round-trip" {
    const t = try roundTrip(testing.allocator, .{ .bool_val = true });
    try testing.expect(t.bool_val == true);
    const f = try roundTrip(testing.allocator, .{ .bool_val = false });
    try testing.expect(f.bool_val == false);
}

test "Int8 round-trip" {
    const v = try roundTrip(testing.allocator, .{ .int8 = -42 });
    try testing.expectEqual(@as(i8, -42), v.int8);
}

test "Int16 round-trip" {
    const v = try roundTrip(testing.allocator, .{ .int16 = -1000 });
    try testing.expectEqual(@as(i16, -1000), v.int16);
}

test "Int32 round-trip" {
    const v = try roundTrip(testing.allocator, .{ .int32 = -100_000 });
    try testing.expectEqual(@as(i32, -100_000), v.int32);
}

test "Int64 round-trip" {
    const v = try roundTrip(testing.allocator, .{ .int64 = -1_000_000_000_000 });
    try testing.expectEqual(@as(i64, -1_000_000_000_000), v.int64);
}

test "UInt8 round-trip" {
    const v = try roundTrip(testing.allocator, .{ .uint8 = 255 });
    try testing.expectEqual(@as(u8, 255), v.uint8);
}

test "UInt16 round-trip" {
    const v = try roundTrip(testing.allocator, .{ .uint16 = 65535 });
    try testing.expectEqual(@as(u16, 65535), v.uint16);
}

test "UInt32 round-trip" {
    const v = try roundTrip(testing.allocator, .{ .uint32 = 0xDEAD_BEEF });
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), v.uint32);
}

test "UInt64 round-trip" {
    const v = try roundTrip(testing.allocator, .{ .uint64 = 0xCAFE_BABE_DEAD_BEEF });
    try testing.expectEqual(@as(u64, 0xCAFE_BABE_DEAD_BEEF), v.uint64);
}

test "Float32 round-trip" {
    const v = try roundTrip(testing.allocator, .{ .float32 = 3.14 });
    try testing.expectApproxEqRel(@as(f32, 3.14), v.float32, 1e-5);
}

test "Float64 round-trip" {
    const v = try roundTrip(testing.allocator, .{ .float64 = 2.718281828459045 });
    try testing.expectApproxEqRel(@as(f64, 2.718281828459045), v.float64, 1e-12);
}

test "Decimal round-trip" {
    const v = try roundTrip(testing.allocator, .{ .decimal = .{ .scale = 4, .coefficient = 123456789 } });
    try testing.expectEqual(@as(u8, 4), v.decimal.scale);
    try testing.expectEqual(@as(i128, 123456789), v.decimal.coefficient);
}

test "Decimal scale > 38 → TypeError" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try codec.encode(&out, testing.allocator, .{ .decimal = .{ .scale = 39, .coefficient = 1 } });
    var cur = Cursor.init(out.items);
    try testing.expectError(error.TypeError, codec.decode(&cur, testing.allocator));
}

test "String round-trip" {
    const v = try roundTrip(testing.allocator, .{ .string = "hello, world" });
    defer testing.allocator.free(v.string);
    try testing.expectEqualStrings("hello, world", v.string);
}

test "Empty string round-trip" {
    const v = try roundTrip(testing.allocator, .{ .string = "" });
    defer testing.allocator.free(v.string);
    try testing.expectEqualStrings("", v.string);
}

test "Bytes round-trip" {
    const data = [_]u8{ 0x00, 0x01, 0xFF, 0xFE };
    const v = try roundTrip(testing.allocator, .{ .bytes = &data });
    defer testing.allocator.free(v.bytes);
    try testing.expectEqualSlices(u8, &data, v.bytes);
}

test "UUID round-trip (BE preserved)" {
    const uuid = [16]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 };
    const v = try roundTrip(testing.allocator, .{ .uuid = uuid });
    try testing.expectEqualSlices(u8, &uuid, &v.uuid);
}

test "Timestamp round-trip" {
    const v = try roundTrip(testing.allocator, .{ .timestamp = 1_700_000_000_000_000 });
    try testing.expectEqual(@as(i64, 1_700_000_000_000_000), v.timestamp);
}

test "IntervalMonths round-trip" {
    const v = try roundTrip(testing.allocator, .{ .interval_months = -12 });
    try testing.expectEqual(@as(i32, -12), v.interval_months);
}

test "IntervalMicros round-trip" {
    const v = try roundTrip(testing.allocator, .{ .interval_micros = 3_600_000_000 });
    try testing.expectEqual(@as(i64, 3_600_000_000), v.interval_micros);
}

test "JSON round-trip" {
    const v = try roundTrip(testing.allocator, .{ .json = "{\"key\":42}" });
    defer testing.allocator.free(v.json);
    try testing.expectEqualStrings("{\"key\":42}", v.json);
}

test "Vector f32 round-trip" {
    const data = [_]u8{
        0x00, 0x00, 0x80, 0x3F, // 1.0f32 LE
        0x00, 0x00, 0x00, 0x40,
    }; // 2.0f32 LE
    const vec = Vector{ .element_type = .f32, .dim = 2, .data = &data };
    const v = try roundTrip(testing.allocator, .{ .vector = vec });
    defer testing.allocator.free(v.vector.data);
    try testing.expectEqual(VectorElementType.f32, v.vector.element_type);
    try testing.expectEqual(@as(u16, 2), v.vector.dim);
    try testing.expectEqualSlices(u8, &data, v.vector.data);
}

test "Array round-trip" {
    const items = [_]TypedValue{
        .{ .int32 = 1 },
        .{ .int32 = 2 },
        .{ .int32 = 3 },
    };
    const v = try roundTrip(testing.allocator, .{ .array = &items });
    defer {
        for (v.array) |item| item.deinit(testing.allocator);
        testing.allocator.free(v.array);
    }
    try testing.expectEqual(@as(usize, 3), v.array.len);
    try testing.expectEqual(@as(i32, 1), v.array[0].int32);
    try testing.expectEqual(@as(i32, 2), v.array[1].int32);
    try testing.expectEqual(@as(i32, 3), v.array[2].int32);
}

test "Struct round-trip" {
    const fields = [_]StructField{
        .{ .name = "x", .value = .{ .float64 = 1.5 } },
        .{ .name = "y", .value = .{ .float64 = 2.5 } },
    };
    const v = try roundTrip(testing.allocator, .{ .struct_val = &fields });
    defer {
        for (v.struct_val) |f| {
            testing.allocator.free(f.name);
            f.value.deinit(testing.allocator);
        }
        testing.allocator.free(v.struct_val);
    }
    try testing.expectEqual(@as(usize, 2), v.struct_val.len);
    try testing.expectEqualStrings("x", v.struct_val[0].name);
    try testing.expectApproxEqRel(@as(f64, 1.5), v.struct_val[0].value.float64, 1e-12);
    try testing.expectEqualStrings("y", v.struct_val[1].name);
}

test "Map round-trip" {
    const entries = [_]MapEntry{
        .{ .key = .{ .string = "a" }, .value = .{ .int64 = 100 } },
    };
    const v = try roundTrip(testing.allocator, .{ .map = &entries });
    defer {
        for (v.map) |e| {
            e.key.deinit(testing.allocator);
            e.value.deinit(testing.allocator);
        }
        testing.allocator.free(v.map);
    }
    try testing.expectEqual(@as(usize, 1), v.map.len);
    try testing.expectEqualStrings("a", v.map[0].key.string);
    try testing.expectEqual(@as(i64, 100), v.map[0].value.int64);
}

test "Map with null key → ProtocolError" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    // Manually encode a map with a null key
    try out.append(testing.allocator, codec.TAG_MAP);
    var count_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_buf, 1, .little);
    try out.appendSlice(testing.allocator, &count_buf);
    try out.append(testing.allocator, codec.TAG_NULL); // null key
    try out.append(testing.allocator, codec.TAG_INT32);
    var val_buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &val_buf, 42, .little);
    try out.appendSlice(testing.allocator, &val_buf);

    var cur = Cursor.init(out.items);
    try testing.expectError(error.ProtocolError, codec.decode(&cur, testing.allocator));
}

test "Unknown type tag → ProtocolError" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try out.append(testing.allocator, 0x99); // unknown tag
    var cur = Cursor.init(out.items);
    try testing.expectError(error.ProtocolError, codec.decode(&cur, testing.allocator));
}

test "Truncated payload → UnexpectedEof" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try out.append(testing.allocator, codec.TAG_INT64);
    // Only 3 bytes instead of 8
    try out.appendSlice(testing.allocator, &[_]u8{ 0x01, 0x02, 0x03 });
    var cur = Cursor.init(out.items);
    try testing.expectError(error.UnexpectedEof, codec.decode(&cur, testing.allocator));
}

test "ColumnDesc encode/decode round-trip" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    const cd = codec.ColumnDesc{ .name = "user_id", .type_tag = codec.TAG_INT64, .nullable = false };
    try codec.encodeColumnDesc(&out, testing.allocator, cd);
    var cur = Cursor.init(out.items);
    const decoded = try codec.decodeColumnDesc(&cur, testing.allocator);
    defer codec.freeColumnDesc(decoded, testing.allocator);
    try testing.expectEqualStrings("user_id", decoded.name);
    try testing.expectEqual(codec.TAG_INT64, decoded.type_tag);
    try testing.expect(!decoded.nullable);
}

test "TypedValue.deinit is safe for scalar types" {
    // Should not crash — scalars have no heap allocations
    const v1: TypedValue = .{ .int64 = 42 };
    v1.deinit(testing.allocator);
    const v2: TypedValue = .null_val;
    v2.deinit(testing.allocator);
    const v3: TypedValue = .{ .uuid = [_]u8{0} ** 16 };
    v3.deinit(testing.allocator);
}
