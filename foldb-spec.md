# Foldb — Engineering Specification

**Version:** 0.1 (design draft)
**Implementation language:** Zig
**Status:** Pre-implementation; intended as the working spec to build against.

---

## 0. How to read this spec

This document is organized so you can build the system in the order it's written. Each section ends with concrete deliverables and the invariants that must hold. Where a decision has genuine alternatives, they're listed with the rationale for the choice. Where a decision is deferred, it's marked `[OPEN]`.

The spec is opinionated. Every "don't" exists because the alternative was considered and rejected for a reason stated in the text.

---

## 1. Thesis and non-negotiables

A database that is a **replicated, deterministic state machine over a shared log**. Two components: an append-only totally-ordered log, and a pure fold function from log to state. Everything else is implementation.

**Non-negotiable invariants.** These are the properties the rest of the system is built to preserve. If a proposed change would violate one of these, the change is wrong.

1. **Log is the sole source of truth.** State on disk is a cache of `fold(log_prefix)`. If state disagrees with the fold of the log, state is wrong.
2. **Commit precedes execution.** A transaction is committed when its entry is durable in the log at a sequence number. Execution is a deterministic consequence.
3. **Determinism is total.** Given the same log prefix, every node produces bit-identical state. No wall clocks, no RNGs, no external calls inside the fold.
4. **Order is assigned once.** Every committed transaction has exactly one sequence number (`seq`), monotonically increasing, gap-free, cluster-wide.
5. **Isolation is strict serializable.** There is no weaker level. Stale reads are expressed by explicitly naming a past `seq`, not by weakening isolation.
6. **Schema is in the log.** DDL is a transaction. There is no side channel for metadata.

---

## 2. System overview

```
                     ┌────────────────────────────────────┐
                     │            Clients                 │
                     └──────────────┬─────────────────────┘
                                    │ prepared queries + params
                                    ▼
                ┌───────────────────────────────────┐
                │         Gateway (any node)        │
                │  - parse / type-check at register │
                │  - bind params, reconnaissance    │
                │  - resolve nondeterminism         │
                │  - submit to Sequencer            │
                └──────────────┬────────────────────┘
                               │ TxnIntent
                               ▼
                ┌───────────────────────────────────┐
                │           Sequencer               │
                │  - per-epoch batch ordering       │
                │  - Raft-replicated decisions      │
                │  - emits global seq numbers       │
                └──────────────┬────────────────────┘
                               │ ordered TxnIntents
                               ▼
                ┌───────────────────────────────────┐
                │              Log                  │
                │  - partitioned, Raft per part.    │
                │  - append-only, durable           │
                └──────────────┬────────────────────┘
                               │ ordered stream
                               ▼
                ┌───────────────────────────────────┐
                │          Fold Executor            │
                │  - per-partition single-threaded  │
                │  - deterministic dataflow for     │
                │    cross-partition txns           │
                │  - produces LSM mutations         │
                └──────────────┬────────────────────┘
                               ▼
                ┌───────────────────────────────────┐
                │      Storage (LSM, PAX, tiered)   │
                │  RAM → local NVMe → object store  │
                └───────────────────────────────────┘
                               ▲
                               │ read at any seq
                               │
                          ┌────┴────┐
                          │ Readers │
                          └─────────┘
```

Subsystems, in the order they'll be built:

1. **Log** — append-only, replicated, sequenced.
2. **Storage** — LSM with PAX value layout, tiered.
3. **Fold Executor** — deterministic, partition-parallel.
4. **Sequencer** — global ordering of transaction intents.
5. **Gateway** — SQL registration, binding, reconnaissance, nondeterminism resolution.
6. **SQL front-end** — parser, type checker, planner.
7. **Client protocol** — prepared queries, result streaming, CDC.
8. **Operations** — snapshots, recovery, reconfiguration, observability.

---

## 3. Why Zig

