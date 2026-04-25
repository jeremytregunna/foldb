/// Observability primitives: Counter, Gauge, Histogram.
///
/// All types are plain structs — no hidden allocations, no atomics.
/// Thread-safety is the caller's responsibility; in the single-threaded
/// executor model (one worker per partition) these are safe as-is.
/// For cross-thread reads, wrap the whole metrics struct in a mutex.
const std = @import("std");

const assert = std.debug.assert;

// ---------------------------------------------------------------------------
// Counter — monotonically increasing u64, saturates at max.
// ---------------------------------------------------------------------------

pub const Counter = struct {
    value: u64 = 0,

    pub fn inc(self: *Counter) void {
        self.value +|= 1;
    }

    pub fn add(self: *Counter, n: u64) void {
        self.value +|= n;
    }

    pub fn get(self: *const Counter) u64 {
        return self.value;
    }

    pub fn reset(self: *Counter) void {
        self.value = 0;
    }
};

// ---------------------------------------------------------------------------
// Gauge — signed i64 that can go up or down, saturates at limits.
// ---------------------------------------------------------------------------

pub const Gauge = struct {
    value: i64 = 0,

    pub fn set(self: *Gauge, v: i64) void {
        self.value = v;
    }

    pub fn inc(self: *Gauge) void {
        self.value +|= 1;
    }

    pub fn dec(self: *Gauge) void {
        self.value -|= 1;
    }

    pub fn add(self: *Gauge, n: i64) void {
        self.value +|= n;
    }

    pub fn get(self: *const Gauge) i64 {
        return self.value;
    }
};

// ---------------------------------------------------------------------------
// Histogram — 16 exponential buckets covering 1µs → ∞.
//
// Bucket upper bounds (nanoseconds):
//   [0]   1 µs      [8]  256 µs
//   [1]   2 µs      [9]  512 µs
//   [2]   4 µs      [10]   1 ms
//   [3]   8 µs      [11]   2 ms
//   [4]  16 µs      [12]   4 ms
//   [5]  32 µs      [13]   8 ms
//   [6]  64 µs      [14]  16 ms
//   [7] 128 µs      [15]     ∞
//
// The last bucket uses maxInt(u64) so every sample is always caught by the
// loop in record(), guaranteeing count == sum of all bucket values.
// ---------------------------------------------------------------------------

pub const BUCKET_COUNT: u32 = 16;

pub const BUCKET_UPPER_NS: [BUCKET_COUNT]u64 = .{
    1_000,     2_000,     4_000,      8_000,
    16_000,    32_000,    64_000,     128_000,
    256_000,   512_000,   1_000_000,  2_000_000,
    4_000_000, 8_000_000, 16_000_000, std.math.maxInt(u64),
};

comptime {
    assert(BUCKET_UPPER_NS.len == BUCKET_COUNT);
    // Buckets must be strictly monotonically increasing so record()'s
    // first-match scan assigns each sample to exactly one bucket.
    var prev: u64 = 0;
    for (BUCKET_UPPER_NS) |b| {
        assert(b > prev);
        prev = b;
    }
    assert(BUCKET_UPPER_NS[BUCKET_COUNT - 1] == std.math.maxInt(u64));
}

