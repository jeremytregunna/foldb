/// KV block: key-value pairs packed for SSTable storage.
/// Format: [header][keys:offsets + key_data + seqs][values:len-prefix blobs][footer]
const std = @import("std");

const assert = std.debug.assert;
const types = @import("types.zig");
const crc_mod = @import("crc.zig");

const Row = types.Row;
const Seq = types.Seq;

pub const MAGIC: [4]u8 = .{ 'F', 'K', 'V', '1' };
pub const MAX_ROWS_PER_BLOCK: usize = 512;
/// Tombstone marker: high bit of seq indicates deleted row.
pub const TOMBSTONE_BIT: Seq = 1 << 63;
pub const MAX_BLOCK_SIZE: usize = 64 * 1024;
pub const HEADER_SIZE: usize = 20;
pub const FOOTER_SIZE: usize = 8;

/// On-disk block header, fixed 20 bytes.
pub const BlockHeader = extern struct {
    magic: [4]u8,
    row_count: u32,
    key_data_offset: u32,  // == HEADER_SIZE
    values_offset: u32,    // after key section + seqs
    footer_offset: u32,

    comptime {
        std.debug.assert(@sizeOf(BlockHeader) == HEADER_SIZE);
    }
};

/// On-disk block footer, fixed 8 bytes.
pub const BlockFooter = extern struct {
    block_size: u32,
    crc: u32,

    comptime {
        std.debug.assert(@sizeOf(BlockFooter) == FOOTER_SIZE);
    }
};

// --- BlockWriter ---

pub const BlockWriter = struct {
    // Parallel arrays
    keys: std.ArrayListUnmanaged([]const u8) = .empty,
    seqs: std.ArrayListUnmanaged(Seq) = .empty,
    values: std.ArrayListUnmanaged([]const u8) = .empty,
    size_estimate: usize = HEADER_SIZE + FOOTER_SIZE,

    pub fn init(_: std.mem.Allocator) BlockWriter {
        return .{};
    }

    pub fn deinit(self: *BlockWriter, alloc: std.mem.Allocator) void {
        for (self.keys.items) |k| alloc.free(k);
        self.keys.deinit(alloc);
        self.seqs.deinit(alloc);
        for (self.values.items) |v| alloc.free(v);
        self.values.deinit(alloc);
    }

    pub fn isFull(self: *const BlockWriter) bool {
        return self.keys.items.len >= MAX_ROWS_PER_BLOCK or
            self.size_estimate >= MAX_BLOCK_SIZE;
    }

    pub fn isEmpty(self: *const BlockWriter) bool {
        return self.keys.items.len == 0;
    }

    /// Append a row. value=null means tombstone (TOMBSTONE_BIT set on seq).
    pub fn append(
        self: *BlockWriter,
        alloc: std.mem.Allocator,
        key: []const u8,
        seq: Seq,
        value: ?[]const u8,
    ) !void {
        const key_copy = try alloc.dupe(u8, key);
        errdefer alloc.free(key_copy);
        try self.keys.append(alloc, key_copy);

        const encoded_seq = if (value == null) seq | TOMBSTONE_BIT else seq;
        try self.seqs.append(alloc, encoded_seq);

        if (value) |v| {
            const val_copy = try alloc.dupe(u8, v);
            errdefer alloc.free(val_copy);
            try self.values.append(alloc, val_copy);
        } else {
            try self.values.append(alloc, ""); // empty placeholder for tombstones
        }
        self.size_estimate += key.len + 8 + (if (value) |v| v.len else 0) + 4; // +4 for value length prefix
    }

    /// Serialize to a heap-allocated buffer (caller owns result).
    pub fn flush(self: *BlockWriter, alloc: std.mem.Allocator) ![]u8 {
        assert(self.keys.items.len > 0);
        assert(self.keys.items.len <= std.math.maxInt(u32));
        const row_count: u32 = @intCast(self.keys.items.len);

        var key_section = try buildKeySection(self, row_count, alloc);
        defer key_section.deinit(alloc);

        var values_section = try buildValuesSection(self, alloc);
        defer values_section.deinit(alloc);

        assert(key_section.items.len <= std.math.maxInt(u32));
        assert(values_section.items.len <= std.math.maxInt(u32));
        const key_offset: u32 = HEADER_SIZE;
        const values_offset: u32 = key_offset + @as(u32, @intCast(key_section.items.len));
        const footer_offset: u32 = values_offset + @as(u32, @intCast(values_section.items.len));
        const total_size: u32 = @intCast(footer_offset + FOOTER_SIZE);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.ensureTotalCapacity(alloc, @as(usize, total_size));

        const hdr = BlockHeader{
            .magic = MAGIC,
            .row_count = row_count,
            .key_data_offset = key_offset,
            .values_offset = values_offset,
            .footer_offset = footer_offset,
        };
        try out.appendSlice(alloc, std.mem.asBytes(&hdr));
        try out.appendSlice(alloc, key_section.items);
        try out.appendSlice(alloc, values_section.items);

        const checksum = crc_mod.crc32c(out.items);
        const footer = BlockFooter{ .block_size = total_size, .crc = checksum };
        try out.appendSlice(alloc, std.mem.asBytes(&footer));

        return out.toOwnedSlice(alloc);
    }
};

