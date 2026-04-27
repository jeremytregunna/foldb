/// Partition routing utility — extracted from PartitionedStorage so executor
/// and gateway code can compute partition IDs without holding a PartitionedStorage.
const std = @import("std");

pub const PartitionId = u32;

/// Returns the data partition that owns `key` given `part_count` total partitions.
/// Uses the same wyhash(0, key) % N formula as PartitionedStorage.partitionIdx.
pub fn partitionFor(key: []const u8, part_count: u32) PartitionId {
    if (part_count <= 1) return 0;
    return @intCast(std.hash.Wyhash.hash(0, key) % part_count);
}
