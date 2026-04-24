/// Segment file handling for Foldb's write-ahead log.
const std = @import("std");
const crc = @import("crc.zig");
const entry_mod = @import("entry.zig");

const LogEntry = entry_mod.LogEntry;
const LogEntryHeader = entry_mod.LogEntryHeader;
const Seq = entry_mod.Seq;
const NodeId = entry_mod.NodeId;

pub fn real_time_sec() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    return ts.sec;
}

pub const magic: [4]u8 = .{ 'F', 'L', 'O', 'G' };
pub const version: u32 = 1;
pub const header_size: u32 = 64;
pub const footer_size: u32 = 64;

const entries_scanned_max: u32 = 1 << 20;
const segment_entries_max: u32 = 1 << 14;

/// Segment header — 64 bytes on disk (extern struct for deterministic layout).
pub const SegmentHeader = extern struct {
    base_seq: Seq,
    node_id: NodeId,
    created_at: i64,
    magic: [4]u8,
    version: u32,
    part_id: u32,
    reserved: [24]u8,
    header_crc: u32,

    comptime {
        std.debug.assert(@offsetOf(SegmentHeader, "header_crc") == 60);
        std.debug.assert(@sizeOf(SegmentHeader) == header_size);
    }

    pub fn init(base_seq: Seq, node_id: NodeId, created_at: i64) SegmentHeader {
        var seg_header = SegmentHeader{
            .base_seq = base_seq,
            .node_id = node_id,
            .created_at = created_at,
            .magic = magic,
            .version = version,
            .part_id = 0,
            .reserved = [_]u8{0} ** 24,
            .header_crc = 0,
        };
        seg_header.header_crc = compute_header_crc(&seg_header);
        return seg_header;
    }

    fn compute_header_crc(self: *const SegmentHeader) u32 {
        const bytes = self.to_bytes();
        return crc.crc32c(bytes[0..@offsetOf(SegmentHeader, "header_crc")]);
    }

    fn to_bytes(self: *const SegmentHeader) []const u8 {
        const ptr: [*]const u8 = @ptrCast(@alignCast(self));
        return ptr[0..header_size];
    }

    pub fn is_valid(self: *const SegmentHeader) bool {
        if (!std.mem.eql(u8, &self.magic, &magic)) return false;
        if (self.version != version) return false;
        const expected = compute_header_crc(self);
        return expected == self.header_crc;
    }
};

/// Segment footer — 64 bytes on disk.
pub const SegmentFooter = struct {
    entry_count: u32,
    last_seq: Seq,
    index_offset: u64,
    reserved: [40]u8,
    footer_crc: u32,

    pub fn init(entry_count: u32, last_seq: Seq, index_offset: u64) SegmentFooter {
        var seg_footer = SegmentFooter{
            .entry_count = entry_count,
            .last_seq = last_seq,
            .index_offset = index_offset,
            .reserved = [_]u8{0} ** 40,
            .footer_crc = 0,
        };
        var buf: [footer_size]u8 = undefined;
        write_footer_body(&seg_footer, &buf);
        seg_footer.footer_crc = crc.crc32c(buf[0 .. footer_size - 4]);
        return seg_footer;
    }

    pub fn serialize_to(self: *const SegmentFooter, buf: *[footer_size]u8) void {
        write_footer_body(self, buf);
        std.mem.writeInt(u32, buf[60..64], self.footer_crc, .little);
    }

    pub fn deserialize_from(buf: *const [footer_size]u8) !SegmentFooter {
        const entry_count = std.mem.readInt(u32, buf[0..4], .little);
        const last_seq = std.mem.readInt(u64, buf[4..12], .little);
        const index_offset = std.mem.readInt(u64, buf[12..20], .little);
        var reserved: [40]u8 = undefined;
        @memcpy(&reserved, buf[20..60]);
        const seg_footer_crc = std.mem.readInt(u32, buf[60..64], .little);
        const seg_footer = SegmentFooter{
            .entry_count = entry_count,
            .last_seq = last_seq,
            .index_offset = index_offset,
            .reserved = reserved,
            .footer_crc = seg_footer_crc,
        };
        var check: [footer_size]u8 = undefined;
        write_footer_body(&seg_footer, &check);
        const expected = crc.crc32c(check[0 .. footer_size - 4]);
        if (expected != seg_footer_crc) return error.CorruptSegmentFooter;
        return seg_footer;
    }
};

