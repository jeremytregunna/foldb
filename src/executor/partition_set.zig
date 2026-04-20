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
const deserializeTxnIntent = executor_mod.deserializeTxnIntent;
const TxnIntentDecoded = executor_mod.TxnIntentDecoded;

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
        const execs = try alloc.alloc(Executor, storages.len);
        errdefer alloc.free(execs);
        const pc: PartitionId = @intCast(storages.len);
        for (storages, 0..) |s, i| {
            execs[i] = Executor.init(s, alloc);
            execs[i].partition_count = pc;
        }
        return .{ .executors = execs, .alloc = alloc };
    }

    pub fn deinit(self: *PartitionSet) void {
        for (self.executors) |*e| e.deinit();
        self.alloc.free(self.executors);
    }

    /// Wire a CDC manager on all partition executors.
    pub fn withCdc(self: *PartitionSet, manager: *executor_mod.CdcManager) void {
        for (self.executors) |*e| e.withCdc(manager);
    }

    /// Register a single-partition handler on all partitions.
    pub fn registerAll(self: *PartitionSet, hash: [32]u8, handler: executor_mod.QueryHandler) !void {
        for (self.executors) |*e| try e.register(hash, handler);
    }

    /// Register a cross-partition handler on all partitions.
    pub fn registerCrossAll(self: *PartitionSet, hash: [32]u8, handler: executor_mod.CrossPartitionQueryHandler) !void {
        for (self.executors) |*e| try e.registerCross(hash, handler);
    }

    /// Process a log entry. Returns one result per written partition.
    /// Caller owns the returned slice; free with `alloc.free(results)`.
    pub fn runEntry(self: *PartitionSet, entry: LogEntry) ![]PartitionExecResult {
        if (entry.header.kind != .txn_intent) {
            // Non-txn entries advance seq on all executors with no side effects.
            for (self.executors) |*e| e.committed_seq = entry.header.seq;
            const results = try self.alloc.alloc(PartitionExecResult, self.executors.len);
            for (0..self.executors.len) |i| {
                results[i] = .{
                    .partition = @intCast(i),
                    .result = .{ .ok = .{ .rows_affected = 0 } },
                };
            }
            return results;
        }

        if (!entry.verifyCrc()) {
            return self.singleAbort(0, .bad_params, "crc mismatch");
        }

        var decoded = deserializeTxnIntent(entry.payload, self.alloc) catch {
            return self.singleAbort(0, .bad_params, "invalid payload");
        };
        defer decoded.deinit();

        // Single-partition fast path: delegate unchanged to the responsible executor.
        if (decoded.write_set_hint.len <= 1) {
            const p: usize = if (decoded.write_set_hint.len == 1) @intCast(decoded.write_set_hint[0]) else 0;
            if (p >= self.executors.len) {
                return self.singleAbort(@intCast(p), .bad_params, "partition out of range");
            }
            const result = try self.executors[p].run(entry);
            const results = try self.alloc.alloc(PartitionExecResult, 1);
            results[0] = .{ .partition = @intCast(p), .result = result };
            return results;
        }

        return self.runCrossPartition(entry, &decoded);
    }

    fn runCrossPartition(self: *PartitionSet, entry: LogEntry, decoded: *const TxnIntentDecoded) ![]PartitionExecResult {
        const partitions = decoded.write_set_hint;
        const seq = entry.header.seq;
        const alloc = self.alloc;

        const ctx = QueryContext{
            .params = decoded.params,
            .resolved = decoded.nondet,
            .seq = seq,
            .alloc = alloc,
        };

        // --- Phase A: each partition declares which foreign rows it needs at seq-1 ---
        var all_requests: std.ArrayList(ForeignReadRequest) = .empty;
        defer {
            for (all_requests.items) |req| alloc.free(req.key);
            all_requests.deinit(alloc);
        }

        for (partitions) |p| {
            const pi: usize = @intCast(p);
            if (pi >= self.executors.len) {
                return self.abortPartitions(partitions, .bad_params, "partition out of range");
            }
            const registered = self.executors[pi].registry.lookup(decoded.query_hash.*) orelse {
                return self.abortPartitions(partitions, .missing_query, "unknown query hash");
            };
            switch (registered) {
                .cross => |h| try h.declareReads(ctx, p, &all_requests),
                .single => return self.abortPartitions(partitions, .missing_query, "single-partition handler on cross-partition txn"),
            }
        }

        // --- Phase B: fetch requested rows from their source partitions at seq-1 ---
        var foreign_rows: std.ArrayList(ForeignRow) = .empty;
        defer {
            for (foreign_rows.items) |*fr| {
                if (fr.row) |*r| r.deinit(alloc);
            }
            foreign_rows.deinit(alloc);
        }

        for (all_requests.items) |req| {
            const src: usize = @intCast(req.from_partition);
            if (src >= self.executors.len) continue;
            const read_seq: Seq = if (seq > 0) seq - 1 else 0;
            const row_opt = try self.executors[src].storage.get(req.table_id, req.key, read_seq);
            const storage_alloc = self.executors[src].storage.alloc;
            const cloned = if (row_opt) |r| blk: {
                var orig = r;
                defer orig.deinit(storage_alloc);
                break :blk try cloneRow(r, alloc);
            } else null;
            try foreign_rows.append(alloc, .{
                .from_partition = req.from_partition,
                .table_id = req.table_id,
                .key = req.key,
                .row = cloned,
            });
        }

        // --- Phase C: execute each partition's local slice, collecting mutations ---
        const mut_arrays = try alloc.alloc(std.ArrayList(Mutation), partitions.len);
        for (mut_arrays) |*m| m.* = .empty;
        defer {
            for (mut_arrays) |*m| {
                freeMutations(m.items, alloc);
                m.deinit(alloc);
            }
            alloc.free(mut_arrays);
        }

        var aborted = false;
        var abort_code: AbortCode = .constraint_violation;
        var abort_detail: []const u8 = "";

        for (partitions, 0..) |p, idx| {
            const pi: usize = @intCast(p);
            const handler = self.executors[pi].registry.lookup(decoded.query_hash.*).?.cross;

            handler.execute(ctx, p, self.executors[pi].storage, foreign_rows.items, &mut_arrays[idx]) catch |err| {
                if (err == error.ConstraintViolation) {
                    aborted = true;
                    abort_code = .constraint_violation;
                    abort_detail = "constraint failed";
                } else {
                    return err;
                }
            };

            if (aborted) break;
        }

        if (aborted) {
            return self.abortPartitions(partitions, abort_code, abort_detail);
        }

        // --- Phase D: apply mutations and emit CDC events per partition ---
        for (partitions, 0..) |p, idx| {
            const pi: usize = @intCast(p);
            const exec = &self.executors[pi];
            const mutations = mut_arrays[idx].items;

            var bi: ?executor_mod.BeforeImages = null;
            defer if (bi) |*b| b.deinit();
            if (exec.cdc) |mgr| {
                const pre_seq: Seq = if (seq > 0) seq - 1 else 0;
                bi = try mgr.captureBeforeImages(mutations, exec.storage, pre_seq, alloc);
            }

            try exec.storage.apply(mutations, seq);
            exec.committed_seq = seq;

            if (exec.cdc) |mgr| {
                if (bi) |b| {
                    try mgr.dispatch(seq, entry.header.epoch, entry.header.kind, mutations, b, alloc);
                }
            }
        }

        const results = try alloc.alloc(PartitionExecResult, partitions.len);
        for (partitions, 0..) |p, idx| {
            results[idx] = .{
                .partition = p,
                .result = .{ .ok = .{ .rows_affected = @intCast(mut_arrays[idx].items.len) } },
            };
        }
        return results;
    }

    fn singleAbort(self: *PartitionSet, partition: PartitionId, code: AbortCode, detail: []const u8) ![]PartitionExecResult {
        const results = try self.alloc.alloc(PartitionExecResult, 1);
        results[0] = .{ .partition = partition, .result = .{ .abort = .{ .code = code, .detail = detail } } };
        return results;
    }

    fn abortPartitions(self: *PartitionSet, partitions: []const PartitionId, code: AbortCode, detail: []const u8) ![]PartitionExecResult {
        const results = try self.alloc.alloc(PartitionExecResult, partitions.len);
        for (partitions, 0..) |p, i| {
            results[i] = .{ .partition = p, .result = .{ .abort = .{ .code = code, .detail = detail } } };
        }
        return results;
    }
};

