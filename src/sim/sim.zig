/// Simulation module — deterministic testing infrastructure.
///
/// Import this module in tests and simulation drivers. Production code should
/// only import the pieces it needs (e.g. VirtualClock for timestamp injection).
pub const VirtualClock = @import("clock.zig").VirtualClock;
pub const SimScheduler = @import("scheduler.zig").SimScheduler;
pub const NetworkSim = @import("network.zig").NetworkSim;
pub const NetworkConfig = @import("network.zig").NetworkConfig;
pub const DiskSim = @import("disk.zig").DiskSim;
pub const DiskConfig = @import("disk.zig").DiskConfig;
