/// Public storage API: unified module re-exporting all storage types.
const std = @import("std");
const types = @import("types.zig");
const lsm_mod = @import("lsm.zig");
const codec_mod = @import("codec.zig");
const block_mod = @import("block.zig");
const sstable_mod = @import("sstable.zig");
const object_store_mod = @import("object_store.zig");
const snapshot_mod = @import("snapshot.zig");

pub const SnapshotLogWriter = snapshot_mod.SnapshotLogWriter;

/// Called after each successful snapshot with the snapshot seq.
/// Allows callers to trigger log truncation and idempotency cache eviction.
pub const PostSnapshotHook = struct {
    ptr: *anyopaque,
    hookFn: *const fn (*anyopaque, seq: Seq) void,

    pub fn call(self: PostSnapshotHook, seq: Seq) void {
        self.hookFn(self.ptr, seq);
    }
};

pub const SnapshotPolicy = struct {
    interval: u64,
    counter: u64 = 0,
    store: object_store_mod.ObjectStore,
    log_writer: ?snapshot_mod.SnapshotLogWriter = null,
    partition_id: u32 = 0,
    post_snapshot: ?PostSnapshotHook = null,
};

// Core types
pub const TableId = types.TableId;
pub const Seq = types.Seq;
pub const ColumnType = types.ColumnType;
pub const ColumnSchema = types.ColumnSchema;
pub const TableSchema = types.TableSchema;
pub const ColumnValue = types.ColumnValue;
pub const Row = types.Row;
pub const Mutation = types.Mutation;
pub const MutationKind = types.MutationKind;
pub const KeyRange = types.KeyRange;
pub const SnapshotHandle = types.SnapshotHandle;

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

pub const Storage = struct {
    tables: std.AutoHashMap(TableId, lsm_mod.LSM),
    dir: []const u8,
    alloc: std.mem.Allocator,
    object_store: ?object_store_mod.ObjectStore = null,
    cache_dir: ?[]const u8 = null,
    snapshot_policy: ?SnapshotPolicy = null,

    pub fn init(dir: []const u8, alloc: std.mem.Allocator) !Storage {
        mkdirAll(dir);
        return .{
            .tables = std.AutoHashMap(TableId, lsm_mod.LSM).init(alloc),
            .dir = dir,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Storage) void {
        var it = self.tables.valueIterator();
        while (it.next()) |lsm| lsm.deinit();
        self.tables.deinit();
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
        if (self.object_store) |store| {
            lsm.withObjectStore(store, self.cache_dir orelse table_dir);
        }
        try self.tables.put(schema.table_id, lsm);
    }

    pub fn get(self: *Storage, table_id: TableId, key: []const u8, at_seq: Seq) !?Row {
        const lsm = self.tables.getPtr(table_id) orelse return error.TableNotFound;
        return lsm.get(key, at_seq);
    }

    pub fn apply(self: *Storage, mutations: []const Mutation, at_seq: Seq) !void {
        var table_ids: std.ArrayList(TableId) = .empty;
        defer table_ids.deinit(self.alloc);

        for (mutations) |m| {
            var found = false;
            for (table_ids.items) |t| {
                if (t == m.table_id) {
                    found = true;
                    break;
                }
            }
            if (!found) try table_ids.append(self.alloc, m.table_id);
        }

        for (table_ids.items) |tid| {
            const lsm = self.tables.getPtr(tid) orelse return error.TableNotFound;
            try lsm.apply(mutations, at_seq);
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
                if (policy.post_snapshot) |hook| hook.call(at_seq);
            }
        }
    }

    pub fn scan(self: *Storage, table_id: TableId, range: KeyRange, at_seq: Seq, alloc: std.mem.Allocator) !ScanIterator {
        const lsm = self.tables.getPtr(table_id) orelse return error.TableNotFound;
        var it = lsm.memtable.rangeEntries(range, at_seq);
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        errdefer {
            for (rows.items) |*r| r.deinit(alloc);
            rows.deinit(alloc);
        }
        while (it.next()) |entry| {
            if (entry.is_tombstone) continue;
            const vals = entry.values orelse continue;
            const key_copy = try alloc.dupe(u8, entry.key);
            errdefer alloc.free(key_copy);
            const vals_copy = try alloc.alloc(ColumnValue, vals.len);
            errdefer alloc.free(vals_copy);
            for (vals, 0..) |v, i| vals_copy[i] = try v.dupe(alloc);
            try rows.append(alloc, Row{ .key = key_copy, .seq = entry.seq, .values = vals_copy });
        }
        return ScanIterator{ .rows = try rows.toOwnedSlice(alloc), .pos = 0, .alloc = alloc };
    }

    pub fn snapshot(self: *Storage, at_seq: Seq) !SnapshotHandle {
        _ = self;
        return SnapshotHandle{ .seq = at_seq };
    }

    pub fn flushAll(self: *Storage) !void {
        var it = self.tables.valueIterator();
        while (it.next()) |lsm| try lsm.flushMemtable();
    }
};

fn mkdirAll(path: []const u8) void {
    const null_path = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(null_path);
    @memcpy(null_path[0..path.len], path);
    _ = std.os.linux.mkdir(null_path.ptr, 0o755);
}
