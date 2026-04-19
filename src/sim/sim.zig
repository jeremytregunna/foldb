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

/// Called at comptime to verify the sim harness exposes the required interface.
/// Same-seed determinism relies on VirtualClock and SimScheduler being the sole
/// sources of time and randomness in simulation; removing their methods would
/// silently break the determinism contract without a compile error.
pub fn verifySimHarness() void {
    comptime {
        if (!@hasDecl(VirtualClock, "now")) {
            @compileError("VirtualClock must expose now() — sim consumers depend on it for logical time");
        }
        if (!@hasDecl(VirtualClock, "advance")) {
            @compileError("VirtualClock must expose advance() — tests advance time explicitly");
        }
        if (!@hasDecl(SimScheduler, "random")) {
            @compileError("SimScheduler must expose random() — all sim randomness goes through it");
        }
        if (!@hasDecl(SimScheduler, "chance")) {
            @compileError("SimScheduler must expose chance() — fault injection depends on it");
        }
        if (!@hasDecl(NetworkSim, "init")) {
            @compileError("NetworkSim must expose init()");
        }
        if (!@hasDecl(DiskSim, "init")) {
            @compileError("DiskSim must expose init()");
        }
    }
}
