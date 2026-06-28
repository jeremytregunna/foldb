# Foldb — System Invariants

Derived from `foldb-spec.md`. Invariants marked **implied** are not stated as formal
invariants in the spec but follow necessarily from the design; these are the highest-value
targets for TLA+ verification, particularly the multi-partition execution cluster (28–34).

---

## Core types

**Explicit:**

1. A `TxnIntent` is self-contained: once in the log, executing it requires no external state beyond `fold(log[0..=seq-1])`. Nothing outside the log and storage metadata needed to locate the KV namespace is needed for replay.

---

## System-level

**Explicit:**

2. State is a cache of `fold(log_prefix)`. State is wrong if it disagrees with the fold.
3. A transaction is committed when its entry is durable in the log. Execution is a deterministic consequence; it cannot precede commit.
4. Given the same log prefix, every node produces bit-identical state. No wall clocks, RNGs, or external calls inside the fold.
5. Every committed transaction has exactly one `seq`, monotonically increasing, gap-free, cluster-wide.
6. Isolation is strict serializable. No weaker level exists.
7. KV namespace metadata is initialized before serving traffic and is not mutated through a side channel while requests are executing.

---

## Log

**Explicit:**

8. `append` returns only after the entry is durable on a quorum.
9. `read(from: s)` returns entries with `seq >= s` in monotonic order with no gaps.
10. Once `append` returns `seq = s`, no future `append` returns `s' <= s`.
11. Truncation never removes entries whose effects are not captured by a durable snapshot.

**Implied:**

12. A replicated entry's `seq` is the same on all replicas (Raft ordering guarantee).
13. A segment is immutable once sealed.
14. Epoch-close is atomic in the Raft log — epochs in flight at leader failure are either fully committed or fully lost.
15. Truncation removes whole segments only — individual entries within a segment cannot be selectively removed.

---

## Storage

**Explicit:**

16. `get` / `scan` at `seq = s` returns state equal to `fold(log[0..=s])` for the queried keys.
17. An SSTable's contents are uniquely determined by the `seq` range it covers and the log entries in that range.
18. Compaction changes on-disk layout but not logical contents.

**Implied:**

19. `apply` is called only by the Fold Executor — no other writer.
20. Mutations are buffered by `seq`; a reader at `seq = s` never sees mutations from `seq > s`.
21. Tombstones, historical versions, and compacted SSTables at `seq = s` equal `fold(log[0..=s])`; compaction never changes visible KV state.

---

## Fold Executor

**Explicit:**

22. `run(entry)` on two nodes with identical state at `seq - 1` produces identical `ExecResult` and identical mutations.
23. A transaction either fully applies its mutations at `seq` or applies none (atomic, no partial writes).
24. `current_seq` is monotonic.

**Implied:**

25. The fold path is deterministic and data-only: it does not depend on wall clocks, RNGs, process-local state, or external services.
26. `run(entry)` advances `current_seq` even on abort — `current_seq` is never blocked.
27. In a multi-partition deployment every executor observes the same ordered KV
    intent stream and applies only mutations owned by its partition. Shared
    storage metadata is initialized before serving traffic and is not mutated by
    concurrent executor threads.

---

## Multi-partition execution

All implied. None are stated as formal invariants in the spec; highest TLA+ value.

28. Every executor receives every `txn_intent` (broadcast invariant).
29. Each executor applies only the mutations whose keys hash to its own partition (partition filter invariant).
30. All executors in a multi-partition txn read from the same snapshot: `seq = first_seq - 1` (consistent read snapshot invariant).
31. Before executor P reads cross-partition state at `first_seq - 1`, every executor Q has `current_seq >= first_seq - N + Q` (sibling visibility invariant — the `waitForSiblings` formula).
32. A constraint violation computed at partition P is identical to the violation that would be computed at any other partition given the same inputs — constraint evaluation is partition-independent.
33. The total `rows_affected` reported to the client equals the sum of own-partition mutations across all executors for that txn.
34. Sequential routing: the `i`th entry of a broadcast batch has `partition = i`. Combined with `first_seq = entry.seq - partition_id`, the formula is invertible: given any entry's `(seq, partition_id)`, its `first_seq` is uniquely determined.

---

## Sequencer

**Explicit:**

35. Every accepted `TxnIntent` eventually gets a unique `seq` or the caller gets a failure.
36. `seq` values are dense and monotonic.
37. The same `TxnIntent` (by `client_id, client_seq`) submitted twice gets the same `seq` (idempotency).

**Implied:**

38. Idempotency cache covers all in-flight and recently-completed txns; the window is large enough that network retries are always covered.
39. Two concurrent epoch proposals from competing leaders cannot both commit (Raft safety: at most one leader per term commits).

---

## Gateway

**Explicit:**

40. Gateway mutation acknowledgements mean the intent is durable in the Raft ordering log; executor application is a deterministic consequence.
41. Read handlers wait for the executor to catch up to the current committed sequence before reading storage.

**Implied:**

42. Mutating batches are submitted as one intent and receive one committed sequence.
43. Mixed read/write batches are rejected until transactional reads are represented in the intent format.
44. Batch mutations for the same key collapse to the last operation in request order.
45. Request payloads are encoded canonically — the same logical KV operation always produces the same intent bytes.

---

## CDC

**Implied:**

49. CDC delivery is at-least-once at the system level; exactly-once is the consumer's responsibility.
50. CDC delivers entries in monotonically increasing `seq` order with no gaps from the subscriber's starting `seq`.
51. `before` images for CDC are computed at `seq - 1` — they reflect state strictly before the entry's mutations.

---

## Operations

**Implied:**

52. Log entries at `seq <= S` may only be truncated when: (a) a snapshot at `seq >= S` is durable in object storage, AND (b) all live CDC subscribers have acked past `S`, AND (c) no live `read_at(seq)` request targets `seq <= S`.
53. Truncation removes whole segments only — entries within a segment cannot be selectively removed.
54. Restoring from snapshot + log replay produces state bit-identical to a node that never crashed (snapshot + replay = continuous fold).
55. A `config_change` entry takes effect at its `seq` on all nodes simultaneously — no node acts on the new config before processing that entry.