/// Build key section: [row_count × 4 offsets][key_data][row_count × 8 seqs]
fn buildKeySection(w: *const BlockWriter, row_count: u32, alloc: std.mem.Allocator) !std.ArrayList(u8) {
    assert(row_count == w.keys.items.len);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    // Key offsets
    var key_data: std.ArrayList(u8) = .empty;
    defer key_data.deinit(alloc);
    for (w.keys.items) |k| {
        assert(key_data.items.len <= std.math.maxInt(u32));
        var off_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &off_buf, @intCast(key_data.items.len), .little);
        try buf.appendSlice(alloc, &off_buf);
        try key_data.appendSlice(alloc, k);
    }

    // Key data
    try buf.appendSlice(alloc, key_data.items);

    // Seqs
    for (w.seqs.items) |s| {
        var seq_b: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq_b, s, .little);
        try buf.appendSlice(alloc, &seq_b);
    }

    return buf;
}

/// Build values section: [len32 + data] per row
fn buildValuesSection(w: *const BlockWriter, alloc: std.mem.Allocator) !std.ArrayList(u8) {
    var section: std.ArrayList(u8) = .empty;
    errdefer section.deinit(alloc);
    for (w.values.items) |v| {
        const len: u32 = @intCast(v.len);
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, len, .little);
        try section.appendSlice(alloc, &len_buf);
        try section.appendSlice(alloc, v);
    }
    return section;
}

// --- BlockReader ---

