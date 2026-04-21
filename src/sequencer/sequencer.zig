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

pub const Seq = log_mod.Seq;
pub const PartitionId = log_mod.PartitionId;
pub const NodeId = log_mod.NodeId;
pub const EpochNum = types_mod.EpochNum;
pub const EpochDecision = types_mod.EpochDecision;
pub const OrderingEntry = types_mod.OrderingEntry;
pub const SubmitResult = types_mod.SubmitResult;
pub const SubmitHandle = types_mod.SubmitHandle;
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
    /// Peer nodes in the Raft group. Empty → single-node, self-elects immediately.
    peers: []const PeerAddr = &.{},
};

pub const SequencerError = error{
    NotLeader,
    PartitionError,
    SerializeError,
};

/// The Sequencer: global ordering for TxnIntents across partition logs.
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
        };
    }

    pub fn deinit(self: *Sequencer) void {
        self.raft.deinit();
        self.raft_log.deinit();
        std.heap.page_allocator.free(self.raft_path);
        for (self.partition_logs) |*pl| pl.deinit();
        self.alloc.free(self.partition_logs);
        self.batcher.deinit();
        self.idempotency.deinit();
    }

    pub fn currentSeq(self: *const Sequencer) Seq {
        return self.next_seq - 1;
    }

    pub fn partitionCount(self: *const Sequencer) u32 {
        return @intCast(self.partition_logs.len);
    }

    /// Return a pointer to the log for the given partition (for reading committed entries).
    pub fn partitionLog(self: *Sequencer, partition: PartitionId) *Log {
        return &self.partition_logs[partition];
    }

    /// Domain boundary — accepts raw gateway input and wraps it in a ValidatedSubmit
    /// before handing off to the sequencer core. The intent_payload is opaque here;
    /// TxnIntent structural validation happened at the gateway before this call.
    /// Infallible — errors surface when the caller calls awaitCommit() on the handle.
    /// Idempotent on (client_id, client_seq_num).
    pub fn submitBytes(
        self: *Sequencer,
        io: std.Io,
        intent_payload: []const u8,
        client_id: u64,
        client_seq_num: u64,
    ) SubmitHandle {
        // This is the domain boundary — external gateway data enters the sequencer here.
        const validated = ValidatedSubmit{
            .client_id = client_id,
            .client_seq = client_seq_num,
            .intent_payload = intent_payload,
        };
        return .{ .future = io.async(doCommit, .{ self, validated }) };
    }
};

/// Free function passed to io.async — contains all durable commit work.
/// Receives a ValidatedSubmit: all external data validation happened at the boundary
/// (submitBytes). This function is pure domain logic: idempotency, batching, seq
/// assignment, Raft replication of ordering decisions, and data log writes.
/// For M7 single-node io.async executes this synchronously; future milestones block here on
/// multi-node Raft round-trips.
fn doCommit(sequencer: *Sequencer, submit: ValidatedSubmit) anyerror!SubmitResult {
    sequencer.metrics.intents_submitted.inc();

    const client_id = submit.client_id;
    const client_seq_num = submit.client_seq;

    // Idempotency fast path
    if (sequencer.idempotency.lookup(client_id, client_seq_num)) |existing_seq| {
        sequencer.metrics.dedup_hits.inc();
        const partition: PartitionId = @intCast(existing_seq % @as(Seq, sequencer.partition_logs.len));
        return .{ .seq = existing_seq, .partition = partition };
    }

    // Single-entry epoch (M7 synchronous mode)
    try sequencer.batcher.submit(client_id, client_seq_num);

    const decision = try sequencer.batcher.closeEpoch(
        sequencer.next_epoch,
        sequencer.next_seq,
        @intCast(sequencer.partition_logs.len),
        sequencer.alloc,
    );
    defer sequencer.alloc.free(decision.entries);

    sequencer.next_epoch += 1;
    sequencer.next_seq += @intCast(decision.entries.len);
    sequencer.metrics.epochs_closed.inc();
    sequencer.metrics.last_epoch_size.set(@intCast(decision.entries.len));

    // Replicate ordering decision via Raft
    var payload_buf: std.ArrayList(u8) = .empty;
    defer payload_buf.deinit(sequencer.alloc);
    try types_mod.serializeEpochDecision(decision, &payload_buf, sequencer.alloc);

    var outputs: std.ArrayList(raft_mod.Output) = .empty;
    defer outputs.deinit(sequencer.alloc);

    const ordering_seq = try sequencer.raft.propose(
        &sequencer.raft_log,
        .epoch_decision,
        payload_buf.items,
        &outputs,
    ) orelse {
        sequencer.metrics.not_leader_errors.inc();
        return SequencerError.NotLeader;
    };
    _ = ordering_seq;

    for (outputs.items) |output| {
        switch (output) {
            .persist => |p| {
                raft_mod.savePersistentState(
                    sequencer.raft_path,
                    sequencer.alloc,
                    p.term,
                    p.voted_for,
                ) catch {};
            },
            else => {},
        }
    }

    // Sequencer→data-log boundary: write the opaque intent payload at the assigned
    // global seq. Raft replicated only the ordering decision above; the intent bytes
    // are written here directly to the data partition log.
    const entry = decision.entries[0]; // single-entry epoch
    const partition_log = &sequencer.partition_logs[entry.partition];
    const log_entry = LogEntry.create(entry.seq, 0, .txn_intent, submit.intent_payload);
    try partition_log.appendEntryAt(log_entry);

    try sequencer.idempotency.record(client_id, client_seq_num, entry.seq);
    sequencer.metrics.current_seq.set(@intCast(entry.seq));

    return .{ .seq = entry.seq, .partition = entry.partition };
}
