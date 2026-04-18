/// Encode/decode f32 vectors as packed little-endian bytes.
const std = @import("std");

pub const Error = error{ InvalidVectorData, OutOfMemory };

/// Encode a slice of f32 as packed little-endian bytes. Caller owns the result.
pub fn encode(vec: []const f32, alloc: std.mem.Allocator) ![]u8 {
    const bytes = try alloc.alloc(u8, vec.len * 4);
    for (vec, 0..) |v, i| {
        std.mem.writeInt(u32, bytes[i * 4 ..][0..4], @bitCast(v), .little);
    }
    return bytes;
}

/// Decode packed little-endian bytes to f32 slice. Caller owns the result.
pub fn decode(data: []const u8, alloc: std.mem.Allocator) ![]f32 {
    if (data.len % 4 != 0) return error.InvalidVectorData;
    const dim = data.len / 4;
    const result = try alloc.alloc(f32, dim);
    for (0..dim) |i| {
        const bits = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
        result[i] = @bitCast(bits);
    }
    return result;
}

/// Return the number of f32 elements encoded in data.
pub fn dimension(data: []const u8) u32 {
    return @intCast(data.len / 4);
}
