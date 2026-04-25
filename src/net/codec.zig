/// TypedValue encode/decode for the FoldDB wire protocol.
/// All integers are little-endian; UUID is big-endian (RFC 4122 exception).
const std = @import("std");

const assert = std.debug.assert;

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

    pub fn byteSize(self: VectorElementType) u8 {
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

    /// Recursively free all owned heap memory (iterative — no recursion).
    pub fn deinit(self: TypedValue, alloc: std.mem.Allocator) void {
        deinitIterative(self, alloc);
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

/// Maximum nesting depth for array/struct/map values from the wire.
pub const MAX_DECODE_DEPTH: u8 = 16;
/// Maximum element count for array/map containers from the wire.
pub const MAX_CONTAINER_COUNT: u32 = 65535;

comptime {
    assert(MAX_DECODE_DEPTH > 0);
    assert(MAX_CONTAINER_COUNT <= std.math.maxInt(u32));
    assert(MAX_CONTAINER_COUNT <= std.math.maxInt(u16) * 2);
}

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

// ---- encode helpers (pub so messages.zig can import without duplication) ----

pub fn appendU8(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u8) !void {
    try out.append(alloc, v);
}

pub fn appendU16Le(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .little);
    try out.appendSlice(alloc, &buf);
}

pub fn appendU32Le(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try out.appendSlice(alloc, &buf);
}

pub fn appendU64Le(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u64) !void {
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
    assert(data.len <= std.math.maxInt(u32));
    try appendU32Le(out, alloc, @intCast(data.len));
    try out.appendSlice(alloc, data);
}

fn appendU8LenPrefixed(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, data: []const u8) !void {
    assert(data.len <= std.math.maxInt(u8));
    try appendU8(out, alloc, @intCast(data.len));
    try out.appendSlice(alloc, data);
}

// ---- iteration frame (shared by encode and deinit traversal) ----

/// Active container being iterated during encode or deinit.
const ContainerIter = struct {
    const Content = union(enum) {
        array: []const TypedValue,
        struct_fields: []const StructField,
        map: []const MapEntry,
    };
    content: Content,
    pos: u32,
    map_doing_value: bool,
};

// ---- TypedValue encode (iterative) ----

/// Encode root and all nested values into out. No recursion; uses an explicit
/// frame stack bounded by MAX_DECODE_DEPTH.
pub fn encode(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, root: TypedValue) !void {
    var frames: [MAX_DECODE_DEPTH]ContainerIter = undefined;
    var depth: u8 = 0;
    var current = root;
    while (true) {
        try encodeValue(out, alloc, current, &frames, &depth);
        var advanced = false;
        while (depth > 0) {
            if (try encodeFrameNext(out, alloc, &frames[depth - 1], &current)) {
                advanced = true;
                break;
            }
            depth -= 1;
        }
        if (!advanced) break;
    }
}

/// Encode one value. For containers, writes the wire header and pushes a frame
/// so the caller's loop can iterate children without recursion.
fn encodeValue(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    v: TypedValue,
    frames: *[MAX_DECODE_DEPTH]ContainerIter,
    depth: *u8,
) !void {
    switch (v) {
        .null_val => try appendU8(out, alloc, TAG_NULL),
        .bool_val => |b| { try appendU8(out, alloc, TAG_BOOL); try appendU8(out, alloc, if (b) 1 else 0); },
        .int8 => |n| { try appendU8(out, alloc, TAG_INT8); try appendI8(out, alloc, n); },
        .int16 => |n| { try appendU8(out, alloc, TAG_INT16); try appendI16Le(out, alloc, n); },
        .int32 => |n| { try appendU8(out, alloc, TAG_INT32); try appendI32Le(out, alloc, n); },
        .int64 => |n| { try appendU8(out, alloc, TAG_INT64); try appendI64Le(out, alloc, n); },
        .uint8 => |n| { try appendU8(out, alloc, TAG_UINT8); try appendU8(out, alloc, n); },
        .uint16 => |n| { try appendU8(out, alloc, TAG_UINT16); try appendU16Le(out, alloc, n); },
        .uint32 => |n| { try appendU8(out, alloc, TAG_UINT32); try appendU32Le(out, alloc, n); },
        .uint64 => |n| { try appendU8(out, alloc, TAG_UINT64); try appendU64Le(out, alloc, n); },
        .float32 => |f| { try appendU8(out, alloc, TAG_FLOAT32); try appendF32Le(out, alloc, f); },
        .float64 => |f| { try appendU8(out, alloc, TAG_FLOAT64); try appendF64Le(out, alloc, f); },
        .decimal => |d| {
            try appendU8(out, alloc, TAG_DECIMAL);
            try appendU8(out, alloc, d.scale);
            try appendI128Le(out, alloc, d.coefficient);
        },
        .string => |s| { try appendU8(out, alloc, TAG_STRING); try appendU32LenPrefixed(out, alloc, s); },
        .bytes => |b| { try appendU8(out, alloc, TAG_BYTES); try appendU32LenPrefixed(out, alloc, b); },
        .uuid => |u| { try appendU8(out, alloc, TAG_UUID); try out.appendSlice(alloc, &u); },
        .timestamp => |ts| { try appendU8(out, alloc, TAG_TIMESTAMP); try appendI64Le(out, alloc, ts); },
        .interval_months => |m| { try appendU8(out, alloc, TAG_INTERVAL_MONTHS); try appendI32Le(out, alloc, m); },
        .interval_micros => |us| { try appendU8(out, alloc, TAG_INTERVAL_MICROS); try appendI64Le(out, alloc, us); },
        .json => |j| { try appendU8(out, alloc, TAG_JSON); try appendU32LenPrefixed(out, alloc, j); },
        .vector => |vec| {
            try appendU8(out, alloc, TAG_VECTOR);
            try appendU8(out, alloc, @intFromEnum(vec.element_type));
            try appendU16Le(out, alloc, vec.dim);
            try out.appendSlice(alloc, vec.data);
        },
        .array => |arr| {
            assert(depth.* < MAX_DECODE_DEPTH);
            assert(arr.len <= MAX_CONTAINER_COUNT);
            try appendU8(out, alloc, TAG_ARRAY);
            try appendU32Le(out, alloc, @intCast(arr.len));
            if (arr.len > 0) {
                frames[depth.*] = .{ .content = .{ .array = arr }, .pos = 0, .map_doing_value = false };
                depth.* += 1;
            }
        },
        .struct_val => |fields| {
            assert(depth.* < MAX_DECODE_DEPTH);
            assert(fields.len <= std.math.maxInt(u16));
            try appendU8(out, alloc, TAG_STRUCT);
            try appendU16Le(out, alloc, @intCast(fields.len));
            if (fields.len > 0) {
                frames[depth.*] = .{ .content = .{ .struct_fields = fields }, .pos = 0, .map_doing_value = false };
                depth.* += 1;
            }
        },
        .map => |entries| {
            assert(depth.* < MAX_DECODE_DEPTH);
            assert(entries.len <= MAX_CONTAINER_COUNT);
            try appendU8(out, alloc, TAG_MAP);
            try appendU32Le(out, alloc, @intCast(entries.len));
            if (entries.len > 0) {
                frames[depth.*] = .{ .content = .{ .map = entries }, .pos = 0, .map_doing_value = false };
                depth.* += 1;
            }
        },
    }
}

/// Advance an encode frame. Writes struct field name prefix as a side effect.
/// Returns true and sets out_val when there is a next value to encode;
/// returns false when the frame is exhausted.
fn encodeFrameNext(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    frame: *ContainerIter,
    out_val: *TypedValue,
) !bool {
    switch (frame.content) {
        .array => |items| {
            if (frame.pos >= items.len) return false;
            out_val.* = items[frame.pos];
            frame.pos += 1;
            return true;
        },
        .struct_fields => |fields| {
            if (frame.pos >= fields.len) return false;
            try appendU8LenPrefixed(out, alloc, fields[frame.pos].name);
            out_val.* = fields[frame.pos].value;
            frame.pos += 1;
            return true;
        },
        .map => |entries| {
            if (frame.pos >= entries.len) return false;
            if (!frame.map_doing_value) {
                out_val.* = entries[frame.pos].key;
                frame.map_doing_value = true;
            } else {
                out_val.* = entries[frame.pos].value;
                frame.map_doing_value = false;
                frame.pos += 1;
            }
            return true;
        },
    }
}

// ---- TypedValue deinit (iterative) ----

/// Iterative deinit: push a ContainerIter frame for containers and process
/// children without recursion, bounded by MAX_DECODE_DEPTH.
fn deinitIterative(root: TypedValue, alloc: std.mem.Allocator) void {
    var frames: [MAX_DECODE_DEPTH]ContainerIter = undefined;
    var depth: u8 = 0;
    var current = root;
    while (true) {
        deinitOne(current, alloc, &frames, &depth);
        var advanced = false;
        while (depth > 0) {
            if (deinitFrameNext(&frames[depth - 1], alloc, &current)) {
                advanced = true;
                break;
            }
            deinitFrameSlice(&frames[depth - 1], alloc);
            depth -= 1;
        }
        if (!advanced) break;
    }
}

/// Free the immediate owned memory of v. For containers, push a frame so
/// children are freed by the caller's loop; empty containers freed immediately.
fn deinitOne(
    v: TypedValue,
    alloc: std.mem.Allocator,
    frames: *[MAX_DECODE_DEPTH]ContainerIter,
    depth: *u8,
) void {
    switch (v) {
        .string, .bytes, .json => |s| alloc.free(s),
        .vector => |vec| alloc.free(vec.data),
        .array => |arr| {
            if (arr.len == 0) { alloc.free(arr); return; }
            assert(depth.* < MAX_DECODE_DEPTH);
            frames[depth.*] = .{ .content = .{ .array = arr }, .pos = 0, .map_doing_value = false };
            depth.* += 1;
        },
        .struct_val => |fields| {
            if (fields.len == 0) { alloc.free(fields); return; }
            assert(depth.* < MAX_DECODE_DEPTH);
            frames[depth.*] = .{ .content = .{ .struct_fields = fields }, .pos = 0, .map_doing_value = false };
            depth.* += 1;
        },
        .map => |entries| {
            if (entries.len == 0) { alloc.free(entries); return; }
            assert(depth.* < MAX_DECODE_DEPTH);
            frames[depth.*] = .{ .content = .{ .map = entries }, .pos = 0, .map_doing_value = false };
            depth.* += 1;
        },
        else => {},
    }
}

/// Return the next child of a deinit frame. Frees struct field names as a side
/// effect (names are plain slices, not TypedValue, so they don't recurse).
fn deinitFrameNext(frame: *ContainerIter, alloc: std.mem.Allocator, out: *TypedValue) bool {
    switch (frame.content) {
        .array => |arr| {
            if (frame.pos >= arr.len) return false;
            out.* = arr[frame.pos];
            frame.pos += 1;
            return true;
        },
        .struct_fields => |fields| {
            if (frame.pos >= fields.len) return false;
            alloc.free(fields[frame.pos].name);
            out.* = fields[frame.pos].value;
            frame.pos += 1;
            return true;
        },
        .map => |entries| {
            if (frame.pos >= entries.len) return false;
            if (!frame.map_doing_value) {
                out.* = entries[frame.pos].key;
                frame.map_doing_value = true;
            } else {
                out.* = entries[frame.pos].value;
                frame.map_doing_value = false;
                frame.pos += 1;
            }
            return true;
        },
    }
}

fn deinitFrameSlice(frame: *ContainerIter, alloc: std.mem.Allocator) void {
    switch (frame.content) {
        .array => |arr| alloc.free(arr),
        .struct_fields => |fields| alloc.free(fields),
        .map => |entries| alloc.free(entries),
    }
}

// ---- TypedValue decode (iterative) ----

/// Partial accumulator for one active container during iterative decode.
const DecodeFrame = struct {
    const Content = union(enum) {
        array: []TypedValue,
        struct_fields: struct { fields: []StructField, pending_name: ?[]u8 },
        map: struct { entries: []MapEntry, pending_key: ?TypedValue },
    };
    content: Content,
    decoded: u32,
};

// This is the domain boundary — all wire data entering via decode() is validated
// for structure (depth, counts, tags) before reaching the domain core.
pub fn decode(cur: *Cursor, alloc: std.mem.Allocator) !TypedValue {
    var frames: [MAX_DECODE_DEPTH]DecodeFrame = undefined;
    var depth: u8 = 0;
    return decodeLoop(cur, alloc, &frames, &depth) catch |err| {
        cleanupDecodeFrames(frames[0..depth], alloc);
        return err;
    };
}

/// Main iterative decode loop. Reads tags one at a time, pushes frames for
/// containers, and unwinds completed frames up the chain.
///
/// The outer while(true) is an intentional non-terminating scanner. Termination
/// is guaranteed: every iteration either advances cur (reads ≥1 byte) or returns
/// an error. MAX_DECODE_DEPTH caps nesting; MAX_CONTAINER_COUNT caps container size.
fn decodeLoop(
    cur: *Cursor,
    alloc: std.mem.Allocator,
    frames: *[MAX_DECODE_DEPTH]DecodeFrame,
    depth: *u8,
) !TypedValue {
    while (true) {
        if (depth.* > 0) {
            switch (frames[depth.* - 1].content) {
                .struct_fields => |*sf| {
                    if (sf.pending_name == null and
                        frames[depth.* - 1].decoded < sf.fields.len)
                    {
                        sf.pending_name = try cur.readU8LenPrefixedAlloc(alloc);
                    }
                },
                else => {},
            }
        }

        const tag = try cur.readU8();
        const v: TypedValue = blk: {
            if (tag == TAG_ARRAY or tag == TAG_STRUCT or tag == TAG_MAP) {
                if (try pushDecodeFrame(tag, cur, alloc, frames, depth)) |empty| {
                    break :blk empty;
                }
                continue;
            }
            break :blk try decodeScalar(tag, cur, alloc);
        };

        var result = v;
        while (true) {
            if (depth.* == 0) return result;
            const done = try storeInDecodeFrame(&frames[depth.* - 1], result, alloc);
            if (!done) break;
            result = decodeFrameToValue(&frames[depth.* - 1]);
            depth.* -= 1;
        }
    }
}

/// Decode a scalar tag. Returns the completed TypedValue.
/// The caller is responsible for ensuring tag is not a container tag.
fn decodeScalar(tag: u8, cur: *Cursor, alloc: std.mem.Allocator) !TypedValue {
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
        else => error.ProtocolError,
    };
}

