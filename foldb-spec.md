# Foldb Engineering Specification

## Thesis

Foldb is a replicated deterministic key-value storage engine. Clients submit
opaque byte-key operations; the sequencer assigns a durable global order; storage
is the deterministic fold of the committed log.

## Non-Negotiable Invariants

1. The log is the source of truth.
2. Commit order is assigned once by the sequencer.
3. Applying the same committed log prefix produces the same storage state.
4. Acknowledged mutations survive restart through log replay.
5. Reads never invent state outside the selected sequence.

## Client API

Foldb exposes these operations:

- `GET key`
- `SET key value`
- `DELETE key`
- `RANGE start end`
- `BATCH ops`

Keys and values are opaque byte slices. Range scans are ordered by key.

## Gateway

The gateway decodes protocol frames, performs request validation, submits
mutations to the sequencer, applies committed mutations to storage for immediate
read-after-write visibility, and encodes responses.

## Sequencer

The sequencer assigns global sequence numbers and persists ordered decisions to
partition logs. Log replay on restart advances storage to the latest committed
sequence before the server accepts requests.

## Storage

Storage is an LSM tree with memtable, SSTables, compaction, snapshots, and
optional object-store tiering. Memtables are a write buffer, not the source of
truth; committed log entries remain replayable.

## Testing

Required coverage:

- protocol encode/decode tests;
- set/get/delete/range integration tests;
- committed-write recovery tests;
- compaction and replay tests;
- sequencer monotonicity and idempotency tests;
- deterministic KV simulation workloads.
