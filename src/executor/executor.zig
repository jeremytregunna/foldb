/// Fold Executor: consumes committed LogEntries, applies mutations to Storage deterministically.
const std = @import("std");
const assert = std.debug.assert;
const types_mod = @import("types.zig");
const registry_mod = @import("registry.zig");
const log_mod = @import("log.zig");
const storage_mod = @import("storage.zig");
const determinism_mod = @import("determinism.zig");
const cdc_mod = @import("cdc.zig");
const obs = @import("observability.zig");

// Verify determinism invariants at compile time.
comptime {
    determinism_mod.verifyExecutorModule();
}

pub const QueryHash = types_mod.QueryHash;
pub const ResolvedValue = types_mod.ResolvedValue;
pub const ResolvedKind = types_mod.ResolvedKind;
pub const AbortCode = types_mod.AbortCode;
pub const ExecResult = types_mod.ExecResult;
pub const TxnIntentDecoded = types_mod.TxnIntentDecoded;
pub const ValidatedTxnEntry = types_mod.ValidatedTxnEntry;
pub const TxnIntentHeader = types_mod.TxnIntentHeader;
pub const serialize_txn_intent = types_mod.serialize_txn_intent;
pub const deserialize_txn_intent = types_mod.deserialize_txn_intent;
pub const PartitionId = types_mod.PartitionId;

pub const QueryContext = registry_mod.QueryContext;
pub const QueryHandler = registry_mod.QueryHandler;
pub const CrossPartitionQueryHandler = registry_mod.CrossPartitionQueryHandler;
pub const RegisteredHandler = registry_mod.RegisteredHandler;
pub const QueryRegistry = registry_mod.QueryRegistry;
pub const ForeignRead = types_mod.ForeignRead;
pub const FetchedRow = types_mod.FetchedRow;

pub const LogEntry = log_mod.LogEntry;
pub const EntryKind = log_mod.EntryKind;

pub const Storage = storage_mod.Storage;
pub const ReadTracker = storage_mod.ReadTracker;
pub const Mutation = storage_mod.Mutation;
pub const ColumnValue = storage_mod.ColumnValue;
pub const Row = storage_mod.Row;
pub const Seq = types_mod.Seq;

pub const ExecutorError = error{
    ConstraintViolation,
};

/// Maximum drain iterations before treating the log as broken.
const drain_iterations_max: u32 = 1 << 20;

/// Domain boundary — CRC-verifies and decodes a txn_intent LogEntry.
/// Returns error for corrupt or malformed entries; never returns partial state.
/// Call this before handing the entry to the Executor core.
pub fn validate_txn_entry(entry: LogEntry, alloc: std.mem.Allocator) !ValidatedTxnEntry {
    assert(entry.header.kind == .txn_intent);
    if (!entry.verify_crc()) return error.CrcMismatch;
    const decoded = try deserialize_txn_intent(entry.payload, alloc);
    assert(decoded.query_hash.len == 32);
    return .{ .seq = entry.header.seq, .epoch = entry.header.epoch, .decoded = decoded };
}

/// Domain boundary — decodes a snapshot_marker LogEntry payload.
/// Returns only the inner marker sequence — the only field the core uses.
/// Returns error if the payload is malformed.
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

// Note: PartitionSet is in partition_set.zig (separate module to avoid circular imports).
// Import it via build.zig's partition_set_module, not through executor.zig.

pub const Log = log_mod.Log;
pub const LogMux = log_mod.LogMux;
pub const CdcManager = cdc_mod.CdcManager;
pub const CdcSubscription = cdc_mod.CdcSubscription;
pub const CdcEvent = cdc_mod.CdcEvent;
pub const CdcEffect = cdc_mod.CdcEffect;
pub const CdcOperation = cdc_mod.CdcOperation;
pub const BeforeImages = cdc_mod.BeforeImages;