/// Allocate and push a container frame. Returns a complete TypedValue for empty
/// containers (count=0), or null when a frame was pushed for non-empty containers.
fn pushDecodeFrame(
    tag: u8,
    cur: *Cursor,
    alloc: std.mem.Allocator,
    frames: *[MAX_DECODE_DEPTH]DecodeFrame,
    depth: *u8,
) !?TypedValue {
    assert(depth.* < MAX_DECODE_DEPTH);
    switch (tag) {
        TAG_ARRAY => {
            const count = try cur.readU32Le();
            if (count > MAX_CONTAINER_COUNT) return error.ProtocolError;
            const items = try alloc.alloc(TypedValue, count);
            if (count == 0) return .{ .array = items };
            frames[depth.*] = .{ .content = .{ .array = items }, .decoded = 0 };
            depth.* += 1;
            return null;
        },
        TAG_STRUCT => {
            const count = try cur.readU16Le();
            const fields = try alloc.alloc(StructField, count);
            if (count == 0) return .{ .struct_val = fields };
            frames[depth.*] = .{
                .content = .{ .struct_fields = .{ .fields = fields, .pending_name = null } },
                .decoded = 0,
            };
            depth.* += 1;
            return null;
        },
        TAG_MAP => {
            const count = try cur.readU32Le();
            if (count > MAX_CONTAINER_COUNT) return error.ProtocolError;
            const entries = try alloc.alloc(MapEntry, count);
            if (count == 0) return .{ .map = entries };
            frames[depth.*] = .{
                .content = .{ .map = .{ .entries = entries, .pending_key = null } },
                .decoded = 0,
            };
            depth.* += 1;
            return null;
        },
        else => unreachable,
    }
}

