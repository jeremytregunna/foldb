/// Simple typed value encode/decode for the FoldDB wire protocol.
/// All integers are little-endian.
const std = @import("std");

const assert = std.debug.assert;

// ─── Primitive value types ───

pub const TypedValue = union(enum) {
    null: void,
    bool: bool,
    integer: i64,
    float: f64,
    bytes: []const u8,
    text: []const u8,

    pub fn deinit(self: TypedValue, alloc: std.mem.Allocator) void {
        switch (self) {
            .null, .bool, .integer, .float => {},
            .bytes => |v| alloc.free(v),
            .text => |v| alloc.free(v),
        }
    }
};

// ─── Encode helpers (pub so messages.zig can use them) ───

pub fn appendU8(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u8) !void {
    try out.append(alloc, v);
}

pub fn appendU16Le(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u16) !void {
    const buf = std.mem.toBytes(v);
    try out.appendSlice(alloc, &buf);
}

pub fn appendU32Le(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u32) !void {
    const buf = std.mem.toBytes(v);
    try out.appendSlice(alloc, &buf);
}

pub fn appendU64Le(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u64) !void {
    const buf = std.mem.toBytes(v);
    try out.appendSlice(alloc, &buf);
}

// ─── TypedValue encode/decode ───

pub fn encode(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: TypedValue) !void {
    switch (v) {
        .null => try appendU8(out, alloc, 0x00),
        .bool => |b| try appendU8(out, alloc, if (b) 0x01 else 0x02),
        .integer => |i| {
            try appendU8(out, alloc, 0x10);
            const buf = std.mem.toBytes(i);
            try out.appendSlice(alloc, &buf);
        },
        .float => |f| {
            try appendU8(out, alloc, 0x20);
            const buf = std.mem.toBytes(f);
            try out.appendSlice(alloc, &buf);
        },
        .bytes => |b| {
            assert(b.len <= std.math.maxInt(u32));
            try appendU8(out, alloc, 0x30);
            try appendU32Le(out, alloc, @intCast(b.len));
            try out.appendSlice(alloc, b);
        },
        .text => |t| {
            assert(t.len <= std.math.maxInt(u32));
            try appendU8(out, alloc, 0x40);
            try appendU32Le(out, alloc, @intCast(t.len));
            try out.appendSlice(alloc, t);
        },
    }
}

pub fn decode(cur: *Cursor, alloc: std.mem.Allocator) !TypedValue {
    const tag = try cur.readU8();
    return switch (tag) {
        0x00 => .{ .null = {} },
        0x01 => .{ .bool = true },
        0x02 => .{ .bool = false },
        0x10 => .{ .integer = try cur.readI64Le() },
        0x20 => .{ .float = try cur.readF64Le() },
        0x30 => .{ .bytes = try cur.readLenPrefixedAlloc(alloc) },
        0x40 => .{ .text = try cur.readLenPrefixedAlloc(alloc) },
        else => return error.ProtocolError,
    };
}

// ─── Cursor ───

/// Simple binary cursor over a byte slice.
pub const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn remaining(self: *const Cursor) usize {
        return self.data.len - self.pos;
    }

    pub fn readU8(self: *Cursor) !u8 {
        if (self.remaining() < 1) return error.EndOfStream;
        defer self.pos += 1;
        return self.data[self.pos];
    }

    pub fn readU16Le(self: *Cursor) !u16 {
        if (self.remaining() < 2) return error.EndOfStream;
        defer self.pos += 2;
        return std.mem.bytesToValue(u16, self.data[self.pos .. self.pos + 2]);
    }

    pub fn readU32Le(self: *Cursor) !u32 {
        if (self.remaining() < 4) return error.EndOfStream;
        defer self.pos += 4;
        return std.mem.bytesToValue(u32, self.data[self.pos .. self.pos + 4]);
    }

    pub fn readU64Le(self: *Cursor) !u64 {
        if (self.remaining() < 8) return error.EndOfStream;
        defer self.pos += 8;
        return std.mem.bytesToValue(u64, self.data[self.pos .. self.pos + 8]);
    }

    pub fn readI64Le(self: *Cursor) !i64 {
        if (self.remaining() < 8) return error.EndOfStream;
        defer self.pos += 8;
        return std.mem.bytesToValue(i64, self.data[self.pos .. self.pos + 8]);
    }

    pub fn readF64Le(self: *Cursor) !f64 {
        if (self.remaining() < 8) return error.EndOfStream;
        defer self.pos += 8;
        return std.mem.bytesToValue(f64, self.data[self.pos .. self.pos + 8]);
    }

    pub fn readSlice(self: *Cursor, len: usize) ![]const u8 {
        if (self.remaining() < len) return error.EndOfStream;
        defer self.pos += len;
        return self.data[self.pos .. self.pos + len];
    }

    /// Read a u32-length-prefixed slice (caller owns, must free).
    pub fn readLenPrefixedAlloc(self: *Cursor, alloc: std.mem.Allocator) ![]const u8 {
        const len = try self.readU32Le();
        const raw = try self.readSlice(len);
        return try alloc.dupe(u8, raw);
    }

    /// Read a u8-length-prefixed slice (caller owns, must free).
    pub fn readU8LenPrefixedAlloc(self: *Cursor, alloc: std.mem.Allocator) ![]const u8 {
        const len = try self.readU8();
        const raw = try self.readSlice(len);
        return try alloc.dupe(u8, raw);
    }
};
