/// Aggregate accumulator: AggAccum struct with update/toValue/deinit.
const std = @import("std");
const plan_mod = @import("plan.zig");
const eval_expr_mod = @import("eval_expr.zig");
const agg_helpers = @import("agg_helpers.zig");
const ast = @import("ast.zig");

const EvalCtx = eval_expr_mod.EvalCtx;
const SqlExecError = eval_expr_mod.SqlExecError;
const evalExpr = eval_expr_mod.evalExpr;
const dupePlanValue = agg_helpers.dupePlanValue;
const freePlanValue = agg_helpers.freePlanValue;
const serializeArrayAgg = agg_helpers.serializeArrayAgg;
const buildStringAgg = agg_helpers.buildStringAgg;

pub const AggAccum = struct {
    count: i64 = 0,
    sum_int: i64 = 0,
    sum_decimal: ast.Decimal = .{ .coefficient = 0, .scale = 0 },
    is_decimal: bool = false,
    min: ?plan_mod.Value = null,
    max: ?plan_mod.Value = null,
    collected: std.ArrayListUnmanaged(plan_mod.Value) = .empty,
    separator: ?[]const u8 = null,

    pub fn deinit(self: *AggAccum, alloc: std.mem.Allocator) void {
        for (self.collected.items) |v| freePlanValue(v, alloc);
        self.collected.deinit(alloc);
        if (self.separator) |s| alloc.free(s);
    }

    pub fn update(self: *AggAccum, ae: plan_mod.AggExpr, row_ctx: EvalCtx) SqlExecError!void {
        if (ae.filter) |f| {
            const fv = try evalExpr(f, row_ctx);
            const passes = switch (fv) {
                .bool_val => |b| b,
                else => false,
            };
            if (!passes) return;
        }

        const val = if (ae.arg) |arg| try evalExpr(arg, row_ctx) else .null_val;
        const fn_name = ae.fn_name;

        if (std.ascii.eqlIgnoreCase(fn_name, "count")) {
            if (ae.arg == null or val != .null_val) self.count += 1;
        } else if (std.ascii.eqlIgnoreCase(fn_name, "sum") or
            std.ascii.eqlIgnoreCase(fn_name, "avg"))
        {
            if (val != .null_val) {
                self.count += 1;
                switch (val) {
                    .int_val => |n| self.sum_int += n,
                    .decimal_val => |d| {
                        self.sum_decimal = decimalAdd(self.sum_decimal, d);
                        self.is_decimal = true;
                    },
                    else => {},
                }
            }
        } else if (std.ascii.eqlIgnoreCase(fn_name, "min")) {
            if (val != .null_val) {
                if (self.min == null or val.lessThan(self.min.?)) self.min = val;
            }
        } else if (std.ascii.eqlIgnoreCase(fn_name, "max")) {
            if (val != .null_val) {
                if (self.max == null or self.max.?.lessThan(val)) self.max = val;
            }
        } else if (std.ascii.eqlIgnoreCase(fn_name, "array_agg")) {
            if (val != .null_val) {
                const duped = try dupePlanValue(val, row_ctx.alloc);
                try self.collected.append(row_ctx.alloc, duped);
            }
        } else if (std.ascii.eqlIgnoreCase(fn_name, "string_agg")) {
            if (val != .null_val) {
                const duped = try dupePlanValue(val, row_ctx.alloc);
                try self.collected.append(row_ctx.alloc, duped);
                if (self.separator == null) {
                    if (ae.separator) |sep_expr| {
                        const sv = try evalExpr(sep_expr, row_ctx);
                        if (sv == .string_val) {
                            self.separator = try row_ctx.alloc.dupe(u8, sv.string_val);
                        }
                    }
                }
            }
        }
    }

    pub fn toValue(self: AggAccum, ae: plan_mod.AggExpr, alloc: std.mem.Allocator) !plan_mod.Value {
        const fn_name = ae.fn_name;
        if (std.ascii.eqlIgnoreCase(fn_name, "count")) {
            return .{ .int_val = self.count };
        } else if (std.ascii.eqlIgnoreCase(fn_name, "sum")) {
            if (self.is_decimal) return .{ .decimal_val = self.sum_decimal };
            return .{ .int_val = self.sum_int };
        } else if (std.ascii.eqlIgnoreCase(fn_name, "avg")) {
            if (self.count == 0) return .null_val;
            if (self.is_decimal) {
                const divisor = ast.Decimal{ .coefficient = self.count, .scale = 0 };
                return .{ .decimal_val = decimalDiv(self.sum_decimal, divisor) catch .{ .coefficient = 0, .scale = 0 } };
            }
            const sum_dec = ast.Decimal{ .coefficient = self.sum_int, .scale = 0 };
            const divisor = ast.Decimal{ .coefficient = self.count, .scale = 0 };
            return .{ .decimal_val = decimalDiv(sum_dec, divisor) catch .{ .coefficient = 0, .scale = 0 } };
        } else if (std.ascii.eqlIgnoreCase(fn_name, "min")) {
            return self.min orelse .null_val;
        } else if (std.ascii.eqlIgnoreCase(fn_name, "max")) {
            return self.max orelse .null_val;
        } else if (std.ascii.eqlIgnoreCase(fn_name, "array_agg")) {
            return .{ .bytes_val = try serializeArrayAgg(self.collected.items, alloc) };
        } else if (std.ascii.eqlIgnoreCase(fn_name, "string_agg")) {
            return .{ .string_val = try buildStringAgg(self.collected.items, self.separator orelse "", alloc) };
        }
        return .null_val;
    }
};

fn decimalPow10(n: u8) i128 {
    var result: i128 = 1;
    var i: u8 = 0;
    while (i < n) : (i += 1) result *= 10;
    return result;
}

fn decimalAdd(a: ast.Decimal, b: ast.Decimal) ast.Decimal {
    if (a.scale == b.scale) return .{ .coefficient = a.coefficient +| b.coefficient, .scale = a.scale };
    const s = @max(a.scale, b.scale);
    const ac = if (a.scale < s) a.coefficient *| decimalPow10(s - a.scale) else a.coefficient;
    const bc = if (b.scale < s) b.coefficient *| decimalPow10(s - b.scale) else b.coefficient;
    return .{ .coefficient = ac +| bc, .scale = s };
}

fn decimalDiv(a: ast.Decimal, b: ast.Decimal) !ast.Decimal {
    if (b.coefficient == 0) return error.DivisionByZero;
    const result_scale: u8 = @max(a.scale, 10);
    const extra: u8 = result_scale + b.scale -| a.scale;
    const scaled_a = a.coefficient *| decimalPow10(extra);
    return .{ .coefficient = @divTrunc(scaled_a, b.coefficient), .scale = result_scale };
}
