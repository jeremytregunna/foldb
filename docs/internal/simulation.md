# Simulation Subsystem

A deterministic simulator for testing distributed behavior — fault injection, virtual time, and controlled randomness — without involving real clocks, disks, or network I/O.

## Role

Replaces real clock, network, and disk dependencies with injectable deterministic alternatives. All randomness goes through `SimScheduler`'s seeded PRNG, ensuring that the same seed produces an identical sequence of fault decisions and random values.

There are two distinct time abstractions:

- **`SimScheduler.virtual_time_ns`** — a `u64` nanosecond counter owned by the scheduler. Managed by the test harness via `advance(delta_ns)` and `advanceTo(ns)`. Used for coordinating simulation time steps.
- **`VirtualClock`** — an `i64` Unix seconds clock injected into individual subsystems in place of real wall-clock calls. Advanced independently by the test harness with `advance(delta_sec)` or `setTo(sec)`.

These two clocks are independent; the harness is responsible for keeping them consistent if both are in use.

## Guarantees

- **Reproducibility**: Same seed → identical fault decisions, random values, and time advancement.
- **Deterministic fault injection**: Network drops and disk failures are decided by calling `shouldDrop()`/`shouldFault()` before each operation. Identical call order + identical seed = identical results.
- **Bounded virtual time**: `VirtualClock.advance` and `SimScheduler.advance` both use saturating addition — they never wrap.

## Invariants

- `SimScheduler.chance(p)` with `p ∈ [0.0, 1.0]` is deterministic, not pure — it advances the PRNG state on each call. Same seed + same call order always produces the same sequence.
- `rangeU64(min, max)` always returns a value in `[min, max]` inclusive.
- `NetworkSim` and `DiskSim` each own a private `SimScheduler` — they are not thread-safe and must not be shared across independent test threads without re-seeding.
- Fault decisions must be read **before** the operation. Reading them out of order breaks determinism.

## Caller Responsibilities

- Production subsystems must accept sim components (`VirtualClock`, `NetworkSim`, `DiskSim`) via injection — no subsystem should hardcode real clock or PRNG access.
- The test harness is responsible for advancing `SimScheduler` and `VirtualClock` explicitly. There are no real-time ticks.
- The harness is responsible for serializing concurrent operations — the simulator does not enforce ordering.

## What Simulation Does Not Do

- Does not enforce message delay or queueing — `delayNs()` returns a sampled value for future use but the step-based simulation does not enforce ordering or timing.
- Does not model CPU or memory resource constraints.
- Does not automatically explore fault space — callers must write test cases with specific seeds or fault probabilities.
- Does not replace integration tests against real storage or network — it is a unit-level determinism tool.

## Source Files

- `src/sim/sim.zig` — module exports; also exposes `verifySimHarness()`, a comptime check that asserts the required interface methods exist on `VirtualClock`, `SimScheduler`, `NetworkSim`, and `DiskSim`
- `src/sim/scheduler.zig` — `SimScheduler`: seeded Xoroshiro128 PRNG, `chance()`, `rangeU64()`, and nanosecond virtual time (`advance`, `advanceTo`, `now`)
- `src/sim/clock.zig` — `VirtualClock`: injectable `i64` Unix seconds clock with saturating `advance` and absolute `setTo`
- `src/sim/network.zig` — `NetworkSim` + `NetworkConfig`: deterministic message drop (`shouldDrop`) and delay sampling (`delayNs`)
- `src/sim/disk.zig` — `DiskSim` + `DiskConfig`: deterministic I/O fault injection (`shouldFault`)
- `src/sim/workload.zig` — stateful SQL op generator; produces a seeded sequence of insert/update/delete/select ops against a `sim_kv (id INT64, value INT64)` table, tracking live keys to avoid invalid deletes and PK conflicts
