# Observability Subsystem

Provides in-process metrics collection, distributed tracing, and subsystem health tracking. All data is held in memory — export to an external backend is the caller's responsibility.

## Role

Instruments each subsystem with structured metrics (counters, gauges, histograms) and a ring-buffer tracer for end-to-end request correlation. Span timestamps use logical ticks rather than wall-clock time, enabling reproducible replay in simulation.

## Guarantees

- **Saturation semantics**: Counters and gauges saturate at their limits — they never overflow or underflow.
- **Zero-allocation tracing**: The ring-buffer tracer never allocates after initialization.
- **Monotonic trace IDs**: `Tracer.newTrace()` is monotonic; identical seeds produce identical trace ID sequences (useful for deterministic test replay).
- **Histogram precision**: Percentile queries return exponential bucket upper bounds (16 buckets: 1µs to ∞), not exact values.

## Invariants

- Single-threaded per-partition model. Cross-thread reads require external synchronization.
- Histogram mean = `sum_ns / count`; returns zero on empty.
- Ring buffer overflow silently overwrites the oldest spans. Caller must size the buffer to at least `max_concurrent_traces × max_span_depth`.
- Span timestamps are logical ticks — they are not wall-clock values.

## Trace Path

Every `TxnIntent` is assigned a trace ID at the gateway. Spans cover the full path: gateway → sequencer → log → executor. Because execution is deterministic, a given `seq` can be re-executed on any node with identical results — given a seq, the system can reproduce the exact TxnIntent, the state it read, and the mutations it produced.

## Covered Subsystems

Seven domain metric structs: `LogMetrics` (append/read rates), `StorageMetrics` (I/O, compaction, cache), `ExecutorMetrics` (throughput, lag), `SequencerMetrics` (progress, epoch sizing), `GatewayMetrics` (query throughput, nondeterminism resolution), `RaftMetrics` (replication latency p50/p99/p99.9, leadership), `CdcMetrics` (event lag, subscription count).

## What Observability Does Not Do

- Does not export or persist metrics — in-memory only.
- Does not aggregate metrics across subsystems or partitions.
- Does not automatically correlate cross-subsystem traces — callers link spans by `trace_id`.
- Does not notify on ring buffer overflow — old spans are silently lost.
- Does not perform sampling.

## Source Files

- `src/observability/observability.zig` — module exports
- `src/observability/metrics.zig` — counter, gauge, histogram primitives with saturation semantics
- `src/observability/tracer.zig` — ring-buffer span tracer, trace ID generation
- `src/observability/subsystems.zig` — per-subsystem metric struct definitions
- `src/observability/debug.zig` — TxnIntent debug reconstruction from log entries
