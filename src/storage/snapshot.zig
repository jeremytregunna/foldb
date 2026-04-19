const std = @import("std");
const lsm_mod = @import("lsm.zig");
const sstable_mod = @import("sstable.zig");
const object_store_mod = @import("object_store.zig");
const types = @import("types.zig");

const LSM = lsm_mod.LSM;
const SSTableMeta = sstable_mod.SSTableMeta;
const ObjectStore = object_store_mod.ObjectStore;
const TableSchema = types.TableSchema;
const Seq = types.Seq;

/// Callback for writing a snapshot_marker entry to a log.
/// Implemented by callers who have a *Log reference.
pub const SnapshotLogWriter = struct {
    ptr: *anyopaque,
    writeFn: *const fn (*anyopaque, manifest_key: []const u8, seq: u64, partition_id: u32, alloc: std.mem.Allocator) anyerror!void,

    pub fn write(self: SnapshotLogWriter, manifest_key: []const u8, seq: u64, pid: u32, alloc: std.mem.Allocator) !void {
        return self.writeFn(self.ptr, manifest_key, seq, pid, alloc);
    }
};

const MANIFEST_MAGIC: [4]u8 = .{ 'F', 'S', 'N', 'P' };
const MANIFEST_VERSION: u32 = 1;

pub const SnapshotManifest = struct {
    seq: u64,
    partition_id: u32,
    sstable_keys: []const []const u8,
    manifest_key: []const u8,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *SnapshotManifest) void {
        for (self.sstable_keys) |k| self.alloc.free(k);
        self.alloc.free(self.sstable_keys);
        self.alloc.free(self.manifest_key);
    }
};

/// Serialize manifest to binary:
/// magic(4) version(4) seq(8) partition_id(4) count(4) then for each: key_len(4) + key bytes
pub fn manifestToBytes(m: *const SnapshotManifest, alloc: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    try buf.appendSlice(alloc, &MANIFEST_MAGIC);

    var v: u32 = MANIFEST_VERSION;
    try buf.appendSlice(alloc, std.mem.asBytes(&v));

    var seq = m.seq;
    try buf.appendSlice(alloc, std.mem.asBytes(&seq));

    var pid = m.partition_id;
    try buf.appendSlice(alloc, std.mem.asBytes(&pid));

    var count: u32 = @intCast(m.sstable_keys.len);
    try buf.appendSlice(alloc, std.mem.asBytes(&count));

    for (m.sstable_keys) |k| {
        var klen: u32 = @intCast(k.len);
        try buf.appendSlice(alloc, std.mem.asBytes(&klen));
        try buf.appendSlice(alloc, k);
    }

    return buf.toOwnedSlice(alloc);
}

pub fn manifestFromBytes(data: []const u8, manifest_key: []const u8, alloc: std.mem.Allocator) !SnapshotManifest {
    if (data.len < 4 + 4 + 8 + 4 + 4) return error.InvalidManifest;
    if (!std.mem.eql(u8, data[0..4], &MANIFEST_MAGIC)) return error.InvalidMagicManifest;

    var pos: usize = 4;
    const version = std.mem.readInt(u32, data[pos..][0..4], .little);
    if (version != MANIFEST_VERSION) return error.UnsupportedManifestVersion;
    pos += 4;

    const seq = std.mem.readInt(u64, data[pos..][0..8], .little);
    pos += 8;

    const partition_id = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    const count = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    var keys: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (keys.items) |k| alloc.free(k);
        keys.deinit(alloc);
    }

    for (0..count) |_| {
        if (pos + 4 > data.len) return error.InvalidManifest;
        const klen = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        if (pos + klen > data.len) return error.InvalidManifest;
        const k = try alloc.dupe(u8, data[pos .. pos + klen]);
        try keys.append(alloc, k);
        pos += klen;
    }

    const mk_copy = try alloc.dupe(u8, manifest_key);
    errdefer alloc.free(mk_copy);

    return .{
        .seq = seq,
        .partition_id = partition_id,
        .sstable_keys = try keys.toOwnedSlice(alloc),
        .manifest_key = mk_copy,
        .alloc = alloc,
    };
}