pub const Histogram = struct {
    buckets: [BUCKET_COUNT]u64 = [_]u64{0} ** BUCKET_COUNT,
    count: u64 = 0,
    sum_ns: u64 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,

    /// Record a latency sample in nanoseconds.
    pub fn record(self: *Histogram, ns: u64) void {
        self.count +|= 1;
        self.sum_ns +|= ns;
        if (ns < self.min_ns) self.min_ns = ns;
        if (ns > self.max_ns) self.max_ns = ns;

        // The last bucket's upper bound is maxInt(u64), so every sample is
        // guaranteed to match before the loop exits. No post-loop fallback
        // is needed or reachable.
        for (BUCKET_UPPER_NS, 0..) |upper, i| {
            if (ns <= upper) {
                self.buckets[i] +|= 1;
                return;
            }
        }
        unreachable; // last bucket upper == maxInt(u64) catches everything
    }

    pub fn mean_ns(self: *const Histogram) u64 {
        if (self.count == 0) return 0;
        return self.sum_ns / self.count;
    }

    /// Approximate percentile via first-match bucket scan.
    /// p is 0–100 (e.g. 99 for p99).
    pub fn percentile(self: *const Histogram, p: u8) u64 {
        assert(p <= 100);
        if (self.count == 0) return 0;
        // Ceiling division: smallest rank ≥ the p-th percentile position.
        const target: u64 = @divFloor(@as(u64, p) * self.count + 99, 100);
        var cumulative: u64 = 0;
        for (self.buckets, 0..) |b, i| {
            cumulative += b;
            if (cumulative >= target) {
                return BUCKET_UPPER_NS[i];
            }
        }
        return self.max_ns;
    }

    pub fn reset(self: *Histogram) void {
        self.* = .{};
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Counter: basic" {
    var c: Counter = .{};
    try std.testing.expectEqual(@as(u64, 0), c.get());
    c.inc();
    c.inc();
    try std.testing.expectEqual(@as(u64, 2), c.get());
    c.add(10);
    try std.testing.expectEqual(@as(u64, 12), c.get());
}

test "Counter: saturates" {
    var c: Counter = .{ .value = std.math.maxInt(u64) };
    c.inc();
    try std.testing.expectEqual(std.math.maxInt(u64), c.get());
}

test "Gauge: set and delta" {
    var g: Gauge = .{};
    g.set(100);
    try std.testing.expectEqual(@as(i64, 100), g.get());
    g.dec();
    try std.testing.expectEqual(@as(i64, 99), g.get());
    g.add(-50);
    try std.testing.expectEqual(@as(i64, 49), g.get());
}

test "Histogram: single sample" {
    var h: Histogram = .{};
    h.record(500); // 500 ns → bucket [0] (≤ 1µs)
    try std.testing.expectEqual(@as(u64, 1), h.count);
    try std.testing.expectEqual(@as(u64, 500), h.sum_ns);
    try std.testing.expectEqual(@as(u64, 500), h.min_ns);
    try std.testing.expectEqual(@as(u64, 500), h.max_ns);
}

test "Histogram: bucket distribution" {
    var h: Histogram = .{};
    h.record(500); // ≤ 1µs
    h.record(1_500); // ≤ 2µs
    h.record(50_000); // ≤ 64µs
    h.record(200_000_000); // overflow → last bucket
    try std.testing.expectEqual(@as(u64, 4), h.count);
    try std.testing.expectEqual(@as(u64, 1), h.buckets[0]); // ≤1µs
    try std.testing.expectEqual(@as(u64, 1), h.buckets[1]); // ≤2µs
    try std.testing.expectEqual(@as(u64, 1), h.buckets[6]); // ≤64µs
    try std.testing.expectEqual(@as(u64, 1), h.buckets[15]); // ∞
}

test "Histogram: last bucket via maxInt" {
    var h: Histogram = .{};
    h.record(std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u64, 1), h.count);
    try std.testing.expectEqual(@as(u64, 1), h.buckets[BUCKET_COUNT - 1]);
}

test "Histogram: mean" {
    var h: Histogram = .{};
    h.record(1000);
    h.record(3000);
    try std.testing.expectEqual(@as(u64, 2000), h.mean_ns());
}

test "Histogram: percentile p50 and p99" {
    var h: Histogram = .{};
    for (0..99) |_| h.record(500); // 99 samples at 500ns → bucket 0
    h.record(5_000_000); // 1 sample at 5ms → bucket 12
    // p50 should be ≤ 1µs bucket
    try std.testing.expectEqual(BUCKET_UPPER_NS[0], h.percentile(50));
    // p99 should be ≤ 1µs bucket (99th sample is the 99th item = still in bucket 0)
    try std.testing.expectEqual(BUCKET_UPPER_NS[0], h.percentile(99));
    // p100 should be last bucket
    try std.testing.expectEqual(BUCKET_UPPER_NS[12], h.percentile(100));
}
