# Network Layer

The network layer handles all client-facing TCP communication — framing, serialization, connection lifecycle, and CDC streaming. It is the transport boundary between external clients and the gateway.

## Role

Accepts TCP connections, decodes client requests into typed values, dispatches to the gateway, and encodes responses back to the wire. It owns the wire protocol but not the business logic.

## Connection Lifecycle

```
connect → request loop → disconnect
```

Each connection runs on the server's main accept loop. Frames are read from the socket, dispatched to the gateway handler, and responses are written back on the same connection.

## Framing Contract

Every message is a frame:

```
[16-byte header] [optional 16-byte trace extension] [payload]
```

Header fields: `stream_id`, `payload_len`, `version`, `kind`, `flags`.

- All integers are little-endian; UUIDs are big-endian (RFC 4122).
- Partial reads and writes are handled internally — callers never see partial frames.
- Payload cap is configurable per connection.

### Frame Flags

| Flag | Meaning |
|---|---|
| `more` (bit 0) | Continuation frame follows |
| `final` (bit 1) | End of stream |
| `trace` (bit 3) | 16-byte trace extension present |

## Serialization

Self-describing messages: a type byte identifies the message kind, followed by fixed-width or length-prefixed fields. All variable-length values are heap-allocated; callers own the memory.

## Message Types

**KV Operations**:
- `SetRequest` / `SetResponse` — write a key-value pair. Carries key, value, and optional ttl.
- `GetRequest` / `GetResponse` — read a key. Returns value or null.
- `DeleteRequest` / `DeleteResponse` — delete a key. Returns previous value if existed.
- `RangeRequest` / `RangeResponse` — scan a key range. Returns list of key-value pairs.
- `BatchOp` / `BatchResponse` — batch multiple set/delete operations atomically.

**Control**:
- `Ping` / `Pong` — health check.
- `Goodbye` — graceful shutdown.
- `Error` — error code + message.

**CDC**:
- `Subscribe` — start a change data capture stream.
- `CdcEvent` — individual change event (key, value, operation type, seq).
- `AckCdc` — acknowledge and replenish credits.
- `Unsubscribe` — end a CDC subscription.

## Error Codes

| Code | Value | Meaning |
|---|---|---|
| `server_error` | 0x000C | Internal server error |
| `protocol_error` | 0x000D | Malformed frame (fatal) |
| `canceled` | 0x000E | Stream was canceled |
| `frame_too_large` | 0x0011 | Payload exceeded cap |

Fatal errors close the connection. Stream errors close only the affected stream.

## Source Files

- `src/net/frame.zig` — frame header layout, read/write primitives
- `src/net/messages.zig` — all message type definitions and encoding
- `src/net/codec.zig` — message serialization and deserialization
- `src/gateway/server.zig` — TCP listener, connection accept loop
