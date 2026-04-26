/// Public storage API: unified module re-exporting all storage types.
const std = @import("std");

const assert = std.debug.assert;
const types = @import("types.zig");
const obs = @import("observability.zig");
const lsm_mod = @import("lsm.zig");
const codec_mod = @import("codec.zig");
const block_mod = @import("block.zig");
const sstable_mod = @import("sstable.zig");
const object_store_mod = @import("object_store.zig");
const snapshot_mod = @import("snapshot.zig");
const json_index_mod = @import("json_index.zig");
const hnsw_mod = @import("hnsw.zig");
pub const vector_codec = @import("vector_codec.zig");
pub const json_path = @import("json_path.zig");

pub const SnapshotLogWriter = snapshot_mod.SnapshotLogWriter;
pub const noop_snapshot_log_writer = snapshot_mod.noop_snapshot_log_writer;

/// Called after each successful snapshot with the snapshot seq.
/// Allows callers to trigger log truncation and idempotency cache eviction.
pub const PostSnapshotHook = struct {
    ptr: *anyopaque,
    hookFn: *const fn (*anyopaque, seq: Seq) void,

    pub fn call(self: PostSnapshotHook, seq: Seq) void {
        self.hookFn(self.ptr, seq);
    }
};

// This is the domain boundary — SnapshotPolicy fields are all non-optional.
// Callers that do not need a log writer or post-snapshot callback use the
// no-op defaults below; the core calls them unconditionally.
fn noopPostSnapshotImpl(_: *anyopaque, _: Seq) void {}
pub const noop_post_snapshot_hook = PostSnapshotHook{
    .ptr = undefined,
    .hookFn = &noopPostSnapshotImpl,
};

pub const SnapshotPolicy = struct {
    interval: u64,
    counter: u64 = 0,
    store: object_store_mod.ObjectStore,
    log_writer: snapshot_mod.SnapshotLogWriter = snapshot_mod.noop_snapshot_log_writer,
    partition_id: u32 = 0,
    post_snapshot: PostSnapshotHook = noop_post_snapshot_hook,
};

// Core types
pub const TableId = types.TableId;
pub const Seq = types.Seq;
pub const Decimal = types.Decimal;
pub const ColumnType = types.ColumnType;
pub const ColumnSchema = types.ColumnSchema;
pub const TableSchema = types.TableSchema;
pub const ColumnValue = types.ColumnValue;
pub const Row = types.Row;
pub const Mutation = types.Mutation;
pub const MutationKind = types.MutationKind;
pub const KeyRange = types.KeyRange;
pub const SnapshotHandle = types.SnapshotHandle;
pub const ReadTracker = types.ReadTracker;
pub const ReadEntry = types.ReadEntry;

// Index types
pub const IndexId = u32;
pub const PkList = json_index_mod.PkList;
pub const Match = hnsw_mod.Match;

/// Typed index specification — one variant per index kind, carrying only the fields that apply.
pub const IndexSpec = union(enum) {
    json_path: []const []const u8, // declared extraction paths
    vector: u32, // vector dimension
};

/// Descriptor passed from gateway to storage when registering a specialty index.
/// All fields are fully validated by the gateway before this type is constructed.
pub const IndexDesc = struct {
    id: IndexId,
    table_id: TableId,
    column_idx: u32,
    spec: IndexSpec,
};

// Codec
pub const CodecId = codec_mod.CodecId;
pub const chooseCodec = codec_mod.chooseCodec;
pub const encodeCol = codec_mod.encode;
pub const decodeCol = codec_mod.decode;

// Block
pub const BlockWriter = block_mod.BlockWriter;
pub const BlockReader = block_mod.BlockReader;
pub const BlockHeader = block_mod.BlockHeader;
pub const TOMBSTONE_BIT = block_mod.TOMBSTONE_BIT;

// SSTable
pub const SSTableWriter = sstable_mod.SSTableWriter;
pub const SSTableReader = sstable_mod.SSTableReader;
pub const SSTableMeta = sstable_mod.SSTableMeta;

// LSM
pub const LSM = lsm_mod.LSM;

// Object store
pub const ObjectStore = object_store_mod.ObjectStore;
pub const MemoryObjectStore = object_store_mod.MemoryObjectStore;
pub const S3Config = @import("s3.zig").S3Config;
pub const S3ObjectStore = @import("s3.zig").S3ObjectStore;
pub const BucketStyle = @import("s3.zig").BucketStyle;

