# Raft Subsystem

Raft provides replicated log durability and linearizable commit across cluster nodes. It is the mechanism by which ordering decisions become durable on a majority of replicas before the sequencer considers them committed.

## Role

A pure state machine — no I/O, no timers. All side effects are expressed as `Output` values that callers must handle. Callers own timing (via `tick()`) and all network/disk operations.

## Guarantees

- **Safety**: Once an entry is committed, it is never overwritten. A majority of nodes have durably recorded it.
- **Monotonic commit index**: `commit_index` never decreases.
- **Single leader per term**: At most one leader exists in any given term within a quorum.
- **Log consistency**: Follower logs are truncated on conflict before new entries are appended, ensuring all replicas agree up to the commit index.
- **Sequential proposal**: Leaders assign monotonically increasing indices. `propose()` returns the assigned index immediately without waiting for commit.

## The Output Contract

Raft communicates required side effects by emitting `Output` values. Callers **must** process all outputs synchronously and in order:

| Output | Caller responsibility |
|---|---|
| `send` | Deliver RPC to the named peer |
| `send_entries` | Read entries from log for the given range, attach to AppendEntries RPC |
| `persist` | Write `term` and `voted_for` to stable storage **before** sending any messages |
| `committed` | Entry is safe to apply to the state machine |
| `apply_config` | Config change committed; rewire transport if a new node was added |

Skipping or reordering outputs violates safety.

## Caller Responsibilities

- Drive the state machine by calling `tick()` on a regular interval for election and heartbeat timeouts.
- Supply a random seed at init — election/heartbeat timeouts are randomized to reduce split-vote probability.
- Handle all `Output` values before processing the next input event.
- Read from and truncate the log synchronously during `handleAppendEntries`.

## Key Invariants

- **Election safety**: Each term has at most one leader. A candidate wins only if its log is at least as up-to-date as a majority (enforced by `last_log_term` vote check).
- **Log matching**: If two logs agree at index N, they agree on all entries before N.
- **Leader completeness**: The leader in term T contains all entries committed in terms 0..T-1.
- **Commit rule**: `commit_index` advances only when a majority of `match_index >= N` and the entry at N is from the current term.

## Entry Flow

1. Leader calls `propose()` — appends to local log, emits `send_entries` outputs to all peers.
2. Followers call `handleAppendEntries()` — truncate on conflict, append new entries.
3. Leader calls `handleAppendEntriesResult()` — updates `match_index`, checks for majority.
4. Once majority reached: emits `committed` output. No additional persistence delay.

## Membership Changes

Config changes use joint consensus (two phases): a `pending_config` is tracked during the transition, ensuring no gap between old and new quorum. The `apply_config` output signals that transport should be rewired.

## Error Conditions

- **Stale term**: Any message with a lower term than the node's current term is rejected.
- **Log conflict**: Detected via `prevLogTerm` mismatch; follower truncates suffix and signals the leader to retry from the correct index.
- **Not leader**: `propose()` on a follower or candidate is rejected; callers must route proposals to the leader.

## What Raft Does Not Do

- Does not own or define the log format — reads and writes via the `Log` interface.
- Does not guarantee liveness — that requires correctly driven election/heartbeat timeouts.
- Does not provide transaction isolation — that is the sequencer's responsibility.
- Does not handle Byzantine faults — honest-majority model only.

## Relation to Other Subsystems

- **Sequencer**: Uses Raft to replicate EpochDecisions. Raft provides the durability guarantee; the sequencer provides the ordering and idempotency guarantees.
- **Log**: Raft reads and writes entries via the `Log` interface. It does not own segment management or CRC validation.

## Source Files

- `src/raft/raft.zig` — module exports and top-level types
- `src/raft/node.zig` — per-node Raft state machine: propose, tick, message handlers
- `src/raft/cluster.zig` — multi-node cluster coordination
- `src/raft/rpc.zig` — RPC message definitions and encoding
- `src/raft/transport.zig` — network transport abstraction for peer communication
- `src/raft/persistent_state.zig` — durable term and voted_for storage
- `src/raft/types.zig` — shared types: Term, Index, NodeId, Output
