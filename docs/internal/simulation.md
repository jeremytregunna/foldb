# Simulation Subsystem

A deterministic simulator for testing distributed behavior — fault injection, virtual time, and controlled randomness — without involving real clocks, disks, or network I/O.

## Role

Replaces real clock, network, and disk dependencies with injectable deterministic alternatives. All randomness and virtual time are channeled through a single `SimScheduler`, ensuring that the same seed produces an identical sequence of events and faults.

## Guarantees

- **Reproducibility**: Same seed → identical fault decisions, message outcomes, and time advancement.
- **Deterministic fault injection**: Network drops and disk failures are decided by querying the `SimScheduler` before each operation. Identical query order + identical seed = identical results.
- **Bounded virtual time**: `VirtualClock` is an `i64` Unix seconds value. Advancement saturates at max — it never wraps.

## Invariants

- `SimScheduler.chance(p)` with `p ∈ [0.0, 1.0]` is pure — same internal state always returns the same result.
- `rangeU64(min, max)` always returns a value in `[min, max]` inclusive.
- `NetworkSim` and `DiskSim` each wrap a single `SimScheduler` — they are not thread-safe and must not be shared across independent test threads without re-seeding.
- Fault decisions must be read **before** the operation. Reading them out of order breaks determinism.

## Caller Responsibilities

- Production subsystems must accept sim components (`VirtualClock`, `NetworkSim`, `DiskSim`) via injection — no subsystem should hardcode real clock or PRNG access.
- The test harness is responsible for advancing `SimScheduler` and `VirtualClock` explicitly. There are no real-time ticks.
- The harness is responsible for serializing concurrent operations — the simulator does not enforce ordering.

## What Simulation Does Not Do

- Does not implement actual message delay or queueing — `delayNs` is returned for future use but not yet enforced.
- Does not model CPU or memory resource constraints.
- Does not automatically explore fault space — callers must write test cases with specific seeds or fault probabilities.
- Does not replace integration tests against real storage or network — it is a unit-level determinism tool.

## Source Files

- `src/sim/sim.zig` — module exports
- `src/sim/scheduler.zig` — SimScheduler: seeded PRNG, chance(), rangeU64()
- `src/sim/clock.zig` — VirtualClock: injectable i64 Unix seconds with saturation
- `src/sim/network.zig` — NetworkSim: deterministic message drop and delay decisions
- `src/sim/disk.zig` — DiskSim: deterministic I/O fault injection
- `src/sim/workload.zig` — workload generation helpers for simulation test harnesses
