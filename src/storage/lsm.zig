/// LSM engine: memtable + L0–L3 SSTables + leveled compaction + MVCC reads.
const std = @import("std");
const types = @import("types.zig");
const memtable_mod = @import("memtable.zig");
const sstable_mod = @import("sstable.zig");
const block_cache_mod = @import("block_cache.zig");
const object_store_mod = @import("object_store.zig");

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
const ObjectStore = object_store_mod.ObjectStore;

const L0_COMPACTION_TRIGGER: usize = 4;
const L2_TIERING_TRIGGER: usize = 4;
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
    levels: [4]Level,
    cache: BlockCache,
    next_file_id: u64,
    alloc: std.mem.Allocator,
    object_store: ?ObjectStore,
    cache_dir: ?[]const u8,

    pub fn init(schema: TableSchema, dir: []const u8, alloc: std.mem.Allocator) !LSM {
        try mkdirAll(dir);
        const dir_copy = try alloc.dupe(u8, dir);
        return .{
            .schema = schema,
            .dir = dir_copy,
            .memtable = Memtable.init(schema, alloc),
            .levels = .{ Level.init(), Level.init(), Level.init(), Level.init() },
            .cache = try BlockCache.init(BLOCK_CACHE_BYTES, alloc),
            .next_file_id = 0,
            .alloc = alloc,
            .object_store = null,
            .cache_dir = null,
        };
    }

    pub fn deinit(self: *LSM) void {
        self.memtable.deinit(self.alloc);
        for (&self.levels) |*l| l.deinit(self.alloc);
        self.cache.deinit();
        self.alloc.free(self.dir);
        if (self.cache_dir) |cd| self.alloc.free(cd);
    }

    pub fn withObjectStore(self: *LSM, store: ObjectStore, cache_dir: []const u8) void {
        self.object_store = store;
        self.cache_dir = self.alloc.dupe(u8, cache_dir) catch null;
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

        // 4. L3 (object store) — download to cache dir if needed
        if (self.object_store) |store| {
            const l3_files = self.levels[3].files.items;
            const idx = findFileForKey(l3_files, key) orelse return null;
            const meta = &l3_files[idx];
            if (at_seq < meta.seq_min) return null;
            const remote_key = meta.remote_key orelse return null;

            const local_path = try self.ensureCached(store, remote_key, meta.path);
            defer if (!std.mem.eql(u8, local_path, meta.path)) self.alloc.free(local_path);

            var reader = try SSTableReader.open(local_path, self.schema, self.alloc);
            defer reader.deinit();
            if (try reader.get(key, at_seq)) |row| return row;
        }

        return null;
    }

    fn ensureCached(self: *LSM, store: ObjectStore, remote_key: []const u8, fallback_path: []const u8) ![]const u8 {
        const cd = self.cache_dir orelse return fallback_path;

        // Derive cache path from remote key (replace slashes with underscores for filename)
        const filename = try self.alloc.dupe(u8, remote_key);
        defer self.alloc.free(filename);
        for (filename) |*c| {
            if (c.* == '/') c.* = '_';
        }
        const local_path = try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ cd, filename });
        errdefer self.alloc.free(local_path);

        // Check if already cached
        if (fileExists(local_path)) return local_path;

        // Download from object store
        const data = store.get(remote_key, self.alloc) catch return fallback_path;
        defer self.alloc.free(data);

        try mkdirAll(cd);
        try writeFile(local_path, data);

        return local_path;
    }

    /// Full multi-level scan: merges memtable + all local SSTable levels.
    /// Returns all live rows in range at at_seq, sorted by key ASC.
    pub fn scan(self: *LSM, range: KeyRange, at_seq: Seq, alloc: std.mem.Allocator) ![]Row {
        var all_entries: std.ArrayList(MergeEntry) = .empty;
        defer {
            for (all_entries.items) |*e| {
                alloc.free(e.key);
                if (e.values) |vs| {
                    for (vs) |v| v.freeIfOwned(alloc);
                    alloc.free(vs);
                }
            }
            all_entries.deinit(alloc);
        }

        // 1. Memtable (sorted key ASC, seq DESC; break on past-end)
        for (self.memtable.entries.items) |entry| {
            if (entry.seq > at_seq) continue;
            if (range.end) |e| {
                if (std.mem.order(u8, entry.key, e) != .lt) break;
            }
            if (!range.contains(entry.key)) continue;
            const key_copy = try alloc.dupe(u8, entry.key);
            errdefer alloc.free(key_copy);
            var vals: ?[]ColumnValue = null;
            if (!entry.is_tombstone) {
                if (entry.values) |vs| {
                    const vc = try alloc.alloc(ColumnValue, vs.len);
                    errdefer alloc.free(vc);
                    for (vs, 0..) |v, i| vc[i] = try v.dupe(alloc);
                    vals = vc;
                }
            }
            try all_entries.append(alloc, .{
                .key = key_copy,
                .seq = entry.seq,
                .values = vals,
                .is_tombstone = entry.is_tombstone,
            });
        }

        // 2. All SSTable levels (skip remote-only L3 files)
        for (&self.levels) |*level| {
            for (level.files.items) |*meta| {
                if (!fileExists(meta.path)) continue;
                try self.collectRangeFromFile(meta, range, at_seq, &all_entries, alloc);
            }
        }

        // 3. Sort: key ASC, seq DESC
        std.sort.pdq(MergeEntry, all_entries.items, {}, mergeEntryCmp);

        // 4. Deduplicate: first (most-recent) entry per key; skip tombstones
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        errdefer {
            for (rows.items) |*r| r.deinit(alloc);
            rows.deinit(alloc);
        }
        var last_key: ?[]const u8 = null;
        for (all_entries.items) |e| {
            if (last_key) |lk| {
                if (std.mem.eql(u8, lk, e.key)) continue;
            }
            last_key = e.key;
            if (e.is_tombstone) continue;
            const vals = e.values orelse &.{};
            const key_copy = try alloc.dupe(u8, e.key);
            errdefer alloc.free(key_copy);
            const vals_copy = try alloc.alloc(ColumnValue, vals.len);
            errdefer alloc.free(vals_copy);
            for (vals, 0..) |v, i| vals_copy[i] = try v.dupe(alloc);
            try rows.append(alloc, Row{ .key = key_copy, .seq = e.seq, .values = vals_copy });
        }
        return rows.toOwnedSlice(alloc);
    }

    fn collectRangeFromFile(self: *LSM, meta: *const SSTableMeta, range: KeyRange, at_seq: Seq, out: *std.ArrayList(MergeEntry), alloc: std.mem.Allocator) !void {
        var reader = try SSTableReader.open(meta.path, self.schema, alloc);
        defer reader.deinit();

        for (0..reader.header.block_count) |bi| {
            const blk = try reader.readBlock(bi);
            defer alloc.free(blk);
            const block_reader = try @import("block.zig").BlockReader.init(blk, self.schema);
            for (0..block_reader.row_count) |ri| {
                const kv = try block_reader.readKey(@intCast(ri));
                if (kv.seq > at_seq) continue;
                if (range.end) |e| {
                    if (std.mem.order(u8, kv.key, e) != .lt) return;
                }
                if (!range.contains(kv.key)) continue;
                const key_copy = try alloc.dupe(u8, kv.key);
                errdefer alloc.free(key_copy);
                var vals: ?[]ColumnValue = null;
                if (!kv.is_tombstone) {
                    vals = try block_reader.readRowValues(@intCast(ri), alloc);
                }
                try out.append(alloc, .{
                    .key = key_copy,
                    .seq = kv.seq,
                    .values = vals,
                    .is_tombstone = kv.is_tombstone,
                });
            }
        }
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
        // L2 → L3 (object store) if enabled and L2 exceeds trigger
        if (self.object_store != null and self.levels[2].files.items.len > L2_TIERING_TRIGGER) {
            try self.compactL2toL3();
        }
    }

    fn compactL0toL1(self: *LSM) !void {
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

        for (self.levels[0].files.items) |*meta| {
            try self.collectFromFile(meta, &all_entries);
        }

        std.sort.pdq(MergeEntry, all_entries.items, {}, mergeEntryCmp);

        if (all_entries.items.len > 0) {
            try self.writeMergedEntries(all_entries.items, 1);
        }

        for (self.levels[0].files.items) |*meta| {
            deleteFile(meta.path);
            meta.deinit(self.alloc);
        }
        self.levels[0].files.clearRetainingCapacity();
    }

    fn compactLevelN(self: *LSM, level: usize) !void {
        if (level >= 2) return;
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

    fn compactL2toL3(self: *LSM) !void {
        const store = self.object_store orelse return;

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

        for (self.levels[2].files.items) |*meta| {
            try self.collectFromFile(meta, &all_entries);
        }

        std.sort.pdq(MergeEntry, all_entries.items, {}, mergeEntryCmp);

        if (all_entries.items.len > 0) {
            // Write merged SSTable locally, then upload
            const path = try self.nextFilePath(3);
            defer self.alloc.free(path);

            var writer = try SSTableWriter.create(path, self.schema, 3, self.alloc);
            defer writer.deinit();

            var last_key: ?[]const u8 = null;
            for (all_entries.items) |e| {
                if (last_key) |lk| {
                    if (std.mem.eql(u8, lk, e.key)) continue;
                }
                last_key = e.key;
                try writer.append(e.key, e.seq, e.values);
            }
            try writer.finish();

            // Read meta
            var reader = try SSTableReader.open(path, self.schema, self.alloc);
            defer reader.deinit();
            var m = try reader.meta(path, self.alloc);

            // Upload to object store
            const file_id = self.next_file_id - 1;
            const remote_key = try std.fmt.allocPrint(self.alloc, "sst/L3_{d:010}.sst", .{file_id});
            errdefer self.alloc.free(remote_key);

            const file_data = try readFileAlloc(path, self.alloc);
            defer self.alloc.free(file_data);

            store.put(remote_key, file_data) catch {
                // Upload failed; keep local copy, no remote_key
                self.alloc.free(remote_key);
                try self.levels[3].files.append(self.alloc, m);
                for (self.levels[2].files.items) |*meta| {
                    deleteFile(meta.path);
                    meta.deinit(self.alloc);
                }
                self.levels[2].files.clearRetainingCapacity();
                return;
            };

            m.remote_key = remote_key;
            try self.levels[3].files.append(self.alloc, m);
        }

        for (self.levels[2].files.items) |*meta| {
            deleteFile(meta.path);
            meta.deinit(self.alloc);
        }
        self.levels[2].files.clearRetainingCapacity();
    }

    fn collectFromFile(self: *LSM, meta: *const SSTableMeta, out: *std.ArrayList(MergeEntry)) !void {
        var reader = try SSTableReader.open(meta.path, self.schema, self.alloc);
        defer reader.deinit();

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

    pub fn listLocalSSTables(self: *LSM, alloc: std.mem.Allocator) ![]SSTableMeta {
        var result: std.ArrayList(SSTableMeta) = .empty;
        errdefer result.deinit(alloc);

        for (&self.levels) |*level| {
            for (level.files.items) |*meta| {
                const path_copy = try alloc.dupe(u8, meta.path);
                errdefer alloc.free(path_copy);
                const key_min_copy = try alloc.dupe(u8, meta.key_min);
                errdefer alloc.free(key_min_copy);
                const key_max_copy = try alloc.dupe(u8, meta.key_max);
                errdefer alloc.free(key_max_copy);
                var rk: ?[]const u8 = null;
                if (meta.remote_key) |r| {
                    rk = try alloc.dupe(u8, r);
                }
                try result.append(alloc, .{
                    .path = path_copy,
                    .table_id = meta.table_id,
                    .level = meta.level,
                    .seq_min = meta.seq_min,
                    .seq_max = meta.seq_max,
                    .key_min = key_min_copy,
                    .key_max = key_max_copy,
                    .block_count = meta.block_count,
                    .file_size = meta.file_size,
                    .remote_key = rk,
                });
            }
        }
        return result.toOwnedSlice(alloc);
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
    return a.seq > b.seq;
}

fn findFileForKey(files: []const SSTableMeta, key: []const u8) ?usize {
    if (files.len == 0) return null;
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
        if (std.mem.order(u8, key, files[idx].key_max) != .gt) return idx;
    }
    return null;
}

fn mkdirAll(path: []const u8) !void {
    const null_path = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    defer std.heap.page_allocator.free(null_path);
    @memcpy(null_path[0..path.len], path);
    _ = std.os.linux.mkdir(null_path.ptr, 0o755);
}

fn deleteFile(path: []const u8) void {
    const null_path = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(null_path);
    @memcpy(null_path[0..path.len], path);
    _ = std.os.linux.unlink(null_path.ptr);
}

fn fileExists(path: []const u8) bool {
    const null_path = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return false;
    defer std.heap.page_allocator.free(null_path);
    @memcpy(null_path[0..path.len], path);
    const raw_fd = std.os.linux.open(null_path.ptr, .{ .ACCMODE = .RDONLY }, 0);
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return false;
    _ = std.os.linux.close(@intCast(fd_i));
    return true;
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const null_path = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    defer std.heap.page_allocator.free(null_path);
    @memcpy(null_path[0..path.len], path);

    const raw_fd = std.os.linux.open(null_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return error.FileCreateError;
    const fd: std.posix.fd_t = @intCast(fd_i);
    defer _ = std.os.linux.close(@intCast(fd));

    var written: usize = 0;
    while (written < data.len) {
        const n = std.os.linux.write(@intCast(fd), data.ptr + written, data.len - written);
        const ni: isize = @bitCast(n);
        if (ni <= 0) return error.WriteError;
        written += @intCast(ni);
    }
}

fn readFileAlloc(path: []const u8, alloc: std.mem.Allocator) ![]u8 {
    const null_path = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    defer std.heap.page_allocator.free(null_path);
    @memcpy(null_path[0..path.len], path);

    const raw_fd = std.os.linux.open(null_path.ptr, .{ .ACCMODE = .RDONLY }, 0);
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return error.FileOpenError;
    const fd: std.posix.fd_t = @intCast(fd_i);
    defer _ = std.os.linux.close(@intCast(fd));

    const size_raw = std.os.linux.lseek(@intCast(fd), 0, std.os.linux.SEEK.END);
    const size_signed: isize = @bitCast(size_raw);
    if (size_signed < 0) return error.SeekError;
    _ = std.os.linux.lseek(@intCast(fd), 0, std.os.linux.SEEK.SET);
    const size: usize = @intCast(size_signed);

    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    var read_total: usize = 0;
    while (read_total < size) {
        const n = std.os.linux.read(@intCast(fd), buf.ptr + read_total, size - read_total);
        const ni: isize = @bitCast(n);
        if (ni <= 0) return error.ReadError;
        read_total += @intCast(ni);
    }
    return buf;
}
