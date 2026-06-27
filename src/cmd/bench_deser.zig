const std = @import("std");
const log_mod = @import("log.zig");

const KvOp = log_mod.KvOp;
const TxnIntent = log_mod.TxnIntent;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var iterations: usize = 1_000_000;
    var value_size: usize = 64;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--iters")) {
            iterations = try std.fmt.parseUnsigned(usize, it.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--value-size")) {
            value_size = try std.fmt.parseUnsigned(usize, it.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.log.info("Usage: foldb-bench-deser [--iters N] [--value-size N]", .{});
            std.process.exit(0);
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }

    const value = try alloc.alloc(u8, value_size);
    defer alloc.free(value);
    @memset(value, 'v');

    var ops = [_]KvOp{.{ .set = .{ .key = "bench-key", .value = value, .expected_seq = 0 } }};
    const payload = try TxnIntent.init(&ops, &.{}, &.{1}, 1, 1).serialize_to(alloc);
    defer alloc.free(payload);

    const start = nowNanos();
    for (0..iterations) |_| {
        var intent = try TxnIntent.deserialize_from(payload, alloc);
        intent.deinit(alloc);
    }
    const elapsed = nowNanos() - start;
    const elapsed_s = @as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0;
    const ops_s = @as(f64, @floatFromInt(iterations)) / elapsed_s;
    const avg_ns = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));

    std.log.info("foldb TxnIntent deserialize benchmark", .{});
    std.log.info("iters={d} payload_bytes={d}", .{ iterations, payload.len });
    std.log.info("deserialize: {d:.2} ops/s, avg {d:.2} ns/op", .{ ops_s, avg_ns });
}

fn nowNanos() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
