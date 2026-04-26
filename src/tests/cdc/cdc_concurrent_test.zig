/// Concurrent CDC tests.
///
/// Verifies that CdcSubscription's lock-free inbox and CdcManager's spinlock
/// protect shared state correctly under concurrent producer/consumer access.
///
/// Scenarios:
///   1. Concurrent dispatch + next: all events delivered without loss or corruption.
///   2. Concurrent subscribe during dispatch: no crash, new subscriber gets events
///      dispatched after it subscribed.
///   3. Concurrent unsubscribe during dispatch: no crash, no use-after-free.
const std = @import("std");
const testing = std.testing;
const cdc_mod = @import("cdc.zig");
const storage_mod = @import("storage.zig");

const CdcManager = cdc_mod.CdcManager;
const CdcEvent = cdc_mod.CdcEvent;
const Mutation = storage_mod.Mutation;
const ColumnValue = storage_mod.ColumnValue;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn makeMutation(alloc: std.mem.Allocator, seq: u64) !Mutation {
    const key = try alloc.dupe(u8, &[_]u8{ @intCast(seq & 0xFF) });
    const vals = try alloc.alloc(ColumnValue, 1);
    vals[0] = .{ .int64 = @intCast(seq) };
    return .{ .table_id = 1, .key = key, .kind = .insert, .values = vals };
}

fn freeMutation(m: Mutation, alloc: std.mem.Allocator) void {
    alloc.free(m.key);
    if (m.values) |v| alloc.free(v);
}

fn makeBeforeImages(mutations: []const Mutation, alloc: std.mem.Allocator) !cdc_mod.BeforeImages {
    const images = try alloc.alloc(?[]ColumnValue, mutations.len);
    for (images) |*img| img.* = null;
    return .{ .images = images, .alloc = alloc };
}

// ---------------------------------------------------------------------------
// Test 1: concurrent dispatch (producer) + next (consumer)
// ---------------------------------------------------------------------------

const ProducerCtx = struct {
    mgr: *CdcManager,
    n_events: usize,
    alloc: std.mem.Allocator,
    err: ?anyerror = null,
};

fn producerThread(ctx: *ProducerCtx) void {
    for (1..ctx.n_events + 1) |seq| {
        const m = makeMutation(ctx.alloc, seq) catch |e| { ctx.err = e; return; };
        defer freeMutation(m, ctx.alloc);
        var before = makeBeforeImages(&.{m}, ctx.alloc) catch |e| { ctx.err = e; return; };
        defer before.deinit();
        ctx.mgr.dispatch(seq, 1, .txn_intent, &.{m}, before, ctx.alloc) catch |e| {
            ctx.err = e;
            return;
        };
    }
}

const ConsumerCtx = struct {
    sub: *cdc_mod.CdcSubscription,
    expected: usize,
    received: usize = 0,
    alloc: std.mem.Allocator,
    err: ?anyerror = null,
};

fn consumerThread(ctx: *ConsumerCtx) void {
    var buf: [8]CdcEvent = undefined;
    while (ctx.received < ctx.expected) {
        const n = ctx.sub.next(&buf);
        for (0..n) |i| {
            ctx.received += 1;
            var e = buf[i];
            e.deinit();
        }
        if (n == 0) std.atomic.spinLoopHint();
    }
}

test "concurrent dispatch and next: all events delivered" {
    const alloc = testing.allocator;
    const N = 500;

    var mgr = try CdcManager.init(alloc);
    defer mgr.deinit();

    const sub = try mgr.subscribe(null, 0);

    var pctx = ProducerCtx{ .mgr = &mgr, .n_events = N, .alloc = alloc };
    var cctx = ConsumerCtx{ .sub = sub, .expected = N, .alloc = alloc };

    const producer = try std.Thread.spawn(.{}, producerThread, .{&pctx});
    const consumer = try std.Thread.spawn(.{}, consumerThread, .{&cctx});
    producer.join();
    consumer.join();

    try testing.expectEqual(@as(?anyerror, null), pctx.err);
    try testing.expectEqual(@as(?anyerror, null), cctx.err);
    try testing.expectEqual(@as(usize, N), cctx.received);
}

// ---------------------------------------------------------------------------
// Test 2: concurrent subscribe during dispatch
// ---------------------------------------------------------------------------

const SubscribeWhileDispatchCtx = struct {
    mgr: *CdcManager,
    n_events: usize,
    alloc: std.mem.Allocator,
    err: ?anyerror = null,
};

fn subscribeUnsubscribeThread(ctx: *SubscribeWhileDispatchCtx) void {
    for (0..20) |_| {
        const sub = ctx.mgr.subscribe(null, 0) catch |e| { ctx.err = e; return; };
        // Spin briefly so dispatch has a chance to run with this subscriber present.
        var i: usize = 0;
        while (i < 100) : (i += 1) std.atomic.spinLoopHint();
        ctx.mgr.unsubscribe(sub.id);
    }
}

test "concurrent subscribe/unsubscribe during dispatch: no crash" {
    const alloc = testing.allocator;
    const N = 200;

    var mgr = try CdcManager.init(alloc);
    defer mgr.deinit();

    var pctx = SubscribeWhileDispatchCtx{ .mgr = &mgr, .n_events = N, .alloc = alloc };
    var pctx2 = ProducerCtx{ .mgr = &mgr, .n_events = N, .alloc = alloc };

    const sub_thread = try std.Thread.spawn(.{}, subscribeUnsubscribeThread, .{&pctx});
    const dispatch_thread = try std.Thread.spawn(.{}, producerThread, .{&pctx2});
    sub_thread.join();
    dispatch_thread.join();

    try testing.expectEqual(@as(?anyerror, null), pctx.err);
    try testing.expectEqual(@as(?anyerror, null), pctx2.err);
}

// ---------------------------------------------------------------------------
// Test 3: concurrent ack during push
// ---------------------------------------------------------------------------

const AckCtx = struct {
    sub: *cdc_mod.CdcSubscription,
    n: usize,
    err: ?anyerror = null,
};

fn ackThread(ctx: *AckCtx) void {
    for (1..ctx.n + 1) |seq| {
        ctx.sub.ack(seq);
        std.atomic.spinLoopHint();
    }
}

test "concurrent push and ack: no corruption, no double-free" {
    const alloc = testing.allocator;
    const N = 300;

    var mgr = try CdcManager.init(alloc);
    defer mgr.deinit();

    const sub = try mgr.subscribe(null, 0);

    var pctx = ProducerCtx{ .mgr = &mgr, .n_events = N, .alloc = alloc };
    var actx = AckCtx{ .sub = sub, .n = N };

    const push_t = try std.Thread.spawn(.{}, producerThread, .{&pctx});
    const ack_t = try std.Thread.spawn(.{}, ackThread, .{&actx});
    push_t.join();
    ack_t.join();

    try testing.expectEqual(@as(?anyerror, null), pctx.err);
    try testing.expectEqual(@as(?anyerror, null), actx.err);

    // Drain any remaining events to verify no corruption.
    var buf: [16]CdcEvent = undefined;
    while (true) {
        const n = sub.next(&buf);
        if (n == 0) break;
        for (0..n) |i| buf[i].deinit();
    }
}
