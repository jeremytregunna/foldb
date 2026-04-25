/// In-memory sorted table. Flushed to SSTable when full.
const std = @import("std");
const types = @import("types.zig");
const sstable_mod = @import("sstable.zig");

const assert = std.debug.assert;

const TableSchema = types.TableSchema;
const ColumnValue = types.ColumnValue;
const Seq = types.Seq;
const Row = types.Row;
const KeyRange = types.KeyRange;
const SSTableWriter = sstable_mod.SSTableWriter;

pub const MEMTABLE_SIZE_THRESHOLD: u64 = 64 * 1024 * 1024; // 64 MiB

comptime {
    assert(MEMTABLE_SIZE_THRESHOLD > 0);
}

pub const MemEntry = struct {
    key: []const u8,
    seq: Seq,
    values: ?[]ColumnValue, // null = tombstone
    is_tombstone: bool,
};

pub const Memtable = struct {
    schema: TableSchema,
    entries: std.ArrayList(MemEntry),
    size_bytes: u64,

    pub fn init(schema: TableSchema, alloc: std.mem.Allocator) Memtable {
        _ = alloc;
        return .{
            .schema = schema,
            .entries = .empty,
            .size_bytes = 0,
        };
    }

    pub fn deinit(self: *Memtable, alloc: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            alloc.free(entry.key);
            if (entry.values) |vals| {
                for (vals) |v| v.freeIfOwned(alloc);
                alloc.free(vals);
            }
        }
        self.entries.deinit(alloc);
    }

    pub fn put(self: *Memtable, key: []const u8, seq: Seq, values: ?[]const ColumnValue, alloc: std.mem.Allocator) !void {
        assert(key.len > 0);
        assert(seq > 0);
        const key_copy = try alloc.dupe(u8, key);
        errdefer alloc.free(key_copy);

        var vals_copy: ?[]ColumnValue = null;
        if (values) |vs| {
            const vc = try alloc.alloc(ColumnValue, vs.len);
            errdefer alloc.free(vc);
            for (vs, 0..) |v, i| vc[i] = try v.dupe(alloc);
            vals_copy = vc;
        }

        const entry = MemEntry{
            .key = key_copy,
            .seq = seq,
            .values = vals_copy,
            .is_tombstone = values == null,
        };

        // Insert in sorted order: (key asc, seq desc)
        const pos = self.findInsertPos(key, seq);
        try self.entries.insert(alloc, pos, entry);

        self.size_bytes += key.len + 8;
        if (values) |vs| {
            for (vs) |v| {
                self.size_bytes += switch (v) {
                    .bytes => |b| b.len + 8,
                    .string => |s| s.len + 8,
                    else => 8,
                };
            }
        }
    }

    /// Find the most recent version of key with seq ≤ at_seq.
    pub fn get(self: *const Memtable, key: []const u8, at_seq: Seq) ?MemEntry {
        // Binary search for first entry with this key
        const lo = self.lowerBoundKey(key);
        for (self.entries.items[lo..]) |entry| {
            if (!std.mem.eql(u8, entry.key, key)) break;
            if (entry.seq <= at_seq) return entry;
        }
        return null;
    }

    pub fn isFull(self: *const Memtable) bool {
        return self.size_bytes >= MEMTABLE_SIZE_THRESHOLD;
    }

    pub fn isEmpty(self: *const Memtable) bool {
        return self.entries.items.len == 0;
    }

    /// Write all entries to an SSTable file.
    pub fn flush(self: *const Memtable, path: []const u8, level: u8, alloc: std.mem.Allocator) !void {
        var writer = try SSTableWriter.create(path, self.schema, level, alloc);
        defer writer.deinit();

        for (self.entries.items) |entry| {
            try writer.append(entry.key, entry.seq, entry.values);
        }
        try writer.finish();
    }

    /// Iterate entries in order for a key range at a given seq. Returns slice view.
    pub fn rangeEntries(self: *const Memtable, range: KeyRange, at_seq: Seq) MemRangeIterator {
        var start: usize = 0;
        if (range.start) |s| {
            start = if (range.start_inclusive)
                self.lowerBoundKey(s)
            else
                self.upperBoundKey(s);
        }
        return .{
            .entries = self.entries.items,
            .pos = start,
            .range = range,
            .at_seq = at_seq,
            .last_key = null,
        };
    }

    fn findInsertPos(self: *const Memtable, key: []const u8, seq: Seq) usize {
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const e = &self.entries.items[mid];
            const cmp = std.mem.order(u8, e.key, key);
            // Sort order: key ASC, seq DESC. Entry at mid comes before new entry iff
            // its key is smaller, or same key with strictly larger seq.
            if (cmp == .lt or (cmp == .eq and e.seq > seq)) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    fn lowerBoundKey(self: *const Memtable, key: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, self.entries.items[mid].key, key) == .lt) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    fn upperBoundKey(self: *const Memtable, key: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, self.entries.items[mid].key, key) != .gt) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }
};

pub const MemRangeIterator = struct {
    entries: []const MemEntry,
    pos: usize,
    range: KeyRange,
    at_seq: Seq,
    last_key: ?[]const u8,

    /// Returns the next live entry (most recent version per key ≤ at_seq).
    /// Returns null when exhausted.
    pub fn next(self: *MemRangeIterator) ?MemEntry {
        while (self.pos < self.entries.len) {
            const entry = &self.entries[self.pos];
            self.pos += 1;

            // Check end of range
            if (self.range.end) |e| {
                if (std.mem.order(u8, entry.key, e) != .lt) return null;
            }

            // Skip versions of a key we've already returned
            if (self.last_key) |lk| {
                if (std.mem.eql(u8, lk, entry.key)) continue;
            }

            // Skip entries newer than at_seq
            if (entry.seq > self.at_seq) continue;

            self.last_key = entry.key;

            // Skip tombstones (return null for tombstone means deleted — skip key entirely)
            if (entry.is_tombstone) continue;

            return entry.*;
        }
        return null;
    }
};
