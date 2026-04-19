/// Segment file handling for Foldb's write-ahead log.
const std = @import("std");
const crc = @import("crc.zig");
const entry_mod = @import("entry.zig");

const LogEntry = entry_mod.LogEntry;
const LogEntryHeader = entry_mod.LogEntryHeader;
const Seq = entry_mod.Seq;
const NodeId = entry_mod.NodeId;

/// Returns the current wall-clock time in seconds (unix epoch).
/// Use this in production code. Tests should use VirtualClock instead.
pub fn realTimeSec() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    return ts.sec;
}

pub const MAGIC: [4]u8 = .{ 'F', 'L', 'O', 'G' };
pub const VERSION: u32 = 1;
pub const HEADER_SIZE: usize = 64;
pub const FOOTER_SIZE: usize = 64;

/// Segment header - 64 bytes on disk (extern struct for deterministic layout):
/// base_seq(8) node_id(8) created_at(8) magic(4) version(4) part_id(4) reserved(24) header_crc(4)
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
        // Verify layout matches HEADER_SIZE (64 bytes).
        std.debug.assert(@offsetOf(SegmentHeader, "header_crc") == 60);
        std.debug.assert(@sizeOf(SegmentHeader) == HEADER_SIZE);
    }

    pub fn init(base_seq: Seq, node_id: NodeId, created_at: i64) SegmentHeader {
        var header = SegmentHeader{
            .base_seq = base_seq,
            .node_id = node_id,
            .created_at = created_at,
            .magic = MAGIC,
            .version = VERSION,
            .part_id = 0,
            .reserved = [_]u8{0} ** 24,
            .header_crc = 0,
        };
        header.header_crc = computeHeaderCrc(&header);
        return header;
    }

    fn computeHeaderCrc(self: *const SegmentHeader) u32 {
        const bytes = self.toBytes();
        // CRC covers bytes up to (not including) header_crc field.
        return crc.crc32c(bytes[0..@offsetOf(SegmentHeader, "header_crc")]);
    }

    fn toBytes(self: *const SegmentHeader) []const u8 {
        const ptr: [*]const u8 = @ptrCast(@alignCast(self));
        return ptr[0..HEADER_SIZE];
    }

    pub fn isValid(self: *const SegmentHeader) bool {
        if (!std.mem.eql(u8, &self.magic, &MAGIC)) return false;
        if (self.version != VERSION) return false;
        const expected = computeHeaderCrc(self);
        return expected == self.header_crc;
    }
};

/// Segment footer - 64 bytes on disk (explicit sequential layout, no padding):
/// entry_count(4) last_seq(8) index_offset(8) reserved(40) footer_crc(4)
pub const SegmentFooter = struct {
    entry_count: u32,
    last_seq: Seq,
    index_offset: u64,
    reserved: [40]u8,
    footer_crc: u32,

    pub fn init(entry_count: u32, last_seq: Seq, index_offset: u64) SegmentFooter {
        var footer = SegmentFooter{
            .entry_count = entry_count,
            .last_seq = last_seq,
            .index_offset = index_offset,
            .reserved = [_]u8{0} ** 40,
            .footer_crc = 0,
        };
        var buf: [FOOTER_SIZE]u8 = undefined;
        writeBody(&footer, &buf);
        footer.footer_crc = crc.crc32c(buf[0 .. FOOTER_SIZE - 4]);
        return footer;
    }

    pub fn serializeTo(self: *const SegmentFooter, buf: *[FOOTER_SIZE]u8) void {
        writeBody(self, buf);
        std.mem.writeInt(u32, buf[60..64], self.footer_crc, .little);
    }

    pub fn deserializeFrom(buf: *const [FOOTER_SIZE]u8) !SegmentFooter {
        const entry_count = std.mem.readInt(u32, buf[0..4], .little);
        const last_seq = std.mem.readInt(u64, buf[4..12], .little);
        const index_offset = std.mem.readInt(u64, buf[12..20], .little);
        var reserved: [40]u8 = undefined;
        @memcpy(&reserved, buf[20..60]);
        const footer_crc = std.mem.readInt(u32, buf[60..64], .little);
        const footer = SegmentFooter{
            .entry_count = entry_count,
            .last_seq = last_seq,
            .index_offset = index_offset,
            .reserved = reserved,
            .footer_crc = footer_crc,
        };
        var check: [FOOTER_SIZE]u8 = undefined;
        writeBody(&footer, &check);
        const expected = crc.crc32c(check[0 .. FOOTER_SIZE - 4]);
        if (expected != footer_crc) return error.CorruptSegmentFooter;
        return footer;
    }
};

