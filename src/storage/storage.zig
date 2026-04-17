/// Public storage API: unified module re-exporting all storage types.
const std = @import("std");
const types = @import("types.zig");
const lsm_mod = @import("lsm.zig");
const codec_mod = @import("codec.zig");
const block_mod = @import("block.zig");
const sstable_mod = @import("sstable.zig");

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

pub const ScanIterator = struct {
    rows:  []Row,
    pos:   usize,
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
    }

    pub fn registerTable(self: *Storage, schema: TableSchema) !void {
        if (self.tables.contains(schema.table_id)) return;
        const table_dir = try std.fmt.allocPrint(self.alloc, "{s}/t{d}", .{ self.dir, schema.table_id });
        defer self.alloc.free(table_dir);
        const lsm = try lsm_mod.LSM.init(schema, table_dir, self.alloc);
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
                if (t == m.table_id) { found = true; break; }
            }
            if (!found) try table_ids.append(self.alloc, m.table_id);
        }

        for (table_ids.items) |tid| {
            const lsm = self.tables.getPtr(tid) orelse return error.TableNotFound;
            try lsm.apply(mutations, at_seq);
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
