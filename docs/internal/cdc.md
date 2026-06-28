# CDC Subsystem

Change Data Capture streams mutation events to subscribers after each committed transaction. It is a post-execution notification mechanism — it observes state changes but does not influence them.

## Role

Captures before-images prior to storage apply, then dispatches `CdcEvent` objects to subscribers after a successful apply. Aborted transactions produce no events.

## Guarantees

- **At-least-once in-process delivery**: Every committed transaction produces a `CdcEvent` per matching subscription. Events remain in the ring buffer until explicitly consumed via `next()` and acked via `ack()`. An event may be re-delivered to a consumer that does not advance its cursor.
- **At-most-once across restarts**: Events not yet consumed are lost on shutdown — the ring buffer is not persisted. The `cursor` field is a building block for future replay-from-log resumption but that mechanism is not yet implemented.
- **Total ordering within a subscription**: Events are queued in sequence order and dequeued FIFO.
- **Complete transaction effects**: All mutations from a single committed transaction are batched into one `CdcEvent` containing multiple `CdcEffect` entries.
- **Causality**: Before-images are captured at `seq - 1` (pre-mutation state) before `storage.apply()`. Events are dispatched only after apply succeeds.

## Before-Image Emission

Before-images are only captured when a `CdcManager` is attached to the executor (`Executor.withCdc()`). When no CDC manager is present, no before-image work is done at all. When one is present, `capture_before_images()` always reads pre-mutation state from storage at `seq - 1` for each non-insert mutation. Inserts produce a null before-image.

## Invariants

- `capture_before_images()` **must** be called before `storage.apply()`. This ordering is enforced by the executor.
- `dispatch()` **must** be called after a successful `storage.apply()`. The executor guarantees this.
- If `dispatch()` fails (e.g. allocation error), the transaction is aborted — no silent data loss.

## Backpressure

Each subscription holds a fixed-size ring buffer of `events_capacity_max` (1024) events. A slow consumer that allows this buffer to fill will cause subsequent `dispatch()` calls to return `error.InboxFull`, which propagates as a transaction abort. Events are never silently dropped — either the consumer keeps up, or the transaction fails.

## Event Scoping

- Subscriptions can be filtered by `namespace_id` — only events touching the specified namespace are delivered. Pass `null` to receive all namespaces.
- Each partition's executor dispatches independently; events are ordered within a partition but not globally ordered across partitions.
- Subscribers resume from a known point using `from_seq`; `push()` silently discards any event at or below the consumer's cursor, so replaying from the wrong offset is safe.
- `CdcEvent` carries `seq`, `epoch`, and `kind` (always `txn_intent` for user transactions) alongside the `effects` slice.
- Up to `subscriptions_max` (256) concurrent subscriptions are supported. Exceeding this returns `error.TooManySubscriptions` from `subscribe()`.

## Caller Responsibilities

- Call `next()` to dequeue events from the ring buffer, then call `CdcEvent.deinit()` after consuming each one — the CDC manager does not reclaim event memory.
- Call `ack(seq)` to advance the cursor and release ring-buffer slots covered by `seq`. Events at or below the cursor are skipped on the next push and discarded during `ack()`.
- Manage subscription cursors durably if resumability is required — CDC does not persist cursors.
- Implement idempotent event handling: delivery is at-least-once; a consumer that does not ack may receive the same event again.

## Integration with Other Subsystems

- **Executor**: Wires CDC via `Executor.withCdc()`. The executor drives the capture → apply → dispatch sequence on every committed log entry.
- **Network layer**: CDC is in-process only. The network layer polls `sub.next()` and fans events out to connected clients over the wire protocol (`CdcEvent`, `AckCdc` messages).

## What CDC Does Not Do

- Does not persist events — all buffered events are lost on shutdown.
- Does not provide global cross-partition event ordering.
- Does not filter by row predicate — only namespace-level filtering.
- Does not provide flow control against the publisher — a full inbox aborts the transaction, not the consumer.
- Does not recover partial dispatch if `dispatch()` fails mid-loop — the transaction aborts.
- Does not manage subscription cursors — consumers are responsible for durability.

## Source Files

- `src/cdc/cdc.zig` — CdcManager, CdcSubscription, CdcEvent, CdcEffect, before-image capture and dispatch
