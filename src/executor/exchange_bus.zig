/// ExchangeBus: manages peer-to-peer SPSC message channels between partition executors.
///
/// For N partitions there are N*(N-1) directed channels, one per ordered pair (from, to).
/// Channel (from=X, to=Y) is written exclusively by executor X and read exclusively by
/// executor Y, satisfying the SPSC contract.
///
/// Usage:
///   - Executor X pushes ExchangeRequest onto channel (X, Y) when it needs rows from Y.
///   - Executor Y pops from channel (X, Y), fetches the rows, and pushes ExchangeResponse
///     onto channel (Y, X) (the reverse direction).
///   - Both sides use pushBlocking/popBlocking only from within the serve-and-wait loop
///     so neither thread blocks indefinitely.
const std = @import("std");
const exchange = @import("exchange.zig");

pub const PartitionId = exchange.PartitionId;
pub const Seq = exchange.Seq;
pub const TableId = exchange.TableId;
pub const ForeignRead = exchange.ForeignRead;
pub const ExchangeRequest = exchange.ExchangeRequest;
pub const FetchedRow = exchange.FetchedRow;
pub const ExchangeResponse = exchange.ExchangeResponse;
pub const ExchangeMsg = exchange.ExchangeMsg;
pub const MsgQueue = exchange.MsgQueue;
pub const SpscQueue = exchange.SpscQueue;

pub const ExchangeBus = struct {
    partition_count: u32,
    /// queues[from * partition_count + to], allocated on the heap so pointers are stable.
    queues: []MsgQueue,
    alloc: std.mem.Allocator,

    pub fn init(partition_count: u32, alloc: std.mem.Allocator) !ExchangeBus {
        const n = partition_count;
        const queues = try alloc.alloc(MsgQueue, n * n);
        for (queues) |*q| q.* = .{};
        return .{
            .partition_count = n,
            .queues = queues,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *ExchangeBus) void {
        self.alloc.free(self.queues);
    }

    /// Non-blocking push from `from` to `to`. Returns false if the channel is full.
    pub fn push(self: *ExchangeBus, from: PartitionId, to: PartitionId, msg: ExchangeMsg) bool {
        return self.channel(from, to).push(msg);
    }

    /// Non-blocking pop of a message sent to `to` by `from`.
    pub fn pop(self: *ExchangeBus, from: PartitionId, to: PartitionId) ?ExchangeMsg {
        return self.channel(from, to).pop();
    }

    /// Returns true if the channel from → to has no pending messages.
    pub fn isEmpty(self: *const ExchangeBus, from: PartitionId, to: PartitionId) bool {
        return self.channelConst(from, to).isEmpty();
    }

    fn channel(self: *ExchangeBus, from: PartitionId, to: PartitionId) *MsgQueue {
        return &self.queues[from * self.partition_count + to];
    }

    fn channelConst(self: *const ExchangeBus, from: PartitionId, to: PartitionId) *const MsgQueue {
        return &self.queues[from * self.partition_count + to];
    }
};