/// Store a decoded value in the current frame. Returns true when the frame is
/// complete (all items stored), false when more items are still expected.
fn storeInDecodeFrame(frame: *DecodeFrame, v: TypedValue, alloc: std.mem.Allocator) !bool {
    _ = alloc;
    switch (frame.content) {
        .array => |items| {
            assert(frame.decoded < items.len);
            items[frame.decoded] = v;
            frame.decoded += 1;
            return frame.decoded >= items.len;
        },
        .struct_fields => |*sf| {
            assert(sf.pending_name != null);
            assert(frame.decoded < sf.fields.len);
            sf.fields[frame.decoded] = .{ .name = sf.pending_name.?, .value = v };
            sf.pending_name = null;
            frame.decoded += 1;
            return frame.decoded >= sf.fields.len;
        },
        .map => |*mp| {
            if (mp.pending_key == null) {
                if (v == .null_val) return error.ProtocolError;
                mp.pending_key = v;
                return false;
            } else {
                assert(frame.decoded < mp.entries.len);
                mp.entries[frame.decoded] = .{ .key = mp.pending_key.?, .value = v };
                mp.pending_key = null;
                frame.decoded += 1;
                return frame.decoded >= mp.entries.len;
            }
        },
    }
}

fn decodeFrameToValue(frame: *const DecodeFrame) TypedValue {
    return switch (frame.content) {
        .array => |items| .{ .array = items },
        .struct_fields => |sf| .{ .struct_val = sf.fields },
        .map => |mp| .{ .map = mp.entries },
    };
}

/// Free all partial state in each frame on decode error.
fn cleanupDecodeFrames(frames: []DecodeFrame, alloc: std.mem.Allocator) void {
    for (frames) |*f| {
        switch (f.content) {
            .array => |items| {
                for (items[0..f.decoded]) |item| item.deinit(alloc);
                alloc.free(items);
            },
            .struct_fields => |*sf| {
                if (sf.pending_name) |n| alloc.free(n);
                for (sf.fields[0..f.decoded]) |field| {
                    alloc.free(field.name);
                    field.value.deinit(alloc);
                }
                alloc.free(sf.fields);
            },
            .map => |*mp| {
                if (mp.pending_key) |k| k.deinit(alloc);
                for (mp.entries[0..f.decoded]) |entry| {
                    entry.key.deinit(alloc);
                    entry.value.deinit(alloc);
                }
                alloc.free(mp.entries);
            },
        }
    }
}

// ---- ColumnDesc encode/decode ----

pub fn encodeColumnDesc(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, cd: ColumnDesc) !void {
    assert(cd.name.len <= std.math.maxInt(u8));
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
