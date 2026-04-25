const std = @import("std");
const testing = std.testing;
const sequencer = @import("sequencer.zig");

const IdempotencyCache = sequencer.IdempotencyCache;

test "IdempotencyCache: lookup returns null for unknown key" {
    var cache = IdempotencyCache.init(testing.allocator);
    defer cache.deinit();

    try testing.expectEqual(@as(?u64, null), cache.lookup(1, 1));
}

test "IdempotencyCache: record and lookup" {
    var cache = IdempotencyCache.init(testing.allocator);
    defer cache.deinit();

    try cache.record(1, 1, 42);
    try testing.expectEqual(@as(?u64, 42), cache.lookup(1, 1));
}

test "IdempotencyCache: different keys are independent" {
    var cache = IdempotencyCache.init(testing.allocator);
    defer cache.deinit();

    try cache.record(1, 1, 10);
    try cache.record(1, 2, 20);
    try cache.record(2, 1, 30);

    try testing.expectEqual(@as(?u64, 10), cache.lookup(1, 1));
    try testing.expectEqual(@as(?u64, 20), cache.lookup(1, 2));
    try testing.expectEqual(@as(?u64, 30), cache.lookup(2, 1));
    try testing.expectEqual(@as(?u64, null), cache.lookup(3, 1));
}

test "IdempotencyCache: evictBefore removes stale entries" {
    var cache = IdempotencyCache.init(testing.allocator);
    defer cache.deinit();

    try cache.record(1, 1, 5);
    try cache.record(1, 2, 10);
    try cache.record(1, 3, 15);

    try cache.evictBefore(10); // removes seq < 10, so seq=5 evicted

    try testing.expectEqual(@as(?u64, null), cache.lookup(1, 1));
    try testing.expectEqual(@as(?u64, 10), cache.lookup(1, 2));
    try testing.expectEqual(@as(?u64, 15), cache.lookup(1, 3));
}

test "IdempotencyCache: second submit for same key returns same seq" {
    var cache = IdempotencyCache.init(testing.allocator);
    defer cache.deinit();

    try cache.record(7, 3, 99);

    const first = cache.lookup(7, 3);
    const second = cache.lookup(7, 3);
    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(?u64, 99), first);
}