Zig gives us three things that matter for this system: explicit allocation (every buffer's lifetime is visible, critical for an engine where object lifetimes are dominated by the log frontier), compile-time metaprogramming (for generating per-type LSM serializers and SIMD codecs from schema), and `comptime`-enforced invariants (we can make "this function cannot allocate" a type-level property). No hidden control flow, no hidden allocator, no runtime. The fold function's determinism requirement is much easier to enforce in a language where all nondeterminism is explicit syntax.

Trade-offs accepted: pre-1.0 language churn, smaller ecosystem than Rust/C++, async story is evolving. We mitigate by minimizing external dependencies (see §14).

---

## 4. Core types

These are the types that cross subsystem boundaries. Internal types are not specified here.

```zig
// ---------- identifiers ----------
pub const Seq = u64;              // global sequence number, gap-free
pub const Epoch = u64;            // sequencer epoch, monotonic
pub const PartitionId = u32;      // 0..N-1, fixed at cluster creation
pub const NodeId = u64;           // unique per process lifetime
pub const TableId = u32;          // assigned by schema txn
pub const ColumnId = u16;
pub const IndexId = u32;
pub const QueryHash = [32]u8;     // BLAKE3 of canonicalized query AST

// ---------- time ----------
pub const LogicalTime = Seq;      // the only time that exists inside the fold

// ---------- log entry ----------
pub const EntryKind = enum(u8) {
    txn_intent = 1,
    schema_change = 2,            // still a txn, separated for fast filtering
    config_change = 3,            // cluster membership
    noop = 4,                     // sequencer heartbeat / gap filler
    snapshot_marker = 5,
};

pub const LogEntry = struct {
    seq: Seq,
    epoch: Epoch,
    kind: EntryKind,
    payload_len: u32,
    payload_crc: u32,             // CRC32C of payload
    // payload follows: see TxnIntent for kind=txn_intent
};

// ---------- transaction intent ----------
pub const TxnIntent = struct {
    query_hash: QueryHash,        // references a registered query
    params: []const u8,           // length-prefixed, typed, canonical encoding
    read_set_hint: ReadSetHint,   // partitions touched, for routing
    write_set_hint: WriteSetHint, // partitions touched, for routing
    resolved_nondet: []const ResolvedValue, // see §9
    client_id: u64,
    client_seq: u64,              // for idempotency
};

pub const ResolvedValue = union(enum) {
    now: i64,                     // unix micros, resolved by gateway
    random: [16]u8,               // 128-bit, resolved by gateway
    uuid_v7: [16]u8,              // resolved by gateway
};
```

**Invariant.** `TxnIntent` is self-contained: once it's in the log, executing it requires no external state beyond the registered query referenced by `query_hash` and the database state at `seq - 1`.

---

## 5. The Log

### 5.1 Responsibilities

1. Accept `TxnIntent` from the Sequencer, assign it a `seq`, persist it durably on a quorum of replicas.
2. Serve ordered reads of the log to executors.
3. Truncate log prefix once a snapshot at or past that prefix has been durably uploaded.

### 5.2 Structure

The log is partitioned into `N` **log partitions** (default 64; configurable at cluster creation). Each partition is a Raft group of 3 or 5 nodes. The Sequencer (§8) produces a global total order across partitions; within a partition, Raft's ordering is sufficient.

**Why partitioned rather than single Raft group?** A single Raft group caps throughput at one leader's append bandwidth. 64 partitions × a few hundred thousand entries/sec per partition gives us tens of millions of txns/sec ceiling. The Sequencer's ordering decisions are cheap (ordering a batch is O(batch size), not O(state)), so it's not the bottleneck the leader of a single Raft group would be.

### 5.3 On-disk format

Each log partition is a sequence of **segments**, each a file of configurable size (default 256 MiB). Segments are immutable once sealed.

```
segment file layout:
  ┌─────────────────────────────────────────────────┐
  │ segment header (64 B, fixed)                     │
  │   magic="FLOG" version part_id base_seq ...      │
  ├─────────────────────────────────────────────────┤
  │ entry 0: LogEntry header + payload              │
  │ entry 1: LogEntry header + payload              │
  │ ...                                              │
  ├─────────────────────────────────────────────────┤
  │ segment footer (64 B)                            │
  │   entry_count last_seq index_offset crc          │
  ├─────────────────────────────────────────────────┤
  │ entry index (seq → file offset, sparse)          │
  └─────────────────────────────────────────────────┘
```

Entries are written with `O_DIRECT | O_DSYNC` on Linux; we do our own buffering aligned to 4 KiB. Each append batches entries up to a deadline (default 500 µs) or a size cap (default 1 MiB) to amortize fsync cost.

### 5.4 Replication

Raft, with two specific modifications:

1. **Batched replication.** The leader sends ranges of entries, not individual entries. Followers ack ranges.
2. **Append ack split from apply ack.** "Durable on a quorum" (the thing Raft guarantees) is what matters for commit. "Applied to state" is separate and follower-local.

**Why Raft and not Paxos / EPaxos / Viewstamped Replication?** Raft has the best operational story (understandable, debuggable, lots of prior art), and its leader-based model matches our workload: the Sequencer is already serializing ordering decisions, so having a Raft leader per log partition adds no additional bottleneck.

### 5.5 API

```zig
pub const Log = struct {
    pub fn append(self: *Log, intent: TxnIntent) !Seq;
    pub fn read(self: *Log, from: Seq, max: usize, out: []LogEntry) !usize;
    pub fn subscribe(self: *Log, from: Seq) !Subscription;
    pub fn truncate_prefix(self: *Log, before: Seq) !void;
};
```

### 5.6 Invariants

- `append` returns only after the entry is durable on a quorum.
- `read(from: s)` returns entries with `seq >= s` in monotonic `seq` order with no gaps.
- Once `append` returns `seq = s`, no future `append` will return `s'` with `s' <= s`.
- Truncation never removes entries whose effects are not captured by a durable snapshot.

### 5.7 Deliverables

- [ ] Segment reader/writer with CRC validation.
- [ ] Raft implementation (single partition first).
- [ ] Multi-partition log manager.
- [ ] Durability tests: kill -9 at every I/O boundary, verify no torn reads.
- [ ] Jepsen-style linearizability test for single-partition append.

---

## 6. Storage

### 6.1 Responsibilities

Materialize the fold output. Be a correct, fast cache of `fold(log_prefix)` at one or more recent `seq` values.

### 6.2 Shape

Per data partition (data partitions ≠ log partitions; see §6.6), state is an LSM tree:

```
  memtable (skip list, in RAM)
      │  flush on size or on seq advance
      ▼
  L0 SSTables (a few, overlapping key ranges)
      │  compact
      ▼
  L1 SSTables (size-tiered, then leveled from L2)
      ▼
  L2..Ln SSTables (leveled, exponential size ratio)
      ▼
  cold tier: object storage (same SSTable format, remote reads)
```

### 6.3 SSTable format: PAX values

Keys are the primary key of the table, big-endian encoded for correct ordering. Values are **row groups** of 64–512 rows, PAX-laid out:

```
SSTable block layout (typical 64 KiB):
  ┌──────────────────────────────────────┐
  │ block header                         │
  │   row_count, column_count, codecs    │
  ├──────────────────────────────────────┤
  │ column 0 data  (contiguous, coded)   │
  │ column 1 data  (contiguous, coded)   │
  │ ...                                  │
  │ column N data                        │
  ├──────────────────────────────────────┤
  │ null bitmap (per column, bit-packed) │
  ├──────────────────────────────────────┤
  │ block footer (crc, offsets)          │
  └──────────────────────────────────────┘
```

Encoding per column, chosen per block by a small heuristic on dictionary size and run length: dictionary, RLE, frame-of-reference, or raw. Compression applied to the whole block (zstd level 3 default; configurable).

**Why PAX and not pure row or pure columnar?** OLTP point lookups need one row's worth of I/O, which PAX gives us (one block, decode one row from each column). Large scans get columnar compression and SIMD-friendly decoding. We lose some point-lookup locality vs pure row storage, but blocks are small enough (64 KiB) that it's a rounding error on NVMe.

### 6.4 Indexes

All indexes are additional LSM trees whose keys are `(indexed_columns..., primary_key)` and whose values are empty (covering indexes are a different tree with the covered columns as the value). Indexes are produced by the fold, at the same `seq` as their base table. **There is no "index build" operation**; creating an index is a schema change that causes the fold to start emitting entries for it, plus a backfill transaction that walks the base table at a specific `seq` and emits index entries.

Secondary index types: ordered (default), hash, vector (HNSW, described in §11), full-text (deferred, `[OPEN]`).

### 6.5 Learned indexes (hot ranges only)

For large, stable, read-heavy tables, we replace the in-memory index of the LSM levels with a small learned model (piecewise linear regression, following the RMI design) predicting position within ±32 keys, then a bounded binary search. This is an optimization, not a correctness feature; disable if the model error exceeds a threshold.

### 6.6 Data partitioning

Data is partitioned by primary key hash (default) or range (opt-in per table, for natural-order scans). Number of data partitions is fixed at table creation; resharding is a future feature `[OPEN]`.

Data partitions are independent of log partitions. A transaction's intent lives in whichever log partition the Sequencer assigns (for load balance); its execution touches whichever data partitions its keys hash to.

### 6.7 Tiered storage

Every SSTable has three possible locations, checked in order on read:

1. **RAM block cache** (clock-pro or similar).
2. **Local NVMe** (canonical location for L0–L2).
3. **Object storage** (canonical for L3+; local copy is a cache).

Migration between tiers is policy-driven by age and access frequency. Object storage is the durable long-term home; local SSDs can be lost without data loss (state re-materializes from log + object store).

### 6.8 API

```zig
pub const Storage = struct {
    pub fn get(self: *Storage, table: TableId, key: []const u8, at_seq: Seq) !?Row;
    pub fn scan(self: *Storage, table: TableId, range: KeyRange, at_seq: Seq) !Iterator;
    pub fn apply(self: *Storage, mutations: []const Mutation, at_seq: Seq) !void;
    pub fn snapshot(self: *Storage, at_seq: Seq) !SnapshotHandle;
};
```

`apply` is called only by the Fold Executor. Mutations are buffered by `seq` so readers at earlier `seq` see consistent state.

### 6.9 Invariants

- Read at `seq = s` returns state equal to `fold(log[0..=s])` restricted to the queried keys.
- An SSTable's contents are uniquely determined by the `seq` range it covers and the log entries in that range.
- Compaction changes on-disk layout but not logical contents.

### 6.10 Deliverables

- [ ] SSTable writer/reader with PAX blocks and per-column codecs.
- [ ] LSM engine with leveled compaction.
- [ ] Tiered storage with object-store backend (S3-compatible).
- [ ] Block cache.
- [ ] MVCC snapshot reads by `seq`.
- [ ] Deterministic replay test: feed same log to two fresh nodes, byte-compare SSTables.

---

## 7. Fold Executor

### 7.1 Responsibilities

Consume `LogEntry` stream. For each `txn_intent`, execute it deterministically and apply resulting mutations to storage at `seq`.

### 7.2 Per-partition executor

One thread (or thread-pool-pinned worker) per data partition. For each entry:

1. Look up registered query by `query_hash`.
2. Bind params from `TxnIntent.params` and `resolved_nondet`.
3. For each statement in the transaction, execute against storage at `seq - 1`, buffer writes.
4. If the transaction is single-partition: apply buffered writes at `seq`.
5. If multi-partition: participate in the dataflow (§7.3).
6. If an `ASSERT` or constraint fails: produce a deterministic abort record at `seq`. No writes are applied. The client sees the error.

**This worker is single-threaded per partition by design.** No locks, no concurrency control, no MVCC inside a partition's execution — it processes log entries in order, one at a time. Parallelism comes from having many partitions.

### 7.3 Multi-partition execution

When a transaction touches partitions P1 and P2:

1. Both P1 and P2's executors reach `seq` in their respective streams.
2. They exchange the **values** each needs from the other (not locks, not votes — just the reads the transaction requires from the other partition's state at `seq - 1`).
3. Each independently executes its slice of the transaction using local writes + received values.
4. Each applies its local writes at `seq`.

Because the transaction's logic is deterministic and both sides see the same input values, they produce consistent results without voting. A constraint violation at P1 is observed identically at P2 (P2 computes the same predicate on the exchanged values).

The exchange uses a dedicated intra-cluster RPC with RDMA when available. Exchange messages are addressed by `(seq, partition_id)` so late-joining followers can replay them from peers.

### 7.4 Determinism enforcement

Inside the executor, the following are **compile-time forbidden** in query execution code:

- System clock reads (use `logical_time = seq` only).
- RNG calls (use `resolved_nondet` only).
- Map/hash iteration order dependence (all hash maps used inside execution use a deterministic ordering or are sorted before iteration).
- Floating-point operations where ordering matters. Floats are allowed as a storage type but aggregations over them use a deterministic ordering (sorted by key).

Enforced by a `comptime` check on the execution module: the set of imports is whitelisted. Any module reachable from query execution transitively must be on the whitelist. Violating is a compile error.

### 7.5 API

```zig
pub const Executor = struct {
    pub fn run(self: *Executor, entry: LogEntry) !ExecResult;
    pub fn current_seq(self: *Executor) Seq;
};

pub const ExecResult = union(enum) {
    ok: struct { rows_affected: u64, result_set: ?ResultSet },
    abort: struct { code: AbortCode, detail: []const u8 },
};
```

### 7.6 Invariants

- `run(entry)` called with the same `entry` on two nodes with identical state at `seq - 1` produces identical `ExecResult` and identical mutations.
- A transaction either fully applies its mutations at `seq` or applies none (and an abort is recorded).
- `current_seq` is monotonic.

### 7.7 Deliverables

- [ ] Single-partition executor with constraint checking.
- [ ] Multi-partition dataflow protocol.
- [ ] Determinism whitelist and `comptime` enforcement.
- [ ] Replay equivalence test across nodes.

---

## 8. Sequencer

### 8.1 Responsibilities

Take a firehose of `TxnIntent`s from gateways, impose a global total order, stamp them with consecutive `seq` numbers, hand them to the appropriate log partitions.

### 8.2 Design

The Sequencer is a Raft-replicated service, but it does *not* replicate intents (that's the Log's job). It replicates only **ordering decisions**: batches of `(seq, log_partition, entry_descriptor)` tuples.

Flow:

1. Gateways send intents to any Sequencer replica.
2. The Sequencer leader groups intents into **epochs** (default 1 ms wall-clock or 10,000 intents, whichever comes first).
3. At epoch close, the leader assigns `seq` numbers to every intent in the epoch and decides which log partition each goes to (round-robin weighted by recent load).
4. The ordering decision is replicated via Raft.
5. Once committed in the Sequencer's Raft, intents are forwarded to their log partitions for durable persistence. Log partition append is what makes the transaction actually committed.

**Why this split (Sequencer vs Log)?** The Sequencer's job is small and CPU-bound (sort and assign). The Log's job is I/O-heavy (durable append). Separating them lets us scale Log bandwidth by adding log partitions while keeping ordering decisions cheap.

### 8.3 Failure modes

- Sequencer leader failure: Raft re-elects. Epochs in flight at the moment of failure are either fully committed or fully lost (the leader's epoch-close write is atomic in Raft).
- Log partition failure: Sequencer retries append to that partition after it recovers. Since intents are durably in the Sequencer's Raft log, they're not lost; their final durable commit is just delayed.
- Split brain: Raft's standard guarantees apply.

### 8.4 API

```zig
pub const Sequencer = struct {
    pub fn submit(self: *Sequencer, intent: TxnIntent) !SubmitHandle;
};

pub const SubmitHandle = struct {
    pub fn await_commit(self: *SubmitHandle) !Seq;  // returns when intent's seq is durable in the Log
};
```

### 8.5 Invariants

- Every `TxnIntent` accepted by `submit` eventually gets a unique `seq` or a failure is returned to the caller.
- `seq` values are dense (no gaps) and monotonic.
- The same `TxnIntent` submitted twice (identified by `client_id, client_seq`) gets the same `seq` (idempotency).

### 8.6 Deliverables

- [ ] Epoch batcher.
- [ ] Raft-replicated ordering decisions.
- [ ] Idempotency cache.
- [ ] Routing to log partitions.

---

## 9. Gateway

### 9.1 Responsibilities

Client-facing. Take a SQL query invocation, produce a `TxnIntent`, submit to Sequencer, return the result.

### 9.2 Flow

1. Client sends `(query_hash, params)`.
2. Gateway looks up the registered query.
3. Gateway **resolves nondeterminism**: any `NOW()`, `RANDOM()`, or `UUID()` in the query is computed here and added to `resolved_nondet`. The query's AST references these by position, not by function call.
4. Gateway does **reconnaissance** if the read/write set depends on values not statically determinable (e.g., a `WHERE` clause on a non-primary-key column that can't be resolved at registration): it reads from a recent snapshot to discover the set. The reconnaissance result goes into the intent as a hint. If the set was wrong by the time the transaction executes (because another transaction touched relevant keys), the executor re-reads and re-executes.
5. Gateway submits `TxnIntent` to Sequencer.
6. Gateway awaits commit, then fetches result from a local or nearby executor.
7. Gateway returns result to client.

### 9.3 Reconnaissance details

Reconnaissance is the one place where a transaction can "fail and retry" in this system. The failure mode is: the intent declared it would touch keys K, but by the time it executes, the query logic would touch keys K' ≠ K. The executor detects this (the query's actual read set, computed during execution, exceeds the declared set) and emits a retry marker at `seq`. The gateway sees the retry, re-does reconnaissance at the new `seq`, and resubmits.

For well-designed schemas (primary-key lookups, indexed scans) this never happens. For queries like `UPDATE t SET x = x+1 WHERE complicated_predicate(y)`, it might happen a few percent of the time.

### 9.4 API

```zig
pub const Gateway = struct {
    pub fn register(self: *Gateway, sql: []const u8) !RegisterResult;
    pub fn execute(self: *Gateway, hash: QueryHash, params: []const u8) !ExecResult;
    pub fn read_at(self: *Gateway, hash: QueryHash, params: []const u8, seq: Seq) !ResultSet;
};
```

### 9.5 Invariants

- A registered query's `QueryHash` uniquely determines its AST and type signature forever.
- No transaction is submitted without all nondeterminism resolved.

### 9.6 Deliverables

- [ ] Query registration with schema-version pinning.
- [ ] Nondeterminism resolver.
- [ ] Reconnaissance with retry loop.
- [ ] Result routing from nearby executor.

---

## 10. SQL front-end

### 10.1 What SQL we accept

A subset with sharp edges ground off:

- Standard DDL: `CREATE TABLE`, `CREATE INDEX`, `ALTER TABLE`.
- Standard DML: `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `MERGE`.
- `WITH` (CTEs), window functions, `GROUP BY`, `HAVING`, subqueries.
- A transaction block: `TRANSACTION (params) { stmt; stmt; ASSERT expr; }`.

### 10.2 What SQL we reject

Rejected at parse or type-check time, with specific errors:

- `SELECT *` inside a registered query. Fine at the REPL; not in registered code.
- Implicit type coercions. `'5' = 5` is an error; write `'5'::int = 5`.
- Nullable-by-default columns. `CREATE TABLE` requires explicit `NULL` or `NOT NULL` per column.
- Three-valued logic in `WHERE`. `NULL` comparisons use `IS [NOT] NULL` or `IS [NOT] DISTINCT FROM`; `=` on a possibly-null column is an error unless one side is a literal non-null value and the column is declared `NOT NULL`, or the query explicitly uses `IS`.
- Unqualified column references in joins. Ambiguity is a parse error, not a runtime guess.
- `ORDER BY` on non-selected columns in queries that will be consumed as streams (allowed in top-level queries where output is materialized).
- Side-effecting functions in `WHERE`, `ON`, etc. (the determinism whitelist applies).
- Triggers, stored procedures in a bespoke language. (Use WASM modules if you need server-side logic; see §10.6.)

### 10.3 Types

Typed more strictly than Postgres/SQL standard.

| Type | Notes |
|------|-------|
| `BOOL` | |
| `INT8, INT16, INT32, INT64` | Overflow is an error by default; `WRAPPING` modifier for wrap-around semantics. |
| `UINT8..UINT64` | |
| `FLOAT32, FLOAT64` | IEEE 754, NaN comparisons are errors. |
| `DECIMAL(p, s)` | Arbitrary precision within bounds. |
| `STRING` | UTF-8, bounded or unbounded. |
| `BYTES` | |
| `UUID` | |
| `TIMESTAMP` | Logical type, microsecond precision, always UTC. No timezone-aware variant; store a separate zone column if you need one. |
| `INTERVAL` | Explicit months vs. micros (separate types), no ambiguous "1 month"+"30 days" nonsense. |
| `JSON` | With optional schema constraint. Indexable on specified paths. |
| `VECTOR(dim)` | Fixed dimension. ANN-indexable. |
| `ARRAY<T>` | |
| `STRUCT<...>` | Named fields. |

### 10.4 Isolation

Only strict serializable. The `ISOLATION LEVEL` clause is a parse error; we tell you why in the error message.

### 10.5 Schema changes

All DDL is a transaction. A `CREATE INDEX` is a single log entry whose fold effect is (a) add the index to the schema, (b) emit a backfill task that will execute in subsequent log entries. The index is usable for reads at `seq >= backfill_complete_seq` and unusable before (not incorrect: unusable, queries planner-rejected).

Schema changes are validated against all currently-registered queries before they're accepted. If a migration would break a registered query, it's rejected with the list of breaking queries. If you need to break a query, deregister it first.

### 10.6 WASM modules for server-side logic

When a transaction's logic is too complex for SQL alone, it can be expressed as a WASM module referenced by hash. The module is loaded at registration time; its exports are callable from transaction bodies.

Constraints: the WASM runtime is configured to disable all nondeterministic opcodes (no SIMD floats with NaN-propagation variance, no threads, no host function calls except a whitelisted set for reading inputs and writing outputs). This is enforced at module load.

### 10.7 Deliverables

- [ ] Parser.
- [ ] Type checker with the strict rules above.
- [ ] Planner producing a deterministic execution plan (seeded sort orders everywhere).
- [ ] WASM runtime integration (wasmtime via FFI, or a pure-Zig interpreter for small functions).
- [ ] Query canonicalization for hashing.

---

## 11. Specialty indexes

### 11.1 Vector index (HNSW)

For `VECTOR(n)` columns. HNSW because it has the best recall/latency trade-off at OLTP-compatible point-query latencies. Inserts go into the graph at transaction commit; deletes are tombstoned and cleaned in compaction.

Parameters (default): M=16, ef_construction=200, ef_search=64 (configurable per query).

### 11.2 JSON path index

Declare paths at index creation; index is a standard LSM on `(path_value, primary_key)`.

### 11.3 Full-text

`[OPEN]`. BM25 over tokenized fields, probably. Deferred to post-v1.

---

## 12. CDC (Change Data Capture)

### 12.1 Shape

Every committed log entry is, by definition, the change stream. CDC is just "subscribe to the log starting at `seq`, optionally filtered to entries affecting table T."

Consumers get:

```
{
  seq: 12345,
  epoch: 42,
  kind: txn_intent,
  effects: [
    { table: "accounts", key: "...", op: update, before: {...}, after: {...} },
    ...
  ]
}
```

`before` requires access to state at `seq - 1` for the affected keys. The fold executor emits it as a side output when CDC subscribers exist for the table; otherwise it's computed on demand by reading at `seq - 1`.

### 12.2 Delivery

At-least-once to the consumer; consumers track their `seq` and the system guarantees gap-free ordered delivery from that `seq`. Exactly-once is the consumer's responsibility (idempotent consumers, or transactional sinks).

### 12.3 API

```zig
pub const CdcSubscription = struct {
    pub fn next(self: *CdcSubscription, out: []CdcEvent) !usize;
    pub fn ack(self: *CdcSubscription, seq: Seq) !void;
};
```

---

## 13. Operations

### 13.1 Snapshots

Periodic (default: every 10M entries or 1 hour) per data partition. A snapshot is:

1. Storage computes a consistent set of SSTables at some `seq = S`.
2. SSTables already in object storage are referenced; others are uploaded.
3. A `snapshot_marker` entry is written to the log at `seq > S` recording the snapshot's manifest location.

Recovery: a fresh node fetches the latest snapshot manifest, downloads SSTables it doesn't have, then replays log from the snapshot's `seq` forward.

### 13.2 Log truncation

Log entries before `seq = S` can be truncated once:
- A snapshot at or after `S` is durable in object storage, AND
- All live CDC subscribers are past `S`, AND
- All live read-at-`seq` requests are for `seq > S`.

Truncation removes whole segments only.

### 13.3 Reconfiguration

Adding/removing nodes is a `config_change` log entry. The config change takes effect at its `seq`. Raft membership changes piggyback on this.

Resharding (changing partition count) is `[OPEN]` for v1. Initial design: pick partition count generously (64 or 128) at cluster creation; do not reshard.

### 13.4 Observability

Every subsystem exports:
- `current_seq` (what seq has this subsystem processed up to).
- `lag` (seq behind the log head).
- Throughput counters (entries/sec, bytes/sec).
- Latency histograms at percentile boundaries.

Tracing: every `TxnIntent` gets a trace id; spans cover gateway → sequencer → log → executor.

Debugging affordance: given a `seq`, the system can dump the exact `TxnIntent`, the state it read, and the mutations it produced. Because execution is deterministic, this is reproducible on any node.

---

## 14. Dependencies

Minimize aggressively. Planned external dependencies:

- **zstd** (C library) — block compression.
- **BLAKE3** — hashing. Can be pure Zig or FFI.
- **wasmtime** (C API) — WASM execution. Swappable for a pure-Zig interpreter if we want to shed this.
- **S3 client** — write our own against the HTTP API; don't pull in AWS SDK.
- **io_uring** — Linux I/O. Direct syscalls, no library.

Explicitly not used: RocksDB (we're building the LSM), any ORM, any async runtime (we'll use Zig's async / a simple thread pool model; decide at §15).

---

## 15. Concurrency model inside a single Zig process

One process per node. Threads:

- **I/O threads**: `io_uring` submission/completion, one per device (log SSD, data SSD).
- **Executor threads**: one per data partition hosted on this node, pinned to a core.
- **Sequencer thread**: if this node is the Sequencer leader, one thread for epoch batching.
- **Gateway threads**: a small pool for client-facing I/O.
- **Background threads**: compaction, snapshotting, tiering.

No shared mutable state across executor threads (partitions are independent). Cross-thread communication via SPSC/MPSC ring buffers.

Allocators: per-thread arena allocators for per-transaction work; a general-purpose allocator (page-based, with freelist) for long-lived data. `comptime`-propagated `std.mem.Allocator` parameters throughout. No global allocator.

---

## 16. Wire protocol

Binary, length-prefixed, versioned. Sketch:

```
frame:
  u32 length
  u16 version
  u8  kind    // request, response, push (cdc), error, ping
  u8  flags
  u64 stream_id
  payload[length - 16]
```

Payload encoding: a compact tagged format (not Protobuf — we want zero-copy decoding and `comptime`-generated codecs from Zig structs). TLS via BoringSSL or similar `[OPEN]`.

---

## 17. Testing strategy

This is a spec section, not an afterthought.

### 17.1 Deterministic simulation

The top-level test harness runs the whole system (sequencer, log, executors, storage, client) inside a single process with:
- A virtual clock.
- A pseudo-random scheduler that interleaves threads deterministically given a seed.
- A network simulator that can delay, drop, reorder, partition.
- A disk simulator that can delay, fail, corrupt.

Every test is `(seed, scenario) -> pass/fail`. Failures reproduce exactly. Inspired by FoundationDB's Flow and TigerBeetle's VOPR.

### 17.2 Property tests

- **Determinism.** Run a workload on two fresh clusters with the same seed; byte-compare SSTables at every snapshot `seq`.
- **Linearizability.** Classic Jepsen-style test with external clients and an independent model checker.
- **Recovery.** Kill `-9` at every I/O boundary; on restart, verify state equals `fold(log)`.
- **Snapshot round-trip.** Take snapshot; wipe state; restore from snapshot + log; verify bit-equality.

### 17.3 Fuzzing

- SQL parser fuzzed against a grammar-aware fuzzer.
- Wire protocol fuzzed against malformed frames.
- LSM fuzzed by replaying random mutation sequences and verifying invariants.

### 17.4 Benchmarks

- Point-lookup latency at p50, p99, p99.9.
- Single-partition txn throughput.
- Cross-partition txn throughput.
- Scan throughput.
- Tail under tiering (cold read from S3).

Baseline comparisons: Postgres 16, CockroachDB, FoundationDB (same workload, same hardware).

---

## 18. Milestones

Rough ordering. Each milestone ends with a runnable artifact and a passing test suite for its scope.

**M1 — Log (single node).** Segment reader/writer, append/read API, durability tests. No Raft yet.

**M2 — Log (replicated).** Single-partition Raft. Linearizability test.

**M3 — Storage (single partition).** LSM with PAX blocks, leveled compaction, block cache, snapshot reads.

**M4 — Fold Executor (single partition).** Run hand-crafted `TxnIntent`s end-to-end: log → executor → storage. Determinism test.

**M5 — SQL front-end.** Parser, type checker, registration. Can register a query, get a hash, execute it.

**M6 — Gateway.** Full path: client sends query, result comes back. Single partition.

**M7 — Sequencer & multi-partition log.** Multiple log partitions, global ordering.

**M8 — Multi-partition execution.** Cross-partition transactions via the dataflow protocol.

**M9 — Tiered storage.** Object store backend, log truncation, snapshots to S3.

**M10 — CDC.** Subscription API, before-image emission.

**M11 — Vector + JSON indexes.** Specialty index types.

**M12 — Operational hardening.** Reconfiguration, observability, deterministic simulation test suite green on 10k seeds.

---

## 19. Open questions

- **Resharding.** Is "pick a large partition count at creation and don't reshard" acceptable for v1, or do we need online resharding? Leaning yes-acceptable.
- **Full-text search.** Native or delegate to an external engine via CDC? Probably external for v1.
- **Multi-region.** The design supports it (the log can span regions), but the latency cost on cross-region transactions is fundamental. Do we ship a "regional-preferred" placement hint in v1? Probably yes.
- **Async model in Zig.** Zig's async is evolving. Start with explicit thread pools + `io_uring`; revisit async when the language stabilizes.
- **WASM interpreter vs wasmtime.** Pure-Zig keeps the dependency surface clean but is work. Wasmtime is fast and battle-tested but adds a big C++ dependency.
- **TLS library.** BoringSSL, rustls via FFI, or pure-Zig. Probably BoringSSL for now.

---

## 20. What this spec commits to, in one paragraph

Foldb is a single-binary Zig database where every node runs the same code, every node sees the same log, and every node produces the same state. There is one source of truth (the log), one order (the sequence numbers), one isolation level (strict serializable), and one interface (SQL with the sharp edges removed). Writes are durable when appended to the log; reads are consistent at any named sequence number; failures are recovered by replay. The system scales by partitioning the log, the sequencer's decisions, and the data — independently — and it is tested by deterministic simulation so that every bug found is reproducible by a seed.

---
