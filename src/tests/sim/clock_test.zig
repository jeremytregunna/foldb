const std = @import("std");
const testing = std.testing;
const sim = @import("sim.zig");

const VirtualClock = sim.VirtualClock;

test "VirtualClock: zero-init and now" {
    const clock = VirtualClock.zero();
    try testing.expectEqual(@as(i64, 0), clock.now());
}

test "VirtualClock: init with start time" {
    const clock = VirtualClock.init(1_700_000_000);
    try testing.expectEqual(@as(i64, 1_700_000_000), clock.now());
}

test "VirtualClock: advance forward" {
    var clock = VirtualClock.zero();
    clock.advance(60);
    try testing.expectEqual(@as(i64, 60), clock.now());
    clock.advance(3600);
    try testing.expectEqual(@as(i64, 3660), clock.now());
}

test "VirtualClock: setTo" {
    var clock = VirtualClock.init(100);
    clock.setTo(9999);
    try testing.expectEqual(@as(i64, 9999), clock.now());
}

test "VirtualClock: overflow saturates" {
    var clock = VirtualClock.init(std.math.maxInt(i64));
    clock.advance(1);
    try testing.expectEqual(std.math.maxInt(i64), clock.now());
}

test "VirtualClock: two independent clocks" {
    var c1 = VirtualClock.zero();
    var c2 = VirtualClock.init(1000);
    c1.advance(10);
    c2.advance(5);
    try testing.expectEqual(@as(i64, 10), c1.now());
    try testing.expectEqual(@as(i64, 1005), c2.now());
}
