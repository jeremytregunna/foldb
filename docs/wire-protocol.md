# FoldDB Wire Protocol

**Version:** 1 (draft)
**Status:** Design review — not yet implemented.

---

## 0. Goals and non-goals

**Goals:** multiplexed (many in-flight requests per connection); push-capable (CDC without polling); self-describing typed values; versioned frames; comptime-friendly fixed-width layout; optional trace-id propagation without conditional branches in payload codecs.

**Non-goals:** Postgres/MySQL driver compatibility; cross-vendor portability; streaming LOBs (String/Bytes have a u32 length field but values larger than the frame cap are unrepresentable — deferred).

---

## 1. Transport

TCP, default port **7432**. TLS is a transport wrapper; framing is identical over plain TCP and TLS (§3).

---

## 2. Frame format

All integer fields are **little-endian**. See §17.F for rationale.

### 2.1 Base header (16 bytes)

Field order gives natural alignment for `extern struct` / `repr(C)` with no padding.

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
┌───────────────────────────────────────────────────────────────────┐
│                                                                   │
│                        stream_id  (u64)                           │  bytes 0–7
│                                                                   │
├───────────────────────────────────────────────────────────────────┤
│                       payload_len  (u32)                          │  bytes 8–11
├───────────────────────────────────┬───────────────┬───────────────┤
│           version  (u16)          │   kind  (u8)  │  flags  (u8)  │  bytes 12–15
└───────────────────────────────────┴───────────────┴───────────────┘
```

`stream_id` is a single 8-byte field; two grid rows are a 32-bit diagram artifact.

| Field | Type | Offset | Description |
|-------|------|--------|-------------|
| `stream_id` | u64 | 0 | Multiplexing identifier (§4). |
| `payload_len` | u32 | 8 | Payload bytes after the full header, not counting the 16-byte trace extension (§2.3). |
| `version` | u16 | 12 | Protocol version. Currently `1`. |
| `kind` | u8 | 14 | Message kind (§6). |
| `flags` | u8 | 15 | Bitfield (§2.2). |

### 2.2 Flags

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | `MORE` | More frames follow on this stream in this direction. |
| 1 | `FINAL` | Last frame on this stream in this direction. |
| 2 | `COMPRESSED` | Payload is zstd-compressed. |
| 3 | `TRACE` | 16-byte trace_id extension present after the base header (§2.3). |
| 4–7 | — | Reserved; must be zero on send. |

`MORE` and `FINAL` are mutually exclusive. **Stream 0 frames never carry `MORE` or `FINAL`**; those bits must be zero. Stream 0 messages are self-terminating by `kind`.

### 2.3 Trace extension (16 bytes, conditional)

When `TRACE` is set, bytes 16–31 carry a `[16]u8` trace_id (W3C format). `payload_len` excludes this extension. On-wire order:

```
[16 B header][16 B trace_id, uncompressed (if TRACE)][payload_len B payload, compressed (if COMPRESSED)]
```

The server echoes the trace_id on all response frames for the same stream_id.

### 2.4 Frame size and DoS mitigation

`max_frame_payload_size` is negotiated in `Hello` (default **16 MiB**, compile-time hard cap **64 MiB**).

**Pre-Hello:** the `Hello` frame MUST NOT exceed **4 KiB**. Any frame other than `Hello` received from the server before `AuthOk` is a protocol error.

**The server MUST check `payload_len` against the cap before allocating.** Frames exceeding the cap get `Error(FrameTooLarge, Fatal)` and the connection closes — no allocation occurs first.

```zig
const cap = if (conn.negotiated) conn.max_payload else pre_hello_cap;
if (header.payload_len > cap) {
    try sendError(io, conn, 0, .frame_too_large, .fatal, "frame exceeds cap");
    return error.FrameTooLarge;
}
const payload = try allocator.alloc(u8, header.payload_len);
```

---

## 3. TLS upgrade

1. Client sends magic `FDBT` (`0x46 0x44 0x42 0x54`).
2. Server replies `Y` (`0x59`) or `N` (`0x4E`).
3. `Y` → TLS handshake, then normal framing inside TLS. `N` or skipped → plain TCP.

Server requires TLS but client didn't upgrade → `Error(TlsRequired, Fatal)`.

---

## 4. Stream IDs

| Range | Use |
|-------|-----|
| `0` | Connection-level (`Hello`, `Auth`, `AuthOk`, `Ping`, `Pong`, `Goodbye`, `Error`). No `MORE`/`FINAL`. |
| `1..2^64-1` | Client-initiated. Monotonically increasing recommended. |

**Lifecycle:** one-shot streams (Execute, ReadAt, RegisterQuery) — the client's direction closes implicitly after the single request frame; stream is fully closed when the server sends `FINAL`. Subscription streams — client's direction closes on `Unsubscribe(FINAL)`, server's on `ExecOk(FINAL)`. Stream_id reuse is permitted once the server has sent `FINAL`.

---

## 5. Frame flow rules

Stream 0: never `MORE` or `FINAL`.

| Kind | Direction | Flags |
|------|-----------|-------|
| `RegisterQuery` | C→S | neither |
| `Registered` | S→C | `FINAL` |
| `Execute` | C→S | neither |
| `ReadAt` | C→S | neither |
| `RowsBegin` | S→C | `MORE` |
| `RowsBatch` | S→C | `MORE` ¹ |
| `ExecOk` | S→C | `FINAL` |
| `Subscribe` | C→S | neither |
| `SubscribeAck` | S→C | `MORE` |
| `CdcEvent` | S→C | neither |
| `AckCdc` | C→S | neither |
| `Unsubscribe` | C→S | `FINAL` |
| `Cancel` | C→S | neither (stream_id=0) |
| `Ping`/`Pong` | either | neither (stream 0) |
| `Auth`/`AuthOk`/`Goodbye` | either | neither (stream 0) |
| `Error` | S→C | `FINAL` on stream ≠ 0; neither on stream 0 |

¹ `RowsBatch` always carries `MORE` — `ExecOk` is the terminal frame. Never treat the last `RowsBatch` as completion.

**Errors are always terminal.** Every `Error` on stream ≠ 0 carries `FINAL`. A Fatal `Error` on stream 0 terminates the connection and all open streams; no per-stream `FINAL` follows. An `Error(FINAL)` mid-stream (e.g., during `RowsBatch`) terminates the stream immediately; the client discards partial state.

---

## 6. Message kinds

```
0x01  Hello       0x20  RegisterQuery   0x40  Subscribe
0x02  Auth        0x21  Registered      0x41  CdcEvent
0x03  AuthOk      0x30  Execute         0x42  AckCdc
0x04  (reserved)  0x31  ReadAt          0x43  Unsubscribe
0x05  Goodbye     0x32  RowsBegin       0x44  SubscribeAck
0x10  Ping        0x33  RowsBatch       0x50  Cancel
0x11  Pong        0x34  ExecOk          0xFF  Error
```

0x04 is reserved (formerly AuthError; candidate for AuthChallenge in future SCRAM-like flows). Auth failures use `Error(Fatal)` on stream 0.

---

## 7. Type encoding

### 7.1 TypedValue

```
TypedValue:  type_tag: u8 + type-specific bytes (LE unless noted)
```

`type_tag = 0x00` → null, no further bytes.

### 7.2 Type tags

| Tag | Name | Encoding |
|-----|------|----------|
| `0x00` | Null | (none) |
| `0x01` | Bool | 1 byte: `0x00`/`0x01` |
| `0x02` | Int8 | i8 |
| `0x03` | Int16 | i16 LE |
| `0x04` | Int32 | i32 LE |
| `0x05` | Int64 | i64 LE |
| `0x06` | UInt8 | u8 |
| `0x07` | UInt16 | u16 LE |
| `0x08` | UInt32 | u32 LE |
| `0x09` | UInt64 | u64 LE |
| `0x0A` | Float32 | f32 IEEE 754 LE |
| `0x0B` | Float64 | f64 IEEE 754 LE |
| `0x0C` | Decimal | §7.3 |
| `0x0D` | String | u32 len + UTF-8 bytes |
| `0x0E` | Bytes | u32 len + bytes |
| `0x0F` | UUID | 16 bytes RFC 4122 BE (exception to LE rule) |
| `0x10` | Timestamp | i64 µs since Unix epoch UTC |
| `0x11` | IntervalMonths | i32 months |
| `0x12` | IntervalMicros | i64 µs |
| `0x13` | Json | u32 len + UTF-8 bytes |
| `0x14` | Vector | §7.5 |
| `0x15` | Array | u32 count + count × TypedValue |
| `0x16` | Struct | §7.6 |
| `0x17` | Map | §7.7 |

NaN in Float32/Float64 is rejected. IntervalMonths and IntervalMicros must not be mixed.

### 7.3 Decimal

```
Decimal:  u8 scale (0–38; >38 → TypeError) + i128 coefficient (LE)
```

Value = `coefficient × 10^(−scale)`. Scale is unsigned: the value is always `coefficient / 10^scale`. Numbers requiring a positive exponent that overflows i128 are not representable — intentional OLTP limitation.

### 7.4 String and Bytes

Length is u32 (4 GiB structural max). Values larger than the negotiated frame cap are not sendable; see §0 non-goals.

### 7.5 Vector

```
Vector:  u8 element_type + u16 dim + dim × sizeof(element_type) bytes (LE)
```

| `element_type` | Type | Bytes |
|----------------|------|-------|
| `0x00` | f32 | 4 |
| `0x01` | f64 | 8 |
| `0x02` | f16 | 2 |
| `0x03` | bf16 | 2 |
| `0x04` | int8 | 1 |
| `0x05` | int16 | 2 |

`dim ≤ 65535`. Unrecognized `element_type` → `ProtocolError`. The `element_type` field is present so new element types can be added without versioning `Vector`.

### 7.6 Struct

Named schema fields; `u8 name_len` (max 255 B; SQL identifiers ≤ 128 B).

```
Struct:  u16 field_count + field_count × (u8 name_len + name + TypedValue)
```

### 7.7 Map

Arbitrary typed key-value pairs; keys are full TypedValues.

```
Map:  u32 count + count × (TypedValue key + TypedValue value)
```

Null keys → `ProtocolError`. Duplicate keys → `ProtocolError`. Use Struct for schema rows, Map for dynamic/JSON-like data.

### 7.8 ColumnDesc

```
ColumnDesc:  u8 name_len + name + u8 type_tag + u8 nullable (0=NOT NULL, 1=nullable)
```

---

## 8. Connection lifecycle

### 8.1 Hello (S→C, stream 0)

Sent after TCP connect (post-TLS). Must not exceed 4 KiB (§2.4).

```
Hello:  u8 server_version_len + version bytes + u8 auth_method_count + method bytes + u32 max_frame_payload_size
```

### 8.2 Auth methods

| Value | Name | Notes |
|-------|------|-------|
| `0x00` | None | No credentials. Accepted only in open mode (no users configured). |
| `0x02` | Token | Bearer token derived via HMAC-SHA256. |

`0x01` (Plain) is removed. Servers must not advertise it; clients must not send it. Auth failures use `Error(AuthFailed, Fatal)`.

### 8.3 Auth (C→S, stream 0)

```
Auth payload:
  method:                u8
  client_max_frame_size: u32   (effective S→C cap = min(server_max, client_max); 0xFFFFFFFF = no constraint)

  // Token: u16 token_len + token
  // None:  (nothing)
