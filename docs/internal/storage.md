# Storage Subsystem

Storage is a cache of folded state derived from the log. It is not the source of truth — the log is. Storage holds the materialized view of all committed mutations up to a given sequence number.

## Role

Accepts atomic mutation batches from the executor, persists them to an LSM-structured disk format, and serves consistent reads at a specified sequence number. It also maintains secondary indexes (B-tree and vector) in sync with base-table mutations.

## Data Partitioning

Data is partitioned by primary key hash (`wyhash(0, key) % N`). Partition count is fixed at table creation. The `PartitionedStorage` wrapper routes reads and writes by this formula; `partitionFor(key, N)` in `partition_util.zig` exposes the same formula so executor and gateway code can compute partition IDs without holding a `PartitionedStorage`.

## Guarantees

- **MVCC reads**: `get()` and `scan()` return a consistent view at a caller-specified `seq`. Visibility rule: a row version is visible if its `write_seq <= at_seq`. Reads return the most recent visible version.
- **Atomic apply**: All mutations in a single `apply(mutations, seq)` call are committed atomically. No partial writes are observable.
- **Durability**: Data survives process restarts via a disk-resident LSM (L0–L2 local levels; L3 optional object store). The block cache is ephemeral — it provides no durability guarantee.
- **Index consistency**: Secondary indexes (JSON path and HNSW vector) are kept in sync with base-table mutations synchronously within each `apply()`. If index maintenance fails after the base-table write, all indexes are cleared and rebuilt from base-table state before the error is returned. Index backfill runs automatically when a new index is registered.
- **Snapshot isolation on vector search**: HNSW search respects sequence visibility — deleted and future-seq nodes are hidden from results.

## Invariants

- **LSM structure**: L0 is unordered; L1–L2 are key-range partitioned. Each SSTable file carries `seq_min` / `seq_max` metadata used to skip files that cannot satisfy the caller's `at_seq`. Compaction deduplicates by key (keeping the newest seq).
- **Block cache**: 2-clock LRU, 32 MiB default. Not persisted across restarts. L3 cache misses trigger a download from the object store.
- **HNSW vector index**: Fully in-memory; rebuilt from base-table scan on recovery. Deletes are soft-tombstoned — physical pruning happens after L0 compaction fires, not on each delete.
- **Sequence monotonicity**: `apply()` is called with strictly increasing sequence numbers. Storage does not validate this — it is the executor's responsibility.
- **PartitionedStorage routing**: The caller must use a consistent key hash (`wyhash(0, key) % N`) for all routing decisions. `scan` fans out to all partitions and merge-sorts by key — correctness depends on each partition holding disjoint key ranges (by hash mod N).

## Read Tracking (OCC)

`Storage` exposes a `read_tracker: ?*ReadTracker` field. When set, every `get()` and `scan()` records `(table_id, key, row_seq)` into the tracker. The executor attaches a tracker around handler calls to detect read-write conflicts against `recon_seq` (optimistic concurrency control).

Limitation: phantom reads from `scan()` (new keys inserted into a range after the recon seq) are not currently tracked. Range predicate tracking is a known gap.

## Read Path

Multi-level merge: memtable → L0 (newest-first) → L1–L2 (binary search by file key range) → L3 (remote). Returns the first match satisfying the seq visibility rule. Files whose `seq_min > at_seq` are skipped.

## Write Path

Mutations route to the memtable. When the memtable fills, it is flushed to L0. When L0 reaches 4 files, compaction cascades to L1, L2, and optionally L3.

## Caller Responsibilities

- Provide strictly increasing sequence numbers per `apply()` call.
- Validate schema and index descriptors before passing to storage — `column_idx` must be in-range and vector dimensions must match.
- Ensure column value types align with the table schema — storage does no dynamic type checking.
- Storage assumes a single executor thread per partition; concurrent writers are not supported.

## Snapshots

A snapshot captures table state at a given seq and writes a manifest to the object store (if configured). A `PostSnapshotHook` is called after each successful snapshot with the snapshot seq; the executor uses this to trigger log truncation and idempotency cache eviction. L3 consistency is best-effort — object store PUTs may lag or fail.

**Object store is optional.** When S3 is not configured, snapshots are disabled and the log is never truncated. Recovery requires full log replay. See `docs/internal/config.md`.

## Integration with Other Subsystems

- **Executor → Storage**: Executor calls `apply(mutations, seq)` with fully validated, pre-image-aware mutations.
- **Storage → Log**: Via a `SnapshotLogWriter` callback in `SnapshotPolicy`, storage signals the executor to write snapshot markers, enabling log prefix truncation.
- **Storage → CDC**: After a successful `apply()`, the executor dispatches CDC events using before-images sourced from storage reads taken prior to the apply.

## Error Conditions

| Error | Meaning |
|---|---|
| `DiskFault` | Flush or compaction failure; no automatic retry |
| Object store upload failure | L2→L3 compaction falls back to local copy; remote key not set |

## What Storage Does Not Do

- Does not validate mutation semantics (foreign keys, constraints, etc.).
- Does not manage transactions — per-entry atomicity only; cross-partition coordination is the executor's responsibility.
- Does not evaluate queries or expressions — that is the SQL layer's responsibility.
- Does not handle replication or distribution.
- Does not guarantee L3 crash consistency.

## Source Files

- `src/storage/storage.zig` — top-level API: apply, get, scan, index registration; also contains `PartitionedStorage` (routing wrapper over `[]*Storage`) and re-exports `S3Config`, `S3ObjectStore`, `BucketStyle`
- `src/storage/partition_util.zig` — `partitionFor(key, N)` helper; same hash formula as `PartitionedStorage.partitionIdx`, extracted so executor/gateway can route without a full `PartitionedStorage`
- `src/storage/lsm.zig` — LSM tree: level management, compaction, visibility merge
- `src/storage/memtable.zig` — in-memory write buffer
- `src/storage/sstable.zig` — sorted string table format for L1/L2
- `src/storage/block.zig` — block encoding and layout
- `src/storage/block_cache.zig` — 2-clock LRU block cache
- `src/storage/hnsw.zig` — HNSW vector index with sequence visibility
- `src/storage/json_index.zig` — JSON path secondary index maintenance
- `src/storage/json_path.zig` — JSON path expression evaluation
- `src/storage/snapshot.zig` — snapshot creation and manifest writing
- `src/storage/recovery.zig` — startup recovery from disk state
- `src/storage/object_store.zig` — L3 object store abstraction
- `src/storage/s3.zig` — S3-compatible object store; supports path-style and virtual-hosted-style buckets via `BucketStyle`; all requests signed with AWS Signature Version 4
- `src/storage/codec.zig` — row serialization and deserialization
- `src/storage/vector_codec.zig` — vector value encoding
- `src/storage/crc.zig` — CRC validation for storage blocks
- `src/storage/types.zig` — shared types: ColumnValue, Mutation, TableSchema, ReadTracker, ReadEntry
