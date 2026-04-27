# folddb

A replicated, deterministic state machine database written in Zig. The log is the source of truth; state is `fold(log)` — a pure function cached in an LSM tree. Strict serializable isolation, one global sequence number, no wall clocks inside the fold.

> **Status**: single-node is stable. Multi-node replication (Raft transport) is in active development.

## Requirements

[Zig](https://ziglang.org/) 0.16.0

## Building

```bash
zig build                              # build
zig build test                         # unit + integration tests
zig build dst-test                     # deterministic simulation (200 seeds)
zig build dst-test -Ddst-seeds=10000   # deeper simulation sweep
```

## Running

```bash
foldb serve --config config.json
```

Full config reference (all fields, with defaults shown as comments):

```jsonc
{
  "storage_dir": "/var/lib/foldb",   // required — where data is stored
  "node_id": 1,                      // unique integer per node in the cluster
  "partition_count": 1,              // number of partitions
  "listen_addr": "0.0.0.0",          // optional, default: 0.0.0.0
  "listen_port": 7432,               // optional, default: 7432
  "peers": [],                       // optional — list of peer objects, e.g. [{"id": 2, "addr": "10.0.0.2:7432"}]
  "max_epoch_size": 10000,           // optional — max transactions per Raft epoch
  "election_timeout_min_ms": 150,    // optional — Raft election timeout range
  "election_timeout_max_ms": 300,
  "heartbeat_interval_ms": 50,       // optional — Raft heartbeat interval

  // S3 — optional, but all five fields are required together or not at all.
  // Without S3, snapshots and log truncation are disabled; recovery replays
  // the full log from the beginning. Fine for development, not for production.
  "s3_endpoint": "http://127.0.0.1:9000",
  "s3_bucket": "foldb",
  "s3_access_key": "...",
  "s3_secret_key": "...",
  "s3_region": "us-east-1",          // required when S3 is configured

  // Auth — optional. Omitting auth_secret leaves the server open to all connections.
  // Generate auth_secret with: foldb gen-secret
  // Add users with: foldb add-user --config config.json --name alice --password hunter2
  "auth_secret": "...",
  "users": [
    { "name": "alice", "token": "..." }
  ]
}
```

Only IPv4 S3 endpoints are supported. See [`docs/internal/config.md`](docs/internal/config.md) for full details and [`docs/internal/auth.md`](docs/internal/auth.md) for auth setup.

## Docs

- [`docs/internal/`](docs/internal/) — subsystem reference (storage, log, gateway, sequencer, CDC, SQL, Raft)
- [`foldb-spec.md`](foldb-spec.md) — full engineering specification

## License

Copyright © Jeremy Tregunna. Released under the [Apache 2.0 License](LICENSE).
