/// TypedValue encode/decode for the FoldDB wire protocol.
/// All integers are little-endian; UUID is big-endian (RFC 4122 exception).
const std = @import("std");

// ---- supporting types ----

pub const Decimal = struct {
    scale: u8,
    coefficient: i128,
};

pub const VectorElementType = enum(u8) {
    f32 = 0x00,
    f64 = 0x01,
    f16 = 0x02,
    bf16 = 0x03,
    int8 = 0x04,
    int16 = 0x05,
    _,

    pub fn byteSize(self: VectorElementType) usize {
        return switch (self) {
            .f32 => 4,
            .f64 => 8,
            .f16 => 2,
            .bf16 => 2,
            .int8 => 1,
            .int16 => 2,
            _ => 0,
        };
    }
};

pub const Vector = struct {
    element_type: VectorElementType,
    dim: u16,
    /// Raw LE bytes: dim * element_type.byteSize(). Caller-owned.
    data: []const u8,
};

pub const StructField = struct {
    name: []const u8,
    value: TypedValue,
};

pub const MapEntry = struct {
    key: TypedValue,
    value: TypedValue,
};

pub const ColumnDesc = struct {
    name: []const u8,
    type_tag: u8,
    nullable: bool,
};

/// Wire-layer typed value. Variable-length payloads (string, bytes, json, vector, array,
/// struct_val, map) are caller-owned slices; call deinit() to free recursively.
pub const TypedValue = union(enum) {
    null_val: void,
    bool_val: bool,
    int8: i8,
    int16: i16,
    int32: i32,
    int64: i64,
    uint8: u8,
    uint16: u16,
    uint32: u32,
    uint64: u64,
    float32: f32,
    float64: f64,
    decimal: Decimal,
    string: []const u8,
    bytes: []const u8,
    uuid: [16]u8,
    timestamp: i64,
    interval_months: i32,
    interval_micros: i64,
    json: []const u8,
    vector: Vector,
    array: []const TypedValue,
    struct_val: []const StructField,
    map: []const MapEntry,

    /// Recursively free all owned heap memory.
    pub fn deinit(self: TypedValue, alloc: std.mem.Allocator) void {
        switch (self) {
            .string, .bytes, .json => |s| alloc.free(s),
            .vector => |v| alloc.free(v.data),
            .array => |arr| {
                for (arr) |item| item.deinit(alloc);
                alloc.free(arr);
            },
            .struct_val => |fields| {
                for (fields) |f| {
                    alloc.free(f.name);
                    f.value.deinit(alloc);
                }
                alloc.free(fields);
            },
            .map => |entries| {
                for (entries) |e| {
                    e.key.deinit(alloc);
                    e.value.deinit(alloc);
                }
                alloc.free(entries);
            },
            else => {},
        }
    }
};

// ---- type tag constants (match wire spec §7.2) ----
pub const TAG_NULL: u8 = 0x00;
pub const TAG_BOOL: u8 = 0x01;
pub const TAG_INT8: u8 = 0x02;
pub const TAG_INT16: u8 = 0x03;
pub const TAG_INT32: u8 = 0x04;
pub const TAG_INT64: u8 = 0x05;
pub const TAG_UINT8: u8 = 0x06;
pub const TAG_UINT16: u8 = 0x07;
pub const TAG_UINT32: u8 = 0x08;
pub const TAG_UINT64: u8 = 0x09;
pub const TAG_FLOAT32: u8 = 0x0A;
pub const TAG_FLOAT64: u8 = 0x0B;
pub const TAG_DECIMAL: u8 = 0x0C;
pub const TAG_STRING: u8 = 0x0D;
pub const TAG_BYTES: u8 = 0x0E;
pub const TAG_UUID: u8 = 0x0F;
pub const TAG_TIMESTAMP: u8 = 0x10;
pub const TAG_INTERVAL_MONTHS: u8 = 0x11;
pub const TAG_INTERVAL_MICROS: u8 = 0x12;
pub const TAG_JSON: u8 = 0x13;
pub const TAG_VECTOR: u8 = 0x14;
pub const TAG_ARRAY: u8 = 0x15;
pub const TAG_STRUCT: u8 = 0x16;
pub const TAG_MAP: u8 = 0x17;

// ---- cursor for decoding ----

