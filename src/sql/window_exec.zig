/// Window function execution: computeWindowFnForAll.
const std = @import("std");
const plan_mod = @import("plan.zig");
const storage_mod = @import("storage.zig");
const eval_expr_mod = @import("eval_expr.zig");
const type_conv = @import("type_conv.zig");

pub const ColumnValue = storage_mod.ColumnValue;
const EvalCtx = eval_expr_mod.EvalCtx;
const SqlExecError = eval_expr_mod.SqlExecError;
const evalExpr = eval_expr_mod.evalExpr;
const planValueToColumnValue = type_conv.planValueToColumnValue;
const aggKeyEquals = type_conv.aggKeyEquals;

// ---------------------------------------------------------------------------
// Frame helpers
// ---------------------------------------------------------------------------

/// Returns true when the ORDER BY keys of two rows (by sorted-array index) are equal.
fn orderKeysEqual(
    a_sorted_pos: usize,
    b_sorted_pos: usize,
    sorted: []const usize,
    rows: []const []const ?ColumnValue,
    order_by: []const plan_mod.SortKey,
    ctx: EvalCtx,
) bool {
    if (order_by.len == 0) return true;
    var ctx_a = ctx;
    var ctx_b = ctx;
    ctx_a.row = rows[sorted[a_sorted_pos]];
    ctx_b.row = rows[sorted[b_sorted_pos]];
    for (order_by) |sk| {
        const va = evalExpr(sk.expr, ctx_a) catch return false;
        const vb = evalExpr(sk.expr, ctx_b) catch return false;
        if (!va.eql(vb)) return false;
    }
    return true;
}

/// For RANGE CURRENT ROW as a start bound: first sorted position whose ORDER BY
/// key equals that of `pos`.
fn rangeCurrentRowStart(
    pos: usize,
    sorted: []const usize,
    rows: []const []const ?ColumnValue,
    order_by: []const plan_mod.SortKey,
    ctx: EvalCtx,
) usize {
    var i: usize = pos;
    while (i > 0 and orderKeysEqual(i - 1, pos, sorted, rows, order_by, ctx)) {
        i -= 1;
    }
    return i;
}

/// For RANGE CURRENT ROW as an end bound: last sorted position whose ORDER BY
/// key equals that of `pos`.
fn rangeCurrentRowEnd(
    pos: usize,
    sorted: []const usize,
    rows: []const []const ?ColumnValue,
    order_by: []const plan_mod.SortKey,
    ctx: EvalCtx,
) usize {
    var i: usize = pos;
    while (i + 1 < sorted.len and orderKeysEqual(i + 1, pos, sorted, rows, order_by, ctx)) {
        i += 1;
    }
    return i;
}

/// Resolve a single frame bound to a sorted-array index (inclusive).
/// `is_start` distinguishes start vs. end for RANGE CURRENT ROW peer-group logic.
fn resolveFrameBound(
    bound: plan_mod.FrameBound,
    mode: plan_mod.FrameMode,
    pos: usize,
    sorted: []const usize,
    rows: []const []const ?ColumnValue,
    order_by: []const plan_mod.SortKey,
    ctx: EvalCtx,
    is_start: bool,
) usize {
    const last = if (sorted.len > 0) sorted.len - 1 else 0;
    return switch (bound) {
        .unbounded_preceding => 0,
        .unbounded_following => last,
        .current_row => switch (mode) {
            .rows => pos,
            .range => if (is_start)
                rangeCurrentRowStart(pos, sorted, rows, order_by, ctx)
            else
                rangeCurrentRowEnd(pos, sorted, rows, order_by, ctx),
        },
        .preceding => |e| switch (mode) {
            .rows => blk: {
                var row_ctx = ctx;
                row_ctx.row = rows[sorted[pos]];
                const v = evalExpr(e, row_ctx) catch break :blk pos;
                const offset: usize = switch (v) {
                    .int_val => |n| if (n >= 0) @as(usize, @intCast(n)) else 0,
                    else => break :blk pos,
                };
                break :blk if (pos >= offset) pos - offset else 0;
            },
            // Offset RANGE requires type-specific arithmetic on the ORDER BY key;
            // fall back to CURRENT ROW semantics until implemented.
            .range => rangeCurrentRowStart(pos, sorted, rows, order_by, ctx),
        },
        .following => |e| switch (mode) {
            .rows => blk: {
                var row_ctx = ctx;
                row_ctx.row = rows[sorted[pos]];
                const v = evalExpr(e, row_ctx) catch break :blk pos;
                const offset: usize = switch (v) {
                    .int_val => |n| if (n >= 0) @as(usize, @intCast(n)) else 0,
                    else => break :blk pos,
                };
                const result = pos + offset;
                break :blk @min(result, last);
            },
            .range => rangeCurrentRowEnd(pos, sorted, rows, order_by, ctx),
        },
    };
}

