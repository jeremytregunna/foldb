const std = @import("std");

pub const TableId = u32;
pub const Seq = u64;

/// Exact decimal value: value = coefficient × 10^(-scale).
/// Stored as 1-byte scale + 16-byte little-endian i128 coefficient (17 bytes total).
pub const Decimal = struct {
    coefficient: i128,
    scale: u8,
};

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
    bytes = 11,
    string = 12,
    decimal = 13,

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
            .int32, .uint32 => 4,
            .int64, .uint64 => 8,
            .decimal => 17,
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
    bytes: []const u8,
    string: []const u8,
    decimal: Decimal,

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
            .bytes => |v| std.mem.eql(u8, v, other.bytes),
            .string => |v| std.mem.eql(u8, v, other.string),
            .decimal => |v| v.coefficient == other.decimal.coefficient and v.scale == other.decimal.scale,
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

/// Records a single key read during handler execution.
/// `row_seq` is the sequence of the row version that was returned (0 if not found).
pub const ReadEntry = struct {
    table_id: TableId,
    key: []const u8,
    row_seq: Seq,
};

/// Tracks keys read by a handler during a single transaction execution.
/// Attach to Storage.read_tracker before calling the handler; detach after.
/// Used by the executor to detect read-write conflicts against recon_seq.
pub const ReadTracker = struct {
    reads: std.ArrayList(ReadEntry),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) ReadTracker {
        return .{ .reads = .empty, .alloc = alloc };
    }

    /// Record a key read. Deduplicates by (table_id, key); if the key was already
    /// recorded the first row_seq is kept (first read wins for conflict purposes).
    pub fn record(self: *ReadTracker, table_id: TableId, key: []const u8, row_seq: Seq) !void {
        for (self.reads.items) |r| {
            if (r.table_id == table_id and std.mem.eql(u8, r.key, key)) return;
        }
        const key_copy = try self.alloc.dupe(u8, key);
        errdefer self.alloc.free(key_copy);
        try self.reads.append(self.alloc, .{ .table_id = table_id, .key = key_copy, .row_seq = row_seq });
    }

    pub fn deinit(self: *ReadTracker) void {
        for (self.reads.items) |r| self.alloc.free(r.key);
        self.reads.deinit(self.alloc);
    }
};