```

`client_max_frame_size` is present for all methods. The client is responsible for choosing a value large enough to receive any single row or CDC event; too-small values cause `Error(FrameTooLarge)` on the affected stream. On `FrameTooLarge` during CDC, the client may re-subscribe from `acked_seq + 1` after raising the cap.

### 8.4 AuthOk (S→C, stream 0)

Empty payload. Client may now send requests.

### 8.5 Auth failure

`Error(Fatal)` on stream 0. Common codes: `AuthFailed`, `TlsRequired`, `PermissionDenied`, `RateLimited`, `ServerError`.

### 8.6 Goodbye (either, stream 0)

Empty payload. Sender closes TCP shortly after; receiver drains then closes.

---

## 9. Query operations

### 9.1 RegisterQuery (C→S)

```
RegisterQuery:  u32 sql_len + sql bytes (UTF-8)
```

Idempotent: same SQL → same hash.

### 9.2 Registered (S→C, FINAL)

```
Registered:  [32]u8 query_hash + u8 param_count + param_count × u8 TypeTag + u16 column_count + columns × ColumnDesc
```

`column_count = 0` for statements with no result set.

### 9.3 Execute (C→S)

```
Execute:  [32]u8 query_hash + u16 param_count + params × TypedValue
```

### 9.4 ReadAt (C→S)

```
ReadAt:  [32]u8 query_hash + u64 at_seq + u16 param_count + params × TypedValue
```

Returns `Error(SeqNotAvailable)` if `at_seq` is truncated.

### 9.5 RowsBegin (S→C, MORE)

```
RowsBegin:  u16 column_count + columns × ColumnDesc
```

### 9.6 RowsBatch (S→C, MORE)

`column_count` from preceding `RowsBegin`. Always MORE; ExecOk terminates.

```
RowsBatch:  u32 row_count + row_count × (column_count × TypedValue)
```

### 9.7 ExecOk (S→C, FINAL)

```
ExecOk:  u64 rows_affected + u64 committed_seq
```

`committed_seq = 0xFFFFFFFFFFFFFFFF` for operations that produce no commit: ReadAt (read-only) and the Unsubscribe confirmation (control-flow). This value is never a valid seq.

---

## 10. CDC subscriptions

### 10.1 Subscribe (C→S)

```
Subscribe payload:
  from_seq:        u64
  initial_credits: u32
  scope:           u8   (0x00 = all_tables, 0x01 = filtered)

  // if filtered:
  filter_count:    u16   (≥ 1; 0 with filtered scope → ProtocolError)
  filters:         filter_count × TableFilter
