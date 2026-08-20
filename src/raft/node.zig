/// Pure Raft state machine — no network I/O, no wall-clock timers.
///
/// All external effects are expressed as Output values appended to the caller's
/// ArrayList. The caller (simulation or cluster driver) processes outputs and
/// feeds responses back via handle* methods.
///
/// Timing is tick-based: call tick() periodically. Election timeouts are
/// randomised at init time using a caller-supplied seed for determinism.
///
/// Log I/O (disk reads/writes) happens inside handle* and tick methods because
/// disk access is fast, deterministic, and required for correctness checks
/// (prevLogTerm, conflict detection). Network and timer I/O do not occur here.
const std = @import("std");
const log_mod = @import("log.zig");
const types = @import("types.zig");
const rpc = @import("rpc.zig");
const obs = @import("observability.zig");

const assert = std.debug.assert;

const Log = log_mod.Log;
const LogEntry = log_mod.LogEntry;
const Seq = log_mod.Seq;
const NodeId = log_mod.NodeId;
pub const Term = types.Term;
pub const RaftRole = types.RaftRole;
const AppendEntriesArgs = rpc.AppendEntriesArgs;
const AppendEntriesResult = rpc.AppendEntriesResult;
const RequestVoteArgs = rpc.RequestVoteArgs;
const RequestVoteResult = rpc.RequestVoteResult;
const Message = rpc.Message;

/// Re-export config change types for callers.
pub const ConfigChangeOp = log_mod.ConfigChangeOp;
pub const ConfigChange = log_mod.ConfigChange;

/// Carries all fields of an in-progress config change as a single unit.
/// Replaces the three separate pending_config_* fields to enforce the invariant
/// that op and peer_id are always present whenever a pending config exists.
const PendingConfigChange = struct {
    seq: Seq,
    op: ConfigChangeOp,
    peer_id: NodeId,
};

/// Effects the caller must process after each state machine step.
pub const Output = union(enum) {
    /// Send a message to a peer node.
    send: struct { to: NodeId, msg: Message },
    /// All entries up to and including this seq are committed (safe to serve reads).
    committed: Seq,
    /// Persist term + voted_for to stable storage before sending any messages.
    persist: struct { term: Term, voted_for: ?NodeId },
    /// Leader wants the caller to read entries from_index..limit from the log
    /// and deliver them as an AppendEntries to 'to'. Decouples log reads from
    /// the state machine so the SM stays allocation-free on the happy path.
    send_entries: struct {
        to: NodeId,
        term: Term,
        leader_id: NodeId,
        prev_log_index: Seq,
        prev_log_term: Term,
        from_index: Seq,
        leader_commit: Seq,
    },
    /// A config_change entry committed; caller must ensure the new node (if any)
    /// is wired into the cluster transport layer.
    apply_config: struct { seq: Seq, op: ConfigChangeOp, peer_id: NodeId },
};

const PeerState = struct {
    id: NodeId,
    next_index: Seq,
    match_index: Seq,
    // Candidate phase
    vote_responded: bool,
    vote_granted: bool,
};

pub const Config = struct {
    /// Minimum election timeout in ticks.
    election_timeout_min: u32 = 10,
    /// Maximum election timeout in ticks.
    election_timeout_max: u32 = 20,
    /// Heartbeat interval in ticks (must be << election_timeout_min).
    heartbeat_interval: u32 = 3,
    /// Max entries per AppendEntries batch.
    max_append_batch: u32 = 64,
};

/// Returns the minimum number of votes required for a majority decision
/// in a cluster of `cluster_size` voters (peers + self).
fn quorumSize(cluster_size: usize) usize {
    assert(cluster_size > 0);
    return cluster_size / 2 + 1;
}

