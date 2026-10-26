/// Tests for the wire protocol frame layer.
const std = @import("std");
const testing = std.testing;
const frame = @import("frame.zig");

const FrameHeader = frame.FrameHeader;
const Flags = frame.Flags;
const Kind = frame.Kind;

test "FrameHeader size and offsets" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(FrameHeader));
    try testing.expectEqual(@as(usize, 0), @offsetOf(FrameHeader, "stream_id"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(FrameHeader, "payload_len"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(FrameHeader, "version"));
    try testing.expectEqual(@as(usize, 14), @offsetOf(FrameHeader, "kind"));
    try testing.expectEqual(@as(usize, 15), @offsetOf(FrameHeader, "flags"));
}

test "Flags bitfield layout" {
    const f_more: Flags = .{ .more = true };
    const f_final: Flags = .{ .final = true };
    const f_compressed: Flags = .{ .compressed = true };
    const f_trace: Flags = .{ .trace = true };

    try testing.expectEqual(@as(u8, 0x01), @as(u8, @bitCast(f_more)));
    try testing.expectEqual(@as(u8, 0x02), @as(u8, @bitCast(f_final)));
    try testing.expectEqual(@as(u8, 0x04), @as(u8, @bitCast(f_compressed)));
    try testing.expectEqual(@as(u8, 0x08), @as(u8, @bitCast(f_trace)));
}

test "Flags round-trip" {
    const f: Flags = .{ .more = true, .trace = true };
    const byte: u8 = @bitCast(f);
    const back: Flags = @bitCast(byte);
    try testing.expect(back.more);
    try testing.expect(back.trace);
    try testing.expect(!back.final);
    try testing.expect(!back.compressed);
}

test "Kind enum values match spec" {
    // Connection
    try testing.expectEqual(@as(u8, 0x01), @backingInt(Kind.hello));
    try testing.expectEqual(@as(u8, 0x02), @backingInt(Kind.auth));
    try testing.expectEqual(@as(u8, 0x03), @backingInt(Kind.auth_ok));
    try testing.expectEqual(@as(u8, 0x05), @backingInt(Kind.goodbye));
    try testing.expectEqual(@as(u8, 0x10), @backingInt(Kind.ping));
    try testing.expectEqual(@as(u8, 0x11), @backingInt(Kind.pong));
    // KV ops
    try testing.expectEqual(@as(u8, 0x20), @backingInt(Kind.get));
    try testing.expectEqual(@as(u8, 0x21), @backingInt(Kind.set));
    try testing.expectEqual(@as(u8, 0x22), @backingInt(Kind.delete));
    try testing.expectEqual(@as(u8, 0x23), @backingInt(Kind.range));
    try testing.expectEqual(@as(u8, 0x24), @backingInt(Kind.batch));
    // Responses
    try testing.expectEqual(@as(u8, 0x30), @backingInt(Kind.response));
    try testing.expectEqual(@as(u8, 0x31), @backingInt(Kind.range_rows));
    // CDC
    try testing.expectEqual(@as(u8, 0x40), @backingInt(Kind.subscribe));
    try testing.expectEqual(@as(u8, 0x41), @backingInt(Kind.cdc_event));
    try testing.expectEqual(@as(u8, 0x42), @backingInt(Kind.ack_cdc));
    try testing.expectEqual(@as(u8, 0x43), @backingInt(Kind.unsubscribe));
    // Control
    try testing.expectEqual(@as(u8, 0x50), @backingInt(Kind.cancel));
    try testing.expectEqual(@as(u8, 0xFF), @backingInt(Kind.err));
}

test "Kind is non-exhaustive: unknown values don't match known tags" {
    const k: Kind = @fromBackingInt(@intCast(0x01));
    try testing.expect(k == .hello);

    const reserved: Kind = @fromBackingInt(@intCast(0x04));
    const is_known = switch (reserved) {
        .hello, .auth, .auth_ok, .goodbye, .ping, .pong, .get, .set, .delete, .range, .batch, .response, .range_rows, .subscribe, .cdc_event, .ack_cdc, .unsubscribe, .cancel, .err => true,
        _ => false,
    };
    try testing.expect(!is_known);
}

test "FrameHeader memory layout (little-endian)" {
    var hdr: FrameHeader = .{
        .stream_id = 0x0102030405060708,
        .payload_len = 0x090A0B0C,
        .version = 0x0D0E,
        .kind = 0x0F,
        .flags = 0x10,
    };
    const bytes = std.mem.asBytes(&hdr);
    try testing.expectEqual(@as(u8, 0x08), bytes[0]);
    try testing.expectEqual(@as(u8, 0x01), bytes[7]);
    try testing.expectEqual(@as(u8, 0x0C), bytes[8]);
    try testing.expectEqual(@as(u8, 0x09), bytes[11]);
    try testing.expectEqual(@as(u8, 0x0E), bytes[12]);
    try testing.expectEqual(@as(u8, 0x0D), bytes[13]);
    try testing.expectEqual(@as(u8, 0x0F), bytes[14]);
    try testing.expectEqual(@as(u8, 0x10), bytes[15]);
}

test "Flags.none is zero" {
    try testing.expectEqual(@as(u8, 0x00), @as(u8, @bitCast(Flags.none)));
}

test "Flags.more_only" {
    try testing.expectEqual(@as(u8, 0x01), @as(u8, @bitCast(Flags.more_only)));
}

test "Flags.final_only" {
    try testing.expectEqual(@as(u8, 0x02), @as(u8, @bitCast(Flags.final_only)));
}

test "MORE and FINAL are mutually exclusive (spec §2.2)" {
    const more_bit: u8 = @bitCast(Flags.more_only);
    const final_bit: u8 = @bitCast(Flags.final_only);
    try testing.expectEqual(@as(u8, 0), more_bit & final_bit);
}
