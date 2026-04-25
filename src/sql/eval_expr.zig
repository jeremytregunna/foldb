/// Expression evaluator: EvalCtx, evalExpr, evalBinary, evalBuiltin, JSON ops, likeMatch.
const std = @import("std");
const plan_mod = @import("plan.zig");
const ast = @import("ast.zig");
const schema_mod = @import("schema.zig");
const storage_mod = @import("storage.zig");
const executor_mod = @import("executor.zig");
const type_conv = @import("type_conv.zig");

const assert = std.debug.assert;

pub const ColumnValue = storage_mod.ColumnValue;
pub const ResolvedValue = executor_mod.ResolvedValue;
pub const Seq = executor_mod.Seq;

const columnValueToPlanValue = type_conv.columnValueToPlanValue;
const planValueToColumnValue = type_conv.planValueToColumnValue;
const castValue = type_conv.castValue;

const Decimal = ast.Decimal;

fn decimalPow10(n: u8) i128 {
    assert(n <= 38);
    var result: i128 = 1;
    var i: u8 = 0;
    while (i < n) : (i += 1) result *= 10;
    return result;
}

fn decimalAdd(a: Decimal, b: Decimal) Decimal {
    if (a.scale == b.scale) return .{ .coefficient = a.coefficient +| b.coefficient, .scale = a.scale };
    const s = @max(a.scale, b.scale);
    const ac = if (a.scale < s) a.coefficient *| decimalPow10(s - a.scale) else a.coefficient;
    const bc = if (b.scale < s) b.coefficient *| decimalPow10(s - b.scale) else b.coefficient;
    return .{ .coefficient = ac +| bc, .scale = s };
}

fn decimalSub(a: Decimal, b: Decimal) Decimal {
    if (a.scale == b.scale) return .{ .coefficient = a.coefficient -| b.coefficient, .scale = a.scale };
    const s = @max(a.scale, b.scale);
    const ac = if (a.scale < s) a.coefficient *| decimalPow10(s - a.scale) else a.coefficient;
    const bc = if (b.scale < s) b.coefficient *| decimalPow10(s - b.scale) else b.coefficient;
    return .{ .coefficient = ac -| bc, .scale = s };
}

fn decimalMul(a: Decimal, b: Decimal) Decimal {
    const new_scale = @min(a.scale + b.scale, 38);
    const scale_drop = (a.scale + b.scale) - new_scale;
    var coeff = a.coefficient *| b.coefficient;
    // Drop excess scale by dividing (truncating toward zero)
    if (scale_drop > 0) coeff = @divTrunc(coeff, decimalPow10(@intCast(scale_drop)));
    return .{ .coefficient = coeff, .scale = new_scale };
}

fn decimalDiv(a: Decimal, b: Decimal) SqlExecError!Decimal {
    if (b.coefficient == 0) return error.DivisionByZero;
    // Bring both to the same scale, then multiply numerator by 10^result_scale.
    const result_scale: u8 = @max(a.scale, 10);
    const extra: u8 = result_scale + b.scale -| a.scale;
    const scaled_a = a.coefficient *| decimalPow10(extra);
    return .{ .coefficient = @divTrunc(scaled_a, b.coefficient), .scale = result_scale };
}

fn decimalMod(a: Decimal, b: Decimal) SqlExecError!Decimal {
    if (b.coefficient == 0) return error.DivisionByZero;
    const s = @max(a.scale, b.scale);
    const ac = if (a.scale < s) a.coefficient *| decimalPow10(s - a.scale) else a.coefficient;
    const bc = if (b.scale < s) b.coefficient *| decimalPow10(s - b.scale) else b.coefficient;
    return .{ .coefficient = @rem(ac, bc), .scale = s };
}

fn intToDecimal(n: i64) Decimal {
    return .{ .coefficient = n, .scale = 0 };
}

pub const SqlExecError = error{
    ConstraintViolation,
    ForeignKeyViolation,
    TableNotFound,
    ColumnNotFound,
    TypeMismatch,
    DivisionByZero,
    IntegerOverflow,
    NullViolation,
    AssertionFailed,
    OutOfMemory,
    StorageReadError,
};

