# FoldDB Wire Protocol

FoldDB speaks a compact binary key-value protocol over TCP. All integer fields
are little-endian.

## Frame

Every message starts with a 16-byte header:

| Field | Type | Description |
|-------|------|-------------|
| `stream_id` | `u64` | Request/response stream. Stream 0 is connection control. |
| `payload_len` | `u32` | Payload byte length after the header. |
| `version` | `u16` | Protocol version, currently `1`. |
| `kind` | `u8` | Message kind. |
| `flags` | `u8` | Bit flags: `FINAL=0x02`, `TRACE=0x08`. |

When `TRACE` is set, a 16-byte trace id follows the base header before the
payload. The negotiated default payload cap is 16 MiB.

## Connection

Server sends `Hello` on stream 0 after connect. Client replies with `Auth`.
Server replies with `AuthOk` or `Error`.

Control kinds:

| Kind | Hex | Direction |
|------|-----|-----------|
| `Hello` | `0x01` | server to client |
| `Auth` | `0x02` | client to server |
| `AuthOk` | `0x03` | server to client |
| `Goodbye` | `0x05` | either |
| `Ping` | `0x10` | client to server |
| `Pong` | `0x11` | server to client |
| `Error` | `0xff` | server to client |

## KV Operations

Client requests use non-zero stream ids. Successful replies use `Response`
(`0x30`) with `FINAL`.

| Kind | Hex | Payload |
|------|-----|---------|
| `Get` | `0x20` | `key`, `at_seq` |
| `Set` | `0x21` | `key`, `value`, `expected_seq` |
| `Delete` | `0x22` | `key` |
| `Range` | `0x23` | `start`, `end`, `limit` |
| `Batch` | `0x24` | repeated KV ops |
| `Response` | `0x30` | operation-specific response |

Byte slices are encoded as `u32 len` followed by raw bytes.

### Get

Request:

```text
u32 key_len
u8[key_len] key
u64 at_seq
```

Response:

```text
u64 committed_seq
u8 present
if present != 0:
  u32 value_len
  u8[value_len] value
```

### Set

Request:

```text
u32 key_len
u8[key_len] key
u32 value_len
u8[value_len] value
u64 expected_seq
```

`expected_seq = 0` disables compare-and-swap.

Response:

```text
u64 committed_seq
u8 cas_failed_present
if cas_failed_present != 0:
  u64 current_seq
```

### Delete

Request:

```text
u32 key_len
u8[key_len] key
```

Response is the same mutation response used by `Set`.

### Range

Request:

```text
u32 start_len
u8[start_len] start
u32 end_len
u8[end_len] end
u32 limit
```

`limit = 0` means no protocol-level row limit.

Response:

```text
u64 committed_seq
u32 entry_count
entry_count * (
  u32 key_len
  u8[key_len] key
  u32 value_len
  u8[value_len] value
)
```

Ranges are ordered by key ascending and use an exclusive end bound.

### Batch

Batch payload starts with `u32 op_count`. Each op is tagged:

| Tag | Operation |
|-----|-----------|
| `0` | Get |
| `1` | Set |
| `2` | Delete |
| `3` | Range |

Each tagged op embeds the same request payload as the standalone operation.
Batch response starts with `u32 result_count`; each result is tagged with the
same operation tag and embeds the corresponding response payload.

Read-only batches are evaluated in request order. Mutating batches are a single
transaction: all set/delete operations are encoded into one intent, assigned one
committed sequence, and applied atomically by the executor. Mixed read/write
batches are currently rejected until transactional read operations are part of
the intent format.

## Error

```text
u16 code
u8 severity       // 0 = stream error, 1 = fatal connection error
u32 message_len
u8[message_len] message
u32 detail_len
u8[detail_len] detail
```

Common codes include `ProtocolError`, `AuthFailed`, `ServerError`,
`FrameTooLarge`, `Canceled`, and `RetryRequired`.
