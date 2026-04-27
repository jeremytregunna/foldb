const std = @import("std");
const testing = std.testing;
const exchange_bus = @import("exchange_bus.zig");

const ExchangeBus = exchange_bus.ExchangeBus;
const ExchangeMsg = exchange_bus.ExchangeMsg;
const ForeignRead = exchange_bus.ForeignRead;

test "SpscQueue: push and pop on same thread" {
    var q: exchange_bus.MsgQueue = .{};
    try testing.expect(q.isEmpty());

    const msg = ExchangeMsg{ .request = .{
        .seq = 42,
        .from = 0,
        .to = 1,
        .reads = &.{},
    } };

    try testing.expect(q.push(msg));
    try testing.expect(!q.isEmpty());

    const got = q.pop();
    try testing.expect(got != null);
    try testing.expectEqual(@as(u64, 42), got.?.request.seq);
    try testing.expect(q.isEmpty());
}

test "SpscQueue: full queue returns false on push" {
    var q: exchange_bus.SpscQueue(ExchangeMsg, 4) = .{};
    const msg = ExchangeMsg{ .response = .{
        .seq = 1,
        .from = 1,
        .to = 0,
        .rows = &.{},
    } };

    try testing.expect(q.push(msg));
    try testing.expect(q.push(msg));
    try testing.expect(q.push(msg));
    try testing.expect(q.push(msg));
    // 5th push must fail — queue is full
    try testing.expect(!q.push(msg));

    // drain
    _ = q.pop();
    // now there's room
    try testing.expect(q.push(msg));
}

test "ExchangeBus: two-thread request-response round-trip" {
    var bus = try ExchangeBus.init(2, testing.allocator);
    defer bus.deinit();

    const reads = [_]ForeignRead{
        .{ .table_id = 7, .key = "pk1" },
    };

    // Producer thread: executor 0 sends request to executor 1, waits for response.
    const Producer = struct {
        fn run(b: *ExchangeBus, r: []const ForeignRead) !void {
            const req = ExchangeMsg{ .request = .{
                .seq = 100,
                .from = 0,
                .to = 1,
                .reads = r,
            } };
            // Spin until push succeeds (bus shouldn't be full in this test).
            while (!b.push(0, 1, req)) std.Thread.yield() catch {};

            // Wait for response from executor 1.
            while (true) {
                if (b.pop(1, 0)) |msg| {
                    try testing.expectEqual(@as(u64, 100), msg.response.seq);
                    try testing.expectEqual(@as(u32, 1), msg.response.from);
                    try testing.expectEqual(@as(u32, 0), msg.response.to);
                    break;
                }
                std.Thread.yield() catch {};
            }
        }
    };

    // Consumer thread: executor 1 receives request from executor 0, sends response back.
    const Consumer = struct {
        fn run(b: *ExchangeBus) !void {
            // Wait for a request from executor 0.
            while (true) {
                if (b.pop(0, 1)) |msg| {
                    try testing.expectEqual(@as(u64, 100), msg.request.seq);
                    try testing.expectEqual(@as(u32, 0), msg.request.from);
                    try testing.expectEqual(@as(u32, 1), msg.request.to);
                    try testing.expectEqual(@as(usize, 1), msg.request.reads.len);
                    break;
                }
                std.Thread.yield() catch {};
            }

            // Send response back to executor 0.
            const resp = ExchangeMsg{ .response = .{
                .seq = 100,
                .from = 1,
                .to = 0,
                .rows = &.{},
            } };
            while (!b.push(1, 0, resp)) std.Thread.yield() catch {};
        }
    };

    const producer = try std.Thread.spawn(.{}, Producer.run, .{ &bus, &reads });
    const consumer = try std.Thread.spawn(.{}, Consumer.run, .{&bus});
    producer.join();
    consumer.join();
}

test "ExchangeBus: N=1 (single partition) has no cross-partition channels" {
    var bus = try ExchangeBus.init(1, testing.allocator);
    defer bus.deinit();
    // With 1 partition there are no valid (from, to) pairs where from != to.
    // Verify the bus was created without panicking.
    try testing.expectEqual(@as(u32, 1), bus.partition_count);
}
