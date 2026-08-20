/// Log manager for Foldb's write-ahead log.
const std = @import("std");
const entry_mod = @import("entry.zig");
const segment = @import("segment.zig");
const obs = @import("observability.zig");

const LogEntry = entry_mod.LogEntry;
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

pub const default_segment_max_entries: u32 = 10000;

const sealed_segments_max: u32 = 1 << 16;

fn build_path(dir: []const u8, name: []const u8, alloc: std.mem.Allocator) ![]u8 {
    return std.mem.concat(alloc, u8, &.{ dir, "/", name });
}

fn to_null_path(path: []const u8, alloc: std.mem.Allocator) ![:0]u8 {
    const buf = try alloc.allocSentinel(u8, path.len, 0);
    @memcpy(buf[0..path.len], path);
    return buf;
}

pub const Log = struct {
    path: []u8,
    node_id: NodeId,
    partition_id: entry_mod.PartitionId,
    current_seq: Seq,
    current_term: entry_mod.Epoch,
    current_segment: Segment,
    segment_max_entries: u32,
    sealed_segments: std.ArrayList(Segment),
    sealed: bool,
    last_snapshot_seq: Seq = 0,
    metrics: obs.LogMetrics = .{},
    alloc: std.mem.Allocator,
    /// Incremented on every append; readers can poll this for change detection.
    append_epoch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn init(path: []const u8, node_id: NodeId, alloc: std.mem.Allocator) !Log {
        return init_partitioned(path, node_id, 0, alloc);
    }

    pub fn init_partitioned(
        path: []const u8,
        node_id: NodeId,
        partition_id: entry_mod.PartitionId,
        alloc: std.mem.Allocator,
    ) !Log {
        const null_path = try to_null_path(path, alloc);
        defer alloc.free(null_path);
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
            for (segments.items) |*log_segment| log_segment.deinit();
            segments.deinit(alloc);
        }

        var max_seq: Seq = 0;
        var buf: [4096]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
        while (true) {
            const ret = std.os.linux.getdents64(@intCast(log_dir_fd), &buf, buf.len);
            const dir_read_result: isize = @bitCast(ret);
            if (dir_read_result <= 0) break;

            var i: usize = 0;
            while (i < @as(usize, @intCast(dir_read_result))) {
                const dent: *const std.os.linux.dirent64 = @ptrCast(@alignCast(buf[i..].ptr));
                const name = std.mem.span(@as([*:0]const u8, @ptrCast(&dent.name)));
                const DT_REG: u8 = 8;
                if (dent.type == DT_REG and std.mem.endsWith(u8, name, ".seg")) {
                    const seg_path = try build_path(path, name, alloc);
                    const log_segment = Segment.open(seg_path, alloc) catch {
                        alloc.free(seg_path);
                        i += dent.reclen;
                        continue;
                    };
                    if (log_segment.last_seq > max_seq) max_seq = log_segment.last_seq;
                    if (segments.items.len >= sealed_segments_max) return error.TooManySegments;
                    try segments.append(alloc, log_segment);
                }
                i += dent.reclen;
            }
        }

        std.mem.sort(Segment, segments.items, {}, segment_comparator);

        const base_seq = max_seq + 1;
        // SAFETY: bufPrint writes to name_buf before seg_name is used; buffer is large enough.
        var name_buf: [32]u8 = undefined;
        const seg_name = std.fmt.bufPrint(&name_buf, "{d:0>16}.seg", .{base_seq}) catch |err| std.debug.panic("unexpected: {}", .{err});
        const current_path = try build_path(path, seg_name, alloc);
        errdefer alloc.free(current_path);

        const current_segment = try Segment.init(current_path, base_seq, node_id, segment.real_time_sec(), alloc);

        return Log{
            .path = try alloc.dupe(u8, path),
            .node_id = node_id,
            .partition_id = partition_id,
            .current_seq = max_seq,
            .current_term = 0,
            .current_segment = current_segment,
            .segment_max_entries = default_segment_max_entries,
            .sealed_segments = segments,
            .sealed = false,
            .alloc = alloc,
        };
    }

    fn segment_comparator(context: void, a: Segment, b: Segment) bool {
        _ = context;
        return a.header.base_seq < b.header.base_seq;
    }

    pub fn deinit(self: *Log) void {
        if (self.current_segment.entry_count > 0) {
            _ = self.current_segment.seal() catch |err| std.log.warn("segment seal on deinit: {}", .{err});
        }
        self.current_segment.deinit();

        for (self.sealed_segments.items) |*log_segment| log_segment.deinit();
        self.sealed_segments.deinit(self.alloc);

        self.alloc.free(self.path);
    }

    pub fn rotate(self: *Log) !void {
        self.metrics.segments_rotated.inc();
        try self.current_segment.seal();

        const new_base_seq = self.current_seq + 1;
        // SAFETY: bufPrint writes to name_buf before seg_name is used; buffer is large enough.
        var name_buf: [32]u8 = undefined;
        const seg_name = std.fmt.bufPrint(&name_buf, "{d:0>16}.seg", .{new_base_seq}) catch |err| std.debug.panic("unexpected: {}", .{err});
        const new_path = try build_path(self.path, seg_name, self.alloc);
        errdefer self.alloc.free(new_path);

        var new_segment = try Segment.init(new_path, new_base_seq, self.node_id, segment.real_time_sec(), self.alloc);
        errdefer new_segment.deinit();

        if (self.sealed_segments.items.len >= sealed_segments_max) return error.TooManySegments;
        try self.sealed_segments.append(self.alloc, self.current_segment);
        self.current_segment = new_segment;
    }

    pub fn read(
        self: *Log,
        from_seq: Seq,
        max: usize,
        alloc: std.mem.Allocator,
    ) ![]LogEntry {
        var entries: std.ArrayList(LogEntry) = .empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(alloc);
            entries.deinit(alloc);
        }

        for (self.sealed_segments.items) |*log_segment| {
            if (entries.items.len >= max) break;
            if (log_segment.last_seq < from_seq) continue;

            const seg_entries = try log_segment.read(from_seq, max - entries.items.len, alloc);
            var appended: usize = 0;
            errdefer {
                for (seg_entries[appended..]) |*entry| entry.deinit(alloc);
                alloc.free(seg_entries);
            }
            for (seg_entries) |entry| {
                try entries.append(alloc, entry);
                appended += 1;
            }
            alloc.free(seg_entries);
        }

        if (entries.items.len < max) {
            const cur_entries = try self.current_segment.read(
                from_seq,
                max - entries.items.len,
                alloc,
            );
            var appended: usize = 0;
            errdefer {
                for (cur_entries[appended..]) |*entry| entry.deinit(alloc);
                alloc.free(cur_entries);
            }
            for (cur_entries) |entry| {
                try entries.append(alloc, entry);
                appended += 1;
            }
            alloc.free(cur_entries);
        }

        const result = try entries.toOwnedSlice(alloc);
        self.metrics.entries_read.add(@intCast(result.len));
        var bytes: u64 = 0;
        for (result) |entry| bytes += @intCast(entry.payload.len);
        self.metrics.bytes_read.add(bytes);
        return result;
    }

    pub fn term_at(self: *Log, seq: Seq, alloc: std.mem.Allocator) !entry_mod.Epoch {
        if (seq == 0) return 0;
        const entries = try self.read(seq, 1, alloc);
        defer {
            for (entries) |*entry| entry.deinit(alloc);
            alloc.free(entries);
        }
        if (entries.len == 0 or entries[0].header.seq != seq) return error.EntryNotFound;
        return entries[0].header.epoch;
    }

    pub fn head(self: *const Log) !Seq {
        var max_seq = self.current_segment.last_seq;
        for (self.sealed_segments.items) |log_segment| {
            if (log_segment.last_seq > max_seq) max_seq = log_segment.last_seq;
        }
        return max_seq;
    }

    pub fn notify_snapshot(self: *Log, seq: Seq) void {
        if (seq > self.last_snapshot_seq) self.last_snapshot_seq = seq;
    }

    pub fn append_marker(self: *Log, kind: entry_mod.EntryKind, payload: []const u8) !Seq {
        if (self.sealed) return LogError.LogSealed;
        self.current_seq += 1;
        const seq = self.current_seq;
        const log_entry = entry_mod.LogEntry.create(seq, self.current_term, kind, payload);
        try self.current_segment.append(log_entry);
        if (self.current_segment.entry_count >= self.segment_max_entries) {
            try self.rotate();
        }
        return seq;
    }

    pub fn truncate_prefix(self: *Log, before_seq: Seq) !void {
        self.metrics.truncations.inc();
        const safe_seq = if (self.last_snapshot_seq == 0) before_seq else @min(before_seq, self.last_snapshot_seq);
        var removed: usize = 0;
        for (self.sealed_segments.items) |*log_segment| {
            if (log_segment.last_seq < safe_seq) {
                const null_path = try to_null_path(log_segment.path, self.alloc);
                defer self.alloc.free(null_path);
                _ = std.os.linux.unlink(null_path.ptr);
                log_segment.deinit();
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

    pub fn sync(self: *Log) !void {
        try self.current_segment.sync();
    }

    pub fn update_term(self: *Log, term: entry_mod.Epoch) void {
        self.current_term = term;
    }

    pub fn append_entry_at(self: *Log, entry: LogEntry) !void {
        if (self.sealed) return LogError.LogSealed;
        if (entry.header.seq <= self.current_seq) return LogError.SeqOutOfOrder;
        std.debug.assert(entry.header.seq > self.current_seq);

        try self.current_segment.append(entry);
        self.current_seq = entry.header.seq;
        self.current_term = entry.header.epoch;

        self.metrics.entries_appended.inc();
        self.metrics.bytes_appended.add(@intCast(entry.header.payload_len));
        self.metrics.current_seq.set(@intCast(entry.header.seq));

        if (self.current_segment.entry_count >= self.segment_max_entries) {
            try self.rotate();
        }
    }

    pub fn append_entry(self: *Log, entry: LogEntry) !void {
        if (self.sealed) return LogError.LogSealed;
        if (entry.header.seq != self.current_seq + 1) return LogError.SeqOutOfOrder;
        std.debug.assert(entry.header.seq == self.current_seq + 1);

        try self.current_segment.append(entry);
        self.current_seq = entry.header.seq;
        self.current_term = entry.header.epoch;

        self.metrics.entries_appended.inc();
        self.metrics.bytes_appended.add(@intCast(entry.header.payload_len));
        self.metrics.current_seq.set(@intCast(entry.header.seq));

        if (self.current_segment.entry_count >= self.segment_max_entries) {
            try self.rotate();
        }
    }

    pub fn truncate_suffix(self: *Log, from_seq: Seq) !void {
        std.debug.assert(from_seq > 0);
        if (from_seq > self.current_seq) return;

        if (from_seq >= self.current_segment.header.base_seq) {
            try self.current_segment.truncate_suffix(from_seq);
            self.current_seq = self.current_segment.last_seq;
            return;
        }

        var pivot: ?usize = null;
        var i: usize = self.sealed_segments.items.len;
        while (i > 0) {
            i -= 1;
            if (self.sealed_segments.items[i].header.base_seq <= from_seq) {
                pivot = i;
                break;
            }
        }

        self.current_segment.deinit();

        const del_start: usize = if (pivot) |p| p + 1 else 0;
        var j: usize = del_start;
        while (j < self.sealed_segments.items.len) : (j += 1) {
            var log_segment = &self.sealed_segments.items[j];
            const null_path = try to_null_path(log_segment.path, self.alloc);
            defer self.alloc.free(null_path);
            _ = std.os.linux.unlink(null_path.ptr);
            log_segment.deinit();
        }
        self.sealed_segments.items.len = del_start;

        if (pivot) |p| {
            try self.sealed_segments.items[p].truncate_suffix(from_seq);
            self.current_segment = self.sealed_segments.items[p];
            self.sealed_segments.items.len = p;
            self.current_seq = self.current_segment.last_seq;
        } else {
            const base: Seq = if (from_seq > 0) from_seq else 1;
            // SAFETY: bufPrint writes to name_buf before seg_name is used; buffer is large enough.
            var name_buf: [32]u8 = undefined;
            const seg_name = std.fmt.bufPrint(&name_buf, "{d:0>16}.seg", .{base}) catch |err| std.debug.panic("unexpected: {}", .{err});
            const new_path = try build_path(self.path, seg_name, self.alloc);
            errdefer self.alloc.free(new_path);
            self.current_segment = try Segment.init(new_path, base, self.node_id, segment.real_time_sec(), self.alloc);
            self.current_seq = if (from_seq > 0) from_seq - 1 else 0;
        }
    }

    pub fn seal(self: *Log) !void {
        if (self.sealed) return;

        if (self.current_segment.entry_count > 0) {
            try self.current_segment.seal();
        }

        self.sealed = true;
    }

    /// Called by the sequencer after appending an entry. Increments the epoch counter so
    /// FoldExecutor can detect new entries by polling.
    pub fn notifyAppend(self: *Log) void {
        _ = self.append_epoch.fetchAdd(1, .release);
    }

    /// Called by FoldExecutor when the log is empty at from_seq.
    /// Blocks using a brief nanosleep until the append epoch changes.
    pub fn waitForEntries(self: *Log, from_seq: Seq) void {
        const initial = self.append_epoch.load(.acquire);
        const sleep_ns = std.os.linux.timespec{ .sec = 0, .nsec = 100_000 };
        while (self.current_seq < from_seq) {
            if (self.append_epoch.load(.acquire) != initial) return;
            _ = std.os.linux.nanosleep(&sleep_ns, null);
        }
    }
};