/// Compute the inclusive [start, end] frame bounds for a given sorted position.
///
/// Default frames (SQL standard):
///   - ORDER BY present, no explicit frame → RANGE UNBOUNDED PRECEDING TO CURRENT ROW
///   - No ORDER BY, no explicit frame      → ROWS UNBOUNDED PRECEDING TO UNBOUNDED FOLLOWING
fn computeFrameBounds(
    frame: ?plan_mod.FrameSpec,
    pos: usize,
    sorted: []const usize,
    rows: []const []const ?ColumnValue,
    order_by: []const plan_mod.SortKey,
    ctx: EvalCtx,
) struct { start: usize, end: usize } {
    const last = if (sorted.len > 0) sorted.len - 1 else 0;
    if (frame == null) {
        if (order_by.len > 0) {
            // Default: RANGE UNBOUNDED PRECEDING TO CURRENT ROW
            return .{ .start = 0, .end = rangeCurrentRowEnd(pos, sorted, rows, order_by, ctx) };
        } else {
            return .{ .start = 0, .end = last };
        }
    }
    const f = frame.?;
    const s = resolveFrameBound(f.start, f.mode, pos, sorted, rows, order_by, ctx, true);
    const e = resolveFrameBound(f.end, f.mode, pos, sorted, rows, order_by, ctx, false);
    return .{ .start = @min(s, last), .end = @min(e, last) };
}

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

