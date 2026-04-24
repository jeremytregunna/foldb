/// PartitionSet: coordinates N Executor instances for cross-partition transactions.
///
/// For single-partition entries (write_set_hint.len <= 1), delegates directly to
/// the responsible Executor.run() — zero overhead over the single-partition path.
///
/// For cross-partition entries (write_set_hint.len > 1), implements the dataflow
/// protocol from spec §7.3:
///   Phase A — each partition declares which foreign rows it needs at seq-1
///   Phase B — fetch those rows from source partitions
///   Phase C — each partition executes its slice with local storage + foreign rows
///   Phase D — apply local mutations at seq (only if ALL partitions succeeded)
///
/// IMPORTANT: This file only imports named modules (executor.zig, storage.zig, log.zig).
/// It must NOT import relative files (types.zig, registry.zig, exchange.zig) since those
/// already belong to executor_module and Zig requires each file to belong to one module.
const std = @import("std");
const assert = std.debug.assert;
const executor_mod = @import("executor.zig");

// All types via the executor module (which re-exports from its sub-files).
const Executor = executor_mod.Executor;
const ExecResult = executor_mod.ExecResult;
const AbortCode = executor_mod.AbortCode;
const Storage = executor_mod.Storage;
const Mutation = executor_mod.Mutation;
const ColumnValue = executor_mod.ColumnValue;
const Row = executor_mod.Row;
const LogEntry = executor_mod.LogEntry;
const QueryContext = executor_mod.QueryContext;
const ForeignReadRequest = executor_mod.ForeignReadRequest;
const ForeignRow = executor_mod.ForeignRow;
const PartitionId = executor_mod.PartitionId;
const Seq = executor_mod.Seq;
const deserialize_txn_intent = executor_mod.deserialize_txn_intent;
const TxnIntentDecoded = executor_mod.TxnIntentDecoded;

/// Maximum drain iterations before treating the log as broken.
const drain_iterations_max: u32 = 1 << 20;

/// One result entry per written partition.
pub const PartitionExecResult = struct {
    partition: PartitionId,
    result: ExecResult,
};

