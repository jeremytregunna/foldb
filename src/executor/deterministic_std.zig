/// Deterministic standard library subset for query execution code.
///
/// This module re-exports only the parts of std that are safe to use inside
/// the fold function (spec §7.4). Code in the execution path (eval_expr, type_conv,
/// agg_accum, window_exec, key_encode, params_codec) should import only from here,
/// never from full std, to make non-determinism visible at code review time.
///
/// ## Approved exports
///
/// - std.mem          — safe: no I/O, no clocks
/// - std.math         — safe: pure functions; NaN comparisons must use explicit checks
/// - std.fmt          — safe: formatting is deterministic
/// - std.unicode      — safe: pure UTF-8 decoding
/// - std.hash         — safe: deterministic hash functions (Wyhash, Blake3)
/// - std.sort         — safe: stable sort produces deterministic order
/// - std.ArrayList    — safe: deterministic container
/// - std.AutoHashMap  — safe when iterated in sorted order (see rule 3)
/// - std.StringHashMap — same caveat as AutoHashMap
/// - std.BoundedArray — safe: deterministic container
///
/// ## Explicitly NOT re-exported (non-deterministic)
///
/// - std.time         — FORBIDDEN: use ctx.seq as logical time (spec §7.4 rule 1)
/// - std.crypto.random — FORBIDDEN: use ctx.resolved (spec §7.4 rule 2)
/// - std.rand         — FORBIDDEN: same as above
/// - std.os           — FORBIDDEN: I/O, clocks, process state
/// - std.Thread       — FORBIDDEN: execution is single-threaded per partition
/// - std.fs           — FORBIDDEN: I/O goes through the storage parameter
/// - std.net          — FORBIDDEN: no external calls inside the fold
const std = @import("std");

pub const mem = std.mem;
pub const math = std.math;
pub const fmt = std.fmt;
pub const unicode = std.unicode;
pub const hash = std.hash;
pub const sort = std.sort;
pub const ArrayList = std.ArrayList;
pub const ArrayListUnmanaged = std.ArrayListUnmanaged;
pub const AutoHashMap = std.AutoHashMap;
pub const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;
pub const StringHashMap = std.StringHashMap;
pub const StringHashMapUnmanaged = std.StringHashMapUnmanaged;
pub const BoundedArray = std.BoundedArray;
pub const MultiArrayList = std.MultiArrayList;
pub const Allocator = std.mem.Allocator;
pub const assert = std.debug.assert;
pub const log = std.log;

/// Compile-time assertion that a type is NOT std.time.Timer or std.time.Instant.
/// Call this on any type that enters the execution path from an external parameter
/// to verify it is not carrying wall-clock state.
pub fn assertNotWallClock(comptime T: type) void {
    comptime {
        if (T == std.time.Timer or T == std.time.Instant) {
            @compileError("Wall-clock type in execution path violates §7.4 rule 1; use ctx.seq");
        }
    }
}

/// Compile-time assertion that a type is NOT std.rand.Random or std.crypto.random.
pub fn assertNotRandom(comptime T: type) void {
    comptime {
        if (T == std.rand.Random) {
            @compileError("RNG type in execution path violates §7.4 rule 2; use ctx.resolved");
        }
    }
}