pub fn computeWindowFnForAll(
    wf: plan_mod.WindowFnSpec,
    rows: []const []const ?ColumnValue,
    results: [][]?ColumnValue,
    fn_idx: usize,
    ctx: EvalCtx,
) SqlExecError!void {
    // Group rows into partitions by evaluating partition_by expressions
    const PartKey = struct { vals: []?ColumnValue, indices: std.ArrayList(usize) };
    var parts: std.ArrayList(PartKey) = .empty;
    defer {
        for (parts.items) |*p| {
            ctx.alloc.free(p.vals);
            p.indices.deinit(ctx.alloc);
        }
        parts.deinit(ctx.alloc);
    }

    for (rows, 0..) |row, ri| {
        var row_ctx = ctx;
        row_ctx.row = row;
        const pk = try ctx.alloc.alloc(?ColumnValue, wf.partition_by.len);
        for (wf.partition_by, 0..) |pb, i| {
            const v = evalExpr(pb, row_ctx) catch .null_val;
            pk[i] = planValueToColumnValue(v, ctx.alloc) catch null;
        }

        var found: ?*PartKey = null;
        for (parts.items) |*p| {
            if (aggKeyEquals(p.vals, pk)) {
                found = p;
                break;
            }
        }
        if (found) |p| {
            ctx.alloc.free(pk);
            try p.indices.append(ctx.alloc, ri);
        } else {
            var idx_list: std.ArrayList(usize) = .empty;
            try idx_list.append(ctx.alloc, ri);
            try parts.append(ctx.alloc, .{ .vals = pk, .indices = idx_list });
        }
    }

    // For each partition, sort by order_by, then assign window fn values
    for (parts.items) |*p| {
        const indices = p.indices.items;
        var sorted = try ctx.alloc.dupe(usize, indices);
        defer ctx.alloc.free(sorted);

        // Stable insertion sort by order_by keys
        if (sorted.len == 0) continue;
        for (1..sorted.len) |i| {
            const key_idx = sorted[i];
            var j: usize = i;
            while (j > 0) {
                var ctx_a = ctx;
                var ctx_b = ctx;
                ctx_a.row = rows[sorted[j - 1]];
                ctx_b.row = rows[key_idx];
                const swap = blk: {
                    for (wf.order_by) |sk| {
                        const va = evalExpr(sk.expr, ctx_a) catch break :blk false;
                        const vb = evalExpr(sk.expr, ctx_b) catch break :blk false;
                        if (!va.eql(vb)) break :blk if (sk.asc) vb.lessThan(va) else va.lessThan(vb);
                    }
                    break :blk false;
                };
                if (!swap) break;
                sorted[j] = sorted[j - 1];
                j -= 1;
            }
            sorted[j] = key_idx;
        }

        if (std.ascii.eqlIgnoreCase(wf.fn_name, "row_number")) {
            for (sorted, 0..) |ri, pos| {
                results[ri][fn_idx] = .{ .int64 = @intCast(pos + 1) };
            }
        } else if (std.ascii.eqlIgnoreCase(wf.fn_name, "rank")) {
            var rank: i64 = 1;
            var count: i64 = 0;
            var prev_order_vals: ?[]plan_mod.Value = null;
            defer if (prev_order_vals) |pv| ctx.alloc.free(pv);
            for (sorted) |ri| {
                count += 1;
                var row_ctx = ctx;
                row_ctx.row = rows[ri];
                const cur = try ctx.alloc.alloc(plan_mod.Value, wf.order_by.len);
                defer ctx.alloc.free(cur);
                for (wf.order_by, 0..) |sk, i| {
                    cur[i] = evalExpr(sk.expr, row_ctx) catch .null_val;
                }
                if (prev_order_vals) |pv| {
                    var same = true;
                    for (cur, pv) |cv, pval| {
                        if (!cv.eql(pval)) {
                            same = false;
                            break;
                        }
                    }
                    if (!same) {
                        rank = count;
                        ctx.alloc.free(pv);
                        prev_order_vals = try ctx.alloc.dupe(plan_mod.Value, cur);
                    }
                } else {
                    prev_order_vals = try ctx.alloc.dupe(plan_mod.Value, cur);
                }
                results[ri][fn_idx] = .{ .int64 = rank };
            }
        } else if (std.ascii.eqlIgnoreCase(wf.fn_name, "dense_rank")) {
            var rank: i64 = 0;
            var prev_order_vals: ?[]plan_mod.Value = null;
            defer if (prev_order_vals) |pv| ctx.alloc.free(pv);
            for (sorted) |ri| {
                var row_ctx = ctx;
                row_ctx.row = rows[ri];
                const cur = try ctx.alloc.alloc(plan_mod.Value, wf.order_by.len);
                defer ctx.alloc.free(cur);
                for (wf.order_by, 0..) |sk, i| {
                    cur[i] = evalExpr(sk.expr, row_ctx) catch .null_val;
                }
                if (prev_order_vals) |pv| {
                    var same = true;
                    for (cur, pv) |cv, pval| {
                        if (!cv.eql(pval)) {
                            same = false;
                            break;
                        }
                    }
                    if (!same) {
                        rank += 1;
                        ctx.alloc.free(pv);
                        prev_order_vals = try ctx.alloc.dupe(plan_mod.Value, cur);
                    }
                } else {
                    rank = 1;
                    prev_order_vals = try ctx.alloc.dupe(plan_mod.Value, cur);
                }
                results[ri][fn_idx] = .{ .int64 = rank };
            }
        } else if (std.ascii.eqlIgnoreCase(wf.fn_name, "lag") or
            std.ascii.eqlIgnoreCase(wf.fn_name, "lead"))
        {
            const is_lead = std.ascii.eqlIgnoreCase(wf.fn_name, "lead");
            for (sorted, 0..) |ri, pos| {
                const offset: usize = if (wf.args.len > 1) blk: {
                    var row_ctx = ctx;
                    row_ctx.row = rows[ri];
                    const ov = evalExpr(wf.args[1], row_ctx) catch break :blk 1;
                    break :blk switch (ov) {
                        .int_val => |n| if (n >= 0) @intCast(n) else 1,
                        else => 1,
                    };
                } else 1;

                const src_pos: ?usize = if (is_lead) blk: {
                    const fwd = pos + offset;
                    break :blk if (fwd < sorted.len) fwd else null;
                } else blk: {
                    break :blk if (pos >= offset) pos - offset else null;
                };

                if (src_pos) |sp| {
                    var row_ctx = ctx;
                    row_ctx.row = rows[sorted[sp]];
                    const v = evalExpr(wf.args[0], row_ctx) catch continue;
                    results[ri][fn_idx] = planValueToColumnValue(v, ctx.alloc) catch null;
                } else if (wf.args.len > 2) {
                    var row_ctx = ctx;
                    row_ctx.row = rows[ri];
                    const dv = evalExpr(wf.args[2], row_ctx) catch continue;
                    results[ri][fn_idx] = planValueToColumnValue(dv, ctx.alloc) catch null;
                }
                // else: out of bounds with no default — leave null
            }
        } else if (std.ascii.eqlIgnoreCase(wf.fn_name, "first_value")) {
            if (sorted.len == 0 or wf.args.len == 0) continue;
            for (sorted, 0..) |ri, pos| {
                const bounds = computeFrameBounds(wf.frame, pos, sorted, rows, wf.order_by, ctx);
                if (bounds.start > bounds.end) {
                    results[ri][fn_idx] = null;
                    continue;
                }
                var row_ctx = ctx;
                row_ctx.row = rows[sorted[bounds.start]];
                const v = evalExpr(wf.args[0], row_ctx) catch continue;
                results[ri][fn_idx] = planValueToColumnValue(v, ctx.alloc) catch null;
            }
        } else if (std.ascii.eqlIgnoreCase(wf.fn_name, "last_value")) {
            if (sorted.len == 0 or wf.args.len == 0) continue;
            for (sorted, 0..) |ri, pos| {
                const bounds = computeFrameBounds(wf.frame, pos, sorted, rows, wf.order_by, ctx);
                if (bounds.start > bounds.end) {
                    results[ri][fn_idx] = null;
                    continue;
                }
                var row_ctx = ctx;
                row_ctx.row = rows[sorted[bounds.end]];
                const v = evalExpr(wf.args[0], row_ctx) catch continue;
                results[ri][fn_idx] = planValueToColumnValue(v, ctx.alloc) catch null;
            }
        } else if (std.ascii.eqlIgnoreCase(wf.fn_name, "nth_value")) {
            if (sorted.len == 0 or wf.args.len < 2) continue;
            for (sorted, 0..) |ri, pos| {
                const bounds = computeFrameBounds(wf.frame, pos, sorted, rows, wf.order_by, ctx);
                if (bounds.start > bounds.end) {
                    results[ri][fn_idx] = null;
                    continue;
                }
                var row_ctx0 = ctx;
                row_ctx0.row = rows[sorted[pos]];
                const n: usize = blk: {
                    const nv = evalExpr(wf.args[1], row_ctx0) catch break :blk 0;
                    break :blk switch (nv) {
                        .int_val => |iv| if (iv >= 1) @as(usize, @intCast(iv - 1)) else 0,
                        else => 0,
                    };
                };
                const frame_pos = bounds.start + n;
                if (frame_pos > bounds.end) {
                    results[ri][fn_idx] = null;
                    continue;
                }
                var row_ctx = ctx;
                row_ctx.row = rows[sorted[frame_pos]];
                const v = evalExpr(wf.args[0], row_ctx) catch continue;
                results[ri][fn_idx] = planValueToColumnValue(v, ctx.alloc) catch null;
            }
        } else if (std.ascii.eqlIgnoreCase(wf.fn_name, "sum") or
            std.ascii.eqlIgnoreCase(wf.fn_name, "count") or
            std.ascii.eqlIgnoreCase(wf.fn_name, "avg") or
            std.ascii.eqlIgnoreCase(wf.fn_name, "min") or
            std.ascii.eqlIgnoreCase(wf.fn_name, "max"))
        {
            const is_count = std.ascii.eqlIgnoreCase(wf.fn_name, "count");
            const is_avg = std.ascii.eqlIgnoreCase(wf.fn_name, "avg");
            const is_min = std.ascii.eqlIgnoreCase(wf.fn_name, "min");
            const is_max = std.ascii.eqlIgnoreCase(wf.fn_name, "max");

            for (sorted, 0..) |ri, pos| {
                const bounds = computeFrameBounds(wf.frame, pos, sorted, rows, wf.order_by, ctx);
                var agg_sum: i128 = 0;
                var agg_count: i64 = 0;
                var agg_min: ?i128 = null;
                var agg_max: ?i128 = null;

                var fi: usize = bounds.start;
                while (fi <= bounds.end and fi < sorted.len) : (fi += 1) {
                    const frame_ri = sorted[fi];
                    var row_ctx = ctx;
                    row_ctx.row = rows[frame_ri];

                    if (is_count and wf.args.len == 0) {
                        agg_count += 1; // COUNT(*)
                        continue;
                    }
                    if (wf.args.len == 0) continue;
                    const v = evalExpr(wf.args[0], row_ctx) catch continue;
                    if (v == .null_val) continue;
                    const n: i128 = switch (v) {
                        .int_val => |iv| @intCast(iv),
                        .uint_val => |uv| @intCast(uv),
                        .decimal_val => |d| d.coefficient,
                        else => continue,
                    };
                    agg_count += 1;
                    agg_sum += n;
                    if (is_min) agg_min = if (agg_min) |m| @min(m, n) else n;
                    if (is_max) agg_max = if (agg_max) |m| @max(m, n) else n;
                }

                results[ri][fn_idx] = if (is_count)
                    .{ .int64 = agg_count }
                else if (agg_count == 0)
                    null
                else if (is_avg)
                    .{ .int64 = @intCast(@divTrunc(agg_sum, agg_count)) }
                else if (is_min)
                    .{ .int64 = @intCast(agg_min.?) }
                else if (is_max)
                    .{ .int64 = @intCast(agg_max.?) }
                else // sum
                    .{ .int64 = @intCast(agg_sum) };
            }
        }
        // Unknown window functions leave result as null
    }
}
