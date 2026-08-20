/// Sequencer: assigns global seq numbers to TxnIntents and routes to partition logs.
///
/// Uses an internal RaftNode for durable ordering decisions.
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

const assert = std.debug.assert;

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
pub const PeerAddr = types_mod.PeerAddr;

/// Sequencer config.
pub const Config = struct {
    /// Number of partitions (storage sharding and write throughput routing).
    partition_count: u32 = 1,
    /// Deprecated alias retained for older tests/configs during the KV transition.
    log_partition_count: ?u32 = null,
    /// Max intents per epoch before forcing a close.
    max_epoch_size: u32 = epoch_mod.DEFAULT_MAX_BATCH_SIZE,
    /// Node ID for the Sequencer's Raft group.
    node_id: NodeId = 1,
    /// How often the tick loop fires (milliseconds).
    tick_interval_ms: u32 = 1,
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
    CommitTimeout,
};

/// Sleep duration per iteration of the commit-wait loop (100 µs in nanoseconds).
const COMMIT_WAIT_SLEEP_NS: u32 = 100_000;
/// Timeout for commit-wait loops (30 seconds in nanoseconds).
/// Replaces the old tick-based assert so replication doesn't crash when quorum is lost.
const COMMIT_WAIT_TIMEOUT_NS: u64 = 30_000_000_000;