/// Context passed to expression evaluator during plan execution.
/// Uses a vtable-style scan_fn + executor_ctx to avoid a circular import
/// back to SqlExecutor.
pub const EvalCtx = struct {
    scan_fn: *const fn (
        *anyopaque,
        *plan_mod.PlanNode,
        *const EvalCtx,
        *std.ArrayList([]const ?ColumnValue),
    ) anyerror!void,
    executor_ctx: *anyopaque,
    params: []const ColumnValue,
    nondet: []const ResolvedValue,
    seq: Seq,
    row: ?[]const ?ColumnValue,
    schema: *const schema_mod.SchemaRegistry,
    alloc: std.mem.Allocator,
};

pub fn freeRowValues(vals: []const ?ColumnValue, alloc: std.mem.Allocator) void {
    for (vals) |v| if (v) |cv| cv.freeIfOwned(alloc);
    alloc.free(vals);
}

pub fn evalExpr(e: *plan_mod.PlanExpr, ctx: EvalCtx) SqlExecError!plan_mod.Value {
    return switch (e.*) {
        .null_literal => .null_val,
        .bool_literal => |v| .{ .bool_val = v },
        .int_literal => |v| .{ .int_val = v },
        .uint_literal => |v| .{ .uint_val = v },
        .float_literal => |v| .{ .float_val = v },
        .decimal_literal => |v| .{ .decimal_val = v },
        .string_literal => |v| .{ .string_val = v },
        .bytes_literal => |v| .{ .bytes_val = v },

        .param => |i| {
            if (i >= ctx.params.len) return error.TypeMismatch;
            return columnValueToPlanValue(ctx.params[i]);
        },

        .nondet => |i| {
            if (i >= ctx.nondet.len) return .null_val;
            return switch (ctx.nondet[i]) {
                .now => |ts| .{ .int_val = ts },
                .random => |b| .{ .bytes_val = &b },
                .uuid_v7 => |b| .{ .bytes_val = &b },
            };
        },

        .column => |idx| {
            const row = ctx.row orelse return .null_val;
            if (idx >= row.len) return .null_val;
            const cv = row[idx] orelse return .null_val;
            return columnValueToPlanValue(cv);
        },

        .fn_call => |f| try evalBuiltin(f.name, f.args, ctx),

        .binary => |b| try evalBinary(b.op, b.left, b.right, ctx),

        .unary => |u| switch (u.op) {
            .neg => {
                const v = try evalExpr(u.expr, ctx);
                return switch (v) {
                    .int_val => |n| .{ .int_val = -n },
                    .float_val => |n| .{ .float_val = -n },
                    .decimal_val => |d| .{ .decimal_val = .{ .coefficient = -d.coefficient, .scale = d.scale } },
                    else => error.TypeMismatch,
                };
            },
            .not => {
                const v = try evalExpr(u.expr, ctx);
                return .{ .bool_val = !(v.toBool() orelse return error.TypeMismatch) };
            },
            .bit_not => {
                const v = try evalExpr(u.expr, ctx);
                return switch (v) {
                    .int_val => |n| .{ .int_val = ~n },
                    else => error.TypeMismatch,
                };
            },
        },

        .is_null => |inner| blk: {
            const v = try evalExpr(inner, ctx);
            break :blk .{ .bool_val = v == .null_val };
        },
        .is_not_null => |inner| blk: {
            const v = try evalExpr(inner, ctx);
            break :blk .{ .bool_val = v != .null_val };
        },

        .cast => |c| {
            const v = try evalExpr(c.expr, ctx);
            return castValue(v, c.to) catch error.TypeMismatch;
        },

        .case_searched => |cs| blk: {
            for (cs.whens) |w| {
                const cond = try evalExpr(w.cond, ctx);
                if (cond.toBool() orelse false) {
                    break :blk try evalExpr(w.result, ctx);
                }
            }
            if (cs.else_expr) |ee| break :blk try evalExpr(ee, ctx);
            break :blk .null_val;
        },

        .table_column => |tc| {
            // In a join context, the combined row has left then right columns.
            // table_idx and col_idx were set by the planner; for M5 we treat the
            // absolute position as table_idx * table_width + col_idx — but since
            // the planner now emits .column for resolved refs, this path is only
            // hit for unresolved cases. Return null safely.
            _ = tc;
            return .null_val;
        },

        .scalar_subquery => |sub| {
            var rows: std.ArrayList([]const ?ColumnValue) = .empty;
            defer {
                for (rows.items) |r| freeRowValues(r, ctx.alloc);
                rows.deinit(ctx.alloc);
            }
            ctx.scan_fn(ctx.executor_ctx, sub, &ctx, &rows) catch return error.TableNotFound;
            if (rows.items.len == 0 or rows.items[0].len == 0) return .null_val;
            const cv = rows.items[0][0] orelse return .null_val;
            return columnValueToPlanValue(cv);
        },

        .exists_subquery => |sub| {
            var rows: std.ArrayList([]const ?ColumnValue) = .empty;
            defer {
                for (rows.items) |r| freeRowValues(r, ctx.alloc);
                rows.deinit(ctx.alloc);
            }
            ctx.scan_fn(ctx.executor_ctx, sub, &ctx, &rows) catch return error.TableNotFound;
            return .{ .bool_val = rows.items.len > 0 };
        },

        .not_exists_subquery => |sub| {
            var rows: std.ArrayList([]const ?ColumnValue) = .empty;
            defer {
                for (rows.items) |r| freeRowValues(r, ctx.alloc);
                rows.deinit(ctx.alloc);
            }
            ctx.scan_fn(ctx.executor_ctx, sub, &ctx, &rows) catch return error.TableNotFound;
            return .{ .bool_val = rows.items.len == 0 };
        },

        .in_subquery => |s| {
            const lhs = try evalExpr(s.expr, ctx);
            var rows: std.ArrayList([]const ?ColumnValue) = .empty;
            defer {
                for (rows.items) |r| freeRowValues(r, ctx.alloc);
                rows.deinit(ctx.alloc);
            }
            ctx.scan_fn(ctx.executor_ctx, s.plan, &ctx, &rows) catch return error.TableNotFound;
            for (rows.items) |row| {
                if (row.len == 0) continue;
                const cv = row[0] orelse continue;
                if (lhs.eql(columnValueToPlanValue(cv))) return .{ .bool_val = true };
            }
            return .{ .bool_val = false };
        },

        .not_in_subquery => |s| {
            const lhs = try evalExpr(s.expr, ctx);
            var rows: std.ArrayList([]const ?ColumnValue) = .empty;
            defer {
                for (rows.items) |r| freeRowValues(r, ctx.alloc);
                rows.deinit(ctx.alloc);
            }
            ctx.scan_fn(ctx.executor_ctx, s.plan, &ctx, &rows) catch return error.TableNotFound;
            for (rows.items) |row| {
                if (row.len == 0) continue;
                const cv = row[0] orelse continue;
                if (lhs.eql(columnValueToPlanValue(cv))) return .{ .bool_val = false };
            }
            return .{ .bool_val = true };
        },
    };
}