// Snapshot
pub const SnapshotManifest = snapshot_mod.SnapshotManifest;
pub const SnapshotMarkerPayload = snapshot_mod.SnapshotMarkerPayload;
pub const takeSnapshot = snapshot_mod.takeSnapshot;
pub const restoreFromSnapshot = snapshot_mod.restoreFromSnapshot;
pub const manifestToBytes = snapshot_mod.manifestToBytes;
pub const manifestFromBytes = snapshot_mod.manifestFromBytes;

pub const ScanIterator = struct {
    rows: []Row,
    pos: usize,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *ScanIterator) void {
        for (self.rows) |*r| r.deinit(self.alloc);
        self.alloc.free(self.rows);
    }

    pub fn next(self: *ScanIterator) !?Row {
        if (self.pos >= self.rows.len) return null;
        const r = self.rows[self.pos];
        self.pos += 1;
        return r;
    }
};

/// Routing wrapper over N Storage partitions.
/// Routes reads/writes by wyhash(key) % N. For N=1 all calls delegate directly
/// to partitions[0] with zero routing overhead.
pub const PartitionedStorage = struct {
    partitions: []*Storage,
    alloc: std.mem.Allocator,

    pub fn partitionIdx(self: *const PartitionedStorage, key: []const u8) usize {
        if (self.partitions.len <= 1) return 0;
        return std.hash.Wyhash.hash(0, key) % self.partitions.len;
    }

    pub fn get(self: *PartitionedStorage, table_id: TableId, key: []const u8, at_seq: Seq) !?Row {
        return self.partitions[self.partitionIdx(key)].get(table_id, key, at_seq);
    }

    /// Scatter scan across all partitions; merge-sort results by key.
    /// Row ownership is transferred: merged ScanIterator owns all row heap data.
    pub fn scan(self: *PartitionedStorage, table_id: TableId, range: KeyRange, at_seq: Seq, alloc: std.mem.Allocator) !ScanIterator {
        if (self.partitions.len <= 1) return self.partitions[0].scan(table_id, range, at_seq, alloc);
        var merged: std.ArrayList(Row) = .empty;
        errdefer {
            for (merged.items) |*r| r.deinit(alloc);
            merged.deinit(alloc);
        }
        var found_any = false;
        for (self.partitions) |p| {
            const iter = p.scan(table_id, range, at_seq, alloc) catch |e| {
                if (e == error.TableNotFound) continue;
                return e;
            };
            found_any = true;
            // Transfer row structs to merged; free only the original slice header.
            // Row heap data (key, values) is now owned by merged.
            try merged.appendSlice(alloc, iter.rows);
            alloc.free(iter.rows);
        }
        if (!found_any) return error.TableNotFound;
        const rows = try merged.toOwnedSlice(alloc);
        std.sort.block(Row, rows, {}, struct {
            fn lt(_: void, a: Row, b: Row) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.lt);
        return ScanIterator{ .rows = rows, .pos = 0, .alloc = alloc };
    }

    /// Group mutations by destination partition and apply each group.
    pub fn apply(self: *PartitionedStorage, mutations: []const Mutation, at_seq: Seq) !void {
        if (self.partitions.len <= 1) return self.partitions[0].apply(mutations, at_seq);
        const n = self.partitions.len;
        const groups = try self.alloc.alloc(std.ArrayListUnmanaged(Mutation), n);
        defer self.alloc.free(groups);
        for (groups) |*g| g.* = .empty;
        defer for (groups) |*g| g.deinit(self.alloc);
        for (mutations) |m| try groups[self.partitionIdx(m.key)].append(self.alloc, m);
        for (groups, self.partitions) |*g, p| {
            if (g.items.len > 0) try p.apply(g.items, at_seq);
        }
    }

    /// Register a table schema on every partition (schema is global, not per-partition).
    pub fn registerTable(self: *PartitionedStorage, schema: TableSchema) !void {
        for (self.partitions) |p| try p.registerTable(schema);
    }

    pub fn unregisterTable(self: *PartitionedStorage, table_id: TableId) void {
        for (self.partitions) |p| p.unregisterTable(table_id);
    }

    /// Register a specialty index on every partition.
    pub fn registerIndex(self: *PartitionedStorage, desc: IndexDesc) !void {
        for (self.partitions) |p| try p.registerIndex(desc);
    }

    pub fn flushAll(self: *PartitionedStorage) !void {
        for (self.partitions) |p| try p.flushAll();
    }

    /// Convenience: wrap a single Storage in a PartitionedStorage.
    /// Allocates a 1-element partitions slice; call deinit() to free it.
    pub fn fromSingle(storage: *Storage, alloc: std.mem.Allocator) !PartitionedStorage {
        const parts = try alloc.alloc(*Storage, 1);
        parts[0] = storage;
        return .{ .partitions = parts, .alloc = alloc };
    }

    /// ANN search across all partitions; results are merged and sorted by distance, top k returned.
    pub fn vectorSearch(self: *PartitionedStorage, index_id: IndexId, query: []const f32, k: u32, at_seq: Seq, alloc: std.mem.Allocator) ![]Match {
        if (self.partitions.len <= 1) return self.partitions[0].vectorSearch(index_id, query, k, at_seq, alloc);
        var merged: std.ArrayListUnmanaged(Match) = .empty;
        errdefer {
            for (merged.items) |m| alloc.free(m.pk);
            merged.deinit(alloc);
        }
        for (self.partitions) |p| {
            const ms = p.vectorSearch(index_id, query, k, at_seq, alloc) catch |e| {
                if (e == error.IndexNotFound) continue;
                return e;
            };
            defer alloc.free(ms);
            for (ms) |m| try merged.append(alloc, m);
        }
        std.sort.block(Match, merged.items, {}, struct {
            fn lt(_: void, a: Match, b: Match) bool {
                return a.distance < b.distance;
            }
        }.lt);
        if (merged.items.len > k) {
            for (merged.items[k..]) |m| alloc.free(m.pk);
            merged.shrinkRetainingCapacity(k);
        }
        return merged.toOwnedSlice(alloc);
    }

    /// Free the partitions slice. Does NOT deinit the Storage objects (caller owns them).
    pub fn deinit(self: *PartitionedStorage) void {
        self.alloc.free(self.partitions);
    }
};

const IndexEntry = union(enum) {
    json: json_index_mod.JsonPathIndex,
    vector: hnsw_mod.HnswIndex,

    fn tableId(self: *const IndexEntry) TableId {
        return switch (self.*) {
            .json => |*j| j.table_id,
            .vector => |*v| v.table_id,
        };
    }

    fn deinit(self: *IndexEntry) void {
        switch (self.*) {
            .json => |*j| j.deinit(),
            .vector => |*v| v.deinit(),
        }
    }
};

pub const StorageMetrics = obs.StorageMetrics;

pub const DiskFaultHook = lsm_mod.DiskFaultHook;

pub const Storage = struct {
    tables: std.AutoHashMap(TableId, lsm_mod.LSM),
    indexes: std.AutoHashMap(IndexId, IndexEntry),
    dir: []const u8,
    alloc: std.mem.Allocator,
    object_store: ?object_store_mod.ObjectStore = null,
    cache_dir: ?[]const u8 = null,
    snapshot_policy: ?SnapshotPolicy = null,
    metrics: obs.StorageMetrics = .{},
    fault_hook: ?DiskFaultHook = null,
    /// When set, storage.get() records each read into this tracker.
    /// Executor sets and clears this around handler calls for OCC conflict detection.
    read_tracker: ?*ReadTracker = null,

    pub fn init(dir: []const u8, alloc: std.mem.Allocator) !Storage {
        mkdirAll(dir);
        return .{
            .tables = std.AutoHashMap(TableId, lsm_mod.LSM).init(alloc),
            .indexes = std.AutoHashMap(IndexId, IndexEntry).init(alloc),
            .dir = dir,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Storage) void {
        var it = self.tables.valueIterator();
        while (it.next()) |lsm| lsm.deinit();
        self.tables.deinit();
        var idx_it = self.indexes.valueIterator();
        while (idx_it.next()) |e| e.deinit();
        self.indexes.deinit();
        if (self.cache_dir) |cd| self.alloc.free(cd);
    }

    pub fn setObjectStore(self: *Storage, store: object_store_mod.ObjectStore, cache_dir: []const u8) !void {
        self.object_store = store;
        if (self.cache_dir) |old| self.alloc.free(old);
        self.cache_dir = try self.alloc.dupe(u8, cache_dir);
    }

    pub fn setSnapshotPolicy(self: *Storage, policy: SnapshotPolicy) void {
        self.snapshot_policy = policy;
    }

    pub fn registerTable(self: *Storage, schema: TableSchema) !void {
        if (self.tables.contains(schema.table_id)) return;
        const table_dir = try std.fmt.allocPrint(self.alloc, "{s}/t{d}", .{ self.dir, schema.table_id });
        defer self.alloc.free(table_dir);
        var lsm = try lsm_mod.LSM.init(schema, table_dir, self.alloc);
        lsm.fault_hook = self.fault_hook;
        if (self.object_store) |store| {
            try lsm.withObjectStore(store, self.cache_dir orelse table_dir);
        }
        try self.tables.put(schema.table_id, lsm);
    }

    pub fn unregisterTable(self: *Storage, table_id: TableId) void {
        if (self.tables.fetchRemove(table_id)) |kv| {
            var lsm = kv.value;
            lsm.deinit();
        }
    }

    /// Register a specialty index (JSON path or vector). Backfills from existing rows.
    /// Domain boundary — desc is fully validated by the gateway; all fields are trusted here.
    pub fn registerIndex(self: *Storage, desc: IndexDesc) !void {
        if (self.indexes.contains(desc.id)) return;

        const idx_dir = try std.fmt.allocPrint(self.alloc, "{s}/idx{d}", .{ self.dir, desc.id });
        defer self.alloc.free(idx_dir);

        const entry: IndexEntry = switch (desc.spec) {
            .json_path => |paths| blk: {
                const idx = try json_index_mod.JsonPathIndex.init(
                    desc.id,
                    desc.table_id,
                    desc.column_idx,
                    paths,
                    idx_dir,
                    self.alloc,
                );
                break :blk .{ .json = idx };
            },
            .vector => |dim| blk: {
                const idx = hnsw_mod.HnswIndex.init(
                    dim,
                    desc.table_id,
                    desc.column_idx,
                    self.alloc,
                );
                break :blk .{ .vector = idx };
            },
        };
        try self.indexes.put(desc.id, entry);

        // Backfill: scan base table and index existing rows
        try self.backfillIndex(desc.id, desc.table_id);
    }

    /// Backfill an index from existing base table rows (all LSM levels).
    fn backfillIndex(self: *Storage, index_id: IndexId, table_id: TableId) !void {
        const entry = self.indexes.getPtr(index_id) orelse return;
        const lsm = self.tables.getPtr(table_id) orelse return;
        const rows = try lsm.scan(KeyRange.all(), std.math.maxInt(Seq), self.alloc);
        defer {
            for (rows) |*r| r.deinit(self.alloc);
            self.alloc.free(rows);
        }
        for (rows) |row| {
            try maintainEntry(entry, row.key, .{ .insert = row.values }, row.seq, self.alloc);
        }
    }

    pub fn get(self: *Storage, table_id: TableId, key: []const u8, at_seq: Seq) !?Row {
        const lsm = self.tables.getPtr(table_id) orelse return error.TableNotFound;
        self.metrics.gets.inc();
        const result = try lsm.get(key, at_seq);
        if (result == null) self.metrics.get_misses.inc();
        if (self.read_tracker) |tracker| {
            const row_seq: Seq = if (result) |row| row.seq else 0;
            // Best-effort: OOM here causes a false negative (no retry trigger).
            // The tracker is advisory; correctness does not depend on it.
            tracker.record(table_id, key, row_seq) catch {};
        }
        return result;
    }

    pub fn apply(self: *Storage, mutations: []const Mutation, at_seq: Seq) !void {
        // Collect pre-images for UPDATE/DELETE mutations in indexed tables —
        // must be read before base-table mutations are applied.
        var pre_images: []?Row = &.{};
        defer {
            for (pre_images) |*r| if (r.*) |*row| row.deinit(self.alloc);
            if (pre_images.len > 0) self.alloc.free(pre_images);
        }
        if (self.indexes.count() > 0) {
            pre_images = try self.applyCollectPreImages(mutations, at_seq);
        }

        var table_ids: std.ArrayListUnmanaged(TableId) = .empty;
        defer table_ids.deinit(self.alloc);
        for (mutations) |m| {
            var found = false;
            for (table_ids.items) |t| {
                if (t == m.table_id) { found = true; break; }
            }
            if (!found) try table_ids.append(self.alloc, m.table_id);
        }

        assert(mutations.len <= std.math.maxInt(u32));
        assert(at_seq <= std.math.maxInt(u32));
        self.metrics.applies.inc();
        self.metrics.mutations_applied.add(@intCast(mutations.len));
        self.metrics.current_seq.set(@intCast(at_seq));

        for (table_ids.items) |tid| {
            const lsm = self.tables.getPtr(tid) orelse return error.TableNotFound;
            const l0_before = lsm.levels[0].files.items.len;
            try lsm.apply(mutations, at_seq);
            const l0_after = lsm.levels[0].files.items.len;
            if (l0_before > 0 and l0_after < l0_before) {
                self.metrics.compactions.inc();
                // Compaction fired; prune tombstoned HNSW nodes for this table.
                var idx_it = self.indexes.iterator();
                while (idx_it.next()) |kv| {
                    switch (kv.value_ptr.*) {
                        .vector => |*v| if (v.table_id == tid) try v.pruneDeleted(),
                        .json => {},
                    }
                }
            }
        }

        if (self.indexes.count() > 0) {
            try self.applyIndexMaintenance(mutations, pre_images, at_seq);
        }

        if (self.snapshot_policy) |*policy| {
            policy.counter += @intCast(mutations.len);
            if (policy.counter >= policy.interval) {
                policy.counter = 0;
                var it = self.tables.valueIterator();
                while (it.next()) |lsm| {
                    var manifest = try snapshot_mod.takeSnapshot(
                        lsm,
                        at_seq,
                        policy.partition_id,
                        policy.store,
                        policy.log_writer,
                        self.alloc,
                    );
                    manifest.deinit();
                }
                self.metrics.snapshots_taken.inc();
                policy.post_snapshot.call(at_seq);
            }
        }
    }

    fn applyCollectPreImages(self: *Storage, mutations: []const Mutation, at_seq: Seq) ![]?Row {
        const pre_images = try self.alloc.alloc(?Row, mutations.len);
        for (pre_images) |*r| r.* = null;
        for (mutations, 0..) |m, i| {
            if (m.kind == .insert) continue;
            if (!self.tableHasIndexes(m.table_id)) continue;
            pre_images[i] = try self.get(m.table_id, m.key, at_seq);
        }
        return pre_images;
    }

    fn applyIndexMaintenance(self: *Storage, mutations: []const Mutation, pre_images: []const ?Row, at_seq: Seq) !void {
        for (mutations, 0..) |m, i| {
            var idx_it = self.indexes.iterator();
            while (idx_it.next()) |kv| {
                const entry = kv.value_ptr;
                if (entry.tableId() != m.table_id) continue;
                const old_row: ?Row = if (pre_images.len > i) pre_images[i] else null;
                // Domain boundary — op is derived from the validated mutation kind;
                // each variant carries exactly the values that exist for that operation.
                const op: IndexOp = switch (m.kind) {
                    .insert => .{ .insert = m.values.? },
                    .delete => .{ .delete = if (old_row) |r| r.values else &.{} },
                    .update => .{ .update = .{
                        .old = if (old_row) |r| r.values else &.{},
                        .new = m.values.?,
                    } },
                };
                try maintainEntry(entry, m.key, op, at_seq, self.alloc);
            }
        }
    }

    pub fn scan(self: *Storage, table_id: TableId, range: KeyRange, at_seq: Seq, alloc: std.mem.Allocator) !ScanIterator {
        const lsm = self.tables.getPtr(table_id) orelse return error.TableNotFound;
        const rows = try lsm.scan(range, at_seq, alloc);
        self.metrics.scans.inc();
        self.metrics.scan_rows_returned.add(@intCast(rows.len));
        return ScanIterator{ .rows = rows, .pos = 0, .alloc = alloc };
    }

    pub fn snapshot(self: *Storage, at_seq: Seq) !SnapshotHandle {
        _ = self;
        return SnapshotHandle{ .seq = at_seq };
    }

    pub fn flushAll(self: *Storage) !void {
        var it = self.tables.valueIterator();
        while (it.next()) |lsm| try lsm.flushMemtable();
    }

    /// Flush all specialty index LSMs to SSTables.
    pub fn flushIndexes(self: *Storage) !void {
        var it = self.indexes.valueIterator();
        while (it.next()) |e| {
            switch (e.*) {
                .json => |*j| try j.lsm.flushMemtable(),
                .vector => {},
            }
        }
    }

    /// Force pruning of tombstoned nodes from all HNSW indexes.
    /// Called automatically after compaction; exposed for testing.
    pub fn pruneVectorIndexes(self: *Storage) !void {
        var it = self.indexes.valueIterator();
        while (it.next()) |e| {
            switch (e.*) {
                .vector => |*v| try v.pruneDeleted(),
                .json => {},
            }
        }
    }

    /// Look up primary keys where json path=value in a JSON path index.
    pub fn indexLookup(
        self: *Storage,
        index_id: IndexId,
        path: []const u8,
        value: []const u8,
        at_seq: Seq,
        alloc: std.mem.Allocator,
    ) !PkList {
        const entry = self.indexes.getPtr(index_id) orelse return error.IndexNotFound;
        switch (entry.*) {
            .json => |*j| return j.lookup(path, value, at_seq, alloc),
            else => return error.WrongIndexType,
        }
    }

    /// ANN search against a vector index.
    pub fn vectorSearch(
        self: *Storage,
        index_id: IndexId,
        query: []const f32,
        k: u32,
        at_seq: Seq,
        alloc: std.mem.Allocator,
    ) ![]Match {
        const entry = self.indexes.getPtr(index_id) orelse return error.IndexNotFound;
        switch (entry.*) {
            .vector => |*v| return v.search(query, k, 64, at_seq, alloc),
            else => return error.WrongIndexType,
        }
    }

    fn tableHasIndexes(self: *const Storage, table_id: TableId) bool {
        var it = self.indexes.valueIterator();
        while (it.next()) |e| {
            if (e.tableId() == table_id) return true;
        }
        return false;
    }
};

/// Typed index maintenance operation — each variant carries exactly the values it needs.
const IndexOp = union(enum) {
    insert: []const ColumnValue,
    delete: []const ColumnValue, // pre-image values
    update: struct { old: []const ColumnValue, new: []const ColumnValue },
};

/// Dispatch index maintenance for a single row mutation.
/// All inputs are fully validated; no optional value chains inside this function.
fn maintainEntry(
    entry: *IndexEntry,
    row_key: []const u8,
    op: IndexOp,
    at_seq: Seq,
    alloc: std.mem.Allocator,
) !void {
    switch (entry.*) {
        .json => |*jidx| switch (op) {
            .insert => |new_vals| {
                const new_json = jsonBytes(new_vals, jidx.column_idx) orelse return;
                try jidx.maintainInsert(row_key, new_json, at_seq);
            },
            .delete => |old_vals| {
                const old_json = jsonBytes(old_vals, jidx.column_idx) orelse return;
                try jidx.maintainDelete(row_key, old_json, at_seq);
            },
            .update => |upd| {
                const new_json = jsonBytes(upd.new, jidx.column_idx) orelse return;
                const old_json = jsonBytes(upd.old, jidx.column_idx) orelse return;
                try jidx.maintainUpdate(row_key, new_json, old_json, at_seq);
            },
        },
        .vector => |*vidx| switch (op) {
            .insert => |new_vals| {
                if (vidx.column_idx >= new_vals.len) return;
                const raw = switch (new_vals[vidx.column_idx]) {
                    .bytes => |b| b,
                    .string => |s| s,
                    else => return,
                };
                const vec = try vector_codec.decode(raw, alloc);
                defer alloc.free(vec);
                std.debug.assert(vec.len == vidx.dim);
                try vidx.insert(vec, row_key, at_seq);
            },
            .delete => _ = vidx.markDeleted(row_key),
            .update => |upd| {
                _ = vidx.markDeleted(row_key);
                if (vidx.column_idx >= upd.new.len) return;
                const raw = switch (upd.new[vidx.column_idx]) {
                    .bytes => |b| b,
                    .string => |s| s,
                    else => return,
                };
                const vec = try vector_codec.decode(raw, alloc);
                defer alloc.free(vec);
                std.debug.assert(vec.len == vidx.dim);
                try vidx.insert(vec, row_key, at_seq);
            },
        },
    }
}

fn jsonBytes(vals: []const ColumnValue, col_idx: u32) ?[]const u8 {
    if (col_idx >= vals.len) return null;
    return switch (vals[col_idx]) {
        .bytes => |b| b,
        .string => |s| s,
        else => null,
    };
}

pub fn mkdirAll(path: []const u8) void {
    const null_path = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(null_path);
    @memcpy(null_path[0..path.len], path);
    _ = std.os.linux.mkdir(null_path.ptr, 0o755);
}
