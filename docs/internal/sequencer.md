# Sequencer Subsystem

The sequencer is the single authority for global ordering. Every mutation enters the system through the sequencer, which assigns it a durable, gap-free sequence number before anything is executed.

## Role

Assigns monotonically increasing sequence numbers to transaction intents, wraps each in a single-entry `EpochDecision`, replicates the ordering decision via Raft, then writes the intent payload to the assigned log partition. All replicas observe the same sequence assignments.

## Guarantees

- **Global order**: Every submitted intent receives a unique, monotonically increasing `seq (u64)`. No two intents share a seq.
- **Durability**: The ordering decision (EpochDecision) is Raft-replicated before `awaitCommit()` returns.
- **Determinism**: The same EpochDecision produces identical seq assignments on all replicas.
- **Idempotency**: Duplicate submissions identified by `(client_id, client_seq_num)` return the same seq without re-processing.
- **Partition routing**: Intents are assigned to the least-loaded log partition, with ties broken by `seq % log_partition_count`. Load counters decay every 4096 commits to prevent stale bias from past bursts.

## Invariants

- `epoch_num` is strictly increasing across epochs.
- An EpochDecision is sealed and Raft-replicated before any intent payload is written to a partition log.
- The in-memory idempotency cache is bounded: `evictBefore(seq)` removes entries older than a checkpoint.
- `next_seq` is always ahead of every seq the Raft log has assigned; it is advanced on startup by replaying committed entries, closing the window where a post-crash restart could reuse a seq from a prior epoch.
- `last_applied` is persisted to `last_applied.bin` after every batch of partition writes, not before. A crash in the middle of applying an epoch replays that epoch on restart; partition log writes are idempotent on seq (entries with `oe.seq <= current_seq` are skipped).

## Epochs

The current implementation creates one `EpochDecision` per submitted intent. The `EpochBatcher` type exists for future batching but is not used in the hot path.

Each epoch produces an `EpochDecision` containing a monotonically increasing `epoch_num`, an `entry_kind`, the raw payload, and exactly one `OrderingEntry`: `{seq, partition, client_id, client_seq}`. This decision is the only thing replicated via Raft — the payload bytes travel inside the serialized `EpochDecision`, not through a separate data channel.

### EpochDecision wire format

```
epoch_num:    u64 le  (8 bytes)
entry_count:  u32 le  (4 bytes)
entries:      [entry_count] × 28 bytes each
  seq:          u64 le
  partition:    u32 le
  client_id:    u64 le
  client_seq:   u64 le
entry_kind:   u8
payload_len:  u32 le  (4 bytes)
payload:      [payload_len]u8
```

## Idempotency

Keyed by `(client_id, client_seq_num)`, not payload content.

1. On submit, check in-memory cache — if found, return cached seq immediately.
2. After seq assignment, record the mapping.
3. Periodically evict entries older than a checkpoint via `evictBefore(seq)` to bound memory.

## Thread Model

The Sequencer runs a dedicated owner thread (`runLoop`). All mutable sequencer state is exclusively owned by that thread.

- Callers submit via `submitBytes()`, which enqueues a `PendingSubmit` onto an MPSC queue and returns a `SubmitHandle`.
- The owner thread drains the queue, calls `commitInner`, and signals completion by writing the result and setting `pending.done = true`.
- `SubmitHandle.awaitCommit()` has two modes:
  - **Fiber path** (`io` non-null): suspends via `io.sleep(1 ms)` between checks, yielding to other connection fibers during the Raft round-trip.
  - **Spin path** (`io` null): spins with `sched_yield`. Safe only for dedicated threads with no fiber scheduler.
  - Both paths return `CommitTimeout` after a fixed bound (30 s / 100M spins respectively).

## Caller Responsibilities

- Submit pre-validated, pre-authorized intent payloads — the sequencer treats them as opaque bytes.
- Provide a unique `client_id` and a strictly increasing `client_seq_num` per client for idempotency.
- Call `awaitCommit()` on the returned `SubmitHandle` before treating the assignment as durable. Pass an `std.Io` handle when calling from fiber context.

## Tick Loop

`tickOnce(alloc)` is the main driver loop step:

