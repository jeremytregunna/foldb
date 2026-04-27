# Plan: Spec-Correct Multi-Partition Execution

**Goal:** Replace the shared-`PartitionedStorage` + `filter_partition` read model with the
spec-correct peer-to-peer value exchange protocol (§7.3, §15). Each `FoldExecutor` owns
exactly one `*Storage`; cross-partition reads arrive via SPSC queues addressed by
`(seq, from_partition, to_partition)`, making them replayable (§7.3). The coordinator
pattern in `partition_set.zig` and design-doc stubs in `sql_cross_partition.zig` are
deleted.

**Resumption note:** Each step ends with a "verify" check. If interrupted, run
`zig build test` and the first failing step tells you where to resume.

---

## Context

### Current architecture (wrong)

```
FoldExecutor[0] ──┐
FoldExecutor[1] ──┤──► shared PartitionedStorage ──► all partition Storages
FoldExecutor[N] ──┘
```

- Every executor runs the **full** SQL plan against all partitions' storage.
- Writes are filtered post-execution to the local partition (`filter_partition`).
- Reads cross partition boundaries freely through shared memory — violates §15.
- `partition_set.zig` implements a coordinator 4-phase protocol but is never wired in.
- `sql_cross_partition.zig` is a design document with `NotImplemented` stubs.

### Target architecture (spec §7.2, §7.3, §15)

```
FoldExecutor[0] ──► Storage[0]     ←── SPSC exchange ──► FoldExecutor[1] ──► Storage[1]
```

- Each `FoldExecutor` owns exactly one `*Storage`.
- Every executor receives every log entry via `LogMux` (unchanged).
- Single-partition txns: execute locally, apply at seq. No exchange.
- Multi-partition txns: declare needed foreign rows → exchange values peer-to-peer via
  SPSC queues → execute with local storage + received values → each applies own mutations.