/// The Sequencer: global ordering for TxnIntents across partition logs.
///
/// Runs a dedicated owner thread (start/deinit). All mutable state is owned exclusively
/// by that thread — callers submit via submitBytes() and spin on PendingSubmit.done.
pub const Sequencer = struct {
    raft: raft_mod.RaftNode,
    raft_log: Log,
    raft_path: []u8,
    last_applied_path: []u8,
    batcher: EpochBatcher,
    idempotency: IdempotencyCache,
    /// Log partition logs, one per partition. Routed to by seq % partition_count.
    partition_logs: []Log,
    /// Number of partitions (storage sharding and write throughput routing).
    partition_count: u32,
    /// Number of physical WAL partitions used by the sequencer.
    log_partition_count: u32,
    /// Per-log-partition append counter for load-weighted routing (spec §8.2).
    /// Incremented each time a seq is routed to that partition; decayed periodically.
    log_append_counts: []u64,
    /// Seq at which log_append_counts were last decayed.
    log_load_decay_seq: Seq = 0,
    next_seq: Seq,
    next_epoch: EpochNum,
    alloc: std.mem.Allocator,
    metrics: obs.SequencerMetrics = .{},
    /// TCP transport for Raft inter-node messaging.
    transport: raft_mod.TcpTransport,
    /// Owner thread fields.
    tick_interval_ms: u32,
    queue: mpsc_mod.MpscQueue(types_mod.PendingSubmit),
    shutdown: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    /// Highest Raft log index whose committed output has been fully applied.
    last_applied: Seq = 0,
    /// Pipelined commit: batches proposed but not yet committed.
    pending_batches: std.ArrayListUnmanaged(PendingBatch) = .empty,

    /// Initialize a Sequencer at the given base path.
    /// Creates:
    ///   {base_path}/seq_raft/    — sequencer's own Raft ordering log
    ///   {base_path}/log_p{n}/    — N partition logs (0..partition_count-1)
    pub fn init(base_path: []const u8, cfg: Config, alloc: std.mem.Allocator) !Sequencer {
        assert(base_path.len > 0);
        const log_partition_count = cfg.log_partition_count orelse cfg.partition_count;
        assert(cfg.partition_count > 0);
        assert(log_partition_count > 0);

        // Ensure base directory exists.
        const base_pathz = try std.heap.page_allocator.allocSentinel(u8, base_path.len, 0);
        defer std.heap.page_allocator.free(base_pathz);
        @memcpy(base_pathz[0..base_path.len], base_path);
        _ = std.os.linux.mkdir(base_pathz.ptr, 0o755);

        // Allocate persistent paths using the caller's allocator for consistency.
        const raft_path = try std.fmt.allocPrint(alloc, "{s}/seq_raft", .{base_path});
        errdefer alloc.free(raft_path);
        const last_applied_path = try std.fmt.allocPrint(alloc, "{s}/last_applied.bin", .{base_path});
        errdefer alloc.free(last_applied_path);

        const seq_partition_id: PartitionId = std.math.maxInt(PartitionId);
        var raft_log = try Log.init_partitioned(raft_path, cfg.node_id, seq_partition_id, alloc);
        errdefer raft_log.deinit();

        var raft_node = try initRaftNode(cfg, &raft_log, alloc);
        errdefer raft_node.deinit();
        if (cfg.peers.len == 0) {
            raft_node.commit_index = try raft_log.head();
        }

        const partition_logs = try createPartitionLogs(base_path, cfg.node_id, log_partition_count, alloc);
        errdefer {
            for (partition_logs) |*pl| pl.deinit();
            alloc.free(partition_logs);
        }

        const log_append_counts = try alloc.alloc(u64, log_partition_count);
        errdefer alloc.free(log_append_counts);
        @memset(log_append_counts, 0);

        var max_seq: Seq = 0;
        for (partition_logs) |pl| {
            if (pl.current_seq > max_seq) max_seq = pl.current_seq;
        }

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
            .last_applied_path = last_applied_path,
            .batcher = EpochBatcher.init(alloc, cfg.max_epoch_size),
            .idempotency = IdempotencyCache.init(alloc),
            .partition_logs = partition_logs,
            .partition_count = cfg.partition_count,
            .log_partition_count = log_partition_count,
            .log_append_counts = log_append_counts,
            .next_seq = max_seq + 1,
            .next_epoch = 1,
            .alloc = alloc,
            .transport = transport,
            .tick_interval_ms = cfg.tick_interval_ms,
            .last_applied = 0,
            // queue is intentionally left undefined here; start() calls queue.init() before use.
            .queue = undefined,
        };
    }

    /// Start the Sequencer's owner thread. Must be called once after the Sequencer is
    /// at its final address (i.e. after assignment into the heap-allocated Gateway).
    pub fn start(self: *Sequencer) !void {
        self.queue.init();
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    pub fn deinit(self: *Sequencer) void {
        self.stopAndCatchUp();
        // Clean up any pending batches still in-flight.
        for (self.pending_batches.items) |pb| {
            self.alloc.free(pb.slots);
        }
        self.pending_batches.deinit(self.alloc);
        self.raft.deinit();
        self.raft_log.deinit();
        self.alloc.free(self.raft_path);
        self.alloc.free(self.last_applied_path);
        for (self.partition_logs) |*pl| pl.deinit();
        self.alloc.free(self.partition_logs);
        self.alloc.free(self.log_append_counts);
        self.batcher.deinit();
        self.idempotency.deinit();
        self.transport.deinit();
    }

    pub fn stopAndCatchUp(self: *Sequencer) void {
        if (self.thread) |t| {
            self.shutdown.store(true, .release);
            self.queue.wakeConsumer();
            t.join();
            self.thread = null;
        }
        self.catchUpCommitted() catch |err| std.log.warn("sequencer shutdown catch-up: {}", .{err});
    }

    pub fn catchUpCommitted(self: *Sequencer) !void {
        try self.applyCommitted(self.raft.commit_index, self.alloc);
    }

    pub fn currentSeq(self: *const Sequencer) Seq {
        return self.next_seq - 1;
    }

    pub fn partitionCount(self: *const Sequencer) u32 {
        return self.partition_count;
    }

    pub fn logPartitionCount(self: *const Sequencer) u32 {
        return self.log_partition_count;
    }

    /// The log partition logs owned by this Sequencer. Each FoldExecutor's LogMux
    /// should span all of these so every executor sees the full global log stream.
    pub fn logPartitionLogs(self: *Sequencer) []Log {
        return self.partition_logs;
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
                    // Raft safety: term+voted_for must be durable before sending any messages.
                    // Failure here risks acting on stale term after crash-restart.
                    try raft_mod.savePersistentState(
                        self.raft_path,
                        alloc,
                        p.term,
                        p.voted_for,
                    );
                },
                .committed => |commit_seq| {
                    try self.applyCommitted(commit_seq, alloc);
                },
                // Raft peer list is already updated internally by RaftNode when this fires.
                // Transport was pre-registered in addNode / cleaned up in removeNode.
                .apply_config => {},
            }
        }
    }

    /// Apply all Raft entries up to commit_seq to the partition logs.
    /// Idempotent: entries already present (seq <= current_seq) are skipped.
    /// Advances next_seq past every seq the Raft log has assigned.
    fn applyCommitted(self: *Sequencer, commit_seq: Seq, alloc: std.mem.Allocator) !void {
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
                    assert(oe.partition < self.partition_logs.len);
                    const pl = &self.partition_logs[oe.partition];
                    // Re-apply is at-least-once. Seq uniqueness means oe.seq <=
                    // current_seq is the entry already on disk, so skip it.
                    if (oe.seq <= pl.current_seq) continue;
                    const le = LogEntry.create(oe.seq, 0, dec.entry_kind, dec.payload);
                    try pl.append_entry_at(le);
                }
                // Keep next_seq ahead of every seq the Raft log has assigned.
                // Covers seqs written just now and seqs skipped above as already-present,
                // so post-restart commits never reuse a seq from a prior epoch decision.
                for (dec.entries) |oe| {
                    if (oe.seq >= self.next_seq) self.next_seq = oe.seq + 1;
                }
                // Notify after all entries in the batch are written, so FoldExecutor
                // does not wake mid-batch and race with concurrent writes.
                for (dec.entries) |oe| {
                    self.partition_logs[oe.partition].notifyAppend();
                }
            }
            self.last_applied = idx;
        }
    }

    /// Return a pointer to the log for the given partition (for reading committed entries).
    pub fn partitionLog(self: *Sequencer, partition: PartitionId) *Log {
        assert(partition < self.partition_logs.len);
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
        assert(!self.shutdown.load(.acquire));
        // SAFETY: result is written by the Sequencer thread before done is set to true.
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

    /// Route one intent to the least-loaded log partition (spec §8.2).
    /// Breaks ties with seq % partition_count for determinism. Decays counters
    /// every 4096 commits to prevent stale bias from past bursts.
    /// Each intent lands in exactly one log partition; LogMux merges all partitions
    /// so every FoldExecutor sees every entry regardless of which partition it landed in.
    pub fn commitRoute(self: *Sequencer, client_id: u64, client_seq_num: u64, submit: ValidatedSubmit) !SubmitResult {
        const seq = self.next_seq;
        const lpc = self.logPartitionCount();

        // Decay counters every 4096 commits to prevent stale bias.
        if (seq -% self.log_load_decay_seq >= 4096) {
            for (self.log_append_counts) |*c| c.* >>= 1;
            self.log_load_decay_seq = seq;
        }

        // Pick least-loaded partition; break ties by seq % lpc.
        const tiebreak: PartitionId = @intCast(seq % @as(Seq, lpc));
        var best: PartitionId = tiebreak;
        var best_count: u64 = self.log_append_counts[tiebreak];
        for (self.log_append_counts, 0..) |count, i| {
            if (count < best_count) {
                best = @intCast(i);
                best_count = count;
            }
        }
        const partition: PartitionId = best;
        self.log_append_counts[partition] += 1;
        const entry = OrderingEntry{
            .seq = seq,
            .partition = partition,
            .client_id = client_id,
            .client_seq = client_seq_num,
        };
        const decision = types_mod.EpochDecision{
            .epoch_num = self.next_epoch,
            .entries = &.{entry},
            .entry_kind = submit.entry_kind,
            .payload = submit.intent_payload,
        };
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
        self.next_epoch += 1;
        self.next_seq += 1;
        self.metrics.epochs_closed.inc();
        self.metrics.last_epoch_size.set(1);
        try self.flushOutputs(outputs.items, self.alloc);
        // Time-based commit-wait loop: replaces tick-based assert so replication
        // doesn't crash when quorum is lost after a proposal.
        var ts_now: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.MONOTONIC, &ts_now);
        const start_ns = @as(u64, @intCast(ts_now.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts_now.nsec));
        const deadline_ns = start_ns + COMMIT_WAIT_TIMEOUT_NS;
        var timeout_reached = false;
        while (self.raft.commit_index < ordering_seq) {
            try self.tickOnce(self.alloc);
            _ = std.os.linux.nanosleep(&.{ .sec = 0, .nsec = COMMIT_WAIT_SLEEP_NS }, null);
            _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.MONOTONIC, &ts_now);
            const elapsed_ns = @as(u64, @intCast(ts_now.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts_now.nsec));
            if (elapsed_ns >= deadline_ns) {
                std.log.warn("commitRoute: commit timeout after {}ms (commit_index={}, ordering_seq={})", .{
                    @divTrunc(elapsed_ns - start_ns, std.time.ns_per_ms),
                    self.raft.commit_index,
                    ordering_seq,
                });
                timeout_reached = true;
                break;
            }
        }
        if (timeout_reached) return SequencerError.CommitTimeout;
        try self.idempotency.record(client_id, client_seq_num, seq);
        // Ensure committed entries are written to partition logs before returning.
        self.applyCommitted(self.raft.commit_index, self.alloc) catch |err|
            std.log.warn("applyCommitted: {}", .{err});
        self.metrics.current_seq.set(@intCast(seq));
        return .{ .seq = seq, .partition = partition };
    }
};