pub fn evalBinary(
    op: ast.BinOp,
    left: *plan_mod.PlanExpr,
    right: *plan_mod.PlanExpr,
    ctx: EvalCtx,
) SqlExecError!plan_mod.Value {
    const lv = try evalExpr(left, ctx);
    const rv = try evalExpr(right, ctx);
    // SQL NULL propagation: most ops return NULL when either operand is NULL.
    if (lv == .null_val or rv == .null_val) {
        return switch (op) {
            .eq, .neq, .lt, .gt, .lte, .gte => .null_val,
            .and_op => if (lv == .null_val and rv.toBool() == false) .{ .bool_val = false } else .null_val,
            .or_op => if (lv == .null_val and rv.toBool() == true) .{ .bool_val = true } else .null_val,
            else => .null_val,
        };
    }
    return switch (op) {
        .add, .sub, .mul, .div, .mod => evalBinaryArith(op, lv, rv),
        .bit_and, .bit_or, .bit_xor, .shl, .shr => evalBinaryBitwise(op, lv, rv),
        .eq => .{ .bool_val = lv.eql(rv) },
        .neq => .{ .bool_val = !lv.eql(rv) },
        .lt => .{ .bool_val = lv.lessThan(rv) },
        .gt => .{ .bool_val = rv.lessThan(lv) },
        .lte => .{ .bool_val = lv.lessThan(rv) or lv.eql(rv) },
        .gte => .{ .bool_val = rv.lessThan(lv) or lv.eql(rv) },
        .and_op => .{ .bool_val = (lv.toBool() orelse false) and (rv.toBool() orelse false) },
        .or_op => .{ .bool_val = (lv.toBool() orelse false) or (rv.toBool() orelse false) },
        .concat => switch (lv) {
            .string_val => |a| switch (rv) {
                .string_val => |b| blk: {
                    const s = try ctx.alloc.alloc(u8, a.len + b.len);
                    @memcpy(s[0..a.len], a);
                    @memcpy(s[a.len..], b);
                    break :blk .{ .string_val = s };
                },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        },
        .contains, .contained => evalBinaryJson(op, lv, rv, ctx.alloc),
        .arrow => evalBinaryJsonAccess(lv, rv, false, ctx.alloc),
        .darrow => evalBinaryJsonAccess(lv, rv, true, ctx.alloc),
    };
}

fn toDecimal(v: plan_mod.Value) ?Decimal {
    return switch (v) {
        .decimal_val => |d| d,
        .int_val => |n| intToDecimal(n),
        else => null,
    };
}

fn evalBinaryArith(op: ast.BinOp, lv: plan_mod.Value, rv: plan_mod.Value) SqlExecError!plan_mod.Value {
    assert(op == .add or op == .sub or op == .mul or op == .div or op == .mod);
    return switch (op) {
        .add => switch (lv) {
            .int_val => |a| switch (rv) { .int_val => |b| .{ .int_val = a + b }, else => decimalArith: {
                const ld = toDecimal(lv) orelse break :decimalArith error.TypeMismatch;
                const rd = toDecimal(rv) orelse break :decimalArith error.TypeMismatch;
                break :decimalArith .{ .decimal_val = decimalAdd(ld, rd) };
            }},
            .float_val => |a| switch (rv) { .float_val => |b| .{ .float_val = a + b }, else => error.TypeMismatch },
            .decimal_val => |a| switch (rv) {
                .decimal_val => |b| .{ .decimal_val = decimalAdd(a, b) },
                .int_val => |b| .{ .decimal_val = decimalAdd(a, intToDecimal(b)) },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        },
        .sub => switch (lv) {
            .int_val => |a| switch (rv) { .int_val => |b| .{ .int_val = a - b }, else => decimalArith: {
                const ld = toDecimal(lv) orelse break :decimalArith error.TypeMismatch;
                const rd = toDecimal(rv) orelse break :decimalArith error.TypeMismatch;
                break :decimalArith .{ .decimal_val = decimalSub(ld, rd) };
            }},
            .float_val => |a| switch (rv) { .float_val => |b| .{ .float_val = a - b }, else => error.TypeMismatch },
            .decimal_val => |a| switch (rv) {
                .decimal_val => |b| .{ .decimal_val = decimalSub(a, b) },
                .int_val => |b| .{ .decimal_val = decimalSub(a, intToDecimal(b)) },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        },
        .mul => switch (lv) {
            .int_val => |a| switch (rv) { .int_val => |b| .{ .int_val = a * b }, else => decimalArith: {
                const ld = toDecimal(lv) orelse break :decimalArith error.TypeMismatch;
                const rd = toDecimal(rv) orelse break :decimalArith error.TypeMismatch;
                break :decimalArith .{ .decimal_val = decimalMul(ld, rd) };
            }},
            .float_val => |a| switch (rv) { .float_val => |b| .{ .float_val = a * b }, else => error.TypeMismatch },
            .decimal_val => |a| switch (rv) {
                .decimal_val => |b| .{ .decimal_val = decimalMul(a, b) },
                .int_val => |b| .{ .decimal_val = decimalMul(a, intToDecimal(b)) },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        },
        .div => switch (lv) {
            .int_val => |a| switch (rv) {
                .int_val => |b| if (b == 0) error.DivisionByZero else .{ .int_val = @divTrunc(a, b) },
                .decimal_val => .{ .decimal_val = try decimalDiv(intToDecimal(a), rv.decimal_val) },
                else => error.TypeMismatch,
            },
            .float_val => |a| switch (rv) { .float_val => |b| .{ .float_val = a / b }, else => error.TypeMismatch },
            .decimal_val => |a| switch (rv) {
                .decimal_val => |b| .{ .decimal_val = try decimalDiv(a, b) },
                .int_val => |b| .{ .decimal_val = try decimalDiv(a, intToDecimal(b)) },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        },
        .mod => switch (lv) {
            .int_val => |a| switch (rv) {
                .int_val => |b| if (b == 0) error.DivisionByZero else .{ .int_val = @rem(a, b) },
                else => error.TypeMismatch,
            },
            .decimal_val => |a| switch (rv) {
                .decimal_val => |b| .{ .decimal_val = try decimalMod(a, b) },
                .int_val => |b| .{ .decimal_val = try decimalMod(a, intToDecimal(b)) },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        },
        else => unreachable,
    };
}

fn evalBinaryBitwise(op: ast.BinOp, lv: plan_mod.Value, rv: plan_mod.Value) SqlExecError!plan_mod.Value {
    assert(op == .bit_and or op == .bit_or or op == .bit_xor or op == .shl or op == .shr);
    return switch (op) {
        .bit_and => switch (lv) {
            .int_val => |a| switch (rv) { .int_val => |b| .{ .int_val = a & b }, else => error.TypeMismatch },
            else => error.TypeMismatch,
        },
        .bit_or => switch (lv) {
            .int_val => |a| switch (rv) { .int_val => |b| .{ .int_val = a | b }, else => error.TypeMismatch },
            else => error.TypeMismatch,
        },
        .bit_xor => switch (lv) {
            .int_val => |a| switch (rv) { .int_val => |b| .{ .int_val = a ^ b }, else => error.TypeMismatch },
            else => error.TypeMismatch,
        },
        .shl => switch (lv) {
            .int_val => |a| switch (rv) {
                .int_val => |b| .{ .int_val = a << @as(u6, @truncate(@as(u64, @bitCast(b)))) },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        },
        .shr => switch (lv) {
            .int_val => |a| switch (rv) {
                .int_val => |b| .{ .int_val = a >> @as(u6, @truncate(@as(u64, @bitCast(b)))) },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        },
        else => unreachable,
    };
}

fn evalBinaryJson(op: ast.BinOp, lv: plan_mod.Value, rv: plan_mod.Value, alloc: std.mem.Allocator) plan_mod.Value {
    assert(op == .contains or op == .contained);
    const ls = switch (lv) {
        .bytes_val => |b| b,
        .string_val => |s| s,
        else => return .null_val,
    };
    const rs = switch (rv) {
        .bytes_val => |b| b,
        .string_val => |s| s,
        else => return .null_val,
    };
    return switch (op) {
        .contains => .{ .bool_val = jsonContains(ls, rs, alloc) },
        .contained => .{ .bool_val = jsonContains(rs, ls, alloc) },
        else => unreachable,
    };
}

fn evalBinaryJsonAccess(lv: plan_mod.Value, rv: plan_mod.Value, as_text: bool, alloc: std.mem.Allocator) plan_mod.Value {
    const json = switch (lv) {
        .bytes_val => |b| b,
        .string_val => |s| s,
        else => return .null_val,
    };
    return jsonFieldAccess(json, rv, as_text, alloc);
}

fn jsonFieldAccess(json_bytes: []const u8, key: plan_mod.Value, as_text: bool, alloc: std.mem.Allocator) plan_mod.Value {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{}) catch return .null_val;
    defer parsed.deinit();

    const field: std.json.Value = switch (key) {
        .string_val => |k| switch (parsed.value) {
            .object => |obj| obj.get(k) orelse return .null_val,
            else => return .null_val,
        },
        .int_val => |idx| switch (parsed.value) {
            .array => |arr| blk: {
                if (idx < 0 or @as(usize, @intCast(idx)) >= arr.items.len) return .null_val;
                break :blk arr.items[@as(usize, @intCast(idx))];
            },
            else => return .null_val,
        },
        else => return .null_val,
    };

    if (as_text) {
        return switch (field) {
            .null => .null_val,
            .bool => |b| .{ .string_val = if (b) "true" else "false" },
            .integer => |n| .{ .string_val = std.fmt.allocPrint(alloc, "{d}", .{n}) catch return .null_val },
            .float => |f| .{ .string_val = std.fmt.allocPrint(alloc, "{d}", .{f}) catch return .null_val },
            .number_string => |s| .{ .string_val = alloc.dupe(u8, s) catch return .null_val },
            .string => |s| .{ .string_val = alloc.dupe(u8, s) catch return .null_val },
            else => blk: {
                const s = std.json.Stringify.valueAlloc(alloc, field, .{}) catch return .null_val;
                break :blk .{ .string_val = s };
            },
        };
    } else {
        const b = std.json.Stringify.valueAlloc(alloc, field, .{}) catch return .null_val;
        return .{ .bytes_val = b };
    }
}

fn jsonContains(left: []const u8, right: []const u8, alloc: std.mem.Allocator) bool {
    var lp = std.json.parseFromSlice(std.json.Value, alloc, left, .{}) catch return false;
    defer lp.deinit();
    var rp = std.json.parseFromSlice(std.json.Value, alloc, right, .{}) catch return false;
    defer rp.deinit();
    return jsonValueContains(lp.value, rp.value);
}

fn jsonValueContains(left: std.json.Value, right: std.json.Value) bool {
    return switch (right) {
        .object => |ro| {
            const lo = switch (left) {
                .object => |o| o,
                else => return false,
            };
            var it = ro.iterator();
            while (it.next()) |entry| {
                const lv = lo.get(entry.key_ptr.*) orelse return false;
                if (!jsonValueContains(lv, entry.value_ptr.*)) return false;
            }
            return true;
        },
        .array => |ra| {
            const la = switch (left) {
                .array => |a| a,
                else => return false,
            };
            for (ra.items) |rv| {
                var found = false;
                for (la.items) |lv| {
                    if (jsonValueContains(lv, rv)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
            return true;
        },
        .null => left == .null,
        .bool => |b| switch (left) {
            .bool => |lb| lb == b,
            else => false,
        },
        .integer => |n| switch (left) {
            .integer => |ln| ln == n,
            else => false,
        },
        .float => |f| switch (left) {
            .float => |lf| lf == f,
            else => false,
        },
        .string => |s| switch (left) {
            .string => |ls| std.mem.eql(u8, ls, s),
            else => false,
        },
        .number_string => |s| switch (left) {
            .number_string => |ls| std.mem.eql(u8, ls, s),
            else => false,
        },
    };
}

pub fn evalBuiltin(name: []const u8, args: []*plan_mod.PlanExpr, ctx: EvalCtx) SqlExecError!plan_mod.Value {
    assert(name.len > 0);
    if (try evalBuiltinPredicate(name, args, ctx)) |v| return v;
    if (try evalBuiltinString(name, args, ctx)) |v| return v;
    if (try evalBuiltinMath(name, args, ctx)) |v| return v;
    // Unknown functions return null (user WASM functions handled separately).
    return .null_val;
}

fn evalBuiltinPredicate(name: []const u8, args: []*plan_mod.PlanExpr, ctx: EvalCtx) SqlExecError!?plan_mod.Value {
    if (std.ascii.eqlIgnoreCase(name, "in_list")) {
        if (args.len < 1) return .{ .bool_val = false };
        const needle = try evalExpr(args[0], ctx);
        for (args[1..]) |a| {
            if (needle.eql(try evalExpr(a, ctx))) return .{ .bool_val = true };
        }
        return .{ .bool_val = false };
    }
    if (std.ascii.eqlIgnoreCase(name, "not_in_list")) {
        if (args.len < 1) return .{ .bool_val = true };
        const needle = try evalExpr(args[0], ctx);
        for (args[1..]) |a| {
            if (needle.eql(try evalExpr(a, ctx))) return .{ .bool_val = false };
        }
        return .{ .bool_val = true };
    }
    if (std.ascii.eqlIgnoreCase(name, "like")) {
        if (args.len != 2) return error.TypeMismatch;
        const s = (try evalExpr(args[0], ctx)).string_val;
        const pat = (try evalExpr(args[1], ctx)).string_val;
        return .{ .bool_val = likeMatch(s, pat) };
    }
    if (std.ascii.eqlIgnoreCase(name, "coalesce")) {
        for (args) |a| {
            const v = try evalExpr(a, ctx);
            if (v != .null_val) return v;
        }
        return .null_val;
    }
    if (std.ascii.eqlIgnoreCase(name, "nullif")) {
        if (args.len != 2) return error.TypeMismatch;
        const a = try evalExpr(args[0], ctx);
        const b = try evalExpr(args[1], ctx);
        return if (a.eql(b)) .null_val else a;
    }
    return null;
}

fn evalBuiltinString(name: []const u8, args: []*plan_mod.PlanExpr, ctx: EvalCtx) SqlExecError!?plan_mod.Value {
    if (std.ascii.eqlIgnoreCase(name, "length") or std.ascii.eqlIgnoreCase(name, "char_length")) {
        if (args.len != 1) return error.TypeMismatch;
        return switch (try evalExpr(args[0], ctx)) {
            .string_val => |s| .{ .int_val = @intCast(s.len) },
            .bytes_val => |b| .{ .int_val = @intCast(b.len) },
            else => error.TypeMismatch,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "lower")) {
        if (args.len != 1) return error.TypeMismatch;
        const s = (try evalExpr(args[0], ctx)).string_val;
        const out = try ctx.alloc.dupe(u8, s);
        for (out) |*c| c.* = std.ascii.toLower(c.*);
        return .{ .string_val = out };
    }
    if (std.ascii.eqlIgnoreCase(name, "upper")) {
        if (args.len != 1) return error.TypeMismatch;
        const s = (try evalExpr(args[0], ctx)).string_val;
        const out = try ctx.alloc.dupe(u8, s);
        for (out) |*c| c.* = std.ascii.toUpper(c.*);
        return .{ .string_val = out };
    }
    if (std.ascii.eqlIgnoreCase(name, "trim")) {
        if (args.len != 1) return error.TypeMismatch;
        return .{ .string_val = std.mem.trim(u8, (try evalExpr(args[0], ctx)).string_val, " \t\n\r") };
    }
    if (std.ascii.eqlIgnoreCase(name, "ltrim")) {
        if (args.len != 1) return error.TypeMismatch;
        const s = (try evalExpr(args[0], ctx)).string_val;
        var i: usize = 0;
        while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) i += 1;
        return .{ .string_val = s[i..] };
    }
    if (std.ascii.eqlIgnoreCase(name, "rtrim")) {
        if (args.len != 1) return error.TypeMismatch;
        const s = (try evalExpr(args[0], ctx)).string_val;
        var i: usize = s.len;
        while (i > 0 and (s[i - 1] == ' ' or s[i - 1] == '\t' or s[i - 1] == '\n' or s[i - 1] == '\r')) i -= 1;
        return .{ .string_val = s[0..i] };
    }
    if (std.ascii.eqlIgnoreCase(name, "substr") or std.ascii.eqlIgnoreCase(name, "substring")) {
        if (args.len < 2) return error.TypeMismatch;
        const s = (try evalExpr(args[0], ctx)).string_val;
        const start_v = try evalExpr(args[1], ctx);
        const start: usize = if (start_v == .int_val) @intCast(@max(0, start_v.int_val - 1)) else 0;
        if (args.len >= 3) {
            const len_v = try evalExpr(args[2], ctx);
            const len: usize = if (len_v == .int_val) @intCast(@max(0, len_v.int_val)) else 0;
            if (start >= s.len) return .{ .string_val = "" };
            return .{ .string_val = s[start..@min(start + len, s.len)] };
        }
        if (start >= s.len) return .{ .string_val = "" };
        return .{ .string_val = s[start..] };
    }
    if (std.ascii.eqlIgnoreCase(name, "replace")) {
        if (args.len != 3) return error.TypeMismatch;
        const s = (try evalExpr(args[0], ctx)).string_val;
        const from = (try evalExpr(args[1], ctx)).string_val;
        const to = (try evalExpr(args[2], ctx)).string_val;
        if (from.len == 0) return .{ .string_val = s };
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < s.len) {
            if (i + from.len <= s.len and std.mem.eql(u8, s[i .. i + from.len], from)) {
                try buf.appendSlice(ctx.alloc, to);
                i += from.len;
            } else {
                try buf.append(ctx.alloc, s[i]);
                i += 1;
            }
        }
        return .{ .string_val = try buf.toOwnedSlice(ctx.alloc) };
    }
    if (std.ascii.eqlIgnoreCase(name, "concat")) {
        var result: std.ArrayList(u8) = .empty;
        for (args) |a| {
            switch (try evalExpr(a, ctx)) {
                .string_val => |s| try result.appendSlice(ctx.alloc, s),
                .int_val => |n| {
                    const s = try std.fmt.allocPrint(ctx.alloc, "{d}", .{n});
                    defer ctx.alloc.free(s);
                    try result.appendSlice(ctx.alloc, s);
                },
                .float_val => |f| {
                    const s = try std.fmt.allocPrint(ctx.alloc, "{d}", .{f});
                    defer ctx.alloc.free(s);
                    try result.appendSlice(ctx.alloc, s);
                },
                else => {},
            }
        }
        return .{ .string_val = try result.toOwnedSlice(ctx.alloc) };
    }
    return null;
}

fn evalBuiltinMath(name: []const u8, args: []*plan_mod.PlanExpr, ctx: EvalCtx) SqlExecError!?plan_mod.Value {
    if (std.ascii.eqlIgnoreCase(name, "greatest")) {
        if (args.len == 0) return .null_val;
        var best = try evalExpr(args[0], ctx);
        for (args[1..]) |a| {
            const v = try evalExpr(a, ctx);
            if (v != .null_val and best.lessThan(v)) best = v;
        }
        return best;
    }
    if (std.ascii.eqlIgnoreCase(name, "least")) {
        if (args.len == 0) return .null_val;
        var best = try evalExpr(args[0], ctx);
        for (args[1..]) |a| {
            const v = try evalExpr(a, ctx);
            if (v != .null_val and v.lessThan(best)) best = v;
        }
        return best;
    }
    if (std.ascii.eqlIgnoreCase(name, "abs")) {
        if (args.len != 1) return error.TypeMismatch;
        return switch (try evalExpr(args[0], ctx)) {
            .int_val => |n| .{ .int_val = if (n < 0) -n else n },
            .float_val => |f| .{ .float_val = @abs(f) },
            else => error.TypeMismatch,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "floor")) {
        if (args.len != 1) return error.TypeMismatch;
        return switch (try evalExpr(args[0], ctx)) {
            .float_val => |f| .{ .float_val = @floor(f) },
            .int_val => |v| .{ .int_val = v },
            else => error.TypeMismatch,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "ceil") or std.ascii.eqlIgnoreCase(name, "ceiling")) {
        if (args.len != 1) return error.TypeMismatch;
        return switch (try evalExpr(args[0], ctx)) {
            .float_val => |f| .{ .float_val = @ceil(f) },
            .int_val => |v| .{ .int_val = v },
            else => error.TypeMismatch,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "round")) {
        if (args.len < 1) return error.TypeMismatch;
        return switch (try evalExpr(args[0], ctx)) {
            .float_val => |f| .{ .float_val = @round(f) },
            .int_val => |v| .{ .int_val = v },
            else => error.TypeMismatch,
        };
    }
    return null;
}

fn likeMatch(s: []const u8, pattern: []const u8) bool {
    var si: usize = 0;
    var pi: usize = 0;
    var star_pi: usize = std.math.maxInt(usize);
    var star_si: usize = 0;

    while (si < s.len) {
        if (pi < pattern.len and (pattern[pi] == '_' or pattern[pi] == s[si])) {
            si += 1;
            pi += 1;
        } else if (pi < pattern.len and pattern[pi] == '%') {
            star_pi = pi;
            star_si = si;
            pi += 1;
        } else if (star_pi != std.math.maxInt(usize)) {
            star_si += 1;
            si = star_si;
            pi = star_pi + 1;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '%') pi += 1;
    return pi == pattern.len;
}