pub const Executor = struct {
    storage: *Storage,
    registry: QueryRegistry,
    committed_seq: Seq,
    alloc: std.mem.Allocator,
    /// Number of storage partitions; used to validate write_set_hint against actual mutations.
    /// Must match the sequencer's partition_count. Defaults to 1 (single-partition).
    partition_count: PartitionId = 1,
    /// Optional log reference for notifying snapshot advancement.
    log: ?*Log = null,
    /// Optional CDC manager for change-data-capture event dispatch.
    cdc: ?*CdcManager = null,
    metrics: obs.ExecutorMetrics = .{},

    pub fn init(storage: *Storage, alloc: std.mem.Allocator) Executor {
        return .{
            .storage = storage,
            .registry = QueryRegistry.init(alloc),
            .committed_seq = 0,
            .alloc = alloc,
        };
    }

    /// Wire a log for snapshot_marker notification.
    pub fn with_log(self: *Executor, log: *Log) void {
        self.log = log;
    }

    /// Wire a CDC manager to receive change events from each committed transaction.
    pub fn with_cdc(self: *Executor, manager: *CdcManager) void {
        self.cdc = manager;
    }

    pub fn deinit(self: *Executor) void {
        self.registry.deinit();
    }

    pub fn register(self: *Executor, hash: [32]u8, handler: QueryHandler) !void {
        try self.registry.register(hash, handler);
    }

    pub fn register_cross(self: *Executor, hash: [32]u8, handler: CrossPartitionQueryHandler) !void {
        try self.registry.register_cross(hash, handler);
    }

    pub fn current_seq(self: *const Executor) Seq {
        return self.committed_seq;
    }

    pub fn run(self: *Executor, entry: LogEntry) !ExecResult {
        defer {
            self.committed_seq = entry.header.seq;
            self.metrics.current_seq.set(@intCast(entry.header.seq));
        }

        // Non-txn entries advance seq; snapshot_marker additionally notifies the log.
        if (entry.header.kind != .txn_intent) {
            if (entry.header.kind == .snapshot_marker) {
                // Domain boundary — decode snapshot marker; skip notification if payload is malformed.
                if (validate_snapshot_entry(entry, self.alloc)) |marker_seq| {
                    if (self.log) |l| l.notify_snapshot(marker_seq);
                } else |_| {}
            }
            self.metrics.noops_processed.inc();
            return .{ .ok = .{ .rows_affected = 0 } };
        }

        // This is the domain boundary — all data past this point is validated.
        var validated = validate_txn_entry(entry, self.alloc) catch |e| {
            self.metrics.txns_aborted.inc();
            return switch (e) {
                error.CrcMismatch => .{ .abort = .{ .code = .bad_params, .detail = "crc mismatch" } },
                else => .{ .abort = .{ .code = .bad_params, .detail = "invalid payload" } },
            };
        };
        defer validated.decoded.deinit();

        return self.run_validated(validated);
    }

    pub fn run_validated(self: *Executor, entry: ValidatedTxnEntry) !ExecResult {
        assert(entry.seq > 0);
        const decoded = entry.decoded;

        const registered = self.registry.lookup(decoded.query_hash.*) orelse {
            self.metrics.txns_missing_query.inc();
            return .{ .abort = .{ .code = .missing_query, .detail = "unknown query hash" } };
        };

        // Single-partition handlers only. Cross-partition txns must go through PartitionSet.
        const handler = switch (registered) {
            .single => |single_handler| single_handler,
            .cross => return .{ .abort = .{ .code = .missing_query, .detail = "cross-partition txn requires PartitionSet" } },
        };

        const ctx = QueryContext{
            .params = decoded.params,
            .resolved = decoded.nondet,
            .seq = entry.seq,
            .alloc = self.alloc,
        };

        var mutations: std.ArrayList(Mutation) = .empty;
        defer {
            for (mutations.items) |mutation| {
                self.alloc.free(mutation.key);
                if (mutation.values) |values| {
                    for (values) |value| value.freeIfOwned(self.alloc);
                    self.alloc.free(values);
                }
            }
            mutations.deinit(self.alloc);
        }

        // Activate read tracking when recon_seq is set — enables OCC conflict detection.
        var read_tracker: ?storage_mod.ReadTracker = if (decoded.recon_seq > 0)
            storage_mod.ReadTracker.init(self.alloc)
        else
            null;
        defer if (read_tracker) |*tracker| tracker.deinit();
        if (read_tracker != null) self.storage.read_tracker = &read_tracker.?;

        assert(mutations.items.len == 0);
        handler(ctx, self.storage, &mutations) catch |err| {
            self.storage.read_tracker = null;
            if (err == error.ConstraintViolation) {
                self.metrics.txns_aborted.inc();
                return .{ .abort = .{ .code = .constraint_violation, .detail = "constraint failed" } };
            }
            return err;
        };
        self.storage.read_tracker = null;

        // OCC: if any read key was written after recon_seq, the gateway's hints are stale.
        if (read_tracker) |*tracker| {
            assert(decoded.recon_seq > 0);
            if (read_write_conflict(tracker, decoded.recon_seq)) {
                self.metrics.txns_aborted.inc();
                return .{ .abort = .{ .code = .retry, .detail = "read-write conflict" } };
            }
        }

        try self.run_validated_apply(entry, mutations.items);

        const rows: u64 = @intCast(mutations.items.len);
        assert(rows == @as(u64, mutations.items.len));
        self.metrics.txns_ok.inc();
        self.metrics.rows_affected.add(rows);
        return .{ .ok = .{ .rows_affected = rows } };
    }

    fn run_validated_apply(
        self: *Executor,
        entry: ValidatedTxnEntry,
        mutations: []const Mutation,
    ) !void {
        var before_images: ?cdc_mod.BeforeImages = null;
        defer if (before_images) |*before_img| before_img.deinit();
        if (self.cdc) |mgr| {
            const pre_seq: Seq = if (entry.seq > 0) entry.seq - 1 else 0;
            before_images = try mgr.capture_before_images(mutations, self.storage, pre_seq, self.alloc);
        }
        try self.storage.apply(mutations, entry.seq);
        if (self.cdc) |mgr| {
            if (before_images) |before_img| {
                try mgr.dispatch(entry.seq, entry.epoch, .txn_intent, mutations, before_img, self.alloc);
            }
        }
    }
};

