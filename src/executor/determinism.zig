/// Determinism enforcement for the fold executor.
///
/// The fold function must be total-deterministic: given the same log prefix,
/// every node produces bit-identical state (spec §1 invariant 3).
///
/// ## Compile-time enforcement (Tier 1)
///
/// Zig does not expose transitive import graph at comptime, so full whitelist
/// enforcement of function pointers is not possible today. What IS enforced:
///   - QueryContext exposes `resolved` (handlers must use it, not system clocks)
///   - Exchange types are well-formed (ForeignReadRequest is accessible)
///
/// ## Documented contract (Tier 2 — code review enforced)
///
/// QueryHandler and CrossPartitionQueryHandler implementations MUST NOT:
///   1. Call std.time.* or std.os.linux.clock_gettime  (use ctx.seq as logical time)
///   2. Call std.crypto.random, io.random, posix.getrandom   (use ctx.resolved[i])
///   3. Depend on hash-map iteration order             (sort before iterating)
///   4. Use float comparisons for ordering             (sort by primary key)
///   5. Call external I/O                              (reads go through storage parameter)
///
/// These rules also apply transitively to any function called from a handler.
/// Called at comptime from executor.zig to verify structural invariants.
pub fn verifyExecutorModule() void {
    comptime {
        const registry = @import("registry.zig");
        const exchange = @import("exchange.zig");

        // QueryContext must have 'resolved' so handlers can access resolved nondeterminism
        // instead of calling system clocks or RNGs.
        if (!@hasField(registry.QueryContext, "resolved")) {
            @compileError("QueryContext must expose 'resolved' field — handlers must not call system clocks");
        }

        // CrossPartitionQueryHandler must have both required function pointers.
        if (!@hasField(registry.CrossPartitionQueryHandler, "declareReads")) {
            @compileError("CrossPartitionQueryHandler missing declareReads");
        }
        if (!@hasField(registry.CrossPartitionQueryHandler, "execute")) {
            @compileError("CrossPartitionQueryHandler missing execute");
        }

        // Exchange types must be well-formed.
        if (!@hasField(exchange.ForeignReadRequest, "from_partition")) {
            @compileError("ForeignReadRequest missing from_partition");
        }
        if (!@hasField(exchange.ForeignRow, "row")) {
            @compileError("ForeignRow missing row");
        }

        // ValidatedTxnEntry must remain well-formed — it is the only type the executor
        // core accepts; removing its fields would silently allow raw entries to leak in.
        const exec_types = @import("types.zig");
        if (!@hasField(exec_types.ValidatedTxnEntry, "seq")) {
            @compileError("ValidatedTxnEntry must have seq field");
        }
        if (!@hasField(exec_types.ValidatedTxnEntry, "decoded")) {
            @compileError("ValidatedTxnEntry must have decoded field");
        }
    }
}
