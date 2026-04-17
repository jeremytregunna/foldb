/// Transport abstraction for Raft message delivery.
///
/// The Transport interface separates the Raft state machine from network I/O,
/// enabling deterministic simulation testing (InProcessTransport) alongside
/// production TCP usage (TcpTransport).
///
/// Simulation design: InProcessTransport queues messages in memory.
/// The simulation driver controls delivery order, drops, and partitions.
/// This gives full deterministic control over network behavior.
const std = @import("std");
const rpc = @import("rpc.zig");

pub const NodeId = rpc.NodeId;
pub const Message = rpc.Message;

// ---------------------------------------------------------------------------
// Envelope — a message in flight.
// ---------------------------------------------------------------------------

pub const Envelope = struct {
    from: NodeId,
    to: NodeId,
    msg: Message,
};

// ---------------------------------------------------------------------------
// InProcessTransport — for simulation and testing.
//
// All nodes share a single InProcessBus. Messages are queued and delivered
// by the simulation driver in a controlled order. Partitions are implemented
// by checking a drop-set before delivering.
// ---------------------------------------------------------------------------

pub const InProcessBus = struct {
    allocator: std.mem.Allocator,
    queue: std.ArrayList(Envelope),
    // Nodes in this set have outbound messages dropped (partition simulation).
    partitioned_from: std.AutoHashMap(NodeId, void),

    pub fn init(allocator: std.mem.Allocator) InProcessBus {
        return .{
            .allocator = allocator,
            .queue = .empty,
            .partitioned_from = .init(allocator),
        };
    }

    pub fn deinit(self: *InProcessBus) void {
        self.queue.deinit(self.allocator);
        self.partitioned_from.deinit();
    }

    /// Queue a message. Silently drops it if sender is partitioned.
    pub fn send(self: *InProcessBus, from: NodeId, to: NodeId, msg: Message) !void {
        if (self.partitioned_from.contains(from)) return;
        try self.queue.append(self.allocator, .{ .from = from, .to = to, .msg = msg });
    }

    /// Deliver the oldest pending message. Returns null if queue is empty.
    pub fn deliverOne(self: *InProcessBus) ?Envelope {
        if (self.queue.items.len == 0) return null;
        const env = self.queue.items[0];
        std.mem.copyForwards(Envelope, self.queue.items[0..], self.queue.items[1..]);
        self.queue.items.len -= 1;
        return env;
    }

    /// Return count of pending messages.
    pub fn pending(self: *const InProcessBus) usize {
        return self.queue.items.len;
    }

    /// Partition: messages from any node in `node_ids` will be dropped.
    pub fn partition(self: *InProcessBus, node_ids: []const NodeId) !void {
        for (node_ids) |id| {
            try self.partitioned_from.put(id, {});
        }
    }

    /// Heal all partitions.
    pub fn healAll(self: *InProcessBus) void {
        self.partitioned_from.clearRetainingCapacity();
    }

    /// Drop all messages currently in the queue (simulates message loss).
    pub fn dropAll(self: *InProcessBus) void {
        self.queue.items.len = 0;
    }
};
