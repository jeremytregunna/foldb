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

const Log = log_mod.Log;
const LogEntry = log_mod.LogEntry;
const Seq = log_mod.Seq;
const NodeId = log_mod.NodeId;
const Epoch = log_mod.Epoch;
pub const Term = types.Term;
pub const RaftRole = types.RaftRole;
const AppendEntriesArgs = rpc.AppendEntriesArgs;
const AppendEntriesResult = rpc.AppendEntriesResult;
const RequestVoteArgs = rpc.RequestVoteArgs;
const RequestVoteResult = rpc.RequestVoteResult;
const Message = rpc.Message;

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
    max_append_batch: usize = 64,
};

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

    pub fn init(
        allocator: std.mem.Allocator,
        id: NodeId,
        peer_ids: []const NodeId,
        cfg: Config,
        seed: u64,
    ) !RaftNode {
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
        if (self.role != .leader) return null;

        const seq = (try log.head()) + 1;
        const entry = LogEntry.create(seq, self.current_term, kind, payload);
        try log.appendEntry(entry);

        // Update our own match_index conceptually (handled via head() in checkCommit).
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
            if (self.role == .candidate) {
                self.role = .follower;
            }
        }

        // Reset election timer on valid leader contact.
        self.election_ticks = 0;

        // Log consistency check.
        if (args.prev_log_index > 0) {
            const our_head = try log.head();
            if (our_head < args.prev_log_index) {
                try out.append(self.allocator, .{ .send = .{ .to = args.leader_id, .msg = .{ .append_entries_result = .{
                    .term = self.current_term,
                    .success = false,
                    .match_index = our_head,
                } } } });
                return;
            }
            const our_term = try log.termAt(args.prev_log_index, self.allocator);
            if (our_term != args.prev_log_term) {
                // Conflict: truncate back to prev_log_index so leader can retry.
                try log.truncateSuffix(args.prev_log_index);
                try out.append(self.allocator, .{ .send = .{ .to = args.leader_id, .msg = .{ .append_entries_result = .{
                    .term = self.current_term,
                    .success = false,
                    .match_index = (try log.head()),
                } } } });
                return;
            }
        }

        // Append new entries (skip any already present and matching).
        for (args.entries) |entry| {
            const our_head = try log.head();
            if (entry.header.seq <= our_head) {
                const our_term = try log.termAt(entry.header.seq, self.allocator);
                if (our_term == entry.header.epoch) continue; // already have it
                // Conflict at this index — truncate and append.
                try log.truncateSuffix(entry.header.seq);
            }
            try log.appendEntry(entry);
        }

        // Advance commit index.
        const new_head = try log.head();
        if (args.leader_commit > self.commit_index) {
            const new_commit = @min(args.leader_commit, new_head);
            if (new_commit > self.commit_index) {
                self.commit_index = new_commit;
                try out.append(self.allocator, .{ .committed = self.commit_index });
            }
        }

        try out.append(self.allocator, .{ .send = .{ .to = args.leader_id, .msg = .{ .append_entries_result = .{
            .term = self.current_term,
            .success = true,
            .match_index = new_head,
        } } } });
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
            const majority = (self.peers.len + 1) / 2 + 1;
            if (self.votes_for_me >= majority) {
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

        try out.append(self.allocator, .{ .persist = .{ .term = self.current_term, .voted_for = self.id } });

        const last_index = try log.head();
        const last_term = try log.termAt(last_index, self.allocator);

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
    }

    fn becomeLeader(self: *RaftNode, log: *Log, out: *std.ArrayList(Output)) !void {
        self.role = .leader;
        self.heartbeat_ticks = 0;
        const last_index = try log.head();
        for (self.peers) |*peer| {
            peer.next_index = last_index + 1;
            peer.match_index = 0;
        }
        // Send immediate heartbeats to assert leadership.
        try self.broadcastAppendEntries(log, out);
    }

    fn stepDown(self: *RaftNode, term: Term, out: *std.ArrayList(Output)) !void {
        const need_persist = term > self.current_term;
        self.current_term = term;
        if (need_persist) {
            self.voted_for = null;
            try out.append(self.allocator, .{ .persist = .{ .term = term, .voted_for = null } });
        }
        self.role = .follower;
        self.election_ticks = 0;
        self.election_timeout = randomElectionTimeout(&self.prng, self.cfg);
    }

    fn broadcastAppendEntries(self: *RaftNode, log: *Log, out: *std.ArrayList(Output)) !void {
        for (self.peers) |*peer| {
            try self.emitSendEntries(log, peer, out);
        }
    }

    fn emitSendEntries(self: *RaftNode, log: *Log, peer: *PeerState, out: *std.ArrayList(Output)) !void {
        const prev_index = peer.next_index - 1;
        const prev_term = try log.termAt(prev_index, self.allocator);
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
    ///   N > commit_index AND entry[N].term == currentTerm AND majority have matchIndex >= N
    fn checkCommit(self: *RaftNode, log: *Log, out: *std.ArrayList(Output)) !void {
        const our_head = try log.head();
        var n = our_head;
        while (n > self.commit_index) : (n -= 1) {
            const entry_term = try log.termAt(n, self.allocator);
            if (entry_term != self.current_term) continue; // safety: only commit current-term entries

            var count: usize = 1; // self
            for (self.peers) |peer| {
                if (peer.match_index >= n) count += 1;
            }
            const majority = (self.peers.len + 1) / 2 + 1;
            if (count >= majority) {
                self.commit_index = n;
                try out.append(self.allocator, .{ .committed = n });
                break;
            }
        }
    }

    fn candidateLogIsUpToDate(self: *RaftNode, log: *Log, cand_last_index: Seq, cand_last_term: Term) !bool {
        const our_last = try log.head();
        const our_term = try log.termAt(our_last, self.allocator);
        if (cand_last_term != our_term) return cand_last_term > our_term;
        return cand_last_index >= our_last;
    }

    fn findPeer(self: *RaftNode, id: NodeId) ?*PeerState {
        for (self.peers) |*peer| {
            if (peer.id == id) return peer;
        }
        return null;
    }

    fn randomElectionTimeout(prng: *std.Random.Xoroshiro128, cfg: Config) u32 {
        const range = cfg.election_timeout_max - cfg.election_timeout_min;
        return cfg.election_timeout_min + prng.random().uintLessThan(u32, range);
    }
};