/// Initialize the RaftNode and perform single-node self-election if no peers.
fn initRaftNode(cfg: Config, raft_log: *Log, alloc: std.mem.Allocator) !raft_mod.RaftNode {
    const tick_ms = if (cfg.tick_interval_ms == 0) 1 else cfg.tick_interval_ms;
    const election_min = @max(1, cfg.election_timeout_min_ms / tick_ms);
    const election_max = @max(1, cfg.election_timeout_max_ms / tick_ms);
    const heartbeat = @max(1, cfg.heartbeat_interval_ms / tick_ms);

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
            try raft_node.tick(raft_log, &outputs);
            outputs.clearRetainingCapacity();
            if (raft_node.role == .leader) break;
        }
    }

    return raft_node;
}

/// Allocate and initialize log partition logs at {base_path}/log_p{0..count-1}.
fn createPartitionLogs(base_path: []const u8, node_id: NodeId, count: u32, alloc: std.mem.Allocator) ![]Log {
    assert(count > 0);
    const logs = try alloc.alloc(Log, count);
    errdefer alloc.free(logs);
    var initialized: u32 = 0;
    errdefer for (logs[0..initialized]) |*pl| pl.deinit();

    for (0..count) |i| {
        const part_path = try std.fmt.allocPrint(alloc, "{s}/log_p{d}", .{ base_path, i });
        defer alloc.free(part_path);
        logs[i] = try Log.init_partitioned(part_path, node_id, @intCast(i), alloc);
        initialized += 1;
    }

    return logs;
}

