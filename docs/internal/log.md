# Log Subsystem

The log is the sole source of truth in FoldDB. All state is derived by folding log entries in sequence order — storage is a cache, not an authority.

## Role

Provides a durable, append-only, sequence-ordered record of every mutation. Other subsystems write to the log; the executor reads from it to produce state.

## Partitioning

The log is partitioned into N **log partitions** (default 64, configurable at cluster creation). Each partition is an independent Raft group of 3 or 5 nodes. The Sequencer assigns a global total order across partitions; within a partition, Raft ordering is sufficient. Log partitions are independent of data partitions — see [Storage](storage.md).

## Guarantees

- **Durability**: Entries are persisted to disk before `appendEntry` returns. CRC32c validation covers both headers and payloads.
- **Immutability**: Written entries are never modified. Sequence numbers are permanent.
- **Sequence ordering**: Entries are strictly monotonically increasing by sequence number (`u64`). No gaps are permitted.
- **Epoch tracking**: Each entry carries a Raft epoch (term). The log tracks the current term and stamps new entries accordingly; historical entries retain their original epochs.
- **Crash recovery**: On open, the log scans the active segment to reconstruct `last_seq` for any entries written before a clean shutdown.

## Invariants

- `appendEntry()` requires `seq == current_seq + 1`. Violation returns `SeqOutOfOrder`.
- `appendEntryAt()` permits `seq > current_seq` (for Raft replication gaps) but `current_seq` always reflects the highest written sequence.
- Sealed segments are immutable. Only the active (current) segment accepts writes.
- A segment seals automatically at 10,000 entries and a new one is created.
- `seal()` is idempotent. Once sealed, no further appends are accepted.

## Entry Kinds

`txn_intent`, `schema_change`, `config_change`, `noop`, `snapshot_marker`, `epoch_decision`.

The log does not interpret payload semantics — callers are responsible for serializing and validating payloads before appending.

## Caller Responsibilities

- Enforce valid sequence numbers before calling `appendEntry`.
- Serialize payloads; the log treats them as opaque bytes.
- Own memory returned by `read()` — callers must deinit returned entries.
- Call `notifySnapshot(seq)` before truncating the prefix, to prevent live snapshotted entries from being discarded.

## Truncation

- **Prefix truncation** (`truncate_prefix`): Discards entries older than a snapshot point. Safe only after `notifySnapshot`.
- **Suffix truncation** (`truncateSuffix`): Resolves Raft log conflicts by removing entries newer than a given seq. Can unseal segments to restore an older active tail.

## Error Conditions

| Error | Meaning |
|---|---|
| `SeqOutOfOrder` | Append attempted with wrong sequence number |
| `CrcMismatch` | Payload or header corruption detected on read |
| `InvalidSegment` | Segment file header is malformed or unrecognized |
| `LogSealed` | Write attempted after `seal()` |
| `DiskFull` | No space to write new entry or segment |
| `SegmentNotFound` | Read requested seq not present in any segment |

## Subscription (Planned)

The spec defines a `subscribe(from: Seq) !Subscription` API for streaming ordered entries to executors as they are committed. The current implementation uses synchronous polling (`read(from_seq, max)`) instead. Streaming subscription is not yet implemented.

## What the Log Does Not Do

- No payload validation or schema awareness.
- No replication — that is Raft's responsibility.
- No execution — that is the Executor's responsibility.

## Observability

Metrics: `entries_appended`, `bytes_appended`, `entries_read`, `bytes_read`, `current_seq`, `segments_rotated`, `truncations`.

## Source Files

- `src/log/log.zig` — core log API: append, read, truncate, seal
- `src/log/manager.zig` — log lifecycle and segment rotation
- `src/log/segment.zig` — segment file format, header/footer, recovery scan
- `src/log/entry.zig` — entry structure and serialization
- `src/log/config_change.zig` — config change entry encoding
- `src/log/crc.zig` — CRC32c implementation
- `src/log/mod.zig` — module exports
