# Storage Subsystem

Storage is a cache of folded state derived from the log. It is not the source of truth — the log is. Storage holds the materialized view of all committed mutations up to a given sequence number.

## Role

Accepts atomic mutation batches from the executor, persists them to an LSM-structured disk format, and serves consistent reads at a specified sequence number. Values are opaque `[]const u8` bytes — no schema, no column types, no type checking.

## Guarantees

- **MVCC reads**: `get()` and `scan()` return a consistent view at a caller-specified `seq`. Visibility rule: a row version is visible if its `write_seq <= at_seq`.
- **Atomic apply**: All mutations in a single `apply(mutations, seq)` call are committed atomically.
- **Durability**: Data survives process restarts via a disk-resident LSM (L0–L2 local levels).
- **Sequence monotonicity**: `apply()` is called with strictly increasing sequence numbers.

## Invariants

- **LSM structure**: L0 is unordered; L1–L2 are key-range partitioned. Each SSTable file carries `seq_min` / `seq_max` metadata. Compaction deduplicates by key (keeping the newest seq).
- **Sequence monotonicity**: Storage does not validate seq ordering — it is the executor's responsibility.

## Read Path

Multi-level merge: memtable → L0 (newest-first) → L1–L2 (binary search by file key range). Returns the first match satisfying the seq visibility rule.

## Write Path

Mutations route to the memtable. When the memtable fills, it is flushed to L0. When L0 reaches 4 files, compaction cascades to L1 and L2.

## Data Types

All keys and values are opaque `[]const u8`. The `Mutation` struct carries:

- `kind: MutationKind` — `.insert`, `.update`, or `.delete`
- `table_id: TableId` — legacy field, always `1`
- `key: []const u8` — the key
- `value: ?[]const u8` — the value (null for tombstones)

## Integration with Other Subsystems

- **Executor → Storage**: Executor calls `apply(mutations, seq)` with validated mutations.
- **Storage → CDC**: After each `apply()`, the executor dispatches CDC events using before-images from storage.

## Error Conditions

| Error | Meaning |
|---|---|
| `DiskFault` | Flush or compaction failure |

## Source Files

- `src/storage/storage.zig` — top-level API: apply, get, scan
- `src/storage/lsm.zig` — LSM tree: level management, compaction, visibility merge
- `src/storage/memtable.zig` — in-memory write buffer (skip list)
- `src/storage/sstable.zig` — sorted string table format for L1/L2
- `src/storage/block.zig` — block encoding and layout
- `src/storage/codec.zig` — key/value serialization
- `src/storage/types.zig` — shared types: Mutation, Row, KeyRange, ReadTracker
