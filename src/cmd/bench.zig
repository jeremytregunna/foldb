const std = @import("std");
const gateway_mod = @import("gateway.zig");
const messages = @import("messages.zig");

const Gateway = gateway_mod.Gateway;

const Options = struct {
    ops: usize = 10_000,
    value_size: usize = 64,
    concurrency: usize = 1,
    batch_size: usize = 1,
    storage_dir: ?[]const u8 = null,
};

const SetWorkerArgs = struct {
    gw: *Gateway,
    value: []const u8,
    start: usize,
    end: usize,
    batch_size: usize,
    failed: std.atomic.Value(bool) = .init(false),
    err: anyerror = error.BenchmarkWorkerFailed,
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    const opts = try parseArgs(init.minimal.args);
    const generated_dir = if (opts.storage_dir == null) try makeTempDir(alloc) else null;
    defer if (generated_dir) |dir| {
        removeTree(dir);
        alloc.free(dir);
    };
    const storage_dir = opts.storage_dir orelse generated_dir.?;

    const value = try alloc.alloc(u8, opts.value_size);
    defer alloc.free(value);
    @memset(value, 'x');

    const gw = try Gateway.init(storage_dir, alloc, .{ .partition_count = 1, .log_partition_count = 4 });
    defer gw.deinit();

    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();

    const start = nowNanos();
    try runSetBenchmark(alloc, gw, value, opts.ops, opts.concurrency, opts.batch_size);
    const set_elapsed = nowNanos() - start;

    const catchup_start = nowNanos();
    try gw.waitCaughtUp();
    const catchup_elapsed = nowNanos() - catchup_start;

    const read_start = nowNanos();
    for (0..opts.ops) |i| {
        var key_buf: [64]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "bench:{d}", .{i});
        try gateway_mod.handleGet(&writer.writer, alloc, @intCast(opts.ops + i + 1), .{
            .key = key,
            .at_seq = std.math.maxInt(u64),
        }, gw);
        writer.clearRetainingCapacity();
    }
    const get_elapsed = nowNanos() - read_start;

    std.log.info("foldb KV benchmark", .{});
    std.log.info("ops={d} value_size={d} concurrency={d} batch_size={d} storage_dir={s}", .{
        opts.ops,
        opts.value_size,
        opts.concurrency,
        opts.batch_size,
        storage_dir,
    });
    report("set", opts.ops, set_elapsed);
    report("catch-up", opts.ops, catchup_elapsed);
    report("get", opts.ops, get_elapsed);
}

fn runSetBenchmark(
    alloc: std.mem.Allocator,
    gw: *Gateway,
    value: []const u8,
    ops: usize,
    concurrency: usize,
    batch_size: usize,
) !void {
    if (concurrency <= 1) {
        var args = SetWorkerArgs{ .gw = gw, .value = value, .start = 0, .end = ops, .batch_size = batch_size };
        try setWorkerFallible(&args);
        return;
    }

    const worker_count = @min(concurrency, ops);
    const threads = try alloc.alloc(std.Thread, worker_count);
    defer alloc.free(threads);
    const args = try alloc.alloc(SetWorkerArgs, worker_count);
    defer alloc.free(args);

    var next: usize = 0;
    for (0..worker_count) |i| {
        const remaining = ops - next;
        const remaining_workers = worker_count - i;
        const take = (remaining + remaining_workers - 1) / remaining_workers;
        args[i] = .{
            .gw = gw,
            .value = value,
            .start = next,
            .end = next + take,
            .batch_size = batch_size,
        };
        next += take;
        threads[i] = try std.Thread.spawn(.{}, setWorker, .{&args[i]});
    }

    for (threads) |thread| thread.join();
    for (args) |arg| {
        if (arg.failed.load(.acquire)) return arg.err;
    }
}

fn setWorker(args: *SetWorkerArgs) void {
    setWorkerFallible(args) catch |err| {
        args.err = err;
        args.failed.store(true, .release);
    };
}