fn readLastApplied(path: []const u8, out: *Seq) void {
    const pathz = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(pathz);
    @memcpy(pathz[0..path.len], path);
    const raw_fd = std.os.linux.open(pathz.ptr, .{ .ACCMODE = .RDONLY }, 0);
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return;
    const fd: std.posix.fd_t = @intCast(fd_i);
    defer _ = std.os.linux.close(@intCast(fd));
    var buf: [8]u8 = undefined;
    const n = std.os.linux.read(@intCast(fd), &buf, 8);
    const ni: isize = @bitCast(n);
    if (ni != 8) return;
    out.* = std.mem.readInt(u64, &buf, .little);
}

fn writeLastApplied(path: []const u8, seq: Seq) !void {
    const pathz = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(pathz);
    @memcpy(pathz[0..path.len], path);
    const raw_fd = std.os.linux.open(pathz.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return error.WriteError;
    const fd: std.posix.fd_t = @intCast(fd_i);
    defer _ = std.os.linux.close(@intCast(fd));
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, seq, .little);
    const w: isize = @bitCast(std.os.linux.write(@intCast(fd), &buf, 8));
    if (w != 8) return error.WriteError;
    // No fsync — this is a restart-optimisation checkpoint only. On crash the
    // sequencer replays from the Raft log, so a stale last_applied just means
    // replaying a few extra already-applied entries (idempotent).
}

