/// SSTable file: header + PAX blocks + sparse index + footer.
const std = @import("std");
const types = @import("types.zig");
const block_mod = @import("block.zig");
const crc_mod = @import("crc.zig");

const TableSchema = types.TableSchema;
const ColumnType = types.ColumnType;
const ColumnValue = types.ColumnValue;
const TableId = types.TableId;
const Seq = types.Seq;
const Row = types.Row;
const KeyRange = types.KeyRange;
const BlockWriter = block_mod.BlockWriter;
const BlockReader = block_mod.BlockReader;

pub const MAGIC: [4]u8 = .{ 'F', 'S', 'S', 'T' };
pub const FOOTER_MAGIC: [8]u8 = .{ 'F', 'S', 'S', 'T', 'F', 'O', 'O', 'T' };
pub const VERSION: u32 = 1;

/// On-disk SSTable header, 64 bytes.
pub const SSTableHeader = extern struct {
    magic: [4]u8,
    version: u32,
    table_id: TableId,
    level: u8,
    _pad: [3]u8,
    seq_min: Seq,
    seq_max: Seq,
    block_count: u32,
    column_count: u16,
    _pad2: [2]u8,
    col_types: [16]u8,
    reserved: [8]u8,

    comptime {
        std.debug.assert(@sizeOf(SSTableHeader) == 64);
    }
};

/// On-disk SSTable footer, 24 bytes.
pub const SSTableFooter = extern struct {
    index_offset: u64,
    entry_count: u32,
    footer_crc: u32,
    footer_magic: [8]u8,

    comptime {
        std.debug.assert(@sizeOf(SSTableFooter) == 24);
    }
};

/// Sparse index entry: first key of block + file offset.
pub const IndexEntry = struct {
    first_key: []const u8,
    file_offset: u64,
};

// --- Path helper ---

fn toNullZ(alloc: std.mem.Allocator, path: []const u8) ![:0]u8 {
    const z = try alloc.allocSentinel(u8, path.len, 0);
    @memcpy(z[0..path.len], path);
    return z;
}

// --- SSTableWriter ---

pub const SSTableWriter = struct {
    schema: TableSchema,
    path: []const u8,
    fd: std.posix.fd_t,
    block_writer: BlockWriter,
    index: std.ArrayList(IndexEntry),
    write_offset: u64,
    block_count: u32,
    entry_count: u32,
    seq_min: Seq,
    seq_max: Seq,
    level: u8,
    alloc: std.mem.Allocator,

    pub fn create(path: []const u8, schema: TableSchema, level: u8, alloc: std.mem.Allocator) !SSTableWriter {
        const null_path = try toNullZ(std.heap.page_allocator, path);
        defer std.heap.page_allocator.free(null_path);

        const raw_fd = std.os.linux.open(null_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        const fd: std.posix.fd_t = @intCast(@as(isize, @bitCast(raw_fd)));
        if (fd < 0) return error.FileCreateError;

        var writer = SSTableWriter{
            .schema = schema,
            .path = path,
            .fd = fd,
            .block_writer = try BlockWriter.init(schema),
            .index = .empty,
            .write_offset = 0,
            .block_count = 0,
            .entry_count = 0,
            .seq_min = std.math.maxInt(Seq),
            .seq_max = 0,
            .level = level,
            .alloc = alloc,
        };

        // Reserve space for the header; will overwrite on finish().
        var header_bytes: [64]u8 = [_]u8{0} ** 64;
        try writer.writeBytes(&header_bytes);

        return writer;
    }

    pub fn deinit(self: *SSTableWriter) void {
        self.block_writer.deinit(self.alloc);
        for (self.index.items) |entry| self.alloc.free(entry.first_key);
        self.index.deinit(self.alloc);
        _ = std.os.linux.close(@intCast(self.fd));
    }

    pub fn append(self: *SSTableWriter, key: []const u8, seq: Seq, values: ?[]const ColumnValue) !void {
        if (self.block_writer.isFull()) try self.flushBlock();
        // Record first key of block for sparse index.
        const is_first = self.block_writer.isEmpty();
        const first_key: ?[]const u8 = if (is_first) key else null;
        try self.block_writer.append(self.alloc, key, seq, values);
        if (is_first) {
            const key_copy = try self.alloc.dupe(u8, first_key.?);
            try self.index.append(self.alloc, .{
                .first_key = key_copy,
                .file_offset = self.write_offset,
            });
        }
        self.entry_count += 1;
        if (seq < self.seq_min) self.seq_min = seq;
        if (seq > self.seq_max) self.seq_max = seq;
    }

    pub fn finish(self: *SSTableWriter) !void {
        if (!self.block_writer.isEmpty()) try self.flushBlock();

        const index_offset = self.write_offset;

        // Write sparse index
        for (self.index.items) |entry| {
            var key_len_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &key_len_buf, @intCast(entry.first_key.len), .little);
            try self.writeBytes(&key_len_buf);
            try self.writeBytes(entry.first_key);
            var off_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &off_buf, entry.file_offset, .little);
            try self.writeBytes(&off_buf);
        }

        // Write footer
        const footer = SSTableFooter{
            .index_offset = index_offset,
            .entry_count = self.entry_count,
            .footer_crc = 0,
            .footer_magic = FOOTER_MAGIC,
        };
        var footer_bytes = std.mem.toBytes(footer);
        // CRC covers all bytes before footer_crc field
        const footer_crc = crc_mod.crc32c(footer_bytes[0..@offsetOf(SSTableFooter, "footer_crc")]);
        std.mem.writeInt(u32, footer_bytes[@offsetOf(SSTableFooter, "footer_crc")..][0..4], footer_crc, .little);
        try self.writeBytes(&footer_bytes);

        // Seek back and write header
        _ = std.os.linux.lseek(@intCast(self.fd), 0, std.os.linux.SEEK.SET);
        const col_count: u16 = @intCast(self.schema.columns.len);
        var col_types: [16]u8 = [_]u8{0} ** 16;
        for (self.schema.columns, 0..) |col, ci| {
            if (ci >= 16) break;
            col_types[ci] = @intFromEnum(col.col_type);
        }
        const header = SSTableHeader{
            .magic = MAGIC,
            .version = VERSION,
            .table_id = self.schema.table_id,
            .level = self.level,
            ._pad = [_]u8{0} ** 3,
            .seq_min = self.seq_min,
            .seq_max = self.seq_max,
            .block_count = self.block_count,
            .column_count = col_count,
            ._pad2 = [_]u8{0} ** 2,
            .col_types = col_types,
            .reserved = [_]u8{0} ** 8,
        };
        _ = std.os.linux.write(@intCast(self.fd), std.mem.asBytes(&header).ptr, 64);

        _ = std.os.linux.fsync(@intCast(self.fd));
    }

    fn flushBlock(self: *SSTableWriter) !void {
        const block_data = try self.block_writer.flush(self.alloc);
        defer self.alloc.free(block_data);
        try self.writeBytes(block_data);
        self.block_count += 1;
        // Reset block writer
        self.block_writer.deinit(self.alloc);
        self.block_writer = try BlockWriter.init(self.schema);
    }

    fn writeBytes(self: *SSTableWriter, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = std.os.linux.write(@intCast(self.fd), data.ptr + written, data.len - written);
            const ni: isize = @bitCast(n);
            if (ni <= 0) return error.WriteError;
            written += @intCast(ni);
        }
        self.write_offset += data.len;
    }
};

