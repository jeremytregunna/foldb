# folddb

A replicated, deterministic state machine database written in Zig. The log is the source of truth; state is `fold(log)` — a pure function cached in an LSM tree. Strict serializable isolation, one global sequence number, no wall clocks inside the fold.

## Requirements

- [Zig](https://ziglang.org/) 0.16.0

## Building

```bash
zig build                        # release build
zig build -Doptimize=Debug       # debug build
zig build test                   # unit + integration tests
zig build dst-test               # deterministic simulation tests (200 seeds)
zig build dst-test -Ddst-seeds=10000  # DST at higher seed count
```

## Running

```bash
foldb serve --config config.json
```

Minimal config (single node, no auth, no S3):

```json
{
  "node_id": 1,
  "storage_dir": "/var/lib/foldb",
  "partition_count": 1,
  "listen_port": 7432
}
```

See `docs/internal/config.md` for the full field reference.

## S3 / Object Storage

S3 is optional. Without it, the server runs in degraded mode: snapshots and log truncation are disabled, and recovery requires full log replay from the beginning. Suitable for development; not for production.

To enable, add to your config:

```json
{
  "s3_endpoint": "http://1.2.3.4:9000",
  "s3_bucket": "foldb",
  "s3_access_key": "...",
  "s3_secret_key": "...",
  "s3_region": "us-east-1"
}
```

Only IPv4 endpoints are supported. See `docs/internal/config.md`.

## Auth

Auth is opt-in. To enable token-based auth:

```bash
foldb gen-secret                                          # add auth_secret to config
foldb add-user --config config.json --name alice --password hunter2
```

Add the printed `UserEntry` to your config's `users` array. See `docs/internal/auth.md`.

## Architecture

- `docs/internal/` — subsystem reference docs
- `foldb-spec.md` — full engineering specification
