/// LogMux: merges multiple Log partitions into a single seq-ordered stream.
///
/// Each FoldExecutor reads via LogMux so it sees every committed entry across
/// all log partitions — the read-side broadcast required by spec §7.2 / inv 28.
///
/// Ownership: LogMux owns the `logs` pointer slice (frees it on deinit) but does
/// NOT own the underlying Log values; those are owned by the caller (Gateway /
/// Sequencer).
const std = @import("std");
const log_mod = @import("manager.zig");

const assert = std.debug.assert;
const Log = log_mod.Log;
const LogEntry = @import("entry.zig").LogEntry;
const Seq = @import("entry.zig").Seq;

pub const LogMux = struct {
    /// Borrowed pointers to underlying logs. Slice is owned by LogMux; logs are not.
    logs: []*Log,
    alloc: std.mem.Allocator,

    /// Caller transfers ownership of the `logs` slice to LogMux (LogMux will free it).
    /// The underlying Log values are NOT owned — they must outlive this LogMux.
    pub fn init(logs: []*Log, alloc: std.mem.Allocator) LogMux {
        assert(logs.len > 0);
        return .{ .logs = logs, .alloc = alloc };
    }

    /// Free the logs pointer slice. Does NOT deinit the underlying Log values.
    pub fn deinit(self: *LogMux) void {
        self.alloc.free(self.logs);
    }

    /// Read up to `max` entries with seq >= `from` across all underlying logs,
    /// returned in ascending seq order. Entries with the same seq appearing in
    /// multiple logs (broadcast remnant) are deduplicated — the first copy is kept.
    ///
    /// Caller owns the returned slice: call `entry.deinit(alloc)` on each entry,
    /// then free the slice itself.
    pub fn read(
        self: *const LogMux,
        from: Seq,
        max: usize,
        alloc: std.mem.Allocator,
    ) ![]LogEntry {
        if (max == 0 or self.logs.len == 0) return &.{};

        // Collect candidates from all logs.
        var candidates: std.ArrayListUnmanaged(LogEntry) = .empty;
        errdefer {
            for (candidates.items) |*e| e.deinit(alloc);
            candidates.deinit(alloc);
        }

        for (self.logs) |log| {
            if (log.current_seq < from) continue;
            // Read up to `max` entries from this log. On error (e.g. segment gap),
            // skip this log — other logs may still have the entries we need.
            const entries = log.read(from, max, alloc) catch continue;
            // `entries` is a slice of LogEntry structs; the payload bytes inside each
            // entry are separately heap-allocated and outlive the slice wrapper.
            // We take ownership of the payload bytes by copying the struct; freeing
            // the slice wrapper (entries) only frees the array of structs, not payloads.
            defer alloc.free(entries);
            for (entries) |entry| {
                try candidates.append(alloc, entry);
            }
        }

        if (candidates.items.len == 0) {
            candidates.deinit(alloc);
            return &.{};
        }

        // Sort ascending by seq.
        std.sort.pdq(LogEntry, candidates.items, {}, lessThanBySeq);

        // Deduplicate: same seq in multiple logs = broadcast remnant. Keep first,
        // free the rest. Walk forward so indices remain valid after removal.
        var i: usize = 1;
        while (i < candidates.items.len) {
            if (candidates.items[i].header.seq == candidates.items[i - 1].header.seq) {
                var dup = candidates.orderedRemove(i);
                dup.deinit(alloc);
                // don't increment i — next element shifted into position i
            } else {
                i += 1;
            }
        }

        // Trim to max, freeing entries beyond the limit.
        while (candidates.items.len > max) {
            if (candidates.pop()) |extra| {
                var e = extra;
                e.deinit(alloc);
            }
        }

        return candidates.toOwnedSlice(alloc);
    }

    /// Block until at least one underlying log has committed an entry at seq >= `from`,
    /// or until any log's append_epoch changes (signals notifyAppend / shutdown).
    /// Mirrors Log.waitForEntries: epoch change causes return so the caller can
    /// re-check its shutdown flag.
    pub fn waitForEntries(self: *const LogMux, from: Seq) void {
        // Snapshot epochs so any notifyAppend() (including from stop()) wakes us.
        var initial: [64]u32 = undefined;
        const n = @min(self.logs.len, initial.len);
        for (self.logs[0..n], 0..) |log, i| {
            initial[i] = log.append_epoch.load(.acquire);
        }
        const sleep_ns: std.os.linux.timespec = .{ .sec = 0, .nsec = 100_000 };
        while (true) {
            for (self.logs) |log| {
                if (log.current_seq >= from) return;
            }
            for (self.logs[0..n], 0..) |log, i| {
                if (log.append_epoch.load(.acquire) != initial[i]) return;
            }
            _ = std.os.linux.nanosleep(&sleep_ns, null);
        }
    }

    /// Notify all underlying logs that a new entry may be available.
    /// Called by FoldExecutor.stop() to unblock any waiting threadLoop.
    pub fn notifyAppend(self: *const LogMux) void {
        for (self.logs) |log| log.notifyAppend();
    }
};

fn lessThanBySeq(_: void, a: LogEntry, b: LogEntry) bool {
    return a.header.seq < b.header.seq;
}
