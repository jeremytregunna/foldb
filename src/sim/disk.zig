/// DiskSim — controlled I/O fault injection for deterministic simulation testing.
///
/// Each I/O site in the simulation calls shouldFault() before the operation.
/// A non-zero fault_rate causes random I/O errors at that rate, seeded through
/// the shared SimScheduler so the fault sequence is reproducible.
const std = @import("std");
const scheduler_mod = @import("scheduler.zig");

pub const SimScheduler = scheduler_mod.SimScheduler;

pub const DiskConfig = struct {
    /// Probability [0.0, 1.0] that any given I/O operation returns an error.
    fault_rate: f64 = 0.0,
};

pub const DiskSim = struct {
    cfg: DiskConfig,
    sched: SimScheduler,

    /// Create a DiskSim backed by a new SimScheduler seeded with `seed`.
    pub fn init(seed: u64, cfg: DiskConfig) DiskSim {
        return .{ .cfg = cfg, .sched = SimScheduler.init(seed) };
    }

    /// Return true if this I/O operation should be faulted (return an error to caller).
    pub fn shouldFault(self: *DiskSim) bool {
        return self.sched.chance(self.cfg.fault_rate);
    }
};

test "DiskSim: fault_rate=0.0 never faults" {
    var d = DiskSim.init(1, .{ .fault_rate = 0.0 });
    for (0..1000) |_| try std.testing.expect(!d.shouldFault());
}

test "DiskSim: fault_rate=1.0 always faults" {
    var d = DiskSim.init(1, .{ .fault_rate = 1.0 });
    for (0..1000) |_| try std.testing.expect(d.shouldFault());
}

test "DiskSim: same seed same fault pattern" {
    var a = DiskSim.init(0xBEEF, .{ .fault_rate = 0.2 });
    var b = DiskSim.init(0xBEEF, .{ .fault_rate = 0.2 });
    for (0..500) |_| {
        try std.testing.expectEqual(a.shouldFault(), b.shouldFault());
    }
}
