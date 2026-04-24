/// Determinism property test.
///
/// Invariant: given the same sequence of operations, two independent Gateway
/// instances produce bit-identical state at every checkpoint.
///
/// Runs the same seeded workload through two separate gateways (different
/// storage dirs, same VirtualClock time, same PRNG seed). After all ops,
/// scans both tables and asserts the result sets are identical.
const std = @import("std");
const testing = std.testing;
const sim = @import("sim.zig");
const gateway_mod = @import("gateway.zig");
const wl = sim.workload;

const Gateway = gateway_mod.Gateway;
const ColumnValue = gateway_mod.ColumnValue;
const ClockSource = gateway_mod.ClockSource;
const RandSource = gateway_mod.RandSource;

// ---- VirtualClock → ClockSource adapter ----

fn virtualNowMicros(ptr: ?*anyopaque) i64 {
    const vc: *sim.VirtualClock = @ptrCast(@alignCast(ptr.?));
    return vc.now() * 1_000_000;
}

fn clockSourceFrom(vc: *sim.VirtualClock) ClockSource {
    return .{ .ptr = vc, .now_micros_fn = virtualNowMicros };
}

// ---- SimScheduler → RandSource adapter ----

fn simRandFill(ptr: ?*anyopaque, buf: []u8) void {
    const sched: *sim.SimScheduler = @ptrCast(@alignCast(ptr.?));
    sched.random().bytes(buf);
}

fn randSourceFrom(sched: *sim.SimScheduler) RandSource {
    return .{ .ptr = sched, .fill_fn = simRandFill };
}

// ---- Temp dir helpers ----

fn makeTempDir(tag: []const u8, seed: u64, alloc: std.mem.Allocator) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "/tmp/sim_det_{s}_{d}", .{ tag, seed });
    removeDirRecursive(path);
    const zpath = try alloc.allocSentinel(u8, path.len, 0);
    defer alloc.free(zpath);
    @memcpy(zpath[0..path.len], path);
    _ = std.os.linux.mkdir(zpath.ptr, 0o755);
    return path;
}

fn removeDirRecursive(path: []const u8) void {
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
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&dent.name)));
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                const child = std.mem.concat(std.heap.page_allocator, u8, &.{ path, "/", name }) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(child);
                const cz = std.heap.page_allocator.allocSentinel(u8, child.len, 0) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(cz);
                @memcpy(cz[0..child.len], child);
                if (dent.type == std.os.linux.DT.DIR) removeDirRecursive(child) else _ = std.os.linux.unlink(cz.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}

// ---- Op execution helpers ----

fn applyOp(
    gw: *Gateway,
    op: wl.Op,
    insert_hash: [32]u8,
    update_hash: [32]u8,
    delete_hash: [32]u8,
) !void {
    switch (op.kind) {
        .insert => {
            const params = [_]ColumnValue{ .{ .int64 = op.id }, .{ .int64 = op.value } };
            _ = gw.execute(insert_hash, &params, &.{}) catch {};
        },
        .update => {
            const params = [_]ColumnValue{ .{ .int64 = op.id }, .{ .int64 = op.value } };
            _ = gw.execute(update_hash, &params, &.{}) catch {};
        },
        .delete => {
            const params = [_]ColumnValue{.{ .int64 = op.id }};
            _ = gw.execute(delete_hash, &params, &.{}) catch {};
        },
        .select => {}, // selects don't mutate state; skip for determinism test
    }
}

// ---- Row hashing ----

/// Deterministic hash of a full table scan result. Rows are expected to come
/// back in primary-key order from the LSM; we hash them in order.
fn hashScan(gw: *Gateway, scan_hash: [32]u8, alloc: std.mem.Allocator) ![32]u8 {
    var rs = try gw.querySelect(scan_hash, &.{}, &.{});
    defer rs.deinit();

    var h = std.crypto.hash.Blake3.init(.{});
    // Include row count so empty vs non-empty tables are distinct.
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

// ---- Core test logic ----

fn runDeterminismTest(seed: u64, n_ops: usize, alloc: std.mem.Allocator) !void {
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

    // Shared virtual clock — both nodes see the same logical time.
    var clock = sim.VirtualClock.zero();

    // Independent but same-seed PRNGs — produce identical resolved values.
    var rand_a = sim.SimScheduler.init(seed);
    var rand_b = sim.SimScheduler.init(seed);

    const opts_a = Gateway.Options{
        .clock = clockSourceFrom(&clock),
        .rand = randSourceFrom(&rand_a),
    };
    const opts_b = Gateway.Options{
        .clock = clockSourceFrom(&clock),
        .rand = randSourceFrom(&rand_b),
    };

    const gw_a = try Gateway.init(dir_a, alloc, opts_a);
    defer gw_a.deinit();
    const gw_b = try Gateway.init(dir_b, alloc, opts_b);
    defer gw_b.deinit();

    // DDL
    try gw_a.applyDdl(wl.TABLE_DDL);
    try gw_b.applyDdl(wl.TABLE_DDL);

    // Register statements
    const ins_a = (try gw_a.register(wl.INSERT_SQL)).hash;
    const upd_a = (try gw_a.register(wl.UPDATE_SQL)).hash;
    const del_a = (try gw_a.register(wl.DELETE_SQL)).hash;
    const ins_b = (try gw_b.register(wl.INSERT_SQL)).hash;
    const upd_b = (try gw_b.register(wl.UPDATE_SQL)).hash;
    const del_b = (try gw_b.register(wl.DELETE_SQL)).hash;
    const scan_a = (try gw_a.register(wl.SCAN_SQL)).hash;
    const scan_b = (try gw_b.register(wl.SCAN_SQL)).hash;

    // Generate workload from a separate scheduler (not shared with gateways).
    var wl_sched = sim.SimScheduler.init(seed ^ 0xABCD_EF01);
    var workload = try wl.generate(&wl_sched, n_ops, alloc);
    defer workload.deinit();

    // Drive identical ops through both gateways in lockstep. Advance the
    // virtual clock by 1 second per op so time-based values stay in sync.
    for (workload.ops) |op| {
        try applyOp(gw_a, op, ins_a, upd_a, del_a);
        try applyOp(gw_b, op, ins_b, upd_b, del_b);
        clock.advance(1);
    }

    // Compare final state.
    const hash_a = try hashScan(gw_a, scan_a, alloc);
    const hash_b = try hashScan(gw_b, scan_b, alloc);

    try testing.expectEqualSlices(u8, &hash_a, &hash_b);
}

test "sim: determinism — same workload produces identical state (multi-seed)" {
    const seeds = [_]u64{ 0, 1, 42, 0xDEAD_BEEF, 0xCAFE_BABE };
    for (seeds) |seed| {
        try runDeterminismTest(seed, 200, testing.allocator);
    }
}
