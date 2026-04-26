const std = @import("std");
const testing = std.testing;
const sim = @import("sim.zig");
const NetworkSim = sim.NetworkSim;

test "NetworkSim: drop_prob=0.0 never drops" {
    var net = NetworkSim.init(1, .{ .drop_prob = 0.0 });
    for (0..1000) |_| try testing.expect(!net.shouldDrop());
}

test "NetworkSim: drop_prob=1.0 always drops" {
    var net = NetworkSim.init(1, .{ .drop_prob = 1.0 });
    for (0..1000) |_| try testing.expect(net.shouldDrop());
}

test "NetworkSim: same seed same drop pattern" {
    var a = NetworkSim.init(0xCAFE, .{ .drop_prob = 0.25 });
    var b = NetworkSim.init(0xCAFE, .{ .drop_prob = 0.25 });
    for (0..500) |_| {
        try testing.expectEqual(a.shouldDrop(), b.shouldDrop());
    }
}

test "NetworkSim: drop rate approximately matches drop_prob" {
    var net = NetworkSim.init(42, .{ .drop_prob = 0.1 });
    var drops: usize = 0;
    for (0..10_000) |_| {
        if (net.shouldDrop()) drops += 1;
    }
    // Expect 7%–13% in 10k samples.
    try testing.expect(drops >= 700);
    try testing.expect(drops <= 1300);
}

test "NetworkSim: delayNs stays in configured range" {
    var net = NetworkSim.init(5, .{ .min_delay_ns = 1000, .max_delay_ns = 5000 });
    for (0..500) |_| {
        const d = net.delayNs();
        try testing.expect(d >= 1000);
        try testing.expect(d <= 5000);
    }
}
