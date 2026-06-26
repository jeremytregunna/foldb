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
