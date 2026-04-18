/// Idempotency cache: deduplicates TxnIntents by (client_id, client_seq).
const std = @import("std");
const types = @import("types.zig");

pub const Seq = types.Seq;

const IdempotencyKey = struct {
    client_id: u64,
    client_seq: u64,
};

pub const IdempotencyCache = struct {
    entries: std.AutoHashMap(IdempotencyKey, Seq),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) IdempotencyCache {
        return .{
            .entries = std.AutoHashMap(IdempotencyKey, Seq).init(alloc),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *IdempotencyCache) void {
        self.entries.deinit();
    }

    pub fn lookup(self: *const IdempotencyCache, client_id: u64, client_seq: u64) ?Seq {
        return self.entries.get(.{ .client_id = client_id, .client_seq = client_seq });
    }

    pub fn record(self: *IdempotencyCache, client_id: u64, client_seq: u64, seq: Seq) !void {
        try self.entries.put(.{ .client_id = client_id, .client_seq = client_seq }, seq);
    }

    /// Evict entries whose assigned seq is strictly less than before_seq.
    /// Called periodically to bound cache memory.
    pub fn evictBefore(self: *IdempotencyCache, before_seq: Seq) void {
        var it = self.entries.iterator();
        var to_remove: std.ArrayList(IdempotencyKey) = .empty;
        defer to_remove.deinit(self.alloc);

        while (it.next()) |entry| {
            if (entry.value_ptr.* < before_seq) {
                to_remove.append(self.alloc, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            _ = self.entries.remove(key);
        }
    }
};