fn setWorkerFallible(args: *SetWorkerArgs) !void {
    const alloc = std.heap.smp_allocator;
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();

    var i = args.start;
    while (i < args.end) {
        const remaining = args.end - i;
        const n = @min(args.batch_size, remaining);
        if (n <= 1) {
            var key_buf: [64]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "bench:{d}", .{i});
            try gateway_mod.handleSet(&writer.writer, alloc, @intCast(i + 1), .{ .key = key, .value = args.value }, args.gw);
            writer.clearRetainingCapacity();
            i += 1;
            continue;
        }

        const ops = try alloc.alloc(messages.BatchOp, n);
        defer alloc.free(ops);
        const keys = try alloc.alloc([]u8, n);
        defer alloc.free(keys);
        for (0..n) |j| {
            keys[j] = try std.fmt.allocPrint(alloc, "bench:{d}", .{i + j});
            ops[j] = .{ .set = .{ .key = keys[j], .value = args.value } };
        }
        defer for (keys) |key| alloc.free(key);

        try gateway_mod.handleBatch(&writer.writer, alloc, @intCast(i + 1), ops, args.gw);
        writer.clearRetainingCapacity();
        i += n;
    }
}

fn parseArgs(args: std.process.Args) !Options {
    var opts = Options{};
    var it = std.process.Args.Iterator.init(args);
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ops")) {
            opts.ops = try std.fmt.parseUnsigned(usize, it.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--value-size")) {
            opts.value_size = try std.fmt.parseUnsigned(usize, it.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--concurrency")) {
            opts.concurrency = try std.fmt.parseUnsigned(usize, it.next() orelse return error.MissingArgument, 10);
            if (opts.concurrency == 0) return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--batch-size")) {
            opts.batch_size = try std.fmt.parseUnsigned(usize, it.next() orelse return error.MissingArgument, 10);
            if (opts.batch_size == 0) return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--storage-dir")) {
            opts.storage_dir = it.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.log.info(
                "Usage: foldb-bench [--ops N] [--value-size N] [--concurrency N] [--batch-size N] [--storage-dir PATH]",
                .{},
            );
            std.process.exit(0);
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }
    return opts;
}

fn report(name: []const u8, ops: usize, elapsed_ns: u64) void {
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const ops_s = @as(f64, @floatFromInt(ops)) / elapsed_s;
    const avg_us = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ops)) / 1000.0;
    std.log.info("{s}: {d:.2} ops/s, avg {d:.2} us/op", .{ name, ops_s, avg_us });
}

fn nowNanos() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn makeTempDir(alloc: std.mem.Allocator) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "/tmp/foldb_bench_{d}", .{nowNanos()});
    const z = try alloc.allocSentinel(u8, path.len, 0);
    defer alloc.free(z);
    @memcpy(z[0..path.len], path);
    _ = std.os.linux.mkdir(z.ptr, 0o755);
    return path;
}

fn removeTree(path: []const u8) void {
    const z = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(z);
    @memcpy(z[0..path.len], path);
    const raw_fd = std.os.linux.open(z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return;
    const fd: std.posix.fd_t = @intCast(fd_i);
    defer _ = std.os.linux.close(@intCast(fd));
    var buf: [4096]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    while (true) {
        const ret = std.os.linux.getdents64(@intCast(fd), &buf, buf.len);
        const n: isize = @bitCast(ret);
        if (n <= 0) break;
        var i: usize = 0;
        while (i < @as(usize, @intCast(n))) {
            const dent: *const std.os.linux.dirent64 = @ptrCast(@alignCast(buf[i..].ptr));
            const entry_name = std.mem.span(@as([*:0]const u8, @ptrCast(&dent.name)));
            if (!std.mem.eql(u8, entry_name, ".") and !std.mem.eql(u8, entry_name, "..")) {
                const child = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ path, entry_name }) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(child);
                const child_z = std.heap.page_allocator.allocSentinel(u8, child.len, 0) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(child_z);
                @memcpy(child_z[0..child.len], child);
                if (dent.type == std.os.linux.DT.DIR) {
                    removeTree(child);
                } else {
                    _ = std.os.linux.unlink(child_z.ptr);
                }
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}
