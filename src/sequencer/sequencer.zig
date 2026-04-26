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
pub const PeerAddr = struct {
    id: NodeId,
    addr: []const u8, // "host:port"
};

/// Sequencer config.
pub const Config = struct {
    /// Number of data partition logs.
    partition_count: u32 = 1,
    /// Max intents per epoch before forcing a close.
    max_epoch_size: u32 = epoch_mod.DEFAULT_MAX_BATCH_SIZE,
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

/// Sleep duration per iteration of the commit-wait loop (1 ms in nanoseconds).
const COMMIT_WAIT_SLEEP_NS: u32 = 1_000_000;
/// Maximum iterations of the commit-wait loop before asserting.
/// Prevents infinite looping when quorum is lost after a proposal.
const COMMIT_WAIT_MAX_TICKS: u32 = 10_000;

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
    queue: mpsc_mod.MpscQueue(types_mod.PendingSubmit),
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
        assert(base_path.len > 0);
        assert(cfg.partition_count > 0);

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

        var persisted_last_applied: Seq = 0;
        readLastApplied(last_applied_path, &persisted_last_applied);

        const seq_partition_id: PartitionId = std.math.maxInt(PartitionId);
        var raft_log = try Log.init_partitioned(raft_path, cfg.node_id, seq_partition_id, alloc);
        errdefer raft_log.deinit();

        var raft_node = try initRaftNode(cfg, &raft_log, alloc);
        errdefer raft_node.deinit();

        const partition_logs = try initPartitionLogs(base_path, cfg.node_id, cfg.partition_count, alloc);
        errdefer {
            for (partition_logs) |*pl| pl.deinit();
            alloc.free(partition_logs);
        }

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
            .next_seq = max_seq + 1,
            .next_epoch = 1,
            .alloc = alloc,
            .transport = transport,
            .tick_interval_ms = cfg.tick_interval_ms,
            .last_applied = persisted_last_applied,
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
        self.shutdown.store(true, .release);
        self.queue.wakeConsumer();
        if (self.thread) |t| t.join();
        self.raft.deinit();
        self.raft_log.deinit();
        self.alloc.free(self.raft_path);
        self.alloc.free(self.last_applied_path);
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
                                assert(oe.partition < self.partition_logs.len);
                                const pl = &self.partition_logs[oe.partition];
                                const le = LogEntry.create(oe.seq, 0, dec.entry_kind, dec.payload);
                                try pl.append_entry_at(le);
                            }
                            // Notify after all entries in the batch are written, so FoldExecutor
                            // does not wake mid-batch and race with concurrent writes.
                            for (dec.entries) |oe| {
                                self.partition_logs[oe.partition].notifyAppend();
                            }
                        }
                        self.last_applied = idx;
                    }
                    try writeLastApplied(self.last_applied_path, self.last_applied);
                },
                // Raft peer list is already updated internally by RaftNode when this fires.
                // Transport was pre-registered in addNode / cleaned up in removeNode.
                .apply_config => {},
            }
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

/// Allocate and initialize all partition logs. Caller owns the returned slice.
fn initPartitionLogs(base_path: []const u8, node_id: NodeId, count: u32, alloc: std.mem.Allocator) ![]Log {
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
    const s: isize = @bitCast(std.os.linux.fsync(@intCast(fd)));
    if (s < 0) return error.FsyncError;
}

/// Sequencer owner thread: drains the MPSC queue, drives Raft ticks, signals completions.
/// This loop is non-terminating by design — it exits only when shutdown is set via deinit().
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

        self.tickOnce(self.alloc) catch |err| std.log.warn("tick: {}", .{err});
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
    // Return NotLeader rather than asserting: a stepdown between processCommit's
    // caller check and here must produce a recoverable error, not a crash.
    if (self.raft.role != .leader) return SequencerError.NotLeader;
    self.metrics.intents_submitted.inc();

    const client_id = submit.client_id;
    const client_seq_num = submit.client_seq;

    // Idempotency fast path
    if (self.idempotency.lookup(client_id, client_seq_num)) |existing_seq| {
        self.metrics.dedup_hits.inc();
        const partition: PartitionId = @intCast(existing_seq % @as(Seq, self.partition_logs.len));
        return .{ .seq = existing_seq, .partition = partition };
    }

    // All txn_intent and schema_change entries broadcast to all partition logs using
    // sequential routing so every FoldExecutor maintains a consistent view.
    return commitBroadcast(self, client_id, client_seq_num, submit);
}

/// Broadcast an entry to all partition logs using sequential routing: entry i → partition i.
/// Used for both schema_change and txn_intent so every FoldExecutor processes every txn.
fn commitBroadcast(self: *Sequencer, client_id: u64, client_seq_num: u64, submit: ValidatedSubmit) !SubmitResult {
    const n: u32 = @intCast(self.partition_logs.len);
    const entries = try self.alloc.alloc(OrderingEntry, n);
    defer self.alloc.free(entries);
    for (0..n) |i| {
        const seq = self.next_seq + @as(Seq, i);
        entries[i] = .{
            .seq = seq,
            .partition = @intCast(i),
            .client_id = client_id,
            .client_seq = client_seq_num,
        };
    }
    const decision = types_mod.EpochDecision{
        .epoch_num = self.next_epoch,
        .entries = entries,
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
    self.next_seq += @intCast(n);
    self.metrics.epochs_closed.inc();
    self.metrics.last_epoch_size.set(@intCast(n));
    try self.flushOutputs(outputs.items, self.alloc);
    const wait_ts: std.os.linux.timespec = .{ .sec = 0, .nsec = COMMIT_WAIT_SLEEP_NS };
    var wait_ticks: u32 = 0;
    while (self.raft.commit_index < ordering_seq) {
        assert(wait_ticks < COMMIT_WAIT_MAX_TICKS);
        wait_ticks += 1;
        try self.tickOnce(self.alloc);
        _ = std.os.linux.nanosleep(&wait_ts, null);
    }
    const last_entry = entries[n - 1];
    try self.idempotency.record(client_id, client_seq_num, last_entry.seq);
    self.metrics.current_seq.set(@intCast(last_entry.seq));
    return .{ .seq = last_entry.seq, .partition = last_entry.partition };
}
