/// Log manager for Foldb's write-ahead log.
const std = @import("std");
const entry_mod = @import("entry.zig");
const segment = @import("segment.zig");

const LogEntry = entry_mod.LogEntry;
const TxnIntent = entry_mod.TxnIntent;
const Seq = entry_mod.Seq;
const NodeId = entry_mod.NodeId;
const Segment = segment.Segment;

pub const LogError = error{
    DiskFull,
    CrcMismatch,
    InvalidSegment,
    SeqOutOfOrder,
    SegmentNotFound,
    DirectoryError,
    LogSealed,
};

pub const DEFAULT_SEGMENT_MAX_ENTRIES: u32 = 10000;

/// Allocates a heap-owned path string: dir + "/" + name
fn buildPath(dir: []const u8, name: []const u8) ![]u8 {
    return std.mem.concat(std.heap.page_allocator, u8, &.{ dir, "/", name });
}

/// Allocates a null-terminated copy of path.
fn toNullPath(path: []const u8) ![:0]u8 {
    const buf = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    @memcpy(buf[0..path.len], path);
    return buf;
}

pub const Log = struct {
    path: []u8,
    node_id: NodeId,
    current_seq: Seq,
    current_segment: Segment,
    segment_max_entries: u32,
    sealed_segments: std.ArrayList(Segment),
    sealed: bool,

    /// Creates or opens a log at the given directory path.
    pub fn init(path: []const u8, node_id: NodeId) !Log {
        const null_path = try toNullPath(path);
        defer std.heap.page_allocator.free(null_path);
        _ = std.os.linux.mkdir(null_path.ptr, 0o755);

        const raw_dir_fd = std.os.linux.open(
            null_path.ptr,
            .{ .ACCMODE = .RDONLY, .DIRECTORY = true },
            0,
        );
        const dir_fd_i: isize = @bitCast(raw_dir_fd);
        if (dir_fd_i < 0) return error.DirectoryOpenError;
        const log_dir_fd: std.posix.fd_t = @intCast(dir_fd_i);
        defer _ = std.os.linux.close(@intCast(log_dir_fd));

        var segments: std.ArrayList(Segment) = .empty;
        errdefer {
            for (segments.items) |*seg| seg.deinit();
            segments.deinit(std.heap.page_allocator);
        }

        var max_seq: Seq = 0;
        var buf: [4096]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
        while (true) {
            const ret = std.os.linux.getdents64(@intCast(log_dir_fd), &buf, buf.len);
            const n: isize = @bitCast(ret);
            if (n <= 0) break;

            var i: usize = 0;
            while (i < @as(usize, @intCast(n))) {
                const dent: *const std.os.linux.dirent64 = @alignCast(@ptrCast(buf[i..].ptr));
                const name = std.mem.span(@as([*:0]const u8, @ptrCast(&dent.name)));
                const DT_REG: u8 = 8;
                if (dent.type == DT_REG and std.mem.endsWith(u8, name, ".seg")) {
                    const seg_path = try buildPath(path, name);
                    const seg = Segment.open(seg_path) catch {
                        std.heap.page_allocator.free(seg_path);
                        i += dent.reclen;
                        continue;
                    };
                    if (seg.last_seq > max_seq) max_seq = seg.last_seq;
                    try segments.append(std.heap.page_allocator, seg);
                }
                i += dent.reclen;
            }
        }

        std.mem.sort(Segment, segments.items, {}, segmentComparator);

        const base_seq = max_seq + 1;
        var name_buf: [32]u8 = undefined;
        const seg_name = std.fmt.bufPrint(&name_buf, "{d:0>16}.seg", .{base_seq}) catch unreachable;
        const current_path = try buildPath(path, seg_name);
        errdefer std.heap.page_allocator.free(current_path);

        const current_segment = try Segment.init(current_path, base_seq, node_id);

        return Log{
            .path = try std.heap.page_allocator.dupe(u8, path),
            .node_id = node_id,
            .current_seq = max_seq,
            .current_segment = current_segment,
            .segment_max_entries = DEFAULT_SEGMENT_MAX_ENTRIES,
            .sealed_segments = segments,
            .sealed = false,
        };
    }

    fn segmentComparator(context: void, a: Segment, b: Segment) bool {
        _ = context;
        return a.header.base_seq < b.header.base_seq;
    }

    pub fn deinit(self: *Log) void {
        if (self.current_segment.entry_count > 0) {
            _ = self.current_segment.seal() catch {};
        }
        self.current_segment.deinit();

        for (self.sealed_segments.items) |*seg| seg.deinit();
        self.sealed_segments.deinit(std.heap.page_allocator);

        std.heap.page_allocator.free(self.path);
    }

    pub fn append(self: *Log, intent: TxnIntent) !Seq {
        if (self.sealed) return LogError.LogSealed;

        self.current_seq += 1;
        const seq = self.current_seq;

        const entry = LogEntry.create(seq, 0, .txn_intent, intent.payload);
        try self.current_segment.append(entry);

        if (self.current_segment.entry_count >= self.segment_max_entries) {
            try self.rotate();
        }

        return seq;
    }

    fn rotate(self: *Log) !void {
        try self.current_segment.seal();

        const new_base_seq = self.current_seq + 1;
        var name_buf: [32]u8 = undefined;
        const seg_name = std.fmt.bufPrint(&name_buf, "{d:0>16}.seg", .{new_base_seq}) catch unreachable;
        const new_path = try buildPath(self.path, seg_name);
        errdefer std.heap.page_allocator.free(new_path);

        var new_segment = try Segment.init(new_path, new_base_seq, self.node_id);
        errdefer new_segment.deinit();

        try self.sealed_segments.append(std.heap.page_allocator, self.current_segment);
        self.current_segment = new_segment;
    }

    pub fn read(
        self: *Log,
        from_seq: Seq,
        max: usize,
        allocator: std.mem.Allocator,
    ) ![]LogEntry {
        var entries: std.ArrayList(LogEntry) = .empty;
        errdefer {
            for (entries.items) |*e| e.deinit(allocator);
            entries.deinit(allocator);
        }

        for (self.sealed_segments.items) |*seg| {
            if (entries.items.len >= max) break;
            if (seg.last_seq < from_seq) continue;

            const seg_entries = try seg.read(from_seq, max - entries.items.len, allocator);
            var appended: usize = 0;
            errdefer {
                for (seg_entries[appended..]) |*e| e.deinit(allocator);
                allocator.free(seg_entries);
            }
            for (seg_entries) |e| {
                try entries.append(allocator, e);
                appended += 1;
            }
            allocator.free(seg_entries);
        }

        if (entries.items.len < max) {
            const cur_entries = try self.current_segment.read(
                from_seq,
                max - entries.items.len,
                allocator,
            );
            var appended: usize = 0;
            errdefer {
                for (cur_entries[appended..]) |*e| e.deinit(allocator);
                allocator.free(cur_entries);
            }
            for (cur_entries) |e| {
                try entries.append(allocator, e);
                appended += 1;
            }
            allocator.free(cur_entries);
        }

        return entries.toOwnedSlice(allocator);
    }

    pub fn head(self: *const Log) !Seq {
        var max_seq = self.current_segment.last_seq;
        for (self.sealed_segments.items) |seg| {
            if (seg.last_seq > max_seq) max_seq = seg.last_seq;
        }
        return max_seq;
    }

    pub fn truncate_prefix(self: *Log, before_seq: Seq) !void {
        var removed: usize = 0;
        for (self.sealed_segments.items) |*seg| {
            if (seg.last_seq < before_seq) {
                const null_path = try toNullPath(seg.path);
                defer std.heap.page_allocator.free(null_path);
                _ = std.os.linux.unlink(null_path.ptr);
                seg.deinit();
                removed += 1;
            } else {
                break;
            }
        }

        if (removed > 0) {
            const new_len = self.sealed_segments.items.len - removed;
            std.mem.copyForwards(
                Segment,
                self.sealed_segments.items[0..new_len],
                self.sealed_segments.items[removed..],
            );
            self.sealed_segments.items.len = new_len;
        }
    }

    pub fn seal(self: *Log) !void {
        if (self.sealed) return;

        if (self.current_segment.entry_count > 0) {
            try self.current_segment.seal();
        }

        self.sealed = true;
    }
};