- Exchange messages keyed by `(seq, from_partition, to_partition)` — replayable.
- `filter_partition` stays for the **write** side (each executor only applies its
  partition's mutations); foreign reads are satisfied by the exchange, not shared storage.

### What "multi-partition" means for reads

A SELECT that spans all partitions: P0 requests all rows from P1, P2, … for the tables
it needs; peers respond; P0 runs the full query with all data and delivers the result.
P1, P2, … also run the plan (to evaluate writes/constraints) but deliver no result.
This is deterministic: every executor sees the same exchanged values at the same seq.

---

## Steps

### Step 1 — Exchange message types (`src/executor/exchange.zig`)

Create a new file with:

```zig
pub const ForeignRead = struct {
    table_id: TableId,
    key:      []const u8,   // borrowed; lifetime = duration of exchange at this seq
};

pub const ExchangeRequest = struct {
    seq:  Seq,
    from: PartitionId,
    to:   PartitionId,
    reads: []const ForeignRead,
};

pub const FetchedRow = struct {
    table_id: TableId,
    key:      []const u8,
    row:      ?Row,         // null = key not found in that partition
};

pub const ExchangeResponse = struct {
    seq:  Seq,
    from: PartitionId,   // the partition that fetched the rows
    to:   PartitionId,   // the partition that requested them
    rows: []const FetchedRow,
};
```

Also add a minimal SPSC ring buffer (capacity = power-of-two, configurable at comptime)
whose item type is a tagged union of `ExchangeRequest | ExchangeResponse`. Use
`std.atomic.Value` for head/tail. No allocator inside the ring buffer — callers own item
memory. Keep this simple: a fixed-size array ring buffer, not a linked list.

**Verify:** `zig build` compiles with the new file imported but unused.

---

### Step 2 — ExchangeBus (`src/executor/exchange_bus.zig`)

Owns `N * (N-1)` directional SPSC queues indexed by `(from, to)` pair.

```zig
pub const ExchangeBus = struct {
    partition_count: u32,
    // queues[from * partition_count + to]  (from != to)
    queues: []SpscQueue(ExchangeMsg),
    alloc:  Allocator,

    pub fn init(partition_count: u32, alloc: Allocator) !ExchangeBus;
    pub fn deinit(self: *ExchangeBus) void;

    /// Non-blocking. Returns false if queue full (caller retries in serve loop).
    pub fn push(self: *ExchangeBus, from: PartitionId, to: PartitionId,
                msg: ExchangeMsg) bool;

    /// Non-blocking. Returns null if queue empty.
    pub fn pop(self: *ExchangeBus, from: PartitionId, to: PartitionId)
               ?ExchangeMsg;
};
```

`ExchangeMsg` is the tagged union from Step 1.

The queue for `(from=X, to=Y)` is used by X to SEND to Y, and by Y to RECEIVE from X.
There is no separate response queue — responses travel on the queue `(to, from)` (i.e.,
the reverse direction). Each queue is accessed by exactly one producer and one consumer,
satisfying the SPSC contract.

**Verify:** `zig build` compiles. Write a unit test in `src/tests/executor/exchange_bus_test.zig`:
two threads exchange a request+response through the bus and verify values round-trip.

---

### Step 3 — DeclareReads (`src/executor/declare_reads.zig`)

For a given SQL plan + params, walk the plan tree and emit `ForeignRead` entries for
every key access that routes to a partition other than `my_partition`.

```zig
pub fn declareReads(
    plan:         Plan,
    params:       []const Value,
    my_partition: PartitionId,
    part_count:   u32,
    alloc:        Allocator,
    out:          *std.ArrayList(ForeignRead),  // keyed by target partition
) !void;
```

Strategy:
- `.get_by_key` nodes: evaluate the key expression with params. Compute
  `partition_for(key, part_count)`. If != `my_partition`, append to `out`.
- `.scan` / `.index_scan` nodes: these are range accesses. Use the `read_set_hint` from
  the `TxnIntent` as the partition set. For each partition in the hint that is not
  `my_partition`, emit a sentinel `ForeignRead { .table_id = s.table_id, .key = "" }`
  (empty key = "I need the full scan result from this partition"). The executor will
  request the full scan from the peer.
- All other nodes: recurse into children.

The `partition_for` function is `wyhash(key) % part_count` — extract it from
`storage.zig:PartitionedStorage.partitionIdx` into a free function in a shared
`src/storage/partition_util.zig` so both storage and executor can call it without
creating a circular dependency.

**Verify:** Unit test: build a minimal plan with a known key, call `declareReads`,
confirm the foreign partition is identified correctly.

---

### Step 4 — ForeignRowMap and SqlExecutor read interception

**4a.** Add to `EvalCtx` in `src/sql/eval_expr.zig`:

```zig
foreign_rows: ?*const ForeignRowMap = null,
```

`ForeignRowMap` is a `std.HashMap((TableId, []const u8), ?Row)` keyed by table+key.

**4b.** In `src/sql/executor_bridge.zig`, change `SqlExecutor`:

- Field `storage: *PartitionedStorage` → `storage: *Storage` (single partition only).
- Add `my_partition: PartitionId` and `part_count: u32` fields.
- Remove the `PartitionedStorage` import alias.

**4c.** In `executeScanBase` and any `self.storage.get(...)` call:

Before calling `self.storage.get(table_id, key, seq)`, compute
`partition_for(key, self.part_count)`. If == `self.my_partition`, proceed as today.
If != `self.my_partition`, look up `ctx.foreign_rows.get(.{table_id, key})` and return
that value (or null if not found, which is "key does not exist in that partition").

For **scan** nodes: if `ctx.foreign_rows` contains a full-scan result for this table
(sentinel key = ""), use those rows instead of calling `self.storage.scan(...)`.

**4d.** `filter_partition` write-side logic: keep exactly as-is. Each executor still
applies only its own mutations. The routing check `self.storage.partitionIdx(key)` needs
to move to `partition_util.partitionFor(key, self.part_count)` since storage no longer
has all partitions.

**Verify:** `zig build test` — existing single-partition tests must still pass (when
`part_count = 1` every key routes to partition 0, so `foreign_rows` is never consulted).

---

### Step 5 — Multi-partition rendezvous in FoldExecutor

Add to `FoldExecutor`:

```zig
storage:    *storage_mod.Storage,   // own partition only (replaces partitioned ref)
bus:        ?*ExchangeBus,          // null when part_count = 1
part_count: u32,
```

In `applyEntry` for `.txn_intent`, after decoding the intent:

```zig
const is_multi = isMultiPartition(intent, self.partition_id);
if (is_multi) {
    try self.runMultiPartition(entry, intent);
} else {
    _ = self.sql_exec.run(entry) catch ...;
}
```

`isMultiPartition`: returns true if `intent.read_set_hint` or `intent.write_set_hint`
contains any partition other than `self.partition_id`.

`runMultiPartition(entry, intent)`:

```
1. DeclareReads: walk plan, collect ForeignReads grouped by target partition.
2. For each target partition T:
     push ExchangeRequest { seq, from=my_partition, to=T, reads } onto bus.
3. Serve-and-wait loop:
     a. Check bus queues for incoming requests TO me (from any peer).
        For each: fetch requested rows from self.storage at seq-1.
                  push ExchangeResponse { seq, from=my_partition, to=requester, rows }.
     b. Check my own response queues (bus[T → my_partition]) for all T I sent to.
        Accumulate received rows into ForeignRowMap.
     c. If all responses received: break loop.
     d. Yield (std.Thread.yield()) to avoid spinning.
4. Build EvalCtx with foreign_rows = &foreign_row_map.
5. self.sql_exec.runWithCtx(entry, &ctx).
```

The serve-and-wait loop avoids deadlock because no executor blocks before serving — it
alternates between serving peer requests and checking for its own responses.

For full-scan requests (sentinel key ""): execute `self.storage.scan(table_id, ...)`,
collect all rows, send them back.

**Verify:** Write `src/tests/executor/multipartition_exec_test.zig` — 2 partitions, one
transaction that inserts a row to each; verify both partitions apply exactly their own
mutation and the row appears queryable on each.

---

### Step 6 — Gateway wiring

In `src/gateway/gateway.zig`:

- Remove `PartitionedStorage` field and its construction.
- Add `exchange_bus: ExchangeBus` field.
- In `init`: create `ExchangeBus.init(partition_count, alloc)`. For each partition i,
  create a `Storage` for directory `{storage_dir}/p{i}` (already done today — just stop
  wrapping them in PartitionedStorage). Pass `storages[i]` and `&exchange_bus` to
  `FoldExecutor.init`.
- Update `FoldExecutor.init` signature: replace `*PartitionedStorage` with `*Storage`,
  add `*ExchangeBus` parameter.

DDL schema registration currently runs only on partition 0 because storage is shared and
registering from multiple threads is unsafe. In the new design, each `FoldExecutor` must
register its own storage's tables. Change: each executor calls `self.storage.registerTable()`
in its own `applyDdlToSchema` — this is now safe because each executor owns its storage
exclusively. Remove the `if (self.partition_id != 0) return;` guard in `applyDdlToSchema`.

**Verify:** `zig build test` — all gateway integration tests pass.

---

### Step 7 — Cleanup

Remove the following files (they're replaced by Steps 1–5):

- `src/executor/partition_set.zig`
- `src/executor/sql_cross_partition.zig`

In `src/storage/storage.zig`:

- Remove the `PartitionedStorage` struct entirely (it's now unused).
- Remove `partitionIdx` method (moved to `partition_util.zig`).
- Remove any imports that become unused.

In `src/sql/executor_bridge.zig`:

- Remove `pub const PartitionedStorage = storage_mod.PartitionedStorage;`.
- Remove `filter_partition: ?u32` field — replace with `my_partition: PartitionId` and
  the routing check uses `partition_util.partitionFor` (no longer optional; always set).
- Tidy the unique-constraint check similarly (already skips foreign-partition keys; now
  the routing is via `partition_util` not `self.storage.partitionIdx`).

Remove any now-dead imports in gateway.zig, fold_executor.zig, and any test files that
imported `PartitionedStorage` directly.

**Verify:** `zig build` with no references to `PartitionedStorage` remaining.
`zig build test` — full suite passes.

---

### Step 8 — Tests

**8a.** `src/tests/executor/exchange_bus_test.zig` — already written in Step 2 verify.

**8b.** `src/tests/executor/multipartition_exec_test.zig` — already written in Step 5 verify.
Expand to cover:
- Cross-partition SELECT (P0 reads from P1).
- Cross-partition constraint (ASSERT on foreign-partition row).
- Two concurrent multi-partition txns at adjacent seq values (verify rendezvous
  handles seq ordering correctly — each rendezvous is scoped to exactly one seq).

**8c.** Add a test to `src/tests/gateway/sql_file_test.zig` using a 2-partition gateway
configuration (currently tests use default partition_count=1). Reuse existing `.sql`
files where possible; they should produce identical results with 2 partitions.

**Verify:** `zig build test` — all tests green.

---

## Files changed summary

| File | Action |
|---|---|
| `src/executor/exchange.zig` | **new** — message types + SPSC ring buffer |
| `src/executor/exchange_bus.zig` | **new** — N*(N-1) directional queues |
| `src/executor/declare_reads.zig` | **new** — foreign key extraction from plan |
| `src/storage/partition_util.zig` | **new** — `partitionFor(key, n)` free function |
| `src/executor/fold_executor.zig` | **change** — own Storage, ExchangeBus, runMultiPartition |
| `src/sql/executor_bridge.zig` | **change** — single Storage, ForeignRowMap interception |
| `src/sql/eval_expr.zig` | **change** — add `foreign_rows` to EvalCtx |
| `src/gateway/gateway.zig` | **change** — ExchangeBus, per-partition Storage |
| `src/executor/partition_set.zig` | **delete** |
| `src/executor/sql_cross_partition.zig` | **delete** |
| `src/storage/storage.zig` | **change** — remove PartitionedStorage |
| `src/tests/executor/exchange_bus_test.zig` | **new** |
| `src/tests/executor/multipartition_exec_test.zig` | **new** |

---

## Non-goals for this plan

- RPC transport (Phase B fetch stays as direct `storage.get()` — that IS the RPC
  injection point; replacing it with a network call is a future step once multi-node
  topology is defined).
- Distributed commit (Phase D: apply is still in-process; 2PC is a future concern).
- Resharding (partition count fixed at cluster creation per §13.3).
