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

**Implementation — row-level granularity**: partition IDs are derived by hashing encoded primary keys, not by `table_id % partition_count`. For `pk_lookup` nodes the key expression is evaluated statically when it resolves to a literal or bound parameter. For full-table `scan` nodes and non-PK DML (UPDATE/DELETE/MERGE), the gateway runs an actual snapshot read of the table at `at_seq` and hashes each row's encoded key via `wyhash(key) % partition_count`. This is exact rather than an over-approximation. With the current `partition_count = 1` default the result is always partition 0, but the routing is correct for any `N`.

**Retry loop**: if the executor detects a read-set mismatch and returns `.abort { .code = .retry }`, the gateway updates the reconnaissance snapshot point to the seq the executor assigned, re-runs reconnaissance, and resubmits — up to 3 attempts. The `recon_retries` metric tracks how often this path is taken.

## Idempotency

Each client operation is assigned a stable `client_seq` that is preserved across retries. The sequencer deduplicates on `(client_id, client_seq)` — re-submitting the same operation returns the cached result without re-executing.

## Coordination

- **Sequencer**: DML mutations are submitted via `Sequencer.submitBytes()`, which assigns a global sequence number and writes the intent to the appropriate partition log after Raft replication of the ordering decision.
- **Executor**: Reads committed entries, validates them, and applies mutations to storage. Constraint violations and missing query hashes are returned as abort codes.
- **Storage**: SELECTs and `readAt` queries are served directly from storage without sequencer involvement.

## Storage Backend

The gateway manages `partition_count` storage instances, created at init under `{storage_dir}/p0`, `{storage_dir}/p1`, etc. All internal calls (`SqlExecutor`, `reconnaissanceScan`, `applyDdlToSchema`, `flushAll`) route through a `PartitionedStorage` wrapper.

S3 object store support is configured via `Options`:

| Field | Purpose |
|---|---|
| `s3_endpoint_ip` / `s3_endpoint_host` / `s3_endpoint_port` | Endpoint address for connection and Host header |
| `s3_access_key` / `s3_secret_key` / `s3_region` | AWS credentials and signing region |
| `s3_bucket` | Bucket name |
| `s3_bucket_style` | `.path` (S3-compatible servers) or `.virtual_hosted` (AWS S3) |
| `s3_cache_dir` | Local dir for downloaded L3 blocks; defaults to `storage_dir` |

When both `s3_access_key` and `s3_bucket` are non-empty, `init()` heap-allocates an `S3ObjectStore` (`?*S3ObjectStore`) and wires it into all storage partitions via `setObjectStore()`. It is heap-allocated so the `*anyopaque` VTable pointer remains stable. Freed in `deinit()`.

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
- Does not support dynamic cluster reconfiguration — multi-node Raft replication via `TcpTransport` is supported, but adding or removing nodes at runtime is not.

## Source Files

- `src/gateway/gateway.zig` — all gateway logic: register, execute, querySelect, readAt, nondeterminism resolution, validation
