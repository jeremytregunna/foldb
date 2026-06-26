/// In-memory sorted table. Flushed to SSTable when full.
const std = @import("std");
const types = @import("types.zig");
const sstable_mod = @import("sstable.zig");

const assert = std.debug.assert;

const Seq = types.Seq;
const KeyRange = types.KeyRange;
const SSTableWriter = sstable_mod.SSTableWriter;

pub const MEMTABLE_SIZE_THRESHOLD: u64 = 64 * 1024 * 1024; // 64 MiB

comptime {
    assert(MEMTABLE_SIZE_THRESHOLD > 0);
}

pub const MemEntry = struct {
    key: []const u8,
    seq: Seq,
    value: ?[]const u8, // null = tombstone
    is_tombstone: bool,
};

pub const Memtable = struct {
    entries: std.ArrayListUnmanaged(MemEntry) = .empty,
    size_bytes: u64 = 0,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Memtable {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Memtable) void {
        for (self.entries.items) |entry| {
            self.alloc.free(entry.key);
            if (entry.value) |v| self.alloc.free(v);
        }
        self.entries.deinit(self.alloc);
    }

    pub fn put(self: *Memtable, key: []const u8, seq: Seq, value: ?[]const u8) !void {
        assert(key.len > 0);
        assert(seq > 0);
        const key_copy = try self.alloc.dupe(u8, key);
        errdefer self.alloc.free(key_copy);

        const val_copy = if (value) |v| try self.alloc.dupe(u8, v) else null;
        errdefer if (val_copy) |v| self.alloc.free(v);

        const entry = MemEntry{
            .key = key_copy,
            .seq = seq,
            .value = val_copy,
            .is_tombstone = value == null,
        };

        const pos = self.findInsertPos(key, seq);
        try self.entries.insert(self.alloc, pos, entry);

        self.size_bytes += key.len + 8;
        if (value) |v| self.size_bytes += v.len;
    }

    /// Find the most recent version of key with seq <= at_seq.
    pub fn get(self: *const Memtable, key: []const u8, at_seq: Seq) ?MemEntry {
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
    pub fn flush(self: *const Memtable, path: []const u8, level: u8) !void {
        var writer = try SSTableWriter.create(path, level, self.alloc);
        defer writer.deinit();

        for (self.entries.items) |entry| {
            try writer.append(entry.key, entry.seq, entry.value orelse "");
        }
        try writer.finish();
    }

    /// Iterate entries in order for a key range at a given seq.
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

    pub fn next(self: *MemRangeIterator) ?MemEntry {
        while (self.pos < self.entries.len) {
            const entry = &self.entries[self.pos];
            self.pos += 1;

            if (self.range.end) |e| {
                if (std.mem.order(u8, entry.key, e) != .lt) return null;
            }

            if (self.last_key) |lk| {
                if (std.mem.eql(u8, lk, entry.key)) continue;
            }

            if (entry.seq > self.at_seq) continue;

            self.last_key = entry.key;

            if (entry.is_tombstone) continue;

            return entry.*;
        }
        return null;
    }
};
