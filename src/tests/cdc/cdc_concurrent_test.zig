/// CDC concurrent subscription tests.
const std = @import("std");
const testing = std.testing;
const cdc_mod = @import("cdc.zig");
const storage = @import("storage.zig");

const CdcManager = cdc_mod.CdcManager;

test "cdc: init and deinit" {
    const alloc = testing.allocator;
    var mgr = try cdc_mod.CdcManager.init(alloc);
    defer mgr.deinit();
    try testing.expect(mgr.subscription_count == 0);
}

test "cdc: create subscription" {
    const alloc = testing.allocator;
    var mgr = try cdc_mod.CdcManager.init(alloc);
    defer mgr.deinit();

    _ = try mgr.subscribe(null, 0);
    try testing.expect(mgr.subscription_count == 1);
}

test "cdc: multiple subscriptions" {
    const alloc = testing.allocator;
    var mgr = try CdcManager.init(alloc);
    defer mgr.deinit();
    _ = try mgr.subscribe(null, 0);
    _ = try mgr.subscribe(null, 1);
    try testing.expect(mgr.subscription_count == 2);
}

test "cdc: dispatch preserves opaque key and value bytes" {
    const alloc = testing.allocator;
    var mgr = try CdcManager.init(alloc);
    defer mgr.deinit();

    const sub = try mgr.subscribe(null, 0);

    const before_bytes = [_]u8{ 0x00, 0xFF, 0x10, 0x20 };
    const after_bytes = [_]u8{ 0x80, 0x00, 0x41, 0x42, 0xFF };
    const key_bytes = [_]u8{ 0x00, 'k', 0xFF };
    const mutation = storage.Mutation{
        .kind = .update,
        .namespace_id = 1,
        .key = &key_bytes,
        .value = &after_bytes,
    };

    const before_copy = try alloc.dupe(u8, &before_bytes);
    const images = try alloc.alloc(?[]const u8, 1);
    images[0] = before_copy;
    var before = cdc_mod.BeforeImages{ .images = images, .alloc = alloc };
    defer before.deinit();

    try mgr.dispatch(9, 0, .txn_intent, &.{mutation}, before, alloc);

    var events: [1]cdc_mod.CdcEvent = undefined;
    const n = sub.next(&events);
    try testing.expectEqual(@as(usize, 1), n);
    defer events[0].deinit();

    try testing.expectEqual(@as(u64, 9), events[0].seq);
    try testing.expectEqual(@as(usize, 1), events[0].effects.len);
    const effect = events[0].effects[0];
    try testing.expectEqual(.update, effect.op);
    try testing.expectEqualSlices(u8, &key_bytes, effect.key);
    try testing.expect(effect.before != null);
    try testing.expectEqualSlices(u8, &before_bytes, effect.before.?);
    try testing.expect(effect.after != null);
    try testing.expectEqualSlices(u8, &after_bytes, effect.after.?);
}
