/// Inter-partition value exchange for cross-partition transaction execution.
///
/// When a TxnIntent touches multiple data partitions, each FoldExecutor declares
/// which rows it needs from peer partitions (ForeignRead), sends ExchangeRequests,
/// and receives ExchangeResponses before executing its local slice.  Messages are
/// keyed by (seq, from, to) so late-joining followers can replay them from peers.
///
/// SpscQueue(T) is a lock-free single-producer / single-consumer ring buffer.
/// Callers own all memory referenced by items; the queue stores copies of the
/// struct values (which may contain pointers/slices into caller-owned buffers).
const std = @import("std");
const types = @import("types.zig");
const storage_mod = @import("storage.zig");

pub const PartitionId = types.PartitionId;
pub const Seq = types.Seq;
pub const TableId = storage_mod.TableId;
pub const Row = storage_mod.Row;

/// A request for one row from a peer partition's storage at seq-1.
/// key = "" is a sentinel meaning "send me the full scan for this table".
pub const ForeignRead = struct {
    table_id: TableId,
    key: []const u8,
};

/// A request sent from partition `from` to partition `to` asking for rows.
pub const ExchangeRequest = struct {
    seq: Seq,
    from: PartitionId,
    to: PartitionId,
    reads: []const ForeignRead, // slice into caller-owned memory
};

/// One row returned by a peer in response to a ForeignRead.
/// row == null means the key did not exist at seq-1.
pub const FetchedRow = struct {
    from_partition: PartitionId, // which partition fetched and returned this row
    table_id: TableId,
    key: []const u8,
    row: ?Row,
};

/// A response sent from partition `from` back to partition `to`.
pub const ExchangeResponse = struct {
    seq: Seq,
    from: PartitionId, // partition that fetched the rows
    to: PartitionId,   // partition that requested them
    rows: []const FetchedRow, // slice into caller-owned memory
};

pub const ExchangeMsg = union(enum) {
    request: ExchangeRequest,
    response: ExchangeResponse,
};

/// Lock-free SPSC ring buffer with compile-time capacity (must be power of two).
/// Only one goroutine may call push(); only one may call pop().
/// Items are copied by value — slices inside are NOT deep-copied.
pub fn SpscQueue(comptime T: type, comptime cap: usize) type {
    comptime std.debug.assert(cap > 0 and (cap & (cap - 1)) == 0); // power of two
    return struct {
        const Self = @This();
        const mask = cap - 1;

        items: [cap]T = undefined,
        // tail written only by producer; head written only by consumer.
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        /// Push an item.  Returns false if the queue is full (caller should retry).
        pub fn push(self: *Self, item: T) bool {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.acquire);
            if (t -% h == cap) return false; // full
            self.items[t & mask] = item;
            self.tail.store(t +% 1, .release);
            return true;
        }

        /// Pop an item.  Returns null if the queue is empty.
        pub fn pop(self: *Self) ?T {
            const h = self.head.load(.monotonic);
            const t = self.tail.load(.acquire);
            if (h == t) return null; // empty
            const item = self.items[h & mask];
            self.head.store(h +% 1, .release);
            return item;
        }

        pub fn isEmpty(self: *const Self) bool {
            const h = self.head.load(.acquire);
            const t = self.tail.load(.acquire);
            return h == t;
        }
    };
}

/// Default queue capacity: 64 messages per directed channel.
pub const default_queue_cap = 64;
pub const MsgQueue = SpscQueue(ExchangeMsg, default_queue_cap);