// --- SSTableReader ---

pub const SSTableMeta = struct {
    path: []const u8,
    table_id: TableId,
    level: u8,
    seq_min: Seq,
    seq_max: Seq,
    key_min: []const u8,
    key_max: []const u8,
    block_count: u32,
    file_size: u64,

    pub fn deinit(self: *SSTableMeta, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        alloc.free(self.key_min);
        alloc.free(self.key_max);
    }
};

pub const SSTableReader = struct {
    schema: TableSchema,
    header: SSTableHeader,
    index: []IndexEntry,
    data: []u8,
    alloc: std.mem.Allocator,

    pub fn open(path: []const u8, schema: TableSchema, alloc: std.mem.Allocator) !SSTableReader {
        const null_path = try toNullZ(std.heap.page_allocator, path);
        defer std.heap.page_allocator.free(null_path);

        const raw_fd = std.os.linux.open(null_path.ptr, .{ .ACCMODE = .RDONLY }, 0);
        const fd: std.posix.fd_t = @intCast(@as(isize, @bitCast(raw_fd)));
        if (fd < 0) return error.FileOpenError;
        defer _ = std.os.linux.close(@intCast(fd));

        // Get file size via lseek
        const file_size_raw = std.os.linux.lseek(@intCast(fd), 0, std.os.linux.SEEK.END);
        const file_size_signed: isize = @bitCast(file_size_raw);
        if (file_size_signed < 0) return error.SeekError;
        _ = std.os.linux.lseek(@intCast(fd), 0, std.os.linux.SEEK.SET);
        const file_size: usize = @intCast(file_size_signed);
        if (file_size < 64 + @sizeOf(SSTableFooter)) return error.FileTooSmall;

        // Load entire file into memory
        const data = try alloc.alloc(u8, file_size);
        errdefer alloc.free(data);
        var total_read: usize = 0;
        while (total_read < file_size) {
            const n = std.os.linux.read(@intCast(fd), data.ptr + total_read, file_size - total_read);
            const ni: isize = @bitCast(n);
            if (ni <= 0) return error.ReadError;
            total_read += @intCast(ni);
        }

        // Parse header
        const header: SSTableHeader = std.mem.bytesToValue(SSTableHeader, data[0..64]);
        if (!std.mem.eql(u8, &header.magic, &MAGIC)) return error.InvalidMagic;

        // Parse footer
        const footer_offset = file_size - @sizeOf(SSTableFooter);
        const footer: SSTableFooter = std.mem.bytesToValue(SSTableFooter, data[footer_offset..][0..@sizeOf(SSTableFooter)]);
        if (!std.mem.eql(u8, &footer.footer_magic, &FOOTER_MAGIC)) return error.InvalidFooter;

        // Parse sparse index
        var index: std.ArrayList(IndexEntry) = .empty;
        errdefer {
            for (index.items) |e| alloc.free(e.first_key);
            index.deinit(alloc);
        }

        var pos: usize = @intCast(footer.index_offset);
        for (0..header.block_count) |_| {
            if (pos + 2 > footer_offset) return error.InvalidIndex;
            const key_len = std.mem.readInt(u16, data[pos..][0..2], .little);
            pos += 2;
            if (pos + key_len + 8 > footer_offset) return error.InvalidIndex;
            const key = try alloc.dupe(u8, data[pos .. pos + key_len]);
            pos += key_len;
            const file_offset = std.mem.readInt(u64, data[pos..][0..8], .little);
            pos += 8;
            try index.append(alloc, .{ .first_key = key, .file_offset = file_offset });
        }

        return .{
            .schema = schema,
            .header = header,
            .index = try index.toOwnedSlice(alloc),
            .data = data,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *SSTableReader) void {
        for (self.index) |e| self.alloc.free(e.first_key);
        self.alloc.free(self.index);
        self.alloc.free(self.data);
    }

    /// Find the most recent version of key with seq ≤ at_seq.
    pub fn get(self: *const SSTableReader, key: []const u8, at_seq: Seq) !?Row {
        const block_idx = self.findBlockIndex(key);

        var bi = block_idx;
        while (bi < self.header.block_count) : (bi += 1) {
            // Stop if this block's first key is past our target key
            if (bi < self.index.len and std.mem.order(u8, self.index[bi].first_key, key) == .gt) break;

            const blk = try self.readBlock(bi);
            defer self.alloc.free(blk);
            const reader = try BlockReader.init(blk, self.schema);

            const first_idx = try reader.lowerBound(key);
            var ri = first_idx;
            while (ri < reader.row_count) : (ri += 1) {
                const kv = try reader.readKey(ri);
                if (!std.mem.eql(u8, kv.key, key)) break;
                if (kv.seq <= at_seq) {
                    if (kv.is_tombstone) return null;
                    const values = try reader.readRowValues(ri, self.alloc);
                    const key_copy = try self.alloc.dupe(u8, key);
                    errdefer self.alloc.free(key_copy);
                    return Row{ .key = key_copy, .seq = kv.seq, .values = values };
                }
            }
        }
        return null;
    }

    pub fn meta(self: *const SSTableReader, path: []const u8, alloc: std.mem.Allocator) !SSTableMeta {
        const path_copy = try alloc.dupe(u8, path);
        errdefer alloc.free(path_copy);
        var key_min: []const u8 = &.{};
        var key_max: []const u8 = &.{};
        if (self.index.len > 0) {
            key_min = try alloc.dupe(u8, self.index[0].first_key);
            errdefer alloc.free(key_min);
            // key_max = true last key in the last block (not just first_key of last block)
            const last_blk_data = try self.readBlock(self.header.block_count - 1);
            defer alloc.free(last_blk_data);
            const last_blk = try block_mod.BlockReader.init(last_blk_data, self.schema);
            if (last_blk.row_count > 0) {
                const last_kv = try last_blk.readKey(last_blk.row_count - 1);
                key_max = try alloc.dupe(u8, last_kv.key);
            } else {
                key_max = try alloc.dupe(u8, key_min);
            }
        } else {
            key_min = try alloc.dupe(u8, "");
            key_max = try alloc.dupe(u8, "");
        }
        return .{
            .path = path_copy,
            .table_id = self.header.table_id,
            .level = self.header.level,
            .seq_min = self.header.seq_min,
            .seq_max = self.header.seq_max,
            .key_min = key_min,
            .key_max = key_max,
            .block_count = self.header.block_count,
            .file_size = self.data.len,
        };
    }

    fn findBlockIndex(self: *const SSTableReader, key: []const u8) usize {
        if (self.index.len == 0) return 0;
        // Find last index entry with first_key ≤ key
        var result: usize = 0;
        for (self.index, 0..) |entry, i| {
            if (std.mem.order(u8, entry.first_key, key) != .gt) {
                result = i;
            } else break;
        }
        return result;
    }

    pub fn readBlock(self: *const SSTableReader, block_idx: usize) ![]u8 {
        if (block_idx >= self.index.len) return error.BlockIndexOutOfRange;
        const block_offset: usize = @intCast(self.index[block_idx].file_offset);
        if (block_offset + block_mod.FOOTER_SIZE > self.data.len) return error.InvalidBlockOffset;

        // Read block_size from footer field at block_offset + footer_offset
        // We peek at the block header to get footer_offset
        if (block_offset + block_mod.HEADER_SIZE > self.data.len) return error.InvalidBlockOffset;
        const blk_header: block_mod.BlockHeader = std.mem.bytesToValue(
            block_mod.BlockHeader,
            self.data[block_offset..][0..block_mod.HEADER_SIZE],
        );
        const total_size = blk_header.footer_offset + block_mod.FOOTER_SIZE;
        if (block_offset + total_size > self.data.len) return error.InvalidBlockSize;

        return try self.alloc.dupe(u8, self.data[block_offset .. block_offset + total_size]);
    }
};
