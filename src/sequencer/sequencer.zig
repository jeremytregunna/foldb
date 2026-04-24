/// Sequencer: assigns global seq numbers to TxnIntents and routes to partition logs.
///
/// Uses an internal RaftNode (single-node for M7) for durable ordering decisions.
/// Batches intents into epochs; each epoch decision is replicated before forwarding
/// intents to their assigned data partition logs.
const std = @import("std");
const log_mod = @import("log.zig");
const raft_mod = @import("raft.zig");
const obs = @import("observability.zig");

const types_mod = @import("types.zig");
const idempotency_mod = @import("idempotency.zig");
const epoch_mod = @import("epoch.zig");
const mpsc_mod = @import("mpsc_queue.zig");

pub const Seq = log_mod.Seq;
pub const PartitionId = log_mod.PartitionId;
pub const NodeId = log_mod.NodeId;
pub const EpochNum = types_mod.EpochNum;
pub const EpochDecision = types_mod.EpochDecision;
pub const OrderingEntry = types_mod.OrderingEntry;
pub const SubmitResult = types_mod.SubmitResult;
pub const SubmitHandle = types_mod.SubmitHandle;
pub const PendingSubmit = types_mod.PendingSubmit;
pub const ValidatedSubmit = types_mod.ValidatedSubmit;
pub const IdempotencyCache = idempotency_mod.IdempotencyCache;
pub const EpochBatcher = epoch_mod.EpochBatcher;

pub const Log = log_mod.Log;
pub const TxnIntent = log_mod.TxnIntent;
pub const LogEntry = log_mod.LogEntry;
pub const EntryKind = log_mod.EntryKind;

/// A peer node in the Raft group: its NodeId and Raft listener address.
pub const PeerAddr = struct {
    id: NodeId,
    addr: []const u8, // "host:port"
};

/// Sequencer config.
pub const Config = struct {
    /// Number of data partition logs.
    partition_count: u32 = 1,
    /// Max intents per epoch before forcing a close.
    max_epoch_size: usize = epoch_mod.DEFAULT_MAX_BATCH_SIZE,
    /// Node ID for the Sequencer's Raft group.
    node_id: NodeId = 1,
    /// How often the tick loop fires (milliseconds).
    tick_interval_ms: u32 = 10,
    /// Raft election timeout bounds (milliseconds).
    election_timeout_min_ms: u32 = 150,
    election_timeout_max_ms: u32 = 300,
    /// Raft heartbeat interval (milliseconds).
    heartbeat_interval_ms: u32 = 50,
    /// TCP port for inbound Raft messages. 0 = OS-assigned (useful in tests).
    listen_port: u16 = 0,
    /// Peer nodes in the Raft group. Empty → single-node, self-elects immediately.
    peers: []const PeerAddr = &.{},
};

pub const SequencerError = error{
    NotLeader,
    PartitionError,
    SerializeError,
    ConfigChangeInProgress,
};

