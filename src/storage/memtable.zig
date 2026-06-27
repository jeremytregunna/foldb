/// In-memory write buffer for the LSM.
///
/// Writes append into an unsorted active buffer. Once that buffer reaches a
/// modest size it is sorted into an immutable run. This avoids O(n) shifting for
/// arbitrary string-key insert order while keeping data in contiguous arrays for
/// cache-friendly reads, flushes, and range scans.
const std = @import("std");
const types = @import("types.zig");
const sstable_mod = @import("sstable.zig");

const assert = std.debug.assert;

const Seq = types.Seq;
const SSTableWriter = sstable_mod.SSTableWriter;

pub const MEMTABLE_SIZE_THRESHOLD: u64 = 64 * 1024 * 1024; // 64 MiB
const ACTIVE_ENTRY_THRESHOLD: usize = 4096;

comptime {
    assert(MEMTABLE_SIZE_THRESHOLD > 0);
    assert(ACTIVE_ENTRY_THRESHOLD > 0);
}

pub const MemEntry = struct {
    key: []const u8,
    seq: Seq,
    value: ?[]const u8, // null = tombstone
    is_tombstone: bool,
};

pub const MemRun = struct {
    entries: []MemEntry,

    pub fn deinit(self: *MemRun, alloc: std.mem.Allocator) void {
        for (self.entries) |entry| {
            alloc.free(entry.key);
            if (entry.value) |v| alloc.free(v);
        }
        alloc.free(self.entries);
    }
};

pub const Memtable = struct {
    active: std.ArrayListUnmanaged(MemEntry) = .empty,
    runs: std.ArrayListUnmanaged(MemRun) = .empty,
    size_bytes: u64 = 0,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Memtable {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Memtable) void {
        for (self.active.items) |entry| {
            self.alloc.free(entry.key);
            if (entry.value) |v| self.alloc.free(v);
        }
        self.active.deinit(self.alloc);

        for (self.runs.items) |*run| run.deinit(self.alloc);
        self.runs.deinit(self.alloc);
    }

    pub fn put(self: *Memtable, key: []const u8, seq: Seq, value: ?[]const u8) !void {
        assert(key.len > 0);
        assert(seq > 0);
        const key_copy = try self.alloc.dupe(u8, key);
        errdefer self.alloc.free(key_copy);

        const val_copy = if (value) |v| try self.alloc.dupe(u8, v) else null;
        errdefer if (val_copy) |v| self.alloc.free(v);

        try self.active.append(self.alloc, .{
            .key = key_copy,
            .seq = seq,
            .value = val_copy,
            .is_tombstone = value == null,
        });

        self.size_bytes += key.len + 8;
        if (value) |v| self.size_bytes += v.len;

        if (self.active.items.len >= ACTIVE_ENTRY_THRESHOLD) try self.freezeActive();
    }

    /// Find the most recent version of key with seq <= at_seq.
    pub fn get(self: *const Memtable, key: []const u8, at_seq: Seq) ?MemEntry {
        var ai = self.active.items.len;
        while (ai > 0) {
            ai -= 1;
            const entry = self.active.items[ai];
            if (entry.seq <= at_seq and std.mem.eql(u8, entry.key, key)) return entry;
        }

        var ri = self.runs.items.len;
        while (ri > 0) {
            ri -= 1;
            if (findInSortedRun(self.runs.items[ri].entries, key, at_seq)) |entry| return entry;
        }
        return null;
    }

    pub fn isFull(self: *const Memtable) bool {
        return self.size_bytes >= MEMTABLE_SIZE_THRESHOLD;
    }

    pub fn isEmpty(self: *const Memtable) bool {
        return self.active.items.len == 0 and self.runs.items.len == 0;
    }

    /// Write all entries to an SSTable file in key ASC, seq DESC order.
    pub fn flush(self: *const Memtable, path: []const u8, level: u8) !void {
        const sorted = try self.sortedEntryRefs(self.alloc);
        defer self.alloc.free(sorted);

        var writer = try SSTableWriter.create(path, level, self.alloc);
        defer writer.deinit();

        for (sorted) |entry| {
            try writer.append(entry.key, entry.seq, entry.value orelse "");
        }
        try writer.finish();
    }

    fn freezeActive(self: *Memtable) !void {
        if (self.active.items.len == 0) return;
        std.sort.pdq(MemEntry, self.active.items, {}, memEntryLessThan);
        var run = MemRun{ .entries = try self.active.toOwnedSlice(self.alloc) };
        errdefer run.deinit(self.alloc);
        try self.runs.append(self.alloc, run);
    }

    pub fn sortedEntryRefs(self: *const Memtable, alloc: std.mem.Allocator) ![]*const MemEntry {
        const count = self.active.items.len + blk: {
            var n: usize = 0;
            for (self.runs.items) |run| n += run.entries.len;
            break :blk n;
        };

        const refs = try alloc.alloc(*const MemEntry, count);
        var idx: usize = 0;
        for (self.active.items) |*entry| {
            refs[idx] = entry;
            idx += 1;
        }
        for (self.runs.items) |run| {
            for (run.entries) |*entry| {
                refs[idx] = entry;
                idx += 1;
            }
        }
        std.sort.pdq(*const MemEntry, refs, {}, memEntryRefLessThan);
        return refs;
    }
};

fn findInSortedRun(entries: []const MemEntry, key: []const u8, at_seq: Seq) ?MemEntry {
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.order(u8, entries[mid].key, key) == .lt) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    var i = lo;
    while (i < entries.len) : (i += 1) {
        const entry = entries[i];
        if (!std.mem.eql(u8, entry.key, key)) break;
        if (entry.seq <= at_seq) return entry;
    }
    return null;
}

fn memEntryLessThan(_: void, a: MemEntry, b: MemEntry) bool {
    const cmp = std.mem.order(u8, a.key, b.key);
    if (cmp != .eq) return cmp == .lt;
    return a.seq > b.seq;
}

fn memEntryRefLessThan(_: void, a: *const MemEntry, b: *const MemEntry) bool {
    return memEntryLessThan({}, a.*, b.*);
}