pub fn takeSnapshot(
    lsm: *LSM,
    at_seq: u64,
    partition_id: u32,
    store: ObjectStore,
    log_writer: ?SnapshotLogWriter,
    alloc: std.mem.Allocator,
) !SnapshotManifest {
    // Flush memtable first
    try lsm.flushMemtable();

    const metas = try lsm.listLocalSSTables(alloc);
    defer {
        for (metas) |*m| {
            var mm = m.*;
            mm.deinit(alloc);
        }
        alloc.free(metas);
    }

    var keys: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (keys.items) |k| alloc.free(k);
        keys.deinit(alloc);
    }

    for (metas) |*meta| {
        const obj_key = try std.fmt.allocPrint(alloc, "snapshots/{d}/{d}/L{d}_{d}.sst", .{ partition_id, at_seq, meta.level, keys.items.len });
        errdefer alloc.free(obj_key);

        // Read file and upload
        const file_data = readFileAlloc(meta.path, alloc) catch {
            alloc.free(obj_key);
            continue;
        };
        defer alloc.free(file_data);

        try store.put(obj_key, file_data);
        try keys.append(alloc, obj_key);
    }

    const manifest_key = try std.fmt.allocPrint(alloc, "snapshots/{d}/{d}/manifest", .{ partition_id, at_seq });
    errdefer alloc.free(manifest_key);

    var manifest = SnapshotManifest{
        .seq = at_seq,
        .partition_id = partition_id,
        .sstable_keys = try keys.toOwnedSlice(alloc),
        .manifest_key = manifest_key,
        .alloc = alloc,
    };

    const manifest_bytes = try manifestToBytes(&manifest, alloc);
    defer alloc.free(manifest_bytes);

    try store.put(manifest_key, manifest_bytes);

    if (log_writer) |lw| {
        try lw.write(manifest.manifest_key, at_seq, partition_id, alloc);
    }

    return manifest;
}

pub fn restoreFromSnapshot(
    manifest: *const SnapshotManifest,
    lsm_dir: []const u8,
    store: ObjectStore,
    schema: TableSchema,
    alloc: std.mem.Allocator,
) !LSM {
    try mkdirAll(lsm_dir);

    var lsm = try LSM.init(schema, lsm_dir, alloc);
    errdefer lsm.deinit();

    for (manifest.sstable_keys) |obj_key| {
        // This is the domain boundary — raw SSTable bytes are fetched from the
        // object store (cold tier) and written to local disk; SSTableReader.open
        // validates structural integrity before the file is registered with the LSM.
        const file_data = try store.get(obj_key, alloc);
        defer alloc.free(file_data);

        // Derive local filename from object key
        const basename = std.fs.path.basename(obj_key);
        const local_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ lsm_dir, basename });
        defer alloc.free(local_path);

        try writeFile(local_path, file_data);

        // Open and register with LSM
        var reader = try sstable_mod.SSTableReader.open(local_path, schema, alloc);
        defer reader.deinit();
        var m = try reader.meta(local_path, alloc);
        m.remote_key = try alloc.dupe(u8, obj_key);

        const level: usize = @min(@as(usize, m.level), 3);
        try lsm.levels[level].files.append(alloc, m);
    }

    return lsm;
}

pub const SnapshotMarkerPayload = struct {
    manifest_key: []const u8,
    seq: u64,
    partition_id: u32,

    /// Format: manifest_key_len(4) + manifest_key bytes + seq(8) + partition_id(4)
    pub fn serialize(self: *const SnapshotMarkerPayload, alloc: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);

        var klen: u32 = @intCast(self.manifest_key.len);
        try buf.appendSlice(alloc, std.mem.asBytes(&klen));
        try buf.appendSlice(alloc, self.manifest_key);

        var seq = self.seq;
        try buf.appendSlice(alloc, std.mem.asBytes(&seq));

        var pid = self.partition_id;
        try buf.appendSlice(alloc, std.mem.asBytes(&pid));

        return buf.toOwnedSlice(alloc);
    }

    pub fn deserialize(data: []const u8, alloc: std.mem.Allocator) !SnapshotMarkerPayload {
        if (data.len < 4) return error.InvalidSnapshotMarker;
        const klen = std.mem.readInt(u32, data[0..4], .little);
        if (data.len < 4 + klen + 8 + 4) return error.InvalidSnapshotMarker;

        const mk = try alloc.dupe(u8, data[4 .. 4 + klen]);
        errdefer alloc.free(mk);

        var pos: usize = 4 + klen;
        const seq = std.mem.readInt(u64, data[pos..][0..8], .little);
        pos += 8;
        const pid = std.mem.readInt(u32, data[pos..][0..4], .little);

        return .{
            .manifest_key = mk,
            .seq = seq,
            .partition_id = pid,
        };
    }

    pub fn deinit(self: *SnapshotMarkerPayload, alloc: std.mem.Allocator) void {
        alloc.free(self.manifest_key);
    }
};

// ---- file helpers (duplicated from lsm.zig to avoid circular dependency) ----

fn mkdirAll(path: []const u8) !void {
    const null_path = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    defer std.heap.page_allocator.free(null_path);
    @memcpy(null_path[0..path.len], path);
    _ = std.os.linux.mkdir(null_path.ptr, 0o755);
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
