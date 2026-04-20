# Gateway Subsystem

The gateway is the external boundary of FoldDB. It is the sole entry point for client operations — all validation, nondeterminism resolution, and sequencer coordination happen here before anything touches the log.

## Role

Accepts client requests, validates and enriches them, resolves nondeterminism, assigns idempotency keys, and routes mutations through the sequencer. Also serves reads directly from storage without going through the sequencer.

## Public Operations

| Operation | Purpose |
|---|---|
| `register(sql)` | Parse, type-check, and cache a query by hash |
| `execute(hash, params)` | Submit a DML mutation |
| `querySelect(hash, params)` | Execute a SELECT against current state |
| `readAt(hash, params, seq)` | Historical read at a specific sequence number |

All operations require the query to be pre-registered. An unregistered hash returns `QueryNotFound`.

## Nondeterminism Resolution

Before forwarding a mutation to the sequencer, the gateway resolves all nondeterministic functions exactly once:

- `NOW()` and `UUID_V7()` — sourced from an injected `ClockSource`.
- `RANDOM()` — 16 bytes from an injected `RandSource`.

Resolved values are bundled into the intent payload. Clients may supply pre-resolved overrides; caller-supplied values take precedence over gateway-resolved values. This ensures every replica applies the same values when the executor folds the entry.

## Validation

The gateway enforces three domain boundaries:

1. **DML entry**: After sequencer commit, `validateTxnEntry()` verifies the CRC of the serialized payload and decodes parameters against the registered query's type schema. Corrupted entries abort cleanly without reaching storage.
2. **SELECT/read**: Parameters are decoded and count-checked against the query's type schema before execution.
3. **DDL replay**: On restart, schema and query registry rebuild idempotently — duplicate `CREATE` statements are silently dropped.

## Reconnaissance

Before submitting a mutation the gateway runs **reconnaissance**: it walks the query plan to determine which storage partitions the transaction will read and write, then embeds those partition IDs as `read_set_hint` / `write_set_hint` in the `TxnIntent`. This enables the executor and `PartitionSet` to route the transaction to the correct partition(s) without guessing.

**Current implementation — table-level granularity**: each table referenced by the plan is mapped to a storage partition via `table_id % partition_count`. With the current single-partition storage layout this always produces partition 0. The code structure is correct for multi-partition deployments; a row-level scan (reading the actual snapshot at `at_seq` to find the exact keys affected by non-PK-filter DML) is left as a TODO until per-table partition counts are tracked in the schema.

**Retry loop**: if the executor detects a read-set mismatch and returns `.abort { .code = .retry }`, the gateway updates the reconnaissance snapshot point to the seq the executor assigned, re-runs reconnaissance, and resubmits — up to 3 attempts. The `recon_retries` metric tracks how often this path is taken.

## Idempotency

Each client operation is assigned a stable `client_seq` that is preserved across retries. The sequencer deduplicates on `(client_id, client_seq)` — re-submitting the same operation returns the cached result without re-executing.

## Coordination

- **Sequencer**: DML mutations are submitted via `Sequencer.submitBytes()`, which assigns a global sequence number and writes the intent to the appropriate partition log after Raft replication of the ordering decision.
- **Executor**: Reads committed entries, validates them, and applies mutations to storage. Constraint violations and missing query hashes are returned as abort codes.
- **Storage**: SELECTs and `readAt` queries are served directly from storage without sequencer involvement.

## Error Conditions

| Error | Meaning |
|---|---|
| `QueryNotFound` | Hash not registered; call `register()` first |
| `ParamDecodeError` | Parameter count or type mismatch |
| `ConstraintViolation` | Mutation violated a constraint; retried up to 3 times |
| `SchemaBreakingChange` | DDL change incompatible with existing data |
| `TableNotFound` | Referenced table does not exist |
| `ExecutionError` | Executor returned a non-constraint abort |

Extended error detail is available via `lastDetail()`.

## What the Gateway Does Not Do

- Does not batch multiple client operations into a single sequencer epoch.
- Does not handle authentication or authorization — that is the network layer's responsibility.
- Does not perform cross-partition joins.
- Does not use pessimistic locking — concurrency is optimistic, validated in storage.
- Does not replicate across cluster nodes — Raft is currently single-node.

## Source Files

- `src/gateway/gateway.zig` — all gateway logic: register, execute, querySelect, readAt, nondeterminism resolution, validation