```

```
TableFilter:
  kind: u8   (0x00 = by_id → u32 table_id; 0x01 = by_name → u8 name_len + name)
```

`scope = all_tables` is the only way to receive all tables; `filtered` with `filter_count = 0` is a ProtocolError. By-name filters are resolved at subscription time; unknown names → `Error(QueryNotFound)`. Subscribe payloads are subject to the frame cap.

### 10.2 SubscribeAck (S→C, MORE)

Sent before any `CdcEvent`. Returns resolved `(name → id)` pairs for by-name filters so the client can decode `CdcEffect.table_id`.

```
SubscribeAck:  u16 resolved_count + resolved_count × (u8 name_len + name + u32 table_id)
```

`resolved_count = 0` when no by-name filters were used. Entries are variable-length; parse sequentially (no struct cast). Mandatory in v1 — every server must send it, every client must handle it.

### 10.3 CdcEvent (S→C, neither)

```
CdcEvent:  u64 seq + u64 epoch + u32 effect_count + effects × CdcEffect
```

```
CdcEffect:
  table_id:         u32
  key_len:          u32
  key:              key_len bytes
  op:               u8   (0x00=insert, 0x01=update, 0x02=delete)
  before_col_count: u16  (0 if absent; present for update, delete)
  before:           before_col_count × TypedValue
  after_col_count:  u16  (0 if absent; present for insert, update)
  after:            after_col_count × TypedValue