pub const Cursor = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) Cursor {
        return .{ .data = data, .pos = 0 };
    }

    pub fn remaining(self: *const Cursor) usize {
        return self.data.len - self.pos;
    }

    pub fn readU8(self: *Cursor) !u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEof;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }

    pub fn readU16Le(self: *Cursor) !u16 {
        if (self.pos + 2 > self.data.len) return error.UnexpectedEof;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }

    pub fn readU32Le(self: *Cursor) !u32 {
        if (self.pos + 4 > self.data.len) return error.UnexpectedEof;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    pub fn readU64Le(self: *Cursor) !u64 {
        if (self.pos + 8 > self.data.len) return error.UnexpectedEof;
        const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }

    pub fn readI8(self: *Cursor) !i8 {
        return @bitCast(try self.readU8());
    }

    pub fn readI16Le(self: *Cursor) !i16 {
        return @bitCast(try self.readU16Le());
    }

    pub fn readI32Le(self: *Cursor) !i32 {
        return @bitCast(try self.readU32Le());
    }

    pub fn readI64Le(self: *Cursor) !i64 {
        return @bitCast(try self.readU64Le());
    }

    pub fn readI128Le(self: *Cursor) !i128 {
        if (self.pos + 16 > self.data.len) return error.UnexpectedEof;
        const v = std.mem.readInt(i128, self.data[self.pos..][0..16], .little);
        self.pos += 16;
        return v;
    }

    pub fn readF32Le(self: *Cursor) !f32 {
        const bits = try self.readU32Le();
        return @bitCast(bits);
    }

    pub fn readF64Le(self: *Cursor) !f64 {
        const bits = try self.readU64Le();
        return @bitCast(bits);
    }

    /// Read n bytes as a slice into the underlying buffer (zero-copy, not owned).
    pub fn readSlice(self: *Cursor, n: usize) ![]const u8 {
        if (self.pos + n > self.data.len) return error.UnexpectedEof;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    /// Read a u32-length-prefixed byte string and dupe into alloc-owned memory.
    pub fn readLenPrefixedAlloc(self: *Cursor, alloc: std.mem.Allocator) ![]u8 {
        const len = try self.readU32Le();
        const raw = try self.readSlice(len);
        return alloc.dupe(u8, raw);
    }

    /// Read a u8-length-prefixed byte string and dupe into alloc-owned memory.
    pub fn readU8LenPrefixedAlloc(self: *Cursor, alloc: std.mem.Allocator) ![]u8 {
        const len = try self.readU8();
        const raw = try self.readSlice(len);
        return alloc.dupe(u8, raw);
    }

    /// Read 16 bytes as a fixed-size array.
    pub fn readBytes16(self: *Cursor) ![16]u8 {
        if (self.pos + 16 > self.data.len) return error.UnexpectedEof;
        var arr: [16]u8 = undefined;
        @memcpy(&arr, self.data[self.pos..][0..16]);
        self.pos += 16;
        return arr;
    }
};

// ---- encode helpers ----

fn appendU8(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u8) !void {
    try out.append(alloc, v);
}

fn appendU16Le(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .little);
    try out.appendSlice(alloc, &buf);
}

fn appendU32Le(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try out.appendSlice(alloc, &buf);
}

fn appendU64Le(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    try out.appendSlice(alloc, &buf);
}

fn appendI8(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: i8) !void {
    try out.append(alloc, @bitCast(v));
}

fn appendI16Le(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: i16) !void {
    return appendU16Le(out, alloc, @bitCast(v));
}

fn appendI32Le(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: i32) !void {
    return appendU32Le(out, alloc, @bitCast(v));
}

fn appendI64Le(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: i64) !void {
    return appendU64Le(out, alloc, @bitCast(v));
}

fn appendI128Le(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: i128) !void {
    var buf: [16]u8 = undefined;
    std.mem.writeInt(i128, &buf, v, .little);
    try out.appendSlice(alloc, &buf);
}

fn appendF32Le(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: f32) !void {
    return appendU32Le(out, alloc, @bitCast(v));
}

fn appendF64Le(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: f64) !void {
    return appendU64Le(out, alloc, @bitCast(v));
}

fn appendU32LenPrefixed(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, data: []const u8) !void {
    try appendU32Le(out, alloc, @intCast(data.len));
    try out.appendSlice(alloc, data);
}

fn appendU8LenPrefixed(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, data: []const u8) !void {
    try appendU8(out, alloc, @intCast(data.len));
    try out.appendSlice(alloc, data);
}

// ---- TypedValue encode ----