pub const RaftNode = struct {
    allocator: std.mem.Allocator,
    id: NodeId,
    peers: []PeerState,
    role: RaftRole,
    current_term: Term,
    voted_for: ?NodeId,
    commit_index: Seq,
    votes_for_me: u32,
    cfg: Config,
    election_ticks: u32,
    election_timeout: u32,
    heartbeat_ticks: u32,
    prng: std.Random.Xoroshiro128,
    metrics: obs.RaftMetrics = .{},
    /// In-progress config change, set when a config_change entry is appended and
    /// cleared when it commits or when the node steps down. Null means none pending.
    pending_config: ?PendingConfigChange = null,
    /// During joint consensus (leader only): peer IDs in the new config (heap-owned).
    joint_config_peer_ids: ?[]NodeId = null,
    /// During joint consensus (leader only): PeerState for genuinely new nodes (heap-owned).
    new_peer_states: ?[]PeerState = null,

    pub fn init(
        allocator: std.mem.Allocator,
        id: NodeId,
        peer_ids: []const NodeId,
        cfg: Config,
        seed: u64,
    ) !RaftNode {
        assert(id > 0);
        assert(peer_ids.len < 256); // practical Raft cluster bound; quorum safety
        assert(cfg.election_timeout_max > cfg.election_timeout_min);
        // For multi-node clusters, heartbeat must fire before any follower times out.
        // Single-node clusters (no peers) self-elect immediately; heartbeat timing is irrelevant.
        if (peer_ids.len > 0) assert(cfg.heartbeat_interval < cfg.election_timeout_min);
        const peers = try allocator.alloc(PeerState, peer_ids.len);
        for (peer_ids, 0..) |pid, i| {
            peers[i] = .{
                .id = pid,
                .next_index = 1,
                .match_index = 0,
                .vote_responded = false,
                .vote_granted = false,
            };
        }
        var prng = std.Random.Xoroshiro128.init(seed);
        const timeout = randomElectionTimeout(&prng, cfg);
        return RaftNode{
            .allocator = allocator,
            .id = id,
            .peers = peers,
            .role = .follower,
            .current_term = 0,
            .voted_for = null,
            .commit_index = 0,
            .votes_for_me = 0,
            .cfg = cfg,
            .election_ticks = 0,
            .election_timeout = timeout,
            .heartbeat_ticks = 0,
            .prng = prng,
        };
    }

    pub fn deinit(self: *RaftNode) void {
        self.allocator.free(self.peers);
        if (self.joint_config_peer_ids) |ids| self.allocator.free(ids);
        if (self.new_peer_states) |nps| self.allocator.free(nps);
    }

    // -----------------------------------------------------------------------
    // Timing
    // -----------------------------------------------------------------------

    /// Advance one tick. Fires election or heartbeat timer when thresholds are reached.
    pub fn tick(self: *RaftNode, log: *Log, out: *std.ArrayList(Output)) !void {
        switch (self.role) {
            .follower, .candidate => {
                self.election_ticks += 1;
                if (self.election_ticks >= self.election_timeout) {
                    try self.startElection(log, out);
                }
            },
            .leader => {
                self.heartbeat_ticks += 1;
                if (self.heartbeat_ticks >= self.cfg.heartbeat_interval) {
                    self.heartbeat_ticks = 0;
                    try self.broadcastAppendEntries(log, out);
                }
            },
        }
    }

    // -----------------------------------------------------------------------
    // Client interface
    // -----------------------------------------------------------------------

    /// Leader appends a new entry and broadcasts to peers.
    /// Returns the assigned seq, or null if this node is not the leader.
    pub fn propose(
        self: *RaftNode,
        log: *Log,
        kind: log_mod.EntryKind,
        payload: []const u8,
        out: *std.ArrayList(Output),
    ) !?Seq {
        return self.proposeInternal(log, kind, payload, out, true);
    }

    /// Leader appends a new entry and broadcasts to peers without syncing the log.
    /// Caller must sync the Raft log before treating the returned sequence as durable.
    pub fn proposeNoSync(
        self: *RaftNode,
        log: *Log,
        kind: log_mod.EntryKind,
        payload: []const u8,
        out: *std.ArrayList(Output),
    ) !?Seq {
        return self.proposeInternal(log, kind, payload, out, false);
    }

    fn proposeInternal(
        self: *RaftNode,
        log: *Log,
        kind: log_mod.EntryKind,
        payload: []const u8,
        out: *std.ArrayList(Output),
        sync: bool,
    ) !?Seq {
        if (self.role != .leader) return null;

        const seq = (try log.head()) + 1;
        const entry = LogEntry.create(seq, self.current_term, kind, payload);
        try log.append_entry(entry);
        if (sync) try log.sync();

        // Update our own match_index conceptually (handled via head() in checkCommit).
        try self.broadcastAppendEntries(log, out);
        return seq;
    }

    /// Leader initiates a membership change using joint consensus.
    /// Returns the seq of the config_change entry, or null if not leader or
    /// another config change is already in progress.
    pub fn proposeConfigChange(
        self: *RaftNode,
        log: *Log,
        op: ConfigChangeOp,
        peer_id: NodeId,
        out: *std.ArrayList(Output),
    ) !?Seq {
        if (self.role != .leader) return null;
        if (self.pending_config != null) return null;

        // Build new peer ID list and PeerState for genuinely new nodes.
        const head = try log.head();
        switch (op) {
            .add_voter => {
                const new_ids = try self.allocator.alloc(NodeId, self.peers.len + 1);
                for (self.peers, 0..) |p, i| new_ids[i] = p.id;
                new_ids[self.peers.len] = peer_id;
                self.joint_config_peer_ids = new_ids;

                const nps = try self.allocator.alloc(PeerState, 1);
                nps[0] = .{ .id = peer_id, .next_index = head + 1, .match_index = 0, .vote_responded = false, .vote_granted = false };
                self.new_peer_states = nps;
            },
            .remove_voter => {
                var count: usize = 0;
                for (self.peers) |p| {
                    if (p.id != peer_id) count += 1;
                }
                const new_ids = try self.allocator.alloc(NodeId, count);
                var i: usize = 0;
                for (self.peers) |p| {
                    if (p.id != peer_id) {
                        new_ids[i] = p.id;
                        i += 1;
                    }
                }
                self.joint_config_peer_ids = new_ids;
                // No new peer states for removal.
            },
        }

        const cc = ConfigChange{ .op = op, .node_id = peer_id };
        const cc_payload = cc.serialize();
        const seq = head + 1;
        const entry = LogEntry.create(seq, self.current_term, .config_change, &cc_payload);
        try log.append_entry(entry);
        try log.sync();

        self.pending_config = .{ .seq = seq, .op = op, .peer_id = peer_id };

        try self.broadcastAppendEntries(log, out);
        return seq;
    }

    // -----------------------------------------------------------------------
    // Message handlers
    // -----------------------------------------------------------------------

    pub fn handleAppendEntries(
        self: *RaftNode,
        log: *Log,
        args: AppendEntriesArgs,
        out: *std.ArrayList(Output),
    ) !void {
        // Stale term — reject.
        if (args.term < self.current_term) {
            try out.append(self.allocator, .{ .send = .{ .to = args.leader_id, .msg = .{ .append_entries_result = .{
                .term = self.current_term,
                .success = false,
                .match_index = 0,
            } } } });
            return;
        }

        // Higher term — update and become follower.
        if (args.term > self.current_term) {
            try self.stepDown(args.term, out);
        } else {
            // Same term: if we were candidate, leader won the election.
            if (self.role == .candidate) self.role = .follower;
        }

        // Reset election timer on valid leader contact.
        self.election_ticks = 0;

        const consistent = try self.handleAppendEntriesCheckLog(log, args, out);
        if (!consistent) return;

        const replicated = try self.handleAppendEntriesApplyEntries(log, args);
        if (replicated > 0) {
            try log.sync();
            self.metrics.entries_replicated.add(replicated);
        }

        // Advance commit index.
        const new_head = try log.head();
        if (args.leader_commit > self.commit_index) {
            const new_commit = @min(args.leader_commit, new_head);
            if (new_commit > self.commit_index) {
                self.commit_index = new_commit;
                try out.append(self.allocator, .{ .committed = self.commit_index });
                try self.maybeApplyConfig(out);
            }
        }

        try out.append(self.allocator, .{ .send = .{ .to = args.leader_id, .msg = .{ .append_entries_result = .{
            .term = self.current_term,
            .success = true,
            .match_index = new_head,
        } } } });
    }

    /// Verify prev_log_index consistency. Sends a failure AppendEntriesResult and
    /// returns false when the follower's log does not match the leader's prefix.
    fn handleAppendEntriesCheckLog(
        self: *RaftNode,
        log: *Log,
        args: AppendEntriesArgs,
        out: *std.ArrayList(Output),
    ) !bool {
        if (args.prev_log_index == 0) return true;

        const our_head = try log.head();
        if (our_head < args.prev_log_index) {
            try out.append(self.allocator, .{ .send = .{ .to = args.leader_id, .msg = .{ .append_entries_result = .{
                .term = self.current_term,
                .success = false,
                .match_index = our_head,
            } } } });
            return false;
        }

        const our_term = try log.term_at(args.prev_log_index, self.allocator);
        if (our_term != args.prev_log_term) {
            // Conflict: truncate back to prev_log_index so leader can retry.
            try log.truncate_suffix(args.prev_log_index);
            try out.append(self.allocator, .{ .send = .{ .to = args.leader_id, .msg = .{ .append_entries_result = .{
                .term = self.current_term,
                .success = false,
                .match_index = (try log.head()),
            } } } });
            return false;
        }

        return true;
    }

    /// Append new entries from args, skipping already-present matching entries
    /// and truncating on conflict. Updates pending_config for config_change entries.
    /// Returns the count of entries actually appended to the log.
    fn handleAppendEntriesApplyEntries(self: *RaftNode, log: *Log, args: AppendEntriesArgs) !u64 {
        var replicated: u64 = 0;
        for (args.entries) |entry| {
            const our_head = try log.head();
            if (entry.header.seq <= our_head) {
                const our_term = try log.term_at(entry.header.seq, self.allocator);
                if (our_term == entry.header.epoch) continue; // already have it
                // Conflict: truncate and clear any pending config change at or after this seq.
                try log.truncate_suffix(entry.header.seq);
                if (self.pending_config) |pc| {
                    if (pc.seq >= entry.header.seq) self.pending_config = null;
                }
            }
            try log.append_entry(entry);
            replicated += 1;
            // Domain boundary — decode config_change payload from the replication stream.
            if (entry.header.kind == .config_change and self.pending_config == null) {
                const cc = try ConfigChange.deserialize(entry.payload);
                self.pending_config = .{ .seq = entry.header.seq, .op = cc.op, .peer_id = cc.node_id };
            }
        }
        return replicated;
    }

    pub fn handleAppendEntriesResult(
        self: *RaftNode,
        log: *Log,
        from: NodeId,
        result: AppendEntriesResult,
        out: *std.ArrayList(Output),
    ) !void {
        if (self.role != .leader) return;

        if (result.term > self.current_term) {
            try self.stepDown(result.term, out);
            return;
        }

        const peer = self.findPeer(from) orelse return;

        if (result.success) {
            if (result.match_index > peer.match_index) {
                peer.match_index = result.match_index;
                peer.next_index = result.match_index + 1;
            }
            try self.checkCommit(log, out);
        } else {
            // Back off next_index and retry.
            if (result.match_index > 0 and result.match_index < peer.next_index) {
                peer.next_index = result.match_index + 1;
            } else if (peer.next_index > 1) {
                peer.next_index -= 1;
            }
            try self.emitSendEntries(log, peer, out);
        }
    }

    pub fn handleRequestVote(
        self: *RaftNode,
        log: *Log,
        args: RequestVoteArgs,
        out: *std.ArrayList(Output),
    ) !void {
        if (args.term < self.current_term) {
            try out.append(self.allocator, .{ .send = .{ .to = args.candidate_id, .msg = .{ .request_vote_result = .{
                .term = self.current_term,
                .vote_granted = false,
            } } } });
            return;
        }

        if (args.term > self.current_term) {
            try self.stepDown(args.term, out);
        }

        const can_vote = (self.voted_for == null or self.voted_for == args.candidate_id);
        const up_to_date = try self.candidateLogIsUpToDate(log, args.last_log_index, args.last_log_term);

        const grant = can_vote and up_to_date;
        if (grant) {
            self.voted_for = args.candidate_id;
            self.election_ticks = 0;
            try out.append(self.allocator, .{ .persist = .{ .term = self.current_term, .voted_for = args.candidate_id } });
        }

        try out.append(self.allocator, .{ .send = .{ .to = args.candidate_id, .msg = .{ .request_vote_result = .{
            .term = self.current_term,
            .vote_granted = grant,
        } } } });
    }

    pub fn handleRequestVoteResult(
        self: *RaftNode,
        log: *Log,
        from: NodeId,
        result: RequestVoteResult,
        out: *std.ArrayList(Output),
    ) !void {
        if (self.role != .candidate) return;

        if (result.term > self.current_term) {
            try self.stepDown(result.term, out);
            return;
        }

        const peer = self.findPeer(from) orelse return;
        if (peer.vote_responded) return;
        peer.vote_responded = true;
        peer.vote_granted = result.vote_granted;

        if (result.vote_granted) {
            self.votes_for_me += 1;
            if (self.votes_for_me >= quorumSize(self.peers.len + 1)) {
                try self.becomeLeader(log, out);
            }
        }
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    fn startElection(self: *RaftNode, log: *Log, out: *std.ArrayList(Output)) !void {
        self.current_term += 1;
        self.role = .candidate;
        self.voted_for = self.id;
        self.votes_for_me = 1;
        self.election_ticks = 0;
        self.election_timeout = randomElectionTimeout(&self.prng, self.cfg);
        self.metrics.elections_started.inc();
        self.metrics.current_term.set(@intCast(self.current_term));
        // Abandon any in-progress config change — the new leader must re-propose it.
        self.pending_config = null;
        if (self.joint_config_peer_ids) |ids| {
            self.allocator.free(ids);
            self.joint_config_peer_ids = null;
        }
        if (self.new_peer_states) |nps| {
            self.allocator.free(nps);
            self.new_peer_states = null;
        }

        try out.append(self.allocator, .{ .persist = .{ .term = self.current_term, .voted_for = self.id } });

        const last_index = try log.head();
        const last_term = try log.term_at(last_index, self.allocator);

        for (self.peers) |*peer| {
            peer.vote_responded = false;
            peer.vote_granted = false;
            try out.append(self.allocator, .{ .send = .{ .to = peer.id, .msg = .{ .request_vote = .{
                .term = self.current_term,
                .candidate_id = self.id,
                .last_log_index = last_index,
                .last_log_term = last_term,
            } } } });
        }

        // Single-node cluster: self-vote already constitutes majority.
        if (self.votes_for_me >= quorumSize(self.peers.len + 1)) {
            try self.becomeLeader(log, out);
        }
    }

    fn becomeLeader(self: *RaftNode, log: *Log, out: *std.ArrayList(Output)) !void {
        assert(self.role == .candidate);
        self.role = .leader;
        self.heartbeat_ticks = 0;
        self.metrics.leadership_won.inc();
        self.metrics.is_leader.set(1);
        const last_index = try log.head();
        for (self.peers) |*peer| {
            peer.next_index = last_index + 1;
            peer.match_index = 0;
        }
        // Send immediate heartbeats to assert leadership.
        try self.broadcastAppendEntries(log, out);
    }

    fn stepDown(self: *RaftNode, term: Term, out: *std.ArrayList(Output)) !void {
        assert(term >= self.current_term); // Raft invariant: terms never decrease
        const was_leader = self.role == .leader;
        const need_persist = term > self.current_term;
        self.current_term = term;
        if (need_persist) {
            self.voted_for = null;
            try out.append(self.allocator, .{ .persist = .{ .term = term, .voted_for = null } });
        }
        self.role = .follower;
        self.election_ticks = 0;
        self.election_timeout = randomElectionTimeout(&self.prng, self.cfg);
        if (was_leader) {
            self.metrics.leadership_lost.inc();
            self.metrics.is_leader.set(0);
        }
        self.metrics.current_term.set(@intCast(self.current_term));
    }

    fn broadcastAppendEntries(self: *RaftNode, log: *Log, out: *std.ArrayList(Output)) !void {
        for (self.peers) |*peer| {
            try self.emitSendEntries(log, peer, out);
        }
        // During joint consensus, also send to genuinely new peers.
        if (self.new_peer_states) |nps| {
            for (nps) |*peer| try self.emitSendEntries(log, peer, out);
        }
        self.metrics.heartbeats_sent.inc();
        // For single-node clusters (0 peers), majority is already met by self alone.
        // For multi-node clusters, this is a no-op until peer acks arrive.
        try self.checkCommit(log, out);
    }

    fn emitSendEntries(self: *RaftNode, log: *Log, peer: *PeerState, out: *std.ArrayList(Output)) !void {
        const prev_index = peer.next_index - 1;
        const prev_term = try log.term_at(prev_index, self.allocator);
        try out.append(self.allocator, .{ .send_entries = .{
            .to = peer.id,
            .term = self.current_term,
            .leader_id = self.id,
            .prev_log_index = prev_index,
            .prev_log_term = prev_term,
            .from_index = peer.next_index,
            .leader_commit = self.commit_index,
        } });
    }

    /// Advance commit_index to the highest N such that:
    ///   N > commit_index AND entry[N].term == currentTerm AND quorum have matchIndex >= N
    ///
    /// During joint consensus, quorum requires majority from BOTH old AND new config.
    fn checkCommit(self: *RaftNode, log: *Log, out: *std.ArrayList(Output)) !void {
        const old_majority = quorumSize(self.peers.len + 1);
        assert(old_majority > 0);

        const our_head = try log.head();
        var n = our_head;
        while (n > self.commit_index) : (n -= 1) {
            const entry_term = try log.term_at(n, self.allocator);
            if (entry_term != self.current_term) continue;

            // Old config quorum.
            var old_count: usize = 1;
            for (self.peers) |peer| {
                if (peer.match_index >= n) old_count += 1;
            }
            if (old_count < old_majority) continue;

            // Joint consensus: also require new config quorum.
            if (self.joint_config_peer_ids) |jids| {
                var new_count: usize = 1; // self is in new config
                for (jids) |jid| {
                    const mi = if (self.findPeer(jid)) |p| p.match_index else 0;
                    if (mi >= n) new_count += 1;
                }
                if (new_count < quorumSize(jids.len + 1)) continue;
            }

            self.commit_index = n;
            try out.append(self.allocator, .{ .committed = n });
            break;
        }

        try self.maybeApplyConfig(out);
    }

    /// If a pending config change has now committed, emit apply_config and update peer list.
    fn maybeApplyConfig(self: *RaftNode, out: *std.ArrayList(Output)) !void {
        // This is the domain boundary — all data past this point is validated.
        const pc = self.pending_config orelse return;
        if (self.commit_index < pc.seq) return;

        try out.append(self.allocator, .{ .apply_config = .{
            .seq = pc.seq,
            .op = pc.op,
            .peer_id = pc.peer_id,
        } });

        try self.applyConfigChangeInternal(pc.op, pc.peer_id);

        self.pending_config = null;
    }

    /// Update peer list to reflect committed config change.
    fn applyConfigChangeInternal(self: *RaftNode, op: ConfigChangeOp, peer_id: NodeId) !void {
        if (self.joint_config_peer_ids) |jids| {
            // Leader: build new peers from joint_config_peer_ids using current state.
            const new_peers = try self.allocator.alloc(PeerState, jids.len);
            for (jids, 0..) |jid, i| {
                if (self.findPeer(jid)) |p| {
                    new_peers[i] = p.*;
                } else {
                    new_peers[i] = .{ .id = jid, .next_index = 1, .match_index = 0, .vote_responded = false, .vote_granted = false };
                }
            }
            self.allocator.free(self.peers);
            self.peers = new_peers;
            self.allocator.free(jids);
            self.joint_config_peer_ids = null;
            if (self.new_peer_states) |nps| {
                self.allocator.free(nps);
                self.new_peer_states = null;
            }
        } else {
            // Follower: compute new peer set directly from op.
            switch (op) {
                .add_voter => {
                    const np = try self.allocator.alloc(PeerState, self.peers.len + 1);
                    @memcpy(np[0..self.peers.len], self.peers);
                    np[self.peers.len] = .{ .id = peer_id, .next_index = 1, .match_index = 0, .vote_responded = false, .vote_granted = false };
                    self.allocator.free(self.peers);
                    self.peers = np;
                },
                .remove_voter => {
                    var count: usize = 0;
                    for (self.peers) |p| {
                        if (p.id != peer_id) count += 1;
                    }
                    const np = try self.allocator.alloc(PeerState, count);
                    var i: usize = 0;
                    for (self.peers) |p| {
                        if (p.id != peer_id) {
                            np[i] = p;
                            i += 1;
                        }
                    }
                    self.allocator.free(self.peers);
                    self.peers = np;
                },
            }
        }
    }

    fn candidateLogIsUpToDate(self: *RaftNode, log: *Log, cand_last_index: Seq, cand_last_term: Term) !bool {
        const our_last = try log.head();
        const our_term = try log.term_at(our_last, self.allocator);
        if (cand_last_term != our_term) return cand_last_term > our_term;
        return cand_last_index >= our_last;
    }

    fn findPeer(self: *RaftNode, id: NodeId) ?*PeerState {
        for (self.peers) |*peer| {
            if (peer.id == id) return peer;
        }
        if (self.new_peer_states) |nps| {
            for (nps) |*peer| {
                if (peer.id == id) return peer;
            }
        }
        return null;
    }

    fn randomElectionTimeout(prng: *std.Random.Xoroshiro128, cfg: Config) u32 {
        // Relationship assertions are checked once in init(); here we only
        // assert the range is non-zero to prevent uintLessThan panicking.
        const range = cfg.election_timeout_max - cfg.election_timeout_min;
        assert(range > 0);
        return cfg.election_timeout_min + prng.random().uintLessThan(u32, range);
    }
};