/// The Sequencer: global ordering for TxnIntents across partition logs.
///
/// Runs a dedicated owner thread (start/deinit). All mutable state is owned exclusively
/// by that thread — callers submit via submitBytes() and spin on PendingSubmit.done.
pub const Sequencer = struct {
    raft: raft_mod.RaftNode,
    raft_log: Log,
    raft_path: []u8,
    batcher: EpochBatcher,
    idempotency: IdempotencyCache,
    /// Data partition logs, one per partition.
    partition_logs: []Log,
    next_seq: Seq,
    next_epoch: EpochNum,
    alloc: std.mem.Allocator,
    metrics: obs.SequencerMetrics = .{},
    /// TCP transport for Raft inter-node messaging.
    transport: raft_mod.TcpTransport,
    /// Owner thread fields.
    tick_interval_ms: u32,
    queue: mpsc_mod.MpscQueue(types_mod.PendingSubmit) = undefined,
    shutdown: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    /// Highest Raft log index whose committed output has been fully applied to
    /// the partition logs. Lets the committed handler apply entries incrementally
    /// on every node (leader and followers) without double-writing.
    last_applied: Seq = 0,

    /// Initialize a Sequencer at the given base path.
    /// Creates:
    ///   {base_path}/seq_raft/    — sequencer's ordering log
    ///   {base_path}/log_p{n}/    — data partition logs (0..partition_count-1)
    pub fn init(base_path: []const u8, cfg: Config, alloc: std.mem.Allocator) !Sequencer {
        // Ensure base directory exists
        const base_pathz = try std.heap.page_allocator.allocSentinel(u8, base_path.len, 0);
        defer std.heap.page_allocator.free(base_pathz);
        @memcpy(base_pathz[0..base_path.len], base_path);
        _ = std.os.linux.mkdir(base_pathz.ptr, 0o755);

        // Create ordering log
        const raft_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/seq_raft", .{base_path});
        errdefer std.heap.page_allocator.free(raft_path);

        const seq_partition_id: PartitionId = std.math.maxInt(PartitionId);
        var raft_log = try Log.initPartitioned(raft_path, cfg.node_id, seq_partition_id);
        errdefer raft_log.deinit();

        // Derive Raft tick counts from millisecond config values.
        const tick_ms = if (cfg.tick_interval_ms == 0) 1 else cfg.tick_interval_ms;
        const election_min = @max(1, cfg.election_timeout_min_ms / tick_ms);
        const election_max = @max(1, cfg.election_timeout_max_ms / tick_ms);
        const heartbeat = @max(1, cfg.heartbeat_interval_ms / tick_ms);

        // Build peer NodeId list from PeerAddr slice.
        const peer_ids = try alloc.alloc(NodeId, cfg.peers.len);
        defer alloc.free(peer_ids);
        for (cfg.peers, 0..) |p, i| peer_ids[i] = p.id;

        const raft_cfg = raft_mod.Config{
            .election_timeout_min = election_min,
            .election_timeout_max = election_max,
            .heartbeat_interval = heartbeat,
            .max_append_batch = 64,
        };
        var raft_node = try raft_mod.RaftNode.init(alloc, cfg.node_id, peer_ids, raft_cfg, cfg.node_id);
        errdefer raft_node.deinit();

        // Single-node: tick until self-elected. Multi-node: leave election to the tick loop.
        var outputs: std.ArrayList(raft_mod.Output) = .empty;
        defer outputs.deinit(alloc);
        if (cfg.peers.len == 0) {
            for (0..election_max + 1) |_| {
                try raft_node.tick(&raft_log, &outputs);
                outputs.clearRetainingCapacity();
                if (raft_node.role == .leader) break;
            }
        }

        // Create data partition logs
        const partition_logs = try alloc.alloc(Log, cfg.partition_count);
        errdefer alloc.free(partition_logs);
        var initialized: usize = 0;
        errdefer for (partition_logs[0..initialized]) |*pl| pl.deinit();

        for (0..cfg.partition_count) |i| {
            const part_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/log_p{d}", .{ base_path, i });
            defer std.heap.page_allocator.free(part_path);
            partition_logs[i] = try Log.initPartitioned(part_path, cfg.node_id, @intCast(i));
            initialized += 1;
        }

        var batcher = EpochBatcher.init(alloc);
        batcher.max_batch_size = cfg.max_epoch_size;

        // Resume from the highest committed seq across all partition logs.
        var max_seq: Seq = 0;
        for (partition_logs) |pl| {
            if (pl.current_seq > max_seq) max_seq = pl.current_seq;
        }

        // Set up TCP transport.
        var transport = raft_mod.TcpTransport.init(alloc, cfg.node_id);
        errdefer transport.deinit();
        if (cfg.peers.len > 0) {
            try transport.listen(cfg.listen_port);
            for (cfg.peers) |p| try transport.addPeer(p.id, p.addr);
        }

        return Sequencer{
            .raft = raft_node,
            .raft_log = raft_log,
            .raft_path = raft_path,
            .batcher = batcher,
            .idempotency = IdempotencyCache.init(alloc),
            .partition_logs = partition_logs,
            .next_seq = max_seq + 1,
            .next_epoch = 1,
            .alloc = alloc,
            .transport = transport,
            .tick_interval_ms = cfg.tick_interval_ms,
        };
    }

    /// Start the Sequencer's owner thread. Must be called once after the Sequencer is
    /// at its final address (i.e. after assignment into the heap-allocated Gateway).
    pub fn start(self: *Sequencer) !void {
        self.queue.init();
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    pub fn deinit(self: *Sequencer) void {
        self.shutdown.store(true, .release);
        self.queue.wakeConsumer();
        if (self.thread) |t| t.join();
        self.raft.deinit();
        self.raft_log.deinit();
        std.heap.page_allocator.free(self.raft_path);
        for (self.partition_logs) |*pl| pl.deinit();
        self.alloc.free(self.partition_logs);
        self.batcher.deinit();
        self.idempotency.deinit();
        self.transport.deinit();
    }

    pub fn currentSeq(self: *const Sequencer) Seq {
        return self.next_seq - 1;
    }

    pub fn partitionCount(self: *const Sequencer) u32 {
        return @intCast(self.partition_logs.len);
    }

    pub fn isLeader(self: *const Sequencer) bool {
        return self.raft.role == .leader;
    }

    /// Return the TCP port the transport is bound to.
    /// Only valid if the transport is listening (multi-node config).
    pub fn boundPort(self: *const Sequencer) !u16 {
        return self.transport.boundPort();
    }

    /// Add an address for a peer to the TCP transport after init.
    /// Useful in tests where ports are assigned by the OS and not known at init time.
    pub fn addTransportPeer(self: *Sequencer, id: NodeId, addr: []const u8) !void {
        try self.transport.addPeer(id, addr);
    }

    /// Start listening on the given port (call after init when listen_port wasn't set).
    pub fn startListening(self: *Sequencer, port: u16) !void {
        try self.transport.listen(port);
    }

    /// Propose adding a new Raft voter. Pre-registers the peer address in the
    /// TCP transport so AppendEntries can be sent immediately after the proposal.
    /// Returns NotLeader if this node is not the leader, ConfigChangeInProgress if
    /// another membership change is already in flight.
    pub fn addNode(self: *Sequencer, node_id: NodeId, addr: []const u8, alloc: std.mem.Allocator) !void {
        if (!self.isLeader()) return SequencerError.NotLeader;
        try self.transport.addPeer(node_id, addr);
        var outputs: std.ArrayList(raft_mod.Output) = .empty;
        defer outputs.deinit(alloc);
        _ = try self.raft.proposeConfigChange(&self.raft_log, .add_voter, node_id, &outputs) orelse
            return SequencerError.ConfigChangeInProgress;
        try self.flushOutputs(outputs.items, alloc);
    }

    /// Propose removing a Raft voter. Closes and deregisters the peer's transport
    /// connection once the proposal is submitted.
    /// Returns NotLeader if this node is not the leader, ConfigChangeInProgress if
    /// another membership change is already in flight.
    pub fn removeNode(self: *Sequencer, node_id: NodeId, alloc: std.mem.Allocator) !void {
        if (!self.isLeader()) return SequencerError.NotLeader;
        var outputs: std.ArrayList(raft_mod.Output) = .empty;
        defer outputs.deinit(alloc);
        _ = try self.raft.proposeConfigChange(&self.raft_log, .remove_voter, node_id, &outputs) orelse
            return SequencerError.ConfigChangeInProgress;
        try self.flushOutputs(outputs.items, alloc);
        self.transport.removePeer(node_id);
    }

    pub fn commitIndex(self: *const Sequencer) Seq {
        return self.raft.commit_index;
    }

    /// Propose a raw payload directly to the Raft ordering log. Returns the committed seq
    /// on this node (entry may still be in-flight on followers). Errors if not leader.
    pub fn proposeRaw(self: *Sequencer, payload: []const u8, alloc: std.mem.Allocator) !Seq {
        var outputs: std.ArrayList(raft_mod.Output) = .empty;
        defer outputs.deinit(alloc);
        const seq = try self.raft.propose(
            &self.raft_log,
            .txn_intent,
            payload,
            &outputs,
        ) orelse return SequencerError.NotLeader;
        try self.flushOutputs(outputs.items, alloc);
        return seq;
    }

    /// Drive one cycle: drain TCP inbox → dispatch messages → tick Raft timer → flush outputs.
    /// The caller's tick loop should call this at the configured tick_interval_ms rate.
    pub fn tickOnce(self: *Sequencer, alloc: std.mem.Allocator) !void {
        // Drain all pending inbound TCP messages.
        while (try self.transport.pollOnce(alloc)) {}

        var inbox: std.ArrayList(raft_mod.Envelope) = .empty;
        defer inbox.deinit(alloc);
        try self.transport.drainInbox(&inbox, alloc);

        // Dispatch each inbound message to the Raft state machine.
        var outputs: std.ArrayList(raft_mod.Output) = .empty;
        defer outputs.deinit(alloc);

        for (inbox.items) |env| {
            switch (env.msg) {
                .append_entries => |args| {
                    defer {
                        for (args.entries) |entry| alloc.free(@constCast(&entry).payload);
                        alloc.free(@constCast(args.entries));
                    }
                    try self.raft.handleAppendEntries(&self.raft_log, args, &outputs);
                },
                .append_entries_result => |result| {
                    try self.raft.handleAppendEntriesResult(&self.raft_log, env.from, result, &outputs);
                },
                .request_vote => |args| {
                    try self.raft.handleRequestVote(&self.raft_log, args, &outputs);
                },
                .request_vote_result => |result| {
                    try self.raft.handleRequestVoteResult(&self.raft_log, env.from, result, &outputs);
                },
            }
            try self.flushOutputs(outputs.items, alloc);
            outputs.clearRetainingCapacity();
        }

        // Advance Raft timers.
        try self.raft.tick(&self.raft_log, &outputs);
        try self.flushOutputs(outputs.items, alloc);
    }

    /// Process Raft output effects: send messages, persist state, build AppendEntries.
    fn flushOutputs(self: *Sequencer, outputs: []const raft_mod.Output, alloc: std.mem.Allocator) !void {
        for (outputs) |output| {
            switch (output) {
                .send => |s| self.transport.send(s.to, s.msg),
                .send_entries => |se| {
                    const entries = try self.raft_log.read(
                        se.from_index,
                        self.raft.cfg.max_append_batch,
                        alloc,
                    );
                    defer {
                        for (entries) |*e| e.deinit(alloc);
                        alloc.free(entries);
                    }
                    self.transport.send(se.to, .{ .append_entries = .{
                        .term = se.term,
                        .leader_id = se.leader_id,
                        .prev_log_index = se.prev_log_index,
                        .prev_log_term = se.prev_log_term,
                        .entries = entries,
                        .leader_commit = se.leader_commit,
                    } });
                },
                .persist => |p| {
                    raft_mod.savePersistentState(
                        self.raft_path,
                        alloc,
                        p.term,
                        p.voted_for,
                    ) catch {};
                },
                .committed => |commit_seq| {
                    // Apply all newly committed Raft entries to the local partition logs.
                    // Runs on every node — leader and followers — so all nodes stay in sync.
                    var idx = self.last_applied + 1;
                    while (idx <= commit_seq) : (idx += 1) {
                        const raft_entries = self.raft_log.read(idx, 1, alloc) catch break;
                        defer {
                            for (raft_entries) |*e| e.deinit(alloc);
                            alloc.free(raft_entries);
                        }
                        if (raft_entries.len == 0) break;
                        const re = raft_entries[0];
                        if (re.header.kind == .epoch_decision) {
                            const dec = types_mod.deserializeEpochDecision(re.payload, alloc) catch {
                                self.last_applied = idx;
                                continue;
                            };
                            defer alloc.free(dec.entries);
                            for (dec.entries) |oe| {
                                const pl = &self.partition_logs[oe.partition];
                                const le = LogEntry.create(oe.seq, 0, dec.entry_kind, dec.payload);
                                pl.appendEntryAt(le) catch {};
                            }
                        }
                        self.last_applied = idx;
                    }
                },
                // Raft peer list is already updated internally by RaftNode when this fires.
                // Transport was pre-registered in addNode / cleaned up in removeNode.
                .apply_config => {},
            }
        }
    }

    /// Return a pointer to the log for the given partition (for reading committed entries).
    pub fn partitionLog(self: *Sequencer, partition: PartitionId) *Log {
        return &self.partition_logs[partition];
    }

    /// Domain boundary — accepts raw gateway input and enqueues it for the Sequencer thread.
    /// The caller stack-allocates pending and must not access it until awaitCommit() returns.
    /// Idempotent on (client_id, client_seq_num).
    pub fn submitBytes(
        self: *Sequencer,
        pending: *types_mod.PendingSubmit,
        intent_payload: []const u8,
        client_id: u64,
        client_seq_num: u64,
        entry_kind: log_mod.EntryKind,
    ) types_mod.SubmitHandle {
        pending.* = .{
            .submit = .{
                .client_id = client_id,
                .client_seq = client_seq_num,
                .intent_payload = intent_payload,
                .entry_kind = entry_kind,
            },
            .result = undefined,
            .err = null,
            .done = .init(false),
            .next = .init(null),
        };
        self.queue.push(pending);
        return .{ .pending = pending };
    }
};

/// Sequencer owner thread: drains the MPSC queue, drives Raft ticks, signals completions.
fn runLoop(self: *Sequencer) void {
    const tick_ns: u64 = @as(u64, self.tick_interval_ms) * 1_000_000;
    while (!self.shutdown.load(.acquire)) {
        // Sample seq before pop — if a producer pushes between the failed pop and
        // waitForWork, the seq change causes waitForWork to return immediately.
        const seq = self.queue.currentSeq();

        if (self.queue.pop()) |p| {
            processCommit(self, p);
        } else {
            self.queue.waitForWork(seq, tick_ns);
        }

        self.tickOnce(self.alloc) catch {};
    }
}

fn processCommit(self: *Sequencer, pending: *types_mod.PendingSubmit) void {
    const result = commitInner(self, pending.submit) catch |e| {
        pending.err = e;
        pending.done.store(true, .release);
        return;
    };
    pending.result = result;
    pending.done.store(true, .release);
}

/// Core commit logic, called only from the Sequencer owner thread.
fn commitInner(self: *Sequencer, submit: ValidatedSubmit) !SubmitResult {
    self.metrics.intents_submitted.inc();

    const client_id = submit.client_id;
    const client_seq_num = submit.client_seq;

    // Idempotency fast path
    if (self.idempotency.lookup(client_id, client_seq_num)) |existing_seq| {
        self.metrics.dedup_hits.inc();
        const partition: PartitionId = @intCast(existing_seq % @as(Seq, self.partition_logs.len));
        return .{ .seq = existing_seq, .partition = partition };
    }

    try self.batcher.submit(client_id, client_seq_num);

    var decision = try self.batcher.closeEpoch(
        self.next_epoch,
        self.next_seq,
        @intCast(self.partition_logs.len),
        self.alloc,
    );
    defer self.alloc.free(decision.entries);
    // Attach the payload so all nodes can write to their partition logs from the
    // committed Raft entry — no separate data replication channel needed.
    decision.entry_kind = submit.entry_kind;
    decision.payload = submit.intent_payload;

    self.next_epoch += 1;
    self.next_seq += @intCast(decision.entries.len);
    self.metrics.epochs_closed.inc();
    self.metrics.last_epoch_size.set(@intCast(decision.entries.len));

    var payload_buf: std.ArrayList(u8) = .empty;
    defer payload_buf.deinit(self.alloc);
    try types_mod.serializeEpochDecision(decision, &payload_buf, self.alloc);

    var outputs: std.ArrayList(raft_mod.Output) = .empty;
    defer outputs.deinit(self.alloc);

    const ordering_seq = try self.raft.propose(
        &self.raft_log,
        .epoch_decision,
        payload_buf.items,
        &outputs,
    ) orelse {
        self.metrics.not_leader_errors.inc();
        return SequencerError.NotLeader;
    };

    try self.flushOutputs(outputs.items, self.alloc);

    // Wait for Raft commit. For single-node, commit_index already advanced (quorum=1)
    // so this loop body never executes. For multi-node, tickOnce drives the round-trips.
    // The .committed output handler in flushOutputs writes to all nodes' partition logs,
    // so by the time we exit this loop the entry is already in the partition log.
    const wait_ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
    while (self.raft.commit_index < ordering_seq) {
        try self.tickOnce(self.alloc);
        _ = std.os.linux.nanosleep(&wait_ts, null);
    }

    const entry = decision.entries[0];
    try self.idempotency.record(client_id, client_seq_num, entry.seq);
    self.metrics.current_seq.set(@intCast(entry.seq));

    return .{ .seq = entry.seq, .partition = entry.partition };
}
