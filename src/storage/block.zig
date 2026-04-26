/// PAX block: column-major layout for SSTable storage.
const std = @import("std");

const assert = std.debug.assert;
const types = @import("types.zig");
const codec_mod = @import("codec.zig");
const crc_mod = @import("crc.zig");

const ColumnValue = types.ColumnValue;
const ColumnType = types.ColumnType;
const TableSchema = types.TableSchema;
const Row = types.Row;
const Seq = types.Seq;
const CodecId = codec_mod.CodecId;

pub const MAGIC: [4]u8 = .{ 'F', 'P', 'A', 'X' };
pub const MAX_ROWS_PER_BLOCK: usize = 512;
/// Tombstone marker: high bit of seq indicates deleted row.
pub const TOMBSTONE_BIT: Seq = 1 << 63;
pub const MAX_BLOCK_SIZE: usize = 64 * 1024;
pub const HEADER_SIZE: usize = 28;
pub const FOOTER_SIZE: usize = 8;

/// On-disk block header, fixed 32 bytes.
pub const BlockHeader = extern struct {
    magic: [4]u8,
    row_count: u32,
    column_count: u16,
    compression: u8,
    _pad: u8,
    key_data_offset: u32,
    col_data_offset: u32,
    null_bmp_offset: u32,
    footer_offset: u32,

    comptime {
        std.debug.assert(@sizeOf(BlockHeader) == HEADER_SIZE);
        std.debug.assert(@offsetOf(BlockHeader, "footer_offset") == 24);
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
    schema: TableSchema,
    // keys and seqs stored parallel
    keys: std.ArrayList([]const u8),
    seqs: std.ArrayList(Seq),
    // one ArrayList per column
    columns: []std.ArrayList(ColumnValue),
    null_bits: []std.ArrayList(bool),
    size_estimate: usize,

    pub fn init(schema: TableSchema) !BlockWriter {
        const col_count = schema.columns.len;
        const columns = try std.heap.page_allocator.alloc(std.ArrayList(ColumnValue), col_count);
        for (columns) |*c| c.* = .empty;
        const null_bits = try std.heap.page_allocator.alloc(std.ArrayList(bool), col_count);
        for (null_bits) |*n| n.* = .empty;
        return .{
            .schema = schema,
            .keys = .empty,
            .seqs = .empty,
            .columns = columns,
            .null_bits = null_bits,
            .size_estimate = HEADER_SIZE + FOOTER_SIZE,
        };
    }

    pub fn deinit(self: *BlockWriter, alloc: std.mem.Allocator) void {
        for (self.keys.items) |k| alloc.free(k);
        self.keys.deinit(alloc);
        self.seqs.deinit(alloc);
        for (self.columns) |*c| {
            for (c.items) |v| v.freeIfOwned(alloc);
            c.deinit(alloc);
        }
        for (self.null_bits) |*n| n.deinit(alloc);
        std.heap.page_allocator.free(self.columns);
        std.heap.page_allocator.free(self.null_bits);
    }

    pub fn isFull(self: *const BlockWriter) bool {
        return self.keys.items.len >= MAX_ROWS_PER_BLOCK or
            self.size_estimate >= MAX_BLOCK_SIZE;
    }

    pub fn isEmpty(self: *const BlockWriter) bool {
        return self.keys.items.len == 0;
    }

    /// Append a row. values=null means tombstone (bit 63 of seq set).
    pub fn append(
        self: *BlockWriter,
        alloc: std.mem.Allocator,
        key: []const u8,
        seq: Seq,
        values: ?[]const ColumnValue,
    ) !void {
        const key_copy = try alloc.dupe(u8, key);
        errdefer alloc.free(key_copy);
        try self.keys.append(alloc, key_copy);
        const encoded_seq = if (values == null) seq | TOMBSTONE_BIT else seq;
        try self.seqs.append(alloc, encoded_seq);

        for (self.schema.columns, 0..) |col_schema, ci| {
            const is_tombstone = values == null;
            if (is_tombstone) {
                try self.null_bits[ci].append(alloc, true);
                try self.columns[ci].append(alloc, zeroValue(col_schema.col_type));
            } else {
                try self.columns[ci].append(alloc, try values.?[ci].dupe(alloc));
                try self.null_bits[ci].append(alloc, false);
            }
        }
        self.size_estimate += key.len + 8 + self.schema.columns.len * 8;
    }

    /// Serialize to a heap-allocated buffer (caller owns result).
    pub fn flush(self: *BlockWriter, alloc: std.mem.Allocator) ![]u8 {
        assert(self.keys.items.len > 0);
        assert(self.keys.items.len <= std.math.maxInt(u32));
        assert(self.schema.columns.len <= std.math.maxInt(u16));
        const row_count: u32 = @intCast(self.keys.items.len);
        const col_count: u16 = @intCast(self.schema.columns.len);

        var key_section = try flushBuildKeySection(self, row_count, alloc);
        defer key_section.deinit(alloc);

        var col_section = try flushBuildColSection(self, alloc);
        defer col_section.deinit(alloc);

        var null_section = try flushBuildNullSection(self, row_count, alloc);
        defer null_section.deinit(alloc);

        // Compute section offsets and assemble final block.
        assert(key_section.items.len <= std.math.maxInt(u32));
        assert(col_section.items.len <= std.math.maxInt(u32));
        assert(null_section.items.len <= std.math.maxInt(u32));
        const key_section_offset: u32 = HEADER_SIZE;
        const col_section_offset: u32 = key_section_offset + @as(u32, @intCast(key_section.items.len));
        const null_bmp_offset: u32 = col_section_offset + @as(u32, @intCast(col_section.items.len));
        const footer_offset: u32 = null_bmp_offset + @as(u32, @intCast(null_section.items.len));
        const total_size: u32 = footer_offset + @as(u32, FOOTER_SIZE);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try out.ensureTotalCapacity(alloc, total_size);

        const hdr = BlockHeader{
            .magic = MAGIC,
            .row_count = row_count,
            .column_count = col_count,
            .compression = 0,
            ._pad = 0,
            .key_data_offset = key_section_offset,
            .col_data_offset = col_section_offset,
            .null_bmp_offset = null_bmp_offset,
            .footer_offset = footer_offset,
        };
        try out.appendSlice(alloc, std.mem.asBytes(&hdr));
        try out.appendSlice(alloc, key_section.items);
        try out.appendSlice(alloc, col_section.items);
        try out.appendSlice(alloc, null_section.items);

        const checksum = crc_mod.crc32c(out.items);
        const footer = BlockFooter{ .block_size = total_size, .crc = checksum };
        try out.appendSlice(alloc, std.mem.asBytes(&footer));

        return out.toOwnedSlice(alloc);
    }
};

/// Build the key section: key_offsets (row_count×4) + key_data + seqs (row_count×8).
fn flushBuildKeySection(w: *const BlockWriter, row_count: u32, alloc: std.mem.Allocator) !std.ArrayList(u8) {
    assert(row_count == w.keys.items.len);
    var key_offsets_buf: std.ArrayList(u8) = .empty;
    defer key_offsets_buf.deinit(alloc);
    var key_data_buf: std.ArrayList(u8) = .empty;
    defer key_data_buf.deinit(alloc);
    var seq_buf: std.ArrayList(u8) = .empty;
    defer seq_buf.deinit(alloc);

    for (w.keys.items, w.seqs.items) |k, s| {
        assert(key_data_buf.items.len <= std.math.maxInt(u32));
        var off_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &off_buf, @intCast(key_data_buf.items.len), .little);
        try key_offsets_buf.appendSlice(alloc, &off_buf);
        try key_data_buf.appendSlice(alloc, k);
        var seq_b: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq_b, s, .little);
        try seq_buf.appendSlice(alloc, &seq_b);
    }

    var section: std.ArrayList(u8) = .empty;
    errdefer section.deinit(alloc);
    try section.appendSlice(alloc, key_offsets_buf.items);
    try section.appendSlice(alloc, key_data_buf.items);
    try section.appendSlice(alloc, seq_buf.items);
    return section;
}

