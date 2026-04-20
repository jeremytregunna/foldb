/// SimScheduler — seeded PRNG and virtual time for deterministic simulation.
///
/// All randomized decisions in the simulation (message drop, delay, fault)
/// go through a single SimScheduler so tests are reproducible from a seed.
/// Same seed → same schedule → same outcome.
const std = @import("std");

pub const SimScheduler = struct {
    prng: std.Random.Xoroshiro128,
    virtual_time_ns: u64,

    pub fn init(seed: u64) SimScheduler {
        return .{
            .prng = std.Random.Xoroshiro128.init(seed),
            .virtual_time_ns = 0,
        };
    }

    pub fn random(self: *SimScheduler) std.Random {
        return self.prng.random();
    }

    /// Return true with probability `prob` (0.0 = never, 1.0 = always).
    pub fn chance(self: *SimScheduler, prob: f64) bool {
        if (prob <= 0.0) return false;
        if (prob >= 1.0) return true;
        return self.prng.random().float(f64) < prob;
    }

    /// Sample a u64 uniformly in [min_val, max_val] inclusive.
    pub fn rangeU64(self: *SimScheduler, min_val: u64, max_val: u64) u64 {
        if (min_val >= max_val) return min_val;
        return min_val + self.prng.random().uintLessThan(u64, max_val - min_val + 1);
    }

    /// Advance virtual time to `ns` (no-op if already past).
    pub fn advanceTo(self: *SimScheduler, ns: u64) void {
        if (ns > self.virtual_time_ns) self.virtual_time_ns = ns;
    }

    /// Advance virtual time by `delta_ns` nanoseconds.
    pub fn advance(self: *SimScheduler, delta_ns: u64) void {
        self.virtual_time_ns +|= delta_ns;
    }

    pub fn now(self: *const SimScheduler) u64 {
        return self.virtual_time_ns;
    }
};

test "SimScheduler: chance boundaries" {
    var s = SimScheduler.init(1234);
    for (0..100) |_| {
        try std.testing.expect(!s.chance(0.0));
        try std.testing.expect(s.chance(1.0));
    }
}

test "SimScheduler: rangeU64 stays in range" {
    var s = SimScheduler.init(42);
    for (0..1000) |_| {
        const v = s.rangeU64(10, 20);
        try std.testing.expect(v >= 10);
        try std.testing.expect(v <= 20);
    }
}

test "SimScheduler: same seed same sequence" {
    var s1 = SimScheduler.init(0xCAFE_BABE);
    var s2 = SimScheduler.init(0xCAFE_BABE);
    for (0..500) |_| {
        try std.testing.expectEqual(s1.rangeU64(0, 1000), s2.rangeU64(0, 1000));
        try std.testing.expectEqual(s1.chance(0.3), s2.chance(0.3));
    }
}

test "SimScheduler: virtual time" {
    var s = SimScheduler.init(0);
    try std.testing.expectEqual(@as(u64, 0), s.now());
    s.advance(1000);
    try std.testing.expectEqual(@as(u64, 1000), s.now());
    s.advanceTo(500);
    try std.testing.expectEqual(@as(u64, 1000), s.now());
    s.advanceTo(2000);
    try std.testing.expectEqual(@as(u64, 2000), s.now());
}

test "SimScheduler: chance distribution roughly 50%" {
    var s = SimScheduler.init(99);
    var hits: usize = 0;
    for (0..10_000) |_| {
        if (s.chance(0.5)) hits += 1;
    }
    // Expect 40%–60% in 10k samples.
    try std.testing.expect(hits >= 4000);
    try std.testing.expect(hits <= 6000);
}
