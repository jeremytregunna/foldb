/// VirtualClock — deterministic wall-clock replacement for simulation.
///
/// All subsystems that previously called clock_gettime directly now accept a
/// *VirtualClock so the simulation harness controls time. In production, wrap
/// a single global VirtualClock and advance it on real-time ticks. In tests,
/// advance it manually for full determinism.
///
/// Time unit: seconds (i64), matching the SegmentHeader.created_at field and
/// unix timestamp conventions throughout the codebase.
const std = @import("std");

pub const VirtualClock = struct {
    now_sec: i64,

    /// Initialize with a specific starting time (unix seconds).
    pub fn init(start_sec: i64) VirtualClock {
        return .{ .now_sec = start_sec };
    }

    /// Initialize at epoch zero (useful for deterministic tests).
    pub fn zero() VirtualClock {
        return .{ .now_sec = 0 };
    }

    /// Return current time as unix seconds.
    pub fn now(self: *const VirtualClock) i64 {
        return self.now_sec;
    }

    /// Advance clock by delta seconds.
    pub fn advance(self: *VirtualClock, delta_sec: i64) void {
        self.now_sec +|= delta_sec;
    }

    /// Set clock to an absolute time.
    pub fn setTo(self: *VirtualClock, sec: i64) void {
        self.now_sec = sec;
    }
};

test "VirtualClock basic" {
    var clock = VirtualClock.zero();
    try std.testing.expectEqual(@as(i64, 0), clock.now());

    clock.advance(10);
    try std.testing.expectEqual(@as(i64, 10), clock.now());

    clock.setTo(1_000_000);
    try std.testing.expectEqual(@as(i64, 1_000_000), clock.now());

    clock.advance(1);
    try std.testing.expectEqual(@as(i64, 1_000_001), clock.now());
}

test "VirtualClock overflow saturates" {
    var clock = VirtualClock.init(std.math.maxInt(i64));
    clock.advance(1);
    try std.testing.expectEqual(std.math.maxInt(i64), clock.now());
}
