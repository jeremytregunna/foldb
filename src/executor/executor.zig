/// Fold Executor: consumes committed LogEntries, applies mutations to Storage deterministically.
const std = @import("std");
const types_mod = @import("types.zig");
const registry_mod = @import("registry.zig");
const log_mod = @import("log.zig");
const storage_mod = @import("storage.zig");
const exchange_mod = @import("exchange.zig");
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
pub const serializeTxnIntent = types_mod.serializeTxnIntent;
pub const deserializeTxnIntent = types_mod.deserializeTxnIntent;
pub const PartitionId = types_mod.PartitionId;

pub const QueryContext = registry_mod.QueryContext;
pub const QueryHandler = registry_mod.QueryHandler;
pub const CrossPartitionQueryHandler = registry_mod.CrossPartitionQueryHandler;
pub const RegisteredHandler = registry_mod.RegisteredHandler;
pub const QueryRegistry = registry_mod.QueryRegistry;
pub const ForeignReadRequest = exchange_mod.ForeignReadRequest;
pub const ForeignRow = exchange_mod.ForeignRow;

pub const LogEntry = log_mod.LogEntry;
pub const EntryKind = log_mod.EntryKind;

pub const Storage = storage_mod.Storage;
pub const Mutation = storage_mod.Mutation;
pub const ColumnValue = storage_mod.ColumnValue;
pub const Row = storage_mod.Row;
pub const Seq = types_mod.Seq;

pub const ExecutorError = error{
    ConstraintViolation,
};

/// Domain boundary — CRC-verifies and decodes a txn_intent LogEntry.
/// Returns error for corrupt or malformed entries; never returns partial state.
/// Call this before handing the entry to the Executor core.
pub fn validateTxnEntry(entry: LogEntry, alloc: std.mem.Allocator) !ValidatedTxnEntry {
    std.debug.assert(entry.header.kind == .txn_intent);
    if (!entry.verifyCrc()) return error.CrcMismatch;
    const decoded = try deserializeTxnIntent(entry.payload, alloc);
    return .{ .seq = entry.header.seq, .epoch = entry.header.epoch, .decoded = decoded };
}

/// Domain boundary — decodes a snapshot_marker LogEntry payload.
/// Returns only the inner marker sequence — the only field the core uses.
/// Returns error if the payload is malformed.
fn validateSnapshotEntry(entry: LogEntry, alloc: std.mem.Allocator) !Seq {
    std.debug.assert(entry.header.kind == .snapshot_marker);
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
    pub fn withLog(self: *Executor, l: *Log) void {
        self.log = l;
    }

    /// Wire a CDC manager to receive change events from each committed transaction.
    pub fn withCdc(self: *Executor, manager: *CdcManager) void {
        self.cdc = manager;
    }

    pub fn deinit(self: *Executor) void {
        self.registry.deinit();
    }

    pub fn register(self: *Executor, hash: [32]u8, handler: QueryHandler) !void {
        try self.registry.register(hash, handler);
    }

    pub fn registerCross(self: *Executor, hash: [32]u8, handler: CrossPartitionQueryHandler) !void {
        try self.registry.registerCross(hash, handler);
    }

    pub fn currentSeq(self: *const Executor) Seq {
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
                if (validateSnapshotEntry(entry, self.alloc)) |marker_seq| {
                    if (self.log) |l| l.notifySnapshot(marker_seq);
                } else |_| {}
            }
            self.metrics.noops_processed.inc();
            return .{ .ok = .{ .rows_affected = 0 } };
        }

        // This is the domain boundary — all data past this point is validated.
        var validated = validateTxnEntry(entry, self.alloc) catch |e| {
            self.metrics.txns_aborted.inc();
            return switch (e) {
                error.CrcMismatch => .{ .abort = .{ .code = .bad_params, .detail = "crc mismatch" } },
                else => .{ .abort = .{ .code = .bad_params, .detail = "invalid payload" } },
            };
        };
        defer validated.decoded.deinit();

        return self.runValidated(validated);
    }

    fn runValidated(self: *Executor, entry: ValidatedTxnEntry) !ExecResult {
        const decoded = entry.decoded;

        const registered = self.registry.lookup(decoded.query_hash.*) orelse {
            self.metrics.txns_missing_query.inc();
            return .{ .abort = .{ .code = .missing_query, .detail = "unknown query hash" } };
        };

        // Single-partition handlers only. Cross-partition txns must go through PartitionSet.
        const handler = switch (registered) {
            .single => |h| h,
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
            for (mutations.items) |m| {
                self.alloc.free(m.key);
                if (m.values) |vs| {
                    for (vs) |v| v.freeIfOwned(self.alloc);
                    self.alloc.free(vs);
                }
            }
            mutations.deinit(self.alloc);
        }

        handler(ctx, self.storage, &mutations) catch |err| {
            if (err == error.ConstraintViolation) {
                self.metrics.txns_aborted.inc();
                return .{ .abort = .{ .code = .constraint_violation, .detail = "constraint failed" } };
            }
            return err;
        };

        // CDC: capture before-images before mutations are applied to storage.
        var before_images: ?cdc_mod.BeforeImages = null;
        defer if (before_images) |*bi| bi.deinit();
        if (self.cdc) |mgr| {
            const pre_seq: Seq = if (entry.seq > 0) entry.seq - 1 else 0;
            before_images = try mgr.captureBeforeImages(mutations.items, self.storage, pre_seq, self.alloc);
        }

        try self.storage.apply(mutations.items, entry.seq);

        // CDC: dispatch events after successful apply.
        if (self.cdc) |mgr| {
            if (before_images) |bi| {
                try mgr.dispatch(entry.seq, entry.epoch, .txn_intent, mutations.items, bi, self.alloc);
            }
        }

        const rows: u64 = @intCast(mutations.items.len);
        self.metrics.txns_ok.inc();
        self.metrics.rows_affected.add(rows);
        return .{ .ok = .{ .rows_affected = rows } };
    }
};

/// Drains committed log entries into an Executor. Decouples the log from the executor
/// so the executor only processes what's been committed rather than polling blindly.
pub const ExecutorDriver = struct {
    log: *Log,
    executor: *Executor,
    alloc: std.mem.Allocator,

    /// Process up to 256 log entries starting at executor.committed_seq+1.
    /// Returns the number of entries processed.
    pub fn drainOnce(self: *ExecutorDriver) !usize {
        const from_seq = self.executor.committed_seq + 1;
        const entries = try self.log.read(from_seq, 256, self.alloc);
        defer {
            for (entries) |*e| e.deinit(self.alloc);
            self.alloc.free(entries);
        }
        for (entries) |entry| {
            _ = try self.executor.run(entry);
        }
        return entries.len;
    }

    /// Drain until the log head is reached (no new entries). Used in tests and
    /// single-threaded operation.
    pub fn drainAll(self: *ExecutorDriver) !void {
        while (true) {
            const n = try self.drainOnce();
            if (n == 0) break;
        }
    }
};