```

`before_col_count`/`after_col_count` are column counts, not byte lengths. Updates carry two full column arrays; a changed-columns bitmap optimisation is reserved via spare `op` values for a future `update_partial`.

### 10.4 AckCdc (C→S)

```
AckCdc:  u64 acked_seq + u32 add_credits
```

### 10.5 Unsubscribe (C→S, FINAL)

Empty payload. Server responds with `ExecOk(FINAL)`.

### 10.6 Flow control

Server maintains a **u64 credit counter** per subscription (wire fields are u32; accumulated total will not overflow). Initialised to `initial_credits`. Decremented by 1 per `CdcEvent` sent; incremented by `add_credits` per `AckCdc`; saturates at 2^64−1. Server must not send `CdcEvent` with zero credits. `initial_credits = 0` is valid — server pauses until first `AckCdc`.

---

## 11. Cancel (stream_id=0)

```
Cancel:  u64 target_stream_id
```

Server sends `Error(Canceled, FINAL)` on `target_stream_id`. `target_stream_id = 0` → `ProtocolError`.

**Races:** (1) Frames already in-flight on the cancelled stream arrive after Cancel — discard them until `Error(Canceled, FINAL)`. (2) If the server has already sent `ExecOk(FINAL)` before Cancel arrives, the server does nothing. The client must tolerate never receiving `Error(Canceled)` if it already received `FINAL` on that stream.

---

## 12. Ping / Pong (stream_id=0)

```
Ping:  u64 client_wall_micros
Pong:  u64 client_wall_micros (echoed) + u64 server_wall_micros
```

Both timestamps are wall clock (Unix µs) for clock-skew estimation. For RTT, bracket with a local monotonic clock — wall timestamps are unreliable due to jumps.

---

## 13. Error frame

```
Error:  u16 error_code + u8 severity + u32 msg_len + msg + u32 detail_len + detail
```

`severity`: `0x00` = Error (stream-level), `0x01` = Fatal (connection closes). Stream 0 errors are always Fatal; connection termination is signaled by the Fatal severity + TCP close — no `FINAL` is sent on individual streams. Every stream-level `Error` carries `FINAL`; there are no non-terminal stream errors.

### 13.1 Error codes

| Code | Name | Notes |
|------|------|-------|
| `0x0001` | ConstraintViolation | Unique, FK, or CHECK failed. |
| `0x0002` | TypeMismatch | Param type mismatch. |
| `0x0003` | QueryNotFound | Hash not registered; or table name in Subscribe unknown. |
| `0x0004` | ParseError | SQL rejected by parser. |
| `0x0005` | TypeError | Type checker rejection; also Decimal scale > 38. |
| `0x0006` | TransactionAborted | ASSERT failed or constraint violation in executor. |
| `0x0007` | RetryRequired | Reconnaissance miss; gateway normally handles transparently. |
| `0x0008` | SeqNotAvailable | `at_seq` truncated. |
| `0x0009` | SchemaConflict | Schema change broke a registered query. |
| `0x000A` | AuthFailed | Credentials rejected. |
| `0x000B` | PermissionDenied | Account lacks permission. |
| `0x000C` | ServerError | Internal error; detail field has context. |
| `0x000D` | ProtocolError † | Malformed frame or invalid state. |
| `0x000E` | Canceled | Stream canceled by client. |
| `0x000F` | TlsRequired | TLS required; or credential auth over non-TLS. |
| `0x0010` | RateLimited | Client sending faster than server accepts. |
| `0x0011` | FrameTooLarge † | `payload_len` exceeds cap. |

† Always Fatal regardless of the `severity` byte.

---

## 14. Compression

`COMPRESSED`: payload is zstd-compressed; trace extension is never compressed. `TRACE` and `COMPRESSED` may be set simultaneously. On-wire order: `[16 B header][16 B trace_id (if TRACE)][payload_len B compressed payload (if COMPRESSED)]`. Minimum recommended payload before compressing: 1 KiB.

---

## 15. Full connection example

```
C→S  FDBT              (TLS request)
S→C  Y
     [TLS handshake]

