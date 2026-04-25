/// Wire protocol frame layer — header types, flags, kind enum, raw read/write.
const std = @import("std");

pub const FRAME_HEADER_SIZE: u32 = 16;
pub const TRACE_EXT_SIZE: u32 = 16;
pub const PRE_HELLO_CAP: u32 = 4 * 1024;
pub const DEFAULT_MAX_PAYLOAD: u32 = 16 * 1024 * 1024;
pub const HARD_CAP_PAYLOAD: u32 = 64 * 1024 * 1024;
pub const PROTOCOL_VERSION: u16 = 1;
pub const DEFAULT_PORT: u16 = 7432;

/// No-commit sentinel for ExecOk.committed_seq (ReadAt + Unsubscribe confirmation).
pub const NO_COMMIT_SEQ: u64 = 0xFFFF_FFFF_FFFF_FFFF;

/// 16-byte frame header. extern struct: no padding, ABI-stable, safe for @ptrCast.
pub const FrameHeader = extern struct {
    stream_id: u64,
    payload_len: u32,
    version: u16,
    kind: u8,
    flags: u8,

    comptime {
        std.debug.assert(@sizeOf(FrameHeader) == FRAME_HEADER_SIZE);
        std.debug.assert(@offsetOf(FrameHeader, "stream_id") == 0);
        std.debug.assert(@offsetOf(FrameHeader, "payload_len") == 8);
        std.debug.assert(@offsetOf(FrameHeader, "version") == 12);
        std.debug.assert(@offsetOf(FrameHeader, "kind") == 14);
        std.debug.assert(@offsetOf(FrameHeader, "flags") == 15);
    }
};

/// Flags byte. LSB-first in Zig packed structs: more=bit0, final=bit1, compressed=bit2, trace=bit3.
pub const Flags = packed struct(u8) {
    more: bool = false,
    final: bool = false,
    compressed: bool = false,
    trace: bool = false,
    _reserved: u4 = 0,

    pub const none: Flags = .{};
    pub const more_only: Flags = .{ .more = true };
    pub const final_only: Flags = .{ .final = true };
};

/// Message kind byte. Non-exhaustive: use in switch with `else => return error.ProtocolError`.
/// 0x04 reserved (formerly AuthError; candidate for AuthChallenge).
pub const Kind = enum(u8) {
    hello = 0x01,
    auth = 0x02,
    auth_ok = 0x03,
    goodbye = 0x05,
    ping = 0x10,
    pong = 0x11,
    register = 0x20,
    registered = 0x21,
    execute = 0x30,
    read_at = 0x31,
    rows_begin = 0x32,
    rows_batch = 0x33,
    exec_ok = 0x34,
    subscribe = 0x40,
    cdc_event = 0x41,
    ack_cdc = 0x42,
    unsubscribe = 0x43,
    subscribe_ack = 0x44,
    cancel = 0x50,
    err = 0xFF,
    _, // non-exhaustive: unknown values handled at call sites
};

// ---- low-level I/O helpers (raw Linux syscalls, consistent with codebase pattern) ----

pub fn readExact(fd: std.posix.fd_t, buf: []u8) !void {
    assert(buf.len > 0);
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.os.linux.read(@intCast(fd), buf.ptr + total, buf.len - total);
        const ni: isize = @bitCast(n);
        if (ni < 0) return error.ReadError;
        if (ni == 0) return error.ConnectionClosed;
        total += @intCast(ni);
    }
    assert(total == buf.len);
}

pub fn writeAll(fd: std.posix.fd_t, data: []const u8) !void {
    assert(data.len > 0);
    var sent: usize = 0;
    while (sent < data.len) {
        const n = std.os.linux.write(@intCast(fd), data.ptr + sent, data.len - sent);
        const ni: isize = @bitCast(n);
        if (ni <= 0) return error.WriteError;
        sent += @intCast(ni);
    }
    assert(sent == data.len);
}

// ---- frame-level helpers ----

/// Read and return the 16-byte base header. Does NOT read trace extension or payload.
pub fn readHeader(fd: std.posix.fd_t) !FrameHeader {
    var hdr: FrameHeader = undefined;
    try readExact(fd, std.mem.asBytes(&hdr));
    return hdr;
}

/// Read the 16-byte trace extension (call only when header.flags has trace=true).
pub fn readTraceExt(fd: std.posix.fd_t) ![TRACE_EXT_SIZE]u8 {
    var trace: [TRACE_EXT_SIZE]u8 = undefined;
    try readExact(fd, &trace);
    return trace;
}

/// Read exactly payload_len bytes into a freshly allocated buffer. Caller owns the slice.
pub fn readPayload(fd: std.posix.fd_t, len: u32, alloc: std.mem.Allocator) ![]u8 {
    assert(len <= HARD_CAP_PAYLOAD);
    const buf = try alloc.alloc(u8, len);
    errdefer alloc.free(buf);
    if (len > 0) try readExact(fd, buf);
    return buf;
}

/// Build and send a complete frame: header + optional trace ext + payload.
pub fn sendFrame(
    fd: std.posix.fd_t,
    stream_id: u64,
    kind: Kind,
    flags: Flags,
    trace_id: ?*const [TRACE_EXT_SIZE]u8,
    payload: []const u8,
) !void {
    assert(payload.len <= HARD_CAP_PAYLOAD);
    var f = flags;
    f.trace = trace_id != null;
    const hdr = FrameHeader{
        .stream_id = stream_id,
        .payload_len = @intCast(payload.len),
        .version = PROTOCOL_VERSION,
        .kind = @intFromEnum(kind),
        .flags = @bitCast(f),
    };
    try writeAll(fd, std.mem.asBytes(&hdr));
    if (trace_id) |tid| try writeAll(fd, tid);
    if (payload.len > 0) try writeAll(fd, payload);
}

/// Send a frame whose payload is in an ArrayList (convenience wrapper).
pub fn sendFrameList(
    fd: std.posix.fd_t,
    stream_id: u64,
    kind: Kind,
    flags: Flags,
    trace_id: ?*const [TRACE_EXT_SIZE]u8,
    payload_list: std.ArrayListUnmanaged(u8),
) !void {
    return sendFrame(fd, stream_id, kind, flags, trace_id, payload_list.items);
}

// ---- compile-time invariant checks ----

comptime {
    std.debug.assert(PRE_HELLO_CAP < DEFAULT_MAX_PAYLOAD);
    std.debug.assert(DEFAULT_MAX_PAYLOAD <= HARD_CAP_PAYLOAD);
    std.debug.assert(FRAME_HEADER_SIZE == @sizeOf(FrameHeader));
    std.debug.assert(TRACE_EXT_SIZE == 16);
    std.debug.assert(NO_COMMIT_SEQ == std.math.maxInt(u64));
}

const assert = std.debug.assert;
