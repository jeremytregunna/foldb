const std = @import("std");

pub const TableId = u32;
pub const Seq = u64;

pub const ColumnType = enum(u8) {
    bool_t = 0,
    int8 = 1,
    int16 = 2,
    int32 = 3,
    int64 = 4,
    uint8 = 5,
    uint16 = 6,
    uint32 = 7,
    uint64 = 8,
    float32 = 9,
    float64 = 10,
    bytes = 11,
    string = 12,

    pub fn isFixedWidth(self: ColumnType) bool {
        return switch (self) {
            .bytes, .string => false,
            else => true,
        };
    }

    pub fn fixedWidthSize(self: ColumnType) u8 {
        return switch (self) {
            .bool_t => 1,
            .int8, .uint8 => 1,
            .int16, .uint16 => 2,
            .int32, .uint32, .float32 => 4,
            .int64, .uint64, .float64 => 8,
            .bytes, .string => 0,
        };
    }
};

pub const ColumnSchema = struct {
    col_type: ColumnType,
    nullable: bool,
};

pub const TableSchema = struct {
    table_id: TableId,
    columns: []const ColumnSchema,
};

pub const ColumnValue = union(ColumnType) {
    bool_t: bool,
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
    bytes: []const u8,
    string: []const u8,

    pub fn eql(self: ColumnValue, other: ColumnValue) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .bool_t => |v| v == other.bool_t,
            .int8 => |v| v == other.int8,
            .int16 => |v| v == other.int16,
            .int32 => |v| v == other.int32,
            .int64 => |v| v == other.int64,
            .uint8 => |v| v == other.uint8,
            .uint16 => |v| v == other.uint16,
            .uint32 => |v| v == other.uint32,
            .uint64 => |v| v == other.uint64,
            .float32 => |v| v == other.float32,
            .float64 => |v| v == other.float64,
            .bytes => |v| std.mem.eql(u8, v, other.bytes),
            .string => |v| std.mem.eql(u8, v, other.string),
        };
    }

    pub fn dupe(self: ColumnValue, alloc: std.mem.Allocator) !ColumnValue {
        return switch (self) {
            .bytes => |v| .{ .bytes = try alloc.dupe(u8, v) },
            .string => |v| .{ .string = try alloc.dupe(u8, v) },
            else => self,
        };
    }

    pub fn freeIfOwned(self: ColumnValue, alloc: std.mem.Allocator) void {
        switch (self) {
            .bytes => |v| alloc.free(v),
            .string => |v| alloc.free(v),
            else => {},
        }
    }
};

pub const Row = struct {
    key: []const u8,
    seq: Seq,
    values: []ColumnValue,
    is_tombstone: bool = false,

    pub fn deinit(self: *Row, alloc: std.mem.Allocator) void {
        for (self.values) |v| v.freeIfOwned(alloc);
        alloc.free(self.values);
        alloc.free(self.key);
    }
};

pub const MutationKind = enum { insert, update, delete };

pub const Mutation = struct {
    kind: MutationKind,
    table_id: TableId,
    key: []const u8,
    values: ?[]const ColumnValue,
};

pub const KeyRange = struct {
    start: ?[]const u8,
    end: ?[]const u8,
    start_inclusive: bool,

    pub fn all() KeyRange {
        return .{ .start = null, .end = null, .start_inclusive = true };
    }

    pub fn contains(self: KeyRange, key: []const u8) bool {
        if (self.start) |s| {
            const cmp = std.mem.order(u8, key, s);
            if (self.start_inclusive) {
                if (cmp == .lt) return false;
            } else {
                if (cmp != .gt) return false;
            }
        }
        if (self.end) |e| {
            if (std.mem.order(u8, key, e) != .lt) return false;
        }
        return true;
    }
};

pub const SnapshotHandle = struct {
    seq: Seq,
};
