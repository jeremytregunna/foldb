# Contributing to FoldDB

FoldDB is a replicated, deterministic database. The architecture is deliberate and the design space is constrained. Contributions that fit that space are welcome. Contributions that don't will be closed.

## Contributor License

By submitting a contribution to this project you retain copyright in your contribution, but grant Jeremy Tregunna and the project a perpetual, worldwide, non-exclusive, royalty-free, irrevocable license to reproduce, prepare derivative works of, publicly display, publicly perform, sublicense, and distribute your contribution and any derivative works under the terms of the Apache License 2.0. This grant cannot be revoked. If you are contributing on behalf of an employer, you confirm you have the authority to grant this license.

## Governance

This is a benevolent dictatorship. Final decisions rest with the maintainer. That's not arrogance — it's honesty about how good systems get built. Strong opinions are welcome; expect to defend them technically.

## Getting Started

Requires Zig 0.16.0.

```bash
zig build                          # build
zig build test                     # unit + integration tests
zig build dst-test                 # deterministic simulation (200 seeds)
zig build dst-test -Ddst-seeds=N   # higher seed count for deeper coverage
```

Single-node dev setup:

```bash
mkdir -p /tmp/foldb-dev
./zig-out/bin/foldb serve --storage-dir /tmp/foldb-dev
```

## Pull Requests

**Bug fixes** must include a test that demonstrates the bug. If it can't be demonstrated, it's not a bug we can fix. For bugs in the core engine, a failing DST seed is the gold standard reproduction.

**Features** must be discussed before implementation. Open an issue first. Off-mission work will be closed — not out of hostility, but because scope discipline is how the project stays coherent.

**All PRs touching the core engine** (log, storage, sequencer, gateway, executor) must pass `zig build dst-test`. Correctness and determinism are not negotiable.

## What "Core Engine" Means

Anything that participates in the fold: log append, MVCC, OCC, sequencer epoch batching, CDC, partition routing. If your change touches any of these, run DST. A bug that only shows up at seed 10,000 is still a bug.

## Code Style

Follow existing patterns. The codebase has a consistent style — match it. If you think something should change structurally, propose it as a separate PR with a clear rationale. Don't mix style changes into feature or bug PRs.

Clarity over cleverness, always.

## AI-Assisted Contributions

Using AI tools is fine. Submitting AI output you haven't reviewed is not — that's just outsourcing your responsibility to a language model, and it shows in the code.

**Every commit must include a `Signed-Off-By` line.** This is your attestation that you read the diff, understand what it does, and stand behind it:

```
Signed-Off-By: Your Name <you@example.com>
```

**If AI assisted in writing the code or commit message, add a `Co-Authored-By` line** identifying the tool:

```
Co-Authored-By: Claude Sonnet <noreply@anthropic.com>
```

Omitting `Co-Authored-By` when AI was involved is bad faith and grounds for immediate rejection. We don't care that you used AI — we care that you're honest about it and that you actually reviewed the output.

## Communication

Be direct. Be technical. We don't do corporate softening. If something is wrong, say it's wrong and explain why. If you disagree with a decision, make the technical case.

What we won't tolerate: bad faith, sustained disruption, or wasting people's time.
