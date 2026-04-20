# CDC Subsystem

Change Data Capture streams mutation events to subscribers after each committed transaction. It is a post-execution notification mechanism — it observes state changes but does not influence them.

## Role

Captures before-images prior to storage apply, then dispatches `CdcEvent` objects to subscribers after a successful apply. Aborted transactions produce no events.

## Guarantees

- **At-least-once delivery**: Every committed transaction produces exactly one `CdcEvent` per subscription. Consumers must handle re-delivery idempotently.
- **Total ordering within a subscription**: Events are queued in sequence order and dequeued FIFO.
- **Complete transaction effects**: All mutations from a single committed transaction are batched into one `CdcEvent` containing multiple `CdcEffect` entries.
- **Causality**: Before-images are captured at `seq - 1` (pre-mutation state) before `storage.apply()`. Events are dispatched only after apply succeeds.

## Before-Image Emission

Before-images are emitted conditionally: when CDC subscribers exist for a table, the executor captures them as a side output during fold execution. When no subscribers exist, before-images are computed on demand by reading storage at `seq - 1`. This avoids the overhead of before-image capture when nothing is listening.

## Invariants

- `captureBeforeImages()` **must** be called before `storage.apply()`. This ordering is enforced by the executor.
- `dispatch()` **must** be called after a successful `storage.apply()`. The executor guarantees this.
- If `dispatch()` fails (e.g. allocation error), the transaction is aborted — no silent data loss.

## Backpressure

Each subscription holds an unbounded in-memory queue. There is no flow control — a slow consumer will cause unbounded memory growth. Allocation failures during dispatch abort the transaction rather than drop the event.

## Event Scoping

- Subscriptions can be filtered by `table_id` — only events touching the specified table are delivered.
- Each partition's executor dispatches independently; events are ordered within a partition but not globally ordered across partitions.
- Subscribers resume from a known point using `from_seq`; the `cursor` tracks the highest acked sequence.

## Caller Responsibilities

- Call `CdcEvent.deinit()` after consuming each event — the CDC manager does not reclaim memory.
- Manage subscription cursors durably if resumability is required — CDC does not persist cursors.
- Implement idempotent event handling to tolerate at-least-once re-delivery.

## Integration with Other Subsystems

- **Executor**: Wires CDC via `Executor.withCdc()`. The executor drives the capture → apply → dispatch sequence on every committed log entry.
- **Network layer**: CDC is in-process only. The network layer polls `sub.next()` and fans events out to connected clients over the wire protocol (`CdcEvent`, `AckCdc` messages).

## What CDC Does Not Do

- Does not persist events — all queued events are lost on shutdown.
- Does not provide global cross-partition event ordering.
- Does not filter by row predicate — only table-level filtering.
- Does not provide flow control or backpressure against the publisher.
- Does not recover partial dispatch if `dispatch()` fails mid-loop — the transaction aborts.
- Does not manage subscription cursors — consumers are responsible for durability.

## Source Files

- `src/cdc/cdc.zig` — CdcManager, CdcSubscription, CdcEvent, CdcEffect, before-image capture and dispatch