/// Sequencer owner thread: drains the MPSC queue, drives Raft ticks, signals completions.
/// This loop is non-terminating by design — it exits only when shutdown is set via deinit().
fn runLoop(self: *Sequencer) void {
    const tick_ns: u64 = @as(u64, self.tick_interval_ms) * 1_000_000;
    // Apply any Raft entries already committed before this run started. This brings
    // next_seq up to the true Raft high-water mark before commitRoute can assign
    // new seqs, closing the window where a post-crash restart could reuse a seq from
    // a partially-written prior epoch.
    self.applyCommitted(self.raft.commit_index, self.alloc) catch |err|
        std.log.warn("startup catch-up: {}", .{err});
    while (!self.shutdown.load(.acquire)) {
        // Sample seq before pop — if a producer pushes between the failed pop and
        // waitForWork, the seq change causes waitForWork to return immediately.
        const seq = self.queue.currentSeq();

        // Drain all available entries into a batch. Multiple concurrent clients
        // sharing one Raft log sync is the primary throughput lever (group commit).
        var batch: [MAX_GROUP_COMMIT_SIZE]*types_mod.PendingSubmit = undefined;
        var n: usize = 0;
        while (n < MAX_GROUP_COMMIT_SIZE) {
            if (self.queue.pop()) |p| {
                batch[n] = p;
                n += 1;
            } else break;
        }

        if (n > 0) {
            commitBatch(self, batch[0..n]);
        } else {
            self.queue.waitForWork(seq, tick_ns);
            if (self.queue.currentSeq() == seq) {
                self.applyCommitted(self.raft.commit_index, self.alloc) catch |err|
                    std.log.warn("idle applyCommitted: {}", .{err});
            }
        }

        self.tickOnce(self.alloc) catch |err| std.log.warn("tick: {}", .{err});

        resolvePendingBatches(self);
    }
}

/// Maximum number of pending submits to drain into one group commit.
const MAX_GROUP_COMMIT_SIZE: u32 = 256;

/// Holds per-entry results accumulated during the append phase of commitBatch.
const BatchSlot = struct {
    pending: *types_mod.PendingSubmit,
    seq: Seq,
    partition: PartitionId,
};

/// A batch of entries proposed to Raft but not yet committed.
/// Resolved when commit_index >= max_ordering_seq.
const PendingBatch = struct {
    slots: []BatchSlot,
    max_ordering_seq: Seq,
};

