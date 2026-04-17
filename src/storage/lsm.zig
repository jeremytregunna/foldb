/// LSM engine: memtable + L0–L2 SSTables + leveled compaction + MVCC reads.
const std = @import("std");
const types = @import("types.zig");
const memtable_mod = @import("memtable.zig");
const sstable_mod = @import("sstable.zig");
const block_cache_mod = @import("block_cache.zig");

const TableSchema = types.TableSchema;
const TableId = types.TableId;
const ColumnValue = types.ColumnValue;
const Mutation = types.Mutation;
const MutationKind = types.MutationKind;
const Seq = types.Seq;
const Row = types.Row;
const KeyRange = types.KeyRange;
const Memtable = memtable_mod.Memtable;
const SSTableWriter = sstable_mod.SSTableWriter;
const SSTableReader = sstable_mod.SSTableReader;
const SSTableMeta = sstable_mod.SSTableMeta;
const BlockCache = block_cache_mod.BlockCache;

const L0_COMPACTION_TRIGGER: usize = 4;
const BLOCK_CACHE_BYTES: usize = 32 * 1024 * 1024; // 32 MiB default

pub const Level = struct {
    files: std.ArrayList(SSTableMeta),

    pub fn init() Level {
        return .{ .files = .empty };
    }

    pub fn deinit(self: *Level, alloc: std.mem.Allocator) void {
        for (self.files.items) |*m| m.deinit(alloc);
        self.files.deinit(alloc);
    }
};