pub fn encode(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: TypedValue) !void {
    switch (v) {
        .null_val => try appendU8(out, alloc, TAG_NULL),
        .bool_val => |b| {
            try appendU8(out, alloc, TAG_BOOL);
            try appendU8(out, alloc, if (b) 1 else 0);
        },
        .int8 => |n| {
            try appendU8(out, alloc, TAG_INT8);
            try appendI8(out, alloc, n);
        },
        .int16 => |n| {
            try appendU8(out, alloc, TAG_INT16);
            try appendI16Le(out, alloc, n);
        },
        .int32 => |n| {
            try appendU8(out, alloc, TAG_INT32);
            try appendI32Le(out, alloc, n);
        },
        .int64 => |n| {
            try appendU8(out, alloc, TAG_INT64);
            try appendI64Le(out, alloc, n);
        },
        .uint8 => |n| {
            try appendU8(out, alloc, TAG_UINT8);
            try appendU8(out, alloc, n);
        },
        .uint16 => |n| {
            try appendU8(out, alloc, TAG_UINT16);
            try appendU16Le(out, alloc, n);
        },
        .uint32 => |n| {
            try appendU8(out, alloc, TAG_UINT32);
            try appendU32Le(out, alloc, n);
        },
        .uint64 => |n| {
            try appendU8(out, alloc, TAG_UINT64);
            try appendU64Le(out, alloc, n);
        },
        .float32 => |f| {
            try appendU8(out, alloc, TAG_FLOAT32);
            try appendF32Le(out, alloc, f);
        },
        .float64 => |f| {
            try appendU8(out, alloc, TAG_FLOAT64);
            try appendF64Le(out, alloc, f);
        },
        .decimal => |d| {
            try appendU8(out, alloc, TAG_DECIMAL);
            try appendU8(out, alloc, d.scale);
            try appendI128Le(out, alloc, d.coefficient);
        },
        .string => |s| {
            try appendU8(out, alloc, TAG_STRING);
            try appendU32LenPrefixed(out, alloc, s);
        },
        .bytes => |b| {
            try appendU8(out, alloc, TAG_BYTES);
            try appendU32LenPrefixed(out, alloc, b);
        },
        .uuid => |u| {
            try appendU8(out, alloc, TAG_UUID);
            try out.appendSlice(alloc, &u); // RFC 4122 BE — stored as-is
        },
        .timestamp => |ts| {
            try appendU8(out, alloc, TAG_TIMESTAMP);
            try appendI64Le(out, alloc, ts);
        },
        .interval_months => |m| {
            try appendU8(out, alloc, TAG_INTERVAL_MONTHS);
            try appendI32Le(out, alloc, m);
        },
        .interval_micros => |us| {
            try appendU8(out, alloc, TAG_INTERVAL_MICROS);
            try appendI64Le(out, alloc, us);
        },
        .json => |j| {
            try appendU8(out, alloc, TAG_JSON);
            try appendU32LenPrefixed(out, alloc, j);
        },
        .vector => |vec| {
            try appendU8(out, alloc, TAG_VECTOR);
            try appendU8(out, alloc, @intFromEnum(vec.element_type));
            try appendU16Le(out, alloc, vec.dim);
            try out.appendSlice(alloc, vec.data);
        },
        .array => |arr| {
            try appendU8(out, alloc, TAG_ARRAY);
            try appendU32Le(out, alloc, @intCast(arr.len));
            for (arr) |item| try encode(out, alloc, item);
        },
        .struct_val => |fields| {
            try appendU8(out, alloc, TAG_STRUCT);
            try appendU16Le(out, alloc, @intCast(fields.len));
            for (fields) |f| {
                try appendU8LenPrefixed(out, alloc, f.name);
                try encode(out, alloc, f.value);
            }
        },
        .map => |entries| {
            try appendU8(out, alloc, TAG_MAP);
            try appendU32Le(out, alloc, @intCast(entries.len));
            for (entries) |e| {
                try encode(out, alloc, e.key);
                try encode(out, alloc, e.value);
            }
        },
    }
}

// ---- TypedValue decode ----