fn writeBody(footer: *const SegmentFooter, buf: *[FOOTER_SIZE]u8) void {
    std.mem.writeInt(u32, buf[0..4], footer.entry_count, .little);
    std.mem.writeInt(u64, buf[4..12], footer.last_seq, .little);
    std.mem.writeInt(u64, buf[12..20], footer.index_offset, .little);
    @memcpy(buf[20..60], &footer.reserved);
}

/// Index entry - maps sequence number to file offset (16 bytes).
pub const IndexEntry = struct {
    seq: Seq,
    file_offset: u64,

    pub const ENTRY_SIZE: usize = 16;

    pub fn serializeTo(self: IndexEntry, buf: *[ENTRY_SIZE]u8) void {
        std.mem.writeInt(u64, buf[0..8], self.seq, .little);
        std.mem.writeInt(u64, buf[8..16], self.file_offset, .little);
    }

    pub fn deserializeFrom(buf: *const [ENTRY_SIZE]u8) IndexEntry {
        return .{
            .seq = std.mem.readInt(u64, buf[0..8], .little),
            .file_offset = std.mem.readInt(u64, buf[8..16], .little),
        };
    }
};

/// Segment file - a contiguous file containing log entries.
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

    pub fn init(path: []u8, base_seq: Seq, node_id: NodeId, created_at: i64) !Segment {
        const null_path = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
        defer std.heap.page_allocator.free(null_path);
        @memcpy(null_path[0..path.len], path);

        const raw_fd = std.os.linux.open(
            null_path.ptr,
            .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true },
            0o644,
        );
        const fd: std.posix.fd_t = @intCast(@as(isize, @bitCast(raw_fd)));
        if (fd < 0) return error.FileOpenError;

        const header = SegmentHeader.init(base_seq, node_id, created_at);
        const header_bytes = header.toBytes();
        _ = std.os.linux.write(@intCast(fd), header_bytes.ptr, HEADER_SIZE);

        return Segment{
            .fd = fd,
            .path = path,
            .header = header,
            .index = .empty,
            .next_offset = HEADER_SIZE,
            .entry_count = 0,
            .last_seq = if (base_seq > 0) base_seq - 1 else 0,
            .sealed = false,
        };
    }

    pub fn open(path: []u8) !Segment {
        const null_path = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
        defer std.heap.page_allocator.free(null_path);
        @memcpy(null_path[0..path.len], path);

        const raw_fd = std.os.linux.open(null_path.ptr, .{ .ACCMODE = .RDWR }, 0);
        const fd: std.posix.fd_t = @intCast(@as(isize, @bitCast(raw_fd)));
        if (fd < 0) return error.FileOpenError;

        // Read and validate header
        var header_buf: [HEADER_SIZE]u8 align(@alignOf(SegmentHeader)) = undefined;
        const hn = std.os.linux.read(@intCast(fd), &header_buf, HEADER_SIZE);
        if (hn != HEADER_SIZE) {
            _ = std.os.linux.close(@intCast(fd));
            return error.InvalidSegment;
        }

        const header_ptr = @as(*const SegmentHeader, @ptrCast(@alignCast(&header_buf)));
        const header = header_ptr.*;
        if (!header.isValid()) {
            _ = std.os.linux.close(@intCast(fd));
            return error.CorruptSegmentHeader;
        }

        // Get file size
        const file_size = std.os.linux.lseek(@intCast(fd), 0, std.os.linux.SEEK.END);

        if (file_size < HEADER_SIZE + FOOTER_SIZE) {
            _ = std.os.linux.lseek(@intCast(fd), @intCast(HEADER_SIZE), std.os.linux.SEEK.SET);
            return Segment{
                .fd = fd,
                .path = path,
                .header = header,
                .index = .empty,
                .next_offset = HEADER_SIZE,
                .entry_count = 0,
                .last_seq = 0,
                .sealed = false,
            };
        }

        // Read footer
        const footer_pos: i64 = @intCast(file_size - FOOTER_SIZE);
        _ = std.os.linux.lseek(@intCast(fd), footer_pos, std.os.linux.SEEK.SET);
        var footer_buf: [FOOTER_SIZE]u8 = undefined;
        const fn2 = std.os.linux.read(@intCast(fd), &footer_buf, FOOTER_SIZE);

        if (fn2 != FOOTER_SIZE) {
            _ = std.os.linux.close(@intCast(fd));
            return error.InvalidSegment;
        }

        const footer = SegmentFooter.deserializeFrom(&footer_buf) catch {
            _ = std.os.linux.lseek(@intCast(fd), @intCast(HEADER_SIZE), std.os.linux.SEEK.SET);
            return Segment{
                .fd = fd,
                .path = path,
                .header = header,
                .index = .empty,
                .next_offset = HEADER_SIZE,
                .entry_count = 0,
                .last_seq = 0,
                .sealed = false,
            };
        };

        _ = std.os.linux.lseek(@intCast(fd), @intCast(HEADER_SIZE), std.os.linux.SEEK.SET);

        return Segment{
            .fd = fd,
            .path = path,
            .header = header,
            .index = .empty,
            .next_offset = footer.index_offset,
            .entry_count = footer.entry_count,
            .last_seq = footer.last_seq,
            .sealed = true,
        };
    }

    pub fn append(self: *Segment, log_entry: LogEntry) !void {
        if (self.sealed) return error.SegmentSealed;

        const offset = self.next_offset;
        const entry_size = log_entry.totalSize();

        const buf = try std.heap.page_allocator.alloc(u8, entry_size);
        defer std.heap.page_allocator.free(buf);
        log_entry.serializeTo(buf);
        _ = std.os.linux.write(@intCast(self.fd), buf.ptr, entry_size);

        self.next_offset += entry_size;
        self.entry_count += 1;
        self.last_seq = log_entry.header.seq;

        try self.index.append(std.heap.page_allocator, .{
            .seq = log_entry.header.seq,
            .file_offset = offset,
        });
    }

    pub fn read(
        self: *Segment,
        from_seq: Seq,
        max: usize,
        allocator: std.mem.Allocator,
    ) ![]LogEntry {
        _ = std.os.linux.lseek(@intCast(self.fd), @intCast(HEADER_SIZE), std.os.linux.SEEK.SET);

        var result: std.ArrayList(LogEntry) = .empty;
        errdefer {
            for (result.items) |*e| e.deinit(allocator);
            result.deinit(allocator);
        }

        var read_count: u32 = 0;
        while (read_count < self.entry_count and result.items.len < max) {
            const entry = LogEntry.deserializeFd(self.fd, allocator) catch break;
            read_count += 1;

            if (entry.header.seq < from_seq) {
                var e = entry;
                e.deinit(allocator);
                continue;
            }

            try result.append(allocator, entry);
        }

        return try result.toOwnedSlice(allocator);
    }

    pub fn seal(self: *Segment) !void {
        if (self.sealed) return;

        const index_offset = self.next_offset;

        for (self.index.items) |ie| {
            var buf: [IndexEntry.ENTRY_SIZE]u8 = undefined;
            ie.serializeTo(&buf);
            _ = std.os.linux.write(@intCast(self.fd), &buf, IndexEntry.ENTRY_SIZE);
        }

        const footer = SegmentFooter.init(self.entry_count, self.last_seq, index_offset);
        var footer_buf: [FOOTER_SIZE]u8 = undefined;
        footer.serializeTo(&footer_buf);
        _ = std.os.linux.write(@intCast(self.fd), &footer_buf, FOOTER_SIZE);

        _ = std.os.linux.fsync(@intCast(self.fd));
        self.sealed = true;
    }

    /// Remove all entries with seq >= from_seq.
    /// For unsealed segments uses the in-memory index; for sealed segments scans from header.
    /// Leaves the segment unsealed and writable afterwards.
    pub fn truncateSuffix(self: *Segment, from_seq: Seq) !void {
        if (from_seq > self.last_seq) return;

        var cutoff: u64 = HEADER_SIZE;
        var new_count: u32 = 0;
        var new_last: Seq = if (self.header.base_seq > 0) self.header.base_seq - 1 else 0;

        if (!self.sealed) {
            for (self.index.items, 0..) |ie, idx| {
                if (ie.seq < from_seq) {
                    cutoff = if (idx + 1 < self.index.items.len)
                        self.index.items[idx + 1].file_offset
                    else
                        self.next_offset;
                    new_count += 1;
                    new_last = ie.seq;
                } else break;
            }
            self.index.items.len = new_count;
        } else {
            // Scan entries sequentially since index is empty for sealed segments.
            _ = std.os.linux.lseek(@intCast(self.fd), @intCast(HEADER_SIZE), std.os.linux.SEEK.SET);
            var scanned: u32 = 0;
            while (scanned < self.entry_count) {
                var hbuf: [LogEntryHeader.HEADER_SIZE]u8 = undefined;
                const n = std.os.linux.read(@intCast(self.fd), &hbuf, LogEntryHeader.HEADER_SIZE);
                if (n != LogEntryHeader.HEADER_SIZE) break;
                const hdr = LogEntryHeader.deserializeFrom(&hbuf) catch break;
                _ = std.os.linux.lseek(@intCast(self.fd), @intCast(hdr.payload_len), std.os.linux.SEEK.CUR);
                scanned += 1;
                if (hdr.seq < from_seq) {
                    cutoff = @intCast(std.os.linux.lseek(@intCast(self.fd), 0, std.os.linux.SEEK.CUR));
                    new_count += 1;
                    new_last = hdr.seq;
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
            self.index.deinit(std.heap.page_allocator);
        }
        _ = std.os.linux.close(@intCast(self.fd));
        std.heap.page_allocator.free(self.path);
    }
};
