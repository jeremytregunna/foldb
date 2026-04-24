# Config Subsystem

The config subsystem loads node configuration from a JSON file. All fields are optional; defaults apply for any field not present. Parsed strings are arena-allocated and freed together when the server shuts down.

## Loading

`from_file(path, alloc)` reads the file with raw Linux syscalls and delegates to `from_slice`. Files are capped at 1 MiB. `from_slice(json, alloc)` parses the JSON top-level object field by field; unknown keys are silently ignored.

`Config{}` (zero-initialised) is a valid single-node, no-auth, no-S3 configuration.

## Fields

| Field | Default | Purpose |
|---|---|---|
| `node_id` | `1` | Unique node identifier. Must be distinct across nodes in a cluster. |
| `storage_dir` | `/var/lib/foldb` | Base directory for partition logs and SSTables. |
| `partition_count` | `1` | Number of data and log partitions. Fixed at startup; must match across all nodes. |
| `listen_addr` | `0.0.0.0` | TCP bind address for the client-facing server. |
| `listen_port` | `7432` | TCP port. |
| `peers` | `[]` | Peer addresses for Raft (e.g. `"192.168.1.2:7432"`). Empty = single-node mode. |
| `max_epoch_size` | `10000` | Maximum intents per sequencer epoch. |
| `election_timeout_min_ms` | `150` | Raft election timeout lower bound. |
| `election_timeout_max_ms` | `300` | Raft election timeout upper bound. |
| `heartbeat_interval_ms` | `50` | Raft leader heartbeat interval. |
| `s3_endpoint` | `""` | Endpoint URL, e.g. `"http://1.2.3.4:9000"` or `"https://s3.example.com"`. Bare `host[:port]` without a scheme is also accepted (defaults to port 443). The S3 client handles hostname resolution at connect time. |
| `s3_bucket` | `""` | S3 bucket name. |
| `s3_access_key` | `""` | S3 access key. |
| `s3_secret_key` | `""` | S3 secret key. |
| `s3_region` | `""` | AWS signing region (e.g. `"us-east-1"`). Required when S3 is configured; no default. |
| `auth_secret` | `""` | Server-side HMAC-SHA256 key used by `add-user` to derive tokens. Never sent over the wire. |
| `users` | `[]` | Registered users. Empty = open access. Non-empty = all connections must present a valid token. |

## S3 — Optional, Degraded Mode if Absent

S3 configuration is all-or-nothing: set all four of `s3_endpoint`, `s3_bucket`, `s3_access_key`, `s3_secret_key`, and `s3_region`, or set none of them. Partial configuration is rejected at startup with a clear error.

**When S3 is not configured**, the server starts in degraded mode:
- Snapshots are disabled.
- Log truncation does not occur — the log grows without bound.
- Recovery requires full log replay from the beginning.

A warning is printed at startup. This mode is acceptable for development and single-node use but is not suitable for production.

**When S3 is configured**, the gateway wires an `S3ObjectStore` into each storage partition at init. Snapshots are uploaded to the bucket; snapshot markers are written to the log to enable log truncation and fast recovery.

## Auth

Auth is opt-in. If `users` is empty the server accepts all connections. If `users` is non-empty every connection must authenticate with a valid token.

Tokens are derived offline: `add-user --config <path> --name <name> --password <pw>` computes `base64(HMAC-SHA256(auth_secret, name:password))` and prints the `UserEntry` JSON to add to the config file. The server stores only the derived token — passwords are never stored or transmitted.

`auth_secret` must be set before running `add-user`. Use `gen-secret` to generate one.

## Invariants

- All string fields in a parsed config are owned by the config's arena. Do not free individually.
- `partition_count` must be ≥ 1. `from_slice` rejects zero with `error.InvalidConfig`.
- `listen_port` must be ≥ 1. `from_slice` rejects zero with `error.InvalidConfig`.
- `election_timeout_min_ms` must be strictly less than `election_timeout_max_ms`. `from_slice` enforces this and rejects equal or inverted values with `error.InvalidConfig`.
- `partition_count` sizes internal arrays at startup. Changing it while data exists under `storage_dir` produces incorrect behaviour.
- A rotated `auth_secret` invalidates all existing tokens.

## Source Files

- `src/config/config.zig` — `Config`, `UserEntry`, `ParsedConfig`, `from_file`, `from_slice`, `parse_s3_endpoint`
