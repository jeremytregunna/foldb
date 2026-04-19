# Transactions in folddb

## Why there is no BEGIN / COMMIT / ROLLBACK

folddb does not support interactive transactions. This is intentional and load-bearing, not a gap to be filled later.

Interactive transactions require the database to hold open mutable state on behalf of a client across multiple round-trips: buffer writes, track locks or conflicts, and either commit or discard them when the client eventually says so. That model breaks three things folddb depends on:

**Determinism.** Every operation that reaches the storage core must be a fully-resolved, validated intent: all nondeterministic values (NOW(), RANDOM(), UUID()) resolved once at the boundary, all parameters type-checked, all reads and writes declared upfront. An interactive transaction accumulates decisions across round-trips, making it impossible to assign a single stable log entry that can be replayed identically on restart or across replicas.

**Log-based recovery.** The partition log is the source of truth. After a crash, folddb replays every committed `txn_intent` entry in order to reconstruct storage state. Each entry is self-contained: it carries the query hash, the encoded parameters, and the already-resolved nondeterministic values. An open interactive transaction has no single log entry — it would need to be checkpointed as partial state, which folddb does not do.

**Sequencer ordering.** The Sequencer assigns a globally ordered sequence number to each committed operation. A single interactive transaction spanning multiple requests would need to either hold a seq reservation across the network boundary (fragile) or be assigned its seq only at commit time (meaning it can't read its own writes with a stable cursor). Neither fits the model.

## What folddb does instead: compiled transactions

A folddb transaction is a named, parameterized block registered once and executed atomically as a single operation:

```sql
TRANSACTION (user_id INT64, amount INT64) {
    UPDATE accounts SET balance = balance - $amount WHERE id = $user_id;
    UPDATE accounts SET balance = balance + $amount WHERE id = 2;
    ASSERT (SELECT balance FROM accounts WHERE id = $user_id) >= 0;
}
```

You register this block with the gateway — it is parsed, type-checked, planned, and hashed. At execution time you pass the parameters; the entire block executes atomically in a single sequencer round-trip. All mutations are accumulated in memory and applied to storage in one call. If any statement fails, or any ASSERT evaluates false, no mutations are applied.

This is the same pattern used by stored procedures in traditional databases, but mandatory rather than optional.

## Behaviour that might surprise you

**Nondeterminism is resolved once at the boundary, before the log.**
When a transaction block contains NOW(), RANDOM(), or UUID(), the gateway resolves those values exactly once before serializing the `TxnIntent`. The resolved values are stored in the log entry alongside the parameters. On replay (crash recovery, replica catch-up), the original resolved values are used — not re-evaluated. Two replicas executing the same log entry always see the same NOW() value, even if wall clock time has advanced.

**Query hashes, not query text, identify operations.**
`register()` returns a BLAKE3 hash of the canonicalized query. That hash is what you pass to `execute()`. The canonical form is deterministic: parameter names, whitespace, and comment differences don't produce different hashes. If you register the same logical query twice you get the same hash. Registrations are also persisted to the log and replayed on restart, so you don't need to re-register after a restart.

**Each execute() call is one sequencer round-trip.**
There is no batching of multiple `execute()` calls into a shared sequence number. If you want multiple mutations to be atomic, they must be in a single `TRANSACTION` block. Calling `execute()` twice in a row gives you two independent committed entries with two independent sequence numbers — they can be interleaved with other clients' operations between them.

**ASSERT is a postcondition, not a query.**
An ASSERT inside a transaction block runs after all mutations are staged but before they are applied. It reads the pre-mutation storage state. Use it to enforce invariants that depend on values you haven't changed yet (e.g. balance constraints, foreign-key-style checks). If you need to assert on the result of a mutation in the same block, you cannot — reads inside a transaction see the state at the start of the block.

**Aborted transactions leave no trace.**
If a transaction aborts (ASSERT failure, constraint violation, missing row), the mutations list is discarded and nothing is written to storage. The sequence number is still consumed and the `txn_intent` log entry is still written — the Sequencer committed the entry — but the executor returns an abort result and applies nothing. On replay, the same abort result is produced and the same nothing is applied.

**Rollback does not exist because the commit boundary is the execute() call.**
There is nothing to roll back. The client decides what the transaction does before calling execute(). If the operation fails, it failed atomically. If you need "try this, and if it fails do that instead", model it as two separate registered transactions and handle the result code in your application.

## How to structure application logic

For operations that would traditionally use interactive transactions:

- **Multi-table atomic writes**: put all mutations in a single `TRANSACTION` block with ASSERT guards for invariants.
- **Read-then-write with conflict detection**: use ASSERT inside the transaction to verify the precondition you read is still true at commit time. The Sequencer serializes operations, so a conflicting concurrent write will cause your ASSERT to fail.
- **Conditional updates**: use a `TRANSACTION` with an ASSERT that checks the precondition, then performs the mutation. No separate SELECT round-trip needed.
- **Saga / compensating transactions**: handle at the application layer. folddb gives you atomic single-block commits; multi-step workflows with compensations are application logic, not database logic.
