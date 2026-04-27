/// Query registry: maps QueryHash → QueryHandler (single-partition).
const std = @import("std");
const assert = std.debug.assert;

pub const handlers_max: u32 = 1024;
const types = @import("types.zig");
const storage_mod = @import("storage.zig");

pub const QueryHash = types.QueryHash;
pub const ResolvedValue = types.ResolvedValue;
pub const Seq = types.Seq;
pub const PartitionId = types.PartitionId;
pub const Storage = storage_mod.Storage;
pub const Mutation = storage_mod.Mutation;

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

pub const RegisteredHandler = union(enum) {
    single: QueryHandler,
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
        assert(self.handlers.count() < handlers_max);
        if (self.handlers.count() >= handlers_max) return error.TooManyHandlers;
        try self.handlers.put(hash, .{ .single = handler });
    }

    pub fn lookup(self: *const QueryRegistry, hash: [32]u8) ?RegisteredHandler {
        return self.handlers.get(hash);
    }
};