pub fn decode(cur: *Cursor, alloc: std.mem.Allocator) !TypedValue {
    const tag = try cur.readU8();
    return switch (tag) {
        TAG_NULL => .null_val,
        TAG_BOOL => .{ .bool_val = (try cur.readU8()) != 0 },
        TAG_INT8 => .{ .int8 = try cur.readI8() },
        TAG_INT16 => .{ .int16 = try cur.readI16Le() },
        TAG_INT32 => .{ .int32 = try cur.readI32Le() },
        TAG_INT64 => .{ .int64 = try cur.readI64Le() },
        TAG_UINT8 => .{ .uint8 = try cur.readU8() },
        TAG_UINT16 => .{ .uint16 = try cur.readU16Le() },
        TAG_UINT32 => .{ .uint32 = try cur.readU32Le() },
        TAG_UINT64 => .{ .uint64 = try cur.readU64Le() },
        TAG_FLOAT32 => .{ .float32 = try cur.readF32Le() },
        TAG_FLOAT64 => .{ .float64 = try cur.readF64Le() },
        TAG_DECIMAL => blk: {
            const scale = try cur.readU8();
            if (scale > 38) return error.TypeError;
            const coeff = try cur.readI128Le();
            break :blk .{ .decimal = .{ .scale = scale, .coefficient = coeff } };
        },
        TAG_STRING => .{ .string = try cur.readLenPrefixedAlloc(alloc) },
        TAG_BYTES => .{ .bytes = try cur.readLenPrefixedAlloc(alloc) },
        TAG_UUID => .{ .uuid = try cur.readBytes16() },
        TAG_TIMESTAMP => .{ .timestamp = try cur.readI64Le() },
        TAG_INTERVAL_MONTHS => .{ .interval_months = try cur.readI32Le() },
        TAG_INTERVAL_MICROS => .{ .interval_micros = try cur.readI64Le() },
        TAG_JSON => .{ .json = try cur.readLenPrefixedAlloc(alloc) },
        TAG_VECTOR => blk: {
            const et_raw = try cur.readU8();
            const et_raw_enum: VectorElementType = @enumFromInt(et_raw);
            const et = switch (et_raw_enum) {
                .f32, .f64, .f16, .bf16, .int8, .int16 => et_raw_enum,
                _ => return error.ProtocolError,
            };
            const dim = try cur.readU16Le();
            const byte_count: usize = @as(usize, dim) * et.byteSize();
            const raw = try cur.readSlice(byte_count);
            const data = try alloc.dupe(u8, raw);
            break :blk .{ .vector = .{ .element_type = et, .dim = dim, .data = data } };
        },
        TAG_ARRAY => blk: {
            const count = try cur.readU32Le();
            const arr = try alloc.alloc(TypedValue, count);
            var decoded: u32 = 0;
            errdefer {
                for (arr[0..decoded]) |item| item.deinit(alloc);
                alloc.free(arr);
            }
            while (decoded < count) : (decoded += 1) {
                arr[decoded] = try decode(cur, alloc);
            }
            break :blk .{ .array = arr };
        },
        TAG_STRUCT => blk: {
            const count = try cur.readU16Le();
            const fields = try alloc.alloc(StructField, count);
            var decoded: u16 = 0;
            errdefer {
                for (fields[0..decoded]) |f| {
                    alloc.free(f.name);
                    f.value.deinit(alloc);
                }
                alloc.free(fields);
            }
            while (decoded < count) : (decoded += 1) {
                const name = try cur.readU8LenPrefixedAlloc(alloc);
                errdefer alloc.free(name);
                const value = try decode(cur, alloc);
                fields[decoded] = .{ .name = name, .value = value };
            }
            break :blk .{ .struct_val = fields };
        },
        TAG_MAP => blk: {
            const count = try cur.readU32Le();
            const entries = try alloc.alloc(MapEntry, count);
            var decoded: u32 = 0;
            errdefer {
                for (entries[0..decoded]) |e| {
                    e.key.deinit(alloc);
                    e.value.deinit(alloc);
                }
                alloc.free(entries);
            }
            while (decoded < count) : (decoded += 1) {
                const key = try decode(cur, alloc);
                if (key == .null_val) return error.ProtocolError;
                errdefer key.deinit(alloc);
                const value = try decode(cur, alloc);
                entries[decoded] = .{ .key = key, .value = value };
            }
            break :blk .{ .map = entries };
        },
        else => error.ProtocolError,
    };
}

// ---- ColumnDesc encode/decode ----

pub fn encodeColumnDesc(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, cd: ColumnDesc) !void {
    try appendU8LenPrefixed(out, alloc, cd.name);
    try appendU8(out, alloc, cd.type_tag);
    try appendU8(out, alloc, if (cd.nullable) 1 else 0);
}

pub fn decodeColumnDesc(cur: *Cursor, alloc: std.mem.Allocator) !ColumnDesc {
    const name = try cur.readU8LenPrefixedAlloc(alloc);
    errdefer alloc.free(name);
    const type_tag = try cur.readU8();
    const nullable_byte = try cur.readU8();
    return .{ .name = name, .type_tag = type_tag, .nullable = nullable_byte != 0 };
}

pub fn freeColumnDesc(cd: ColumnDesc, alloc: std.mem.Allocator) void {
    alloc.free(cd.name);
}
