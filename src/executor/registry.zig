/// Query registry: maps QueryHash → RegisteredHandler (single or cross-partition).
const std = @import("std");
const types = @import("types.zig");
const storage_mod = @import("storage.zig");
const exchange = @import("exchange.zig");

pub const QueryHash = types.QueryHash;
pub const ResolvedValue = types.ResolvedValue;
pub const Seq = types.Seq;
pub const PartitionId = types.PartitionId;
pub const Storage = storage_mod.Storage;
pub const Mutation = storage_mod.Mutation;
pub const ForeignReadRequest = exchange.ForeignReadRequest;
pub const ForeignRow = exchange.ForeignRow;

pub const QueryContext = struct {
    params: []const u8,
    resolved: []const ResolvedValue,
    seq: Seq,
    alloc: std.mem.Allocator,
};

/// Single-partition query handler. Must be deterministic: no clock reads, no RNG,
/// no hash-map iteration order dependence. All nondeterminism arrives via ctx.resolved.
/// Return error.ConstraintViolation to abort the transaction without applying mutations.
pub const QueryHandler = *const fn (
    ctx: QueryContext,
    storage: *Storage,
    mutations: *std.ArrayList(Mutation),
) anyerror!void;

/// Cross-partition query handler. Used when a TxnIntent's write_set_hint spans
/// multiple partitions. Each partition's executor calls declareReads then execute.
///
/// Determinism contract (same as QueryHandler):
///   - No std.time.* (use ctx.seq as logical time)
///   - No RNG (use ctx.resolved[i])
///   - No hash-map iteration order dependence
///   - No float comparisons for ordering
pub const CrossPartitionQueryHandler = struct {
    /// Declare which rows are needed from other partitions at seq-1.
    /// Called once per involved partition before any execution begins.
    /// Append ForeignReadRequest items to `out` for each foreign row needed.
    declareReads: *const fn (
        ctx: QueryContext,
        local_partition: PartitionId,
        out: *std.ArrayList(ForeignReadRequest),
    ) anyerror!void,

    /// Execute this partition's slice of the transaction.
    /// `foreign` contains all rows collected from other partitions at seq-1.
    /// Return error.ConstraintViolation to abort all partitions.
    execute: *const fn (
        ctx: QueryContext,
        local_partition: PartitionId,
        storage: *Storage,
        foreign: []const ForeignRow,
        mutations: *std.ArrayList(Mutation),
    ) anyerror!void,
};

pub const RegisteredHandler = union(enum) {
    single: QueryHandler,
    cross: CrossPartitionQueryHandler,
};

pub const QueryRegistry = struct {
    handlers: std.AutoHashMap([32]u8, RegisteredHandler),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) QueryRegistry {
        return .{
            .handlers = std.AutoHashMap([32]u8, RegisteredHandler).init(alloc),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *QueryRegistry) void {
        self.handlers.deinit();
    }

    pub fn register(self: *QueryRegistry, hash: [32]u8, handler: QueryHandler) !void {
        try self.handlers.put(hash, .{ .single = handler });
    }

    pub fn registerCross(self: *QueryRegistry, hash: [32]u8, handler: CrossPartitionQueryHandler) !void {
        try self.handlers.put(hash, .{ .cross = handler });
    }

    pub fn lookup(self: *const QueryRegistry, hash: [32]u8) ?RegisteredHandler {
        return self.handlers.get(hash);
    }
};
