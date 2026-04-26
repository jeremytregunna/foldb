/// Per-partition snapshot log writer context and callback.
/// TruncateCtx and onSnapshotComplete remain in gateway.zig (they reference Gateway directly).
const std = @import("std");
const sequencer_mod = @import("sequencer.zig");
const storage_mod = @import("storage.zig");

/// Per-partition context for the snapshot log writer hook. Stable once allocated in init.
pub const SnapshotWriterCtx = struct {
    sequencer: *sequencer_mod.Sequencer,
    partition_id: u32,
    client_id: u64,
    client_seq: u64,
};

/// Write a snapshot marker entry to the sequencer log so restarts can skip log replay
/// up to the snapshot point.
pub fn writeSnapshotToLog(ptr: *anyopaque, manifest_key: []const u8, seq: u64, partition_id: u32, alloc: std.mem.Allocator) anyerror!void {
    const ctx: *SnapshotWriterCtx = @ptrCast(@alignCast(ptr));
    const payload = storage_mod.SnapshotMarkerPayload{
        .manifest_key = manifest_key,
        .seq = seq,
        .partition_id = partition_id,
    };
    const bytes = try payload.serialize(alloc);
    defer alloc.free(bytes);
    ctx.client_seq += 1;
    var pending: sequencer_mod.PendingSubmit = undefined;
    _ = try ctx.sequencer.submitBytes(
        &pending,
        bytes,
        ctx.client_id,
        ctx.client_seq,
        .snapshot_marker,
    ).awaitCommit(null);
}