/// Drains committed log entries into a PartitionSet. Feeds each entry to runEntry()
/// starting at the minimum committed_seq across all partitions.
pub const PartitionDriver = struct {
    log: *executor_mod.Log,
    partition_set: *PartitionSet,
    alloc: std.mem.Allocator,

    pub fn drainOnce(self: *PartitionDriver) !usize {
        // Drive from the minimum committed_seq across executors.
        var min_seq: Seq = std.math.maxInt(Seq);
        for (self.partition_set.executors) |e| {
            if (e.committed_seq < min_seq) min_seq = e.committed_seq;
        }
        const from_seq = min_seq + 1;
        const entries = try self.log.read(from_seq, 256, self.alloc);
        defer {
            for (entries) |*e| e.deinit(self.alloc);
            self.alloc.free(entries);
        }
        for (entries) |entry| {
            const results = try self.partition_set.runEntry(entry);
            self.alloc.free(results);
        }
        return entries.len;
    }

    pub fn drainAll(self: *PartitionDriver) !void {
        while (true) {
            const n = try self.drainOnce();
            if (n == 0) break;
        }
    }
};

fn freeMutations(items: []Mutation, alloc: std.mem.Allocator) void {
    for (items) |m| {
        alloc.free(m.key);
        if (m.values) |vs| {
            for (vs) |v| v.freeIfOwned(alloc);
            alloc.free(vs);
        }
    }
}

fn cloneRow(r: Row, alloc: std.mem.Allocator) !Row {
    const key = try alloc.dupe(u8, r.key);
    errdefer alloc.free(key);
    const vals = try alloc.alloc(ColumnValue, r.values.len);
    errdefer alloc.free(vals);
    for (r.values, 0..) |v, i| vals[i] = try v.dupe(alloc);
    return .{ .key = key, .seq = r.seq, .values = vals };
}
