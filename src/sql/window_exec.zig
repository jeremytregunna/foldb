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
            var row_ctx = ctx;
            row_ctx.row = rows[sorted[0]];
            const v = evalExpr(wf.args[0], row_ctx) catch continue;
            const cv = planValueToColumnValue(v, ctx.alloc) catch null;
            for (sorted) |ri| {
                results[ri][fn_idx] = if (cv) |c| c.dupe(ctx.alloc) catch null else null;
            }
            if (cv) |c| c.freeIfOwned(ctx.alloc);
        } else if (std.ascii.eqlIgnoreCase(wf.fn_name, "last_value")) {
            if (sorted.len == 0 or wf.args.len == 0) continue;
            var row_ctx = ctx;
            row_ctx.row = rows[sorted[sorted.len - 1]];
            const v = evalExpr(wf.args[0], row_ctx) catch continue;
            const cv = planValueToColumnValue(v, ctx.alloc) catch null;
            for (sorted) |ri| {
                results[ri][fn_idx] = if (cv) |c| c.dupe(ctx.alloc) catch null else null;
            }
            if (cv) |c| c.freeIfOwned(ctx.alloc);
        } else if (std.ascii.eqlIgnoreCase(wf.fn_name, "nth_value")) {
            if (sorted.len == 0 or wf.args.len < 2) continue;
            var row_ctx0 = ctx;
            row_ctx0.row = rows[sorted[0]];
            const n: usize = blk: {
                const nv = evalExpr(wf.args[1], row_ctx0) catch break :blk 0;
                break :blk switch (nv) {
                    .int_val => |iv| if (iv >= 1) @as(usize, @intCast(iv - 1)) else 0,
                    else => 0,
                };
            };
            const cv: ?ColumnValue = if (n < sorted.len) blk: {
                var row_ctx = ctx;
                row_ctx.row = rows[sorted[n]];
                const v = evalExpr(wf.args[0], row_ctx) catch break :blk null;
                break :blk planValueToColumnValue(v, ctx.alloc) catch null;
            } else null;
            for (sorted) |ri| {
                results[ri][fn_idx] = if (cv) |c| c.dupe(ctx.alloc) catch null else null;
            }
            if (cv) |c| c.freeIfOwned(ctx.alloc);
        }
        // Unknown window functions leave result as null
    }
}
