/// Seeded KV workload generator for deterministic simulation tests.
///
/// Produces a reproducible sequence of typed KV operations.
/// The caller registers KV ops.
/// Same seed → same op sequence → same final state.
const std = @import("std");
const SimScheduler = @import("scheduler.zig").SimScheduler;



pub const OpKind = enum { insert, update, delete, get };

pub const Op = struct {
    kind: OpKind,
    id: i64,
    value: i64, // used by insert and update; ignored for delete/get
};

pub const Workload = struct {
    ops: []Op,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *Workload) void {
        self.alloc.free(self.ops);
    }
};

/// Generate `n_ops` operations from `sched`. The live key set is tracked so
/// updates and deletes only target keys that actually exist.
pub fn generate(sched: *SimScheduler, n_ops: usize, alloc: std.mem.Allocator) !Workload {
    const ops = try alloc.alloc(Op, n_ops);
    errdefer alloc.free(ops);

    // Track which ids are live so we can generate valid updates/deletes.
    var live = std.AutoHashMap(i64, void).init(alloc);
    defer live.deinit();

    // Pool of ids to draw from — keeps keys in a bounded range for interesting
    // overlap between inserts, updates, and deletes.
    const id_range: i64 = @intCast(@max(n_ops / 4, 4));

    for (ops) |*op| {
        const live_count = live.count();

        // Weight: prefer inserts when table is sparse, more variety when populated.
        const roll = sched.random().uintLessThan(u8, 100);
        const kind: OpKind = if (live_count == 0 or roll < 40)
            .insert
        else if (roll < 60)
            .update
        else if (roll < 75)
            .delete
        else
            .get;

        switch (kind) {
            .insert => {
                const id = sched.random().intRangeLessThan(i64, 1, id_range + 1);
                const value = sched.random().int(i64);
                // Avoid PK conflict: if id already live, treat as update.
                op.* = .{ .kind = if (live.contains(id)) .update else .insert, .id = id, .value = value };
                try live.put(id, {});
            },
            .update => {
                const id = randomLiveKey(sched, &live) orelse blk: {
                    // No live keys — fall back to insert.
                    const fid = sched.random().intRangeLessThan(i64, 1, id_range + 1);
                    try live.put(fid, {});
                    break :blk fid;
                };
                const value = sched.random().int(i64);
                op.* = .{ .kind = if (live.contains(id)) .update else .insert, .id = id, .value = value };
                try live.put(id, {});
            },
            .delete => {
                const id = randomLiveKey(sched, &live) orelse blk: {
                    const fid = sched.random().intRangeLessThan(i64, 1, id_range + 1);
                    break :blk fid;
                };
                op.* = .{ .kind = .delete, .id = id, .value = 0 };
                _ = live.remove(id);
            },
            .get => {
                const id = sched.random().intRangeLessThan(i64, 1, id_range + 1);
                op.* = .{ .kind = .get, .id = id, .value = 0 };
            },
        }
    }

    return .{ .ops = ops, .alloc = alloc };
}

fn randomLiveKey(sched: *SimScheduler, live: *std.AutoHashMap(i64, void)) ?i64 {
    const count = live.count();
    if (count == 0) return null;
    var target = sched.random().uintLessThan(usize, count);
    var it = live.keyIterator();
    while (it.next()) |key| {
        if (target == 0) return key.*;
        target -= 1;
    }
    return null;
}
