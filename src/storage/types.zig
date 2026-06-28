const std = @import("std");

pub const NamespaceId = u32;
pub const Seq = u64;

pub const Row = struct {
    key: []const u8,
    value: []const u8,
    seq: Seq,
    is_tombstone: bool = false,

    pub fn deinit(self: Row, alloc: std.mem.Allocator) void {
        alloc.free(self.value);
        alloc.free(self.key);
    }
};

pub const MutationKind = enum { insert, update, delete };

pub const Mutation = struct {
    kind: MutationKind,
    namespace_id: NamespaceId,
    key: []const u8,
    value: ?[]const u8,
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
    namespace_id: NamespaceId,
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

    /// Record a key read. Deduplicates by (namespace_id, key); if the key was already
    /// recorded the first row_seq is kept (first read wins for conflict purposes).
    pub fn record(self: *ReadTracker, namespace_id: NamespaceId, key: []const u8, row_seq: Seq) !void {
        for (self.reads.items) |r| {
            if (r.namespace_id == namespace_id and std.mem.eql(u8, r.key, key)) return;
        }
        const key_copy = try self.alloc.dupe(u8, key);
        errdefer self.alloc.free(key_copy);
        try self.reads.append(self.alloc, .{ .namespace_id = namespace_id, .key = key_copy, .row_seq = row_seq });
    }

    pub fn deinit(self: *ReadTracker) void {
        for (self.reads.items) |r| self.alloc.free(r.key);
        self.reads.deinit(self.alloc);
    }
};
