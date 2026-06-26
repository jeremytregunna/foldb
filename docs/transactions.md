# Transactions in FoldDB

FoldDB does not expose interactive multi-request transactions. The committed
unit is an ordered KV mutation submitted through the sequencer.

## Commit Model

`Set`, `Delete`, and mutating `Batch` operations are serialized by the
sequencer and assigned a global sequence number. The sequence number is durable
once the operation has been written to the partition log.

Reads (`Get` and `Range`) observe the latest applied sequence by default. `Get`
also accepts `at_seq` for historical reads when the requested version is still
available.

## Atomicity

A single `Set` or `Delete` is atomic. A `Batch` groups multiple protocol
operations in one round trip, but the current implementation sequences mutating
entries individually. Multi-key atomic batches are a separate storage contract
and should not be assumed until explicitly documented.

## Compare And Swap

`Set` supports `expected_seq`.

- `expected_seq = 0`: unconditional write.
- `expected_seq > 0`: write only if the current key version has that sequence.

On mismatch the server returns a mutation response with `cas_failed` set to the
current sequence and does not modify the key.

## Recovery

The partition log is the source of truth. On restart, FoldDB replays committed
KV intents from the log into storage before serving requests. This guarantees a
client-acknowledged write survives restart even if the in-memory memtable was
not flushed before shutdown.
