const std = @import("std");
const testing = std.testing;
const sim = @import("sim.zig");
const SimScheduler = sim.SimScheduler;

test "SimScheduler: chance boundaries" {
    var s = SimScheduler.init(1234);
    for (0..100) |_| {
        try testing.expect(!s.chance(0.0));
        try testing.expect(s.chance(1.0));
    }
}

test "SimScheduler: rangeU64 bounds" {
    var s = SimScheduler.init(42);
    for (0..1000) |_| {
        const v = s.rangeU64(5, 15);
        try testing.expect(v >= 5);
        try testing.expect(v <= 15);
    }
}

test "SimScheduler: rangeU64 min==max returns min" {
    var s = SimScheduler.init(0);
    for (0..100) |_| {
        try testing.expectEqual(@as(u64, 7), s.rangeU64(7, 7));
    }
}

test "SimScheduler: same seed reproduces same sequence" {
    var a = SimScheduler.init(0xDEAD_BEEF);
    var b = SimScheduler.init(0xDEAD_BEEF);
    for (0..1000) |_| {
        try testing.expectEqual(a.rangeU64(0, 9999), b.rangeU64(0, 9999));
        try testing.expectEqual(a.chance(0.4), b.chance(0.4));
    }
}

test "SimScheduler: different seeds produce different sequences" {
    var a = SimScheduler.init(1);
    var b = SimScheduler.init(2);
    var differs: usize = 0;
    for (0..100) |_| {
        if (a.rangeU64(0, 0xFFFF_FFFF) != b.rangeU64(0, 0xFFFF_FFFF)) differs += 1;
    }
    try testing.expect(differs > 0);
}

test "SimScheduler: virtual time advances correctly" {
    var s = SimScheduler.init(0);
    try testing.expectEqual(@as(u64, 0), s.now());
    s.advance(500);
    try testing.expectEqual(@as(u64, 500), s.now());
    s.advanceTo(200);
    try testing.expectEqual(@as(u64, 500), s.now());
    s.advanceTo(1000);
    try testing.expectEqual(@as(u64, 1000), s.now());
    s.advance(1);
    try testing.expectEqual(@as(u64, 1001), s.now());
}

test "SimScheduler: chance is approximately correct at 0.5" {
    var s = SimScheduler.init(777);
    var hits: usize = 0;
    for (0..10_000) |_| {
        if (s.chance(0.5)) hits += 1;
    }
    try testing.expect(hits >= 4500);
    try testing.expect(hits <= 5500);
}
