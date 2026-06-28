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
const partition_util = @import("partition_util.zig");
pub const partitionFor = partition_util.partitionFor;

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
// SAFETY: ptr is never dereferenced by noopPostSnapshotImpl; it ignores its *anyopaque argument.
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
pub const NamespaceId = types.NamespaceId;
pub const Seq = types.Seq;
pub const Row = types.Row;
pub const Mutation = types.Mutation;
pub const MutationKind = types.MutationKind;
pub const KeyRange = types.KeyRange;
pub const SnapshotHandle = types.SnapshotHandle;
pub const ReadTracker = types.ReadTracker;
pub const ReadEntry = types.ReadEntry;

/// One entry in a sequenced apply batch: a slice of mutations sharing a single commit seq.
pub const ApplyBatch = struct {
    mutations: []const Mutation,
    seq: Seq,
};

// Codec
pub const encodeCol = codec_mod.encode;
pub const decodeCol = codec_mod.decode;

// Block
pub const MAX_ROWS_PER_BLOCK = block_mod.MAX_ROWS_PER_BLOCK;
pub const HEADER_SIZE = block_mod.HEADER_SIZE;
pub const FOOTER_SIZE = block_mod.FOOTER_SIZE;
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
        for (self.rows) |r| r.deinit(self.alloc);
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

    pub fn get(self: *PartitionedStorage, namespace_id: NamespaceId, key: []const u8, at_seq: Seq) !?Row {
        return self.partitions[self.partitionIdx(key)].get(namespace_id, key, at_seq);
    }

    /// Scatter scan across all partitions; merge-sort results by key.
    /// Row ownership is transferred: merged ScanIterator owns all row heap data.
    pub fn scan(self: *PartitionedStorage, namespace_id: NamespaceId, range: KeyRange, at_seq: Seq, alloc: std.mem.Allocator) !ScanIterator {
        if (self.partitions.len <= 1) return self.partitions[0].scan(namespace_id, range, at_seq, alloc);
        var merged: std.ArrayList(Row) = .empty;
        errdefer {
            for (merged.items) |r| r.deinit(alloc);
            merged.deinit(alloc);
        }
        var found_any = false;
        for (self.partitions) |p| {
            const iter = p.scan(namespace_id, range, at_seq, alloc) catch |e| {
                if (e == error.NamespaceNotFound) continue;
                return e;
            };
            found_any = true;
            // Transfer row structs to merged; free only the original slice header.
            // Row heap data (key, values) is now owned by merged.
            try merged.appendSlice(alloc, iter.rows);
            alloc.free(iter.rows);
        }
        if (!found_any) return error.NamespaceNotFound;
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

    /// Register a namespace on every partition.
    pub fn registerNamespace(self: *PartitionedStorage, namespace_id: NamespaceId) !void {
        for (self.partitions) |p| try p.registerNamespace(namespace_id);
    }

    pub fn unregisterNamespace(self: *PartitionedStorage, namespace_id: NamespaceId) void {
        for (self.partitions) |p| p.unregisterNamespace(namespace_id);
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

    /// Free the partitions slice. Does NOT deinit the Storage objects (caller owns them).
    pub fn deinit(self: *PartitionedStorage) void {
        self.alloc.free(self.partitions);
    }
};

pub const StorageMetrics = obs.StorageMetrics;

pub const DiskFaultHook = lsm_mod.DiskFaultHook;

pub const Storage = struct {
    namespaces: std.AutoHashMap(NamespaceId, lsm_mod.LSM),
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
            .namespaces = std.AutoHashMap(NamespaceId, lsm_mod.LSM).init(alloc),
            .dir = dir,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Storage) void {
        var it = self.namespaces.valueIterator();
        while (it.next()) |lsm| lsm.deinit();
        self.namespaces.deinit();
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

    pub fn registerNamespace(self: *Storage, namespace_id: NamespaceId) !void {
        if (self.namespaces.contains(namespace_id)) return;
        const namespace_dir = try std.fmt.allocPrint(self.alloc, "{s}/n{d}", .{ self.dir, namespace_id });
        defer self.alloc.free(namespace_dir);
        var lsm = try lsm_mod.LSM.init(namespace_dir, self.alloc);
        lsm.fault_hook = self.fault_hook;
        if (self.object_store) |store| {
            try lsm.withObjectStore(store, self.cache_dir orelse namespace_dir);
        }
        try self.namespaces.put(namespace_id, lsm);
    }

    pub fn unregisterNamespace(self: *Storage, namespace_id: NamespaceId) void {
        if (self.namespaces.fetchRemove(namespace_id)) |kv| {
            var lsm = kv.value;
            lsm.deinit();
        }
    }

    pub fn get(self: *Storage, namespace_id: NamespaceId, key: []const u8, at_seq: Seq) !?Row {
        const lsm = self.namespaces.getPtr(namespace_id) orelse return error.NamespaceNotFound;
        self.metrics.gets.inc();
        const result = try lsm.get(key, at_seq);
        if (result == null) self.metrics.get_misses.inc();
        if (self.read_tracker) |tracker| {
            const row_seq: Seq = if (result) |row| row.seq else 0;
            // Best-effort: OOM here causes a false negative (no retry trigger).
            // The tracker is advisory; correctness does not depend on it.
            tracker.record(namespace_id, key, row_seq) catch |err| std.log.warn("read tracker record: {}", .{err});
        }
        return result;
    }

    pub fn apply(self: *Storage, mutations: []const Mutation, at_seq: Seq) !void {
        var namespace_ids: std.ArrayListUnmanaged(NamespaceId) = .empty;
        defer namespace_ids.deinit(self.alloc);
        for (mutations) |m| {
            var found = false;
            for (namespace_ids.items) |t| {
                if (t == m.namespace_id) {
                    found = true;
                    break;
                }
            }
            if (!found) try namespace_ids.append(self.alloc, m.namespace_id);
        }

        assert(mutations.len <= std.math.maxInt(u32));
        assert(at_seq <= std.math.maxInt(u32));
        self.metrics.applies.inc();
        self.metrics.mutations_applied.add(@intCast(mutations.len));
        self.metrics.current_seq.set(@intCast(at_seq));

        for (namespace_ids.items) |nid| {
            const lsm = self.namespaces.getPtr(nid) orelse return error.NamespaceNotFound;
            const l0_before = lsm.levels[0].files.items.len;
            try lsm.apply(mutations, at_seq);
            const l0_after = lsm.levels[0].files.items.len;
            if (l0_before > 0 and l0_after < l0_before) {
                self.metrics.compactions.inc();
            }
        }

        if (self.snapshot_policy) |*policy| {
            policy.counter += @intCast(mutations.len);
            if (policy.counter >= policy.interval) {
                policy.counter = 0;
                var it = self.namespaces.valueIterator();
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

    /// Apply a sequence of (mutations, seq) pairs in one call.
    /// Each pair's mutations are stamped with their own seq, preserving MVCC correctness.
    /// Metrics and snapshot policy are updated once per batch instead of per entry.
    pub fn apply_sequenced(self: *Storage, batch: []const ApplyBatch) !void {
        if (batch.len == 0) return;

        var total_mutations: usize = 0;
        var last_seq: Seq = 0;

        for (batch) |b| {
            if (b.mutations.len == 0) {
                last_seq = b.seq;
                continue;
            }

            var namespace_ids: std.ArrayListUnmanaged(NamespaceId) = .empty;
            defer namespace_ids.deinit(self.alloc);
            for (b.mutations) |m| {
                var found = false;
                for (namespace_ids.items) |t| {
                    if (t == m.namespace_id) {
                        found = true;
                        break;
                    }
                }
                if (!found) try namespace_ids.append(self.alloc, m.namespace_id);
            }

            for (namespace_ids.items) |nid| {
                const lsm = self.namespaces.getPtr(nid) orelse return error.NamespaceNotFound;
                const l0_before = lsm.levels[0].files.items.len;
                try lsm.apply(b.mutations, b.seq);
                const l0_after = lsm.levels[0].files.items.len;
                if (l0_before > 0 and l0_after < l0_before) {
                    self.metrics.compactions.inc();
                }
            }

            total_mutations += b.mutations.len;
            last_seq = b.seq;
        }

        assert(total_mutations <= std.math.maxInt(u32));
        assert(last_seq <= std.math.maxInt(u32));
        self.metrics.applies.inc();
        self.metrics.mutations_applied.add(@intCast(total_mutations));
        self.metrics.current_seq.set(@intCast(last_seq));

        if (self.snapshot_policy) |*policy| {
            policy.counter += @intCast(total_mutations);
            if (policy.counter >= policy.interval) {
                policy.counter = 0;
                var it = self.namespaces.valueIterator();
                while (it.next()) |lsm| {
                    var manifest = try snapshot_mod.takeSnapshot(
                        lsm,
                        last_seq,
                        policy.partition_id,
                        policy.store,
                        policy.log_writer,
                        self.alloc,
                    );
                    manifest.deinit();
                }
                self.metrics.snapshots_taken.inc();
                policy.post_snapshot.call(last_seq);
            }
        }
    }

    pub fn scan(self: *Storage, namespace_id: NamespaceId, range: KeyRange, at_seq: Seq, alloc: std.mem.Allocator) !ScanIterator {
        const lsm = self.namespaces.getPtr(namespace_id) orelse return error.NamespaceNotFound;
        const rows = try lsm.scan(range, at_seq, alloc);
        self.metrics.scans.inc();
        self.metrics.scan_rows_returned.add(@intCast(rows.len));
        if (self.read_tracker) |tracker| {
            for (rows) |row| {
                // Record each returned row so OCC detects writes to those keys after
                // recon_seq. Best-effort: OOM here causes a false negative (no retry).
                tracker.record(namespace_id, row.key, row.seq) catch |err|
                    std.log.warn("read tracker record: {}", .{err});
            }
            // Note: new rows inserted into this range after recon_seq (phantoms) are
            // not detected here — range predicate tracking requires a separate extension
            // to ReadEntry and is not yet implemented.
        }
        return ScanIterator{ .rows = rows, .pos = 0, .alloc = alloc };
    }

    pub fn snapshot(self: *Storage, at_seq: Seq) !SnapshotHandle {
        _ = self;
        return SnapshotHandle{ .seq = at_seq };
    }

    pub fn flushAll(self: *Storage) !void {
        var it = self.namespaces.valueIterator();
        while (it.next()) |lsm| try lsm.flushMemtable();
    }

    pub fn compactAll(self: *Storage) !void {
        var it = self.namespaces.valueIterator();
        while (it.next()) |lsm| try lsm.maybeCompact();
    }
};

pub fn mkdirAll(path: []const u8) void {
    const null_path = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(null_path);
    @memcpy(null_path[0..path.len], path);
    _ = std.os.linux.mkdir(null_path.ptr, 0o755);
}