pub const BlockReader = struct {
    data: []const u8,
    header: BlockHeader,
    row_count: u32,
    key_data_start: u32,
    seq_section_start: u32,

    pub fn init(data: []const u8) !BlockReader {
        if (data.len < HEADER_SIZE + FOOTER_SIZE) return error.BlockTooSmall;
        const hdr: BlockHeader = std.mem.bytesToValue(BlockHeader, data[0..HEADER_SIZE]);
        if (!std.mem.eql(u8, &hdr.magic, &MAGIC)) return error.InvalidMagic;
        if (hdr.footer_offset + FOOTER_SIZE > data.len) return error.BlockTooSmall;

        const footer: BlockFooter = std.mem.bytesToValue(BlockFooter, data[hdr.footer_offset..][0..FOOTER_SIZE]);
        const expected_crc = crc_mod.crc32c(data[0..hdr.footer_offset]);
        if (footer.crc != expected_crc) return error.CrcMismatch;

        // key_section starts at key_data_offset (= HEADER_SIZE)
        // layout: [row_count * 4 offsets] [key_data] [row_count * 8 seqs]
        const key_sec = hdr.key_data_offset;
        const key_data_start = key_sec + hdr.row_count * 4;
        const seq_section_start = hdr.values_offset -| hdr.row_count * 8;

        return .{
            .data = data,
            .header = hdr,
            .row_count = hdr.row_count,
            .key_data_start = key_data_start,
            .seq_section_start = seq_section_start,
        };
    }

    /// Returns key (slice into data), seq, and tombstone flag.
    pub fn readKey(self: *const BlockReader, row_idx: u32) !struct { key: []const u8, seq: Seq, is_tombstone: bool } {
        if (row_idx >= self.row_count) return error.OutOfBounds;
        const key_sec = self.header.key_data_offset;

        const off = std.mem.readInt(u32, self.data[key_sec + row_idx * 4 ..][0..4], .little);
        const next_off: u32 = if (row_idx + 1 < self.row_count)
            std.mem.readInt(u32, self.data[key_sec + (row_idx + 1) * 4 ..][0..4], .little)
        else
            self.seq_section_start - self.key_data_start;

        const key = self.data[self.key_data_start + off .. self.key_data_start + next_off];
        const raw_seq = std.mem.readInt(u64, self.data[self.seq_section_start + row_idx * 8 ..][0..8], .little);
        const is_tombstone = (raw_seq & TOMBSTONE_BIT) != 0;
        const seq = raw_seq & ~TOMBSTONE_BIT;
        return .{ .key = key, .seq = seq, .is_tombstone = is_tombstone };
    }

    /// Read value for a specific row. Caller owns result.
    pub fn readValue(self: *const BlockReader, row_idx: u32, alloc: std.mem.Allocator) ![]const u8 {
        if (row_idx >= self.row_count) return error.OutOfBounds;
        var pos: u32 = self.header.values_offset;
        for (0..row_idx) |_| {
            if (pos + 4 > self.data.len) return error.InvalidData;
            const len: u32 = std.mem.readInt(u32, self.data[pos..][0..4], .little);
            pos += 4 + len;
        }
        if (pos + 4 > self.data.len) return error.InvalidData;
        const len: u32 = std.mem.readInt(u32, self.data[pos..][0..4], .little);
        pos += 4;
        if (pos + len > self.data.len) return error.InvalidData;
        return try alloc.dupe(u8, self.data[pos .. pos + len]);
    }

    /// Binary search for first row where key matches. Returns row index or null.
    pub fn findKey(self: *const BlockReader, key: []const u8) !?u32 {
        if (self.row_count == 0) return null;
        var lo: u32 = 0;
        var hi: u32 = self.row_count;
        var found: ?u32 = null;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const mid_kv = try self.readKey(mid);
            switch (std.mem.order(u8, mid_kv.key, key)) {
                .lt => lo = mid + 1,
                .eq => {
                    found = mid;
                    hi = mid;
                },
                .gt => hi = mid,
            }
        }
        return found;
    }

    /// Lower bound: first row where key >= target.
    pub fn lowerBound(self: *const BlockReader, key: []const u8) !u32 {
        if (self.row_count == 0) return 0;
        var lo: u32 = 0;
        var hi: u32 = self.row_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const mid_kv = try self.readKey(mid);
            if (std.mem.order(u8, mid_kv.key, key) == .lt) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    /// Read full row (key, value, seq, tombstone). Caller owns key and value.
    pub fn readRow(self: *const BlockReader, row_idx: u32, alloc: std.mem.Allocator) !Row {
        const kv = try self.readKey(row_idx);
        const key_copy = try alloc.dupe(u8, kv.key);
        errdefer alloc.free(key_copy);
        const value = try self.readValue(row_idx, alloc);
        return .{ .key = key_copy, .value = value, .seq = kv.seq, .is_tombstone = kv.is_tombstone };
    }
};
