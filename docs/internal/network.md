# Network Layer

The network layer handles all client-facing TCP communication — framing, serialization, connection lifecycle, and CDC streaming. It is the transport boundary between external clients and the gateway.

## Role

Accepts TCP connections, negotiates a session, decodes client requests into typed values, dispatches to the gateway, and encodes responses back to the wire. It owns the wire protocol but not the business logic.

## Connection Lifecycle

```
TLS negotiation → Hello → Auth → request loop → Goodbye / socket close
```

Each connection is an independent task. Connections are tracked in a spinlock-protected registry; shutdown waits for all connection tasks to exit before tearing down the gateway.

## Framing Contract

Every message is a frame:

```
[16-byte header] [optional 16-byte trace extension] [payload]
```

Header fields: `stream_id`, `payload_len`, `version`, `kind`, `flags`.

- All integers are little-endian; UUIDs are big-endian (RFC 4122).
- Partial reads and writes are retried internally — callers never see partial frames.
- Pre-handshake payloads are capped at 4 KB. Post-negotiation cap is `min(client_requested, 16 MB)`.
- Exceeding the negotiated cap is a fatal `ProtocolError`.

### Frame Flags

| Flag | Meaning |
|---|---|
| `more` (bit 0) | Continuation frame follows |
| `final` (bit 1) | End of stream |
| `trace` (bit 3) | 16-byte trace extension present |
| `compressed` (bit 2) | Reserved |

## Streams

Stream 0 is reserved for control messages (Ping, Auth, Cancel, Goodbye). All other stream IDs are client-assigned and auto-incrementing. Multiple streams may be in flight concurrently on a single connection; responses are keyed by `stream_id`. Cancelling a stream marks it as canceled and sends an error; cleanup happens when the connection task exits.

## Serialization (TypedValue)

Self-describing: a tag byte identifies the type, followed by fixed-width or length-prefixed payload. Constraints:

- Max nesting depth: 16.
- Max container element count: 65,535.
- Decode validates structure before returning to the domain layer.
- All variable-length values are heap-allocated; callers own the memory and must call `TypedValue.deinit()` recursively.

## Message Types

**Control** (stream 0): `Hello`, `Auth`, `AuthOk`, `Ping`, `Pong`, `Goodbye`.

**Query**: `RegisterQuery` / `Registered` (returns hash + param/column type tags), `Execute` / `ExecOk`, `ReadAt` (time-travel read at a specific seq).

**CDC**: `Subscribe` (from_seq, credits, scope), `SubscribeAck`, `CdcEvent` (seq, epoch, effects), `AckCdc` (backpressure).

**Error**: code (u16), severity (error or fatal), message + detail strings.

## Caller Responsibilities

- Free all decoded `TypedValue` payloads via `TypedValue.deinit()`.
- Stay within the negotiated `max_payload_size`.
- Handle retries and idempotency — the network layer does not retry on behalf of clients.

## Error Conditions

| Error | Meaning |
|---|---|
| `ProtocolError` (fatal) | Payload exceeded cap, malformed frame, or unexpected message kind |
| Auth failure | Connection closed after `AuthOk` is not received |
| Stream canceled | Client sent `Cancel` for this stream_id |

## What the Network Layer Does Not Do

- Does not validate business logic — constraint checks and query validation happen in the gateway.
- Does not implement TLS — planned (BoringSSL or equivalent), not yet implemented. The handshake rejects known TLS client hellos with an explicit error.
- Does not implement compression — flag bit reserved, not yet enforced.
- Does not pool or reuse connections on the server side — each connection is a one-shot task.
- Does not retry failed requests.
- Does not handle authentication credentials beyond passing them to the gateway auth handler.

## Source Files

- `src/net/net.zig` — module exports
- `src/net/server.zig` — TCP accept loop, connection registry, shutdown coordination
- `src/net/conn.zig` — per-connection state machine: handshake, stream management, request dispatch
- `src/net/frame.zig` — frame header layout, flag definitions, read/write primitives
- `src/net/messages.zig` — all message type definitions and encoding
- `src/net/codec.zig` — TypedValue self-describing serialization and deserialization
