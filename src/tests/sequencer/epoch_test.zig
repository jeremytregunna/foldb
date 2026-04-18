const std = @import("std");
const testing = std.testing;
const sequencer = @import("sequencer.zig");

const EpochBatcher = sequencer.EpochBatcher;

test "EpochBatcher: assigns dense gap-free seqs from next_seq" {
    var batcher = EpochBatcher.init(testing.allocator);
    defer batcher.deinit();

    try batcher.submit(1, 1);
    try batcher.submit(1, 2);
    try batcher.submit(1, 3);

    const decision = try batcher.closeEpoch(1, 1, 1, testing.allocator);
    defer testing.allocator.free(decision.entries);

    try testing.expectEqual(@as(usize, 3), decision.entries.len);
    try testing.expectEqual(@as(u64, 1), decision.entries[0].seq);
    try testing.expectEqual(@as(u64, 2), decision.entries[1].seq);
    try testing.expectEqual(@as(u64, 3), decision.entries[2].seq);
}

test "EpochBatcher: round-robin partition routing" {
    var batcher = EpochBatcher.init(testing.allocator);
    defer batcher.deinit();

    try batcher.submit(1, 1);
    try batcher.submit(1, 2);
    try batcher.submit(1, 3);
    try batcher.submit(1, 4);

    const decision = try batcher.closeEpoch(1, 1, 2, testing.allocator);
    defer testing.allocator.free(decision.entries);

    // seq 1 → partition 1%2=1, seq 2 → partition 2%2=0, seq 3 → 3%2=1, seq 4 → 4%2=0
    try testing.expectEqual(@as(u32, 1), decision.entries[0].partition);
    try testing.expectEqual(@as(u32, 0), decision.entries[1].partition);
    try testing.expectEqual(@as(u32, 1), decision.entries[2].partition);
    try testing.expectEqual(@as(u32, 0), decision.entries[3].partition);
}

test "EpochBatcher: clears pending after close" {
    var batcher = EpochBatcher.init(testing.allocator);
    defer batcher.deinit();

    try batcher.submit(1, 1);
    try testing.expectEqual(@as(usize, 1), batcher.pendingCount());

    const decision = try batcher.closeEpoch(1, 1, 1, testing.allocator);
    defer testing.allocator.free(decision.entries);

    try testing.expectEqual(@as(usize, 0), batcher.pendingCount());
}

test "EpochBatcher: shouldClose when at max" {
    var batcher = EpochBatcher.init(testing.allocator);
    defer batcher.deinit();
    batcher.max_batch_size = 2;

    try batcher.submit(1, 1);
    try testing.expect(!batcher.shouldClose());

    try batcher.submit(1, 2);
    try testing.expect(batcher.shouldClose());
}

test "EpochBatcher: epoch_num and client identity preserved" {
    var batcher = EpochBatcher.init(testing.allocator);
    defer batcher.deinit();

    try batcher.submit(42, 7);

    const decision = try batcher.closeEpoch(99, 100, 1, testing.allocator);
    defer testing.allocator.free(decision.entries);

    try testing.expectEqual(@as(u64, 99), decision.epoch_num);
    try testing.expectEqual(@as(u64, 100), decision.entries[0].seq);
    try testing.expectEqual(@as(u64, 42), decision.entries[0].client_id);
    try testing.expectEqual(@as(u64, 7), decision.entries[0].client_seq);
}
