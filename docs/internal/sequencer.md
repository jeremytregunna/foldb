# Sequencer Subsystem

The sequencer is the single authority for global ordering. Every mutation enters the system through the sequencer, which assigns it a durable, gap-free sequence number before anything is executed.

## Role

Assigns monotonically increasing sequence numbers to transaction intents, batches them into epochs, replicates the ordering decision via Raft, then writes intent payloads to the appropriate partition log. All replicas observe the same sequence assignments.

## Guarantees

- **Global order**: Every submitted intent receives a unique, monotonically increasing `seq (u64)`. No two intents share a seq.
- **Durability**: The ordering decision (EpochDecision) is Raft-replicated before `awaitCommit()` returns.
- **Determinism**: The same EpochDecision produces identical seq assignments on all replicas.
- **Idempotency**: Duplicate submissions identified by `(client_id, client_seq_num)` return the same seq without re-processing.
- **Partition routing**: Intents are assigned to log partitions by the leader using round-robin weighted by recent load. The current implementation uses `partition = seq % partition_count` as a simplification.

## Invariants

- Seqs within an epoch are assigned contiguously, in round-robin partition order.
- `epoch_num` is strictly increasing across epochs.
- An EpochDecision is sealed and replicated before any intent payload is written to a partition log.
- The in-memory idempotency cache is bounded: `evictBefore(seq)` removes entries older than a checkpoint.

## Epochs

Intents are batched into epochs. An epoch closes when either:
1. `pending_intents.len >= max_batch_size` (default 10,000), or
2. A wall-clock deadline expires (default 1 ms), or
3. It is explicitly closed.

Each epoch produces an `EpochDecision` containing a monotonically increasing `epoch_num` and an `OrderingEntry` per intent: `{seq, partition, client_id, client_seq}`. This decision is the only thing replicated via Raft — intent payloads are written separately to partition logs after replication succeeds.

## Idempotency

Keyed by `(client_id, client_seq_num)`, not payload content.

1. On submit, check in-memory cache — if found, return cached seq immediately.
2. After seq assignment, record the mapping.
3. Periodically evict entries older than a checkpoint to bound memory.

## Caller Responsibilities

- Submit pre-validated, pre-authorized intent payloads — the sequencer treats them as opaque bytes.
- Provide a unique `client_id` and a strictly increasing `client_seq_num` per client for idempotency.
- Call `awaitCommit()` on the returned handle before treating the assignment as durable.

## Tick Loop

`tickOnce(alloc)` is the main driver loop step. Each call:

1. Calls `pollOnce` in a loop until no new messages are waiting.
2. Drains the transport inbox into a local message buffer.
3. Dispatches each message to the Raft state machine.
4. Flushes all `Output` values via `flushOutputs` (sends RPCs, builds and sends AppendEntries with log entries, persists term/voted_for).
5. Calls `raft.tick()` to advance election/heartbeat timers.
6. Flushes outputs again to handle any new outputs produced by the tick.

`flushOutputs` handles each `Output` variant: `send` delivers an RPC to a peer via transport, `send_entries` reads the relevant log entries and constructs an AppendEntries message, `persist` writes term and voted_for to stable storage, `committed` notifies waiting callers, and `apply_config` rewires transport peers.

**`send_entries` ownership contract**: `decodeMessage` allocates the `entries` slice and each `entry.payload`. After `handleAppendEntries` returns, the caller must free every `entry.payload` and the slice itself — the log serializes entries to disk and retains no reference to the decoded memory. This cleanup happens in the `tickOnce` defer block.

## Relation to Other Subsystems

- **Raft** (`src/raft/`): The sequencer wraps a RaftNode used exclusively for replicating EpochDecisions. On single-node deployments it immediately becomes leader.
- **Partition logs** (`log_p0/`, `log_p1/`, ...): Intent payloads are written here at the assigned seq, after Raft replication of the ordering decision.
- **Gateway**: Validates and authorizes intents before submission. The sequencer input boundary is `submitBytes()`.
- **Executor**: Reads from partition logs using the seq order established by the sequencer.

## Failure Semantics

Epochs in flight at the moment of a leader failure are either fully committed or fully lost — the epoch-close write is atomic in Raft. Intents that were accepted but not yet assigned a seq are retried by the gateway; idempotency ensures they are not double-applied.

## Error Conditions

| Error | Meaning |
|---|---|
| `NotLeader` | Node is not the Raft leader; client should retry against the leader |

## What the Sequencer Does Not Do

- Does not validate or interpret intent payloads.
- Does not replicate intent bytes via Raft — only ordering decisions.
- Does not execute intents — that is the Executor's responsibility.
- Does not support dynamic reconfiguration (add/remove nodes at runtime).

## Source Files

- `src/sequencer/sequencer.zig` — submit, epoch management, partition log writes, `tickOnce`, `flushOutputs`
- `src/sequencer/epoch.zig` — epoch batching and EpochDecision serialization
- `src/sequencer/idempotency.zig` — `(client_id, client_seq)` deduplication cache
- `src/sequencer/types.zig` — shared types: Seq, EpochDecision, OrderingEntry
- `src/raft/transport.zig` — `TcpTransport` used by the sequencer for inter-node messaging
