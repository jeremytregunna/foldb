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
    try testing.expectEqual(@as(u8, 0x01), @intFromEnum(Kind.hello));
    try testing.expectEqual(@as(u8, 0x02), @intFromEnum(Kind.auth));
    try testing.expectEqual(@as(u8, 0x03), @intFromEnum(Kind.auth_ok));
    try testing.expectEqual(@as(u8, 0x05), @intFromEnum(Kind.goodbye));
    try testing.expectEqual(@as(u8, 0x10), @intFromEnum(Kind.ping));
    try testing.expectEqual(@as(u8, 0x11), @intFromEnum(Kind.pong));
    try testing.expectEqual(@as(u8, 0x20), @intFromEnum(Kind.register));
    try testing.expectEqual(@as(u8, 0x21), @intFromEnum(Kind.registered));
    try testing.expectEqual(@as(u8, 0x30), @intFromEnum(Kind.execute));
    try testing.expectEqual(@as(u8, 0x31), @intFromEnum(Kind.read_at));
    try testing.expectEqual(@as(u8, 0x32), @intFromEnum(Kind.rows_begin));
    try testing.expectEqual(@as(u8, 0x33), @intFromEnum(Kind.rows_batch));
    try testing.expectEqual(@as(u8, 0x34), @intFromEnum(Kind.exec_ok));
    try testing.expectEqual(@as(u8, 0x40), @intFromEnum(Kind.subscribe));
    try testing.expectEqual(@as(u8, 0x41), @intFromEnum(Kind.cdc_event));
    try testing.expectEqual(@as(u8, 0x42), @intFromEnum(Kind.ack_cdc));
    try testing.expectEqual(@as(u8, 0x43), @intFromEnum(Kind.unsubscribe));
    try testing.expectEqual(@as(u8, 0x44), @intFromEnum(Kind.subscribe_ack));
    try testing.expectEqual(@as(u8, 0x50), @intFromEnum(Kind.cancel));
    try testing.expectEqual(@as(u8, 0xFF), @intFromEnum(Kind.err));
}

test "Kind is non-exhaustive: unknown values don't match known tags" {
    // Kind is non-exhaustive (has `_`). @enumFromInt always succeeds, but
    // unknown values fall into the `_` catch-all in switch statements.
    // Verify known values round-trip correctly.
    const k: Kind = @enumFromInt(0x01);
    try testing.expect(k == .hello);

    // 0x04 (reserved) should not match any named tag
    const reserved: Kind = @enumFromInt(0x04);
    const is_known = switch (reserved) {
        .hello, .auth, .auth_ok, .goodbye, .ping, .pong,
        .register, .registered, .execute, .read_at,
        .rows_begin, .rows_batch, .exec_ok,
        .subscribe, .cdc_event, .ack_cdc, .unsubscribe,
        .subscribe_ack, .cancel, .err => true,
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
    // stream_id LE: 08 07 06 05 04 03 02 01
    try testing.expectEqual(@as(u8, 0x08), bytes[0]);
    try testing.expectEqual(@as(u8, 0x01), bytes[7]);
    // payload_len LE: 0C 0B 0A 09
    try testing.expectEqual(@as(u8, 0x0C), bytes[8]);
    try testing.expectEqual(@as(u8, 0x09), bytes[11]);
    // version LE: 0E 0D
    try testing.expectEqual(@as(u8, 0x0E), bytes[12]);
    try testing.expectEqual(@as(u8, 0x0D), bytes[13]);
    // kind
    try testing.expectEqual(@as(u8, 0x0F), bytes[14]);
    // flags
    try testing.expectEqual(@as(u8, 0x10), bytes[15]);
}

test "NO_COMMIT_SEQ sentinel" {
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFF), frame.NO_COMMIT_SEQ);
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
    // Just verify the bit positions don't overlap
    const more_bit: u8 = @as(u8, @bitCast(Flags.more_only));
    const final_bit: u8 = @as(u8, @bitCast(Flags.final_only));
    try testing.expectEqual(@as(u8, 0), more_bit & final_bit);
}
