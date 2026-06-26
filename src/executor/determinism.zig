/// Determinism invariants for the KV fold executor.
const std = @import("std");

pub fn verifyExecutorModule() void {
    comptime {
        _ = @import("types.zig");
    }
}