fn write_footer_body(seg_footer: *const SegmentFooter, buf: *[footer_size]u8) void {
    std.mem.writeInt(u32, buf[0..4], seg_footer.entry_count, .little);
    std.mem.writeInt(u64, buf[4..12], seg_footer.last_seq, .little);
    std.mem.writeInt(u64, buf[12..20], seg_footer.index_offset, .little);
    @memcpy(buf[20..60], &seg_footer.reserved);
}

/// Index entry — maps sequence number to file offset (16 bytes).
pub const IndexEntry = struct {
    seq: Seq,
    file_offset: u64,

    pub const entry_size: u32 = 16;

    pub fn serialize_to(self: IndexEntry, buf: *[entry_size]u8) void {
        std.mem.writeInt(u64, buf[0..8], self.seq, .little);
        std.mem.writeInt(u64, buf[8..16], self.file_offset, .little);
    }

    pub fn deserialize_from(buf: *const [entry_size]u8) IndexEntry {
        return .{
            .seq = std.mem.readInt(u64, buf[0..8], .little),
            .file_offset = std.mem.readInt(u64, buf[8..16], .little),
        };
    }
};

/// Scans entry headers from header_size forward to recover last_seq and next_offset
/// for unsealed segments. Leaves fd positioned at next_offset.
/// Bounded by entries_scanned_max; EOF is the expected termination condition.
fn scan_unsealed_entries(fd: std.posix.fd_t) struct { last_seq: Seq, entry_count: u32, next_offset: u64 } {
    _ = std.os.linux.lseek(@intCast(fd), @intCast(header_size), std.os.linux.SEEK.SET);
    var last_seq: Seq = 0;
    var entry_count: u32 = 0;
    var next_offset: u64 = header_size;
    var header_buf: [entry_mod.LogEntryHeader.header_size]u8 = undefined;
    for (0..entries_scanned_max) |_| {
        const header_read_result = std.os.linux.read(
            @intCast(fd),
            &header_buf,
            entry_mod.LogEntryHeader.header_size,
        );
        if (header_read_result != entry_mod.LogEntryHeader.header_size) break;
        const log_header = entry_mod.LogEntryHeader.deserialize_from(&header_buf) catch break;
        if (log_header.payload_len > entry_mod.payload_len_max) break;
        _ = std.os.linux.lseek(@intCast(fd), @intCast(log_header.payload_len), std.os.linux.SEEK.CUR);
        last_seq = log_header.seq;
        entry_count += 1;
        next_offset += entry_mod.LogEntryHeader.header_size + log_header.payload_len;
    }
    _ = std.os.linux.lseek(@intCast(fd), @intCast(next_offset), std.os.linux.SEEK.SET);
    return .{ .last_seq = last_seq, .entry_count = entry_count, .next_offset = next_offset };
}

/// Returns the sealed footer if present and valid; null if file too short or footer corrupt.
fn open_read_footer(fd: std.posix.fd_t, file_size: usize) !?SegmentFooter {
    if (file_size < header_size + footer_size) return null;
    const footer_pos: i64 = @intCast(file_size - footer_size);
    _ = std.os.linux.lseek(@intCast(fd), footer_pos, std.os.linux.SEEK.SET);
    var footer_buf: [footer_size]u8 = undefined;
    const footer_read_result = std.os.linux.read(@intCast(fd), &footer_buf, footer_size);
    if (footer_read_result != footer_size) return error.InvalidSegment;
    return SegmentFooter.deserialize_from(&footer_buf) catch null;
}

