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
    partition_id: entry_mod.PartitionId,
    current_seq: Seq,
    current_term: entry_mod.Epoch, // Raft term for entries appended via append()
    current_segment: Segment,
    segment_max_entries: u32,
    sealed_segments: std.ArrayList(Segment),
    sealed: bool,
    last_snapshot_seq: Seq = 0,

    /// Creates or opens a log at the given directory path.
    /// partition_id identifies which data/ordering partition this log belongs to.
    pub fn init(path: []const u8, node_id: NodeId) !Log {
        return initPartitioned(path, node_id, 0);
    }

    pub fn initPartitioned(path: []const u8, node_id: NodeId, partition_id: entry_mod.PartitionId) !Log {
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
                const dent: *const std.os.linux.dirent64 = @ptrCast(@alignCast(buf[i..].ptr));
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
            .partition_id = partition_id,
            .current_seq = max_seq,
            .current_term = 0,
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

        const payload = try intent.serializeTo(std.heap.page_allocator);
        errdefer std.heap.page_allocator.free(payload);

        const entry = LogEntry.create(seq, self.current_term, .txn_intent, payload);
        try self.current_segment.append(entry);

        if (self.current_segment.entry_count >= self.segment_max_entries) {
            try self.rotate();
        }

        return seq;
    }

    /// Append a TxnIntent at a pre-assigned global sequence number.
    /// Accepts any seq > current_seq (no gap-freedom requirement).
    /// Used by data partition logs where the Sequencer assigns global seqs.
    pub fn appendAt(self: *Log, intent: TxnIntent, seq: Seq) !void {
        if (self.sealed) return LogError.LogSealed;
        if (seq <= self.current_seq) return LogError.SeqOutOfOrder;

        const payload = try intent.serializeTo(std.heap.page_allocator);
        errdefer std.heap.page_allocator.free(payload);

        const entry = LogEntry.create(seq, self.current_term, .txn_intent, payload);
        try self.current_segment.append(entry);
        self.current_seq = seq;

        if (self.current_segment.entry_count >= self.segment_max_entries) {
            try self.rotate();
        }
    }

    pub fn rotate(self: *Log) !void {
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

    /// Return the Raft term (epoch) of the entry at seq, or 0 if seq == 0.
    pub fn termAt(self: *Log, seq: Seq, allocator: std.mem.Allocator) !entry_mod.Epoch {
        if (seq == 0) return 0;
        const entries = try self.read(seq, 1, allocator);
        defer {
            for (entries) |*e| e.deinit(allocator);
            allocator.free(entries);
        }
        if (entries.len == 0 or entries[0].header.seq != seq) return error.EntryNotFound;
        return entries[0].header.epoch;
    }

    pub fn head(self: *const Log) !Seq {
        var max_seq = self.current_segment.last_seq;
        for (self.sealed_segments.items) |seg| {
            if (seg.last_seq > max_seq) max_seq = seg.last_seq;
        }
        return max_seq;
    }

    pub fn notifySnapshot(self: *Log, seq: Seq) void {
        if (seq > self.last_snapshot_seq) self.last_snapshot_seq = seq;
    }

    pub fn appendMarker(self: *Log, kind: entry_mod.EntryKind, payload: []const u8) !Seq {
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
        const safe_seq = if (self.last_snapshot_seq == 0) before_seq
                         else @min(before_seq, self.last_snapshot_seq);
        var removed: usize = 0;
        for (self.sealed_segments.items) |*seg| {
            if (seg.last_seq < safe_seq) {
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

    /// Updates the current term (epoch) for new entries.
    /// Called by Raft when the node's term changes.
    pub fn updateTerm(self: *Log, term: entry_mod.Epoch) void {
        self.current_term = term;
    }

    /// Append a pre-built LogEntry at a globally-assigned seq (any seq > current_seq).
    /// Used by data partition logs driven by the Sequencer.
    pub fn appendEntryAt(self: *Log, entry: LogEntry) !void {
        if (self.sealed) return LogError.LogSealed;
        if (entry.header.seq <= self.current_seq) return LogError.SeqOutOfOrder;

        try self.current_segment.append(entry);
        self.current_seq = entry.header.seq;
        self.current_term = entry.header.epoch;

        if (self.current_segment.entry_count >= self.segment_max_entries) {
            try self.rotate();
        }
    }

    /// Append a pre-sequenced entry (used by Raft followers).
    /// The entry's seq must equal current_seq + 1.
    pub fn appendEntry(self: *Log, entry: LogEntry) !void {
        if (self.sealed) return LogError.LogSealed;
        if (entry.header.seq != self.current_seq + 1) return LogError.SeqOutOfOrder;

        try self.current_segment.append(entry);
        self.current_seq = entry.header.seq;
        self.current_term = entry.header.epoch; // Update term to match appended entry

        if (self.current_segment.entry_count >= self.segment_max_entries) {
            try self.rotate();
        }
    }

    /// Remove all entries with seq >= from_seq.
    /// Used by Raft followers to resolve log conflicts with a new leader.
    pub fn truncateSuffix(self: *Log, from_seq: Seq) !void {
        if (from_seq > self.current_seq) return;

        // Case 1: conflict is within the current (unsealed) segment.
        if (from_seq >= self.current_segment.header.base_seq) {
            try self.current_segment.truncateSuffix(from_seq);
            self.current_seq = self.current_segment.last_seq;
            return;
        }

        // Case 2: conflict reaches into sealed segments.
        // Walk backwards to find the segment containing from_seq.
        var pivot: ?usize = null;
        var i: usize = self.sealed_segments.items.len;
        while (i > 0) {
            i -= 1;
            if (self.sealed_segments.items[i].header.base_seq <= from_seq) {
                pivot = i;
                break;
            }
        }

        // Discard the current segment entirely.
        self.current_segment.deinit();

        // Delete sealed segments after the pivot (or all if no pivot).
        const del_start: usize = if (pivot) |p| p + 1 else 0;
        var j: usize = del_start;
        while (j < self.sealed_segments.items.len) : (j += 1) {
            var seg = &self.sealed_segments.items[j];
            const null_path = try toNullPath(seg.path);
            defer std.heap.page_allocator.free(null_path);
            _ = std.os.linux.unlink(null_path.ptr);
            seg.deinit();
        }
        self.sealed_segments.items.len = del_start;

        if (pivot) |p| {
            // Truncate inside the pivot sealed segment and promote it to current.
            try self.sealed_segments.items[p].truncateSuffix(from_seq);
            self.current_segment = self.sealed_segments.items[p];
            self.sealed_segments.items.len = p;
            self.current_seq = self.current_segment.last_seq;
        } else {
            // Everything was past from_seq; start a fresh current segment.
            const base: Seq = if (from_seq > 0) from_seq else 1;
            var name_buf: [32]u8 = undefined;
            const seg_name = std.fmt.bufPrint(&name_buf, "{d:0>16}.seg", .{base}) catch unreachable;
            const new_path = try buildPath(self.path, seg_name);
            errdefer std.heap.page_allocator.free(new_path);
            self.current_segment = try Segment.init(new_path, base, self.node_id);
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
};