/// Commit a batch of pending submits with one Raft log sync.
/// Each entry is appended to the Raft log individually (they may have different
/// payloads), but a single fdatasync covers all of them.
///
/// Pipelined path: after sync + flush, the batch is enqueued into pending_batches.
/// The runLoop resolves it once commit_index catches up, keeping the sequencer
/// thread free to process new submits during the Raft round-trip.
fn commitBatch(self: *Sequencer, batch: []*types_mod.PendingSubmit) void {
    assert(batch.len > 0 and batch.len <= MAX_GROUP_COMMIT_SIZE);

    var slots: [MAX_GROUP_COMMIT_SIZE]BatchSlot = undefined;
    var n_appended: usize = 0;
    var max_ordering_seq: Seq = 0;

    var shared_outputs: std.ArrayList(raft_mod.Output) = .empty;
    defer shared_outputs.deinit(self.alloc);

    for (batch) |p| {
        const result = appendOne(self, p.submit, &shared_outputs) catch |e| {
            p.err = e;
            p.markDone();
            continue;
        };
        // Record idempotency at propose time (seq assigned) so duplicate
        // submits in the same batch are deduped. This is safe because
        // next_seq is assigned once and never reused.
        self.idempotency.record(p.submit.client_id, p.submit.client_seq, result.seq) catch {};
        slots[n_appended] = .{ .pending = p, .seq = result.seq, .partition = result.partition };
        max_ordering_seq = result.ordering_seq;
        n_appended += 1;
    }

    if (n_appended == 0) return;

    // Phase 2: one durable Raft sync covers every entry appended above.
    self.raft_log.sync() catch {
        // Fsync failed — data is NOT durable. Do not commit.
        for (slots[0..n_appended]) |s| {
            s.pending.err = error.FsyncFailed;
            s.pending.markDone();
        }
        return;
    };

    // Check if already committed (single-node Raft often commits instantly).
    if (self.raft.commit_index >= max_ordering_seq) {
        for (slots[0..n_appended]) |s| {
            self.metrics.current_seq.set(@intCast(s.seq));
            s.pending.result = .{ .seq = s.seq, .partition = s.partition };
            s.pending.markDone();
        }
        return;
    }

    // Multi-node path: now that the appended entries are durable locally, send
    // Raft messages and process any committed outputs that were produced.
    self.flushOutputs(shared_outputs.items, self.alloc) catch |err|
        std.log.warn("flushOutputs: {}", .{err});

    // Enqueue into pending batches for async resolution by the runLoop.
    const heap_slots = self.alloc.alloc(BatchSlot, n_appended) catch {
        // Allocation failure: fall back to synchronous wait.
        syncWait(self, &slots, n_appended, max_ordering_seq);
        return;
    };
    @memcpy(heap_slots[0..n_appended], slots[0..n_appended]);

    self.pending_batches.append(self.alloc, PendingBatch{
        .slots = heap_slots,
        .max_ordering_seq = max_ordering_seq,
    }) catch {
        syncWait(self, &slots, n_appended, max_ordering_seq);
        return;
    };
}

/// Synchronous commit-wait fallback when the pipelined path cannot enqueue.
fn syncWait(self: *Sequencer, slots: *[MAX_GROUP_COMMIT_SIZE]BatchSlot, n_appended: usize, max_ordering_seq: Seq) void {
    var ts_now: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.MONOTONIC, &ts_now);
    const start_ns = @as(u64, @intCast(ts_now.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts_now.nsec));
    const deadline_ns = start_ns + COMMIT_WAIT_TIMEOUT_NS;
    while (self.raft.commit_index < max_ordering_seq) {
        self.tickOnce(self.alloc) catch |err| std.log.warn("tick: {}", .{err});
        _ = std.os.linux.nanosleep(&.{ .sec = 0, .nsec = COMMIT_WAIT_SLEEP_NS }, null);
        _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.MONOTONIC, &ts_now);
        const now_ns = @as(u64, @intCast(ts_now.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts_now.nsec));
        if (now_ns >= deadline_ns) {
            std.log.warn("syncWait: timeout after {}ms (commit_index={}, max_ordering_seq={})", .{
                @divTrunc(now_ns - start_ns, std.time.ns_per_ms),
                self.raft.commit_index,
                max_ordering_seq,
            });
            for (slots[0..n_appended]) |s| {
                s.pending.err = error.CommitTimeout;
                s.pending.markDone();
            }
            return;
        }
    }
    for (slots[0..n_appended]) |s| {
        self.metrics.current_seq.set(@intCast(s.seq));
        s.pending.result = .{ .seq = s.seq, .partition = s.partition };
        s.pending.markDone();
    }
}