/// Build the column data section: [codec_tag(1) + size(4) + encoded_data] per column.
fn flushBuildColSection(w: *const BlockWriter, alloc: std.mem.Allocator) !std.ArrayList(u8) {
    var section: std.ArrayList(u8) = .empty;
    errdefer section.deinit(alloc);
    for (w.schema.columns, 0..) |col_schema, ci| {
        const chosen = codec_mod.chooseCodec(col_schema.col_type, w.columns[ci].items);
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(alloc);
        try codec_mod.encode(chosen, col_schema.col_type, w.columns[ci].items, &encoded, alloc);
        assert(encoded.items.len <= std.math.maxInt(u32));
        try section.append(alloc, @intFromEnum(chosen));
        var sz_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &sz_buf, @intCast(encoded.items.len), .little);
        try section.appendSlice(alloc, &sz_buf);
        try section.appendSlice(alloc, encoded.items);
    }
    return section;
}

/// Build the null bitmap section (column-major, 1 bit per cell). Empty if no nulls.
fn flushBuildNullSection(w: *const BlockWriter, row_count: u32, alloc: std.mem.Allocator) !std.ArrayList(u8) {
    var section: std.ArrayList(u8) = .empty;
    errdefer section.deinit(alloc);
    var has_nulls = false;
    outer: for (w.null_bits) |nb| {
        for (nb.items) |b| {
            if (b) {
                has_nulls = true;
                break :outer;
            }
        }
    }
    if (!has_nulls) return section;
    for (w.null_bits) |nb| {
        const byte_count = (row_count + 7) / 8;
        var i: u32 = 0;
        while (i < byte_count) : (i += 1) {
            var b: u8 = 0;
            for (0..8) |bit| {
                const row_idx = i * 8 + @as(u32, @intCast(bit));
                if (row_idx < row_count and nb.items[row_idx]) {
                    b |= @as(u8, 1) << @intCast(bit);
                }
            }
            try section.append(alloc, b);
        }
    }
    return section;
}

