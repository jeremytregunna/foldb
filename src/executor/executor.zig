/// Fold Executor: consumes committed LogEntries, applies KV mutations to Storage deterministically.
const std = @import("std");
const assert = std.debug.assert;
const types_mod = @import("types.zig");
const log_mod = @import("log.zig");
const storage_mod = @import("storage.zig");
const determinism_mod = @import("determinism.zig");
const cdc_mod = @import("cdc.zig");
const obs = @import("observability.zig");

comptime {
    determinism_mod.verifyExecutorModule();
}

pub const AbortCode = types_mod.AbortCode;
pub const ExecResult = types_mod.ExecResult;
pub const TxnIntentDecoded = types_mod.TxnIntentDecoded;
pub const ValidatedTxnEntry = types_mod.ValidatedTxnEntry;
pub const serialize_txn_intent = types_mod.serialize_txn_intent;
pub const deserialize_txn_intent = types_mod.deserialize_txn_intent;
pub const PartitionId = types_mod.PartitionId;
pub const LogEntry = log_mod.LogEntry;
pub const EntryKind = log_mod.EntryKind;
pub const Storage = storage_mod.Storage;
pub const Mutation = storage_mod.Mutation;
pub const Seq = types_mod.Seq;

pub fn validate_txn_entry(entry: LogEntry, alloc: std.mem.Allocator) !ValidatedTxnEntry {
    assert(entry.header.kind == .txn_intent);
    if (!entry.verify_crc()) return error.CrcMismatch;
    const decoded = try deserialize_txn_intent(entry.payload, alloc);
    return .{ .seq = entry.header.seq, .partition = 0, .decoded = decoded };
}

fn validate_snapshot_entry(entry: LogEntry, alloc: std.mem.Allocator) !Seq {
    assert(entry.header.kind == .snapshot_marker);
    const marker = try storage_mod.SnapshotMarkerPayload.deserialize(entry.payload, alloc);
    defer {
        var m = marker;
        m.deinit(alloc);
    }
    return marker.seq;
}

pub const ExecutorMetrics = obs.ExecutorMetrics;
pub const Log = log_mod.Log;
pub const CdcManager = cdc_mod.CdcManager;

const NamespaceId = storage_mod.NamespaceId;
const default_namespace_id: NamespaceId = 1;
const drain_iterations_max: u32 = 1 << 20;

