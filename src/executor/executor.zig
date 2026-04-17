/// Fold Executor: consumes committed LogEntries, applies mutations to Storage deterministically.
const std = @import("std");
const types_mod   = @import("types.zig");
const registry_mod = @import("registry.zig");
const log_mod     = @import("log.zig");
const storage_mod = @import("storage.zig");

pub const QueryHash        = types_mod.QueryHash;
pub const ResolvedValue    = types_mod.ResolvedValue;
pub const ResolvedKind     = types_mod.ResolvedKind;
pub const AbortCode        = types_mod.AbortCode;
pub const ExecResult       = types_mod.ExecResult;
pub const TxnIntentDecoded = types_mod.TxnIntentDecoded;
pub const TxnIntentHeader  = types_mod.TxnIntentHeader;
pub const serializeTxnIntent   = types_mod.serializeTxnIntent;
pub const deserializeTxnIntent = types_mod.deserializeTxnIntent;

pub const QueryContext   = registry_mod.QueryContext;
pub const QueryHandler   = registry_mod.QueryHandler;
pub const QueryRegistry  = registry_mod.QueryRegistry;

pub const LogEntry  = log_mod.LogEntry;
pub const EntryKind = log_mod.EntryKind;

pub const Storage  = storage_mod.Storage;
pub const Mutation = storage_mod.Mutation;
pub const Seq      = types_mod.Seq;

pub const ExecutorError = error{
    ConstraintViolation,
};

pub const Executor = struct {
    storage:       *Storage,
    registry:      QueryRegistry,
    committed_seq: Seq,
    alloc:         std.mem.Allocator,

    pub fn init(storage: *Storage, alloc: std.mem.Allocator) Executor {
        return .{
            .storage       = storage,
            .registry      = QueryRegistry.init(alloc),
            .committed_seq = 0,
            .alloc         = alloc,
        };
    }

    pub fn deinit(self: *Executor) void {
        self.registry.deinit();
    }

    pub fn register(self: *Executor, hash: [32]u8, handler: QueryHandler) !void {
        try self.registry.register(hash, handler);
    }

    pub fn currentSeq(self: *const Executor) Seq {
        return self.committed_seq;
    }

    pub fn run(self: *Executor, entry: LogEntry) !ExecResult {
        defer self.committed_seq = entry.header.seq;

        // Non-txn entries advance seq with no side effects.
        if (entry.header.kind != .txn_intent) {
            return .{ .ok = .{ .rows_affected = 0 } };
        }

        if (!entry.verifyCrc()) {
            return .{ .abort = .{ .code = .bad_params, .detail = "crc mismatch" } };
        }

        var decoded = deserializeTxnIntent(entry.payload, self.alloc) catch {
            return .{ .abort = .{ .code = .bad_params, .detail = "invalid payload" } };
        };
        defer decoded.deinit();

        const handler = self.registry.lookup(decoded.query_hash.*) orelse {
            return .{ .abort = .{ .code = .missing_query, .detail = "unknown query hash" } };
        };

        const ctx = QueryContext{
            .params   = decoded.params,
            .resolved = decoded.nondet,
            .seq      = entry.header.seq,
            .alloc    = self.alloc,
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
                return .{ .abort = .{ .code = .constraint_violation, .detail = "constraint failed" } };
            }
            return err;
        };

        try self.storage.apply(mutations.items, entry.header.seq);

        const rows: u64 = @intCast(mutations.items.len);
        return .{ .ok = .{ .rows_affected = rows } };
    }
};