S→C  Hello  stream=0
C→S  Auth   stream=0  Token
S→C  AuthOk stream=0

C→S  RegisterQuery  stream=1
S→C  Registered     stream=1  FINAL

C→S  Execute   stream=2
S→C  RowsBegin stream=2  MORE
S→C  RowsBatch stream=2  MORE
S→C  ExecOk    stream=2  FINAL

C→S  Subscribe   stream=3  scope=filtered  filter=[by_name "accounts"]
S→C  SubscribeAck stream=3  MORE           (resolved: "accounts"→42)
S→C  CdcEvent     stream=3
S→C  CdcEvent     stream=3
C→S  AckCdc       stream=3
C→S  Unsubscribe  stream=3  FINAL
S→C  ExecOk       stream=3  FINAL

C→S  Goodbye  stream=0
S→C  Goodbye  stream=0
```

---

## 16. Implementation notes (Zig)

```zig
pub const FrameHeader = extern struct {
    stream_id:   u64,
    payload_len: u32,
    version:     u16,
    kind:        u8,
    flags:       u8,
};

// Zig packed structs are LSB-first: more=bit0, final=bit1, compressed=bit2, trace=bit3.
// On-wire masks: 0x01=more, 0x02=final, 0x04=compressed, 0x08=trace.
pub const Flags = packed struct(u8) {
    more:       bool, // bit 0
    final:      bool, // bit 1
    compressed: bool, // bit 2
    trace:      bool, // bit 3
    _reserved:  u4 = 0,
};

