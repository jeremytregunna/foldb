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
| `readAt(seq, hash, params)` | Historical read at a specific sequence number |

All operations require the query to be pre-registered. An unregistered hash returns `QueryNotFound`.

## Nondeterminism Resolution

Before forwarding a mutation to the sequencer, the gateway resolves all nondeterministic functions exactly once:

- `NOW()` and `UUID_V7()` — sourced from an injected `ClockSource`.
- `RANDOM()` — 16 bytes from an injected `RandSource`.

Resolved values are bundled into the intent payload. Clients may supply pre-resolved overrides, but gateway-resolved values take precedence. This ensures every replica applies the same values when the executor folds the entry.

## Validation

The gateway enforces three domain boundaries:

1. **DML entry**: After sequencer commit, `validateTxnEntry()` verifies the CRC of the serialized payload and decodes parameters against the registered query's type schema. Corrupted entries abort cleanly without reaching storage.
2. **SELECT/read**: Parameters are decoded and count-checked against the query's type schema before execution.
3. **DDL replay**: On restart, schema and query registry rebuild idempotently — duplicate `CREATE` statements are silently dropped.

## Reconnaissance

For queries whose read/write set cannot be statically determined at registration time (e.g. `WHERE` on a non-primary-key column), the gateway performs **reconnaissance** before submitting: it reads from a recent snapshot to discover which keys the transaction will actually touch, then includes this as a hint in the `TxnIntent`.

If the declared set turns out to be wrong by the time the executor runs the transaction (because another transaction modified relevant keys), the executor detects the mismatch, produces a retry marker at `seq`, and the gateway re-runs reconnaissance at the new seq and resubmits. For well-designed schemas (primary-key lookups, indexed scans), this never occurs.

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