pub const LSM = struct {
    schema: TableSchema,
    dir: []const u8,
    memtable: Memtable,
    levels: [3]Level,
    cache: BlockCache,
    next_file_id: u64,
    alloc: std.mem.Allocator,

    pub fn init(schema: TableSchema, dir: []const u8, alloc: std.mem.Allocator) !LSM {
        try mkdirAll(dir);
        const dir_copy = try alloc.dupe(u8, dir);
        return .{
            .schema = schema,
            .dir = dir_copy,
            .memtable = Memtable.init(schema, alloc),
            .levels = .{ Level.init(), Level.init(), Level.init() },
            .cache = try BlockCache.init(BLOCK_CACHE_BYTES, alloc),
            .next_file_id = 0,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *LSM) void {
        self.memtable.deinit(self.alloc);
        for (&self.levels) |*l| l.deinit(self.alloc);
        self.cache.deinit();
        self.alloc.free(self.dir);
    }

    pub fn apply(self: *LSM, mutations: []const Mutation, at_seq: Seq) !void {
        for (mutations) |m| {
            if (m.table_id != self.schema.table_id) continue;
            const vals: ?[]const ColumnValue = switch (m.kind) {
                .delete => null,
                .insert, .update => m.values,
            };
            try self.memtable.put(m.key, at_seq, vals, self.alloc);
        }

        if (self.memtable.isFull()) try self.flushMemtable();
        if (self.levels[0].files.items.len >= L0_COMPACTION_TRIGGER) {
            try self.compactL0toL1();
        }
    }

    pub fn get(self: *LSM, key: []const u8, at_seq: Seq) !?Row {
        // 1. Memtable
        if (self.memtable.get(key, at_seq)) |entry| {
            if (entry.is_tombstone) return null;
            const key_copy = try self.alloc.dupe(u8, entry.key);
            errdefer self.alloc.free(key_copy);
            const vals = entry.values.?;
            const vals_copy = try self.alloc.alloc(ColumnValue, vals.len);
            errdefer self.alloc.free(vals_copy);
            for (vals, 0..) |v, i| vals_copy[i] = try v.dupe(self.alloc);
            return Row{ .key = key_copy, .seq = entry.seq, .values = vals_copy };
        }

        // 2. L0 files (newest first)
        const l0_files = self.levels[0].files.items;
        var li: usize = l0_files.len;
        while (li > 0) {
            li -= 1;
            const meta = &l0_files[li];
            if (at_seq < meta.seq_min) continue;
            var reader = try SSTableReader.open(meta.path, self.schema, self.alloc);
            defer reader.deinit();
            if (try reader.get(key, at_seq)) |row| return row;
        }

        // 3. L1 and L2 files (binary search by key range)
        for (1..3) |level| {
            const files = self.levels[level].files.items;
            const idx = findFileForKey(files, key) orelse continue;
            const meta = &files[idx];
            if (at_seq < meta.seq_min) continue;
            var reader = try SSTableReader.open(meta.path, self.schema, self.alloc);
            defer reader.deinit();
            if (try reader.get(key, at_seq)) |row| return row;
        }

        return null;
    }

    pub fn flushMemtable(self: *LSM) !void {
        if (self.memtable.isEmpty()) return;
        const path = try self.nextFilePath(0);
        defer self.alloc.free(path);
        try self.memtable.flush(path, 0, self.alloc);

        var reader = try SSTableReader.open(path, self.schema, self.alloc);
        defer reader.deinit();
        const m = try reader.meta(path, self.alloc);
        try self.levels[0].files.append(self.alloc, m);

        self.memtable.deinit(self.alloc);
        self.memtable = Memtable.init(self.schema, self.alloc);
    }

    pub fn maybeCompact(self: *LSM) !void {
        if (self.levels[0].files.items.len >= L0_COMPACTION_TRIGGER) {
            try self.compactL0toL1();
        }
        // L1 → L2 if L1 has too many files (simple heuristic: > 10)
        if (self.levels[1].files.items.len > 10) {
            try self.compactLevelN(1);
        }
    }

    fn compactL0toL1(self: *LSM) !void {
        // Merge all L0 files + overlapping L1 files → new L1 SSTables.
        // For M3: collect all entries from L0, sort, deduplicate by (key, seq desc), write to L1.

        var all_entries: std.ArrayList(MergeEntry) = .empty;
        defer {
            for (all_entries.items) |*e| {
                self.alloc.free(e.key);
                if (e.values) |vs| {
                    for (vs) |v| v.freeIfOwned(self.alloc);
                    self.alloc.free(vs);
                }
            }
            all_entries.deinit(self.alloc);
        }

        // Collect from L0
        for (self.levels[0].files.items) |*meta| {
            try self.collectFromFile(meta, &all_entries);
        }

        // Sort: (key asc, seq desc)
        std.sort.pdq(MergeEntry, all_entries.items, {}, mergeEntryCmp);

        if (all_entries.items.len > 0) {
            try self.writeMergedEntries(all_entries.items, 1);
        }

        // Remove old L0 files
        for (self.levels[0].files.items) |*meta| {
            deleteFile(meta.path);
            meta.deinit(self.alloc);
        }
        self.levels[0].files.clearRetainingCapacity();
    }

    fn compactLevelN(self: *LSM, level: usize) !void {
        if (level >= 2) return;
        // Simple: merge all files in level → level+1
        var all_entries: std.ArrayList(MergeEntry) = .empty;
        defer {
            for (all_entries.items) |*e| {
                self.alloc.free(e.key);
                if (e.values) |vs| {
                    for (vs) |v| v.freeIfOwned(self.alloc);
                    self.alloc.free(vs);
                }
            }
            all_entries.deinit(self.alloc);
        }

        for (self.levels[level].files.items) |*meta| {
            try self.collectFromFile(meta, &all_entries);
        }

        std.sort.pdq(MergeEntry, all_entries.items, {}, mergeEntryCmp);

        if (all_entries.items.len > 0) {
            try self.writeMergedEntries(all_entries.items, level + 1);
        }

        for (self.levels[level].files.items) |*meta| {
            deleteFile(meta.path);
            meta.deinit(self.alloc);
        }
        self.levels[level].files.clearRetainingCapacity();
    }

    fn collectFromFile(self: *LSM, meta: *const SSTableMeta, out: *std.ArrayList(MergeEntry)) !void {
        var reader = try SSTableReader.open(meta.path, self.schema, self.alloc);
        defer reader.deinit();

        // Iterate all entries by reading blocks
        for (0..reader.header.block_count) |bi| {
            const blk = try reader.readBlock(bi);
            defer self.alloc.free(blk);
            const block_reader = try @import("block.zig").BlockReader.init(blk, self.schema);
            for (0..block_reader.row_count) |ri| {
                const kv = try block_reader.readKey(@intCast(ri));
                const key_copy = try self.alloc.dupe(u8, kv.key);
                errdefer self.alloc.free(key_copy);
                var vals: ?[]ColumnValue = null;
                if (!kv.is_tombstone) {
                    vals = try block_reader.readRowValues(@intCast(ri), self.alloc);
                }
                try out.append(self.alloc, .{
                    .key = key_copy,
                    .seq = kv.seq,
                    .values = vals,
                    .is_tombstone = kv.is_tombstone,
                });
            }
        }
    }

    fn writeMergedEntries(self: *LSM, entries: []const MergeEntry, target_level: usize) !void {
        const path = try self.nextFilePath(target_level);
        defer self.alloc.free(path);

        var writer = try SSTableWriter.create(path, self.schema, @intCast(target_level), self.alloc);
        defer writer.deinit();

        var last_key: ?[]const u8 = null;
        for (entries) |e| {
            // Dedup: for each key, only keep entries not shadowed by a newer version
            // (entries are sorted key asc, seq desc; so first entry per key wins)
            if (last_key) |lk| {
                if (std.mem.eql(u8, lk, e.key)) continue;
            }
            last_key = e.key;
            try writer.append(e.key, e.seq, e.values);
        }
        try writer.finish();

        var reader = try SSTableReader.open(path, self.schema, self.alloc);
        defer reader.deinit();
        const m = try reader.meta(path, self.alloc);
        try self.levels[target_level].files.append(self.alloc, m);
    }

    fn nextFilePath(self: *LSM, level: usize) ![]const u8 {
        const id = self.next_file_id;
        self.next_file_id += 1;
        return std.fmt.allocPrint(self.alloc, "{s}/L{d}_{d:010}.sst", .{ self.dir, level, id });
    }
};

const MergeEntry = struct {
    key: []const u8,
    seq: Seq,
    values: ?[]ColumnValue,
    is_tombstone: bool,
};

fn mergeEntryCmp(_: void, a: MergeEntry, b: MergeEntry) bool {
    const key_ord = std.mem.order(u8, a.key, b.key);
    if (key_ord == .lt) return true;
    if (key_ord == .gt) return false;
    // Same key: higher seq first (desc)
    return a.seq > b.seq;
}

fn findFileForKey(files: []const SSTableMeta, key: []const u8) ?usize {
    if (files.len == 0) return null;
    // Binary search for last file whose key_min ≤ key
    var result: ?usize = null;
    var lo: usize = 0;
    var hi: usize = files.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const cmp = std.mem.order(u8, files[mid].key_min, key);
        if (cmp != .gt) {
            result = mid;
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (result) |idx| {
        // Verify key ≤ key_max
        if (std.mem.order(u8, key, files[idx].key_max) != .gt) return idx;
    }
    return null;
}

fn mkdirAll(path: []const u8) !void {
    const null_path = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    defer std.heap.page_allocator.free(null_path);
    @memcpy(null_path[0..path.len], path);
    _ = std.os.linux.mkdir(null_path.ptr, 0o755);
    // Ignore error (dir may already exist)
}

fn deleteFile(path: []const u8) void {
    const null_path = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(null_path);
    @memcpy(null_path[0..path.len], path);
    _ = std.os.linux.unlink(null_path.ptr);
}