pub const Executor = struct {
    storage: *Storage,
    committed_seq: Seq,
    alloc: std.mem.Allocator,
    partition_count: PartitionId = 1,
    log: ?*Log = null,
    cdc: ?*CdcManager = null,
    metrics: obs.ExecutorMetrics = .{},
    namespace_id: NamespaceId = default_namespace_id,

    pub fn init(storage: *Storage, alloc: std.mem.Allocator) Executor {
        return .{ .storage = storage, .committed_seq = 0, .alloc = alloc };
    }

    pub fn with_log(self: *Executor, log: *Log) void {
        self.log = log;
    }
    pub fn with_cdc(self: *Executor, manager: *CdcManager) void {
        self.cdc = manager;
    }
    pub fn deinit(self: *Executor) void {
        _ = self;
    }
    pub fn current_seq(self: *const Executor) Seq {
        return self.committed_seq;
    }

    pub fn run(self: *Executor, entry: LogEntry) !ExecResult {
        defer {
            self.committed_seq = entry.header.seq;
            self.metrics.current_seq.set(@intCast(entry.header.seq));
        }

        if (entry.header.kind != .txn_intent) {
            if (entry.header.kind == .snapshot_marker) {
                if (validate_snapshot_entry(entry, self.alloc)) |ms| {
                    if (self.log) |l| l.notify_snapshot(ms);
                } else |_| {}
            }
            self.metrics.noops_processed.inc();
            return .{ .ok = .{ .rows_affected = 0 } };
        }

        var validated = validate_txn_entry(entry, self.alloc) catch |e| {
            self.metrics.txns_aborted.inc();
            return switch (e) {
                error.CrcMismatch => .{ .abort = .{ .code = .bad_payload, .detail = "crc mismatch" } },
                else => .{ .abort = .{ .code = .bad_payload, .detail = "invalid payload" } },
            };
        };
        defer validated.decoded.deinit(self.alloc);

        var mutations: std.ArrayList(Mutation) = .empty;
        defer {
            for (mutations.items) |m| {
                self.alloc.free(m.key);
                if (m.value) |v| self.alloc.free(v);
            }
            mutations.deinit(self.alloc);
        }

        const decoded = validated.decoded;
        for (decoded.ops) |op| {
            switch (op) {
                .set => |s| {
                    if (s.expected_seq > 0) {
                        const current = try self.storage.get(self.namespace_id, s.key, entry.header.seq - 1);
                        defer if (current) |row| row.deinit(self.alloc);
                        if (current == null or current.?.seq != s.expected_seq) {
                            self.metrics.txns_aborted.inc();
                            return .{ .abort = .{ .code = .constraint_violation, .detail = "compare-and-swap failed" } };
                        }
                    }
                },
                .delete => {},
            }
        }

        for (decoded.ops) |op| {
            switch (op) {
                .set => |s| {
                    const key_copy = try self.alloc.dupe(u8, s.key);
                    errdefer self.alloc.free(key_copy);
                    const val = try self.alloc.dupe(u8, s.value);
                    errdefer self.alloc.free(val);
                    try self.appendTxnMutation(&mutations, 0, .{ .kind = .update, .namespace_id = self.namespace_id, .key = key_copy, .value = val });
                },
                .delete => |d| {
                    const key_copy = try self.alloc.dupe(u8, d.key);
                    errdefer self.alloc.free(key_copy);
                    try self.appendTxnMutation(&mutations, 0, .{ .kind = .delete, .namespace_id = self.namespace_id, .key = key_copy, .value = null });
                },
            }
        }

        var before_images: ?cdc_mod.BeforeImages = null;
        defer if (before_images) |*bi| bi.deinit();
        if (self.cdc) |mgr| {
            const pre_seq: Seq = if (entry.header.seq > 0) entry.header.seq - 1 else 0;
            before_images = try mgr.capture_before_images(mutations.items, self.storage, pre_seq, self.alloc);
        }
        try self.storage.apply(mutations.items, entry.header.seq);
        if (self.cdc) |mgr| {
            if (before_images) |bi| {
                try mgr.dispatch(entry.header.seq, 0, .txn_intent, mutations.items, bi, self.alloc);
            }
        }

        const rows: u64 = @intCast(mutations.items.len);
        self.metrics.txns_ok.inc();
        self.metrics.rows_affected.add(rows);
        return .{ .ok = .{ .rows_affected = rows } };
    }

    fn run_collect(self: *Executor, entry: LogEntry, mut_buf: *std.ArrayList(Mutation)) !CollectOutcome {
        if (entry.header.kind != .txn_intent) {
            if (entry.header.kind == .snapshot_marker) {
                if (validate_snapshot_entry(entry, self.alloc)) |ms| {
                    if (self.log) |l| l.notify_snapshot(ms);
                } else |_| {}
            }
            self.metrics.noops_processed.inc();
            return .noop;
        }

        var validated = validate_txn_entry(entry, self.alloc) catch {
            self.metrics.txns_aborted.inc();
            return .aborted;
        };
        defer validated.decoded.deinit(self.alloc);

        const start = mut_buf.items.len;
        var committed = false;
        defer {
            if (!committed) {
                for (mut_buf.items[start..]) |m| {
                    self.alloc.free(m.key);
                    if (m.value) |v| self.alloc.free(v);
                }
                mut_buf.shrinkRetainingCapacity(start);
            }
        }

        const decoded = validated.decoded;
        for (decoded.ops) |op| {
            switch (op) {
                .set => |s| {
                    if (s.expected_seq > 0) {
                        const current = try self.storage.get(self.namespace_id, s.key, entry.header.seq - 1);
                        defer if (current) |row| row.deinit(self.alloc);
                        if (current == null or current.?.seq != s.expected_seq) {
                            self.metrics.txns_aborted.inc();
                            return .aborted;
                        }
                    }
                },
                .delete => {},
            }
        }

        for (decoded.ops) |op| {
            switch (op) {
                .set => |s| {
                    const key_copy = try self.alloc.dupe(u8, s.key);
                    errdefer self.alloc.free(key_copy);
                    const val = try self.alloc.dupe(u8, s.value);
                    errdefer self.alloc.free(val);
                    try self.appendTxnMutation(mut_buf, start, .{ .kind = .update, .namespace_id = self.namespace_id, .key = key_copy, .value = val });
                },
                .delete => |d| {
                    const key_copy = try self.alloc.dupe(u8, d.key);
                    errdefer self.alloc.free(key_copy);
                    try self.appendTxnMutation(mut_buf, start, .{ .kind = .delete, .namespace_id = self.namespace_id, .key = key_copy, .value = null });
                },
            }
        }

        self.metrics.txns_ok.inc();
        self.metrics.rows_affected.add(@intCast(mut_buf.items.len - start));
        committed = true;
        return .committed;
    }

    fn appendTxnMutation(
        self: *Executor,
        mutations: *std.ArrayList(Mutation),
        start: usize,
        mutation: Mutation,
    ) !void {
        var i = start;
        while (i < mutations.items.len) {
            if (mutations.items[i].namespace_id == mutation.namespace_id and
                std.mem.eql(u8, mutations.items[i].key, mutation.key))
            {
                const old = mutations.orderedRemove(i);
                self.alloc.free(old.key);
                if (old.value) |v| self.alloc.free(v);
                continue;
            }
            i += 1;
        }
        try mutations.append(self.alloc, mutation);
    }
};

