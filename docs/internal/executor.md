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

This is enforced structurally via `deterministic_std.zig`, which re-exports only the safe subset of `std` (mem, math, fmt, unicode, hash, sort, ArrayList, BoundedArray). Execution-path modules (`eval_expr`, `type_conv`, `agg_accum`, `window_exec`, `key_encode`, `params_codec`) import from `deterministic_std` rather than full `std`, making non-deterministic access visible at code-review time. `std.time`, `std.crypto.random`, `std.rand`, `std.os`, `std.Thread`, `std.fs`, and `std.net` are not re-exported.

## Caller Responsibilities (Handler Contract)

Registered query handlers must be:
- **Total**: they must handle all valid inputs without panicking.
- **Deterministic**: same inputs → same outputs, always.
- **Side-effect free**: reads go through the `Storage` parameter; no external I/O.

The executor validates entries via `validateTxnEntry()` (including CRC check) before dispatching. Raw bytes are never passed to handlers.

## Two-Executor Architecture

There are two distinct executor types:

- **`Executor`** — low-level fold loop. Receives validated `TxnEntry` values, dispatches to a registered `QueryHandler`, accumulates mutations, and commits atomically. Used in tests and by the low-level handler path. Does not own schema or SQL.
- **`FoldExecutor`** — SQL executor. Runs on a dedicated OS thread. Owns `ClusterSchema`, `SqlRegistry`, and `SqlExecutor`. Reads committed entries from its log partition via `LogMux` and applies them using the SQL execution path. Handles cross-partition row exchange via `ExchangeBus`.

## Partition Management

Each `FoldExecutor` services one storage partition. In multi-partition deployments each partition runs on its own OS thread and communicates with peers through an `ExchangeBus`.

**Cross-partition protocol (FoldExecutor path):**

1. All partitions read the same `TxnIntent` from the merged log stream (`LogMux`).
2. Each partition calls `declareReads` to walk the `ExecutionPlan` and emit `ForeignRead` entries for tables on peer partitions.
3. Each partition sends an `ExchangeRequest` to each peer it needs rows from, then enters a serve-and-wait loop: while waiting for its own response it answers incoming requests from other partitions by fetching rows from local storage and sending `ExchangeResponse` messages back.
4. Once all foreign rows are received, the partition executes its local slice deterministically and applies mutations.

Both sides see the same `TxnIntent` and execute the same deterministic logic — no voting or coordination needed. A constraint violation is computed identically by all participating partitions.

The `ExchangeBus` provides N*(N-1) directed in-process SPSC lock-free ring buffer channels, one per ordered pair `(from, to)`. Channel `(X, Y)` is written exclusively by executor X and read exclusively by executor Y. Exchange messages carry `(seq, from, to)` so late-joining followers can replay them from peers during recovery.

In **replay mode** (`replay_mode = true`), `FoldExecutor` re-derives cross-partition foreign rows from local storage instead of the live bus, so recovering nodes do not need live peers to reconstruct state.

Single-partition entries skip exchange entirely.

## Schema-Change Routing

`schema_change` log entries carry a 5-byte header before the SQL text:

```
[1 byte: SchemaPayloadKind][4 bytes: database_id, little-endian][sql text...]
```

`SchemaPayloadKind` values:
- `ddl` (0x01) — DDL SQL (`CREATE TABLE`, `DROP TABLE`, etc.) scoped to `database_id`
- `query` (0x02) — query registration SQL scoped to `database_id`
- `cluster` (0x03) — cluster-level DDL (`CREATE DATABASE`, `DROP DATABASE`); `database_id` field is unused

This allows `FoldExecutor` to route DDL and query registration to the correct per-database `SchemaRegistry`. Payloads shorter than 5 bytes or with an unknown kind byte are silently skipped — the entry still advances the seq counter.

## Integration with Other Subsystems

- **Log**: The executor driver polls in 256-entry batches via `drain_once()`. It notifies the log when a snapshot advances, enabling safe prefix truncation.
- **Storage**: Mutations accumulate during handler execution, then commit atomically via `storage.apply()`.
- **CDC**: Receives before/after images after each successful apply. See [CDC](cdc.md).

## OCC Conflict Detection (low-level handler path only)

The low-level `Executor` implements optimistic concurrency control to detect cases where a handler's read set was invalidated between reconnaissance and execution.

When a `TxnIntent` carries a non-zero `recon_seq`, the executor wires a `ReadTracker` to storage before calling the handler and detaches it after. Every `get()` and `scan()` call records `(table_id, key, row_seq)` for each key read. After the handler returns, `read_write_conflict()` checks whether any recorded `row_seq > recon_seq` — if so, a key the handler read was written after reconnaissance, and the entry aborts with code `retry`. The gateway re-scouts at the conflicting seq and resubmits.

**What OCC covers:**
- Point reads (`get`) — both found rows and missing keys (recorded with `row_seq = 0`)
- Rows returned by range scans (`scan`) — each returned row is individually tracked

**What OCC does not cover — phantom reads:**
A phantom occurs when a new row is inserted into a range that the handler scanned, after `recon_seq`. Because the inserted row was not present during the scan, there is no `ReadEntry` for it and no conflict is detected. Preventing phantoms requires range-predicate tracking: recording the scan bounds and checking, during conflict detection, whether any key in that range has `row_seq > recon_seq`. This is not yet implemented.

**This does not affect the SQL execution path.** `FoldExecutor` → `SqlExecutor` does not use OCC at all — strict serializability there is structural, achieved by executing every transaction in a deterministic serial order derived from the Raft log.

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

- `src/executor/executor.zig` — low-level `Executor`: fold loop, handler dispatch, CDC integration, `ExecutorDriver`, schema-change payload encoding/decoding
- `src/executor/fold_executor.zig` — `FoldExecutor`: dedicated-thread SQL executor, cross-partition serve-and-wait loop, replay mode
- `src/executor/registry.zig` — query handler registration by QueryHash
- `src/executor/determinism.zig` — determinism enforcement utilities (`verifyExecutorModule`)
- `src/executor/deterministic_std.zig` — approved std subset for execution-path code
- `src/executor/exchange.zig` — cross-partition exchange types: `ForeignRead`, `ExchangeRequest`, `ExchangeResponse`, `SpscQueue`
- `src/executor/exchange_bus.zig` — `ExchangeBus`: N*(N-1) directed SPSC channels between partition executors
- `src/executor/declare_reads.zig` — walks an `ExecutionPlan` to emit `ForeignRead` entries for peer partitions
- `src/executor/types.zig` — shared types: `ExecResult`, `ValidatedTxnEntry`, `TxnIntentHeader`, wire serialisation
