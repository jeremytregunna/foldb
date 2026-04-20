/// NetworkSim — controlled message faults for deterministic simulation testing.
///
/// Wraps a SimScheduler to decide, for each in-flight message, whether to
/// drop it. The SimCluster queries this in drainBus() before delivering each
/// message so every fault decision is seeded and reproducible.
const std = @import("std");
const scheduler_mod = @import("scheduler.zig");

pub const SimScheduler = scheduler_mod.SimScheduler;

pub const NetworkConfig = struct {
    /// Probability [0.0, 1.0] that any given message is silently dropped.
    drop_prob: f64 = 0.0,
    /// Minimum simulated one-way delay in nanoseconds (informational; not
    /// currently enforced in step-based simulation — use for future event queue).
    min_delay_ns: u64 = 0,
    /// Maximum simulated one-way delay in nanoseconds.
    max_delay_ns: u64 = 0,
};

pub const NetworkSim = struct {
    cfg: NetworkConfig,
    sched: SimScheduler,

    /// Create a NetworkSim backed by a new SimScheduler seeded with `seed`.
    pub fn init(seed: u64, cfg: NetworkConfig) NetworkSim {
        return .{ .cfg = cfg, .sched = SimScheduler.init(seed) };
    }

    /// Return true if this message should be silently dropped.
    pub fn shouldDrop(self: *NetworkSim) bool {
        return self.sched.chance(self.cfg.drop_prob);
    }

    /// Sample a delay for this message in nanoseconds.
    pub fn delayNs(self: *NetworkSim) u64 {
        return self.sched.rangeU64(self.cfg.min_delay_ns, self.cfg.max_delay_ns);
    }
};

test "NetworkSim: drop_prob=0.0 never drops" {
    var net = NetworkSim.init(1, .{ .drop_prob = 0.0 });
    for (0..1000) |_| try std.testing.expect(!net.shouldDrop());
}

test "NetworkSim: drop_prob=1.0 always drops" {
    var net = NetworkSim.init(1, .{ .drop_prob = 1.0 });
    for (0..1000) |_| try std.testing.expect(net.shouldDrop());
}

test "NetworkSim: same seed same drop pattern" {
    var a = NetworkSim.init(0xDEAD, .{ .drop_prob = 0.3 });
    var b = NetworkSim.init(0xDEAD, .{ .drop_prob = 0.3 });
    for (0..500) |_| {
        try std.testing.expectEqual(a.shouldDrop(), b.shouldDrop());
    }
}

test "NetworkSim: delayNs stays in range" {
    var net = NetworkSim.init(7, .{ .min_delay_ns = 100, .max_delay_ns = 1000 });
    for (0..500) |_| {
        const d = net.delayNs();
        try std.testing.expect(d >= 100);
        try std.testing.expect(d <= 1000);
    }
}
