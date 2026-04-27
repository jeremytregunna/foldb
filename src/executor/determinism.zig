/// Determinism enforcement for the fold executor.
///
/// The fold function must be total-deterministic: given the same log prefix,
/// every node produces bit-identical state (spec §1 invariant 3).
///
/// ## Enforcement strategy
///
/// Full transitive import-graph whitelisting is not possible in Zig today (the compiler
/// does not expose the import graph at comptime). Enforcement uses two tiers:
///
/// ### Tier 1 — Compile-time structural checks (this file)
///
///   - QueryContext exposes `resolved`; handlers must use it instead of system clocks.
///   - ValidatedTxnEntry is well-formed; it is the only type the executor core accepts.
///   - EvalCtx does not carry wall-clock or RNG types.
///   - The deterministic_std shim is the approved import surface (code-review enforced).
///
/// ### Tier 2 — Code review enforced (documented contract)
///
/// QueryHandler implementations and the code they call MUST NOT:
///   1. Call std.time.* or clock_gettime     — use ctx.seq as logical time
///   2. Call std.crypto.random / std.rand    — use ctx.resolved[i]
///   3. Iterate hash maps without sorting    — sort before iterating or use sorted structures
///   4. Use float comparisons for ordering   — sort by primary key instead
///   5. Call external I/O                    — reads go through the storage parameter
///
/// Import whitelist for execution-path modules (eval_expr, type_conv, agg_accum,
/// window_exec, key_encode, params_codec):
///   ALLOWED: std.mem, std.math, std.fmt, std.unicode, std.hash, std.sort,
///            std.ArrayList, std.AutoHashMap, std.StringHashMap, std.BoundedArray
///   FORBIDDEN: std.time, std.crypto.random, std.rand, std.os, std.Thread, std.fs, std.net
///
/// Called at comptime from executor.zig to verify structural invariants.
pub fn verifyExecutorModule() void {
    comptime {
        const registry = @import("registry.zig");

        // Rule: QueryContext must expose 'resolved' so handlers access nondeterminism
        // through the resolved parameter, not system clocks or RNGs.
        if (!@hasField(registry.QueryContext, "resolved")) {
            @compileError("QueryContext must expose 'resolved' field — handlers must not call system clocks");
        }

        // Rule: ValidatedTxnEntry is the domain boundary; it must remain well-formed
        // so the executor core cannot be bypassed by passing raw log entries.
        const exec_types = @import("types.zig");
        if (!@hasField(exec_types.ValidatedTxnEntry, "seq")) {
            @compileError("ValidatedTxnEntry must have seq field");
        }
        if (!@hasField(exec_types.ValidatedTxnEntry, "decoded")) {
            @compileError("ValidatedTxnEntry must have decoded field");
        }

        // Note: EvalCtx structural checks (seq field type, no RNG fields) live in
        // executor_bridge.zig which has access to eval_expr.zig (same sql module).
        // See verifyEvalCtx() called from sql.zig's comptime block.
    }
}
