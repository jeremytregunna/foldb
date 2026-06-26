/// Recovery: restore from latest snapshot then replay log forward.
const std = @import("std");
const storage_mod = @import("storage.zig");
const executor_mod = @import("executor.zig");
const log_mod = @import("log.zig");

const ObjectStore = storage_mod.ObjectStore;
const LSM = storage_mod.LSM;
const Seq = storage_mod.Seq;
const Executor = executor_mod.Executor;
const Log = log_mod.Log;

pub const RecoveryResult = struct {
    lsm: LSM,
    recovered_through_seq: Seq,
};

/// Find the latest snapshot for the given partition, restore it, then replay
/// log entries from manifest.seq+1 to bring the LSM current.
pub fn recoverLatest(
    store: ObjectStore,
    partition_id: u32,
    lsm_dir: []const u8,
    log: *Log,
    executor: *Executor,
    alloc: std.mem.Allocator,
) !RecoveryResult {
    const prefix = try std.fmt.allocPrint(alloc, "snapshots/{d}/", .{partition_id});
    defer alloc.free(prefix);

    const keys = store.list(prefix, alloc) catch |err| switch (err) {
        error.KeyNotFound => blk: {
            const empty: [][]const u8 = &.{};
            break :blk empty;
        },
        else => return err,
    };
    defer {
        for (keys) |k| alloc.free(k);
        alloc.free(keys);
    }

    var best_seq: Seq = 0;
    var best_key: ?[]const u8 = null;
    for (keys) |k| {
        if (!std.mem.endsWith(u8, k, "/manifest")) continue;
        const parts = k[prefix.len..];
        const slash_pos = std.mem.indexOfScalar(u8, parts, '/') orelse continue;
        const seq_str = parts[0..slash_pos];
        const seq = std.fmt.parseUnsigned(Seq, seq_str, 10) catch continue;
        if (seq > best_seq) {
            best_seq = seq;
            best_key = k;
        }
    }

    var lsm: LSM = undefined;
    if (best_key == null or best_seq == 0) {
        lsm = try LSM.init(lsm_dir, alloc);
        return RecoveryResult{ .lsm = lsm, .recovered_through_seq = 0 };
    }

    // Deserialize and validate manifest from object store.
    const manifest_data = try store.get(best_key.?, alloc);
    defer alloc.free(manifest_data);
    var manifest = try storage_mod.manifestFromBytes(manifest_data, best_key.?, alloc);
    defer manifest.deinit();

    lsm = try storage_mod.restoreFromSnapshot(&manifest, lsm_dir, store, alloc);
    errdefer lsm.deinit();

    log.notify_snapshot(best_seq);

    const batch_size: usize = 1000;
    var replay_from: Seq = best_seq + 1;
    while (true) {
        const entries = try log.read(replay_from, batch_size, alloc);
        defer {
            for (entries) |*e| e.deinit(alloc);
            alloc.free(entries);
        }
        if (entries.len == 0) break;
        for (entries) |entry| {
            _ = try executor.run(entry);
        }
        replay_from = entries[entries.len - 1].header.seq + 1;
        if (entries.len < batch_size) break;
    }

    return RecoveryResult{
        .lsm = lsm,
        .recovered_through_seq = executor.committed_seq,
    };
}
