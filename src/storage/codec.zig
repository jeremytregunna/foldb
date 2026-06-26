/// Simple key-value block codec: encodes/decodes opaque []u8 value slices.
const std = @import("std");

/// Encode a slice of []const u8 values as: [len32 + data] per value.
pub fn encode(values: []const []const u8, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    for (values) |v| {
        const len: u32 = @intCast(v.len);
        try out.appendNTimes(alloc, 0, 4);
        const base = out.items.len - 4;
        std.mem.writeInt(u32, out.items[base..][0..4], len, .little);
        try out.appendSlice(alloc, v);
    }
}

/// Decode a values section: read row_count values of format [len32 + data].
pub fn decode(data: []const u8, row_count: usize, alloc: std.mem.Allocator) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |v| alloc.free(v);
        result.deinit(alloc);
    }
    var pos: usize = 0;
    for (0..row_count) |_| {
        if (pos + 4 > data.len) return error.InvalidData;
        const len: u32 = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        if (pos + len > data.len) return error.InvalidData;
        const val = data[pos .. pos + len];
        pos += len;
        const copied = try alloc.dupe(u8, val);
        errdefer alloc.free(copied);
        try result.append(alloc, copied);
    }
    return result.toOwnedSlice(alloc);
}