/// Segment file — a contiguous file containing log entries.
/// The segment owns its path slice and frees it in deinit.
pub const Segment = struct {
    fd: std.posix.fd_t,
    path: []u8,
    header: SegmentHeader,
    index: std.ArrayList(IndexEntry),
    next_offset: u64,
    entry_count: u32,
    last_seq: Seq,
    sealed: bool,
    alloc: std.mem.Allocator,

    pub fn init(path: []u8, base_seq: Seq, node_id: NodeId, created_at: i64, alloc: std.mem.Allocator) !Segment {
        const null_path = try alloc.allocSentinel(u8, path.len, 0);
        defer alloc.free(null_path);
        @memcpy(null_path[0..path.len], path);

        const raw_fd = std.os.linux.open(
            null_path.ptr,
            .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true },
            0o644,
        );
        const fd: std.posix.fd_t = @intCast(@as(isize, @bitCast(raw_fd)));
        if (fd < 0) return error.FileOpenError;
        std.debug.assert(fd >= 0);

        const seg_header = SegmentHeader.init(base_seq, node_id, created_at);
        const header_bytes = seg_header.to_bytes();
        _ = std.os.linux.write(@intCast(fd), header_bytes.ptr, header_size);

        return Segment{
            .fd = fd,
            .path = path,
            .header = seg_header,
            .index = .empty,
            .next_offset = header_size,
            .entry_count = 0,
            .last_seq = if (base_seq > 0) base_seq - 1 else 0,
            .sealed = false,
            .alloc = alloc,
        };
    }

    pub fn open(path: []u8, alloc: std.mem.Allocator) !Segment {
        const null_path = try alloc.allocSentinel(u8, path.len, 0);
        defer alloc.free(null_path);
        @memcpy(null_path[0..path.len], path);

        const raw_fd = std.os.linux.open(null_path.ptr, .{ .ACCMODE = .RDWR }, 0);
        const fd: std.posix.fd_t = @intCast(@as(isize, @bitCast(raw_fd)));
        if (fd < 0) return error.FileOpenError;
        errdefer _ = std.os.linux.close(@intCast(fd));

        var header_buf: [header_size]u8 align(@alignOf(SegmentHeader)) = undefined;
        const header_read_result = std.os.linux.read(@intCast(fd), &header_buf, header_size);
        if (header_read_result != header_size) return error.InvalidSegment;

        const seg_header = @as(*const SegmentHeader, @ptrCast(@alignCast(&header_buf))).*;
        if (!seg_header.is_valid()) return error.CorruptSegmentHeader;

        const file_size = std.os.linux.lseek(@intCast(fd), 0, std.os.linux.SEEK.END);

        const maybe_footer = try open_read_footer(fd, file_size);
        if (maybe_footer == null) {
            const recovered = scan_unsealed_entries(fd);
            return Segment{
                .fd = fd,
                .path = path,
                .header = seg_header,
                .index = .empty,
                .next_offset = recovered.next_offset,
                .entry_count = recovered.entry_count,
                .last_seq = recovered.last_seq,
                .sealed = false,
                .alloc = alloc,
            };
        }

        const seg_footer = maybe_footer.?;
        _ = std.os.linux.lseek(@intCast(fd), header_size, std.os.linux.SEEK.SET);
        return Segment{
            .fd = fd,
            .path = path,
            .header = seg_header,
            .index = .empty,
            .next_offset = seg_footer.index_offset,
            .entry_count = seg_footer.entry_count,
            .last_seq = seg_footer.last_seq,
            .sealed = true,
            .alloc = alloc,
        };
    }

    pub fn append(self: *Segment, log_entry: LogEntry) !void {
        if (self.sealed) return error.SegmentSealed;
        std.debug.assert(!self.sealed);
        std.debug.assert(self.index.items.len < segment_entries_max);

        const offset = self.next_offset;
        const entry_size = log_entry.total_size();

        const buf = try self.alloc.alloc(u8, entry_size);
        defer self.alloc.free(buf);
        log_entry.serialize_to(buf);
        _ = std.os.linux.write(@intCast(self.fd), buf.ptr, entry_size);

        self.next_offset += entry_size;
        self.entry_count += 1;
        self.last_seq = log_entry.header.seq;

        try self.index.append(self.alloc, .{
            .seq = log_entry.header.seq,
            .file_offset = offset,
        });
    }

    pub fn read(
        self: *Segment,
        from_seq: Seq,
        max: usize,
        alloc: std.mem.Allocator,
    ) ![]LogEntry {
        _ = std.os.linux.lseek(@intCast(self.fd), @intCast(header_size), std.os.linux.SEEK.SET);

        var result: std.ArrayList(LogEntry) = .empty;
        errdefer {
            for (result.items) |*entry| entry.deinit(alloc);
            result.deinit(alloc);
        }

        var read_count: u32 = 0;
        while (read_count < self.entry_count and result.items.len < max) {
            const entry = LogEntry.deserialize_fd(self.fd, alloc) catch break;
            read_count += 1;

            if (entry.header.seq < from_seq) {
                var skip_entry = entry;
                skip_entry.deinit(alloc);
                continue;
            }

            try result.append(alloc, entry);
        }

        return try result.toOwnedSlice(alloc);
    }

    pub fn seal(self: *Segment) !void {
        if (self.sealed) return;
        std.debug.assert(self.entry_count > 0);

        const index_offset = self.next_offset;

        for (self.index.items) |index_entry| {
            var buf: [IndexEntry.entry_size]u8 = undefined;
            index_entry.serialize_to(&buf);
            _ = std.os.linux.write(@intCast(self.fd), &buf, IndexEntry.entry_size);
        }

        const seg_footer = SegmentFooter.init(self.entry_count, self.last_seq, index_offset);
        var footer_buf: [footer_size]u8 = undefined;
        seg_footer.serialize_to(&footer_buf);
        _ = std.os.linux.write(@intCast(self.fd), &footer_buf, footer_size);

        _ = std.os.linux.fsync(@intCast(self.fd));
        self.sealed = true;
    }

    /// Remove all entries with seq >= from_seq.
    pub fn truncate_suffix(self: *Segment, from_seq: Seq) !void {
        if (from_seq > self.last_seq) return;

        var cutoff: u64 = header_size;
        var new_count: u32 = 0;
        var new_last: Seq = if (self.header.base_seq > 0) self.header.base_seq - 1 else 0;

        if (!self.sealed) {
            for (self.index.items, 0..) |index_entry, idx| {
                if (index_entry.seq < from_seq) {
                    cutoff = if (idx + 1 < self.index.items.len)
                        self.index.items[idx + 1].file_offset
                    else
                        self.next_offset;
                    new_count += 1;
                    new_last = index_entry.seq;
                } else break;
            }
            self.index.items.len = new_count;
        } else {
            _ = std.os.linux.lseek(@intCast(self.fd), @intCast(header_size), std.os.linux.SEEK.SET);
            var scanned: u32 = 0;
            while (scanned < self.entry_count) {
                var header_buf: [LogEntryHeader.header_size]u8 = undefined;
                const header_read_result = std.os.linux.read(
                    @intCast(self.fd),
                    &header_buf,
                    LogEntryHeader.header_size,
                );
                if (header_read_result != LogEntryHeader.header_size) break;
                const log_header = LogEntryHeader.deserialize_from(&header_buf) catch break;
                _ = std.os.linux.lseek(@intCast(self.fd), @intCast(log_header.payload_len), std.os.linux.SEEK.CUR);
                scanned += 1;
                if (log_header.seq < from_seq) {
                    cutoff = @intCast(std.os.linux.lseek(@intCast(self.fd), 0, std.os.linux.SEEK.CUR));
                    new_count += 1;
                    new_last = log_header.seq;
                } else break;
            }
            self.sealed = false;
        }

        _ = std.os.linux.ftruncate(@intCast(self.fd), @intCast(cutoff));
        _ = std.os.linux.lseek(@intCast(self.fd), @intCast(cutoff), std.os.linux.SEEK.SET);
        self.next_offset = cutoff;
        self.entry_count = new_count;
        self.last_seq = new_last;
        self.sealed = false;
    }

    pub fn deinit(self: *Segment) void {
        if (!self.sealed) {
            _ = std.os.linux.fsync(@intCast(self.fd));
        }
        if (self.index.capacity > 0) {
            self.index.deinit(self.alloc);
        }
        _ = std.os.linux.close(@intCast(self.fd));
        self.alloc.free(self.path);
    }
};