const CollectOutcome = enum { committed, aborted, noop };

/// Drains committed log entries into an Executor.
pub const ExecutorDriver = struct {
    log: *Log,
    executor: *Executor,
    alloc: std.mem.Allocator,

    pub fn drain_once(self: *ExecutorDriver) !usize {
        const from_seq = self.executor.committed_seq + 1;
        assert(from_seq > 0);
        const entries = try self.log.read(from_seq, 256, self.alloc);
        defer {
            for (entries) |*e| e.deinit(self.alloc);
            self.alloc.free(entries);
        }
        if (entries.len == 0) return 0;

        var mut_buf: std.ArrayList(Mutation) = .empty;
        defer {
            for (mut_buf.items) |m| {
                self.alloc.free(m.key);
                if (m.value) |v| self.alloc.free(v);
            }
            mut_buf.deinit(self.alloc);
        }

        const PendingBatch = struct { start: usize, end: usize, seq: Seq };
        var pending: std.ArrayList(PendingBatch) = .empty;
        defer pending.deinit(self.alloc);

        for (entries) |entry| {
            const start = mut_buf.items.len;
            const outcome = try self.executor.run_collect(entry, &mut_buf);
            if (outcome == .committed) {
                try pending.append(self.alloc, .{ .start = start, .end = mut_buf.items.len, .seq = entry.header.seq });
            }
        }

        if (pending.items.len > 0) {
            const apply_batch = try self.alloc.alloc(storage_mod.ApplyBatch, pending.items.len);
            defer self.alloc.free(apply_batch);
            for (pending.items, 0..) |p, i| {
                apply_batch[i] = .{ .mutations = mut_buf.items[p.start..p.end], .seq = p.seq };
            }
            try self.executor.storage.apply_sequenced(apply_batch);
        }

        self.executor.committed_seq = entries[entries.len - 1].header.seq;
        self.executor.metrics.current_seq.set(@intCast(self.executor.committed_seq));
        return entries.len;
    }

    pub fn drain_all(self: *ExecutorDriver) !void {
        for (0..drain_iterations_max) |_| {
            const n = try self.drain_once();
            if (n == 0) return;
        }
        return error.TooManyDrainIterations;
    }
};