/// Returns true if any tracked read has a row_seq newer than recon_seq, meaning
/// the key was written after reconnaissance — the gateway's hints are stale.
fn read_write_conflict(tracker: *const storage_mod.ReadTracker, recon_seq: Seq) bool {
    assert(recon_seq > 0);
    for (tracker.reads.items) |r| {
        if (r.row_seq > recon_seq) return true;
    }
    return false;
}

/// Drains committed log entries into an Executor. Decouples the log from the executor
/// so the executor only processes what's been committed rather than polling blindly.
pub const ExecutorDriver = struct {
    log: *Log,
    executor: *Executor,
    alloc: std.mem.Allocator,

    /// Process up to 256 log entries starting at executor.committed_seq+1.
    /// Returns the number of entries processed.
    pub fn drain_once(self: *ExecutorDriver) !usize {
        const from_seq = self.executor.committed_seq + 1;
        assert(from_seq > 0);
        const entries = try self.log.read(from_seq, 256, self.alloc);
        defer {
            for (entries) |*entry| entry.deinit(self.alloc);
            self.alloc.free(entries);
        }
        for (entries) |entry| {
            _ = try self.executor.run(entry);
        }
        return entries.len;
    }

    /// Drain until the log head is reached (no new entries). Used in tests and
    /// single-threaded operation.
    pub fn drain_all(self: *ExecutorDriver) !void {
        for (0..drain_iterations_max) |_| {
            const entries_count = try self.drain_once();
            if (entries_count == 0) return;
        }
        return error.TooManyDrainIterations;
    }
};
