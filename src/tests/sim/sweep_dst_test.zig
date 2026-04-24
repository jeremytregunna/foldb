/// Seed sweep DST.
///
/// Runs the determinism property across 200 seeds with a lightweight 20-op
/// workload. Covers a wide slice of the PRNG space without making the suite
/// slow — 200 × 20 ops is roughly the coverage of the focused 5 × 200-op
/// determinism_test but spread across more distinct code paths.
///
/// Property per seed: two independent Gateway instances driven through the
/// same seeded workload produce bit-identical table scan hashes.
const std = @import("std");
const testing = std.testing;
const sim = @import("sim.zig");
const gateway_mod = @import("gateway.zig");
const wl = sim.workload;

const Gateway = gateway_mod.Gateway;
const ColumnValue = gateway_mod.ColumnValue;
const ClockSource = gateway_mod.ClockSource;
const RandSource = gateway_mod.RandSource;

// ---------------------------------------------------------------------------
// VirtualClock / SimScheduler → Gateway adapter
// ---------------------------------------------------------------------------

fn virtualNowMicros(ptr: ?*anyopaque) i64 {
    const vc: *sim.VirtualClock = @ptrCast(@alignCast(ptr.?));
    return vc.now() * 1_000_000;
}

fn clockSourceFrom(vc: *sim.VirtualClock) ClockSource {
    return .{ .clock_ctx = vc, .now_micros_fn = virtualNowMicros };
}

fn simRandFill(ptr: ?*anyopaque, buf: []u8) void {
    const sched: *sim.SimScheduler = @ptrCast(@alignCast(ptr.?));
    sched.random().bytes(buf);
}

fn randSourceFrom(sched: *sim.SimScheduler) RandSource {
    return .{ .rand_ctx = sched, .fill_fn = simRandFill };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn makeTempDir(tag: []const u8, seed: u64, alloc: std.mem.Allocator) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "/tmp/sweep_dst_{s}_{d}", .{ tag, seed });
    removeDirRecursive(path);
    const zpath = try alloc.allocSentinel(u8, path.len, 0);
    defer alloc.free(zpath);
    @memcpy(zpath[0..path.len], path);
    _ = std.os.linux.mkdir(zpath.ptr, 0o755);
    return path;
}

fn removeDirRecursive(path: []const u8) void {
    const alloc = std.heap.page_allocator;
    const z = alloc.allocSentinel(u8, path.len, 0) catch return;
    defer alloc.free(z);
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
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&dent.name)));
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                const child = std.fmt.allocPrint(alloc, "{s}/{s}", .{ path, name }) catch {
                    i += dent.reclen;
                    continue;
                };
                defer alloc.free(child);
                const cz = alloc.allocSentinel(u8, child.len, 0) catch {
                    i += dent.reclen;
                    continue;
                };
                defer alloc.free(cz);
                @memcpy(cz[0..child.len], child);
                const DT_DIR: u8 = 4;
                if (dent.type == DT_DIR) removeDirRecursive(child) else _ = std.os.linux.unlink(cz.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}

fn applyOp(
    gw: *Gateway,
    op: wl.Op,
    ins: [32]u8,
    upd: [32]u8,
    del: [32]u8,
) !void {
    switch (op.kind) {
        .insert, .update => {
            const hash = if (op.kind == .insert) ins else upd;
            const params = [_]ColumnValue{ .{ .int64 = op.id }, .{ .int64 = op.value } };
            _ = gw.execute(hash, &params, &.{}) catch {};
        },
        .delete => {
            const params = [_]ColumnValue{.{ .int64 = op.id }};
            _ = gw.execute(del, &params, &.{}) catch {};
        },
        .select => {},
    }
}

fn hashScan(gw: *Gateway, scan: [32]u8, alloc: std.mem.Allocator) ![32]u8 {
    var rs = try gw.querySelect(scan, &.{}, &.{});
    defer rs.deinit();
    var h = std.crypto.hash.Blake3.init(.{});
    var count_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &count_buf, rs.rows.len, .little);
    h.update(&count_buf);
    for (rs.rows) |row| {
        for (row) |maybe_cell| {
            if (maybe_cell) |cell| switch (cell) {
                .int64 => |v| {
                    var vb: [8]u8 = undefined;
                    std.mem.writeInt(i64, &vb, v, .little);
                    h.update(&vb);
                },
                else => {
                    var tmp: [64]u8 = undefined;
                    const s = std.fmt.bufPrint(&tmp, "{any}", .{cell}) catch continue;
                    h.update(s);
                },
            } else h.update(&[_]u8{0xFE});
        }
    }
    _ = alloc;
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

// ---------------------------------------------------------------------------
// Core sweep logic
// ---------------------------------------------------------------------------

fn runSweepSeed(seed: u64, n_ops: usize, alloc: std.mem.Allocator) !void {
    const dir_a = try makeTempDir("a", seed, alloc);
    defer {
        removeDirRecursive(dir_a);
        alloc.free(dir_a);
    }
    const dir_b = try makeTempDir("b", seed, alloc);
    defer {
        removeDirRecursive(dir_b);
        alloc.free(dir_b);
    }

    var clock = sim.VirtualClock.zero();
    var rand_a = sim.SimScheduler.init(seed);
    var rand_b = sim.SimScheduler.init(seed);

    const gw_a = try Gateway.init(dir_a, alloc, .{
        .clock = clockSourceFrom(&clock),
        .rand = randSourceFrom(&rand_a),
    });
    defer gw_a.deinit();
    const gw_b = try Gateway.init(dir_b, alloc, .{
        .clock = clockSourceFrom(&clock),
        .rand = randSourceFrom(&rand_b),
    });
    defer gw_b.deinit();

    try gw_a.applyDdl(wl.TABLE_DDL);
    try gw_b.applyDdl(wl.TABLE_DDL);

    const ins_a = (try gw_a.register(wl.INSERT_SQL)).hash;
    const upd_a = (try gw_a.register(wl.UPDATE_SQL)).hash;
    const del_a = (try gw_a.register(wl.DELETE_SQL)).hash;
    const ins_b = (try gw_b.register(wl.INSERT_SQL)).hash;
    const upd_b = (try gw_b.register(wl.UPDATE_SQL)).hash;
    const del_b = (try gw_b.register(wl.DELETE_SQL)).hash;
    const scan_a = (try gw_a.register(wl.SCAN_SQL)).hash;
    const scan_b = (try gw_b.register(wl.SCAN_SQL)).hash;

    var wl_sched = sim.SimScheduler.init(seed ^ 0xABCD_EF01);
    var workload = try wl.generate(&wl_sched, n_ops, alloc);
    defer workload.deinit();

    for (workload.ops) |op| {
        try applyOp(gw_a, op, ins_a, upd_a, del_a);
        try applyOp(gw_b, op, ins_b, upd_b, del_b);
        clock.advance(1);
    }

    const hash_a = try hashScan(gw_a, scan_a, alloc);
    const hash_b = try hashScan(gw_b, scan_b, alloc);
    try testing.expectEqualSlices(u8, &hash_a, &hash_b);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "sweep: determinism across N seeds (20 ops each)" {
    // Seed count set via -Ddst-seeds=N at build time (default: 200).
    // Seeds drawn via golden-ratio stride across u64 space for good coverage.
    const n = @import("options").dst_seeds;
    const STRIDE = 0x9E37_79B9_7F4A_7C15;
    var seed: u64 = 0;
    for (0..n) |_| {
        try runSweepSeed(seed, 20, testing.allocator);
        seed +%= STRIDE;
    }
}