// --- BlockReader ---

pub const BlockReader = struct {
    data: []const u8,
    header: BlockHeader,
    schema: TableSchema,
    row_count: u32,
    key_data_start: u32,
    seq_section_start: u32,

    pub fn init(data: []const u8, schema: TableSchema) !BlockReader {
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
        // seqs are just before col_data
        const seq_section_start = hdr.col_data_offset -| hdr.row_count * 8;

        return .{
            .data = data,
            .header = hdr,
            .schema = schema,
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

    /// Decode column values for a specific row. Caller owns result.
    pub fn readRowValues(self: *const BlockReader, row_idx: u32, alloc: std.mem.Allocator) ![]ColumnValue {
        if (row_idx >= self.row_count) return error.OutOfBounds;
        const col_count = self.header.column_count;
        const out = try alloc.alloc(ColumnValue, col_count);
        errdefer alloc.free(out);

        var pos: usize = self.header.col_data_offset;
        for (0..col_count) |ci| {
            const col_schema = self.schema.columns[ci];
            if (pos + 5 > self.data.len) return error.InvalidData;
            const codec_id: CodecId = @enumFromInt(self.data[pos]);
            pos += 1;
            const encoded_size = std.mem.readInt(u32, self.data[pos..][0..4], .little);
            pos += 4;
            const encoded_data = self.data[pos .. pos + encoded_size];
            pos += encoded_size;

            const col_vals = try alloc.alloc(ColumnValue, self.row_count);
            defer alloc.free(col_vals);
            try codec_mod.decode(codec_id, col_schema.col_type, encoded_data, self.row_count, col_vals, alloc);
            out[ci] = try col_vals[row_idx].dupe(alloc);
            for (col_vals) |v| v.freeIfOwned(alloc);
        }
        return out;
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
                }, // keep searching left for first match
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

    pub fn readRow(self: *const BlockReader, row_idx: u32, alloc: std.mem.Allocator) !Row {
        const kv = try self.readKey(row_idx);
        const key_copy = try alloc.dupe(u8, kv.key);
        errdefer alloc.free(key_copy);
        const values = try self.readRowValues(row_idx, alloc);
        return .{ .key = key_copy, .seq = kv.seq, .values = values, .is_tombstone = kv.is_tombstone };
    }
};

fn zeroValue(col_type: ColumnType) ColumnValue {
    return switch (col_type) {
        .bool_t => .{ .bool_t = false },
        .int8 => .{ .int8 = 0 },
        .int16 => .{ .int16 = 0 },
        .int32 => .{ .int32 = 0 },
        .int64 => .{ .int64 = 0 },
        .uint8 => .{ .uint8 = 0 },
        .uint16 => .{ .uint16 = 0 },
        .uint32 => .{ .uint32 = 0 },
        .uint64 => .{ .uint64 = 0 },
        .bytes => .{ .bytes = "" },
        .string => .{ .string = "" },
        .decimal => .{ .decimal = .{ .coefficient = 0, .scale = 0 } },
    };
}
