/// JSON path index: an LSM whose keys are (path, value, primary_key).
/// Paths are declared at index creation time.
const std = @import("std");
const types = @import("types.zig");
const lsm_mod = @import("lsm.zig");
const json_path_mod = @import("json_path.zig");

const TableId = types.TableId;
const Seq = types.Seq;
const Mutation = types.Mutation;
const MutationKind = types.MutationKind;
const ColumnValue = types.ColumnValue;
const KeyRange = types.KeyRange;
const Row = types.Row;

pub const PkList = struct {
    pks: []const []u8,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *PkList) void {
        for (self.pks) |pk| self.alloc.free(pk);
        self.alloc.free(self.pks);
    }
};

pub const JsonPathIndex = struct {
    lsm: lsm_mod.LSM,
    table_id: TableId,
    column_idx: u32,
    paths: []const []const u8,
    alloc: std.mem.Allocator,

    pub fn init(
        index_id: u32,
        table_id: TableId,
        column_idx: u32,
        paths: []const []const u8,
        dir: []const u8,
        alloc: std.mem.Allocator,
    ) !JsonPathIndex {
        // Index LSM schema: no value columns — keys encode everything
        const schema = types.TableSchema{
            .table_id = @intCast(index_id),
            .columns = &.{},
        };
        const lsm = try lsm_mod.LSM.init(schema, dir, alloc);

        const owned_paths = try alloc.alloc([]const u8, paths.len);
        errdefer alloc.free(owned_paths);
        for (paths, 0..) |p, i| owned_paths[i] = try alloc.dupe(u8, p);

        return .{
            .lsm = lsm,
            .table_id = table_id,
            .column_idx = column_idx,
            .paths = owned_paths,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *JsonPathIndex) void {
        self.lsm.deinit();
        for (self.paths) |p| self.alloc.free(p);
        self.alloc.free(self.paths);
    }

    /// Index a newly inserted row. json must be the row's JSON column bytes.
    pub fn maintainInsert(self: *JsonPathIndex, row_key: []const u8, json: []const u8, at_seq: Seq) !void {
        for (self.paths) |path| {
            const raw = (try json_path_mod.extract(json, path, self.alloc)) orelse continue;
            defer self.alloc.free(raw);
            const norm = try json_path_mod.normalizeValue(raw, self.alloc);
            defer self.alloc.free(norm);
            const idx_key = try encodeKey(path, norm, row_key, self.alloc);
            defer self.alloc.free(idx_key);
            const m = Mutation{ .kind = .insert, .table_id = self.lsm.schema.table_id, .key = idx_key, .values = &.{} };
            try self.lsm.apply(&.{m}, at_seq);
        }
    }

    /// Remove index entries for a deleted row. json must be the row's previous JSON column bytes.
    pub fn maintainDelete(self: *JsonPathIndex, row_key: []const u8, json: []const u8, at_seq: Seq) !void {
        for (self.paths) |path| {
            const raw = (try json_path_mod.extract(json, path, self.alloc)) orelse continue;
            defer self.alloc.free(raw);
            const norm = try json_path_mod.normalizeValue(raw, self.alloc);
            defer self.alloc.free(norm);
            const idx_key = try encodeKey(path, norm, row_key, self.alloc);
            defer self.alloc.free(idx_key);
            const m = Mutation{ .kind = .delete, .table_id = self.lsm.schema.table_id, .key = idx_key, .values = null };
            try self.lsm.apply(&.{m}, at_seq);
        }
    }

    /// Update index entries for a modified row.
    pub fn maintainUpdate(self: *JsonPathIndex, row_key: []const u8, new_json: []const u8, old_json: []const u8, at_seq: Seq) !void {
        try self.maintainDelete(row_key, old_json, at_seq);
        try self.maintainInsert(row_key, new_json, at_seq);
    }

    /// Return primary keys where path equals value, as of at_seq.
    /// Scans all LSM levels (memtable + SSTables).
    pub fn lookup(
        self: *JsonPathIndex,
        path: []const u8,
        value: []const u8,
        at_seq: Seq,
        alloc: std.mem.Allocator,
    ) !PkList {
        const start_key = try encodeKey(path, value, "", alloc);
        defer alloc.free(start_key);
        const end_key = try encodeKeyEnd(path, value, alloc);
        defer alloc.free(end_key);

        const range = KeyRange{
            .start = start_key,
            .end = end_key,
            .start_inclusive = true,
        };

        const rows = try self.lsm.scan(range, at_seq, alloc);
        defer {
            for (rows) |*r| r.deinit(alloc);
            alloc.free(rows);
        }

        var pks: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (pks.items) |pk| alloc.free(pk);
            pks.deinit(alloc);
        }

        for (rows) |row| {
            const pk = decodeKeyPk(row.key, path.len, value.len);
            try pks.append(alloc, try alloc.dupe(u8, pk));
        }

        return PkList{ .pks = try pks.toOwnedSlice(alloc), .alloc = alloc };
    }
};

/// Key format: [4B path_len][path][4B value_len][value][pk]
/// All lengths big-endian so keys sort by (path, value, pk).
pub fn encodeKey(path: []const u8, value: []const u8, pk: []const u8, alloc: std.mem.Allocator) ![]u8 {
    const total = 4 + path.len + 4 + value.len + pk.len;
    const buf = try alloc.alloc(u8, total);
    var pos: usize = 0;
    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(path.len), .big);
    pos += 4;
    @memcpy(buf[pos..][0..path.len], path);
    pos += path.len;
    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(value.len), .big);
    pos += 4;
    @memcpy(buf[pos..][0..value.len], value);
    pos += value.len;
    @memcpy(buf[pos..][0..pk.len], pk);
    return buf;
}

/// End key for range scan: includes all pks for (path, value).
fn encodeKeyEnd(path: []const u8, value: []const u8, alloc: std.mem.Allocator) ![]u8 {
    const total = 4 + path.len + 4 + value.len + 1;
    const buf = try alloc.alloc(u8, total);
    var pos: usize = 0;
    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(path.len), .big);
    pos += 4;
    @memcpy(buf[pos..][0..path.len], path);
    pos += path.len;
    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(value.len), .big);
    pos += 4;
    @memcpy(buf[pos..][0..value.len], value);
    pos += value.len;
    buf[pos] = 0xFF;
    return buf;
}

/// Extract pk from a composite key given path and value lengths.
fn decodeKeyPk(key: []const u8, path_len: usize, value_len: usize) []const u8 {
    const offset = 4 + path_len + 4 + value_len;
    return key[offset..];
}
