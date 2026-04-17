/// Simulation cluster — wires together RaftNodes, Logs, and InProcessBus.
///
/// This is the primary driver for deterministic simulation testing.
/// It runs all nodes in a single thread, giving complete control over
/// message delivery order, partition injection, and tick scheduling.
///
/// For production use, replace this with a multi-threaded driver that
/// binds TcpTransport to each node and runs an event loop per node.
const std = @import("std");
const log_mod = @import("log.zig");
const node_mod = @import("node.zig");
const transport_mod = @import("transport.zig");
const rpc = @import("rpc.zig");
const persistent = @import("persistent_state.zig");

const Log = log_mod.Log;
const LogEntry = log_mod.LogEntry;
const Seq = log_mod.Seq;
const NodeId = log_mod.NodeId;
pub const RaftNode = node_mod.RaftNode;
pub const RaftRole = node_mod.RaftRole;
pub const Config = node_mod.Config;
pub const Output = node_mod.Output;
const InProcessBus = transport_mod.InProcessBus;
const Envelope = transport_mod.Envelope;
const AppendEntriesArgs = rpc.AppendEntriesArgs;

pub const ClusterError = error{
    NoLeader,
    NotLeader,
    ProposeTimeout,
};

/// A simulation cluster of N Raft nodes sharing an in-process message bus.
pub fn SimCluster(comptime N: usize) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        nodes: [N]RaftNode,
        logs: [N]Log,
        bus: InProcessBus,
        node_ids: [N]NodeId,
        // Per-node directories for log files.
        dirs: [N][]u8,

        pub fn init(
            allocator: std.mem.Allocator,
            base_dir: []const u8,
            cfg: Config,
            seeds: [N]u64,
        ) !Self {
            var node_ids: [N]NodeId = undefined;
            for (0..N) |i| node_ids[i] = @intCast(i + 1);

            var dirs: [N][]u8 = undefined;
            var logs: [N]Log = undefined;
            var nodes: [N]RaftNode = undefined;

            var inited_logs: usize = 0;
            var inited_nodes: usize = 0;

            errdefer {
                var j: usize = 0;
                while (j < inited_nodes) : (j += 1) nodes[j].deinit();
                j = 0;
                while (j < inited_logs) : (j += 1) {
                    logs[j].deinit();
                    allocator.free(dirs[j]);
                }
            }

            // Ensure base directory exists before creating node subdirs.
            {
                const null_base = try allocator.dupeZ(u8, base_dir);
                defer allocator.free(null_base);
                _ = std.os.linux.mkdir(null_base.ptr, 0o755);
            }

            for (0..N) |i| {
                dirs[i] = try std.fmt.allocPrint(allocator, "{s}/node{d}", .{ base_dir, i });
                logs[i] = try Log.init(dirs[i], node_ids[i]);
                inited_logs += 1;

                // Build peer list (all nodes except self).
                var peer_ids: [N - 1]NodeId = undefined;
                var p: usize = 0;
                for (0..N) |j| {
                    if (j != i) {
                        peer_ids[p] = node_ids[j];
                        p += 1;
                    }
                }
                nodes[i] = try RaftNode.init(allocator, node_ids[i], &peer_ids, cfg, seeds[i]);
                inited_nodes += 1;
            }

            return Self{
                .allocator = allocator,
                .nodes = nodes,
                .logs = logs,
                .bus = InProcessBus.init(allocator),
                .node_ids = node_ids,
                .dirs = dirs,
            };
        }

        pub fn deinit(self: *Self) void {
            for (0..N) |i| {
                self.nodes[i].deinit();
                self.logs[i].deinit();
                self.allocator.free(self.dirs[i]);
            }
            self.bus.deinit();
        }

        /// Advance all nodes by one tick and deliver all pending messages.
        pub fn step(self: *Self) !void {
            // Tick all nodes.
            for (0..N) |i| {
                var outputs: std.ArrayList(Output) = .empty;
                defer outputs.deinit(self.allocator);
                try self.nodes[i].tick(&self.logs[i], &outputs);
                try self.processOutputs(i, &outputs);
            }
            // Deliver all messages currently in the bus.
            try self.drainBus();
        }

        /// Tick all nodes `n` times, delivering messages between each tick.
        pub fn stepN(self: *Self, n: usize) !void {
            for (0..n) |_| try self.step();
        }

        /// Find the current leader, or null if none elected yet.
        pub fn leader(self: *Self) ?usize {
            for (0..N) |i| {
                if (self.nodes[i].role == .leader) return i;
            }
            return null;
        }

        /// Propose a new entry to the leader. Returns the committed seq.
        /// Drives the cluster until the entry is committed (up to `max_steps` steps).
        pub fn propose(
            self: *Self,
            payload: []const u8,
            max_steps: usize,
        ) !Seq {
            const leader_idx = self.leader() orelse return ClusterError.NoLeader;

            var outputs: std.ArrayList(Output) = .empty;
            defer outputs.deinit(self.allocator);

            const seq = (try self.nodes[leader_idx].propose(
                &self.logs[leader_idx],
                .txn_intent,
                payload,
                &outputs,
            )) orelse return ClusterError.NotLeader;

            try self.processOutputs(leader_idx, &outputs);
            try self.drainBus();

            // Drive until committed on majority.
            var steps: usize = 0;
            while (steps < max_steps) : (steps += 1) {
                if (try self.isCommitted(seq)) return seq;
                try self.step();
            }
            return ClusterError.ProposeTimeout;
        }

        /// Return true if a majority of nodes have commit_index >= seq.
        pub fn isCommitted(self: *Self, seq: Seq) !bool {
            var count: usize = 0;
            for (0..N) |i| {
                if (self.nodes[i].commit_index >= seq) count += 1;
            }
            return count >= (N / 2 + 1);
        }

        /// Partition: messages from node_idx will be dropped.
        pub fn partitionNode(self: *Self, node_idx: usize) !void {
            try self.bus.partition(&.{self.node_ids[node_idx]});
        }

        /// Heal all partitions and optionally drop queued messages.
        pub fn heal(self: *Self, drop_queued: bool) void {
            self.bus.healAll();
            if (drop_queued) self.bus.dropAll();
        }

        // -----------------------------------------------------------------------
        // Private
        // -----------------------------------------------------------------------

        fn processOutputs(self: *Self, node_idx: usize, outputs: *std.ArrayList(Output)) !void {
            for (outputs.items) |output| {
                switch (output) {
                    .send => |s| {
                        try self.bus.send(self.node_ids[node_idx], s.to, s.msg);
                    },
                    .send_entries => |se| {
                        // Drop if sender is partitioned.
                        if (self.bus.partitioned_from.contains(self.node_ids[node_idx])) continue;
                        const target_idx = self.nodeIndex(se.to) orelse continue;
                        // Read entries while alive, deliver inline to avoid use-after-free
                        // if we buffered the slice pointer through the bus queue.
                        const entries = try self.logs[node_idx].read(
                            se.from_index,
                            self.nodes[node_idx].cfg.max_append_batch,
                            self.allocator,
                        );
                        defer {
                            for (entries) |*e| e.deinit(self.allocator);
                            self.allocator.free(entries);
                        }
                        var target_outs: std.ArrayList(Output) = .empty;
                        defer target_outs.deinit(self.allocator);
                        try self.nodes[target_idx].handleAppendEntries(
                            &self.logs[target_idx],
                            .{
                                .term = se.term,
                                .leader_id = se.leader_id,
                                .prev_log_index = se.prev_log_index,
                                .prev_log_term = se.prev_log_term,
                                .entries = entries,
                                .leader_commit = se.leader_commit,
                            },
                            &target_outs,
                        );
                        try self.processOutputs(target_idx, &target_outs);
                    },
                    .committed => {
                        // Cluster driver can hook here for client notifications.
                        // In simulation tests, we poll isCommitted() instead.
                    },
                    .persist => |p| {
                        try persistent.save(
                            self.dirs[node_idx],
                            self.allocator,
                            p.term,
                            p.voted_for,
                        );
                    },
                }
            }
        }

        fn drainBus(self: *Self) !void {
            while (self.bus.deliverOne()) |env| {
                const target_idx = self.nodeIndex(env.to) orelse continue;
                var outputs: std.ArrayList(Output) = .empty;
                defer outputs.deinit(self.allocator);

                switch (env.msg) {
                    .append_entries => |args| {
                        // Entries in args point into bus memory valid for this call.
                        try self.nodes[target_idx].handleAppendEntries(
                            &self.logs[target_idx],
                            args,
                            &outputs,
                        );
                    },
                    .append_entries_result => |result| {
                        try self.nodes[target_idx].handleAppendEntriesResult(
                            &self.logs[target_idx],
                            env.from,
                            result,
                            &outputs,
                        );
                    },
                    .request_vote => |args| {
                        try self.nodes[target_idx].handleRequestVote(
                            &self.logs[target_idx],
                            args,
                            &outputs,
                        );
                    },
                    .request_vote_result => |result| {
                        try self.nodes[target_idx].handleRequestVoteResult(
                            &self.logs[target_idx],
                            env.from,
                            result,
                            &outputs,
                        );
                    },
                }
                try self.processOutputs(target_idx, &outputs);
            }
        }

        fn nodeIndex(self: *const Self, id: NodeId) ?usize {
            for (self.node_ids, 0..) |nid, i| {
                if (nid == id) return i;
            }
            return null;
        }
    };
}
