# Network Layer

The network layer handles all client-facing TCP communication — framing, serialization, connection lifecycle, and CDC streaming. It is the transport boundary between external clients and the gateway.

## Role

Accepts TCP connections, negotiates a session, decodes client requests into typed values, dispatches to the gateway, and encodes responses back to the wire. It owns the wire protocol but not the business logic.

## Connection Lifecycle

```
preamble probe → Hello → Auth → request loop → Goodbye / socket close
```

Each connection runs as a cooperative fiber via `std.Io.Group`. Shutdown cancels the group and awaits all fibers before tearing down the gateway.

## Framing Contract

Every message is a frame:

```
[16-byte header] [optional 16-byte trace extension] [payload]
```

Header fields: `stream_id`, `payload_len`, `version`, `kind`, `flags`.

- All integers are little-endian; UUIDs are big-endian (RFC 4122).
- Partial reads and writes are retried internally — callers never see partial frames.
- Pre-handshake payloads are capped at 4 KB. Post-negotiation cap is `min(client_requested, 16 MB)`; a client that sends `0xFFFFFFFF` gets the 16 MB default. An absolute hard cap of 64 MB is enforced regardless.
- Exceeding the negotiated cap is a fatal `frame_too_large` error.

### Frame Flags

| Flag | Meaning |
|---|---|
| `more` (bit 0) | Continuation frame follows |
| `final` (bit 1) | End of stream |
| `compressed` (bit 2) | Reserved |
| `trace` (bit 3) | 16-byte trace extension present |

## Streams

Stream 0 is reserved for control messages (Ping, Auth, Cancel, Goodbye). All other stream IDs are client-assigned and auto-incrementing. Multiple streams may be in flight concurrently on a single connection; responses are keyed by `stream_id`. Cancelling a stream marks it as canceled and sends an error; cleanup happens when the connection task exits.

## Serialization (TypedValue)

Self-describing: a tag byte identifies the type, followed by fixed-width or length-prefixed payload. Constraints:

- Max nesting depth: 16.
- Max container element count: 65,535.
- Decode validates structure before returning to the domain layer.
- All variable-length values are heap-allocated; callers own the memory and must call `TypedValue.deinit()` recursively.

## ExecOk Sentinel

`ExecOk.committed_seq` carries the committed sequence number after a write. For read-only results (SELECT, ReadAt) and Unsubscribe confirmations, `committed_seq` is set to `NO_COMMIT_SEQ` (`0xFFFF_FFFF_FFFF_FFFF` = `maxInt(u64)`). Clients must not interpret this value as a real sequence number.

## Message Types

**Control** (stream 0): `Hello`, `Auth`, `AuthOk`, `Ping`, `Pong`, `Goodbye`.

**Query**:
- `RegisterQuery` / `Registered` — registers a query hash for later Execute. DDL statements and `USE DATABASE <name>` are intercepted here: DDL is applied immediately, USE DATABASE switches the connection's active database, and both return a `Registered` with a stable hash. Executing a DDL or USE DATABASE hash is a no-op.
- `Execute` — runs a registered hash. DML response: `ExecOk` (FINAL). SELECT response: `RowsBegin` (MORE) → one or more `RowsBatch` (MORE) → `ExecOk` (FINAL). RETURNING clauses follow the SELECT path.
- `ReadAt` — time-travel read at a specific committed seq. Response follows the SELECT path.

**CDC**:
- `Subscribe` (from_seq, initial_credits, scope) — scope is `all_tables` or `filtered`; filtered subscriptions carry table filters by ID or name.
- `SubscribeAck` (MORE) — echoes resolved names for any by-name filters.
- `CdcEvent` (seq, epoch, effects) — each effect carries table_id, row key, op (insert/update/delete), and before/after column value arrays.
- `AckCdc` (acked_seq, add_credits) — backpressure; replenishes the credit window.
- `Unsubscribe` — ends a CDC subscription; server responds with `ExecOk` (committed_seq = `NO_COMMIT_SEQ`).

**Error**: code (u16), severity (error or fatal), message + detail strings.

## Caller Responsibilities

- Free all decoded `TypedValue` payloads via `TypedValue.deinit()`.
- Stay within the negotiated `max_payload_size`.
- Handle retries and idempotency — the network layer does not retry on behalf of clients.

## Error Codes

| Code | Value | Meaning |
|---|---|---|
| `constraint_violation` | 0x0001 | Unique or FK constraint failed |
| `type_mismatch` | 0x0002 | Bind parameter type mismatch |
| `query_not_found` | 0x0003 | Hash not registered |
| `parse_error` | 0x0004 | SQL parse or DDL parse failed |
| `type_error` | 0x0005 | Type-check error during register |
| `transaction_aborted` | 0x0006 | Transaction rolled back |
| `retry_required` | 0x0007 | Optimistic conflict; client should retry |
| `seq_not_available` | 0x0008 | Requested seq is not in the log window |
| `schema_conflict` | 0x0009 | DDL conflicts with existing schema |
| `auth_failed` | 0x000A | Bad token or unknown database at connect time |
| `permission_denied` | 0x000B | Action not permitted for this user |
| `server_error` | 0x000C | Internal server error |
| `protocol_error` | 0x000D | Malformed frame or unexpected message kind (fatal) |
| `canceled` | 0x000E | Stream was canceled by client |
| `tls_required` | 0x000F | Reserved for future TLS enforcement |
| `rate_limited` | 0x0010 | Request rate exceeded |
| `frame_too_large` | 0x0011 | Payload exceeded negotiated or hard cap |

Fatal errors (severity = fatal) close the connection immediately after the error frame is sent. Stream errors (severity = error) close only the affected stream.

## What the Network Layer Does Not Do

- Does not validate business logic — constraint checks and query validation happen in the gateway.
- Does not implement TLS — planned, not yet implemented. On connection open, the server peeks at the first 4 bytes; if they match the `FDBT` preamble (future TLS upgrade path), it sends `N` (decline) and continues with the plaintext protocol.
- Does not implement compression — flag bit reserved, not yet enforced.
- Does not pool or reuse connections on the server side — each connection is a one-shot task.
- Does not retry failed requests.
- **Enforces authentication credentials** — `conn.zig` validates tokens against the configured user list during the `Auth` handshake step. If the server's `users` list is non-empty, a valid `Token` credential matching a known token is required; `None` auth is rejected. If the `users` list is empty, the server operates in open mode and accepts either `None` or `Token` (unvalidated). Failed auth sends `Error(auth_failed, fatal)` and closes the connection. The `Plain` auth method is not supported on the wire. The `Auth` payload also carries an optional `database_name` (u8-length-prefixed, empty = default database); if the name is non-empty and not found, the handshake fails with `auth_failed`.

## Source Files

- `src/net/net.zig` — module exports
- `src/net/server.zig` — TCP accept loop, connection registry, shutdown coordination
- `src/net/conn.zig` — per-connection state machine: handshake, stream management, request dispatch
- `src/net/frame.zig` — frame header layout, flag definitions, read/write primitives
- `src/net/messages.zig` — all message type definitions and encoding
- `src/net/codec.zig` — TypedValue self-describing serialization and deserialization
