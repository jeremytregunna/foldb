const std = @import("std");
const storage = @import("storage.zig");

const jp = storage.json_path;

test "json path extract top-level field" {
    const alloc = std.testing.allocator;
    const json = "{\"name\": \"alice\", \"age\": 30}";

    const name = try jp.extract(json, "$.name", alloc);
    defer if (name) |n| alloc.free(n);
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("\"alice\"", name.?);

    const age = try jp.extract(json, "$.age", alloc);
    defer if (age) |a| alloc.free(a);
    try std.testing.expect(age != null);
    try std.testing.expectEqualStrings("30", age.?);
}

test "json path extract nested field" {
    const alloc = std.testing.allocator;
    const json = "{\"user\": {\"city\": \"toronto\"}}";

    const city = try jp.extract(json, "$.user.city", alloc);
    defer if (city) |c| alloc.free(c);
    try std.testing.expect(city != null);
    try std.testing.expectEqualStrings("\"toronto\"", city.?);
}

test "json path missing field returns null" {
    const alloc = std.testing.allocator;
    const json = "{\"x\": 1}";
    const val = try jp.extract(json, "$.y", alloc);
    defer if (val) |v| alloc.free(v);
    try std.testing.expect(val == null);
}

test "json path normalize string value" {
    const alloc = std.testing.allocator;
    const norm = try jp.normalizeValue("\"hello world\"", alloc);
    defer alloc.free(norm);
    try std.testing.expectEqualStrings("hello world", norm);
}

test "json path normalize number value" {
    const alloc = std.testing.allocator;
    const norm = try jp.normalizeValue("42", alloc);
    defer alloc.free(norm);
    try std.testing.expectEqualStrings("42", norm);
}

test "json path normalize boolean" {
    const alloc = std.testing.allocator;
    const norm = try jp.normalizeValue("true", alloc);
    defer alloc.free(norm);
    try std.testing.expectEqualStrings("true", norm);
}

test "json path invalid path returns error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidPath, jp.extract("{}", "no-dollar", alloc));
}