pub const PartitionSet = struct {
    executors: []Executor,
    alloc: std.mem.Allocator,

    /// Initialize with pre-created Storage instances (index = partition id).
    /// Caller retains ownership of storages; they must outlive the PartitionSet.
    pub fn init(storages: []*Storage, alloc: std.mem.Allocator) !PartitionSet {
        assert(storages.len > 0);
        const execs = try alloc.alloc(Executor, storages.len);
        errdefer alloc.free(execs);
        const partition_count: PartitionId = @intCast(storages.len);
        for (storages, 0..) |storage, i| {
            execs[i] = Executor.init(storage, alloc);
            execs[i].partition_count = partition_count;
        }
        assert(execs.len == storages.len);
        return .{ .executors = execs, .alloc = alloc };
    }

    pub fn deinit(self: *PartitionSet) void {
        for (self.executors) |*executor| executor.deinit();
        self.alloc.free(self.executors);
    }

    /// Wire a CDC manager on all partition executors.
    pub fn with_cdc(self: *PartitionSet, manager: *executor_mod.CdcManager) void {
        for (self.executors) |*executor| executor.with_cdc(manager);
    }

    /// Register a single-partition handler on all partitions.
    pub fn register_all(self: *PartitionSet, hash: [32]u8, handler: executor_mod.QueryHandler) !void {
        for (self.executors) |*executor| try executor.register(hash, handler);
    }

    /// Register a cross-partition handler on all partitions.
    pub fn register_cross_all(self: *PartitionSet, hash: [32]u8, handler: executor_mod.CrossPartitionQueryHandler) !void {
        for (self.executors) |*executor| try executor.register_cross(hash, handler);
    }

    /// Process a log entry. Returns one result per written partition.
    /// Caller owns the returned slice; free with `alloc.free(results)`.
    pub fn run_entry(self: *PartitionSet, entry: LogEntry) ![]PartitionExecResult {
        assert(entry.header.seq > 0);
        if (entry.header.kind != .txn_intent) {
            // Non-txn entries advance seq on all executors with no side effects.
            for (self.executors) |*executor| executor.committed_seq = entry.header.seq;
            const results = try self.alloc.alloc(PartitionExecResult, self.executors.len);
            for (0..self.executors.len) |i| {
                results[i] = .{
                    .partition = @intCast(i),
                    .result = .{ .ok = .{ .rows_affected = 0 } },
                };
            }
            return results;
        }

        if (!entry.verify_crc()) {
            return self.single_abort(0, .bad_params, "crc mismatch");
        }

        var decoded = deserialize_txn_intent(entry.payload, self.alloc) catch {
            return self.single_abort(0, .bad_params, "invalid payload");
        };
        defer decoded.deinit();

        // Single-partition fast path: delegate unchanged to the responsible executor.
        if (decoded.write_set_hint.len <= 1) {
            const partition_index: usize = if (decoded.write_set_hint.len == 1) @intCast(decoded.write_set_hint[0]) else 0;
            if (partition_index >= self.executors.len) {
                return self.single_abort(@intCast(partition_index), .bad_params, "partition out of range");
            }
            const result = try self.executors[partition_index].run(entry);
            const results = try self.alloc.alloc(PartitionExecResult, 1);
            results[0] = .{ .partition = @intCast(partition_index), .result = result };
            return results;
        }

        return self.run_cross_partition(entry, &decoded);
    }

    fn run_cross_partition(self: *PartitionSet, entry: LogEntry, decoded: *const TxnIntentDecoded) ![]PartitionExecResult {
        const partitions = decoded.write_set_hint;
        assert(partitions.len > 1);
        const seq = entry.header.seq;
        assert(seq > 0);

        const ctx = QueryContext{
            .params = decoded.params,
            .resolved = decoded.nondet,
            .seq = seq,
            .alloc = self.alloc,
        };

        // Phase A: each partition declares which foreign rows it needs at seq-1.
        var all_requests: std.ArrayList(ForeignReadRequest) = .empty;
        defer {
            for (all_requests.items) |request| self.alloc.free(request.key);
            all_requests.deinit(self.alloc);
        }
        if (try self.run_cross_partition_declare(ctx, partitions, decoded, &all_requests)) |abort| return abort;

        // Phase B: fetch requested rows from their source partitions at seq-1.
        var foreign_rows: std.ArrayList(ForeignRow) = .empty;
        defer {
            for (foreign_rows.items) |*foreign_row| {
                if (foreign_row.row) |*row| row.deinit(self.alloc);
            }
            foreign_rows.deinit(self.alloc);
        }
        try self.run_cross_partition_fetch(seq, all_requests.items, &foreign_rows);

        // Phase C: execute each partition's local slice, collecting mutations.
        const mut_arrays = try self.alloc.alloc(std.ArrayList(Mutation), partitions.len);
        assert(mut_arrays.len == partitions.len);
        for (mut_arrays) |*mutation_list| mutation_list.* = .empty;
        defer {
            for (mut_arrays) |*mutation_list| {
                free_mutations(mutation_list.items, self.alloc);
                mutation_list.deinit(self.alloc);
            }
            self.alloc.free(mut_arrays);
        }
        if (try self.run_cross_partition_execute(ctx, partitions, decoded, foreign_rows.items, mut_arrays)) |abort| return abort;

        // Phase D: apply mutations and emit CDC events per partition.
        return self.run_cross_partition_apply(entry, partitions, mut_arrays);
    }

    fn run_cross_partition_declare(
        self: *PartitionSet,
        ctx: QueryContext,
        partitions: []const PartitionId,
        decoded: *const TxnIntentDecoded,
        out: *std.ArrayList(ForeignReadRequest),
    ) !?[]PartitionExecResult {
        assert(partitions.len > 1);
        for (partitions) |partition_id| {
            const partition_index: usize = @intCast(partition_id);
            if (partition_index >= self.executors.len) {
                return try self.abort_partitions(partitions, .bad_params, "partition out of range");
            }
            const registered = self.executors[partition_index].registry.lookup(decoded.query_hash.*) orelse {
                return try self.abort_partitions(partitions, .missing_query, "unknown query hash");
            };
            switch (registered) {
                .cross => |handler| try handler.declareReads(ctx, partition_id, out),
                .single => return try self.abort_partitions(partitions, .missing_query, "single-partition handler on cross-partition txn"),
            }
        }
        return null;
    }

    fn run_cross_partition_fetch(
        self: *PartitionSet,
        seq: Seq,
        requests: []const ForeignReadRequest,
        out: *std.ArrayList(ForeignRow),
    ) !void {
        const read_seq: Seq = if (seq > 0) seq - 1 else 0;
        for (requests) |request| {
            const source_index: usize = @intCast(request.from_partition);
            if (source_index >= self.executors.len) continue;
            const row_opt = try self.executors[source_index].storage.get(request.table_id, request.key, read_seq);
            const storage_alloc = self.executors[source_index].storage.alloc;
            const cloned = if (row_opt) |row| blk: {
                var original = row;
                defer original.deinit(storage_alloc);
                break :blk try clone_row(row, self.alloc);
            } else null;
            try out.append(self.alloc, .{
                .from_partition = request.from_partition,
                .table_id = request.table_id,
                .key = request.key,
                .row = cloned,
            });
        }
    }

    fn run_cross_partition_execute(
        self: *PartitionSet,
        ctx: QueryContext,
        partitions: []const PartitionId,
        decoded: *const TxnIntentDecoded,
        foreign_rows: []const ForeignRow,
        mut_arrays: []std.ArrayList(Mutation),
    ) !?[]PartitionExecResult {
        assert(partitions.len == mut_arrays.len);
        for (partitions, 0..) |partition_id, index| {
            const partition_index: usize = @intCast(partition_id);
            const registered_opt = self.executors[partition_index].registry.lookup(decoded.query_hash.*);
            assert(registered_opt != null); // Phase A verified handler existence.
            const handler = registered_opt.?.cross;
            handler.execute(ctx, partition_id, self.executors[partition_index].storage, foreign_rows, &mut_arrays[index]) catch |err| {
                if (err == error.ConstraintViolation) {
                    return try self.abort_partitions(partitions, .constraint_violation, "constraint failed");
                }
                return err;
            };
        }
        return null;
    }

    fn run_cross_partition_apply(
        self: *PartitionSet,
        entry: LogEntry,
        partitions: []const PartitionId,
        mut_arrays: []std.ArrayList(Mutation),
    ) ![]PartitionExecResult {
        assert(partitions.len == mut_arrays.len);
        const seq = entry.header.seq;
        for (partitions, 0..) |partition_id, index| {
            const partition_index: usize = @intCast(partition_id);
            const executor = &self.executors[partition_index];
            const mutations = mut_arrays[index].items;

            var before_images: ?executor_mod.BeforeImages = null;
            defer if (before_images) |*before_img| before_img.deinit();
            if (executor.cdc) |mgr| {
                const pre_seq: Seq = if (seq > 0) seq - 1 else 0;
                before_images = try mgr.capture_before_images(mutations, executor.storage, pre_seq, self.alloc);
            }

            try executor.storage.apply(mutations, seq);
            executor.committed_seq = seq;

            if (executor.cdc) |mgr| {
                if (before_images) |before_img| {
                    try mgr.dispatch(seq, entry.header.epoch, entry.header.kind, mutations, before_img, self.alloc);
                }
            }
        }

        const results = try self.alloc.alloc(PartitionExecResult, partitions.len);
        for (partitions, 0..) |partition_id, index| {
            results[index] = .{
                .partition = partition_id,
                .result = .{ .ok = .{ .rows_affected = @intCast(mut_arrays[index].items.len) } },
            };
        }
        assert(results.len == partitions.len);
        return results;
    }

    fn single_abort(self: *PartitionSet, partition: PartitionId, code: AbortCode, detail: []const u8) ![]PartitionExecResult {
        const results = try self.alloc.alloc(PartitionExecResult, 1);
        results[0] = .{ .partition = partition, .result = .{ .abort = .{ .code = code, .detail = detail } } };
        return results;
    }

    fn abort_partitions(self: *PartitionSet, partitions: []const PartitionId, code: AbortCode, detail: []const u8) ![]PartitionExecResult {
        assert(partitions.len > 0);
        const results = try self.alloc.alloc(PartitionExecResult, partitions.len);
        for (partitions, 0..) |partition_id, i| {
            results[i] = .{ .partition = partition_id, .result = .{ .abort = .{ .code = code, .detail = detail } } };
        }
        return results;
    }
};

