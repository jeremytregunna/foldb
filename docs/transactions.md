# Transactions in FoldDB

FoldDB does not expose interactive multi-request transactions. The committed
unit is an ordered KV mutation submitted through the sequencer.

## Commit Model

`Set`, `Delete`, and mutating `Batch` operations are serialized by the
sequencer and assigned a global sequence number. The sequence number is durable
once the operation has been committed to the Raft ordering log.

The executor applies committed intents to storage asynchronously. Reads (`Get`
and `Range`) wait for the executor to catch up to the current committed sequence
before reading storage. `Get` also accepts `at_seq` for historical reads when
the requested version is still available.

## Atomicity

A single `Set` or `Delete` is atomic. A mutating `Batch` is also atomic: all
set/delete operations in the batch share one committed sequence and are applied
as one executor transaction. Read-only batches remain an ordered request
convenience. Mixed read/write batches are currently rejected until transactional
reads are encoded in the intent format.

## Compare And Swap

`Set` supports `expected_seq`.

- `expected_seq = 0`: unconditional write.
- `expected_seq > 0`: write only if the current key version has that sequence.

On mismatch the server returns a mutation response with `cas_failed` set to the
current sequence and does not modify the key.

## Recovery

The Raft ordering log is the source of truth for acknowledged intents. On
restart, FoldDB applies committed ordering entries to the partition logs, then
replays committed KV intents into storage before serving requests. This
guarantees a client-acknowledged write survives restart even if the in-memory
memtable was not flushed before shutdown.