// Values not listed are ProtocolError. 0x04 reserved (formerly AuthError).
pub const Kind = enum(u8) {
    hello         = 0x01,
    auth          = 0x02,
    auth_ok       = 0x03,
    // 0x04 reserved
    goodbye       = 0x05,
    ping          = 0x10,
    pong          = 0x11,
    register      = 0x20,
    registered    = 0x21,
    execute       = 0x30,
    read_at       = 0x31,
    rows_begin    = 0x32,
    rows_batch    = 0x33,
    exec_ok       = 0x34,
    subscribe     = 0x40,
    cdc_event     = 0x41,
    ack_cdc       = 0x42,
    unsubscribe   = 0x43,
    subscribe_ack = 0x44,
    cancel        = 0x50,
    err           = 0xFF,
};

pub const VectorElementType = enum(u8) {
    f32   = 0x00,
    f64   = 0x01,
    f16   = 0x02,
    bf16  = 0x03,
    int8  = 0x04,
    int16 = 0x05,
};
```

`FrameHeader` is `extern struct` — ABI-stable, no padding. On LE hosts, read with a single 16-byte `readAll` and `@ptrCast`. **Zero-copy path for RowsBatch:** payload bytes write directly from LSM block buffers (LE integers, same widths). Serializer must account for the 16 B header (32 B with TRACE).

---

## 17. Design decisions

**A. `version` in every frame.**
16 bytes is a clean power-of-two header; removing `version` produces an awkward 14. The 2-byte overhead (~1.6% of a 10 GbE link at 10M fps) is negligible. The real reason to keep it: in-flight version multiplexing on a single connection is a plausible use case for a database evolving its protocol.

**B. `payload_len: u32` with a 64 MiB policy cap.**
u24 would align the structural limit to policy, but u24 is not a C-natural type and not a Zig primitive. u32 for alignment and tooling; cap enforced before allocation (§2.4).

**C. `SubscribeAck` for name→id resolution.**
Clients that subscribe by name receive `CdcEvent.table_id` values they cannot decode without a resolution step. `SubscribeAck` returns `(name → id)` pairs once, before events flow. Alternatives rejected: adding `table_name` to every `CdcEffect` (per-event bandwidth cost); silent catalog coupling (undocumented dependency).

**D. No client→server flow control.**
Server→client CDC uses credits because the server can outpace a slow consumer. The reverse is handled by TCP backpressure and `RateLimited`. Adding client→server credits would significantly complicate the protocol for a case that rarely causes problems in OLTP workloads.

**E. TRACE carries trace-id only.**
Full W3C Trace Context (trace-id + parent-id + flags = 25 bytes) would require a 32-byte extension. Only trace-id is propagated in v1; server spans always start fresh trees. A future `TRACE_FULL` flag can extend to 32 bytes for full parent linkage — the 16-byte boundary leaves exactly that room.

**F. Little-endian is final.**
LSM block buffers are stored LE on all target architectures (x86-64, ARM). LE on the wire means `RowsBatch` payloads write directly from storage into frames with no per-value byte-swap — the zero-copy path for the highest-bandwidth operation in the system. Switching to BE (network byte order) would destroy this. UUID is the sole exception: RFC 4122 mandates BE and UUID bytes are never arithmetically manipulated. This decision is not revisable; a future protocol that changes endianness is a full protocol break.

**G. Keepalive timeout is client-local.**
`Ping`/`Pong` are defined; timeout policy is not. Appropriate intervals vary by deployment (LAN vs. WAN, proxies). The server imposes no keepalive requirement.
