# Executor Subsystem

The executor applies committed log entries to storage. Given the same log prefix, every node produces bit-identical state — determinism is the central invariant.

## Role

Reads committed entries from the log and folds them into storage state by dispatching to registered query handlers. It is a pure consumer — it never writes to the log or influences ordering.

## Guarantees

- **Determinism**: Given identical log input, all replicas produce identical storage state.
- **Atomicity**: Mutations from a single entry are applied atomically. A constraint violation aborts the entire entry with no partial state.
- **Seq advancement**: Every committed entry advances the executor's position, including non-mutating entries (noop, snapshot_marker, etc.).
- **Causality with CDC**: Before-images are captured before mutations apply; CDC events are dispatched after. Order is preserved.

## The Fold Function

**In**: `LogEntry` — containing query_hash, params, and resolved nondeterminism (timestamps, random values, UUIDs resolved at commit time).

**Out**: `ExecResult` — either `ok` (with rows_affected) or `abort` (with code and detail).

Nondeterminism is not generated during execution — it is resolved upstream and delivered as part of the entry. The following are compile-time forbidden in query execution code:

- System clock reads — use `seq` as logical time only.
- RNG calls — use `resolved_nondet` values only.
- Hash-map iteration order dependence — all maps used during execution use deterministic ordering or are sorted before iteration.
- Float operations where ordering matters — float aggregations use key-sorted ordering.

This is enforced by a `comptime` import whitelist: any module reachable from query execution code must be on the whitelist. Violations are compile errors.

## Caller Responsibilities (Handler Contract)

Registered query handlers must be:
- **Total**: they must handle all valid inputs without panicking.
- **Deterministic**: same inputs → same outputs, always.
- **Side-effect free**: reads go through the `Storage` parameter; no external I/O.

The executor validates entries via `validateTxnEntry()` (including CRC check) before dispatching. Raw bytes are never passed to handlers.

## Partition Management

- `Executor` handles a single partition.
- `PartitionSet` coordinates N executors for cross-partition transactions using a four-phase protocol:
  1. Declare foreign reads
  2. Fetch rows at `seq - 1`
  3. Execute locally
  4. Apply mutations atomically

Both sides of a cross-partition transaction see the same input values and execute the same deterministic logic — no voting or coordination is needed to reach consistent results. A constraint violation at one partition is computed identically by all participating partitions. Exchange messages are addressed by `(seq, partition_id)` so late-joining followers can replay them from peers. The exchange uses a dedicated intra-cluster RPC; RDMA is used when available.

Single-partition entries bypass `PartitionSet` entirely.

## Integration with Other Subsystems

- **Log**: The executor driver polls in 256-entry batches via `drainOnce()`. It notifies the log when a snapshot advances, enabling safe prefix truncation.
- **Storage**: Mutations accumulate during handler execution, then commit atomically via `storage.apply()`.
- **CDC**: Receives before/after images after each successful apply. See [CDC](cdc.md).

## Error Conditions

| Error | Meaning |
|---|---|
| `bad_params` | CRC mismatch on entry params |
| `missing_query` | No handler registered for the entry's query hash |
| `constraint_violation` | Handler rejected the entry; a deterministic abort record is written at `seq`, no mutations applied |

Cross-partition transactions routed to a single-partition executor are aborted.

## What the Executor Does Not Do

- Does not write to the log or influence sequencing.
- Does not persist state — that is Storage's responsibility.
- Does not coordinate across nodes — each replica runs its own executor independently.
- Does not provide durability — durability comes from the log.
- Does not handle Byzantine failures.

## Source Files

- `src/executor/executor.zig` — fold loop, handler dispatch, CDC integration, driver
- `src/executor/partition_set.zig` — cross-partition coordinator and four-phase protocol
- `src/executor/registry.zig` — query handler registration by QueryHash
- `src/executor/determinism.zig` — determinism enforcement utilities
- `src/executor/exchange.zig` — cross-partition data exchange types
- `src/executor/types.zig` — shared types: ExecResult, ValidatedTxnEntry