/// Drains committed log entries into a PartitionSet. Feeds each entry to run_entry()
/// starting at the minimum committed_seq across all partitions.
pub const PartitionDriver = struct {
    log: *executor_mod.Log,
    partition_set: *PartitionSet,
    alloc: std.mem.Allocator,

    pub fn drain_once(self: *PartitionDriver) !usize {
        // Drive from the minimum committed_seq across executors.
        var min_seq: Seq = std.math.maxInt(Seq);
        for (self.partition_set.executors) |executor| {
            if (executor.committed_seq < min_seq) min_seq = executor.committed_seq;
        }
        const from_seq = min_seq + 1;
        assert(from_seq > 0);
        const entries = try self.log.read(from_seq, 256, self.alloc);
        defer {
            for (entries) |*entry| entry.deinit(self.alloc);
            self.alloc.free(entries);
        }
        for (entries) |entry| {
            const results = try self.partition_set.run_entry(entry);
            self.alloc.free(results);
        }
        return entries.len;
    }

    pub fn drain_all(self: *PartitionDriver) !void {
        for (0..drain_iterations_max) |_| {
            const entries_count = try self.drain_once();
            if (entries_count == 0) return;
        }
        return error.TooManyDrainIterations;
    }
};

fn free_mutations(items: []Mutation, alloc: std.mem.Allocator) void {
    for (items) |mutation| {
        alloc.free(mutation.key);
        if (mutation.values) |values| {
            for (values) |value| value.freeIfOwned(alloc);
            alloc.free(values);
        }
    }
}

fn clone_row(row: Row, alloc: std.mem.Allocator) !Row {
    assert(row.key.len > 0);
    const key = try alloc.dupe(u8, row.key);
    errdefer alloc.free(key);
    assert(key.len == row.key.len);
    const values = try alloc.alloc(ColumnValue, row.values.len);
    errdefer alloc.free(values);
    for (row.values, 0..) |value, i| values[i] = try value.dupe(alloc);
    return .{ .key = key, .seq = row.seq, .values = values };
}