/// Resolve any pending batches whose max_ordering_seq <= commit_index.
/// Called from the runLoop after tickOnce() to avoid blocking the sequencer.
fn resolvePendingBatches(self: *Sequencer) void {
    var write_idx: usize = 0;
    for (self.pending_batches.items, 0..) |pb, read_idx| {
        if (self.raft.commit_index >= pb.max_ordering_seq) {
            // Batch is committed — resolve all entries.
            for (pb.slots) |s| {
                self.metrics.current_seq.set(@intCast(s.seq));
                s.pending.result = .{ .seq = s.seq, .partition = s.partition };
                s.pending.markDone();
            }
            self.alloc.free(pb.slots);
        } else {
            // Not yet committed — compact to front.
            if (write_idx != read_idx) {
                self.pending_batches.items[write_idx] = self.pending_batches.items[read_idx];
            }
            write_idx += 1;
        }
    }
    self.pending_batches.shrinkRetainingCapacity(write_idx);
}

/// Assign a seq, pick a partition, serialize, and append to the Raft log without syncing.
/// Returns the ordering_seq assigned by Raft (for the commit-wait threshold).
const AppendResult = struct { seq: Seq, partition: PartitionId, ordering_seq: Seq };

fn appendOne(self: *Sequencer, submit: ValidatedSubmit, outputs: *std.ArrayList(raft_mod.Output)) !AppendResult {
    if (self.raft.role != .leader) {
        self.metrics.not_leader_errors.inc();
        return SequencerError.NotLeader;
    }
    self.metrics.intents_submitted.inc();

    // Idempotency fast path — signal immediately without appending.
    if (self.idempotency.lookup(submit.client_id, submit.client_seq)) |existing_seq| {
        self.metrics.dedup_hits.inc();
        const partition: PartitionId = @intCast(existing_seq % @as(Seq, self.logPartitionCount()));
        // Dedup entries still need a result but don't touch the Raft log.
        // Return a synthetic ordering_seq that is already committed.
        return .{ .seq = existing_seq, .partition = partition, .ordering_seq = self.raft.commit_index };
    }

    const seq = self.next_seq;
    const lpc = self.logPartitionCount();

    if (seq -% self.log_load_decay_seq >= 4096) {
        for (self.log_append_counts) |*c| c.* >>= 1;
        self.log_load_decay_seq = seq;
    }

    const tiebreak: PartitionId = @intCast(seq % @as(Seq, lpc));
    var best: PartitionId = tiebreak;
    var best_count: u64 = self.log_append_counts[tiebreak];
    for (self.log_append_counts, 0..) |count, i| {
        if (count < best_count) {
            best = @intCast(i);
            best_count = count;
        }
    }
    const partition: PartitionId = best;
    self.log_append_counts[partition] += 1;

    const entry = OrderingEntry{
        .seq = seq,
        .partition = partition,
        .client_id = submit.client_id,
        .client_seq = submit.client_seq,
    };
    const decision = types_mod.EpochDecision{
        .epoch_num = self.next_epoch,
        .entries = &.{entry},
        .entry_kind = submit.entry_kind,
        .payload = submit.intent_payload,
    };
    var payload_buf: std.ArrayList(u8) = .empty;
    defer payload_buf.deinit(self.alloc);
    try types_mod.serializeEpochDecision(decision, &payload_buf, self.alloc);

    const ordering_seq = try self.raft.proposeNoSync(
        &self.raft_log,
        .epoch_decision,
        payload_buf.items,
        outputs,
    ) orelse {
        self.metrics.not_leader_errors.inc();
        return SequencerError.NotLeader;
    };

    self.next_epoch += 1;
    self.next_seq += 1;
    self.metrics.epochs_closed.inc();
    self.metrics.last_epoch_size.set(1);

    return .{ .seq = seq, .partition = partition, .ordering_seq = ordering_seq };
}
