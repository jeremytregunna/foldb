# Executor Subsystem

The executor applies committed log entries to storage. Given the same log prefix, every node produces bit-identical state — determinism is the central invariant.

## Role

Reads committed entries from the log and folds them into storage state by applying KV mutations. It is a pure consumer — it never writes to the log or influences ordering.

## Guarantees

- **Determinism**: Given identical log input, all replicas produce identical storage state.
- **Atomicity**: Mutations from a single entry are applied atomically.
- **Seq advancement**: Every committed entry advances the executor's position.
- **Causality with CDC**: Before-images are captured before mutations apply; CDC events are dispatched after.

## The Fold Function

**In**: `LogEntry` — containing serialized KV operations (set/delete with key and optional value).

**Out**: `ExecResult` — either `ok` or `abort` (with code and detail).

The executor decodes each `LogEntry` into a `TxnIntent` containing `[]const KvOp` operations, converts them to `[]const Mutation` for Storage, and applies them at the entry's sequence number.

## ExecutorDriver

The gateway owns a dedicated executor thread. It drains committed entries from the sequencer partition logs in 256-entry batches:

1. Read committed entries from the log mux.
2. Decode the entry payload into `TxnIntent` (contains `[]const KvOp`).
3. Convert `TxnIntent` to `[]const Mutation` (key, value, kind), coalescing duplicate keys within the transaction to the final operation.
4. Capture before-images if CDC is configured.
5. Apply mutations to Storage via `storage.apply(mutations, seq)`.
6. Dispatch CDC events with before/after images.
7. Advance the executor's applied sequence.

## Integration with Other Subsystems

- **Log**: The executor driver polls committed entries in batches.
- **Storage**: Mutations are applied via `storage.apply(mutations, seq)`.
- **CDC**: Receives before/after images after each successful apply.

## Error Conditions

| Error | Meaning |
|---|---|
| `bad_payload` | CRC mismatch or invalid entry payload |
| `constraint_violation` | Transaction-level condition failed, such as CAS mismatch |

## Source Files

- `src/executor/executor.zig` — fold loop, handler dispatch, CDC integration, ExecutorDriver
- `src/executor/types.zig` — shared types: KvOp, TxnIntent, ExecResult, AbortCode
- `src/executor/determinism.zig` — determinism enforcement utilities