1. Calls `transport.pollOnce` in a loop until no new messages are waiting.
2. Drains the transport inbox into a local message buffer.
3. For each message, dispatches to the Raft state machine and flushes outputs immediately.
4. Calls `raft.tick()` to advance election/heartbeat timers, then flushes outputs.

`flushOutputs` handles each `Output` variant: `send` delivers an RPC to a peer via transport; `send_entries` reads the relevant log entries from `raft_log` and constructs an AppendEntries message; `persist` writes term and `voted_for` to stable storage (must be durable before any messages are sent — failure here risks acting on a stale term after crash-restart); `committed` triggers `applyCommitted`; `apply_config` is a no-op (transport is pre-registered in `addNode`/`removeNode`).

**`send_entries` memory contract**: `raft_log.read()` allocates the `entries` slice and each `entry.payload`. The entries are deferred-freed in `flushOutputs` after `send` copies what it needs — the log retains no reference to the decoded memory.

**Incoming `append_entries` memory contract**: `decodeMessage` allocates `entries` and each `entry.payload`. After `handleAppendEntries` returns, the `tickOnce` defer block frees every `entry.payload` and the slice — the log serializes entries to disk and retains no reference to the decoded memory.

## Crash Recovery

On startup, `runLoop` calls `applyCommitted(raft.commit_index)` before accepting new submissions. This brings `next_seq` to the true Raft high-water mark, so new seqs can never collide with seqs from a prior run. `last_applied.bin` records the highest fully-applied Raft index; entries already reflected in the partition logs are skipped on replay.

## Dynamic Membership

`addNode(node_id, addr)` proposes adding a Raft voter. The peer address is pre-registered in the TCP transport so AppendEntries can be sent immediately after the proposal.

`removeNode(node_id)` proposes removing a voter and closes the transport connection once the proposal is submitted.

Both return `NotLeader` if this node is not the leader, or `ConfigChangeInProgress` if another membership change is in flight. Only one config change may be in flight at a time (joint consensus rule).

## Relation to Other Subsystems

- **Raft** (`src/raft/`): The sequencer wraps a RaftNode used exclusively for replicating EpochDecisions. On single-node deployments it immediately becomes leader.
- **Partition logs** (`log_p0/`, `log_p1/`, ...): Intent payloads are written here at the assigned seq, after Raft replication of the ordering decision.
- **Gateway**: Validates and authorizes intents before submission. The sequencer input boundary is `submitBytes()`.
- **Executor**: Reads from partition logs using the seq order established by the sequencer. Each FoldExecutor's `LogMux` should span all log partition logs.

## Failure Semantics

Epochs in flight at the moment of a leader failure are either fully committed or fully lost — the epoch-close write is atomic in Raft. Intents that were accepted but not yet assigned a seq are retried by the gateway; idempotency ensures they are not double-applied.

## Error Conditions

| Error | Meaning |
|---|---|
| `NotLeader` | Node is not the Raft leader; client should retry against the leader |
| `PartitionError` | Partition log write failed |
| `SerializeError` | EpochDecision serialization failed |
| `ConfigChangeInProgress` | A membership change is already in flight; retry after it commits |
| `CommitTimeout` | `awaitCommit` hit its deadline (30 s fiber / 100M spin-yields) without observing `done` |

## What the Sequencer Does Not Do

- Does not validate or interpret intent payloads.
- Does not replicate intent bytes separately — they travel inside the serialized EpochDecision.
- Does not execute intents — that is the Executor's responsibility.

## Source Files

- `src/sequencer/sequencer.zig` — submit, partition routing, `commitRoute`, `tickOnce`, `flushOutputs`, `applyCommitted`, owner thread
- `src/sequencer/epoch.zig` — `EpochBatcher` (future batching; not used in the hot path)
- `src/sequencer/idempotency.zig` — `(client_id, client_seq)` deduplication cache
- `src/sequencer/types.zig` — shared types: `Seq`, `EpochDecision`, `OrderingEntry`, `SubmitHandle`; EpochDecision wire format serialization/deserialization
- `src/raft/transport.zig` — `TcpTransport` used by the sequencer for inter-node messaging
