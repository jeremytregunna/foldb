/// EpochBatcher: accumulates TxnIntent payloads and closes epochs with assigned seqs.
const std = @import("std");
const types = @import("types.zig");

const assert = std.debug.assert;

pub const Seq = types.Seq;
pub const PartitionId = types.PartitionId;
pub const EpochNum = types.EpochNum;
pub const EpochDecision = types.EpochDecision;
pub const OrderingEntry = types.OrderingEntry;

pub const DEFAULT_MAX_BATCH_SIZE: u32 = 10_000;

const PendingIntent = struct {
    client_id: u64,
    client_seq: u64,
};

pub const EpochBatcher = struct {
    pending: std.ArrayList(PendingIntent),
    max_batch_size: u32,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, max_batch_size: u32) EpochBatcher {
        assert(max_batch_size > 0);
        return .{
            .pending = .empty,
            .max_batch_size = max_batch_size,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *EpochBatcher) void {
        self.pending.deinit(self.alloc);
    }

    pub fn submit(self: *EpochBatcher, client_id: u64, client_seq: u64) !void {
        assert(self.pending.items.len < self.max_batch_size);
        try self.pending.append(self.alloc, .{ .client_id = client_id, .client_seq = client_seq });
    }

    pub fn shouldClose(self: *const EpochBatcher) bool {
        return self.pending.items.len >= self.max_batch_size;
    }

    pub fn pendingCount(self: *const EpochBatcher) u32 {
        return @intCast(self.pending.items.len);
    }

    /// Close the epoch: assign global seqs starting at next_seq, route round-robin to
    /// partition_count partitions. Clears pending list. Caller owns the returned entries slice.
    pub fn closeEpoch(
        self: *EpochBatcher,
        epoch_num: EpochNum,
        next_seq: Seq,
        partition_count: u32,
        alloc: std.mem.Allocator,
    ) !EpochDecision {
        assert(partition_count > 0);
        assert(next_seq > 0);
        const count = self.pending.items.len;
        const entries = try alloc.alloc(OrderingEntry, count);
        errdefer alloc.free(entries);

        for (self.pending.items, 0..) |intent, i| {
            const seq = next_seq + @as(Seq, i);
            const partition: PartitionId = @intCast(seq % @as(Seq, partition_count));
            entries[i] = .{
                .seq = seq,
                .partition = partition,
                .client_id = intent.client_id,
                .client_seq = intent.client_seq,
            };
        }

        self.pending.clearRetainingCapacity();

        return .{ .epoch_num = epoch_num, .entries = entries };
    }
};
