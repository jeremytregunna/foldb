/// Per-subsystem metrics structs.
///
/// Each struct is a plain value (no allocations). Embed one in each subsystem
/// and update it on hot paths. The zero-value is valid (all counters/gauges
/// start at 0, histograms empty).
///
/// Spec §13.4 requirements covered:
///   - current_seq — what seq has this subsystem processed up to
///   - lag         — seq behind the log head
///   - throughput  — entries/sec, bytes/sec (counters, caller computes rate)
///   - latency     — histograms at p50/p99/p99.9
const metrics = @import("metrics.zig");

pub const Counter = metrics.Counter;
pub const Gauge = metrics.Gauge;
pub const Histogram = metrics.Histogram;

// ---------------------------------------------------------------------------
// Log subsystem
// ---------------------------------------------------------------------------

pub const LogMetrics = struct {
    /// Total entries appended (includes all kinds).
    entries_appended: Counter = .{},
    /// Total payload bytes written.
    bytes_appended: Counter = .{},
    /// fsync calls issued.
    fsync_count: Counter = .{},
    /// Segment rotations (current segment sealed, new one opened).
    segments_rotated: Counter = .{},
    /// Prefix truncations performed.
    truncations: Counter = .{},
    /// Total entries returned by read() calls.
    entries_read: Counter = .{},
    /// Total payload bytes returned by read() calls.
    bytes_read: Counter = .{},
    /// Highest seq durably in the log.
    current_seq: Gauge = .{},
    /// Entries in the log not yet applied by the local executor.
    lag: Gauge = .{},
    /// End-to-end append latency (from append() call to return), nanoseconds.
    append_latency: Histogram = .{},

    pub fn reset(self: *LogMetrics) void {
        self.entries_appended.reset();
        self.bytes_appended.reset();
        self.fsync_count.reset();
        self.segments_rotated.reset();
        self.truncations.reset();
        self.entries_read.reset();
        self.bytes_read.reset();
        self.append_latency.reset();
        // Gauges are not reset — they reflect current state.
    }
};

// ---------------------------------------------------------------------------
// Storage subsystem
// ---------------------------------------------------------------------------

pub const StorageMetrics = struct {
    /// Total get() calls.
    gets: Counter = .{},
    /// get() calls that missed all caches (went to disk/object store).
    get_misses: Counter = .{},
    /// Total apply() calls (batches of mutations).
    applies: Counter = .{},
    /// Total individual mutation records applied.
    mutations_applied: Counter = .{},
    /// LSM compaction runs completed.
    compactions: Counter = .{},
    /// Block cache hits.
    block_cache_hits: Counter = .{},
    /// Block cache misses.
    block_cache_misses: Counter = .{},
    /// Snapshots uploaded to object storage.
    snapshots_taken: Counter = .{},
    /// Total scan() calls issued.
    scans: Counter = .{},
    /// Total rows returned across all scan() calls.
    scan_rows_returned: Counter = .{},
    /// Highest seq visible in storage (applied up to here).
    current_seq: Gauge = .{},
    /// get() latency in nanoseconds.
    get_latency: Histogram = .{},
    /// apply() latency in nanoseconds (per batch).
    apply_latency: Histogram = .{},
};

// ---------------------------------------------------------------------------
// Executor subsystem
// ---------------------------------------------------------------------------

pub const ExecutorMetrics = struct {
    /// Transactions successfully executed (ok result).
    txns_ok: Counter = .{},
    /// Transactions aborted (constraint violation or retry marker).
    txns_aborted: Counter = .{},
    /// Total rows affected across all successful transactions.
    rows_affected: Counter = .{},
    /// Noop log entries processed (heartbeats / gap fillers).
    noops_processed: Counter = .{},
    /// Transactions aborted because the query hash was not registered.
    txns_missing_query: Counter = .{},
    /// Highest seq the executor has processed.
    current_seq: Gauge = .{},
    /// Seq behind the log head (how far behind the executor is).
    lag: Gauge = .{},
    /// Per-transaction execution latency (from run() call to return), nanoseconds.
    exec_latency: Histogram = .{},
};

// ---------------------------------------------------------------------------
// Sequencer subsystem
// ---------------------------------------------------------------------------

pub const SequencerMetrics = struct {
    /// TxnIntents accepted via submit().
    intents_submitted: Counter = .{},
    /// Epochs closed (each epoch = one ordering decision batch).
    epochs_closed: Counter = .{},
    /// Total intents that were idempotency-deduplicated (already seen client_seq).
    dedup_hits: Counter = .{},
    /// Intents that failed because the sequencer was not the leader.
    not_leader_errors: Counter = .{},
    /// Latest global seq assigned by this sequencer.
    current_seq: Gauge = .{},
    /// Average batch size of the last epoch (updated at each epoch close).
    last_epoch_size: Gauge = .{},
};

// ---------------------------------------------------------------------------
// Gateway subsystem
// ---------------------------------------------------------------------------

pub const GatewayMetrics = struct {
    /// SQL queries registered.
    queries_registered: Counter = .{},
    /// execute() calls.
    queries_executed: Counter = .{},
    /// Transactions that ended in an abort visible to the client.
    queries_aborted: Counter = .{},
    /// Nondeterministic values resolved (NOW/RANDOM/UUID calls).
    nondet_resolved: Counter = .{},
    /// Reconnaissance retries (read-set mismatch required re-execution).
    recon_retries: Counter = .{},
    /// End-to-end execute() latency (from client call to result), nanoseconds.
    exec_latency: Histogram = .{},
};

// ---------------------------------------------------------------------------
// Raft subsystem
// ---------------------------------------------------------------------------

pub const RaftMetrics = struct {
    /// Election attempts started (term increments).
    elections_started: Counter = .{},
    /// Times this node won an election and became leader.
    leadership_won: Counter = .{},
    /// Times this node stepped down from leader to follower.
    leadership_lost: Counter = .{},
    /// Total log entries replicated to peers (AppendEntries payloads sent).
    entries_replicated: Counter = .{},
    /// Heartbeat broadcasts emitted while leader.
    heartbeats_sent: Counter = .{},
    /// Current Raft term.
    current_term: Gauge = .{},
    /// 1 if this node is currently leader, 0 otherwise.
    is_leader: Gauge = .{},
};

// ---------------------------------------------------------------------------
// CDC subsystem
// ---------------------------------------------------------------------------

pub const CdcMetrics = struct {
    /// Total CdcEvents emitted across all subscriptions.
    events_emitted: Counter = .{},
    /// Total CdcEffects (individual row changes) emitted.
    effects_total: Counter = .{},
    /// Before-images captured prior to storage.apply() calls.
    before_images_captured: Counter = .{},
    /// Current number of active subscriptions.
    subscriptions_active: Gauge = .{},
};
