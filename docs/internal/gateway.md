# Gateway Subsystem

The gateway is the external boundary of FoldDB. It is the sole entry point for client operations — all validation, routing, and sequencer coordination happen here before anything touches the log.

## Role

Accepts client requests over the wire protocol, validates KV operations, submits mutations through the Sequencer for global ordering, and serves reads from Storage after the executor has caught up to the committed sequence.

## Public Operations

| Operation | Purpose |
|---|---|
| `set(key, value)` | Submit a key-value mutation through the Sequencer |
| `get(key)` | Read a key directly from Storage |
| `delete(key)` | Submit a deletion through the Sequencer |
| `range(start, end)` | Scan a key range from Storage |
| `batch(ops[])` | Run read-only ops in order or commit set/delete ops as one transaction |

All mutations (set, delete, mutating batch entries) go through the Sequencer for deterministic ordering. Reads (get, range) wait for committed intents to be applied, then read Storage. A mutating batch is submitted as one transaction with one committed sequence. Read-only batches are evaluated in request order. Mixed read/write batches are currently rejected.

## Mutation Path

1. Client sends a `SetRequest`, `DeleteRequest`, or mutating `BatchOp` via the wire protocol.
2. The gateway validates the request (key/value length, batch size limits).
3. The gateway submits the payload via `sequencer.submitBytes()`, which assigns a global sequence number and replicates the ordering decision via Raft.
4. The gateway calls `sequencer.awaitCommit()` to wait for the Raft ordering entry to be durable and committed.
5. The gateway sends a mutation response to the client with the committed sequence number. The executor applies committed intents to Storage in the background.
6. CAS mutations additionally wait for apply so the response can report whether the expected sequence matched.

## Read Path

1. Client sends a `GetRequest` or `RangeRequest`.
2. The gateway waits until the executor has applied the current committed sequence.
3. The gateway calls `storage.get()` or `storage.scan()`.
4. The result is encoded and returned.

## Idempotency

Each client operation carries a `stream_id` (u64) assigned by the client. The Sequencer deduplicates on `(client_id, client_seq)` — re-submitting the same operation returns the cached result without re-executing.

## Integration with Other Subsystems

- **Sequencer**: DML mutations are submitted via `Sequencer.submitBytes()` which assigns a global sequence number and writes to the Log after Raft replication.
- **Executor**: One instance running on a dedicated thread. Reads committed entries from the Log and applies KV mutations to Storage via `ExecutorDriver.drain()`.
- **Storage**: Single LSM tree instance. Serves reads directly and receives writes from the Executor.

## Error Conditions

| Error | Meaning |
|---|---|
| `key_too_long` | Key exceeds maximum length |
| `value_too_large` | Value exceeds maximum size |
| `batch_too_large` | Batch exceeds maximum operation count |
| `sequencer_full` | Sequencer queue is full; client should retry |
| `server_error` | Internal server error |

## Source Files

- `src/gateway/gateway.zig` — KV RPC handlers: handleSet, handleGet, handleDelete, handleRange, handleBatch
- `src/gateway/server.zig` — TCP listener, connection accept loop, frame dispatch
